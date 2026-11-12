const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("lens_api.zig");
const UrError = lens_mod.UrError;
const UrTokenStream = lens_mod.UrTokenStream;
const UrLensVTable = lens_mod.UrLensVTable;
const TypeDiff = lens_mod.TypeDiff;

pub const SexprLens = struct {
    pub const vtable: UrLensVTable = .{
        .dialect_name = "urasg_sexpr",
        .project_to_surface = projectToSurface,
        .parse_into_graph = parseIntoGraph,
        .compute_type_diff = computeTypeDiff,
        .lower_subgraph = null,
    };

    pub fn projectToSurface(graph: *const UrGraph, root: CellIdx, out: *UrTokenStream) UrError!void {
        var printer = SexprPrinter.init(graph, out);
        defer printer.deinit();
        try printer.collectCyclicAnchors(root);
        try printer.printCell(root);
    }

    pub fn parseIntoGraph(graph: *UrGraph, target: CellIdx, src: []const u8) UrError!CellIdx {
        var parser = SexprParser.init(graph, src);
        defer parser.deinit();
        return parser.parse(target);
    }

    pub fn computeTypeDiff(graph: *const UrGraph, hole_idx: CellIdx, plug_idx: CellIdx) TypeDiff {
        const hole_cell = graph.getCell(hole_idx);
        const plug_cell = graph.getCell(plug_idx);

        if (hole_cell.type_id == BuiltinType.any_type or hole_cell.type_id == BuiltinType.hole_type or hole_cell.type_id == plug_cell.type_id) {
            return .{
                .status = .exact,
                .expected_type = hole_cell.type_id,
                .actual_type = plug_cell.type_id,
            };
        }
        return .{
            .status = .needs_membrane,
            .expected_type = hole_cell.type_id,
            .actual_type = plug_cell.type_id,
        };
    }
};

