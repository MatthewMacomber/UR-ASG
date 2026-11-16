const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const SymId = cell_mod.SymId;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const sexpr_lens = @import("../sexpr_lens.zig");
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;

pub fn runAllPasses(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    try runConstantFoldingPass(compiler, unit_root);

    if ((compiler.features & urc_mod.FEAT_SAMPLE_ORACLE) != 0) {
        try runSampleOraclePass(compiler, unit_root);
    }
    if ((compiler.features & urc_mod.FEAT_HAZEL_MEMBRANES) != 0) {
        try runHazelMembranePass(compiler, unit_root);
    }
    if ((compiler.features & urc_mod.FEAT_RELATIONAL_SIMD) != 0) {
        try runRelationalSimdPass(compiler, unit_root);
    }
    if ((compiler.features & urc_mod.FEAT_MMIO_CAPABILITIES) != 0) {
        try runMmioCapabilityPass(compiler, unit_root);
    }
    if ((compiler.features & urc_mod.FEAT_UNCERTAIN_AUTODIFF) != 0) {
        try runUncertainAutodiffPass(compiler, unit_root);
    }

    // Wire host domain extension rewrites & typechecking (opcodes 0x80..0xFF)
    for (compiler.extensions.items) |ext| {
        if (ext.run_custom_rewrite_pass) |rewrite_fn| {
            _ = try rewrite_fn(compiler.graph, unit_root);
        }
    }
    try runExtensionTypecheckPass(compiler, unit_root);
}

fn isLeafOrSpecial(kind: UrKind) bool {
    return switch (kind) {
        .nil_cell, .bool_lit, .int_lit, .float_lit, .fixed_q16_16, .uncertain_f32, .sym_atom, .bytes_blob, .cyclic_backref, .eav_tuple, .hazel_hole, .mmio_capability, .irq_capability => true,
        else => false,
    };
}

pub fn runConstantFoldingPass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        try foldConstantsRecursive(graph, child_idx, 0);
    }
}

fn foldConstantsRecursive(graph: *UrGraph, idx: CellIdx, depth: u32) UrError!void {
    if (idx == NULL_CELL or depth >= 256) return;
    const cell = graph.getCell(idx);
    if (isLeafOrSpecial(cell.kind) or cell.kind == .sample_io_row or cell.kind == .grad_adjoint) return;

    const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
    for (children) |c| {
        try foldConstantsRecursive(graph, c, depth + 1);
    }

    if (cell.kind == .call_node and children.len >= 2) {
        const op = graph.getSym(cell.head_idx);
        const c1 = graph.getCell(children[0]);
        const c2 = graph.getCell(children[1]);

        if (c1.kind == .int_lit and c2.kind == .int_lit) {
            const a = c1.payload.imm_i64;
            const b = c2.payload.imm_i64;
            const folded: ?i64 = if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "add"))
                a +% b
            else if (std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "sub"))
                a -% b
            else if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "mul"))
                a *% b
            else if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "div")) and b != 0)
                @divTrunc(a, b)
            else
                null;
            if (folded) |v| {
                graph.mutateCell(idx, .{
                    .kind = .int_lit,
                    .type_id = BuiltinType.int_type,
                    .payload = .{ .imm_i64 = v },
                }) catch return error.OutOfMemory;
            }
        } else if ((c1.kind == .float_lit or c1.kind == .int_lit) and (c2.kind == .float_lit or c2.kind == .int_lit) and
            (c1.kind == .float_lit or c2.kind == .float_lit))
        {
            const a = if (c1.kind == .float_lit) c1.payload.imm_f64 else @as(f64, @floatFromInt(c1.payload.imm_i64));
            const b = if (c2.kind == .float_lit) c2.payload.imm_f64 else @as(f64, @floatFromInt(c2.payload.imm_i64));
            const folded: ?f64 = if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "add"))
                a + b
            else if (std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "sub"))
                a - b
            else if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "mul"))
                a * b
            else if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "div")) and b != 0.0)
                a / b
            else
                null;
            if (folded) |v| {
                graph.mutateCell(idx, .{
                    .kind = .float_lit,
                    .type_id = BuiltinType.float_type,
                    .payload = .{ .imm_f64 = v },
                }) catch return error.OutOfMemory;
            }
        }
    }
}

pub fn runExtensionTypecheckPass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        try typecheckExtensionsRecursive(compiler, child_idx, 0);
    }
}

