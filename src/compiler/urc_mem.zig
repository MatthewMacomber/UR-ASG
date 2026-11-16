const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const UrMemStrategy = cell_mod.UrMemStrategy;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;

pub const EscapeStatus = enum {
    non_escaping,
    escapes_via_return,
    escapes_via_eav_commit,
    escapes_via_dynamic_call,
};

pub const CallOwnership = enum {
    fresh,
    borrow,
    mutate_or_escape,
};

// Ported from Aether src/autofree.zig: classifies builtin call ownership semantics.
pub const FRESH_BUILTINS = [_][]const u8{
    "list",
    "map",
    "set",
    "deque",
    "concat",
    "slice",
    "str_concat",
    "str_split",
    "str_join",
    "str_trim",
    "f32_to_str",
    "to_str",
    "alloc",
};

pub const BORROW_BUILTINS = [_][]const u8{
    "print",
    "length",
    "get",
    "add",
    "+",
    "sub",
    "-",
    "mul",
    "*",
    "div",
    "/",
    "gt",
    ">",
    "lt",
    "<",
    "eq",
    "==",
    "assert",
};

pub const MUTATE_BUILTINS = [_][]const u8{
    "append",
    "list_append",
    "set_at",
    "map_set",
    "set_add",
    "push_back",
    "commit_eav",
};