const SexprPrinter = struct {
    graph: *const UrGraph,
    out: *UrTokenStream,
    anchor_map: std.AutoHashMapUnmanaged(CellIdx, u32) = .empty,
    next_anchor: u32 = 1,
    visited: std.AutoHashMapUnmanaged(CellIdx, void) = .empty,

    pub fn init(graph: *const UrGraph, out: *UrTokenStream) SexprPrinter {
        return .{
            .graph = graph,
            .out = out,
        };
    }

    pub fn deinit(self: *SexprPrinter) void {
        self.anchor_map.deinit(self.out.allocator);
        self.visited.deinit(self.out.allocator);
    }

    pub fn collectCyclicAnchors(self: *SexprPrinter, root: CellIdx) !void {
        if (root == NULL_CELL) return;
        if (self.visited.contains(root)) {
            if (!self.anchor_map.contains(root)) {
                try self.anchor_map.put(self.out.allocator, root, self.next_anchor);
                self.next_anchor += 1;
            }
            return;
        }

        try self.visited.put(self.out.allocator, root, {});
        const cell = self.graph.getCell(root);
        if (cell.flags.cyclic_anchor and !self.anchor_map.contains(root)) {
            try self.anchor_map.put(self.out.allocator, root, self.next_anchor);
            self.next_anchor += 1;
        }

        if (cell.head_idx != NULL_CELL and cell.kind != .sym_atom and cell.kind != .cyclic_backref) {
            try self.collectCyclicAnchors(cell.head_idx);
        }

        switch (cell.kind) {
            .eav_tuple => {
                try self.collectCyclicAnchors(cell.payload.eav.object_idx);
            },
            .unit_def, .call_node, .let_bind, .if_branch, .sample_io_row, .loop_repeat, .match_switch => {
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |c| try self.collectCyclicAnchors(c);
            },
            else => {},
        }
    }

    pub fn printCell(self: *SexprPrinter, idx: CellIdx) !void {
        if (idx == NULL_CELL) {
            try self.out.write("nil");
            return;
        }

        const cell = self.graph.getCell(idx);

        if (cell.kind == .cyclic_backref) {
            const anchor = self.anchor_map.get(cell.head_idx) orelse 1;
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "#{d}#", .{anchor}) catch "#1#";
            try self.out.write(s);
            return;
        }

        if (self.anchor_map.get(idx)) |anchor| {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "#{d}=", .{anchor}) catch "#1=";
            try self.out.write(s);
        }

        switch (cell.kind) {
            .nil_cell => try self.out.write("nil"),
            .bool_lit => try self.out.write(if (cell.payload.raw != 0) "true" else "false"),
            .int_lit => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{cell.payload.imm_i64}) catch "0";
                try self.out.write(s);
            },
            .float_lit => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.2}", .{cell.payload.imm_f64}) catch "0.0";
                try self.out.write(s);
            },
            .uncertain_f32 => {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "(Uncertain {d:.2} {d:.2})", .{ cell.payload.uncertain.mean, cell.payload.uncertain.std_dev }) catch "(Uncertain 0 0)";
                try self.out.write(s);
            },
            .sym_atom => {
                const sym = self.graph.getSym(cell.head_idx);
                try self.out.write(sym);
            },
            .bytes_blob => {
                const blob = self.graph.getBlob(@truncate(cell.payload.raw >> 32), @truncate(cell.payload.raw));
                try self.out.writeByte('"');
                try self.out.write(blob);
                try self.out.writeByte('"');
            },
            .unit_def => {
                const name = self.graph.getSym(cell.head_idx);
                try self.out.write("(unit ");
                try self.out.write(name);

                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
            .let_bind => {
                const name = self.graph.getSym(cell.head_idx);
                try self.out.write("(let ");
                try self.out.write(name);
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len > 0) {
                    try self.out.writeByte(' ');
                    try self.printCell(children[0]);
                }
                try self.out.writeByte(')');
            },
            .call_node => {
                const fn_name = self.graph.getSym(cell.head_idx);
                try self.out.write("(call ");
                try self.out.write(fn_name);
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
            .if_branch => {
                try self.out.write("(if");
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
            .return_ok => {
                try self.out.write("(return_ok");
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
            .try_or_err => {
                try self.out.write("(try_or_err");
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
            .sample_io_row => {
                try self.out.write("(sample ");
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len >= 2) {
                    try self.printCell(children[0]);
                    try self.out.write(" => ");
                    try self.printCell(children[1]);
                }
                try self.out.writeByte(')');
            },
            .hazel_hole => try self.out.write("?hole"),
            .hazel_membrane => {
                try self.out.write("(hazel_membrane ");
                try self.printCell(cell.payload.membrane.inner_cell);
                try self.out.writeByte(')');
            },
            .eav_tuple => {
                const pred = self.graph.getSym(cell.payload.eav.predicate_sym);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "(eav {d} :{s} ", .{ cell.head_idx, pred }) catch "(eav ? ";
                try self.out.write(s);
                try self.printCell(cell.payload.eav.object_idx);
                try self.out.writeByte(')');
            },
            else => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "(op_0x{X:0>2}", .{@intFromEnum(cell.kind)}) catch "(op";
                try self.out.write(s);
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child| {
                    try self.out.writeByte(' ');
                    try self.printCell(child);
                }
                try self.out.writeByte(')');
            },
        }
    }
};

