const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;

// Forward declaration of UrGraph interface needed by Merkle hasher
pub const IUrGraph = struct {
    ptr: *anyopaque,
    getCellFn: *const fn (ctx: *const anyopaque, idx: CellIdx) UrCell,
    getChildrenFn: *const fn (ctx: *const anyopaque, start: u32, len: u32) []const CellIdx,
    getSymFn: *const fn (ctx: *const anyopaque, id: cell_mod.SymId) []const u8,
    getBlobFn: *const fn (ctx: *const anyopaque, offset: u32, len: u32) []const u8,
    getCachedHashFn: *const fn (ctx: *const anyopaque, idx: CellIdx) u64,
    setCachedHashFn: *const fn (ctx: *anyopaque, idx: CellIdx, hash: u64) void,

    pub fn getCell(self: IUrGraph, idx: CellIdx) UrCell {
        return self.getCellFn(self.ptr, idx);
    }
    pub fn getChildren(self: IUrGraph, start: u32, len: u32) []const CellIdx {
        return self.getChildrenFn(self.ptr, start, len);
    }
    pub fn getSym(self: IUrGraph, id: cell_mod.SymId) []const u8 {
        return self.getSymFn(self.ptr, id);
    }
    pub fn getBlob(self: IUrGraph, offset: u32, len: u32) []const u8 {
        return self.getBlobFn(self.ptr, offset, len);
    }
    pub fn getCachedHash(self: IUrGraph, idx: CellIdx) u64 {
        return self.getCachedHashFn(self.ptr, idx);
    }
    pub fn setCachedHash(self: IUrGraph, idx: CellIdx, hash: u64) void {
        self.setCachedHashFn(self.ptr, idx, hash);
    }
};

const AncestorEntry = struct {
    idx: CellIdx,
    depth: u32,
};

pub const MerkleHasher = struct {
    allocator: std.mem.Allocator,
    ancestors: std.ArrayListUnmanaged(AncestorEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) MerkleHasher {
        return .{
            .allocator = allocator,
            .ancestors = .empty,
        };
    }

    pub fn deinit(self: *MerkleHasher) void {
        self.ancestors.deinit(self.allocator);
    }

    pub fn computeHash(self: *MerkleHasher, graph: IUrGraph, root_idx: CellIdx) !u64 {
        self.ancestors.clearRetainingCapacity();
        return self.hashNode(graph, root_idx);
    }

    fn hashNode(self: *MerkleHasher, graph: IUrGraph, idx: CellIdx) !u64 {
        if (idx == NULL_CELL) return 0;

        const cell = graph.getCell(idx);

        // Check if this node is an active ancestor on the stack (cycle detection)
        const current_depth: u32 = @intCast(self.ancestors.items.len);
        for (self.ancestors.items) |anc| {
            if (anc.idx == idx or (cell.kind == .cyclic_backref and cell.head_idx == anc.idx)) {
                // Canonical De Bruijn cycle hash
                const rel_depth = current_depth - anc.depth;
                var hasher = std.hash.XxHash3.init(0);
                const tag: [8]u8 = .{
                    @intFromEnum(UrKind.cyclic_backref),
                    @intCast((rel_depth >> 24) & 0xFF),
                    @intCast((rel_depth >> 16) & 0xFF),
                    @intCast((rel_depth >> 8) & 0xFF),
                    @intCast(rel_depth & 0xFF),
                    @intCast((cell.type_id >> 8) & 0xFF),
                    @intCast(cell.type_id & 0xFF),
                    0xAA,
                };
                hasher.update(&tag);
                return hasher.final();
            }
        }

        // Fast clean cache hit
        if (!cell.flags.dirty) {
            const cached = graph.getCachedHash(idx);
            if (cached != 0) return cached;
        }

        try self.ancestors.append(self.allocator, .{ .idx = idx, .depth = current_depth });
        defer _ = self.ancestors.pop();

        var hasher = std.hash.XxHash3.init(0);

        // Feed kind, flags (masking out volatile dirty bit 0), type_id
        const flags_byte = @as(u8, @bitCast(cell.flags)) & ~@as(u8, 0x01);
        const header_bytes: [4]u8 = .{
            @intFromEnum(cell.kind),
            flags_byte,
            @truncate(cell.type_id >> 8),
            @truncate(cell.type_id),
        };
        hasher.update(&header_bytes);

        switch (cell.kind) {
            .nil_cell => {},
            .bool_lit, .int_lit, .float_lit, .fixed_q16_16, .uncertain_f32, .mmio_capability, .irq_capability => {
                var p_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &p_buf, cell.payload.raw, .little);
                hasher.update(&p_buf);
            },
            .sym_atom => {
                const sym_str = graph.getSym(cell.head_idx);
                hasher.update(sym_str);
            },
            .bytes_blob => {
                const blob_bytes = graph.getBlob(@truncate(cell.payload.raw >> 32), @truncate(cell.payload.raw));
                hasher.update(blob_bytes);
            },
            .eav_tuple => {
                var head_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &head_buf, cell.head_idx, .little);
                hasher.update(&head_buf);

                const pred_str = graph.getSym(cell.payload.eav.predicate_sym);
                hasher.update(pred_str);

                const obj_hash = try self.hashNode(graph, cell.payload.eav.object_idx);
                var obj_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &obj_buf, obj_hash, .little);
                hasher.update(&obj_buf);
            },
            .cyclic_backref => {
                // If head_idx wasn't on ancestor stack, hash its index
                var h_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &h_buf, cell.head_idx, .little);
                hasher.update(&h_buf);
            },
            else => {
                // Structural/composite node with children
                if (cell.head_idx != NULL_CELL) {
                    const head_hash = try self.hashNode(graph, cell.head_idx);
                    var h_buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &h_buf, head_hash, .little);
                    hasher.update(&h_buf);
                }

                const children = graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                for (children) |child_idx| {
                    const child_hash = try self.hashNode(graph, child_idx);
                    var c_buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &c_buf, child_hash, .little);
                    hasher.update(&c_buf);
                }
            },
        }

        const digest = hasher.final();
        graph.setCachedHash(idx, digest);
        return digest;
    }
};

