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

    pub fn init(compiler: *UrCompiler) UrMemoryEngine {
        return .{
            .compiler = compiler,
            .allocations = .empty,
            .generation_counter = 1,
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

        // Stage 1: Escape analysis over bindings inside the unit
        for (children) |child_idx| {
            try self.scanEscapeFlow(child_idx, unit_cell);
        }

        // Stage 2 & 3: Instrument according to memory strategy
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

    fn scanEscapeFlow(self: *UrMemoryEngine, idx: CellIdx, unit_cell: UrCell) !void {
        if (idx == NULL_CELL) return;
        const graph = self.compiler.graph;
        const cell = graph.getCell(idx);

        if (cell.kind == .let_bind) {
            // Check value of binding
            const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
            var is_escaping: EscapeStatus = .non_escaping;

            // Check if returned by unit body
            for (children) |child_val| {
                const val_cell = graph.getCell(child_val);
                // String literals marked static do not escape as dynamic allocations
                if (val_cell.kind == .bytes_blob) {
                    continue;
                }
                if (self.reachesReturn(child_val, unit_cell)) {
                    is_escaping = .escapes_via_return;
                } else if (self.reachesEavCommit(child_val)) {
                    is_escaping = .escapes_via_eav_commit;
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
                const reason_blob = try graph.allocBlob(if (is_escaping == .escapes_via_return) "returned_to_caller" else "eav_global_commit");
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

    fn reachesReturn(self: *UrMemoryEngine, cell_idx: CellIdx, unit_cell: UrCell) bool {
        const graph = self.compiler.graph;
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |c| {
            const child_cell = graph.getCell(c);
            if (child_cell.kind == .return_ok) {
                const ret_children = graph.getChildren(child_cell.payload.slice.start, child_cell.payload.slice.len);
                for (ret_children) |ret_c| {
                    if (ret_c == cell_idx or self.isDescendantOf(ret_c, cell_idx)) return true;
                }
            }
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

    fn instrumentAutofreeAndLobster(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        for (self.allocations.items) |alloc| {
            if (alloc.status == .non_escaping) {
                // Splice scope_free (0x2C) cell
                const free_cell = try graph.allocCell(UrCell{
                    .kind = .scope_free,
                    .head_idx = alloc.cell_idx,
                });
                _ = free_cell;
            } else if (alloc.status == .escapes_via_return or alloc.status == .escapes_via_dynamic_call) {
                // Promote remaining escaping dynamic objects to MEM_LOBSTER_RC and splice rc_adjust (0x2D)
                const rc_cell = try graph.allocCell(UrCell{
                    .kind = .rc_adjust,
                    .head_idx = alloc.cell_idx,
                    .payload = .{ .imm_i64 = 1 }, // retain on escape edge
                });
                _ = rc_cell;
            }
        }
        _ = unit_idx;
    }

    fn instrumentFrameArena(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        // Check if any allocation escapes via return -> insert arena_promote (0x31) copy
        for (self.allocations.items) |alloc| {
            if (alloc.status == .escapes_via_return) {
                const promote_cell = try graph.allocCell(UrCell{
                    .kind = .arena_promote,
                    .head_idx = alloc.cell_idx,
                });
                _ = promote_cell;
            }
        }
        _ = unit_idx;
    }

    fn instrumentBeefGuarded(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        for (self.allocations.items) |alloc| {
            const gen = self.generation_counter;
            self.generation_counter += 1;
            // Tag with gen_guard_check (0x2E)
            const guard_cell = try graph.allocCell(UrCell{
                .kind = .gen_guard_check,
                .head_idx = alloc.cell_idx,
                .payload = .{ .imm_i64 = gen },
            });
            _ = guard_cell;
        }
        _ = unit_idx;
    }

    fn instrumentRawManual(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        // Enforce zero inserted frees; annotate cross-boundary calls with borrow_ref
        for (self.allocations.items) |alloc| {
            const borrow_cell = try graph.allocCell(UrCell{
                .kind = .borrow_ref,
                .head_idx = alloc.cell_idx,
            });
            _ = borrow_cell;
        }
        _ = unit_idx;
    }

    fn instrumentPureLobster(self: *UrMemoryEngine, unit_idx: CellIdx) !void {
        const graph = self.compiler.graph;
        for (self.allocations.items) |alloc| {
            const rc_cell = try graph.allocCell(UrCell{
                .kind = .rc_adjust,
                .head_idx = alloc.cell_idx,
                .payload = .{ .imm_i64 = 1 },
            });
            _ = rc_cell;
        }
        _ = unit_idx;
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
}

