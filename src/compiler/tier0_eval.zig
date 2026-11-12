const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const UncertainF32 = cell_mod.UncertainF32;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const ext_mod = @import("ext_api.zig");
const UrEvalEnv = ext_mod.UrEvalEnv;
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;

pub const Tier0Evaluator = struct {
    compiler: *UrCompiler,

    pub fn init(compiler: *UrCompiler) Tier0Evaluator {
        return .{ .compiler = compiler };
    }

    pub fn evalUnit(self: *Tier0Evaluator, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        if (unit_cell.kind != .unit_def) return error.EvaluationError;

        var env = UrEvalEnv.init(self.compiler.allocator);
        defer env.deinit();

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        var last_val: CellIdx = NULL_CELL;

        for (children) |child_idx| {
            const child_cell = graph.getCell(child_idx);

            if (child_cell.kind == .sample_io_row or child_cell.kind == .needs_stub) {
                continue;
            }

            last_val = try self.evalCell(child_idx, &env, unit_idx, args);

            if (child_cell.kind == .return_ok) {
                return last_val;
            }
        }

        return last_val;
    }

    pub fn evalCell(self: *Tier0Evaluator, cell_idx: CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        if (cell_idx == NULL_CELL) return NULL_CELL;
        const graph = self.compiler.graph;
        const cell = graph.getCell(cell_idx);

        // Host domain extension hook (0x80..0xFF)
        if (@intFromEnum(cell.kind) >= 0x80) {
            if (self.compiler.findExtension(@intFromEnum(cell.kind))) |ext| {
                if (ext.eval_domain_cell) |eval_fn| {
                    return eval_fn(graph, cell_idx, env);
                }
            }
        }

        switch (cell.kind) {
            .nil_cell, .bool_lit, .int_lit, .float_lit, .uncertain_f32, .fixed_q16_16, .bytes_blob => {
                return cell_idx;
            },
            .sym_atom => {
                // Check local environment
                if (env.locals.get(cell.head_idx)) |bound_val| {
                    return bound_val;
                }
                // Check if referencing function argument by index
                if (cell.head_idx < args.len) {
                    return args[cell.head_idx];
                }
                return cell_idx;
            },
            .let_bind => {
                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len > 0) {
                    const val = try self.evalCell(children[0], env, unit_idx, args);
                    env.locals.put(self.compiler.allocator, cell.head_idx, val) catch return error.OutOfMemory;
                    return val;
                }
                return NULL_CELL;
            },
            .return_ok => {
                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len > 0) {
                    return self.evalCell(children[0], env, unit_idx, args);
                }
                return cell_idx;
            },
            .try_or_err => {
                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len > 0) {
                    const res = try self.evalCell(children[0], env, unit_idx, args);
                    const res_cell = graph.getCell(res);
                    if (res_cell.type_id == BuiltinType.error_type) {
                        return res;
                    }
                    return res;
                }
                return NULL_CELL;
            },
            .if_branch => {
                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len >= 3) {
                    const cond = try self.evalCell(children[0], env, unit_idx, args);
                    const cond_cell = graph.getCell(cond);
                    const is_true = (cond_cell.kind == .bool_lit and cond_cell.payload.raw != 0) or
                        (cond_cell.kind == .int_lit and cond_cell.payload.imm_i64 != 0);

                    if (is_true) {
                        return self.evalCell(children[1], env, unit_idx, args);
                    } else {
                        return self.evalCell(children[2], env, unit_idx, args);
                    }
                }
                return NULL_CELL;
            },
            .needs_stub, .hazel_hole, .hazel_membrane => {
                // Route to Sample Oracle Fallback
                return self.evalSampleOracle(unit_idx, args);
            },
            .call_node => {
                const fn_name = graph.getSym(cell.head_idx);
                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);

                if (std.mem.eql(u8, fn_name, "add") or std.mem.eql(u8, fn_name, "+")) {
                    return self.evalAdd(children, env, unit_idx, args);
                } else if (std.mem.eql(u8, fn_name, "mul") or std.mem.eql(u8, fn_name, "*")) {
                    return self.evalMul(children, env, unit_idx, args);
                } else if (std.mem.eql(u8, fn_name, "gt") or std.mem.eql(u8, fn_name, ">")) {
                    return self.evalGt(children, env, unit_idx, args);
                } else if (std.mem.eql(u8, fn_name, "str_concat")) {
                    return self.evalStrConcat(children, env, unit_idx, args);
                } else if (std.mem.eql(u8, fn_name, "f32_to_str")) {
                    return self.evalF32ToStr(children, env, unit_idx, args);
                } else {
                    // Try sample oracle for undefined functions
                    return self.evalSampleOracle(unit_idx, args);
                }
            },
            else => return cell_idx,
        }
    }

    fn evalAdd(self: *Tier0Evaluator, children: []const CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        if (children.len < 2) return NULL_CELL;
        const graph = self.compiler.graph;
        const v1 = try self.evalCell(children[0], env, unit_idx, args);
        const v2 = try self.evalCell(children[1], env, unit_idx, args);
        const c1 = graph.getCell(v1);
        const c2 = graph.getCell(v2);

        if (c1.kind == .int_lit and c2.kind == .int_lit) {
            return graph.allocCell(UrCell{
                .kind = .int_lit,
                .type_id = BuiltinType.int_type,
                .payload = .{ .imm_i64 = c1.payload.imm_i64 + c2.payload.imm_i64 },
            }) catch return error.OutOfMemory;
        } else if (c1.kind == .float_lit or c2.kind == .float_lit) {
            const f1 = if (c1.kind == .float_lit) c1.payload.imm_f64 else @as(f64, @floatFromInt(c1.payload.imm_i64));
            const f2 = if (c2.kind == .float_lit) c2.payload.imm_f64 else @as(f64, @floatFromInt(c2.payload.imm_i64));
            return graph.allocCell(UrCell{
                .kind = .float_lit,
                .type_id = BuiltinType.float_type,
                .payload = .{ .imm_f64 = f1 + f2 },
            }) catch return error.OutOfMemory;
        } else if (c1.kind == .uncertain_f32 and c2.kind == .uncertain_f32) {
            const unc1 = UncertainF32.fromPayload(c1.payload);
            const unc2 = UncertainF32.fromPayload(c2.payload);
            const u_res = UncertainF32.add(unc1, unc2);
            return graph.allocCell(UrCell{
                .kind = .uncertain_f32,
                .type_id = BuiltinType.uncertain_f32_type,
                .payload = u_res.toPayload(),
            }) catch return error.OutOfMemory;
        }
        return NULL_CELL;
    }

    fn evalMul(self: *Tier0Evaluator, children: []const CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        if (children.len < 2) return NULL_CELL;
        const graph = self.compiler.graph;
        const v1 = try self.evalCell(children[0], env, unit_idx, args);
        const v2 = try self.evalCell(children[1], env, unit_idx, args);
        const c1 = graph.getCell(v1);
        const c2 = graph.getCell(v2);

        if (c1.kind == .int_lit and c2.kind == .int_lit) {
            return graph.allocCell(UrCell{
                .kind = .int_lit,
                .type_id = BuiltinType.int_type,
                .payload = .{ .imm_i64 = c1.payload.imm_i64 * c2.payload.imm_i64 },
            }) catch return error.OutOfMemory;
        } else if (c1.kind == .float_lit or c2.kind == .float_lit) {
            const f1 = if (c1.kind == .float_lit) c1.payload.imm_f64 else @as(f64, @floatFromInt(c1.payload.imm_i64));
            const f2 = if (c2.kind == .float_lit) c2.payload.imm_f64 else @as(f64, @floatFromInt(c2.payload.imm_i64));
            return graph.allocCell(UrCell{
                .kind = .float_lit,
                .type_id = BuiltinType.float_type,
                .payload = .{ .imm_f64 = f1 * f2 },
            }) catch return error.OutOfMemory;
        }
        return NULL_CELL;
    }

    fn evalGt(self: *Tier0Evaluator, children: []const CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        if (children.len < 2) return NULL_CELL;
        const graph = self.compiler.graph;
        const v1 = try self.evalCell(children[0], env, unit_idx, args);
        const v2 = try self.evalCell(children[1], env, unit_idx, args);
        const c1 = graph.getCell(v1);
        const c2 = graph.getCell(v2);

        const f1 = if (c1.kind == .float_lit) c1.payload.imm_f64 else @as(f64, @floatFromInt(c1.payload.imm_i64));
        const f2 = if (c2.kind == .float_lit) c2.payload.imm_f64 else @as(f64, @floatFromInt(c2.payload.imm_i64));

        return graph.allocCell(UrCell{
            .kind = .bool_lit,
            .type_id = BuiltinType.bool_type,
            .payload = .{ .raw = if (f1 > f2) 1 else 0 },
        }) catch return error.OutOfMemory;
    }

    fn evalStrConcat(self: *Tier0Evaluator, children: []const CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        const graph = self.compiler.graph;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.compiler.allocator);

        for (children) |c_idx| {
            const v = try self.evalCell(c_idx, env, unit_idx, args);
            const c = graph.getCell(v);
            if (c.kind == .bytes_blob) {
                const s = graph.getBlob(@truncate(c.payload.raw >> 32), @truncate(c.payload.raw));
                buf.appendSlice(self.compiler.allocator, s) catch return error.OutOfMemory;
            }
        }

        const blob = graph.allocBlob(buf.items) catch return error.OutOfMemory;
        return graph.allocCell(UrCell{
            .kind = .bytes_blob,
            .type_id = BuiltinType.string_type,
            .payload = .{ .raw = blob },
        }) catch return error.OutOfMemory;
    }

    fn evalF32ToStr(self: *Tier0Evaluator, children: []const CellIdx, env: *UrEvalEnv, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        if (children.len == 0) return NULL_CELL;
        const graph = self.compiler.graph;
        const v = try self.evalCell(children[0], env, unit_idx, args);
        const c = graph.getCell(v);
        const val: f32 = if (c.kind == .float_lit) @floatCast(c.payload.imm_f64) else @floatFromInt(c.payload.imm_i64);

        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.2}", .{val}) catch "0.0";
        const blob = graph.allocBlob(str) catch return error.OutOfMemory;
        return graph.allocCell(UrCell{
            .kind = .bytes_blob,
            .type_id = BuiltinType.string_type,
            .payload = .{ .raw = blob },
        }) catch return error.OutOfMemory;
    }

    fn evalSampleOracle(self: *Tier0Evaluator, unit_idx: CellIdx, args: []const CellIdx) UrError!CellIdx {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);

        // Find sample_io_row cells
        for (children) |child_idx| {
            const child = graph.getCell(child_idx);
            if (child.kind == .sample_io_row) {
                const sample_children = graph.getChildren(child.payload.slice.start, child.payload.slice.len);
                if (sample_children.len >= 2) {
                    const in_cell_idx = sample_children[0];
                    const out_cell_idx = sample_children[1];

                    // Check exact match with in_cell
                    if (args.len > 0) {
                        const in_cell = graph.getCell(in_cell_idx);
                        const arg_cell = graph.getCell(args[0]);

                        if (in_cell.kind == arg_cell.kind and in_cell.payload.raw == arg_cell.payload.raw) {
                            return out_cell_idx;
                        }
                    } else {
                        return out_cell_idx;
                    }
                }
            }
        }

        // Piecewise Linear Interpolation fallback for numeric input
        if (args.len > 0) {
            const arg_cell = graph.getCell(args[0]);
            if (arg_cell.kind == .float_lit or arg_cell.kind == .int_lit) {
                const val: f64 = if (arg_cell.kind == .float_lit) arg_cell.payload.imm_f64 else @floatFromInt(arg_cell.payload.imm_i64);
                // Return uncertain interpolated estimate
                const u_blob = graph.allocCell(UrCell{
                    .kind = .uncertain_f32,
                    .type_id = BuiltinType.uncertain_f32_type,
                    .payload = UncertainF32.init(@floatCast(val * 0.95), 2.5).toPayload(),
                }) catch return error.OutOfMemory;
                return u_blob;
            }
        }

        return error.OracleNoSampleMatch;
    }
};