test "Cycle-safe De Bruijn Merkle hashing produces identical hash across distinct arena locations" {
    const graph_mod = @import("graph_store.zig");
    const allocator = std.testing.allocator;
    var graph = try graph_mod.UrGraph.create(allocator);
    defer graph.destroy();

    // Create cyclic graph 1: unit A -> call -> cyclic backref to unit A
    const unit1 = try graph.allocCell(UrCell{
        .kind = .unit_def,
        .flags = .{ .cyclic_anchor = true },
    });
    const backref1 = try graph.allocCell(UrCell{
        .kind = .cyclic_backref,
        .flags = .{ .cyclic_ref = true },
        .head_idx = unit1,
    });
    const slice1 = try graph.allocChildren(&.{backref1}, unit1);
    var u1_cell = graph.getCell(unit1);
    u1_cell.payload.slice = slice1;
    try graph.mutateCell(unit1, u1_cell);

    const hash1 = try graph.merkleHash(unit1);

    // Create cyclic graph 2 at different cell indices: unit B -> call -> cyclic backref to unit B
    // Add some dummy cells first so indices are shifted
    _ = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 123 } });
    _ = try graph.allocCell(UrCell{ .kind = .int_lit, .payload = .{ .imm_i64 = 456 } });

    const unit2 = try graph.allocCell(UrCell{
        .kind = .unit_def,
        .flags = .{ .cyclic_anchor = true },
    });
    const backref2 = try graph.allocCell(UrCell{
        .kind = .cyclic_backref,
        .flags = .{ .cyclic_ref = true },
        .head_idx = unit2,
    });
    const slice2 = try graph.allocChildren(&.{backref2}, unit2);
    var u2_cell = graph.getCell(unit2);
    u2_cell.payload.slice = slice2;
    try graph.mutateCell(unit2, u2_cell);

    const hash2 = try graph.merkleHash(unit2);

    try std.testing.expect(unit1 != unit2);
    try std.testing.expectEqual(hash1, hash2);
}
