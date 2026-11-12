const std = @import("std");
const cell_mod = @import("cell.zig");
const CellIdx = cell_mod.CellIdx;
const TypeId = cell_mod.TypeId;
const graph_mod = @import("graph_store.zig");
const UrGraph = graph_mod.UrGraph;

pub const UrError = error{
    OutOfMemory,
    InvalidSyntax,
    UnresolvedCyclicRef,
    InvalidCellIdx,
    TypeMismatch,
    CapabilityViolation,
    CorruptBinaryHeader,
    ChecksumMismatch,
    UnimplementedOpcode,
    OracleNoSampleMatch,
    UseAfterFreeTrap,
    DoubleFreeTrap,
    MemoryLeakTrap,
    EvaluationError,
    BufferTooSmall,
};

pub const SourceSpan = struct {
    cell_idx: CellIdx,
    start: usize,
    end: usize,
};

pub const UrTokenStream = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    spans: std.ArrayListUnmanaged(SourceSpan) = .empty,

    pub fn init(allocator: std.mem.Allocator) UrTokenStream {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .spans = .empty,
        };
    }

    pub fn deinit(self: *UrTokenStream) void {
        self.buf.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    pub fn write(self: *UrTokenStream, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *UrTokenStream, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    pub fn recordSpan(self: *UrTokenStream, cell_idx: CellIdx, start: usize, end: usize) !void {
        try self.spans.append(self.allocator, .{
            .cell_idx = cell_idx,
            .start = start,
            .end = end,
        });
    }

    pub fn getOutput(self: *const UrTokenStream) []const u8 {
        return self.buf.items;
    }
};

pub const TypeDiffStatus = enum {
    exact,
    coercible,
    needs_membrane,
    incompatible,
};

pub const TypeDiff = struct {
    status: TypeDiffStatus,
    expected_type: TypeId,
    actual_type: TypeId,
};

pub const LowerTarget = enum {
    zig_freestanding,
    c99_portable,
    wasm32_binary,
    spirv_shader,
    register_bytecode,
};

pub const UrLensVTable = struct {
    dialect_name: []const u8,
    project_to_surface: *const fn (graph: *const UrGraph, root: CellIdx, out: *UrTokenStream) UrError!void,
    parse_into_graph: *const fn (graph: *UrGraph, target: CellIdx, src: []const u8) UrError!CellIdx,
    compute_type_diff: *const fn (graph: *const UrGraph, hole_idx: CellIdx, plug_idx: CellIdx) TypeDiff,
    lower_subgraph: ?*const fn (graph: *const UrGraph, root: CellIdx, target: LowerTarget) UrError![]const u8 = null,
};

