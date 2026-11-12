const std = @import("std");
const builtin = @import("builtin");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const graph_mod = @import("graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const CELLS_PER_PAGE = graph_mod.CELLS_PER_PAGE;
const UrPage = graph_mod.UrPage;
const eav_mod = @import("eav_index.zig");
const EavRow = eav_mod.EavRow;
const lens_mod = @import("lens_api.zig");
const UrError = lens_mod.UrError;

pub const URASG_MAGIC: [8]u8 = "URASGv01".*;

pub const UrBinaryHeader = extern struct {
    magic: [8]u8 = URASG_MAGIC,
    version: u32 = 1,
    flags: u32 = 0,
    root_idx: u32 = 0,
    cell_count: u32 = 0,
    child_idx_count: u32 = 0,
    sym_count: u32 = 0,
    blob_bytes_len: u64 = 0,
    eav_count: u32 = 0,
    type_count: u32 = 0,
    content_xxh3: u64 = 0,
    reserved: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(UrBinaryHeader) == 64);
    }
};

pub fn serializeGraph(graph: *const UrGraph, root_idx: CellIdx, allocator: std.mem.Allocator) UrError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var header = UrBinaryHeader{
        .magic = URASG_MAGIC,
        .version = 1,
        .flags = 0,
        .root_idx = root_idx,
        .cell_count = graph.cell_count,
        .child_idx_count = @intCast(graph.child_indices.items.len),
        .sym_count = @intCast(graph.symbol_offsets.items.len),
        .blob_bytes_len = graph.blobs.items.len,
        .eav_count = @intCast(graph.eav_index.spo.items.len),
        .type_count = @intCast(graph.type_table.entries.items.len),
        .content_xxh3 = 0,
        .reserved = 0,
    };

    // Placeholder for 64-byte header
    const header_slice = std.mem.asBytes(&header);
    out.appendSlice(allocator, header_slice) catch return error.OutOfMemory;

    const payload_start = out.items.len;

    // 1. Cells
    var i: usize = 0;
    while (i < graph.cell_count) : (i += 1) {
        const cell = graph.getCell(@intCast(i));
        const cell_bytes = std.mem.asBytes(&cell);
        out.appendSlice(allocator, cell_bytes) catch return error.OutOfMemory;
    }

    // 2. Child indices
    const child_bytes = std.mem.sliceAsBytes(graph.child_indices.items);
    out.appendSlice(allocator, child_bytes) catch return error.OutOfMemory;

    // 3. Symbol offsets & strings length and bytes
    const sym_offset_bytes = std.mem.sliceAsBytes(graph.symbol_offsets.items);
    out.appendSlice(allocator, sym_offset_bytes) catch return error.OutOfMemory;
    var sym_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sym_len_buf, @intCast(graph.symbols.items.len), .little);
    out.appendSlice(allocator, &sym_len_buf) catch return error.OutOfMemory;
    out.appendSlice(allocator, graph.symbols.items) catch return error.OutOfMemory;

    // 4. Blobs
    out.appendSlice(allocator, graph.blobs.items) catch return error.OutOfMemory;

    // 5. EAV SPO table
    const eav_bytes = std.mem.sliceAsBytes(graph.eav_index.spo.items);
    out.appendSlice(allocator, eav_bytes) catch return error.OutOfMemory;

    // Compute XXH3-64 checksum of payload
    const payload = out.items[payload_start..];
    const checksum = std.hash.XxHash3.hash(0, payload);

    header.content_xxh3 = checksum;
    @memcpy(out.items[0..64], std.mem.asBytes(&header));

    const result = allocator.alloc(u8, out.items.len) catch return error.OutOfMemory;
    @memcpy(result, out.items);
    return result;
}

