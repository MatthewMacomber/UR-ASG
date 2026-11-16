const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const graph_mod = @import("graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("lens_api.zig");
const UrError = lens_mod.UrError;
const UrTokenStream = lens_mod.UrTokenStream;
const UrLensVTable = lens_mod.UrLensVTable;
const TypeDiff = lens_mod.TypeDiff;
const sexpr_lens = @import("sexpr_lens.zig");
const SexprLens = sexpr_lens.SexprLens;

/// Projectional Sweet-Syntax Lens ported from Aether src/sweet.zig.
/// Provides human-friendly brace/infix syntax over canonical UR-ASG graphs.
pub const SweetLens = struct {
    pub const vtable: UrLensVTable = .{
        .dialect_name = "urasg_sweet",
        .project_to_surface = projectToSurface,
        .parse_into_graph = parseIntoGraph,
        .compute_type_diff = computeTypeDiff,
        .lower_subgraph = null,
    };

    pub fn projectToSurface(graph: *const UrGraph, root: CellIdx, out: *UrTokenStream) UrError!void {
        var printer = SweetPrinter{ .graph = graph, .out = out };
        defer printer.deinit();
        try printer.printCell(root, 0, true);
    }

    pub fn parseIntoGraph(graph: *UrGraph, target: CellIdx, src: []const u8) UrError!CellIdx {
        const canonical = toCanonical(graph.allocator, src) catch return error.OutOfMemory;
        defer graph.allocator.free(canonical);
        return SexprLens.parseIntoGraph(graph, target, canonical);
    }

    pub fn computeTypeDiff(graph: *const UrGraph, hole_idx: CellIdx, plug_idx: CellIdx) TypeDiff {
        return SexprLens.computeTypeDiff(graph, hole_idx, plug_idx);
    }
};

const BlockKind = enum { unit_block, if_then, if_else };

pub fn toCanonical(allocator: std.mem.Allocator, sweet: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var stack: std.ArrayListUnmanaged(BlockKind) = .empty;
    defer stack.deinit(allocator);

    var lines = std.mem.splitScalar(u8, sweet, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "#")) {
            continue;
        }

        if (std.mem.eql(u8, line, "} else {") or std.mem.eql(u8, line, "else {")) {
            if (stack.items.len > 0 and stack.items[stack.items.len - 1] == .if_then) {
                stack.items[stack.items.len - 1] = .if_else;
            }
            continue;
        }

        if (std.mem.eql(u8, line, "}")) {
            if (stack.items.len > 0) _ = stack.pop();
            try out.appendSlice(allocator, ")\n");
            continue;
        }

        if (std.mem.startsWith(u8, line, "fn ")) {
            const after_fn = std.mem.trim(u8, line[3..], " ");
            const lparen = std.mem.indexOfScalar(u8, after_fn, '(') orelse after_fn.len;
            const fn_name = std.mem.trim(u8, after_fn[0..lparen], " ");
            try out.appendSlice(allocator, "(unit ");
            try out.appendSlice(allocator, fn_name);
            try out.append(allocator, '\n');
            try stack.append(allocator, .unit_block);
            continue;
        }

        if (std.mem.startsWith(u8, line, "let ")) {
            const rest = std.mem.trim(u8, line[4..], " ;");
            if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
                const raw_name = std.mem.trim(u8, rest[0..eq], " ");
                const colon = std.mem.indexOfScalar(u8, raw_name, ':') orelse raw_name.len;
                const var_name = std.mem.trim(u8, raw_name[0..colon], " ");
                const val_expr = std.mem.trim(u8, rest[eq + 1 ..], " ;");
                try out.appendSlice(allocator, "  (let ");
                try out.appendSlice(allocator, var_name);
                try out.append(allocator, ' ');
                try transpileExpr(allocator, &out, val_expr);
                try out.appendSlice(allocator, ")\n");
                continue;
            }
        }

        if (std.mem.startsWith(u8, line, "if ")) {
            var rest = std.mem.trim(u8, line[3..], " {");
            if (std.mem.startsWith(u8, rest, "(") and std.mem.endsWith(u8, rest, ")")) {
                rest = rest[1 .. rest.len - 1];
            }
            try out.appendSlice(allocator, "  (if ");
            try transpileExpr(allocator, &out, rest);
            try out.append(allocator, '\n');
            try stack.append(allocator, .if_then);
            continue;
        }

        if (std.mem.startsWith(u8, line, "return")) {
            const rest = std.mem.trim(u8, line[6..], " ;");
            try out.appendSlice(allocator, "  (return_ok ");
            if (rest.len > 0) {
                try transpileExpr(allocator, &out, rest);
            } else {
                try out.appendSlice(allocator, "0");
            }
            try out.appendSlice(allocator, ")\n");
            continue;
        }

        // Bare call or expression line
        try out.appendSlice(allocator, "  ");
        try transpileExpr(allocator, &out, line);
        try out.append(allocator, '\n');
    }

    while (stack.items.len > 0) {
        _ = stack.pop();
        try out.appendSlice(allocator, ")\n");
    }

    return try out.toOwnedSlice(allocator);
}