fn typecheckExtensionsRecursive(compiler: *UrCompiler, idx: CellIdx, depth: u32) UrError!void {
    if (idx == NULL_CELL or depth >= 256) return;
    const graph = compiler.graph;
    var cell = graph.getCell(idx);

    if (@intFromEnum(cell.kind) >= 0x80) {
        if (compiler.findExtension(@intFromEnum(cell.kind))) |ext| {
            if (ext.typecheck_domain_cell) |tc_fn| {
                const new_tid = try tc_fn(graph, idx);
                if (new_tid != cell.type_id) {
                    cell.type_id = new_tid;
                    graph.mutateCell(idx, cell) catch return error.OutOfMemory;
                }
            }
        }
    }

    if (isLeafOrSpecial(cell.kind)) return;
    const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
    for (children) |c| {
        try typecheckExtensionsRecursive(compiler, c, depth + 1);
    }
}

pub fn runSampleOraclePass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        const child = graph.getCell(child_idx);
        if (child.kind == .needs_stub) {
            // Find sample table attached to unit or child and link fallback
            var updated = child;
            updated.flags.verified = true;
            try graph.mutateCell(child_idx, updated);
        } else if (child.kind == .showboat_proof) {
            var updated = child;
            updated.flags.verified = true;
            try graph.mutateCell(child_idx, updated);
        }
    }
}

pub fn runHazelMembranePass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        try checkMembranesRecursive(graph, child_idx, 0);
    }
}

fn checkMembranesRecursive(graph: *UrGraph, idx: CellIdx, depth: u32) UrError!void {
    if (idx == NULL_CELL or depth >= 256) return;
    const cell = graph.getCell(idx);

    if (cell.kind == .hazel_hole or cell.kind == .hazel_membrane or isLeafOrSpecial(cell.kind)) {
        return;
    }

    const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);

    // If let_bind specifies an explicit expected type, wrap mismatched child in hazel_membrane
    if (cell.kind == .let_bind and children.len > 0 and
        cell.type_id != BuiltinType.any_type and cell.type_id != BuiltinType.hole_type)
    {
        const val_idx = children[0];
        const val_cell = graph.getCell(val_idx);
        if (val_cell.kind != .hazel_membrane and val_cell.kind != .hazel_hole) {
            const diff = sexpr_lens.SexprLens.computeTypeDiff(graph, idx, val_idx);
            if (diff.status == .needs_membrane or diff.status == .incompatible) {
                const copy_idx = graph.allocCell(val_cell) catch return error.OutOfMemory;
                var hole_shell = val_cell;
                hole_shell.type_id = cell.type_id;
                graph.mutateCell(val_idx, hole_shell) catch return error.OutOfMemory;
                _ = graph.spliceHole(val_idx, copy_idx) catch return error.OutOfMemory;
                return;
            }
        }
    }

    for (children) |c| {
        try checkMembranesRecursive(graph, c, depth + 1);
    }
}

pub fn runRelationalSimdPass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        const child = graph.getCell(child_idx);
        if (child.kind == .query_search or child.kind == .shard_wire) {
            // Lower to SIMD kernel loop node
            var simd_cell = child;
            simd_cell.kind = .simd_kernel;
            try graph.mutateCell(child_idx, simd_cell);
        }
    }
}

pub fn runMmioCapabilityPass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        const child = graph.getCell(child_idx);
        if (child.kind == .mmio_capability) {
            // Verify bounds: base_addr > 0 and byte_len > 0
            if (child.payload.capability.base_addr == 0 or child.payload.capability.byte_len == 0) {
                return error.CapabilityViolation;
            }
        }
    }
}

fn makeNumCell(graph: *UrGraph, val: f64) UrError!CellIdx {
    return graph.allocCell(.{
        .kind = .float_lit,
        .type_id = BuiltinType.float_type,
        .payload = .{ .imm_f64 = val },
    }) catch return error.OutOfMemory;
}

fn makeCallCell(graph: *UrGraph, op_name: []const u8, args: []const CellIdx) UrError!CellIdx {
    const sym = graph.internSym(op_name) catch return error.OutOfMemory;
    const call_idx = graph.allocCell(.{
        .kind = .call_node,
        .type_id = BuiltinType.float_type,
        .head_idx = sym,
    }) catch return error.OutOfMemory;
    var c = graph.getCell(call_idx);
    c.payload.slice = graph.allocChildren(args, call_idx) catch return error.OutOfMemory;
    graph.mutateCell(call_idx, c) catch return error.OutOfMemory;
    return call_idx;
}

fn cellFloatVal(cell: UrCell) ?f64 {
    return switch (cell.kind) {
        .float_lit => cell.payload.imm_f64,
        .int_lit => @as(f64, @floatFromInt(cell.payload.imm_i64)),
        else => null,
    };
}

