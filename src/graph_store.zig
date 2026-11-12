const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const TypeId = cell_mod.TypeId;
const SymId = cell_mod.SymId;
const EntityId = cell_mod.EntityId;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const UrPayload = cell_mod.UrPayload;
const UrSliceDesc = cell_mod.UrSliceDesc;
const UrTypeTable = cell_mod.UrTypeTable;
const BuiltinType = cell_mod.BuiltinType;

const eav_mod = @import("eav_index.zig");
const UrEavIndex = eav_mod.UrEavIndex;
const merkle_mod = @import("merkle.zig");
const MerkleHasher = merkle_mod.MerkleHasher;
const IUrGraph = merkle_mod.IUrGraph;

pub const CELLS_PER_PAGE: usize = 256;

pub const UrPage = struct {
    cells: [CELLS_PER_PAGE]UrCell align(64),
    merkle_cache: [CELLS_PER_PAGE]u64,
    parent_idx: [CELLS_PER_PAGE]CellIdx,
    ref_count: u32,
    epoch: u32,

    pub fn init(epoch: u32) UrPage {
        var page = UrPage{
            .cells = undefined,
            .merkle_cache = undefined,
            .parent_idx = undefined,
            .ref_count = 1,
            .epoch = epoch,
        };
        for (&page.cells) |*c| c.* = UrCell{};
        for (&page.merkle_cache) |*m| m.* = 0;
        for (&page.parent_idx) |*p| p.* = NULL_CELL;
        return page;
    }
};