fn transpileExpr(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), expr_in: []const u8) anyerror!void {
    const expr = std.mem.trim(u8, expr_in, " ;");
    if (expr.len == 0) return;

    if (expr.len >= 2 and expr[0] == '"' and expr[expr.len - 1] == '"') {
        try out.appendSlice(allocator, expr);
        return;
    }

    // Strip outer balanced parentheses if wrapping the entire expression
    if (expr.len >= 2 and expr[0] == '(' and expr[expr.len - 1] == ')') {
        var depth: usize = 0;
        var balanced_outer = true;
        for (expr, 0..) |ch, i| {
            if (ch == '(') depth += 1 else if (ch == ')') depth -= 1;
            if (depth == 0 and i < expr.len - 1) {
                balanced_outer = false;
                break;
            }
        }
        if (balanced_outer) {
            try transpileExpr(allocator, out, expr[1 .. expr.len - 1]);
            return;
        }
    }

    // Precedence-aware top-level binary operator scan (outside parens/quotes)
    const ops = [_][]const u8{ " == ", " > ", " < ", " + ", " - ", " * ", " / " };
    for (ops) |op| {
        if (findTopLevelOp(expr, op)) |pos| {
            const op_sym = std.mem.trim(u8, op, " ");
            const left = expr[0..pos];
            const right = expr[pos + op.len ..];
            try out.appendSlice(allocator, "(call ");
            try out.appendSlice(allocator, op_sym);
            try out.append(allocator, ' ');
            try transpileExpr(allocator, out, left);
            try out.append(allocator, ' ');
            try transpileExpr(allocator, out, right);
            try out.appendSlice(allocator, ")");
            return;
        }
    }

    // Function call: fname(arg1, arg2)
    if (std.mem.indexOfScalar(u8, expr, '(')) |lparen| {
        if (std.mem.endsWith(u8, expr, ")")) {
            const fname = std.mem.trim(u8, expr[0..lparen], " ");
            const inner = expr[lparen + 1 .. expr.len - 1];
            try out.appendSlice(allocator, "(call ");
            try out.appendSlice(allocator, fname);
            var args = std.mem.splitScalar(u8, inner, ',');
            while (args.next()) |arg| {
                const a = std.mem.trim(u8, arg, " ");
                if (a.len == 0) continue;
                try out.append(allocator, ' ');
                try transpileExpr(allocator, out, a);
            }
            try out.appendSlice(allocator, ")");
            return;
        }
    }

    try out.appendSlice(allocator, expr);
}

fn findTopLevelOp(expr: []const u8, op: []const u8) ?usize {
    if (expr.len < op.len) return null;
    var depth: usize = 0;
    var in_str = false;
    var i: usize = 0;
    while (i + op.len <= expr.len) : (i += 1) {
        const ch = expr[i];
        if (ch == '"') in_str = !in_str;
        if (!in_str) {
            if (ch == '(') depth += 1 else if (ch == ')' and depth > 0) depth -= 1;
            if (depth == 0 and std.mem.eql(u8, expr[i .. i + op.len], op)) {
                return i;
            }
        }
    }
    return null;
}

