const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const EntityId = cell_mod.EntityId;
const SymId = cell_mod.SymId;

pub const EavRow = struct {
    subject: EntityId,
    predicate: SymId,
    object: CellIdx,
    tuple_cell: CellIdx,
    valid_from: u32 = 0,
    invalidated_at: u32 = 0, // 0 means currently valid (no expiration)

    pub fn isValidAt(self: EavRow, timestamp: u32) bool {
        if (self.valid_from > timestamp) return false;
        if (self.invalidated_at != 0 and timestamp >= self.invalidated_at) return false;
        return true;
    }
};

fn compareSpo(_: void, a: EavRow, b: EavRow) bool {
    if (a.subject != b.subject) return a.subject < b.subject;
    if (a.predicate != b.predicate) return a.predicate < b.predicate;
    if (a.object != b.object) return a.object < b.object;
    return a.valid_from < b.valid_from;
}

fn comparePos(_: void, a: EavRow, b: EavRow) bool {
    if (a.predicate != b.predicate) return a.predicate < b.predicate;
    if (a.object != b.object) return a.object < b.object;
    if (a.subject != b.subject) return a.subject < b.subject;
    return a.valid_from < b.valid_from;
}

pub const UrEavIndex = struct {
    allocator: std.mem.Allocator,
    spo: std.ArrayListUnmanaged(EavRow) = .empty,
    pos: std.ArrayListUnmanaged(EavRow) = .empty,

    pub fn init(allocator: std.mem.Allocator) UrEavIndex {
        return .{
            .allocator = allocator,
            .spo = .empty,
            .pos = .empty,
        };
    }

    pub fn deinit(self: *UrEavIndex) void {
        self.spo.deinit(self.allocator);
        self.pos.deinit(self.allocator);
    }

    pub fn clone(self: *const UrEavIndex, allocator: std.mem.Allocator) !UrEavIndex {
        var copy = UrEavIndex.init(allocator);
        try copy.spo.appendSlice(allocator, self.spo.items);
        try copy.pos.appendSlice(allocator, self.pos.items);
        return copy;
    }

    pub fn commitEav(self: *UrEavIndex, subject: EntityId, predicate: SymId, object: CellIdx, tuple_cell: CellIdx) !void {
        try self.commitBitemporal(subject, predicate, object, tuple_cell, 0, 0);
    }

    pub fn commitBitemporal(
        self: *UrEavIndex,
        subject: EntityId,
        predicate: SymId,
        object: CellIdx,
        tuple_cell: CellIdx,
        valid_from: u32,
        invalidated_at: u32,
    ) !void {
        const row = EavRow{
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .tuple_cell = tuple_cell,
            .valid_from = valid_from,
            .invalidated_at = invalidated_at,
        };

        // Binary search insertion index in spo
        var low: usize = 0;
        var high: usize = self.spo.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (compareSpo({}, self.spo.items[mid], row)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        try self.spo.insert(self.allocator, low, row);

        // Binary search insertion index in pos
        low = 0;
        high = self.pos.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (comparePos({}, self.pos.items[mid], row)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        try self.pos.insert(self.allocator, low, row);
    }

    pub fn querySpo(self: *const UrEavIndex, subject: EntityId, predicate: SymId) ?CellIdx {
        // Find matching range in spo
        var result: ?CellIdx = null;
        var max_valid_from: u32 = 0;

        for (self.spo.items) |row| {
            if (row.subject == subject and row.predicate == predicate) {
                if (row.invalidated_at == 0 or row.invalidated_at > max_valid_from) {
                    if (result == null or row.valid_from >= max_valid_from) {
                        result = row.object;
                        max_valid_from = row.valid_from;
                    }
                }
            } else if (row.subject > subject) {
                break;
            }
        }
        return result;
    }

    pub fn queryBitemporal(self: *const UrEavIndex, subject: EntityId, predicate: SymId, timestamp: u32) ?CellIdx {
        var result: ?CellIdx = null;
        var max_valid_from: u32 = 0;

        for (self.spo.items) |row| {
            if (row.subject == subject and row.predicate == predicate) {
                if (row.isValidAt(timestamp)) {
                    if (result == null or row.valid_from >= max_valid_from) {
                        result = row.object;
                        max_valid_from = row.valid_from;
                    }
                }
            } else if (row.subject > subject) {
                break;
            }
        }
        return result;
    }

    pub fn scanEntityAttributes(self: *const UrEavIndex, subject: EntityId) []const EavRow {
        var start: usize = self.spo.items.len;
        var end: usize = self.spo.items.len;

        for (self.spo.items, 0..) |row, idx| {
            if (row.subject == subject) {
                if (start == self.spo.items.len) start = idx;
                end = idx + 1;
            } else if (row.subject > subject) {
                break;
            }
        }

        if (start < end) {
            return self.spo.items[start..end];
        }
        return &.{};
    }

    pub fn scanByPredicate(self: *const UrEavIndex, predicate: SymId) []const EavRow {
        var start: usize = self.pos.items.len;
        var end: usize = self.pos.items.len;

        for (self.pos.items, 0..) |row, idx| {
            if (row.predicate == predicate) {
                if (start == self.pos.items.len) start = idx;
                end = idx + 1;
            } else if (row.predicate > predicate) {
                break;
            }
        }

        if (start < end) {
            return self.pos.items[start..end];
        }
        return &.{};
    }

    pub fn queryPos(self: *const UrEavIndex, predicate: SymId, object: CellIdx) []const EavRow {
        var start: usize = self.pos.items.len;
        var end: usize = self.pos.items.len;

        for (self.pos.items, 0..) |row, idx| {
            if (row.predicate == predicate and row.object == object) {
                if (start == self.pos.items.len) start = idx;
                end = idx + 1;
            } else if (row.predicate > predicate or (row.predicate == predicate and row.object > object)) {
                break;
            }
        }

        if (start < end) {
            return self.pos.items[start..end];
        }
        return &.{};
    }
};

test "UrEavIndex basic and bitemporal queries" {
    const allocator = std.testing.allocator;
    var index = UrEavIndex.init(allocator);
    defer index.deinit();

    const entity_ship: EntityId = 101;
    const entity_station: EntityId = 102;
    const sym_hp: SymId = 10;
    const sym_pos: SymId = 11;

    try index.commitEav(entity_ship, sym_hp, 50, 1);
    try index.commitEav(entity_ship, sym_pos, 100, 2);
    try index.commitEav(entity_station, sym_hp, 999, 3);

    try std.testing.expectEqual(@as(?CellIdx, 50), index.querySpo(entity_ship, sym_hp));
    try std.testing.expectEqual(@as(?CellIdx, 100), index.querySpo(entity_ship, sym_pos));
    try std.testing.expectEqual(@as(?CellIdx, 999), index.querySpo(entity_station, sym_hp));
    try std.testing.expectEqual(@as(?CellIdx, null), index.querySpo(entity_station, sym_pos));

    const ship_attrs = index.scanEntityAttributes(entity_ship);
    try std.testing.expectEqual(@as(usize, 2), ship_attrs.len);

    const hp_matches = index.scanByPredicate(sym_hp);
    try std.testing.expectEqual(@as(usize, 2), hp_matches.len);

    // Test Bitemporal edge
    const entity_oracle: EntityId = 200;
    const sym_state: SymId = 20;
    // State 1 active from t=0 to t=10
    try index.commitBitemporal(entity_oracle, sym_state, 1001, 10, 0, 10);
    // State 2 active from t=10 onwards
    try index.commitBitemporal(entity_oracle, sym_state, 1002, 11, 10, 0);

    try std.testing.expectEqual(@as(?CellIdx, 1001), index.queryBitemporal(entity_oracle, sym_state, 5));
    try std.testing.expectEqual(@as(?CellIdx, 1002), index.queryBitemporal(entity_oracle, sym_state, 15));
}