fn matchesAny(name: []const u8, table: []const []const u8) bool {
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

pub fn classifyCallOwnership(name: []const u8) CallOwnership {
    if (matchesAny(name, &FRESH_BUILTINS)) return .fresh;
    if (matchesAny(name, &BORROW_BUILTINS)) return .borrow;
    if (matchesAny(name, &MUTATE_BUILTINS)) return .mutate_or_escape;
    return .mutate_or_escape;
}

pub const AllocationInfo = struct {
    cell_idx: CellIdx,
    name_sym: cell_mod.SymId,
    status: EscapeStatus,
    strategy: UrMemStrategy,
};

pub const UrMemoryEngine = struct {
    compiler: *UrCompiler,
    allocations: std.ArrayListUnmanaged(AllocationInfo) = .empty,
    generation_counter: u32 = 1,
    has_autodiff_backprop: bool = false,

    pub fn init(compiler: *UrCompiler) UrMemoryEngine {
        return .{
            .compiler = compiler,
            .allocations = .empty,
            .generation_counter = 1,
            .has_autodiff_backprop = false,
        };
    }

    pub fn deinit(self: *UrMemoryEngine) void {
        self.allocations.deinit(self.compiler.allocator);
    }

    pub fn analyzeAndInstrumentUnit(self: *UrMemoryEngine, unit_idx: CellIdx) UrError!void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        if (unit_cell.kind != .unit_def) return;

        const strat = unit_cell.flags.mem_strategy;
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        self.allocations.clearRetainingCapacity();
        self.has_autodiff_backprop = self.hasBackpropCall(unit_idx);

        // Stage 1: Escape analysis over bindings inside the unit
        for (children) |child_idx| {
            try self.scanEscapeFlow(child_idx, unit_cell);
        }

        // Propagate escape status across local aliases: (let b a)
        try self.propagateAliasEscapes();

        // Stage 2 & 3: Instrument according to memory strategy & splice cells into unit
        switch (strat) {
            .vlang_autofree => {
                try self.instrumentAutofreeAndLobster(unit_idx);
            },
            .frame_arena => {
                try self.instrumentFrameArena(unit_idx);
            },
            .beef_guarded => {
                try self.instrumentBeefGuarded(unit_idx);
            },
            .raw_manual => {
                try self.instrumentRawManual(unit_idx);
            },
            .lobster_rc => {
                try self.instrumentPureLobster(unit_idx);
            },
            .cow_gc => {},
            _ => {},
        }
    }

    fn hasBackpropCall(self: *const UrMemoryEngine, idx: CellIdx) bool {
        if (idx == NULL_CELL) return false;
        const graph = self.compiler.graph;
        const cell = graph.getCell(idx);
        if (cell.kind == .grad_adjoint) return true;
        if (cell.kind == .call_node) {
            const name = graph.getSym(cell.head_idx);
            if (std.mem.eql(u8, name, "backward") or std.mem.eql(u8, name, "grad")) return true;
        }
        const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
        for (children) |c| {
            if (self.hasBackpropCall(c)) return true;
        }
        return false;
    }

    fn scanEscapeFlow(self: *UrMemoryEngine, idx: CellIdx, unit_cell: UrCell) !void {
        if (idx == NULL_CELL) return;
        const graph = self.compiler.graph;
        const cell = graph.getCell(idx);

        if (cell.kind == .let_bind) {
            // Check value of binding
            const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
            var is_escaping: EscapeStatus = .non_escaping;

            // If autodiff backprop retains intermediates, promote local tensors/allocs to RC.
            if (self.has_autodiff_backprop) {
                is_escaping = .escapes_via_dynamic_call;
            }

            for (children) |child_val| {
                const val_cell = graph.getCell(child_val);
                // String literals marked static do not escape as dynamic allocations unless returned by symbol
                if (self.reachesReturn(child_val, cell.head_idx, unit_cell)) {
                    is_escaping = .escapes_via_return;
                } else if (val_cell.kind != .bytes_blob and self.reachesEavCommit(child_val)) {
                    is_escaping = .escapes_via_eav_commit;
                } else if (val_cell.kind != .bytes_blob and self.reachesMutatingCall(cell.head_idx, unit_cell)) {
                    is_escaping = .escapes_via_dynamic_call;
                }
            }

            try self.allocations.append(self.compiler.allocator, .{
                .cell_idx = idx,
                .name_sym = cell.head_idx,
                .status = is_escaping,
                .strategy = if (is_escaping == .non_escaping) .vlang_autofree else .lobster_rc,
            });

            // If escape reporting diagnostic is enabled, commit diagnostic EAV fact
            if ((self.compiler.features & urc_mod.URC_DIAG_REPORT_ESCAPES) != 0 and is_escaping != .non_escaping) {
                const diag_sym = try graph.internSym("escape_reason");
                const reason = switch (is_escaping) {
                    .escapes_via_return => "returned_to_caller",
                    .escapes_via_eav_commit => "eav_global_commit",
                    .escapes_via_dynamic_call => "dynamic_call_escape",
                    .non_escaping => "local",
                };
                const reason_blob = try graph.allocBlob(reason);
                const diag_cell = try graph.allocCell(UrCell{
                    .kind = .bytes_blob,
                    .payload = .{ .raw = reason_blob },
                });
                try graph.eav_index.commitEav(idx, diag_sym, diag_cell, NULL_CELL);
            }
        }

        // Recurse children
        const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
        for (children) |c| {
            try self.scanEscapeFlow(c, unit_cell);
        }
    }

    fn propagateAliasEscapes(self: *UrMemoryEngine) !void {
        const graph = self.compiler.graph;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.allocations.items) |alias_alloc| {
                if (alias_alloc.status == .non_escaping) continue;
                const alias_cell = graph.getCell(alias_alloc.cell_idx);
                const children = graph.getChildren(alias_cell.payload.slice.start, alias_cell.payload.slice.len);
                if (children.len == 0) continue;
                const rhs_cell = graph.getCell(children[0]);
                if (rhs_cell.kind != .sym_atom) continue;

                for (self.allocations.items) |*src_alloc| {
                    if (src_alloc.name_sym == rhs_cell.head_idx and src_alloc.status == .non_escaping) {
                        src_alloc.status = alias_alloc.status;
                        src_alloc.strategy = .lobster_rc;
                        changed = true;
                    }
                }
            }
        }
    }

    fn reachesReturn(self: *UrMemoryEngine, val_idx: CellIdx, name_sym: cell_mod.SymId, unit_cell: UrCell) bool {
        const graph = self.compiler.graph;
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |c| {
            const child_cell = graph.getCell(c);
            if (child_cell.kind == .return_ok) {
                const ret_children = graph.getChildren(child_cell.payload.slice.start, child_cell.payload.slice.len);
                for (ret_children) |ret_c| {
                    if (ret_c == val_idx or self.isDescendantOf(ret_c, val_idx)) return true;
                    if (self.containsSym(ret_c, name_sym)) return true;
                }
            }
        }
        return false;
    }

    fn reachesMutatingCall(self: *UrMemoryEngine, name_sym: cell_mod.SymId, unit_cell: UrCell) bool {
        const graph = self.compiler.graph;
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |c| {
            if (self.nodePassesSymToMutatingCall(c, name_sym)) return true;
        }
        return false;
    }

    fn nodePassesSymToMutatingCall(self: *UrMemoryEngine, idx: CellIdx, name_sym: cell_mod.SymId) bool {
        if (idx == NULL_CELL) return false;
        const graph = self.compiler.graph;
        const cell = graph.getCell(idx);
        const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);

        if (cell.kind == .call_node) {
            const fn_name = graph.getSym(cell.head_idx);
            if (classifyCallOwnership(fn_name) == .mutate_or_escape) {
                for (children) |arg| {
                    if (self.containsSym(arg, name_sym)) return true;
                }
            }
        }

        for (children) |c| {
            if (self.nodePassesSymToMutatingCall(c, name_sym)) return true;
        }
        return false;
    }

    fn containsSym(self: *UrMemoryEngine, root: CellIdx, name_sym: cell_mod.SymId) bool {
        if (root == NULL_CELL) return false;
        const graph = self.compiler.graph;
        const cell = graph.getCell(root);
        if (cell.kind == .sym_atom and cell.head_idx == name_sym) return true;
        const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
        for (children) |c| {
            if (self.containsSym(c, name_sym)) return true;
        }
        return false;
    }

    fn reachesEavCommit(self: *UrMemoryEngine, cell_idx: CellIdx) bool {
        const graph = self.compiler.graph;
        const eav_rows = graph.eav_index.spo.items;
        for (eav_rows) |row| {
            if (row.object == cell_idx) return true;
        }
        return false;
    }

    fn isDescendantOf(self: *UrMemoryEngine, root: CellIdx, target: CellIdx) bool {
        if (root == target) return true;
        const graph = self.compiler.graph;
        const cell = graph.getCell(root);
        const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
        for (children) |c| {
            if (self.isDescendantOf(c, target)) return true;
        }
        return false;
    }

    fn hasInstrumentation(graph: *const UrGraph, children: []const CellIdx, kind: UrKind, target: CellIdx) bool {
        for (children) |c_idx| {
            const c = graph.getCell(c_idx);
            if (c.kind == kind and c.head_idx == target) return true;
        }
        return false;
    }

    fn spliceUnitInstrumentation(self: *UrMemoryEngine, unit_idx: CellIdx, extra_cells: []const CellIdx) !void {
        if (extra_cells.len == 0) return;
        const graph = self.compiler.graph;
        var unit_cell = graph.getCell(unit_idx);
        const old_children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var new_children: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer new_children.deinit(self.compiler.allocator);

        var inserted = false;
        for (old_children) |c_idx| {
            if (!inserted and graph.getCell(c_idx).kind == .return_ok) {
                try new_children.appendSlice(self.compiler.allocator, extra_cells);
                inserted = true;
            }
            try new_children.append(self.compiler.allocator, c_idx);
        }
        if (!inserted) {
            try new_children.appendSlice(self.compiler.allocator, extra_cells);
        }

        unit_cell.payload.slice = try graph.allocChildren(new_children.items, unit_idx);
        try graph.mutateCell(unit_idx, unit_cell);
    }

    fn instrumentAutofreeAndLobster(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const existing = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var spliced: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer spliced.deinit(self.compiler.allocator);

        for (self.allocations.items) |alloc| {
            if (alloc.status == .non_escaping) {
                if (hasInstrumentation(graph, existing, .scope_free, alloc.cell_idx)) continue;
                const free_cell = try graph.allocCell(UrCell{
                    .kind = .scope_free,
                    .head_idx = alloc.cell_idx,
                });
                try spliced.append(self.compiler.allocator, free_cell);
            } else if (alloc.status == .escapes_via_return or alloc.status == .escapes_via_dynamic_call) {
                if (hasInstrumentation(graph, existing, .rc_adjust, alloc.cell_idx)) continue;
                const rc_cell = try graph.allocCell(UrCell{
                    .kind = .rc_adjust,
                    .head_idx = alloc.cell_idx,
                    .payload = .{ .imm_i64 = 1 }, // retain on escape edge
                });
                try spliced.append(self.compiler.allocator, rc_cell);
            }
        }
        try self.spliceUnitInstrumentation(unit_idx, spliced.items);
    }

    fn instrumentFrameArena(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const existing = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var spliced: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer spliced.deinit(self.compiler.allocator);

        for (self.allocations.items) |alloc| {
            if (alloc.status == .escapes_via_return) {
                if (hasInstrumentation(graph, existing, .arena_promote, alloc.cell_idx)) continue;
                const promote_cell = try graph.allocCell(UrCell{
                    .kind = .arena_promote,
                    .head_idx = alloc.cell_idx,
                });
                try spliced.append(self.compiler.allocator, promote_cell);
            }
        }
        try self.spliceUnitInstrumentation(unit_idx, spliced.items);
    }

    fn instrumentBeefGuarded(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const existing = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var spliced: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer spliced.deinit(self.compiler.allocator);

        for (self.allocations.items) |alloc| {
            if (hasInstrumentation(graph, existing, .gen_guard_check, alloc.cell_idx)) continue;
            const gen = self.generation_counter;
            self.generation_counter += 1;
            const guard_cell = try graph.allocCell(UrCell{
                .kind = .gen_guard_check,
                .head_idx = alloc.cell_idx,
                .payload = .{ .imm_i64 = gen },
            });
            try spliced.append(self.compiler.allocator, guard_cell);
        }
        try self.spliceUnitInstrumentation(unit_idx, spliced.items);
    }

    fn instrumentRawManual(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const existing = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var spliced: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer spliced.deinit(self.compiler.allocator);

        for (self.allocations.items) |alloc| {
            if (hasInstrumentation(graph, existing, .borrow_ref, alloc.cell_idx)) continue;
            const borrow_cell = try graph.allocCell(UrCell{
                .kind = .borrow_ref,
                .head_idx = alloc.cell_idx,
            });
            try spliced.append(self.compiler.allocator, borrow_cell);
        }
        try self.spliceUnitInstrumentation(unit_idx, spliced.items);
    }

    fn instrumentPureLobster(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const existing = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        var spliced: std.ArrayListUnmanaged(CellIdx) = .empty;
        defer spliced.deinit(self.compiler.allocator);

        for (self.allocations.items) |alloc| {
            if (hasInstrumentation(graph, existing, .rc_adjust, alloc.cell_idx)) continue;
            const rc_cell = try graph.allocCell(UrCell{
                .kind = .rc_adjust,
                .head_idx = alloc.cell_idx,
                .payload = .{ .imm_i64 = 1 },
            });
            try spliced.append(self.compiler.allocator, rc_cell);
        }
        try self.spliceUnitInstrumentation(unit_idx, spliced.items);
    }
};

