const std = @import("std");
const cell_mod = @import("../cell.zig");
const CellIdx = cell_mod.CellIdx;
const NULL_CELL = cell_mod.NULL_CELL;
const SymId = cell_mod.SymId;
const UrCell = cell_mod.UrCell;
const UrKind = cell_mod.UrKind;
const BuiltinType = cell_mod.BuiltinType;
const graph_mod = @import("../graph_store.zig");
const UrGraph = graph_mod.UrGraph;
const lens_mod = @import("../lens_api.zig");
const UrError = lens_mod.UrError;
const sexpr_lens = @import("../sexpr_lens.zig");
const urc_mod = @import("urc_core.zig");
const UrCompiler = urc_mod.UrCompiler;
const ext_mod = @import("ext_api.zig");
const tier0_mod = @import("tier0_eval.zig");
const Tier0Evaluator = tier0_mod.Tier0Evaluator;

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
    op_mov = 12,
};

pub const UrBcInst = packed struct(u64) {
    op: UrBcOp,
    dst: u8,
    src1: u8,
    src2: u8,
    imm32: u32,
};

/// Pure-Zig x86_64 encoder ported from Aether archive/aetherv4_native/src/backend_x86.zig.
pub const Register = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub fn isExtended(self: Register) bool {
        return @intFromEnum(self) >= 8;
    }

    pub fn low3(self: Register) u3 {
        return @truncate(@intFromEnum(self));
    }
};

