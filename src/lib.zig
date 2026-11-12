const std = @import("std");

pub const cell = @import("cell.zig");
pub const graph_store = @import("graph_store.zig");
pub const merkle = @import("merkle.zig");
pub const eav_index = @import("eav_index.zig");
pub const lens_api = @import("lens_api.zig");
pub const sexpr_lens = @import("sexpr_lens.zig");
pub const binary_codec = @import("binary_codec.zig");

pub const compiler = struct {
    pub const core = @import("compiler/urc_core.zig");
    pub const mem = @import("compiler/urc_mem.zig");
    pub const passes = @import("compiler/passes.zig");
    pub const tier0 = @import("compiler/tier0_eval.zig");
    pub const tier1 = @import("compiler/tier1_jit.zig");
    pub const tier2 = @import("compiler/tier2_aot.zig");
    pub const ext = @import("compiler/ext_api.zig");
};

pub const UrCell = cell.UrCell;
pub const CellIdx = cell.CellIdx;
pub const NULL_CELL = cell.NULL_CELL;
pub const UrKind = cell.UrKind;
pub const UrGraph = graph_store.UrGraph;
pub const UrCompiler = compiler.core.UrCompiler;

// ============================================================================
// Stable C ABI Export Implementation (matching include/urasg.h)
// ============================================================================

pub export fn urasg_create(initial_cells: usize) ?*UrGraph {
    _ = initial_cells;
    return UrGraph.create(std.heap.page_allocator) catch null;
}

pub export fn urasg_destroy(g: ?*UrGraph) void {
    if (g) |graph| graph.destroy();
}

pub export fn urasg_fork_cow(parent: ?*const UrGraph) ?*UrGraph {
    if (parent) |p| {
        return p.forkCow() catch null;
    }
    return null;
}

pub export fn urasg_merkle_hash(g: ?*UrGraph, root: CellIdx) u64 {
    if (g) |graph| {
        return graph.merkleHash(root) catch 0;
    }
    return 0;
}

pub export fn urasg_alloc_cell(g: ?*UrGraph, c: UrCell) CellIdx {
    if (g) |graph| {
        return graph.allocCell(c) catch NULL_CELL;
    }
    return NULL_CELL;
}

pub export fn urasg_get_cell(g: ?*const UrGraph, idx: CellIdx) UrCell {
    if (g) |graph| {
        return graph.getCell(idx);
    }
    return UrCell{};
}

pub export fn urasg_set_cell(g: ?*UrGraph, idx: CellIdx, c: UrCell) void {
    if (g) |graph| {
        graph.mutateCell(idx, c) catch {};
    }
}

pub export fn urasg_splice_hole(g: ?*UrGraph, hole_idx: CellIdx, plug_idx: CellIdx) CellIdx {
    if (g) |graph| {
        return graph.spliceHole(hole_idx, plug_idx) catch NULL_CELL;
    }
    return NULL_CELL;
}

pub export fn urasg_intern_sym(g: ?*UrGraph, name: [*:0]const u8, len: usize) u32 {
    if (g) |graph| {
        const slice = name[0..len];
        return graph.internSym(slice) catch 0;
    }
    return 0;
}

pub export fn urasg_commit_eav(g: ?*UrGraph, entity: u32, attr_sym: u32, val: CellIdx) void {
    if (g) |graph| {
        graph.eav_index.commitEav(entity, attr_sym, val, NULL_CELL) catch {};
    }
}

pub export fn urasg_query_eav(g: ?*const UrGraph, entity: u32, attr_sym: u32) CellIdx {
    if (g) |graph| {
        return graph.eav_index.querySpo(entity, attr_sym) orelse NULL_CELL;
    }
    return NULL_CELL;
}

pub export fn urasg_eval_unit(g: ?*UrGraph, unit_idx: CellIdx, args: ?[*]const CellIdx, arg_count: usize) CellIdx {
    if (g) |graph| {
        var c = UrCompiler.create(graph, compiler.core.DEFAULT_FEATURES) catch return NULL_CELL;
        defer c.destroy();
        var t0 = compiler.tier0.Tier0Evaluator.init(c);
        const args_slice = if (args) |a| a[0..arg_count] else &.{};
        return t0.evalUnit(unit_idx, args_slice) catch NULL_CELL;
    }
    return NULL_CELL;
}

pub export fn urc_create_compiler(g: ?*UrGraph, feature_flags: u64) ?*UrCompiler {
    if (g) |graph| {
        return UrCompiler.create(graph, feature_flags) catch null;
    }
    return null;
}

