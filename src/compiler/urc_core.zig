const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const ext_mod = @import("ext_api.zig");
const UrCompilerExtension = ext_mod.UrCompilerExtension;
const UrIntrinsicEntry = ext_mod.UrIntrinsicEntry;

pub const FEAT_SAMPLE_ORACLE: u64 = 1 << 0;
pub const FEAT_HAZEL_MEMBRANES: u64 = 1 << 1;
pub const FEAT_LOBSTER_RC: u64 = 1 << 2;
pub const FEAT_AUTOFREE_ARENA: u64 = 1 << 3;
pub const FEAT_BEEF_MIXED_OPT: u64 = 1 << 4;
pub const FEAT_RELATIONAL_SIMD: u64 = 1 << 5;
pub const FEAT_MMIO_CAPABILITIES: u64 = 1 << 6;
pub const FEAT_UNCERTAIN_AUTODIFF: u64 = 1 << 7;
pub const URC_DIAG_REPORT_ESCAPES: u64 = 1 << 8;

pub const DEFAULT_FEATURES: u64 = FEAT_SAMPLE_ORACLE | FEAT_HAZEL_MEMBRANES;

pub const PinnedBuiltin = struct {
    merkle_hash: u64,
    native_fn_ptr: ?*const anyopaque = null,
    tier: u8 = 2,
};

pub const UrCompiler = struct {
    allocator: std.mem.Allocator,
    graph: *UrGraph,
    features: u64,
    extensions: std.ArrayListUnmanaged(UrCompilerExtension) = .empty,
    intrinsics: std.ArrayListUnmanaged(UrIntrinsicEntry) = .empty,
    pinned_builtins: std.AutoHashMapUnmanaged(u64, PinnedBuiltin) = .empty,
    ffi_call_time_ns: u64 = 0,
    cell_eval_time_ns: u64 = 0,

    pub fn create(graph: *UrGraph, features: u64) !*UrCompiler {
        const self = try graph.allocator.create(UrCompiler);
        self.* = .{
            .allocator = graph.allocator,
            .graph = graph,
            .features = features,
            .extensions = .empty,
            .intrinsics = .empty,
            .pinned_builtins = .empty,
            .ffi_call_time_ns = 0,
            .cell_eval_time_ns = 0,
        };
        return self;
    }

    pub fn destroy(self: *UrCompiler) void {
        self.extensions.deinit(self.allocator);
        self.intrinsics.deinit(self.allocator);
        self.pinned_builtins.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn registerExtension(self: *UrCompiler, ext: UrCompilerExtension) !void {
        try self.extensions.append(self.allocator, ext);
    }

    pub fn findExtension(self: *const UrCompiler, opcode: u8) ?UrCompilerExtension {
        for (self.extensions.items) |ext| {
            if (opcode >= ext.opcode_range_start and opcode <= ext.opcode_range_end) {
                return ext;
            }
        }
        return null;
    }

    pub fn profileDilation(self: *const UrCompiler, _: CellIdx) f64 {
        const total = self.cell_eval_time_ns + self.ffi_call_time_ns;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.cell_eval_time_ns)) / @as(f64, @floatFromInt(total));
    }
};