const SweetPrinter = struct {
    graph: *const UrGraph,
    out: *UrTokenStream,
    visited: std.AutoHashMapUnmanaged(CellIdx, void) = .empty,

    fn deinit(self: *SweetPrinter) void {
        self.visited.deinit(self.out.allocator);
    }

    fn writeIndent(self: *SweetPrinter, level: usize) !void {
        var i: usize = 0;
        while (i < level * 2) : (i += 1) {
            try self.out.writeByte(' ');
        }
    }

    fn isInfixOp(op: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "add")) return "+";
        if (std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "sub")) return "-";
        if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "mul")) return "*";
        if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "div")) return "/";
        if (std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "gt")) return ">";
        if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "lt")) return "<";
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "eq")) return "==";
        return null;
    }

    fn printCell(self: *SweetPrinter, idx: CellIdx, indent: usize, stmt_ctx: bool) UrError!void {
        if (idx == NULL_CELL) {
            self.out.write("nil") catch return error.OutOfMemory;
            return;
        }
        const cell = self.graph.getCell(idx);
        const start_pos = self.out.buf.items.len;

        switch (cell.kind) {
            .nil_cell => self.out.write("nil") catch return error.OutOfMemory,
            .bool_lit => self.out.write(if (cell.payload.raw != 0) "true" else "false") catch return error.OutOfMemory,
            .int_lit => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{cell.payload.imm_i64}) catch "0";
                self.out.write(s) catch return error.OutOfMemory;
            },
            .float_lit => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.2}", .{cell.payload.imm_f64}) catch "0.0";
                self.out.write(s) catch return error.OutOfMemory;
            },
            .sym_atom => self.out.write(self.graph.getSym(cell.head_idx)) catch return error.OutOfMemory,
            .bytes_blob => {
                const s = self.graph.getBlob(@truncate(cell.payload.raw >> 32), @truncate(cell.payload.raw));
                self.out.writeByte('"') catch return error.OutOfMemory;
                self.out.write(s) catch return error.OutOfMemory;
                self.out.writeByte('"') catch return error.OutOfMemory;
            },
            .hazel_hole => self.out.write("?hole") catch return error.OutOfMemory,
            .hazel_membrane => try self.printCell(cell.payload.membrane.inner_cell, indent, stmt_ctx),
            .unit_def => {
                if (self.visited.contains(idx)) return;
                self.visited.put(self.out.allocator, idx, {}) catch return error.OutOfMemory;
                const name = self.graph.getSym(cell.head_idx);
                self.out.write("fn ") catch return error.OutOfMemory;
                self.out.write(name) catch return error.OutOfMemory;
                self.out.write("() {\n") catch return error.OutOfMemory;
                const ch = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (ch) |c| {
                    self.writeIndent(indent + 1) catch return error.OutOfMemory;
                    try self.printCell(c, indent + 1, true);
                    const ck = self.graph.getCell(c).kind;
                    if (ck != .if_branch) {
                        self.out.write(";\n") catch return error.OutOfMemory;
                    }
                }
                self.writeIndent(indent) catch return error.OutOfMemory;
                self.out.write("}\n") catch return error.OutOfMemory;
            },
            .let_bind => {
                const name = self.graph.getSym(cell.head_idx);
                self.out.write("let ") catch return error.OutOfMemory;
                self.out.write(name) catch return error.OutOfMemory;
                self.out.write(" = ") catch return error.OutOfMemory;
                const ch = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len > 0) try self.printCell(ch[0], indent, false) else self.out.write("nil") catch return error.OutOfMemory;
            },
            .return_ok => {
                self.out.write("return") catch return error.OutOfMemory;
                const ch = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len > 0) {
                    self.out.writeByte(' ') catch return error.OutOfMemory;
                    try self.printCell(ch[0], indent, false);
                }
            },
            .call_node => {
                const fn_name = self.graph.getSym(cell.head_idx);
                const ch = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (isInfixOp(fn_name)) |op| {
                    if (ch.len >= 2) {
                        self.out.writeByte('(') catch return error.OutOfMemory;
                        try self.printCell(ch[0], indent, false);
                        self.out.writeByte(' ') catch return error.OutOfMemory;
                        self.out.write(op) catch return error.OutOfMemory;
                        self.out.writeByte(' ') catch return error.OutOfMemory;
                        try self.printCell(ch[1], indent, false);
                        self.out.writeByte(')') catch return error.OutOfMemory;
                    }
                } else {
                    self.out.write(fn_name) catch return error.OutOfMemory;
                    self.out.writeByte('(') catch return error.OutOfMemory;
                    for (ch, 0..) |arg, i| {
                        if (i > 0) self.out.write(", ") catch return error.OutOfMemory;
                        try self.printCell(arg, indent, false);
                    }
                    self.out.writeByte(')') catch return error.OutOfMemory;
                }
            },
            .if_branch => {
                const ch = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (ch.len >= 3) {
                    self.out.write("if (") catch return error.OutOfMemory;
                    try self.printCell(ch[0], indent, false);
                    self.out.write(") {\n") catch return error.OutOfMemory;
                    self.writeIndent(indent + 1) catch return error.OutOfMemory;
                    try self.printCell(ch[1], indent + 1, true);
                    self.out.write(";\n") catch return error.OutOfMemory;
                    self.writeIndent(indent) catch return error.OutOfMemory;
                    self.out.write("} else {\n") catch return error.OutOfMemory;
                    self.writeIndent(indent + 1) catch return error.OutOfMemory;
                    try self.printCell(ch[2], indent + 1, true);
                    self.out.write(";\n") catch return error.OutOfMemory;
                    self.writeIndent(indent) catch return error.OutOfMemory;
                    self.out.write("}\n") catch return error.OutOfMemory;
                }
            },
            else => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "/* op_0x{X:0>2} */", .{@intFromEnum(cell.kind)}) catch "/* op */";
                self.out.write(s) catch return error.OutOfMemory;
            },
        }

        const end_pos = self.out.buf.items.len;
        self.out.recordSpan(idx, start_pos, end_pos) catch return error.OutOfMemory;
    }
};

