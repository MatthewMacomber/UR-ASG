const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;
const tier0_mod = @import("tier0_eval.zig");
const Tier0Evaluator = tier0_mod.Tier0Evaluator;

pub const Tier2AotCompiler = struct {
    compiler: *UrCompiler,

    pub fn init(compiler: *UrCompiler) Tier2AotCompiler {
        return .{ .compiler = compiler };
    }

    pub fn promoteBuiltin(self: *Tier2AotCompiler, unit_idx: CellIdx) UrError!bool {
        const graph = self.compiler.graph;
        var unit_cell = graph.getCell(unit_idx);
        if (unit_cell.kind != .unit_def) return false;

        // 1. Verify against all sample_io_row contracts
        var t0 = Tier0Evaluator.init(self.compiler);
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        var tested_samples: usize = 0;

        for (children) |child_idx| {
            const child = graph.getCell(child_idx);
            if (child.kind == .sample_io_row) {
                const sample_children = graph.getChildren(child.payload.slice.start, child.payload.slice.len);
                if (sample_children.len >= 2) {
                    const in_cell_idx = sample_children[0];
                    const expected_out_idx = sample_children[1];

                    const actual_out_idx = try t0.evalUnit(unit_idx, &.{in_cell_idx});
                    const actual_cell = graph.getCell(actual_out_idx);
                    const expected_cell = graph.getCell(expected_out_idx);

                    if (actual_cell.kind != expected_cell.kind or actual_cell.payload.raw != expected_cell.payload.raw) {
                        return false; // Contract failure
                    }
                    tested_samples += 1;
                }
            }
        }

        // 2. Set VERIFIED flag and compute canonical XXH3-64 Merkle hash
        unit_cell.flags.verified = true;
        try graph.mutateCell(unit_idx, unit_cell);

        const merkle_hash = try graph.merkleHash(unit_idx);

        // 3. Register in Pinned Builtin Cache
        self.compiler.pinned_builtins.put(self.compiler.allocator, merkle_hash, .{
            .merkle_hash = merkle_hash,
            .native_fn_ptr = null,
            .tier = 2,
        }) catch return error.OutOfMemory;

        // 4. Mark cell PINNED_BUILTIN
        unit_cell.flags.pinned_builtin = true;
        try graph.mutateCell(unit_idx, unit_cell);

        return true;
    }

    pub fn emitZigSource(self: *Tier2AotCompiler, unit_idx: CellIdx, writer: anytype) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const unit_name = graph.getSym(unit_cell.head_idx);

        try writer.print(
            \\// Generated freestanding Zig 0.17.0 from UR-ASG
            \\const std = @import("std");
            \\
            \\pub export fn ur_fn_{s}(arg0: i64) i64 {{
            \\
        , .{unit_name});

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |child_idx| {
            const child = graph.getCell(child_idx);
            if (child.kind == .return_ok) {
                const ret_children = graph.getChildren(child.payload.slice.start, child.payload.slice.len);
                if (ret_children.len > 0) {
                    const ret_cell = graph.getCell(ret_children[0]);
                    if (ret_cell.kind == .int_lit) {
                        try writer.print("    return {d};\n", .{ret_cell.payload.imm_i64});
                    } else {
                        try writer.print("    return arg0;\n", .{});
                    }
                }
            }
        }

        try writer.print("}}\n", .{});
    }

    pub fn emitC99Source(self: *Tier2AotCompiler, unit_idx: CellIdx, writer: anytype) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const unit_name = graph.getSym(unit_cell.head_idx);

        try writer.print(
            \\/* Generated C99 from UR-ASG */
            \\#include <stdint.h>
            \\
            \\int64_t ur_fn_{s}(int64_t arg0) {{
            \\    return arg0;
            \\}}
            \\
        , .{unit_name});
    }
};

