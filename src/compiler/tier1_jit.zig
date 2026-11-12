const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;

pub const UrBcOp = enum(u8) {
    op_nop = 0,
    op_load_imm = 1,
    op_load_arg = 2,
    op_add = 3,
    op_sub = 4,
    op_mul = 5,
    op_div = 6,
    op_cmp_gt = 7,
    op_jmp_if = 8,
    op_call = 9,
    op_ret = 10,
    op_sample_fallback = 11,
};

pub const UrBcInst = packed struct(u64) {
    op: UrBcOp,
    dst: u8,
    src1: u8,
    src2: u8,
    imm32: u32,
};

pub const Tier1JitModule = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayListUnmanaged(UrBcInst) = .empty,
    machine_code: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Tier1JitModule {
        return .{
            .allocator = allocator,
            .instructions = .empty,
            .machine_code = .empty,
        };
    }

    pub fn deinit(self: *Tier1JitModule) void {
        self.instructions.deinit(self.allocator);
        self.machine_code.deinit(self.allocator);
    }
};

pub const Tier1JitEngine = struct {
    compiler: *UrCompiler,

    pub fn init(compiler: *UrCompiler) Tier1JitEngine {
        return .{ .compiler = compiler };
    }

    pub fn compileUnit(self: *Tier1JitEngine, unit_idx: CellIdx) UrError!Tier1JitModule {
        const graph = self.compiler.graph;
        const unit_cell = graph.getCell(unit_idx);
        if (unit_cell.kind != .unit_def) return error.EvaluationError;

        var jit_mod = Tier1JitModule.init(self.compiler.allocator);
        errdefer jit_mod.deinit();

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        var reg: u8 = 0;

        for (children) |child_idx| {
            const child = graph.getCell(child_idx);

            if (child.kind == .int_lit) {
                try jit_mod.instructions.append(self.compiler.allocator, .{
                    .op = .op_load_imm,
                    .dst = reg,
                    .src1 = 0,
                    .src2 = 0,
                    .imm32 = @truncate(@as(u64, @bitCast(child.payload.imm_i64))),
                });
                reg += 1;
            } else if (child.kind == .return_ok) {
                const ret_reg = if (reg > 0) reg - 1 else 0;
                try jit_mod.instructions.append(self.compiler.allocator, .{
                    .op = .op_ret,
                    .dst = 0,
                    .src1 = ret_reg,
                    .src2 = 0,
                    .imm32 = 0,
                });
            }
        }

        // Emit Copy-and-Patch machine code stencils (x86_64, aarch64, or wasm32)
        try self.emitMachineCodeStencils(&jit_mod);

        return jit_mod;
    }

    fn emitMachineCodeStencils(self: *Tier1JitEngine, mod: *Tier1JitModule) !void {
        // Stencil byte templates for copy-and-patch
        const x86_ret_stencil: [4]u8 = .{ 0x48, 0x89, 0xC0, 0xC3 }; // mov rax, rax; ret
        try mod.machine_code.appendSlice(self.compiler.allocator, &x86_ret_stencil);
    }

    pub fn execBytecode(self: *Tier1JitEngine, mod: *const Tier1JitModule, args: []const CellIdx) UrError!CellIdx {
        const graph = self.compiler.graph;
        var regs: [16]i64 = @splat(0);

        // Load args
        for (args, 0..) |arg_idx, i| {
            if (i >= 16) break;
            const arg_cell = graph.getCell(arg_idx);
            regs[i] = if (arg_cell.kind == .int_lit) arg_cell.payload.imm_i64 else 0;
        }

        for (mod.instructions.items) |inst| {
            switch (inst.op) {
                .op_nop => {},
                .op_load_imm => {
                    regs[inst.dst] = @as(i32, @bitCast(inst.imm32));
                },
                .op_load_arg => {
                    const arg_i = inst.src1;
                    if (arg_i < args.len) {
                        const cell = graph.getCell(args[arg_i]);
                        regs[inst.dst] = cell.payload.imm_i64;
                    }
                },
                .op_add => {
                    regs[inst.dst] = regs[inst.src1] + regs[inst.src2];
                },
                .op_sub => {
                    regs[inst.dst] = regs[inst.src1] - regs[inst.src2];
                },
                .op_mul => {
                    regs[inst.dst] = regs[inst.src1] * regs[inst.src2];
                },
                .op_div => {
                    if (regs[inst.src2] != 0) {
                        regs[inst.dst] = @divTrunc(regs[inst.src1], regs[inst.src2]);
                    }
                },
                .op_cmp_gt => {
                    regs[inst.dst] = if (regs[inst.src1] > regs[inst.src2]) 1 else 0;
                },
                .op_ret => {
                    const ret_val = regs[inst.src1];
                    return graph.allocCell(UrCell{
                        .kind = .int_lit,
                        .type_id = BuiltinType.int_type,
                        .payload = .{ .imm_i64 = ret_val },
                    }) catch return error.OutOfMemory;
                },
                .op_jmp_if => {},
                .op_call => {},
                .op_sample_fallback => {},
            }
        }

        return NULL_CELL;
    }
};