pub export fn urc_destroy_compiler(c: ?*UrCompiler) void {
    if (c) |comp| comp.destroy();
}

pub export fn urc_register_extension(c: ?*UrCompiler, ext_name: [*:0]const u8, start_op: u8, end_op: u8) c_int {
    if (c) |comp| {
        const len = std.mem.len(ext_name);
        const name_slice = ext_name[0..len];
        comp.registerExtension(.{
            .ext_name = name_slice,
            .opcode_range_start = start_op,
            .opcode_range_end = end_op,
        }) catch return -1;
        return 0;
    }
    return -1;
}

pub export fn urc_compile_unit(c: ?*UrCompiler, unit_idx: CellIdx, target_tier: c_int) c_int {
    if (c) |comp| {
        var mem_eng = compiler.mem.UrMemoryEngine.init(comp);
        defer mem_eng.deinit();
        mem_eng.analyzeAndInstrumentUnit(unit_idx) catch return -1;

        compiler.passes.runAllPasses(comp, unit_idx) catch return -1;

        if (target_tier == 1) {
            var j = compiler.tier1.Tier1JitEngine.init(comp);
            var mod = j.compileUnit(unit_idx) catch return -1;
            mod.deinit();
        } else if (target_tier == 2) {
            var aot = compiler.tier2.Tier2AotCompiler.init(comp);
            _ = aot.promoteBuiltin(unit_idx) catch return -1;
        }
        return 0;
    }
    return -1;
}

pub export fn urc_promote_builtin(c: ?*UrCompiler, unit_idx: CellIdx) c_int {
    if (c) |comp| {
        var aot = compiler.tier2.Tier2AotCompiler.init(comp);
        const ok = aot.promoteBuiltin(unit_idx) catch return -1;
        return if (ok) 1 else 0;
    }
    return -1;
}

pub export fn urc_profile_dilation(c: ?*const UrCompiler, unit_idx: CellIdx) f64 {
    if (c) |comp| {
        return comp.profileDilation(unit_idx);
    }
    return 1.0;
}

pub export fn urasg_print_sexpr(g: ?*const UrGraph, root: CellIdx, buf: [*]u8, buf_cap: usize) usize {
    if (g) |graph| {
        const slice = buf[0..buf_cap];
        return sexpr_lens.printSexpr(graph, root, slice) catch 0;
    }
    return 0;
}

pub export fn urasg_parse_sexpr(g: ?*UrGraph, sexpr_utf8: [*]const u8, len: usize) CellIdx {
    if (g) |graph| {
        const slice = sexpr_utf8[0..len];
        return sexpr_lens.parseSexpr(graph, slice) catch NULL_CELL;
    }
    return NULL_CELL;
}

pub export fn urasg_save_binary(g: ?*const UrGraph, filepath: [*:0]const u8) c_int {
    if (g) |graph| {
        const path_slice = std.mem.span(filepath);
        binary_codec.saveBinaryToFile(graph, NULL_CELL, path_slice) catch return -1;
        return 0;
    }
    return -1;
}

pub export fn urasg_load_binary(filepath: [*:0]const u8) ?*UrGraph {
    const path_slice = std.mem.span(filepath);
    return binary_codec.loadBinaryFromFile(path_slice, std.heap.page_allocator) catch null;
}

// ============================================================================
// Comprehensive Cross-Project Reuse Blueprint Test Suite (Section 7)
// ============================================================================

test "Blueprint 1: Fluid Substrate v2.0 - Projectional Lens, Hazel Membranes & Autofree" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, compiler.core.FEAT_SAMPLE_ORACLE | compiler.core.FEAT_HAZEL_MEMBRANES | compiler.core.FEAT_AUTOFREE_ARENA | compiler.core.FEAT_LOBSTER_RC);
    defer comp.destroy();

    // 1. S-Expr parse of unit
    const src = "(unit fluid_step (let x 42) (return_ok x))";
    const unit_idx = try sexpr_lens.parseSexpr(graph, src);
    try std.testing.expect(unit_idx != NULL_CELL);

    // 2. Instrument with memory engine
    var mem_eng = compiler.mem.UrMemoryEngine.init(comp);
    defer mem_eng.deinit();
    try mem_eng.analyzeAndInstrumentUnit(unit_idx);

    // 3. Evaluate unit in Tier 0
    var t0 = compiler.tier0.Tier0Evaluator.init(comp);
    const result_idx = try t0.evalUnit(unit_idx, &.{});
    try std.testing.expectEqual(@as(i64, 42), graph.getCell(result_idx).payload.imm_i64);
}

