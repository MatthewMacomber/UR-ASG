const std = @import("std");

pub const CellIdx = u32;
pub const NULL_CELL: CellIdx = 0;
pub const TypeId = u16;
pub const SymId = u32;
pub const EntityId = u32;

pub const UrKind = enum(u8) {
    // 0x00..0x1F: Atoms & Literals
    nil_cell = 0x00,
    bool_lit = 0x01,
    int_lit = 0x02,
    float_lit = 0x03,
    fixed_q16_16 = 0x04,
    uncertain_f32 = 0x05,
    sym_atom = 0x06,
    bytes_blob = 0x07,

    // 0x20..0x3F: Homoiconic Graph, Control, SSA & Memory Nodes
    unit_def = 0x20,
    call_node = 0x21,
    let_bind = 0x22,
    if_branch = 0x23,
    match_switch = 0x24,
    loop_repeat = 0x25,
    fiber_yield = 0x26,
    return_ok = 0x27,
    try_or_err = 0x28,
    ssa_phi = 0x29,
    simd_kernel = 0x2A,
    cyclic_backref = 0x2B,
    scope_free = 0x2C,
    rc_adjust = 0x2D,
    gen_guard_check = 0x2E,
    list_node = 0x2F,
    grad_adjoint = 0x30,
    arena_promote = 0x31,
    borrow_ref = 0x32,
    move_transfer = 0x33,

    // 0x40..0x5F: Relational EAV, Matrix & Dataflow Nodes
    eav_tuple = 0x40,
    query_search = 0x41,
    query_bind = 0x42,
    query_commit = 0x43,
    mech_table = 0x44,
    mech_fsm_transition = 0x45,
    shard_port = 0x46,
    shard_wire = 0x47,
    bitemporal_edge = 0x48,

    // 0x60..0x7F: Live Contracts, Typed Holes & Hardware Capabilities
    needs_stub = 0x60,
    sample_io_row = 0x61,
    hoist_step = 0x62,
    showboat_proof = 0x63,
    hazel_hole = 0x64,
    hazel_membrane = 0x65,
    mmio_capability = 0x66,
    irq_capability = 0x67,

    // Non-exhaustive to allow 0x80..0xFF host domain opcodes
    _,
};

pub const UrMemStrategy = enum(u3) {
    vlang_autofree = 0,
    lobster_rc = 1,
    beef_guarded = 2,
    raw_manual = 3,
    frame_arena = 4,
    cow_gc = 5,
    _,
};

pub const UrFlags = packed struct(u8) {
    dirty: bool = true,
    cyclic_anchor: bool = false,
    cyclic_ref: bool = false,
    verified: bool = false,
    pinned_builtin: bool = false,
    mem_strategy: UrMemStrategy = .vlang_autofree,
};

pub const UrSliceDesc = extern struct {
    start: u32,
    len: u32,
};

pub const UrEavDesc = extern struct {
    predicate_sym: u32,
    object_idx: u32,
};

pub const UrUncertainDesc = extern struct {
    mean: f32,
    std_dev: f32,
};

pub const UrBitemporalDesc = extern struct {
    valid_from: u32,
    invalidated_at: u32,
};

pub const UrCapabilityDesc = extern struct {
    base_addr: u32,
    byte_len: u32,
};

pub const UrMembraneDesc = extern struct {
    inner_cell: u32,
    expected_type: u16,
    actual_type: u16,
};

pub const UrPayload = extern union {
    raw: u64,
    imm_i64: i64,
    imm_f64: f64,
    q32_32: i64,
    uncertain: UrUncertainDesc,
    slice: UrSliceDesc,
    eav: UrEavDesc,
    bitemporal: UrBitemporalDesc,
    capability: UrCapabilityDesc,
    membrane: UrMembraneDesc,
};

pub const UrCell = extern struct {
    kind: UrKind align(16) = .nil_cell,
    flags: UrFlags = .{},
    type_id: TypeId = BuiltinType.any_type,
    head_idx: CellIdx = NULL_CELL,
    payload: UrPayload = .{ .raw = 0 },

    comptime {
        std.debug.assert(@sizeOf(UrCell) == 16);
        std.debug.assert(@alignOf(UrCell) == 16);
        std.debug.assert(@offsetOf(UrCell, "kind") == 0);
        std.debug.assert(@offsetOf(UrCell, "flags") == 1);
        std.debug.assert(@offsetOf(UrCell, "type_id") == 2);
        std.debug.assert(@offsetOf(UrCell, "head_idx") == 4);
        std.debug.assert(@offsetOf(UrCell, "payload") == 8);
    }
};

// Deterministic Q16.16 fixed point helpers
pub const Q16_16 = struct {
    pub inline fn fromF32(v: f32) i32 {
        return @intFromFloat(v * 65536.0);
    }

    pub inline fn toF32(raw: i32) f32 {
        return @as(f32, @floatFromInt(raw)) / 65536.0;
    }

    pub inline fn add(a: i32, b: i32) i32 {
        return a +% b;
    }

    pub inline fn sub(a: i32, b: i32) i32 {
        return a -% b;
    }

    pub inline fn mul(a: i32, b: i32) i32 {
        const prod = @as(i64, a) * @as(i64, b);
        return @truncate(prod >> 16);
    }

    pub inline fn div(a: i32, b: i32) i32 {
        if (b == 0) return 0;
        const num = @as(i64, a) << 16;
        return @truncate(@divTrunc(num, b));
    }
};