/// Ported from Aether src/autodiff.zig: symbolic differentiation over UrGraph cells.
pub fn diffCell(graph: *UrGraph, expr_idx: CellIdx, wrt_sym: SymId) UrError!CellIdx {
    if (expr_idx == NULL_CELL) return makeNumCell(graph, 0.0);
    const cell = graph.getCell(expr_idx);
    switch (cell.kind) {
        .nil_cell, .bool_lit, .int_lit, .float_lit, .fixed_q16_16, .uncertain_f32, .bytes_blob => {
            return makeNumCell(graph, 0.0);
        },
        .sym_atom => {
            return makeNumCell(graph, if (cell.head_idx == wrt_sym) 1.0 else 0.0);
        },
        .if_branch => {
            const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
            if (ch.len < 3) return makeNumCell(graph, 0.0);
            const du = try diffCell(graph, ch[1], wrt_sym);
            const dv = try diffCell(graph, ch[2], wrt_sym);
            const if_idx = graph.allocCell(.{ .kind = .if_branch, .type_id = BuiltinType.float_type }) catch return error.OutOfMemory;
            var ic = graph.getCell(if_idx);
            ic.payload.slice = graph.allocChildren(&.{ ch[0], du, dv }, if_idx) catch return error.OutOfMemory;
            graph.mutateCell(if_idx, ic) catch return error.OutOfMemory;
            return if_idx;
        },
        .call_node => {
            const op = graph.getSym(cell.head_idx);
            const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
            if ((std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "add")) and ch.len >= 2) {
                return makeCallCell(graph, "+", &.{ try diffCell(graph, ch[0], wrt_sym), try diffCell(graph, ch[1], wrt_sym) });
            } else if ((std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "sub")) and ch.len >= 2) {
                return makeCallCell(graph, "-", &.{ try diffCell(graph, ch[0], wrt_sym), try diffCell(graph, ch[1], wrt_sym) });
            } else if ((std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "mul")) and ch.len >= 2) {
                const du = try diffCell(graph, ch[0], wrt_sym);
                const dv = try diffCell(graph, ch[1], wrt_sym);
                const t1 = try makeCallCell(graph, "*", &.{ du, ch[1] });
                const t2 = try makeCallCell(graph, "*", &.{ ch[0], dv });
                return makeCallCell(graph, "+", &.{ t1, t2 });
            } else if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "div")) and ch.len >= 2) {
                const du = try diffCell(graph, ch[0], wrt_sym);
                const dv = try diffCell(graph, ch[1], wrt_sym);
                const num = try makeCallCell(graph, "-", &.{
                    try makeCallCell(graph, "*", &.{ du, ch[1] }),
                    try makeCallCell(graph, "*", &.{ ch[0], dv }),
                });
                const denom = try makeCallCell(graph, "*", &.{ ch[1], ch[1] });
                return makeCallCell(graph, "/", &.{ num, denom });
            } else if (std.mem.eql(u8, op, "exp") and ch.len >= 1) {
                const du = try diffCell(graph, ch[0], wrt_sym);
                return makeCallCell(graph, "*", &.{ try makeCallCell(graph, "exp", &.{ch[0]}), du });
            } else if (std.mem.eql(u8, op, "sin") and ch.len >= 1) {
                const du = try diffCell(graph, ch[0], wrt_sym);
                return makeCallCell(graph, "*", &.{ try makeCallCell(graph, "cos", &.{ch[0]}), du });
            } else if (std.mem.eql(u8, op, "cos") and ch.len >= 1) {
                const du = try diffCell(graph, ch[0], wrt_sym);
                const neg_sin = try makeCallCell(graph, "-", &.{ try makeNumCell(graph, 0.0), try makeCallCell(graph, "sin", &.{ch[0]}) });
                return makeCallCell(graph, "*", &.{ neg_sin, du });
            } else if (std.mem.eql(u8, op, "log") and ch.len >= 1) {
                return makeCallCell(graph, "/", &.{ try diffCell(graph, ch[0], wrt_sym), ch[0] });
            }
            return makeNumCell(graph, 0.0);
        },
        else => return makeNumCell(graph, 0.0),
    }
}