test "Blueprint 2: EngageLang v3 - Fiber yield and JIT stencil compilation" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, compiler.core.DEFAULT_FEATURES);
    defer comp.destroy();

    const sym_fiber = try graph.internSym("fiber_worker");
    const int_c = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 100 } });
    const ret_c = try graph.allocCell(UrCell{ .kind = .return_ok });
    const s_ret = try graph.allocChildren(&.{int_c}, ret_c);
    var c_ret = graph.getCell(ret_c);
    c_ret.payload.slice = s_ret;
    try graph.mutateCell(ret_c, c_ret);

    const fiber_cell = try graph.allocCell(UrCell{ .kind = .fiber_yield });
    const unit_idx = try graph.allocCell(UrCell{ .kind = .unit_def, .head_idx = sym_fiber });
    const s_unit = try graph.allocChildren(&.{ fiber_cell, int_c, ret_c }, unit_idx);
    var c_unit = graph.getCell(unit_idx);
    c_unit.payload.slice = s_unit;
    try graph.mutateCell(unit_idx, c_unit);

    var jit = compiler.tier1.Tier1JitEngine.init(comp);
    var jit_mod = try jit.compileUnit(unit_idx);
    defer jit_mod.deinit();

    try std.testing.expect(jit_mod.instructions.items.len > 0);
    try std.testing.expect(jit_mod.machine_code.items.len > 0);

    const out_idx = try jit.execBytecode(&jit_mod, &.{});
    try std.testing.expectEqual(@as(i64, 100), graph.getCell(out_idx).payload.imm_i64);
}

test "Blueprint 3: AetherLang - Uncertain F32 and MMIO capability checks" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, compiler.core.FEAT_UNCERTAIN_AUTODIFF | compiler.core.FEAT_MMIO_CAPABILITIES);
    defer comp.destroy();

    // 1. Uncertain arithmetic
    const unc1 = try graph.allocCell(UrCell{
        .kind = .uncertain_f32,
        .payload = cell.UncertainF32.init(50.0, 2.0).toPayload(),
    });
    const unc2 = try graph.allocCell(UrCell{
        .kind = .uncertain_f32,
        .payload = cell.UncertainF32.init(10.0, 1.0).toPayload(),
    });
    const sym_add = try graph.internSym("add");
    const call_add = try graph.allocCell(UrCell{ .kind = .call_node, .head_idx = sym_add });
    const s_add = try graph.allocChildren(&.{ unc1, unc2 }, call_add);
    var c_add = graph.getCell(call_add);
    c_add.payload.slice = s_add;
    try graph.mutateCell(call_add, c_add);

    var t0 = compiler.tier0.Tier0Evaluator.init(comp);
    var env = compiler.ext.UrEvalEnv.init(allocator);
    defer env.deinit();
    const res_idx = try t0.evalCell(call_add, &env, NULL_CELL, &.{});
    const res_cell = graph.getCell(res_idx);
    try std.testing.expectEqual(UrKind.uncertain_f32, res_cell.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), res_cell.payload.uncertain.mean, 0.001);

    // 2. MMIO capability pass check
    const sym_driver = try graph.internSym("driver_init");
    const valid_cap = try graph.allocCell(UrCell{
        .kind = .mmio_capability,
        .payload = .{ .capability = .{ .base_addr = 0x4000, .byte_len = 0x1000 } },
    });
    const unit_driver = try graph.allocCell(UrCell{ .kind = .unit_def, .head_idx = sym_driver });
    const s_driver = try graph.allocChildren(&.{valid_cap}, unit_driver);
    var c_driver = graph.getCell(unit_driver);
    c_driver.payload.slice = s_driver;
    try graph.mutateCell(unit_driver, c_driver);

    try compiler.passes.runMmioCapabilityPass(comp, unit_driver);
}

test "Blueprint 4: RimPowder - Domain physics opcode (0x81 cell_fourier_heat) and SIMD" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, compiler.core.FEAT_RELATIONAL_SIMD);
    defer comp.destroy();

    const heat_opcode: u8 = 0x81;
    try comp.registerExtension(.{
        .ext_name = "rimpowder_physics",
        .opcode_range_start = heat_opcode,
        .opcode_range_end = heat_opcode,
        .eval_domain_cell = struct {
            fn eval(g: *UrGraph, idx: CellIdx, _: *compiler.ext.UrEvalEnv) lens_api.UrError!CellIdx {
                _ = idx;
                return g.allocCell(UrCell{
                    .kind = .float_lit,
                    .payload = .{ .imm_f64 = 37.5 },
                }) catch return error.OutOfMemory;
            }
        }.eval,
    });

    const heat_cell = try graph.allocCell(UrCell{
        .kind = @enumFromInt(heat_opcode),
    });

    var t0 = compiler.tier0.Tier0Evaluator.init(comp);
    var env = compiler.ext.UrEvalEnv.init(allocator);
    defer env.deinit();
    const eval_res = try t0.evalCell(heat_cell, &env, NULL_CELL, &.{});
    try std.testing.expectEqual(@as(f64, 37.5), graph.getCell(eval_res).payload.imm_f64);
}