// Probabilistic Uncertain(F32) with Gaussian error propagation
pub const UncertainF32 = struct {
    mean: f32,
    std_dev: f32,

    pub fn init(mean: f32, std_dev: f32) UncertainF32 {
        return .{ .mean = mean, .std_dev = std_dev };
    }

    pub fn fromPayload(p: UrPayload) UncertainF32 {
        return .{
            .mean = p.uncertain.mean,
            .std_dev = p.uncertain.std_dev,
        };
    }

    pub fn toPayload(self: UncertainF32) UrPayload {
        return .{
            .uncertain = .{
                .mean = self.mean,
                .std_dev = self.std_dev,
            },
        };
    }

    pub fn add(a: UncertainF32, b: UncertainF32) UncertainF32 {
        return .{
            .mean = a.mean + b.mean,
            .std_dev = @sqrt(a.std_dev * a.std_dev + b.std_dev * b.std_dev),
        };
    }

    pub fn sub(a: UncertainF32, b: UncertainF32) UncertainF32 {
        return .{
            .mean = a.mean - b.mean,
            .std_dev = @sqrt(a.std_dev * a.std_dev + b.std_dev * b.std_dev),
        };
    }

    pub fn mul(a: UncertainF32, b: UncertainF32) UncertainF32 {
        const m = a.mean * b.mean;
        const s2 = (b.mean * b.mean * a.std_dev * a.std_dev) +
            (a.mean * a.mean * b.std_dev * b.std_dev);
        return .{
            .mean = m,
            .std_dev = @sqrt(s2),
        };
    }

    pub fn div(a: UncertainF32, b: UncertainF32) UncertainF32 {
        if (b.mean == 0.0) return .{ .mean = 0, .std_dev = 0 };
        const m = a.mean / b.mean;
        const s2 = (a.std_dev * a.std_dev) / (b.mean * b.mean) +
            (a.mean * a.mean * b.std_dev * b.std_dev) / (b.mean * b.mean * b.mean * b.mean);
        return .{
            .mean = m,
            .std_dev = @sqrt(s2),
        };
    }
};

// Builtin structural type IDs
pub const BuiltinType = struct {
    pub const nil_type: TypeId = 0;
    pub const void_type: TypeId = 1;
    pub const bool_type: TypeId = 2;
    pub const int_type: TypeId = 3;
    pub const float_type: TypeId = 4;
    pub const fixed_q16_16_type: TypeId = 5;
    pub const uncertain_f32_type: TypeId = 6;
    pub const sym_type: TypeId = 7;
    pub const bytes_type: TypeId = 8;
    pub const string_type: TypeId = 9;
    pub const any_type: TypeId = 10;
    pub const hole_type: TypeId = 11;
    pub const error_type: TypeId = 12;
    pub const user_type_start: TypeId = 32;
};

// Interned structural type definition
pub const UrTypeKind = enum(u8) {
    primitive = 0,
    result = 1,
    uncertain = 2,
    slice = 3,
    ptr = 4,
    record = 5,
    mmio_cap = 6,
    irq_cap = 7,
};

pub const UrTypeEntry = struct {
    name_sym: SymId = 0,
    kind: UrTypeKind = .primitive,
    param1: TypeId = 0, // e.g. ok_type or elem_type
    param2: TypeId = 0, // e.g. err_type
    aux_id: u32 = 0, // e.g. mmio base address or struct field hash
};

pub const UrTypeTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(UrTypeEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) UrTypeTable {
        var self = UrTypeTable{
            .allocator = allocator,
            .entries = .empty,
        };
        // Seed standard built-ins
        self.entries.ensureTotalCapacity(allocator, BuiltinType.user_type_start) catch {};
        var i: usize = 0;
        while (i < BuiltinType.user_type_start) : (i += 1) {
            self.entries.append(allocator, .{
                .name_sym = @intCast(i),
                .kind = .primitive,
                .param1 = 0,
                .param2 = 0,
                .aux_id = 0,
            }) catch {};
        }
        return self;
    }

    pub fn deinit(self: *UrTypeTable) void {
        self.entries.deinit(self.allocator);
    }

    pub fn internType(self: *UrTypeTable, entry: UrTypeEntry) !TypeId {
        for (self.entries.items, 0..) |existing, idx| {
            if (existing.kind == entry.kind and
                existing.param1 == entry.param1 and
                existing.param2 == entry.param2 and
                existing.aux_id == entry.aux_id and
                existing.name_sym == entry.name_sym)
            {
                return @intCast(idx);
            }
        }
        const new_id: TypeId = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, entry);
        return new_id;
    }

    pub fn getType(self: *const UrTypeTable, id: TypeId) ?UrTypeEntry {
        if (id < self.entries.items.len) {
            return self.entries.items[id];
        }
        return null;
    }
};

test "UrCell 16-byte layout and alignment" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(UrCell));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(UrCell));

    const cell = UrCell{
        .kind = .int_lit,
        .flags = .{
            .dirty = true,
            .cyclic_anchor = false,
            .cyclic_ref = false,
            .verified = true,
            .pinned_builtin = false,
            .mem_strategy = .vlang_autofree,
        },
        .type_id = BuiltinType.int_type,
        .head_idx = 42,
        .payload = .{ .imm_i64 = -123456789 },
    };

    try std.testing.expect(cell.flags.dirty);
    try std.testing.expect(cell.flags.verified);
    try std.testing.expectEqual(@as(i64, -123456789), cell.payload.imm_i64);
}

test "Fixed Q16.16 and UncertainF32 math" {
    const q1 = Q16_16.fromF32(3.5);
    const q2 = Q16_16.fromF32(2.0);
    const q_mul = Q16_16.mul(q1, q2);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), Q16_16.toF32(q_mul), 0.001);

    const unc1 = UncertainF32.init(10.0, 1.0);
    const unc2 = UncertainF32.init(20.0, 2.0);
    const u_add = UncertainF32.add(unc1, unc2);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), u_add.mean, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(5.0)), u_add.std_dev, 0.001);
}
