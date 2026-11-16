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
const ext_mod = @import("ext_api.zig");
const tier0_mod = @import("tier0_eval.zig");
const Tier0Evaluator = tier0_mod.Tier0Evaluator;

pub const Tier2AotCompiler = struct {
    compiler: *UrCompiler,

    pub fn init(compiler: *UrCompiler) Tier2AotCompiler {
        return .{ .compiler = compiler };
    }

    pub fn typeIdToZig(graph: *const UrGraph, tid: cell_mod.TypeId) []const u8 {
        return switch (tid) {
            BuiltinType.void_type => "void",
            BuiltinType.bool_type => "bool",
            BuiltinType.int_type => "i64",
            BuiltinType.float_type => "f64",
            BuiltinType.fixed_q16_16_type => "i32",
            BuiltinType.uncertain_f32_type => "UncertainF32",
            BuiltinType.string_type, BuiltinType.bytes_type => "[]const u8",
            else => blk: {
                if (graph.type_table.getType(tid)) |entry| {
                    break :blk switch (entry.kind) {
                        .ptr => "*anyopaque",
                        .slice => "[]const u8",
                        .uncertain => "UncertainF32",
                        else => "i64",
                    };
                }
                break :blk "i64";
            },
        };
    }

    pub fn typeIdToC99(graph: *const UrGraph, tid: cell_mod.TypeId) []const u8 {
        return switch (tid) {
            BuiltinType.void_type => "void",
            BuiltinType.bool_type => "bool",
            BuiltinType.int_type => "int64_t",
            BuiltinType.float_type => "double",
            BuiltinType.fixed_q16_16_type => "int32_t",
            BuiltinType.string_type, BuiltinType.bytes_type => "const char*",
            else => blk: {
                if (graph.type_table.getType(tid)) |entry| {
                    break :blk switch (entry.kind) {
                        .ptr => "void*",
                        .slice => "const char*",
                        else => "int64_t",
                    };
                }
                break :blk "int64_t";
            },
        };
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

    const TargetLang = enum { zig, c99 };

    fn collectFreeParams(
        graph: *const UrGraph,
        idx: CellIdx,
        bound: *std.AutoHashMapUnmanaged(SymId, void),
        params: *std.ArrayListUnmanaged(SymId),
        allocator: std.mem.Allocator,
    ) !void {
        if (idx == NULL_CELL) return;
        const cell = graph.getCell(idx);
        switch (cell.kind) {
            .sym_atom => {
                if (!bound.contains(cell.head_idx)) {
                    for (params.items) |p| {
                        if (p == cell.head_idx) return;
                    }
                    try params.append(allocator, cell.head_idx);
                }
            },
            .let_bind => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (ch) |c| try collectFreeParams(graph, c, bound, params, allocator);
                try bound.put(allocator, cell.head_idx, {});
            },
            .nil_cell, .bool_lit, .int_lit, .float_lit, .fixed_q16_16, .uncertain_f32, .bytes_blob, .cyclic_backref, .sample_io_row => {},
            else => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (ch) |c| try collectFreeParams(graph, c, bound, params, allocator);
            },
        }
    }

    fn inferReturnType(graph: *const UrGraph, unit_cell: UrCell) cell_mod.TypeId {
        if (unit_cell.type_id != BuiltinType.any_type and unit_cell.type_id != BuiltinType.hole_type) {
            return unit_cell.type_id;
        }
        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |child_idx| {
            const c = graph.getCell(child_idx);
            if (c.kind == .return_ok) {
                const rc = graph.getChildren(c.payload.slice.start, c.payload.slice.len);
                if (rc.len > 0) {
                    const ret_tid = graph.getCell(rc[0]).type_id;
                    if (ret_tid != BuiltinType.any_type and ret_tid != BuiltinType.hole_type and ret_tid != BuiltinType.sym_type) {
                        return ret_tid;
                    }
                }
            }
        }
        return BuiltinType.int_type;
    }

    fn mapBinOp(fn_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, fn_name, "add") or std.mem.eql(u8, fn_name, "+")) return "+";
        if (std.mem.eql(u8, fn_name, "sub") or std.mem.eql(u8, fn_name, "-")) return "-";
        if (std.mem.eql(u8, fn_name, "mul") or std.mem.eql(u8, fn_name, "*")) return "*";
        if (std.mem.eql(u8, fn_name, "div") or std.mem.eql(u8, fn_name, "/")) return "/";
        if (std.mem.eql(u8, fn_name, "gt") or std.mem.eql(u8, fn_name, ">")) return ">";
        if (std.mem.eql(u8, fn_name, "lt") or std.mem.eql(u8, fn_name, "<")) return "<";
        if (std.mem.eql(u8, fn_name, "eq") or std.mem.eql(u8, fn_name, "==")) return "==";
        return null;
    }

    fn emitExpr(self: *Tier2AotCompiler, lang: TargetLang, idx: CellIdx, writer: anytype) anyerror!void {
        const graph = self.compiler.graph;
        if (idx == NULL_CELL) {
            try writer.writeAll("0");
            return;
        }
        const cell = graph.getCell(idx);

        if (@intFromEnum(cell.kind) >= 0x80) {
            if (self.compiler.findExtension(@intFromEnum(cell.kind))) |ext| {
                if (ext.emit_domain_codegen) |emit_fn| {
                    var builder = ext_mod.UrCodegenBuilder.init(self.compiler.allocator);
                    defer builder.deinit();
                    try emit_fn(graph, idx, &builder);
                    try writer.writeAll(builder.out.items);
                    return;
                }
            }
        }

        switch (cell.kind) {
            .int_lit => try writer.print("{d}", .{cell.payload.imm_i64}),
            .float_lit => try writer.print("{d}", .{cell.payload.imm_f64}),
            .bool_lit => try writer.writeAll(if (cell.payload.raw != 0) "true" else "false"),
            .fixed_q16_16 => try writer.print("{d}", .{@as(i32, @truncate(cell.payload.imm_i64))}),
            .uncertain_f32 => {
                if (lang == .zig) {
                    try writer.print("UncertainF32.init({d}, {d})", .{ cell.payload.uncertain.mean, cell.payload.uncertain.std_dev });
                } else {
                    try writer.print("{d}", .{cell.payload.uncertain.mean});
                }
            },
            .sym_atom => try writer.writeAll(graph.getSym(cell.head_idx)),
            .bytes_blob => {
                const s = graph.getBlob(@truncate(cell.payload.raw >> 32), @truncate(cell.payload.raw));
                try writer.print("\"{s}\"", .{s});
            },
            .hazel_membrane => try self.emitExpr(lang, cell.payload.membrane.inner_cell, writer),
            .if_branch => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len >= 3) {
                    if (lang == .zig) {
                        try writer.writeAll("if (");
                        try self.emitCondExpr(lang, ch[0], writer);
                        try writer.writeAll(") ");
                        try self.emitExpr(lang, ch[1], writer);
                        try writer.writeAll(" else ");
                        try self.emitExpr(lang, ch[2], writer);
                    } else {
                        try writer.writeAll("(");
                        try self.emitCondExpr(lang, ch[0], writer);
                        try writer.writeAll(" ? ");
                        try self.emitExpr(lang, ch[1], writer);
                        try writer.writeAll(" : ");
                        try self.emitExpr(lang, ch[2], writer);
                        try writer.writeAll(")");
                    }
                } else {
                    try writer.writeAll("0");
                }
            },
            .call_node => {
                const fn_name = graph.getSym(cell.head_idx);
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (mapBinOp(fn_name)) |op| {
                    if (ch.len >= 2) {
                        const c1 = graph.getCell(ch[0]);
                        const c2 = graph.getCell(ch[1]);
                        if (lang == .zig and c1.kind == .uncertain_f32 and c2.kind == .uncertain_f32) {
                            const method = if (std.mem.eql(u8, op, "+")) "add" else if (std.mem.eql(u8, op, "-")) "sub" else if (std.mem.eql(u8, op, "*")) "mul" else "div";
                            try writer.print("UncertainF32.{s}(", .{method});
                            try self.emitExpr(lang, ch[0], writer);
                            try writer.writeAll(", ");
                            try self.emitExpr(lang, ch[1], writer);
                            try writer.writeAll(")");
                            return;
                        }
                        if (lang == .zig and std.mem.eql(u8, op, "/") and c1.kind != .float_lit and c2.kind != .float_lit) {
                            try writer.writeAll("@divTrunc(");
                            try self.emitExpr(lang, ch[0], writer);
                            try writer.writeAll(", ");
                            try self.emitExpr(lang, ch[1], writer);
                            try writer.writeAll(")");
                            return;
                        }
                        try writer.writeAll("(");
                        try self.emitExpr(lang, ch[0], writer);
                        try writer.print(" {s} ", .{op});
                        try self.emitExpr(lang, ch[1], writer);
                        try writer.writeAll(")");
                        return;
                    }
                }
                try writer.print("{s}(", .{fn_name});
                for (ch, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.emitExpr(lang, arg, writer);
                }
                try writer.writeAll(")");
            },
            else => try writer.writeAll("0"),
        }
    }

    fn emitCondExpr(self: *Tier2AotCompiler, lang: TargetLang, idx: CellIdx, writer: anytype) anyerror!void {
        const graph = self.compiler.graph;
        const c = graph.getCell(idx);
        if (c.kind == .bool_lit) {
            try self.emitExpr(lang, idx, writer);
            return;
        }
        if (c.kind == .call_node) {
            const fn_name = graph.getSym(c.head_idx);
            if (std.mem.eql(u8, fn_name, ">") or std.mem.eql(u8, fn_name, "gt") or
                std.mem.eql(u8, fn_name, "<") or std.mem.eql(u8, fn_name, "lt") or
                std.mem.eql(u8, fn_name, "==") or std.mem.eql(u8, fn_name, "eq"))
            {
                try self.emitExpr(lang, idx, writer);
                return;
            }
        }
        try writer.writeAll("(");
        try self.emitExpr(lang, idx, writer);
        try writer.writeAll(" != 0)");
    }

    fn emitStmt(self: *Tier2AotCompiler, lang: TargetLang, idx: CellIdx, writer: anytype, indent: usize) anyerror!void {
        const graph = self.compiler.graph;
        const cell = graph.getCell(idx);

        if (cell.kind == .sample_io_row or cell.kind == .needs_stub) return;

        var i: usize = 0;
        while (i < indent) : (i += 1) try writer.writeAll("    ");

        switch (cell.kind) {
            .let_bind => {
                const name = graph.getSym(cell.head_idx);
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (lang == .zig) {
                    try writer.print("const {s} = ", .{name});
                    if (ch.len > 0) try self.emitExpr(lang, ch[0], writer) else try writer.writeAll("0");
                    try writer.print(";\n", .{});
                    var j: usize = 0;
                    while (j < indent) : (j += 1) try writer.writeAll("    ");
                    try writer.print("_ = &{s};\n", .{name});
                } else {
                    const c_ty = typeIdToC99(graph, cell.type_id);
                    try writer.print("{s} {s} = ", .{ c_ty, name });
                    if (ch.len > 0) try self.emitExpr(lang, ch[0], writer) else try writer.writeAll("0");
                    try writer.writeAll(";\n");
                }
            },
            .if_branch => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len >= 3) {
                    try writer.writeAll("if (");
                    try self.emitCondExpr(lang, ch[0], writer);
                    try writer.writeAll(") {\n");
                    try self.emitStmt(lang, ch[1], writer, indent + 1);
                    var j: usize = 0;
                    while (j < indent) : (j += 1) try writer.writeAll("    ");
                    try writer.writeAll("} else {\n");
                    try self.emitStmt(lang, ch[2], writer, indent + 1);
                    j = 0;
                    while (j < indent) : (j += 1) try writer.writeAll("    ");
                    try writer.writeAll("}\n");
                }
            },
            .loop_repeat => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len >= 2) {
                    try writer.writeAll("while (");
                    try self.emitCondExpr(lang, ch[0], writer);
                    try writer.writeAll(") {\n");
                    for (ch[1..]) |body| {
                        try self.emitStmt(lang, body, writer, indent + 1);
                    }
                    var j: usize = 0;
                    while (j < indent) : (j += 1) try writer.writeAll("    ");
                    try writer.writeAll("}\n");
                }
            },
            .return_ok => {
                const ch = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                try writer.writeAll("return ");
                if (ch.len > 0) try self.emitExpr(lang, ch[0], writer) else try writer.writeAll("arg0");
                try writer.writeAll(";\n");
            },
            .scope_free => {
                try writer.print("// scope_free cell {d}\n", .{cell.head_idx});
            },
            .rc_adjust, .arena_promote, .gen_guard_check, .borrow_ref => {
                try writer.print("// mem_op 0x{X:0>2} cell {d}\n", .{ @intFromEnum(cell.kind), cell.head_idx });
            },
            else => {
                if (@intFromEnum(cell.kind) >= 0x80) {
                    try self.emitExpr(lang, idx, writer);
                    try writer.writeAll(";\n");
                } else {
                    try writer.writeAll("_ = ");
                    try self.emitExpr(lang, idx, writer);
                    try writer.writeAll(";\n");
                }
            },
        }
    }

    pub fn emitZigSource(self: *Tier2AotCompiler, unit_idx: CellIdx, writer: anytype) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const unit_name = graph.getSym(unit_cell.head_idx);

        var bound: std.AutoHashMapUnmanaged(SymId, void) = .empty;
        defer bound.deinit(self.compiler.allocator);
        var params: std.ArrayListUnmanaged(SymId) = .empty;
        defer params.deinit(self.compiler.allocator);

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |ch| {
            try collectFreeParams(graph, ch, &bound, &params, self.compiler.allocator);
        }

        const ret_zig = typeIdToZig(graph, inferReturnType(graph, unit_cell));

        try writer.print(
            \\// Generated freestanding Zig 0.17.0 from UR-ASG
            \\const std = @import("std");
            \\
            \\pub export fn ur_fn_{s}(
        , .{unit_name});

        if (params.items.len == 0) {
            try writer.writeAll("arg0: i64");
        } else {
            for (params.items, 0..) |p_sym, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}: i64", .{graph.getSym(p_sym)});
            }
        }
        try writer.print(") {s} {{\n", .{ret_zig});
        if (params.items.len == 0) {
            try writer.writeAll("    _ = &arg0;\n");
        }

        for (children) |child_idx| {
            try self.emitStmt(.zig, child_idx, writer, 1);
        }

        try writer.print("}}\n", .{});
    }

    pub fn emitC99Source(self: *Tier2AotCompiler, unit_idx: CellIdx, writer: anytype) !void {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        const unit_name = graph.getSym(unit_cell.head_idx);

        var bound: std.AutoHashMapUnmanaged(SymId, void) = .empty;
        defer bound.deinit(self.compiler.allocator);
        var params: std.ArrayListUnmanaged(SymId) = .empty;
        defer params.deinit(self.compiler.allocator);

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |ch| {
            try collectFreeParams(graph, ch, &bound, &params, self.compiler.allocator);
        }

        const ret_c = typeIdToC99(graph, inferReturnType(graph, unit_cell));

        try writer.print(
            \\/* Generated C99 from UR-ASG */
            \\#include <stdint.h>
            \\#include <stdbool.h>
            \\
            \\{s} ur_fn_{s}(
        , .{ ret_c, unit_name });

        if (params.items.len == 0) {
            try writer.writeAll("int64_t arg0");
        } else {
            for (params.items, 0..) |p_sym, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("int64_t {s}", .{graph.getSym(p_sym)});
            }
        }
        try writer.writeAll(") {\n");
        if (params.items.len == 0) {
            try writer.writeAll("    (void)arg0;\n");
        }

        for (children) |child_idx| {
            try self.emitStmt(.c99, child_idx, writer, 1);
        }

        try writer.writeAll("}\n");
    }
};

const TestStringWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *TestStringWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn writeAll(self: *TestStringWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *TestStringWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.buf.appendSlice(self.allocator, formatted);
    }
};

test "Tier2AotCompiler recursive Zig & C99 emission and domain codegen hook" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, urc_mod.DEFAULT_FEATURES);
    defer comp.destroy();

    const src = "(unit gain (let scaled (call * x 3)) (if (call > scaled 10) (return_ok (call + scaled 1)) (return_ok scaled)))";
    const unit_idx = try sexpr_lens.parseSexpr(graph, src);

    var aot = Tier2AotCompiler.init(comp);

    var zig_buf = TestStringWriter{ .allocator = allocator };
    defer zig_buf.deinit();
    try aot.emitZigSource(unit_idx, &zig_buf);
    try std.testing.expect(std.mem.indexOf(u8, zig_buf.buf.items, "pub export fn ur_fn_gain(x: i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_buf.buf.items, "const scaled = (x * 3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_buf.buf.items, "return (scaled + 1);") != null);

    var c_buf = TestStringWriter{ .allocator = allocator };
    defer c_buf.deinit();
    try aot.emitC99Source(unit_idx, &c_buf);
    try std.testing.expect(std.mem.indexOf(u8, c_buf.buf.items, "int64_t ur_fn_gain(int64_t x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_buf.buf.items, "int64_t scaled = (x * 3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_buf.buf.items, "return (scaled + 1);") != null);

    // Verify ext.emit_domain_codegen integration
    const dom_op: u8 = 0x82;
    try comp.registerExtension(.{
        .ext_name = "ai_ops",
        .opcode_range_start = dom_op,
        .opcode_range_end = dom_op,
        .emit_domain_codegen = struct {
            fn emit(_: *const UrGraph, _: CellIdx, out: *ext_mod.UrCodegenBuilder) UrError!void {
                out.write("tensor_relu_kernel()") catch return error.OutOfMemory;
            }
        }.emit,
    });
    const dom_c = try graph.allocCell(.{ .kind = @enumFromInt(dom_op) });
    const dom_u = try graph.allocCell(.{ .kind = .unit_def, .head_idx = try graph.internSym("run_ai") });
    var du = graph.getCell(dom_u);
    du.payload.slice = try graph.allocChildren(&.{dom_c}, dom_u);
    try graph.mutateCell(dom_u, du);

    var dom_zig = TestStringWriter{ .allocator = allocator };
    defer dom_zig.deinit();
    try aot.emitZigSource(dom_u, &dom_zig);
    try std.testing.expect(std.mem.indexOf(u8, dom_zig.buf.items, "tensor_relu_kernel();") != null);
}