test "UrMemoryEngine escape analysis and autofree instrumentation" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var compiler = try UrCompiler.create(graph, urc_mod.FEAT_AUTOFREE_ARENA | urc_mod.FEAT_LOBSTER_RC);
    defer compiler.destroy();

    var mem_engine = UrMemoryEngine.init(compiler);
    defer mem_engine.deinit();

    // Build a unit with 1 local non-escaping temporary and 1 returned value
    const sym_unit = try graph.internSym("format_telemetry");
    const sym_temp = try graph.internSym("temp_buf");
    const sym_ret = try graph.internSym("result_buf");

    const temp_val = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 100 } });
    const let_temp = try graph.allocCell(UrCell{ .kind = .let_bind, .head_idx = sym_temp });
    const s1 = try graph.allocChildren(&.{temp_val}, let_temp);
    var c1 = graph.getCell(let_temp);
    c1.payload.slice = s1;
    try graph.mutateCell(let_temp, c1);

    const ret_val = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 200 } });
    const let_ret = try graph.allocCell(UrCell{ .kind = .let_bind, .head_idx = sym_ret });
    const s2 = try graph.allocChildren(&.{ret_val}, let_ret);
    var c2 = graph.getCell(let_ret);
    c2.payload.slice = s2;
    try graph.mutateCell(let_ret, c2);

    const ret_ok = try graph.allocCell(UrCell{ .kind = .return_ok });
    const s3 = try graph.allocChildren(&.{ret_val}, ret_ok);
    var c3 = graph.getCell(ret_ok);
    c3.payload.slice = s3;
    try graph.mutateCell(ret_ok, c3);

    const unit_idx = try graph.allocCell(UrCell{
        .kind = .unit_def,
        .head_idx = sym_unit,
        .flags = .{ .mem_strategy = .vlang_autofree },
    });
    const s_unit = try graph.allocChildren(&.{ let_temp, let_ret, ret_ok }, unit_idx);
    var c_unit = graph.getCell(unit_idx);
    c_unit.payload.slice = s_unit;
    try graph.mutateCell(unit_idx, c_unit);

    try mem_engine.analyzeAndInstrumentUnit(unit_idx);

    // Verify allocations identified
    try std.testing.expectEqual(@as(usize, 2), mem_engine.allocations.items.len);
    try std.testing.expectEqual(EscapeStatus.non_escaping, mem_engine.allocations.items[0].status);
    try std.testing.expectEqual(EscapeStatus.escapes_via_return, mem_engine.allocations.items[1].status);

    // Verify instrumentation cells were actually spliced before return_ok
    const final_unit = graph.getCell(unit_idx);
    const unit_children = graph.getChildren(final_unit.payload.slice.start, final_unit.payload.slice.len);
    try std.testing.expectEqual(@as(usize, 5), unit_children.len);
    try std.testing.expectEqual(UrKind.scope_free, graph.getCell(unit_children[2]).kind);
    try std.testing.expectEqual(let_temp, graph.getCell(unit_children[2]).head_idx);
    try std.testing.expectEqual(UrKind.rc_adjust, graph.getCell(unit_children[3]).kind);
    try std.testing.expectEqual(UrKind.return_ok, graph.getCell(unit_children[4]).kind);
}