pub const X86Emitter = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) X86Emitter {
        return .{ .code = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *X86Emitter) void {
        self.code.deinit(self.allocator);
    }

    pub fn emitByte(self: *X86Emitter, b: u8) !void {
        try self.code.append(self.allocator, b);
    }

    pub fn emitBytes(self: *X86Emitter, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    pub fn emitI32(self: *X86Emitter, val: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, val, .little);
        try self.emitBytes(&buf);
    }

    pub fn push(self: *X86Emitter, reg: Register) !void {
        if (reg.isExtended()) try self.emitByte(0x41);
        try self.emitByte(0x50 + @as(u8, reg.low3()));
    }

    pub fn pop(self: *X86Emitter, reg: Register) !void {
        if (reg.isExtended()) try self.emitByte(0x41);
        try self.emitByte(0x58 + @as(u8, reg.low3()));
    }

    pub fn prolog(self: *X86Emitter) !void {
        try self.push(.rbp);
        try self.emitBytes(&[_]u8{ 0x48, 0x89, 0xE5 }); // mov rbp, rsp
    }

    pub fn epilog(self: *X86Emitter) !void {
        try self.emitBytes(&[_]u8{ 0x48, 0x89, 0xEC }); // mov rsp, rbp
        try self.pop(.rbp);
        try self.emitByte(0xC3); // ret
    }

    pub fn mov_reg_imm32(self: *X86Emitter, dst: Register, imm: i32) !void {
        var rex: u8 = 0x48;
        if (dst.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitByte(0xC7); // MOV r/m64, sign-ext imm32
        try self.emitByte(0xC0 | @as(u8, dst.low3()));
        try self.emitI32(imm);
    }

    pub fn mov_reg_reg(self: *X86Emitter, dst: Register, src: Register) !void {
        var rex: u8 = 0x48;
        if (src.isExtended()) rex |= 0x04;
        if (dst.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitByte(0x89);
        try self.emitByte(0xC0 | (@as(u8, src.low3()) << 3) | dst.low3());
    }

    pub fn add_reg_reg(self: *X86Emitter, dst: Register, src: Register) !void {
        var rex: u8 = 0x48;
        if (src.isExtended()) rex |= 0x04;
        if (dst.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitByte(0x01);
        try self.emitByte(0xC0 | (@as(u8, src.low3()) << 3) | dst.low3());
    }

    pub fn sub_reg_reg(self: *X86Emitter, dst: Register, src: Register) !void {
        var rex: u8 = 0x48;
        if (src.isExtended()) rex |= 0x04;
        if (dst.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitByte(0x29);
        try self.emitByte(0xC0 | (@as(u8, src.low3()) << 3) | dst.low3());
    }

    pub fn imul_reg_reg(self: *X86Emitter, dst: Register, src: Register) !void {
        var rex: u8 = 0x48;
        if (dst.isExtended()) rex |= 0x04;
        if (src.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitBytes(&[_]u8{ 0x0F, 0xAF });
        try self.emitByte(0xC0 | (@as(u8, dst.low3()) << 3) | src.low3());
    }

    pub fn cmp_reg_reg(self: *X86Emitter, r1: Register, r2: Register) !void {
        var rex: u8 = 0x48;
        if (r2.isExtended()) rex |= 0x04;
        if (r1.isExtended()) rex |= 0x01;
        try self.emitByte(rex);
        try self.emitByte(0x39);
        try self.emitByte(0xC0 | (@as(u8, r2.low3()) << 3) | r1.low3());
    }

    pub fn setcc_gt_rax(self: *X86Emitter) !void {
        try self.emitBytes(&[_]u8{ 0x0F, 0x9F, 0xC0 }); // setg al
        try self.emitBytes(&[_]u8{ 0x48, 0x0F, 0xB6, 0xC0 }); // movzx rax, al
    }

    pub fn test_reg_self(self: *X86Emitter, r: Register) !void {
        var rex: u8 = 0x48;
        if (r.isExtended()) rex |= 0x05;
        try self.emitByte(rex);
        try self.emitByte(0x85);
        try self.emitByte(0xC0 | (@as(u8, r.low3()) << 3) | @as(u8, r.low3()));
    }

    pub fn jmp_rel32(self: *X86Emitter, rel32: i32) !usize {
        try self.emitByte(0xE9);
        const disp_offset = self.code.items.len;
        try self.emitI32(rel32);
        return disp_offset;
    }

    pub fn jcc_rel32(self: *X86Emitter, jz: bool, rel32: i32) !usize {
        try self.emitBytes(&[_]u8{ 0x0F, if (jz) 0x84 else 0x85 });
        const disp_offset = self.code.items.len;
        try self.emitI32(rel32);
        return disp_offset;
    }
};

pub const Tier1JitModule = struct {
    allocator: std.mem.Allocator,
    unit_idx: CellIdx = NULL_CELL,
    instructions: std.ArrayListUnmanaged(UrBcInst) = .empty,
    machine_code: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Tier1JitModule {
        return .{
            .allocator = allocator,
            .unit_idx = NULL_CELL,
            .instructions = .empty,
            .machine_code = .empty,
        };
    }

    pub fn deinit(self: *Tier1JitModule) void {
        self.instructions.deinit(self.allocator);
        self.machine_code.deinit(self.allocator);
    }
};

const JitLowerCtx = struct {
    graph: *const UrGraph,
    mod: *Tier1JitModule,
    unit_idx: CellIdx,
    used_regs: [16]bool = @splat(false),
    pinned_regs: [16]bool = @splat(false),
    sym_regs: std.AutoHashMapUnmanaged(SymId, u8) = .empty,
    arg_slots: std.AutoHashMapUnmanaged(SymId, u8) = .empty,
    next_arg_slot: u8 = 0,
    last_reg: u8 = 0,

    fn deinit(self: *JitLowerCtx) void {
        self.sym_regs.deinit(self.mod.allocator);
        self.arg_slots.deinit(self.mod.allocator);
    }

    fn allocReg(self: *JitLowerCtx) UrError!u8 {
        for (0..16) |i| {
            if (!self.used_regs[i]) {
                self.used_regs[i] = true;
                return @intCast(i);
            }
        }
        return error.EvaluationError;
    }

    fn freeTempReg(self: *JitLowerCtx, r: u8) void {
        if (r < 16 and !self.pinned_regs[r]) {
            self.used_regs[r] = false;
        }
    }

    fn emit(self: *JitLowerCtx, inst: UrBcInst) UrError!void {
        self.mod.instructions.append(self.mod.allocator, inst) catch return error.OutOfMemory;
    }

    fn resolveArgSlot(self: *JitLowerCtx, sym_id: SymId) UrError!u8 {
        if (self.arg_slots.get(sym_id)) |slot| return slot;
        const name = self.graph.getSym(sym_id);
        var slot: u8 = self.next_arg_slot;
        if (std.mem.startsWith(u8, name, "arg")) {
            if (std.fmt.parseInt(u8, name[3..], 10)) |parsed| {
                slot = parsed;
            } else |_| {
                self.next_arg_slot += 1;
            }
        } else {
            self.next_arg_slot += 1;
        }
        self.arg_slots.put(self.mod.allocator, sym_id, slot) catch return error.OutOfMemory;
        return slot;
    }

    fn lowerExpr(self: *JitLowerCtx, idx: CellIdx) UrError!u8 {
        if (idx == NULL_CELL) {
            const dst = try self.allocReg();
            try self.emit(.{ .op = .op_load_imm, .dst = dst, .src1 = 0, .src2 = 0, .imm32 = 0 });
            self.last_reg = dst;
            return dst;
        }
        const cell = self.graph.getCell(idx);
        switch (cell.kind) {
            .int_lit => {
                const dst = try self.allocReg();
                try self.emit(.{
                    .op = .op_load_imm,
                    .dst = dst,
                    .src1 = 0,
                    .src2 = 0,
                    .imm32 = @truncate(@as(u64, @bitCast(cell.payload.imm_i64))),
                });
                self.last_reg = dst;
                return dst;
            },
            .bool_lit => {
                const dst = try self.allocReg();
                try self.emit(.{
                    .op = .op_load_imm,
                    .dst = dst,
                    .src1 = 0,
                    .src2 = 0,
                    .imm32 = if (cell.payload.raw != 0) 1 else 0,
                });
                self.last_reg = dst;
                return dst;
            },
            .sym_atom => {
                if (self.sym_regs.get(cell.head_idx)) |r| {
                    self.last_reg = r;
                    return r;
                }
                const slot = try self.resolveArgSlot(cell.head_idx);
                const dst = try self.allocReg();
                self.pinned_regs[dst] = true;
                try self.emit(.{ .op = .op_load_arg, .dst = dst, .src1 = slot, .src2 = 0, .imm32 = 0 });
                self.sym_regs.put(self.mod.allocator, cell.head_idx, dst) catch return error.OutOfMemory;
                self.last_reg = dst;
                return dst;
            },
            .let_bind => {
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                const val_reg = if (children.len > 0) try self.lowerExpr(children[0]) else try self.allocReg();
                self.pinned_regs[val_reg] = true;
                self.sym_regs.put(self.mod.allocator, cell.head_idx, val_reg) catch return error.OutOfMemory;
                self.last_reg = val_reg;
                return val_reg;
            },
            .call_node => {
                const fn_name = self.graph.getSym(cell.head_idx);
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                const bc_op: ?UrBcOp = if (std.mem.eql(u8, fn_name, "+") or std.mem.eql(u8, fn_name, "add"))
                    .op_add
                else if (std.mem.eql(u8, fn_name, "-") or std.mem.eql(u8, fn_name, "sub"))
                    .op_sub
                else if (std.mem.eql(u8, fn_name, "*") or std.mem.eql(u8, fn_name, "mul"))
                    .op_mul
                else if (std.mem.eql(u8, fn_name, "/") or std.mem.eql(u8, fn_name, "div"))
                    .op_div
                else if (std.mem.eql(u8, fn_name, ">") or std.mem.eql(u8, fn_name, "gt"))
                    .op_cmp_gt
                else
                    null;

                if (bc_op != null and children.len >= 2) {
                    const r1 = try self.lowerExpr(children[0]);
                    const r2 = try self.lowerExpr(children[1]);
                    self.freeTempReg(r1);
                    self.freeTempReg(r2);
                    const dst = try self.allocReg();
                    try self.emit(.{ .op = bc_op.?, .dst = dst, .src1 = r1, .src2 = r2, .imm32 = 0 });
                    self.last_reg = dst;
                    return dst;
                }

                const dst = try self.allocReg();
                try self.emit(.{ .op = .op_call, .dst = dst, .src1 = 0, .src2 = 0, .imm32 = idx });
                self.last_reg = dst;
                return dst;
            },
            .if_branch => {
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                if (children.len < 3) {
                    const dst = try self.allocReg();
                    try self.emit(.{ .op = .op_load_imm, .dst = dst, .src1 = 0, .src2 = 0, .imm32 = 0 });
                    self.last_reg = dst;
                    return dst;
                }
                const cond_reg = try self.lowerExpr(children[0]);
                const out_reg = try self.allocReg();
                self.pinned_regs[out_reg] = true;
                self.freeTempReg(cond_reg);

                const jz_idx = self.mod.instructions.items.len;
                try self.emit(.{ .op = .op_jmp_if, .dst = 0, .src1 = cond_reg, .src2 = 0, .imm32 = 0 });

                const then_reg = try self.lowerExpr(children[1]);
                if (self.graph.getCell(children[1]).kind != .return_ok) {
                    try self.emit(.{ .op = .op_mov, .dst = out_reg, .src1 = then_reg, .src2 = 0, .imm32 = 0 });
                }
                self.freeTempReg(then_reg);

                const jmp_end_idx = self.mod.instructions.items.len;
                try self.emit(.{ .op = .op_jmp_if, .dst = 1, .src1 = 0, .src2 = 0, .imm32 = 0 });

                self.mod.instructions.items[jz_idx].imm32 = @intCast(self.mod.instructions.items.len);
                const else_reg = try self.lowerExpr(children[2]);
                if (self.graph.getCell(children[2]).kind != .return_ok) {
                    try self.emit(.{ .op = .op_mov, .dst = out_reg, .src1 = else_reg, .src2 = 0, .imm32 = 0 });
                }
                self.freeTempReg(else_reg);

                self.mod.instructions.items[jmp_end_idx].imm32 = @intCast(self.mod.instructions.items.len);
                self.pinned_regs[out_reg] = false;
                self.last_reg = out_reg;
                return out_reg;
            },
            .needs_stub, .hazel_hole, .hazel_membrane => {
                const dst = try self.allocReg();
                try self.emit(.{ .op = .op_sample_fallback, .dst = dst, .src1 = 0, .src2 = 0, .imm32 = self.unit_idx });
                self.last_reg = dst;
                return dst;
            },
            .return_ok => {
                const children = self.graph.getChildren(cell.payload.slice.start, cell.payload.slice.len);
                const ret_reg = if (children.len > 0) try self.lowerExpr(children[0]) else self.last_reg;
                try self.emit(.{ .op = .op_ret, .dst = 0, .src1 = ret_reg, .src2 = 0, .imm32 = 0 });
                self.last_reg = ret_reg;
                return ret_reg;
            },
            .fiber_yield => {
                try self.emit(.{ .op = .op_nop, .dst = 0, .src1 = 0, .src2 = 0, .imm32 = 0 });
                return self.last_reg;
            },
            .sample_io_row, .scope_free, .rc_adjust, .arena_promote, .gen_guard_check, .borrow_ref => {
                return self.last_reg;
            },
            else => return self.last_reg,
        }
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
        jit_mod.unit_idx = unit_idx;
        errdefer jit_mod.deinit();

        var ctx = JitLowerCtx{
            .graph = graph,
            .mod = &jit_mod,
            .unit_idx = unit_idx,
        };
        defer ctx.deinit();

        const children = graph.getChildren(unit_cell.payload.slice.start, unit_cell.payload.slice.len);
        for (children) |child_idx| {
            _ = try ctx.lowerExpr(child_idx);
        }

        // Emit x86_64 machine code from lowered register bytecode via Aether's X86Emitter
        try self.emitMachineCodeStencils(&jit_mod);

        return jit_mod;
    }

    fn mapVmReg(reg: u8) Register {
        const table = [8]Register{ .rax, .rcx, .rdx, .rbx, .rsi, .rdi, .r8, .r9 };
        return table[reg % 8];
    }

    fn emitMachineCodeStencils(self: *Tier1JitEngine, mod: *Tier1JitModule) !void {
        var emitter = X86Emitter.init(self.compiler.allocator);
        defer emitter.deinit();

        try emitter.prolog();

        const inst_count = mod.instructions.items.len;
        const bc_offsets = try self.compiler.allocator.alloc(usize, inst_count + 1);
        defer self.compiler.allocator.free(bc_offsets);

        const JumpPatch = struct { disp_offset: usize, target_pc: usize };
        var patches: std.ArrayListUnmanaged(JumpPatch) = .empty;
        defer patches.deinit(self.compiler.allocator);

        for (mod.instructions.items, 0..) |inst, pc| {
            bc_offsets[pc] = emitter.code.items.len;
            switch (inst.op) {
                .op_nop => try emitter.emitByte(0x90),
                .op_load_imm => try emitter.mov_reg_imm32(mapVmReg(inst.dst), @bitCast(inst.imm32)),
                .op_load_arg => {
                    // Win64 arg0 arrives in RCX; move to target VM register
                    if (inst.src1 == 0 and mapVmReg(inst.dst) != .rcx) {
                        try emitter.mov_reg_reg(mapVmReg(inst.dst), .rcx);
                    } else if (inst.src1 == 1 and mapVmReg(inst.dst) != .rdx) {
                        try emitter.mov_reg_reg(mapVmReg(inst.dst), .rdx);
                    }
                },
                .op_mov => try emitter.mov_reg_reg(mapVmReg(inst.dst), mapVmReg(inst.src1)),
                .op_add => {
                    try emitter.mov_reg_reg(.r10, mapVmReg(inst.src1));
                    try emitter.add_reg_reg(.r10, mapVmReg(inst.src2));
                    try emitter.mov_reg_reg(mapVmReg(inst.dst), .r10);
                },
                .op_sub => {
                    try emitter.mov_reg_reg(.r10, mapVmReg(inst.src1));
                    try emitter.sub_reg_reg(.r10, mapVmReg(inst.src2));
                    try emitter.mov_reg_reg(mapVmReg(inst.dst), .r10);
                },
                .op_mul => {
                    try emitter.mov_reg_reg(.r10, mapVmReg(inst.src1));
                    try emitter.imul_reg_reg(.r10, mapVmReg(inst.src2));
                    try emitter.mov_reg_reg(mapVmReg(inst.dst), .r10);
                },
                .op_div => {
                    try emitter.mov_reg_reg(.r10, mapVmReg(inst.src1));
                    try emitter.mov_reg_reg(mapVmReg(inst.dst), .r10);
                },
                .op_cmp_gt => {
                    try emitter.cmp_reg_reg(mapVmReg(inst.src1), mapVmReg(inst.src2));
                    try emitter.setcc_gt_rax();
                    if (mapVmReg(inst.dst) != .rax) {
                        try emitter.mov_reg_reg(mapVmReg(inst.dst), .rax);
                    }
                },
                .op_jmp_if => {
                    if (inst.dst == 1) {
                        const off = try emitter.jmp_rel32(0);
                        try patches.append(self.compiler.allocator, .{ .disp_offset = off, .target_pc = inst.imm32 });
                    } else {
                        try emitter.test_reg_self(mapVmReg(inst.src1));
                        const off = try emitter.jcc_rel32(inst.dst == 0, 0);
                        try patches.append(self.compiler.allocator, .{ .disp_offset = off, .target_pc = inst.imm32 });
                    }
                },
                .op_ret => {
                    if (mapVmReg(inst.src1) != .rax) {
                        try emitter.mov_reg_reg(.rax, mapVmReg(inst.src1));
                    }
                    try emitter.epilog();
                },
                .op_call, .op_sample_fallback => try emitter.emitByte(0x90),
            }
        }
        bc_offsets[inst_count] = emitter.code.items.len;

        // Backpatch relative jump displacements
        for (patches.items) |p| {
            const target_pc = @min(p.target_pc, inst_count);
            const target_byte = bc_offsets[target_pc];
            const next_ip = p.disp_offset + 4;
            const rel: i32 = @intCast(@as(isize, @intCast(target_byte)) - @as(isize, @intCast(next_ip)));
            std.mem.writeInt(i32, emitter.code.items[p.disp_offset..][0..4], rel, .little);
        }

        if (inst_count == 0 or mod.instructions.items[inst_count - 1].op != .op_ret) {
            try emitter.epilog();
        }

        try mod.machine_code.appendSlice(self.compiler.allocator, emitter.code.items);
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

        var pc: usize = 0;
        while (pc < mod.instructions.items.len) {
            const inst = mod.instructions.items[pc];
            switch (inst.op) {
                .op_nop => {},
                .op_load_imm => {
                    regs[inst.dst] = @as(i32, @bitCast(inst.imm32));
                },
                .op_load_arg => {
                    const arg_i = inst.src1;
                    if (arg_i < args.len) {
                        const cell = graph.getCell(args[arg_i]);
                        regs[inst.dst] = if (cell.kind == .int_lit) cell.payload.imm_i64 else if (cell.kind == .bool_lit) @as(i64, @intCast(cell.payload.raw)) else 0;
                    }
                },
                .op_mov => {
                    regs[inst.dst] = regs[inst.src1];
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
                .op_jmp_if => {
                    const should_jump = switch (inst.dst) {
                        0 => regs[inst.src1] == 0,
                        1 => true,
                        2 => regs[inst.src1] != 0,
                        else => false,
                    };
                    if (should_jump) {
                        pc = inst.imm32;
                        continue;
                    }
                },
                .op_call => {
                    var t0 = Tier0Evaluator.init(self.compiler);
                    var env = ext_mod.UrEvalEnv.init(self.compiler.allocator);
                    defer env.deinit();
                    const res_idx = try t0.evalCell(inst.imm32, &env, mod.unit_idx, args);
                    const rc = graph.getCell(res_idx);
                    regs[inst.dst] = if (rc.kind == .int_lit) rc.payload.imm_i64 else 0;
                },
                .op_sample_fallback => {
                    var t0 = Tier0Evaluator.init(self.compiler);
                    const target_unit = if (inst.imm32 != NULL_CELL) inst.imm32 else mod.unit_idx;
                    const oracle_idx = try t0.evalSampleOracle(target_unit, args);
                    const oc = graph.getCell(oracle_idx);
                    if (oc.kind == .int_lit) {
                        regs[inst.dst] = oc.payload.imm_i64;
                    } else {
                        return oracle_idx;
                    }
                },
                .op_ret => {
                    const ret_val = regs[inst.src1];
                    return graph.allocCell(UrCell{
                        .kind = .int_lit,
                        .type_id = BuiltinType.int_type,
                        .payload = .{ .imm_i64 = ret_val },
                    }) catch return error.OutOfMemory;
                },
            }
            pc += 1;
        }

        return NULL_CELL;
    }
};

test "Tier1JitEngine recursive lowering, if_branch jumps, and x86_64 codegen" {
    const allocator = std.testing.allocator;
    var graph = try UrGraph.create(allocator);
    defer graph.destroy();

    var comp = try UrCompiler.create(graph, urc_mod.DEFAULT_FEATURES);
    defer comp.destroy();

    // (unit clamp_step (let doubled (call * x 2)) (if (call > doubled 10) (return_ok (call + doubled 5)) (return_ok (call - doubled 1))))
    const src = "(unit clamp_step (let doubled (call * x 2)) (if (call > doubled 10) (return_ok (call + doubled 5)) (return_ok (call - doubled 1))))";
    const unit_idx = try sexpr_lens.parseSexpr(graph, src);

    var jit = Tier1JitEngine.init(comp);
    var mod = try jit.compileUnit(unit_idx);
    defer mod.deinit();

    // Verify x86_64 code contains prologue (55 48 89 E5) and epilogue (48 89 EC 5D C3)
    try std.testing.expect(mod.machine_code.items.len > 12);
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5 }, mod.machine_code.items[0..4]);

    const arg_hi = try graph.allocCell(.{ .kind = .int_lit, .type_id = BuiltinType.int_type, .payload = .{ .imm_i64 = 7 } });
    const out_hi = try jit.execBytecode(&mod, &.{arg_hi});
    try std.testing.expectEqual(@as(i64, 19), graph.getCell(out_hi).payload.imm_i64);

    const arg_lo = try graph.allocCell(.{ .kind = .int_lit, .type_id = BuiltinType.int_type, .payload = .{ .imm_i64 = 3 } });
    const out_lo = try jit.execBytecode(&mod, &.{arg_lo});
    try std.testing.expectEqual(@as(i64, 5), graph.getCell(out_lo).payload.imm_i64);
}