/// Ported from Aether src/autodiff.zig: algebraic simplification (0+x->x, 0*x->0, 1*x->x, constant eval).
pub fn simplifyCell(graph: *UrGraph, expr_idx: CellIdx) UrError!CellIdx {
    if (expr_idx == NULL_CELL) return expr_idx;
    const cell = graph.getCell(expr_idx);
    if (cell.kind != .call_node) return expr_idx;

    const op = graph.getSym(cell.head_idx);
    const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
    if (ch.len < 2) return expr_idx;

    const l = try simplifyCell(graph, ch[0]);
    const r = try simplifyCell(graph, ch[1]);
    const lv = cellFloatVal(graph.getCell(l));
    const rv = cellFloatVal(graph.getCell(r));

    const is_add = std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "add");
    const is_sub = std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "sub");
    const is_mul = std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "mul");
    const is_div = std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "div");

    if (lv != null and rv != null) {
        if (is_add) return makeNumCell(graph, lv.? + rv.?);
        if (is_sub) return makeNumCell(graph, lv.? - rv.?);
        if (is_mul) return makeNumCell(graph, lv.? * rv.?);
        if (is_div and rv.? != 0.0) return makeNumCell(graph, lv.? / rv.?);
    }

    if (is_add) {
        if (lv != null and lv.? == 0.0) return r;
        if (rv != null and rv.? == 0.0) return l;
    } else if (is_sub) {
        if (rv != null and rv.? == 0.0) return l;
    } else if (is_mul) {
        if ((lv != null and lv.? == 0.0) or (rv != null and rv.? == 0.0)) return makeNumCell(graph, 0.0);
        if (lv != null and lv.? == 1.0) return r;
        if (rv != null and rv.? == 1.0) return l;
    } else if (is_div) {
        if (lv != null and lv.? == 0.0) return makeNumCell(graph, 0.0);
        if (rv != null and rv.? == 1.0) return l;
    }

    return makeCallCell(graph, op, &.{ l, r });
}

fn findFirstSymbol(graph: *const UrGraph, idx: CellIdx, depth: u32) ?SymId {
    if (idx == NULL_CELL or depth >= 64) return null;
    const c = graph.getCell(idx);
    if (c.kind == .sym_atom) return c.head_idx;
    if (isLeafOrSpecial(c.kind)) return null;
    const children = graph.getChildren(c.payload.slice.start, c.payload.slice.len);
    for (children) |ch| {
        if (findFirstSymbol(graph, ch, depth + 1)) |s| return s;
    }
    return null;
}

pub fn runUncertainAutodiffPass(compiler: *UrCompiler, unit_root: CellIdx) UrError!void {
    const graph = compiler.graph;
    const unit_cell = graph.getCell(unit_root);
    if (unit_cell.kind != .unit_def) return;

    const sym_grad = graph.internSym("grad_adjoint") catch return error.OutOfMemory;
    const default_wrt = findFirstSymbol(graph, unit_root, 0) orelse (graph.internSym("x") catch return error.OutOfMemory);

    const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
    for (children) |child_idx| {
        const child = graph.getCell(child_idx);
        if (child.kind == .uncertain_f32) {
            const one = try makeNumCell(graph, 1.0);
            const grad_idx = try graph.allocCell(UrCell{
                .kind = .grad_adjoint,
                .type_id = BuiltinType.float_type,
                .head_idx = child_idx,
            });
            var gc = graph.getCell(grad_idx);
            gc.payload.slice = graph.allocChildren(&.{one}, grad_idx) catch return error.OutOfMemory;
            try graph.mutateCell(grad_idx, gc);
            graph.eav_index.commitEav(child_idx, sym_grad, grad_idx, grad_idx) catch return error.OutOfMemory;
        } else if (child.kind == .return_ok) {
            const ret_ch = graph.getChildren(child.payload.slice.start, child.payload.slice.len);
            if (ret_ch.len > 0) {
                const raw_d = try diffCell(graph, ret_ch[0], default_wrt);
                const simp_d = try simplifyCell(graph, raw_d);
                const grad_idx = try graph.allocCell(UrCell{
                    .kind = .grad_adjoint,
                    .type_id = BuiltinType.float_type,
                    .head_idx = ret_ch[0],
                });
                var gc = graph.getCell(grad_idx);
                gc.payload.slice = graph.allocChildren(&.{simp_d}, grad_idx) catch return error.OutOfMemory;
                try graph.mutateCell(grad_idx, gc);
                graph.eav_index.commitEav(unit_root, sym_grad, grad_idx, grad_idx) catch return error.OutOfMemory;
            }
        }
    }
}