test "UrMemoryEngine alias propagation and Tier0 use-after-free / double-free traps" {
    const tier0 = @import("tier0_eval.zig");
    const ext_mod = @import("ext_api.zig");
    const allocator = std.testing.allocator;

    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var compiler = try UrCompiler.create(graph, urc_mod.FEAT_AUTOFREE_ARENA | urc_mod.FEAT_LOBSTER_RC);
    defer compiler.destroy();

    // 1. Alias propagation: (let a 77) (let b a) (return_ok b) -> both escape!
    const sym_unit = try graph.internSym("alias_test");
    const sym_a = try graph.internSym("a");
    const sym_b = try graph.internSym("b");
    const lit_77 = try graph.allocCell(.{ .kind = .int_lit, .payload = .{ .imm_i64 = 77 } });
    const let_a = try graph.allocCell(.{ .kind = .let_bind, .head_idx = sym_a });
    var ca = graph.getCell(let_a);
    ca.payload.slice = try graph.allocChildren(&.{lit_77}, let_a);
    try graph.mutateCell(let_a, ca);

    const ref_a = try graph.allocCell(.{ .kind = .sym_atom, .head_idx = sym_a });
    const let_b = try graph.allocCell(.{ .kind = .let_bind, .head_idx = sym_b });
    var cb = graph.getCell(let_b);
    cb.payload.slice = try graph.allocChildren(&.{ref_a}, let_b);
    try graph.mutateCell(let_b, cb);

    const ref_b = try graph.allocCell(.{ .kind = .sym_atom, .head_idx = sym_b });
    const ret_b = try graph.allocCell(.{ .kind = .return_ok });
    var cr = graph.getCell(ret_b);
    cr.payload.slice = try graph.allocChildren(&.{ref_b}, ret_b);
    try graph.mutateCell(ret_b, cr);

    const unit_alias = try graph.allocCell(.{
        .kind = .unit_def,
        .head_idx = sym_unit,
        .flags = .{ .mem_strategy = .vlang_autofree },
    });
    var cu = graph.getCell(unit_alias);
    cu.payload.slice = try graph.allocChildren(&.{ let_a, let_b, ret_b }, unit_alias);
    try graph.mutateCell(unit_alias, cu);

    var mem_engine = UrMemoryEngine.init(compiler);
    defer mem_engine.deinit();
    try mem_engine.analyzeAndInstrumentUnit(unit_alias);
    try std.testing.expectEqual(EscapeStatus.escapes_via_return, mem_engine.allocations.items[0].status);
    try std.testing.expectEqual(EscapeStatus.escapes_via_return, mem_engine.allocations.items[1].status);

    // 2. Tier 0 traps on DoubleFreeTrap and UseAfterFreeTrap
    var t0 = tier0.Tier0Evaluator.init(compiler);
    var env = ext_mod.UrEvalEnv.init(allocator);
    defer env.deinit();

    _ = try t0.evalCell(let_a, &env, unit_alias, &.{});
    const free_a = try graph.allocCell(.{ .kind = .scope_free, .head_idx = let_a });
    _ = try t0.evalCell(free_a, &env, unit_alias, &.{});
    try std.testing.expectError(error.DoubleFreeTrap, t0.evalCell(free_a, &env, unit_alias, &.{}));
    try std.testing.expectError(error.UseAfterFreeTrap, t0.evalCell(ref_a, &env, unit_alias, &.{}));

    // Generation guard mismatch trap
    const guard_ok = try graph.allocCell(.{ .kind = .gen_guard_check, .head_idx = let_b, .payload = .{ .imm_i64 = 1 } });
    const guard_bad = try graph.allocCell(.{ .kind = .gen_guard_check, .head_idx = let_b, .payload = .{ .imm_i64 = 2 } });
    _ = try t0.evalCell(guard_ok, &env, unit_alias, &.{});
    try std.testing.expectError(error.UseAfterFreeTrap, t0.evalCell(guard_bad, &env, unit_alias, &.{}));
}