test "Blueprint 5: OmniBench - Sample verification and PINNED_BUILTIN Merkle caching" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, compiler.core.FEAT_SAMPLE_ORACLE | compiler.core.FEAT_BEEF_MIXED_OPT);
    defer comp.destroy();

    const sym_latch = try graph.internSym("nand_latch");
    const in_c = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 1 } });
    const out_c = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 10 } });

    // Sample row: 1 => 10
    const sample_row = try graph.allocCell(UrCell{ .kind = .sample_io_row });
    const s_sample = try graph.allocChildren(&.{ in_c, out_c }, sample_row);
    var c_sample = graph.getCell(sample_row);
    c_sample.payload.slice = s_sample;
    try graph.mutateCell(sample_row, c_sample);

    const ret_c = try graph.allocCell(UrCell{ .kind = .return_ok });
    const s_ret = try graph.allocChildren(&.{out_c}, ret_c);
    var c_ret = graph.getCell(ret_c);
    c_ret.payload.slice = s_ret;
    try graph.mutateCell(ret_c, c_ret);

    const unit_latch = try graph.allocCell(UrCell{ .kind = .unit_def, .head_idx = sym_latch });
    const s_latch = try graph.allocChildren(&.{ sample_row, ret_c }, unit_latch);
    var c_latch = graph.getCell(unit_latch);
    c_latch.payload.slice = s_latch;
    try graph.mutateCell(unit_latch, c_latch);

    // Promote to builtin
    var aot = compiler.tier2.Tier2AotCompiler.init(comp);
    const promoted = try aot.promoteBuiltin(unit_latch);
    try std.testing.expect(promoted);

    const latch_after = graph.getCell(unit_latch);
    try std.testing.expect(latch_after.flags.verified);
    try std.testing.expect(latch_after.flags.pinned_builtin);
}

test "Blueprint 6: ThoughtGraph / CortexKG - Bi-temporal knowledge graph queries" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    const entity_concept: u32 = 500;
    const sym_relation = try graph.internSym("relates_to");

    const target1 = try graph.allocCell(UrCell{ .kind = .sym_atom, .head_idx = try graph.internSym("QuantumMechanics") });
    const target2 = try graph.allocCell(UrCell{ .kind = .sym_atom, .head_idx = try graph.internSym("GeneralRelativity") });

    // t=0 to t=100: relates to QuantumMechanics
    try graph.eav_index.commitBitemporal(entity_concept, sym_relation, target1, NULL_CELL, 0, 100);
    // t=100 onwards: relates to GeneralRelativity
    try graph.eav_index.commitBitemporal(entity_concept, sym_relation, target2, NULL_CELL, 100, 0);

    const hist1 = graph.eav_index.queryBitemporal(entity_concept, sym_relation, 50);
    const hist2 = graph.eav_index.queryBitemporal(entity_concept, sym_relation, 150);

    try std.testing.expectEqual(@as(?CellIdx, target1), hist1);
    try std.testing.expectEqual(@as(?CellIdx, target2), hist2);
}

test "C ABI functions roundtrip" {
    const g = urasg_create(1024);
    try std.testing.expect(g != null);
    defer urasg_destroy(g);

    const sym_id = urasg_intern_sym(g, "speed", 5);
    try std.testing.expect(sym_id != 0);

    const c1 = urasg_alloc_cell(g, UrCell{
        .kind = .int_lit,
        .payload = .{ .imm_i64 = 42 },
    });
    try std.testing.expect(c1 != NULL_CELL);

    const read_cell = urasg_get_cell(g, c1);
    try std.testing.expectEqual(@as(i64, 42), read_cell.payload.imm_i64);

    urasg_commit_eav(g, 10, sym_id, c1);
    const queried = urasg_query_eav(g, 10, sym_id);
    try std.testing.expectEqual(c1, queried);

    const hash = urasg_merkle_hash(g, c1);
    try std.testing.expect(hash != 0);
}