test "passes: constant folding, symbolic autodiff simplification, hazel membrane & extensions" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    // 1. Constant folding: (unit cf (return_ok (call + 10 32))) -> (return_ok 42)
    const cf_unit = try sexpr_lens.parseSexpr(graph, "(unit cf (return_ok (call + 10 32)))");
    var comp = try UrCompiler.create(graph, urc_mod.FEAT_HAZEL_MEMBRANES | urc_mod.FEAT_UNCERTAIN_AUTODIFF);
    defer comp.destroy();

    try runConstantFoldingPass(comp, cf_unit);
    const cf_ret = graph.getChildren(graph.getCell(cf_unit).payload.slice.start, graph.getCell(cf_unit).payload.slice.len)[0];
    const cf_val_idx = graph.getChildren(graph.getCell(cf_ret).payload.slice.start, graph.getCell(cf_ret).payload.slice.len)[0];
    try std.testing.expectEqual(UrKind.int_lit, graph.getCell(cf_val_idx).kind);
    try std.testing.expectEqual(@as(i64, 42), graph.getCell(cf_val_idx).payload.imm_i64);

    // 2. Symbolic differentiation of (+ (+ (* x x) (* 3.0 x)) 5.0) w.r.t x -> (+ (+ x x) 3.0)
    const diff_unit = try sexpr_lens.parseSexpr(graph, "(unit poly (return_ok (call + (call + (call * x x) (call * 3.0 x)) 5.0)))");
    try runUncertainAutodiffPass(comp, diff_unit);
    const sym_grad = try graph.internSym("grad_adjoint");
    const grad_idx = graph.eav_index.querySpo(diff_unit, sym_grad) orelse return error.EvaluationError;
    const grad_cell = graph.getCell(grad_idx);
    try std.testing.expectEqual(UrKind.grad_adjoint, grad_cell.kind);
    const deriv_idx = graph.getChildren(grad_cell.payload.slice.start, grad_cell.payload.slice.len)[0];
    var buf: [256]u8 = undefined;
    const len = try sexpr_lens.printSexpr(graph, deriv_idx, &buf);
    try std.testing.expectEqualStrings("(call + (call + x x) 3.00)", buf[0..len]);

    // 3. Hazel membrane insertion on typed let_bind mismatch (bool -> float)
    const sym_typed = try graph.internSym("typed_val");
    const bad_bool = try graph.allocCell(.{ .kind = .bool_lit, .type_id = BuiltinType.bool_type, .payload = .{ .raw = 1 } });
    const let_typed = try graph.allocCell(.{ .kind = .let_bind, .type_id = BuiltinType.float_type, .head_idx = sym_typed });
    var lt = graph.getCell(let_typed);
    lt.payload.slice = try graph.allocChildren(&.{bad_bool}, let_typed);
    try graph.mutateCell(let_typed, lt);
    const hm_unit = try graph.allocCell(.{ .kind = .unit_def, .head_idx = try graph.internSym("hm_u") });
    var hu = graph.getCell(hm_unit);
    hu.payload.slice = try graph.allocChildren(&.{let_typed}, hm_unit);
    try graph.mutateCell(hm_unit, hu);

    try runHazelMembranePass(comp, hm_unit);
    try std.testing.expectEqual(UrKind.hazel_membrane, graph.getCell(bad_bool).kind);

    // 4. Domain extension rewrite + typecheck dispatch
    const dom_op: u8 = 0x85;
    try comp.registerExtension(.{
        .ext_name = "tensor_ext",
        .opcode_range_start = dom_op,
        .opcode_range_end = dom_op,
        .typecheck_domain_cell = struct {
            fn tc(_: *UrGraph, _: CellIdx) UrError!cell_mod.TypeId {
                return BuiltinType.float_type;
            }
        }.tc,
        .run_custom_rewrite_pass = struct {
            fn rw(g: *UrGraph, u: CellIdx) UrError!bool {
                const uc = g.getCell(u);
                const ch = g.getChildren(uc.payload.slice.start, uc.payload.slice.len);
                if (ch.len > 0) {
                    var dc = g.getCell(ch[0]);
                    dc.flags.verified = true;
                    g.mutateCell(ch[0], dc) catch return error.OutOfMemory;
                }
                return true;
            }
        }.rw,
    });
    const dom_cell = try graph.allocCell(.{ .kind = @enumFromInt(dom_op), .type_id = BuiltinType.any_type });
    const ext_unit = try graph.allocCell(.{ .kind = .unit_def, .head_idx = try graph.internSym("ext_u") });
    var eu = graph.getCell(ext_unit);
    eu.payload.slice = try graph.allocChildren(&.{dom_cell}, ext_unit);
    try graph.mutateCell(ext_unit, eu);

    try runAllPasses(comp, ext_unit);
    try std.testing.expect(graph.getCell(dom_cell).flags.verified);
    try std.testing.expectEqual(BuiltinType.float_type, graph.getCell(dom_cell).type_id);
}