const SexprParser = struct {
    graph: *UrGraph,
    src: []const u8,
    pos: usize = 0,
    anchors: std.AutoHashMapUnmanaged(u32, CellIdx) = .empty,
    pending_refs: std.ArrayListUnmanaged(struct { cell_idx: CellIdx, anchor_id: u32 }) = .empty,

    pub fn init(graph: *UrGraph, src: []const u8) SexprParser {
        return .{
            .graph = graph,
            .src = src,
        };
    }

    pub fn deinit(self: *SexprParser) void {
        self.anchors.deinit(self.graph.allocator);
        self.pending_refs.deinit(self.graph.allocator);
    }

    pub fn parse(self: *SexprParser, target: CellIdx) UrError!CellIdx {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return NULL_CELL;

        var anchor_id: ?u32 = null;
        if (self.peekAnchorDef()) |aid| {
            anchor_id = aid;
        }

        const root = try self.parseForm();

        if (anchor_id) |aid| {
            self.anchors.put(self.graph.allocator, aid, root) catch return error.OutOfMemory;
            var root_cell = self.graph.getCell(root);
            root_cell.flags.cyclic_anchor = true;
            self.graph.mutateCell(root, root_cell) catch return error.OutOfMemory;
        }

        // Resolve any back-references
        for (self.pending_refs.items) |ref| {
            if (self.anchors.get(ref.anchor_id)) |target_idx| {
                var ref_cell = self.graph.getCell(ref.cell_idx);
                ref_cell.head_idx = target_idx;
                self.graph.mutateCell(ref.cell_idx, ref_cell) catch return error.OutOfMemory;
            }
        }

        if (target != NULL_CELL) {
            const root_cell = self.graph.getCell(root);
            self.graph.mutateCell(target, root_cell) catch return error.OutOfMemory;
            return target;
        }

        return root;
    }

    fn peekAnchorDef(self: *SexprParser) ?u32 {
        if (self.pos + 3 < self.src.len and self.src[self.pos] == '#') {
            var i = self.pos + 1;
            var num: u32 = 0;
            while (i < self.src.len and std.ascii.isDigit(self.src[i])) : (i += 1) {
                num = num * 10 + (self.src[i] - '0');
            }
            if (i < self.src.len and self.src[i] == '=') {
                self.pos = i + 1;
                return num;
            }
        }
        return null;
    }

    fn skipWhitespace(self: *SexprParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == ';') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else {
                break;
            }
        }
    }

    fn parseForm(self: *SexprParser) UrError!CellIdx {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return NULL_CELL;

        const c = self.src[self.pos];

        if (c == '#') {
            // Check for cyclic backref #N#
            var i = self.pos + 1;
            var num: u32 = 0;
            while (i < self.src.len and std.ascii.isDigit(self.src[i])) : (i += 1) {
                num = num * 10 + (self.src[i] - '0');
            }
            if (i < self.src.len and self.src[i] == '#') {
                self.pos = i + 1;
                const backref_cell = self.graph.allocCell(UrCell{
                    .kind = .cyclic_backref,
                    .flags = .{ .cyclic_ref = true },
                    .head_idx = self.anchors.get(num) orelse NULL_CELL,
                }) catch return error.OutOfMemory;
                if (!self.anchors.contains(num)) {
                    self.pending_refs.append(self.graph.allocator, .{
                        .cell_idx = backref_cell,
                        .anchor_id = num,
                    }) catch return error.OutOfMemory;
                }
                return backref_cell;
            }
        }

        if (c == '(') {
            return self.parseList();
        } else if (c == '"') {
            return self.parseString();
        } else if (c == '?') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isAlphanumeric(self.src[self.pos])) : (self.pos += 1) {}
            return self.graph.allocCell(UrCell{
                .kind = .hazel_hole,
                .type_id = BuiltinType.hole_type,
            }) catch return error.OutOfMemory;
        } else {
            return self.parseAtom();
        }
    }

    fn parseString(self: *SexprParser) UrError!CellIdx {
        self.pos += 1; // skip opening quote
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '"') : (self.pos += 1) {
            if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 1;
            }
        }
        const text = self.src[start..self.pos];
        if (self.pos < self.src.len) self.pos += 1; // skip closing quote

        const payload_blob = self.graph.allocBlob(text) catch return error.OutOfMemory;
        return self.graph.allocCell(UrCell{
            .kind = .bytes_blob,
            .type_id = BuiltinType.string_type,
            .payload = .{ .raw = payload_blob },
        }) catch return error.OutOfMemory;
    }

    fn parseAtom(self: *SexprParser) UrError!CellIdx {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == ')' or ch == '(') break;
            self.pos += 1;
        }
        const token = self.src[start..self.pos];

        if (std.mem.eql(u8, token, "true")) {
            return self.graph.allocCell(UrCell{
                .kind = .bool_lit,
                .type_id = BuiltinType.bool_type,
                .payload = .{ .raw = 1 },
            }) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, token, "false")) {
            return self.graph.allocCell(UrCell{
                .kind = .bool_lit,
                .type_id = BuiltinType.bool_type,
                .payload = .{ .raw = 0 },
            }) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, token, "nil")) {
            return self.graph.allocCell(UrCell{ .kind = .nil_cell }) catch return error.OutOfMemory;
        }

        // Try integer
        if (std.fmt.parseInt(i64, token, 10)) |val| {
            return self.graph.allocCell(UrCell{
                .kind = .int_lit,
                .type_id = BuiltinType.int_type,
                .payload = .{ .imm_i64 = val },
            }) catch return error.OutOfMemory;
        } else |_| {}

        // Try float
        if (std.fmt.parseFloat(f64, token)) |val| {
            return self.graph.allocCell(UrCell{
                .kind = .float_lit,
                .type_id = BuiltinType.float_type,
                .payload = .{ .imm_f64 = val },
            }) catch return error.OutOfMemory;
        } else |_| {}

        // Identifier symbol
        const sym_id = self.graph.internSym(token) catch return error.OutOfMemory;
        return self.graph.allocCell(UrCell{
            .kind = .sym_atom,
            .type_id = BuiltinType.sym_type,
            .head_idx = sym_id,
        }) catch return error.OutOfMemory;
    }

    fn parseList(self: *SexprParser) UrError!CellIdx {
        self.pos += 1; // skip '('
        self.skipWhitespace();

        if (self.pos < self.src.len and self.src[self.pos] == ')') {
            self.pos += 1;
            return self.graph.allocCell(UrCell{ .kind = .nil_cell }) catch return error.OutOfMemory;
        }

        // Check head token
        const head_start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == ')' or ch == '(') break;
            self.pos += 1;
        }
        const tag = self.src[head_start..self.pos];

        if (std.mem.eql(u8, tag, "unit")) {
            self.skipWhitespace();
            // Parse unit name
            const name_start = self.pos;
            while (self.pos < self.src.len and !std.ascii.isWhitespace(self.src[self.pos]) and self.src[self.pos] != ')') : (self.pos += 1) {}
            const unit_name = self.src[name_start..self.pos];
            const sym_id = self.graph.internSym(unit_name) catch return error.OutOfMemory;

            var children: std.ArrayListUnmanaged(CellIdx) = .empty;
            defer children.deinit(self.graph.allocator);

            while (true) {
                self.skipWhitespace();
                if (self.pos >= self.src.len or self.src[self.pos] == ')') break;
                const child = try self.parseForm();
                children.append(self.graph.allocator, child) catch return error.OutOfMemory;
            }
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;

            const unit_cell_idx = self.graph.allocCell(UrCell{
                .kind = .unit_def,
                .head_idx = sym_id,
            }) catch return error.OutOfMemory;
            const slice = self.graph.allocChildren(children.items, unit_cell_idx) catch return error.OutOfMemory;
            var u_cell = self.graph.getCell(unit_cell_idx);
            u_cell.payload.slice = slice;
            self.graph.mutateCell(unit_cell_idx, u_cell) catch return error.OutOfMemory;
            return unit_cell_idx;
        } else if (std.mem.eql(u8, tag, "let")) {
            self.skipWhitespace();
            const name_start = self.pos;
            while (self.pos < self.src.len and !std.ascii.isWhitespace(self.src[self.pos]) and self.src[self.pos] != ')') : (self.pos += 1) {}
            const let_name = self.src[name_start..self.pos];
            const sym_id = self.graph.internSym(let_name) catch return error.OutOfMemory;

            self.skipWhitespace();
            const val_cell = try self.parseForm();

            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;

            const let_idx = self.graph.allocCell(UrCell{
                .kind = .let_bind,
                .head_idx = sym_id,
            }) catch return error.OutOfMemory;
            const slice = self.graph.allocChildren(&.{val_cell}, let_idx) catch return error.OutOfMemory;
            var l_cell = self.graph.getCell(let_idx);
            l_cell.payload.slice = slice;
            self.graph.mutateCell(let_idx, l_cell) catch return error.OutOfMemory;
            return let_idx;
        } else if (std.mem.eql(u8, tag, "call")) {
            self.skipWhitespace();
            const fn_start = self.pos;
            while (self.pos < self.src.len and !std.ascii.isWhitespace(self.src[self.pos]) and self.src[self.pos] != ')') : (self.pos += 1) {}
            const fn_name = self.src[fn_start..self.pos];
            const sym_id = self.graph.internSym(fn_name) catch return error.OutOfMemory;

            var args: std.ArrayListUnmanaged(CellIdx) = .empty;
            defer args.deinit(self.graph.allocator);

            while (true) {
                self.skipWhitespace();
                if (self.pos >= self.src.len or self.src[self.pos] == ')') break;
                const arg = try self.parseForm();
                args.append(self.graph.allocator, arg) catch return error.OutOfMemory;
            }
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;

            const call_idx = self.graph.allocCell(UrCell{
                .kind = .call_node,
                .head_idx = sym_id,
            }) catch return error.OutOfMemory;
            const slice = self.graph.allocChildren(args.items, call_idx) catch return error.OutOfMemory;
            var c_cell = self.graph.getCell(call_idx);
            c_cell.payload.slice = slice;
            self.graph.mutateCell(call_idx, c_cell) catch return error.OutOfMemory;
            return call_idx;
        } else {
            // General form: (tag child1 child2 ...)
            const sym_id = self.graph.internSym(tag) catch return error.OutOfMemory;
            var items: std.ArrayListUnmanaged(CellIdx) = .empty;
            defer items.deinit(self.graph.allocator);

            while (true) {
                self.skipWhitespace();
                if (self.pos >= self.src.len or self.src[self.pos] == ')') break;
                // Handle arrow => or ⇒ in samples
                if (self.pos + 2 <= self.src.len and (std.mem.eql(u8, self.src[self.pos .. self.pos + 2], "=>") or
                    (self.pos + 3 <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "⇒"))))
                {
                    self.pos += if (self.src[self.pos] == '=') 2 else 3;
                    continue;
                }
                const item = try self.parseForm();
                items.append(self.graph.allocator, item) catch return error.OutOfMemory;
            }
            if (self.pos < self.src.len and self.src[self.pos] == ')') self.pos += 1;

            const parent_idx = self.graph.allocCell(UrCell{
                .kind = if (std.mem.eql(u8, tag, "if"))
                    .if_branch
                else if (std.mem.eql(u8, tag, "return_ok"))
                    .return_ok
                else if (std.mem.eql(u8, tag, "try_or_err"))
                    .try_or_err
                else
                    .call_node,
                .head_idx = sym_id,
            }) catch return error.OutOfMemory;
            const slice = self.graph.allocChildren(items.items, parent_idx) catch return error.OutOfMemory;
            var p_cell = self.graph.getCell(parent_idx);
            p_cell.payload.slice = slice;
            self.graph.mutateCell(parent_idx, p_cell) catch return error.OutOfMemory;
            return parent_idx;
        }
    }
};

pub fn printSexpr(graph: *const UrGraph, root: CellIdx, buf: []u8) !usize {
    var stream = UrTokenStream.init(graph.allocator);
    defer stream.deinit();

    try SexprLens.projectToSurface(graph, root, &stream);
    const output = stream.getOutput();
    if (output.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0..output.len], output);
    return output.len;
}

pub fn parseSexpr(graph: *UrGraph, src: []const u8) !CellIdx {
    return SexprLens.parseIntoGraph(graph, NULL_CELL, src);
}

test "Canonical Cyclic S-Expression print and parse round-trip" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    const sample_sexpr = "#1=(unit apply_thruster (call validate sensor) #1#)";
    const root = try parseSexpr(graph, sample_sexpr);
    try std.testing.expect(root != NULL_CELL);

    var buf: [512]u8 = undefined;
    const len = try printSexpr(graph, root, &buf);
    const printed = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, printed, "#1=") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(unit apply_thruster") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "#1#") != null);
}