pub const UrGraph = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(*UrPage) = .empty,
    cell_count: u32 = 0,
    epoch: u32 = 0,
    eav_index: UrEavIndex,
    type_table: UrTypeTable,
    child_indices: std.ArrayListUnmanaged(CellIdx) = .empty,
    symbols: std.ArrayListUnmanaged(u8) = .empty,
    symbol_offsets: std.ArrayListUnmanaged(u32) = .empty,
    blobs: std.ArrayListUnmanaged(u8) = .empty,
    hasher: MerkleHasher,

    pub fn create(allocator: std.mem.Allocator) !*UrGraph {
        const self = try allocator.create(UrGraph);
        self.* = .{
            .allocator = allocator,
            .pages = .empty,
            .cell_count = 0,
            .epoch = 0,
            .eav_index = UrEavIndex.init(allocator),
            .type_table = UrTypeTable.init(allocator),
            .child_indices = .empty,
            .symbols = .empty,
            .symbol_offsets = .empty,
            .blobs = .empty,
            .hasher = MerkleHasher.init(allocator),
        };

        // Pre-allocate NULL_CELL at index 0 so cell indices start at 1
        _ = try self.allocCell(UrCell{ .kind = .nil_cell });
        // Pre-intern empty string at symbol index 0
        _ = try self.internSym("");

        return self;
    }

    pub fn destroy(self: *UrGraph) void {
        for (self.pages.items) |page| {
            if (page.ref_count <= 1) {
                self.allocator.destroy(page);
            } else {
                page.ref_count -= 1;
            }
        }
        self.pages.deinit(self.allocator);
        self.eav_index.deinit();
        self.type_table.deinit();
        self.child_indices.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.symbol_offsets.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        self.hasher.deinit();
        self.allocator.destroy(self);
    }

    pub fn forkCow(self: *const UrGraph) !*UrGraph {
        const copy = try self.allocator.create(UrGraph);
        copy.* = .{
            .allocator = self.allocator,
            .pages = .empty,
            .cell_count = self.cell_count,
            .epoch = self.epoch + 1,
            .eav_index = try self.eav_index.clone(self.allocator),
            .type_table = UrTypeTable.init(self.allocator),
            .child_indices = .empty,
            .symbols = .empty,
            .symbol_offsets = .empty,
            .blobs = .empty,
            .hasher = MerkleHasher.init(self.allocator),
        };

        // Increment ref_count on all pages
        try copy.pages.ensureTotalCapacity(self.allocator, self.pages.items.len);
        for (self.pages.items) |page| {
            page.ref_count += 1;
            try copy.pages.append(self.allocator, page);
        }

        try copy.child_indices.appendSlice(self.allocator, self.child_indices.items);
        try copy.symbols.appendSlice(self.allocator, self.symbols.items);
        try copy.symbol_offsets.appendSlice(self.allocator, self.symbol_offsets.items);
        try copy.blobs.appendSlice(self.allocator, self.blobs.items);

        return copy;
    }

    pub fn allocCell(self: *UrGraph, cell: UrCell) !CellIdx {
        const new_idx = self.cell_count;
        const page_idx = new_idx / CELLS_PER_PAGE;
        const slot_idx = new_idx % CELLS_PER_PAGE;

        if (page_idx >= self.pages.items.len) {
            const new_page = try self.allocator.create(UrPage);
            new_page.* = UrPage.init(self.epoch);
            try self.pages.append(self.allocator, new_page);
        }

        var page = self.pages.items[page_idx];
        if (page.ref_count > 1) {
            // CoW on page
            const cloned_page = try self.allocator.create(UrPage);
            cloned_page.* = page.*;
            cloned_page.ref_count = 1;
            cloned_page.epoch = self.epoch;
            page.ref_count -= 1;
            self.pages.items[page_idx] = cloned_page;
            page = cloned_page;
        }

        page.cells[slot_idx] = cell;
        page.cells[slot_idx].flags.dirty = true;
        page.merkle_cache[slot_idx] = 0;
        self.cell_count += 1;

        return new_idx;
    }

    pub fn getCell(self: *const UrGraph, idx: CellIdx) UrCell {
        if (idx >= self.cell_count) return UrCell{};
        const page_idx = idx / CELLS_PER_PAGE;
        const slot_idx = idx % CELLS_PER_PAGE;
        return self.pages.items[page_idx].cells[slot_idx];
    }

    pub fn mutateCell(self: *UrGraph, idx: CellIdx, new_cell: UrCell) !void {
        if (idx == NULL_CELL or idx >= self.cell_count) return;
        const page_idx = idx / CELLS_PER_PAGE;
        const slot_idx = idx % CELLS_PER_PAGE;

        var page = self.pages.items[page_idx];
        if (page.ref_count > 1) {
            // Trigger 4 KB Copy-on-Write page fault
            const cloned_page = try self.allocator.create(UrPage);
            cloned_page.* = page.*;
            cloned_page.ref_count = 1;
            cloned_page.epoch = self.epoch;
            page.ref_count -= 1;
            self.pages.items[page_idx] = cloned_page;
            page = cloned_page;
        }

        page.cells[slot_idx] = new_cell;
        page.cells[slot_idx].flags.dirty = true;
        page.merkle_cache[slot_idx] = 0;

        // Propagate dirty up parent_idx chain
        var curr_parent = page.parent_idx[slot_idx];
        var iterations: usize = 0;
        while (curr_parent != NULL_CELL and iterations < 1024) : (iterations += 1) {
            const p_page_idx = curr_parent / CELLS_PER_PAGE;
            const p_slot_idx = curr_parent % CELLS_PER_PAGE;
            if (p_page_idx >= self.pages.items.len) break;

            var p_page = self.pages.items[p_page_idx];
            if (p_page.ref_count > 1) {
                const c_page = try self.allocator.create(UrPage);
                c_page.* = p_page.*;
                c_page.ref_count = 1;
                c_page.epoch = self.epoch;
                p_page.ref_count -= 1;
                self.pages.items[p_page_idx] = c_page;
                p_page = c_page;
            }

            p_page.cells[p_slot_idx].flags.dirty = true;
            p_page.merkle_cache[p_slot_idx] = 0;
            curr_parent = p_page.parent_idx[p_slot_idx];
        }
    }

    pub fn allocChildren(self: *UrGraph, children: []const CellIdx, parent: CellIdx) !UrSliceDesc {
        const start: u32 = @intCast(self.child_indices.items.len);
        const len: u32 = @intCast(children.len);

        try self.child_indices.appendSlice(self.allocator, children);

        // Record parent indices
        for (children) |child_idx| {
            if (child_idx != NULL_CELL and child_idx < self.cell_count) {
                const page_idx = child_idx / CELLS_PER_PAGE;
                const slot_idx = child_idx % CELLS_PER_PAGE;
                self.pages.items[page_idx].parent_idx[slot_idx] = parent;
            }
        }

        return .{ .start = start, .len = len };
    }

    pub fn getChildren(self: *const UrGraph, start: u32, len: u32) []const CellIdx {
        if (start + len <= self.child_indices.items.len) {
            return self.child_indices.items[start .. start + len];
        }
        return &.{};
    }

    pub fn internSym(self: *UrGraph, name: []const u8) !SymId {
        // Linear scan existing symbols
        for (self.symbol_offsets.items, 0..) |offset, id| {
            const next_offset = if (id + 1 < self.symbol_offsets.items.len)
                self.symbol_offsets.items[id + 1]
            else
                @as(u32, @intCast(self.symbols.items.len));

            const existing = self.symbols.items[offset..next_offset];
            if (std.mem.eql(u8, existing, name)) {
                return @intCast(id);
            }
        }

        const new_id: SymId = @intCast(self.symbol_offsets.items.len);
        const offset: u32 = @intCast(self.symbols.items.len);
        try self.symbol_offsets.append(self.allocator, offset);
        try self.symbols.appendSlice(self.allocator, name);
        return new_id;
    }

    pub fn getSym(self: *const UrGraph, id: SymId) []const u8 {
        if (id >= self.symbol_offsets.items.len) return "";
        const offset = self.symbol_offsets.items[id];
        const next_offset = if (id + 1 < self.symbol_offsets.items.len)
            self.symbol_offsets.items[id + 1]
        else
            @as(u32, @intCast(self.symbols.items.len));
        return self.symbols.items[offset..next_offset];
    }

    pub fn allocBlob(self: *UrGraph, data: []const u8) !u64 {
        const offset: u32 = @intCast(self.blobs.items.len);
        const len: u32 = @intCast(data.len);
        try self.blobs.appendSlice(self.allocator, data);
        return (@as(u64, offset) << 32) | @as(u64, len);
    }

    pub fn getBlob(self: *const UrGraph, offset: u32, len: u32) []const u8 {
        if (offset + len <= self.blobs.items.len) {
            return self.blobs.items[offset .. offset + len];
        }
        return &.{};
    }

    pub fn spliceHole(self: *UrGraph, hole_idx: CellIdx, plug_idx: CellIdx) !CellIdx {
        const hole_cell = self.getCell(hole_idx);
        const plug_cell = self.getCell(plug_idx);

        // Check Pantograph type compatibility
        const types_compatible = (hole_cell.type_id == BuiltinType.any_type or
            hole_cell.type_id == BuiltinType.hole_type or
            hole_cell.type_id == plug_cell.type_id);

        if (types_compatible) {
            // Clean splice
            try self.mutateCell(hole_idx, plug_cell);
            return hole_idx;
        } else {
            // Mismatch: wrap in non-crashing hazel_membrane (0x65)
            const membrane_cell = UrCell{
                .kind = .hazel_membrane,
                .flags = .{ .dirty = true },
                .type_id = hole_cell.type_id,
                .head_idx = hole_idx,
                .payload = .{
                    .membrane = .{
                        .inner_cell = plug_idx,
                        .expected_type = hole_cell.type_id,
                        .actual_type = plug_cell.type_id,
                    },
                },
            };
            try self.mutateCell(hole_idx, membrane_cell);
            return hole_idx;
        }
    }

    pub fn merkleHash(self: *UrGraph, root_idx: CellIdx) !u64 {
        const adapter = IUrGraph{
            .ptr = self,
            .getCellFn = struct {
                fn get(ctx: *const anyopaque, idx: CellIdx) UrCell {
                    const g: *const UrGraph = @ptrCast(@alignCast(ctx));
                    return g.getCell(idx);
                }
            }.get,
            .getChildrenFn = struct {
                fn get(ctx: *const anyopaque, start: u32, len: u32) []const CellIdx {
                    const g: *const UrGraph = @ptrCast(@alignCast(ctx));
                    return g.getChildren(start, len);
                }
            }.get,
            .getSymFn = struct {
                fn get(ctx: *const anyopaque, id: SymId) []const u8 {
                    const g: *const UrGraph = @ptrCast(@alignCast(ctx));
                    return g.getSym(id);
                }
            }.get,
            .getBlobFn = struct {
                fn get(ctx: *const anyopaque, offset: u32, len: u32) []const u8 {
                    const g: *const UrGraph = @ptrCast(@alignCast(ctx));
                    return g.getBlob(offset, len);
                }
            }.get,
            .getCachedHashFn = struct {
                fn get(ctx: *const anyopaque, idx: CellIdx) u64 {
                    const g: *const UrGraph = @ptrCast(@alignCast(ctx));
                    if (idx >= g.cell_count) return 0;
                    return g.pages.items[idx / CELLS_PER_PAGE].merkle_cache[idx % CELLS_PER_PAGE];
                }
            }.get,
            .setCachedHashFn = struct {
                fn set(ctx: *anyopaque, idx: CellIdx, hash: u64) void {
                    const g: *UrGraph = @ptrCast(@alignCast(ctx));
                    if (idx >= g.cell_count) return;
                    g.pages.items[idx / CELLS_PER_PAGE].merkle_cache[idx % CELLS_PER_PAGE] = hash;
                    g.pages.items[idx / CELLS_PER_PAGE].cells[idx % CELLS_PER_PAGE].flags.dirty = false;
                }
            }.set,
        };

        return self.hasher.computeHash(adapter, root_idx);
    }
};