test "SweetLens roundtrip parse, Tier0 eval, and projectToSurface with spans" {
    const tier0 = @import("compiler/tier0_eval.zig");
    const urc_core = @import("compiler/urc_core.zig");
    const allocator = std.testing.allocator;

    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    const sweet_src =
        \\fn step(arg0) {
        \\  let doubled = (arg0 * 2);
        \\  if (doubled > 10) {
        \\    return (doubled + 5);
        \\  } else {
        \\    return (doubled - 1);
        \\  }
        \\}
    ;

    const unit_idx = try SweetLens.parseIntoGraph(graph, NULL_CELL, sweet_src);
    try std.testing.expect(unit_idx != NULL_CELL);
    try std.testing.expectEqual(UrKind.unit_def, graph.getCell(unit_idx).kind);

    var comp = try urc_core.UrCompiler.create(graph, urc_core.DEFAULT_FEATURES);
    defer comp.destroy();
    var t0 = tier0.Tier0Evaluator.init(comp);

    const arg_7 = try graph.allocCell(.{ .kind = .int_lit, .payload = .{ .imm_i64 = 7 } });
    const res_hi = try t0.evalUnit(unit_idx, &.{arg_7});
    try std.testing.expectEqual(@as(i64, 19), graph.getCell(res_hi).payload.imm_i64);

    var stream = UrTokenStream.init(allocator);
    defer stream.deinit();
    try SweetLens.projectToSurface(graph, unit_idx, &stream);
    const printed = stream.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, printed, "fn step()") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "let doubled = (arg0 * 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "return (doubled + 5);") != null);
    try std.testing.expect(stream.spans.items.len > 0);
}