pub fn deserializeGraph(bytes: []const u8, allocator: std.mem.Allocator) UrError!*UrGraph {
    if (bytes.len < @sizeOf(UrBinaryHeader)) return error.CorruptBinaryHeader;

    var header: UrBinaryHeader = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..64]);

    if (!std.mem.eql(u8, &header.magic, &URASG_MAGIC)) {
        return error.CorruptBinaryHeader;
    }

    const payload = bytes[64..];
    const actual_checksum = std.hash.XxHash3.hash(0, payload);
    if (actual_checksum != header.content_xxh3) {
        return error.ChecksumMismatch;
    }

    var graph = UrGraph.create(allocator) catch return error.OutOfMemory;
    errdefer graph.destroy();

    var offset: usize = 0;

    // 1. Read cells
    const cell_bytes_len = header.cell_count * @sizeOf(UrCell);
    if (offset + cell_bytes_len > payload.len) return error.CorruptBinaryHeader;

    // Reset cell_count and pre-allocated nil cell
    for (graph.pages.items) |p| allocator.destroy(p);
    graph.pages.clearRetainingCapacity();
    graph.cell_count = 0;

    var c_i: usize = 0;
    while (c_i < header.cell_count) : (c_i += 1) {
        var cell: UrCell = undefined;
        @memcpy(std.mem.asBytes(&cell), payload[offset .. offset + @sizeOf(UrCell)]);
        offset += @sizeOf(UrCell);
        _ = graph.allocCell(cell) catch return error.OutOfMemory;
    }

    // 2. Read child indices
    const child_bytes_len = header.child_idx_count * @sizeOf(CellIdx);
    if (offset + child_bytes_len > payload.len) return error.CorruptBinaryHeader;
    var ch_i: usize = 0;
    while (ch_i < header.child_idx_count) : (ch_i += 1) {
        const val = std.mem.readInt(CellIdx, payload[offset..][0..4], .little);
        offset += 4;
        graph.child_indices.append(allocator, val) catch return error.OutOfMemory;
    }

    // 3. Read symbol offsets & strings
    const sym_offset_len = header.sym_count * @sizeOf(u32);
    if (offset + sym_offset_len > payload.len) return error.CorruptBinaryHeader;
    var sym_i: usize = 0;
    while (sym_i < header.sym_count) : (sym_i += 1) {
        const val = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;
        graph.symbol_offsets.append(allocator, val) catch return error.OutOfMemory;
    }

    if (offset + 4 > payload.len) return error.CorruptBinaryHeader;
    const sym_bytes_len = std.mem.readInt(u32, payload[offset..][0..4], .little);
    offset += 4;

    if (offset + sym_bytes_len > payload.len) return error.CorruptBinaryHeader;
    const sym_bytes = payload[offset .. offset + sym_bytes_len];
    offset += sym_bytes_len;
    graph.symbols.appendSlice(allocator, sym_bytes) catch return error.OutOfMemory;

    // 4. Read blobs
    if (offset + header.blob_bytes_len > payload.len) return error.CorruptBinaryHeader;
    const blob_bytes = payload[offset .. offset + @as(usize, @intCast(header.blob_bytes_len))];
    offset += @as(usize, @intCast(header.blob_bytes_len));
    graph.blobs.appendSlice(allocator, blob_bytes) catch return error.OutOfMemory;

    // 5. Read EAV table
    const eav_bytes_len = header.eav_count * @sizeOf(EavRow);
    if (offset + eav_bytes_len <= payload.len) {
        var eav_i: usize = 0;
        while (eav_i < header.eav_count) : (eav_i += 1) {
            var row: EavRow = undefined;
            @memcpy(std.mem.asBytes(&row), payload[offset .. offset + @sizeOf(EavRow)]);
            offset += @sizeOf(EavRow);
            graph.eav_index.commitBitemporal(row.subject, row.predicate, row.object, row.tuple_cell, row.valid_from, row.invalidated_at) catch return error.OutOfMemory;
        }
    }

    return graph;
}

pub fn saveBinaryToFile(graph: *const UrGraph, root_idx: CellIdx, filepath: []const u8) UrError!void {
    if (builtin.os.tag == .freestanding) return error.InvalidSyntax;

    const bytes = try serializeGraph(graph, root_idx, graph.allocator);
    defer graph.allocator.free(bytes);

    var path_buf: [1024:0]u8 = undefined;
    if (filepath.len >= path_buf.len) return error.InvalidSyntax;
    @memcpy(path_buf[0..filepath.len], filepath);
    path_buf[filepath.len] = 0;

    const f = std.c.fopen(&path_buf, "wb") orelse return error.InvalidSyntax;
    defer _ = std.c.fclose(f);
    const written = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    if (written != bytes.len) return error.InvalidSyntax;
}

pub fn loadBinaryFromFile(filepath: []const u8, allocator: std.mem.Allocator) UrError!*UrGraph {
    if (builtin.os.tag == .freestanding) return error.InvalidSyntax;

    var path_buf: [1024:0]u8 = undefined;
    if (filepath.len >= path_buf.len) return error.InvalidSyntax;
    @memcpy(path_buf[0..filepath.len], filepath);
    path_buf[filepath.len] = 0;

    const f = std.c.fopen(&path_buf, "rb") orelse return error.InvalidSyntax;
    defer _ = std.c.fclose(f);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const read_bytes = std.c.fread(&chunk, 1, chunk.len, f);
        if (read_bytes == 0) break;
        buf.appendSlice(allocator, chunk[0..read_bytes]) catch return error.OutOfMemory;
    }

    return deserializeGraph(buf.items, allocator);
}

test "Zero-copy .urasg binary serialization and deserialization" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    const sym_tag = try graph.internSym("my_var");
    const int_c = try graph.allocCell(UrCell{
        .kind = .int_lit,
        .head_idx = sym_tag,
        .payload = .{ .imm_i64 = 777 },
    });
    const blob_payload = try graph.allocBlob("binary_data_payload");
    const blob_c = try graph.allocCell(UrCell{
        .kind = .bytes_blob,
        .payload = .{ .raw = blob_payload },
    });

    const root = try graph.allocCell(UrCell{ .kind = .unit_def, .head_idx = sym_tag });
    const slice = try graph.allocChildren(&.{ int_c, blob_c }, root);
    var root_cell = graph.getCell(root);
    root_cell.payload.slice = slice;
    try graph.mutateCell(root, root_cell);

    const serialized = try serializeGraph(graph, root, allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 64);
    try std.testing.expect(std.mem.startsWith(u8, serialized, &URASG_MAGIC));

    var loaded = try deserializeGraph(serialized, allocator);
    defer loaded.destroy();

    try std.testing.expectEqual(graph.cell_count, loaded.cell_count);
    const loaded_root = loaded.getCell(root);
    try std.testing.expectEqual(UrKind.unit_def, loaded_root.kind);

    const children = loaded.getChildren(loaded_root.payload.slice.start, loaded_root.payload.slice.len);
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqual(@as(i64, 777), loaded.getCell(children[0]).payload.imm_i64);
}