test "UrGraph creation, CoW page fault and Pantograph splice" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    const c1 = try graph.allocCell(UrCell{
        .kind = .int_lit,
        .type_id = BuiltinType.int_type,
        .payload = .{ .imm_i64 = 42 },
    });
    try std.testing.expectEqual(@as(i64, 42), graph.getCell(c1).payload.imm_i64);

    // Fork CoW
    var fork = try graph.forkCow();
    defer fork.destroy();

    // Verify initial shared page ref_count
    try std.testing.expectEqual(@as(u32, 2), graph.pages.items[0].ref_count);

    // Mutate cell in fork -> page fault, creates private copy
    try fork.mutateCell(c1, UrCell{
        .kind = .int_lit,
        .type_id = BuiltinType.int_type,
        .payload = .{ .imm_i64 = 999 },
    });

    try std.testing.expectEqual(@as(i64, 42), graph.getCell(c1).payload.imm_i64);
    try std.testing.expectEqual(@as(i64, 999), fork.getCell(c1).payload.imm_i64);

    // Test Merkle hashing on graph
    const hash1 = try graph.merkleHash(c1);
    try std.testing.expect(hash1 != 0);

    // Test Pantograph splice
    const hole = try graph.allocCell(UrCell{
        .kind = .hazel_hole,
        .type_id = BuiltinType.float_type,
    });
    const plug_int = try graph.allocCell(UrCell{
        .kind = .int_lit,
        .type_id = BuiltinType.int_type,
        .payload = .{ .imm_i64 = 100 },
    });
    // Type mismatch -> wrapped in hazel_membrane
    const spliced = try graph.spliceHole(hole, plug_int);
    const spliced_cell = graph.getCell(spliced);
    try std.testing.expectEqual(UrKind.hazel_membrane, spliced_cell.kind);
    try std.testing.expectEqual(plug_int, spliced_cell.payload.membrane.inner_cell);
}
