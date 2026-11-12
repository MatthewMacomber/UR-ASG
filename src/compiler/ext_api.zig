const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const TypeId = cell_mod.TypeId;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;

pub const UrEvalEnv = struct {
    allocator: std.mem.Allocator,
    locals: std.AutoHashMapUnmanaged(CellIdx, CellIdx) = .empty,
    scratch_cells: std.ArrayListUnmanaged(CellIdx) = .empty,
    generation_guards: std.AutoHashMapUnmanaged(CellIdx, u32) = .empty,
    freed_cells: std.AutoHashMapUnmanaged(CellIdx, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) UrEvalEnv {
        return .{
            .allocator = allocator,
            .locals = .empty,
            .scratch_cells = .empty,
            .generation_guards = .empty,
            .freed_cells = .empty,
        };
    }

    pub fn deinit(self: *UrEvalEnv) void {
        self.locals.deinit(self.allocator);
        self.scratch_cells.deinit(self.allocator);
        self.generation_guards.deinit(self.allocator);
        self.freed_cells.deinit(self.allocator);
    }
};

pub const UrCodegenBuilder = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) UrCodegenBuilder {
        return .{
            .allocator = allocator,
            .out = .empty,
        };
    }

    pub fn deinit(self: *UrCodegenBuilder) void {
        self.out.deinit(self.allocator);
    }

    pub fn write(self: *UrCodegenBuilder, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }
};

pub const UrCompilerExtension = struct {
    ext_name: []const u8,
    opcode_range_start: u8 = 0x80,
    opcode_range_end: u8 = 0xFF,
    typecheck_domain_cell: ?*const fn (g: *UrGraph, idx: CellIdx) UrError!TypeId = null,
    eval_domain_cell: ?*const fn (g: *UrGraph, idx: CellIdx, env: *UrEvalEnv) UrError!CellIdx = null,
    run_custom_rewrite_pass: ?*const fn (g: *UrGraph, unit_root: CellIdx) UrError!bool = null,
    emit_domain_codegen: ?*const fn (g: *const UrGraph, idx: CellIdx, out: *UrCodegenBuilder) UrError!void = null,
};

pub const UrIntrinsicEntry = struct {
    name: []const u8,
    func_ptr: *const anyopaque,
    cost_weight: f64 = 1.0,
    total_calls: u64 = 0,
    total_time_ns: u64 = 0,
};

