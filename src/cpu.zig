const std = @import("std");
const Bus = @import("bus.zig").Bus;
const InterruptFlags = @import("ppu.zig").InterruptFlags;

const Flags = packed struct(u8) {
    _pad: u4 = 0,
    carry: bool = false,
    half: bool = false,
    n: bool = false,
    zero: bool = false,
};

// ── Comptime register abstraction ───────────────────────────────────
const Reg = enum(u3) { b = 0, c = 1, d = 2, e = 3, h = 4, l = 5, hl_ind = 6, a = 7 };

const Reg16 = enum { bc, de, hl, sp, af };

const Cond = enum { nz, z, nc, c };

pub const CPU = struct {
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    f: Flags = .{},
    h: u8 = 0,
    l: u8 = 0,
    pc: u16 = 0,
    sp: u16 = 0xFFFE,
    cycles: u32 = 0,

    halted: bool = false,
    interrupt_master_enable: bool = false,
    ei_pending: bool = false,

    bus: *Bus = undefined,

    pub fn skipBootRom(self: *CPU) void {
        self.a = 0x01;
        self.f = .{ .carry = true, .half = true, .zero = true };
        self.b = 0x00;
        self.c = 0x13;
        self.d = 0x00;
        self.e = 0xd8;
        self.h = 0x01;
        self.l = 0x4d;
        self.sp = 0xFFFE;
        self.pc = 0x0100;
    }

    pub fn serialize(self: *const CPU, writer: anytype) !void {
        try writer.writeAll(&[_]u8{self.a});
        try writer.writeAll(&[_]u8{self.b});
        try writer.writeAll(&[_]u8{self.c});
        try writer.writeAll(&[_]u8{self.d});
        try writer.writeAll(&[_]u8{self.e});
        try writer.writeAll(&[_]u8{@bitCast(self.f)});
        try writer.writeAll(&[_]u8{self.h});
        try writer.writeAll(&[_]u8{self.l});
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.pc)));
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.sp)));
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.cycles)));
        try writer.writeAll(&[_]u8{if (self.halted) 1 else 0});
        try writer.writeAll(&[_]u8{if (self.interrupt_master_enable) 1 else 0});
        try writer.writeAll(&[_]u8{if (self.ei_pending) 1 else 0});
    }

    pub fn deserialize(self: *CPU, reader: anytype) !void {
        var buf: [1]u8 = undefined;
        try reader.readNoEof(&buf);
        self.a = buf[0];
        try reader.readNoEof(&buf);
        self.b = buf[0];
        try reader.readNoEof(&buf);
        self.c = buf[0];
        try reader.readNoEof(&buf);
        self.d = buf[0];
        try reader.readNoEof(&buf);
        self.e = buf[0];
        try reader.readNoEof(&buf);
        self.f = @bitCast(buf[0]);
        try reader.readNoEof(&buf);
        self.h = buf[0];
        try reader.readNoEof(&buf);
        self.l = buf[0];

        var buf16: [2]u8 = undefined;
        try reader.readNoEof(&buf16);
        self.pc = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, &buf16));
        try reader.readNoEof(&buf16);
        self.sp = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, &buf16));

        var buf32: [4]u8 = undefined;
        try reader.readNoEof(&buf32);
        self.cycles = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, &buf32));

        try reader.readNoEof(&buf);
        self.halted = buf[0] != 0;
        try reader.readNoEof(&buf);
        self.interrupt_master_enable = buf[0] != 0;
        try reader.readNoEof(&buf);
        self.ei_pending = buf[0] != 0;
    }

    // ── Comptime register read/write ────────────────────────────────

    fn readReg(self: *CPU, comptime r: Reg) u8 {
        return switch (r) {
            .b => self.b,
            .c => self.c,
            .d => self.d,
            .e => self.e,
            .h => self.h,
            .l => self.l,
            .hl_ind => self.readByte(self.getHL()),
            .a => self.a,
        };
    }

    fn writeReg(self: *CPU, comptime r: Reg, val: u8) void {
        switch (r) {
            .b => self.b = val,
            .c => self.c = val,
            .d => self.d = val,
            .e => self.e = val,
            .h => self.h = val,
            .l => self.l = val,
            .hl_ind => self.writeByte(self.getHL(), val),
            .a => self.a = val,
        }
    }

    fn checkCond(self: *const CPU, comptime cond: Cond) bool {
        return switch (cond) {
            .nz => !self.f.zero,
            .z => self.f.zero,
            .nc => !self.f.carry,
            .c => self.f.carry,
        };
    }

    // ── Register pairs ──────────────────────────────────────────────

    fn getAF(self: *const CPU) u16 {
        return (@as(u16, self.a) << 8) | @as(u16, @as(u8, @bitCast(self.f)));
    }

    fn getBC(self: *const CPU) u16 {
        return (@as(u16, self.b) << 8) | @as(u16, self.c);
    }

    fn getDE(self: *const CPU) u16 {
        return (@as(u16, self.d) << 8) | @as(u16, self.e);
    }

    fn getHL(self: *const CPU) u16 {
        return (@as(u16, self.h) << 8) | @as(u16, self.l);
    }

    fn setBC(self: *CPU, v: u16) void {
        self.b = @truncate(v >> 8);
        self.c = @truncate(v);
    }

    fn setDE(self: *CPU, v: u16) void {
        self.d = @truncate(v >> 8);
        self.e = @truncate(v);
    }

    fn setHL(self: *CPU, v: u16) void {
        self.h = @truncate(v >> 8);
        self.l = @truncate(v);
    }

    fn getReg16(self: *CPU, comptime r: Reg16) u16 {
        return switch (r) {
            .bc => self.getBC(),
            .de => self.getDE(),
            .hl => self.getHL(),
            .sp => self.sp,
            .af => self.getAF(),
        };
    }

    fn setReg16(self: *CPU, comptime r: Reg16, v: u16) void {
        switch (r) {
            .bc => self.setBC(v),
            .de => self.setDE(v),
            .hl => self.setHL(v),
            .sp => {
                self.sp = v;
            },
            .af => {
                self.a = @truncate(v >> 8);
                self.f = @bitCast(@as(u8, @truncate(v)) & 0xf0);
            },
        }
    }

    // ── Memory access ───────────────────────────────────────────────

    fn readByte(self: *CPU, addr: u16) u8 {
        return self.bus.readByte(addr);
    }

    fn writeByte(self: *CPU, addr: u16, value: u8) void {
        self.bus.writeByte(addr, value);
    }

    fn getImmU8(self: *CPU) u8 {
        const v = self.readByte(self.pc);
        self.pc +%= 1;
        return v;
    }

    fn getImmI8(self: *CPU) i8 {
        const v: i8 = @bitCast(self.readByte(self.pc));
        self.pc +%= 1;
        return v;
    }

    fn getImmU16(self: *CPU) u16 {
        const lo = self.readByte(self.pc);
        const hi = self.readByte(self.pc +% 1);
        self.pc +%= 2;
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    // ── Stack operations ────────────────────────────────────────────

    fn pushU8(self: *CPU, n_val: u8) void {
        self.sp -%= 1;
        self.writeByte(self.sp, n_val);
    }

    fn pushU16(self: *CPU, n_val: u16) void {
        self.pushU8(@truncate(n_val >> 8));
        self.pushU8(@truncate(n_val));
    }

    fn popU8(self: *CPU) u8 {
        const v = self.readByte(self.sp);
        self.sp +%= 1;
        return v;
    }

    fn popU16(self: *CPU) u16 {
        const lo = self.popU8();
        const hi = self.popU8();
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    // ── ALU operations ──────────────────────────────────────────────

    fn getCarry(self: *const CPU) u8 {
        return if (self.f.carry) 1 else 0;
    }

    fn op_add(self: *CPU, n_val: u8) void {
        const result = @addWithOverflow(self.a, n_val);
        self.f = .{
            .zero = result[0] == 0,
            .n = false,
            .half = ((self.a & 0xf) + (n_val & 0xf)) & 0x10 != 0,
            .carry = result[1] != 0,
        };
        self.a = result[0];
    }

    fn op_adc(self: *CPU, n_val: u8) void {
        const carry = self.getCarry();
        const r = self.a +% n_val +% carry;
        self.f = .{
            .zero = r == 0,
            .n = false,
            .half = (self.a & 0xf) + (n_val & 0xf) + carry > 0xf,
            .carry = @as(u16, self.a) + @as(u16, n_val) + @as(u16, carry) > 0xff,
        };
        self.a = r;
    }

    fn op_sub(self: *CPU, n_val: u8) void {
        const result = @subWithOverflow(self.a, n_val);
        self.f = .{
            .zero = result[0] == 0,
            .n = true,
            .half = (self.a & 0xf) < (n_val & 0xf),
            .carry = result[1] != 0,
        };
        self.a = result[0];
    }

    fn op_sbc(self: *CPU, n_val: u8) void {
        const carry = self.getCarry();
        const r = self.a -% n_val -% carry;
        self.f = .{
            .zero = r == 0,
            .n = true,
            .half = (self.a & 0x0f) < (n_val & 0x0f) + carry,
            .carry = @as(u16, self.a) < @as(u16, n_val) + @as(u16, carry),
        };
        self.a = r;
    }

    fn op_and(self: *CPU, n_val: u8) void {
        self.a &= n_val;
        self.f = .{ .zero = self.a == 0, .half = true };
    }

    fn op_or(self: *CPU, n_val: u8) void {
        self.a |= n_val;
        self.f = .{ .zero = self.a == 0 };
    }

    fn op_xor(self: *CPU, n_val: u8) void {
        self.a ^= n_val;
        self.f = .{ .zero = self.a == 0 };
    }

    fn op_cp(self: *CPU, n_val: u8) void {
        const result = @subWithOverflow(self.a, n_val);
        self.f = .{
            .zero = result[0] == 0,
            .n = true,
            .half = (self.a & 0xf) < (n_val & 0xf),
            .carry = result[1] != 0,
        };
    }

    // ── INC/DEC 8-bit RMW operations ───────────────────────────────

    fn op_inc8(self: *CPU, val: u8) u8 {
        const r = val +% 1;
        self.f.zero = r == 0;
        self.f.n = false;
        self.f.half = ((val & 0xf) + 1) & 0x10 == 0x10;
        return r;
    }

    fn op_dec8(self: *CPU, val: u8) u8 {
        const r = val -% 1;
        self.f.zero = r == 0;
        self.f.n = true;
        self.f.half = (val & 0xf0) != (r & 0xf0);
        return r;
    }

    // ── Rotate / Shift operations ───────────────────────────────────

    fn op_rlc(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        var r = v << 1;
        if (carry) r |= 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_rl(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        var r = v << 1;
        if (self.f.carry) r |= 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_rrc(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        var r = v >> 1;
        if (carry) r |= 0x80;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_rr(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        var r = v >> 1;
        if (self.f.carry) r |= 0x80;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_sla(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        const r = v << 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_sra(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        const r = (v >> 1) | (v & 0x80);
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_srl(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        const r = v >> 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn op_swap(self: *CPU, n_val: u8) u8 {
        self.f = .{ .zero = n_val == 0 };
        return (n_val >> 4) | (n_val << 4);
    }

    // ── Comptime bit operations ─────────────────────────────────────

    fn bit_n(comptime bit: u3) fn (*CPU, u8) void {
        return struct {
            fn func(self: *CPU, val: u8) void {
                self.f.zero = (val >> bit) & 1 == 0;
                self.f.n = false;
                self.f.half = true;
            }
        }.func;
    }

    fn set_n(comptime bit: u3) fn (*CPU, u8) u8 {
        return struct {
            fn func(_: *CPU, val: u8) u8 {
                return val | (@as(u8, 1) << bit);
            }
        }.func;
    }

    fn res_n(comptime bit: u3) fn (*CPU, u8) u8 {
        return struct {
            fn func(_: *CPU, val: u8) u8 {
                return val & ~(@as(u8, 1) << bit);
            }
        }.func;
    }

    // ── 16-bit ALU helpers ──────────────────────────────────────────

    fn addHL16(self: *CPU, n_val: u16) void {
        const hl = self.getHL();
        const result = @addWithOverflow(hl, n_val);
        self.f.n = false;
        self.f.half = ((hl & 0xfff) + (n_val & 0xfff)) & 0x1000 != 0;
        self.f.carry = result[1] != 0;
        self.setHL(result[0]);
    }

    fn add16Imm(self: *CPU, a: u16) u16 {
        const b_i8 = self.getImmI8();
        const b_val: u16 = @bitCast(@as(i16, b_i8));
        self.f = .{
            .half = (a & 0xf) + (b_val & 0xf) > 0xf,
            .carry = (a & 0xff) + (b_val & 0xff) > 0xff,
        };
        return a +% b_val;
    }

    // ── DAA ─────────────────────────────────────────────────────────

    fn daa(self: *CPU) void {
        var adjust: u8 = 0;
        if (self.f.carry) adjust = 0x60;
        if (self.f.half) adjust |= 0x06;

        if (!self.f.n) {
            if (self.a & 0x0f > 0x09) adjust |= 0x06;
            if (self.a > 0x99) adjust |= 0x60;
            self.a = self.a +% adjust;
        } else {
            self.a = self.a -% adjust;
        }

        self.f.carry = adjust >= 0x60;
        self.f.half = false;
        self.f.zero = self.a == 0;
    }

    // ── Call / Ret / RST ────────────────────────────────────────────

    fn doCall(self: *CPU, addr: u16) void {
        self.pushU16(self.pc);
        self.pc = addr;
    }

    fn doRet(self: *CPU) void {
        self.pc = self.popU16();
    }

    fn doRst(self: *CPU, addr: u16) void {
        self.pushU16(self.pc);
        self.pc = addr;
    }

    // ── HLI / HLD ───────────────────────────────────────────────────

    fn hli(self: *CPU) u16 {
        const hl = self.getHL();
        self.setHL(hl +% 1);
        return hl;
    }

    fn hld(self: *CPU) u16 {
        const hl = self.getHL();
        self.setHL(hl -% 1);
        return hl;
    }

    // ── Interrupts ──────────────────────────────────────────────────

    fn checkAndExecuteInterrupts(self: *CPU) bool {
        const interrupt_triggered = self.bus.checkInterrupt();

        if (interrupt_triggered) {
            self.halted = false;

            if (self.interrupt_master_enable) {
                const ie = self.bus.interrupt_enable;
                const interrupt_flags = InterruptFlags.bitwiseAnd(self.bus.ppu.interrupt_flag, ie);
                if (interrupt_flags.interruptAddress()) |addr| {
                    self.interrupt_master_enable = false;
                    const triggered = interrupt_flags.highestPrioBit();
                    self.bus.ppu.interrupt_flag.remove(triggered);
                    self.doCall(addr);
                    return true;
                }
            }
        }

        return false;
    }

    // ── Addressing-mode templates ───────────────────────────────────

    const Handler = *const fn (*CPU) void;

    /// Read from register, apply read-only op. Cycles: base + 4 if (HL).
    fn read_reg(comptime op: fn (*CPU, u8) void, comptime r: Reg, comptime base: u32) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                op(self, self.readReg(r));
                self.cycles = if (r == .hl_ind) base + 4 else base;
            }
        }.handler;
    }

    /// Read immediate byte, apply op. Cycles: base.
    fn read_imm(comptime op: fn (*CPU, u8) void, comptime base: u32) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                op(self, self.getImmU8());
                self.cycles = base;
            }
        }.handler;
    }

    /// Read-modify-write register. Cycles: base + 8 if (HL).
    fn rmw_reg(comptime op: fn (*CPU, u8) u8, comptime r: Reg, comptime base: u32) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                if (r == .hl_ind) {
                    const hl = self.getHL();
                    const val = self.readByte(hl);
                    const result = op(self, val);
                    self.writeByte(hl, result);
                    self.cycles = base + 8;
                } else {
                    const val = self.readReg(r);
                    const result = op(self, val);
                    self.writeReg(r, result);
                    self.cycles = base;
                }
            }
        }.handler;
    }

    /// Load register to register. Cycles: 4, or 8 if either is (HL).
    fn ld_rr(comptime dst: Reg, comptime src: Reg) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.writeReg(dst, self.readReg(src));
                self.cycles = if (dst == .hl_ind or src == .hl_ind) 8 else 4;
            }
        }.handler;
    }

    /// Load immediate to register. Cycles: 8, or 12 if (HL).
    fn ld_r_imm(comptime r: Reg) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                const n = self.getImmU8();
                self.writeReg(r, n);
                self.cycles = if (r == .hl_ind) 12 else 8;
            }
        }.handler;
    }

    // ── 16-bit templates ──────────────────────────────────────────────

    fn ld_rr16_imm(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.setReg16(r, self.getImmU16());
                self.cycles = 12;
            }
        }.handler;
    }

    fn inc16(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.setReg16(r, self.getReg16(r) +% 1);
                self.cycles = 8;
            }
        }.handler;
    }

    fn dec16(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.setReg16(r, self.getReg16(r) -% 1);
                self.cycles = 8;
            }
        }.handler;
    }

    fn add_hl_rr(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.addHL16(self.getReg16(r));
                self.cycles = 8;
            }
        }.handler;
    }

    fn push_rr(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.pushU16(self.getReg16(r));
                self.cycles = 16;
            }
        }.handler;
    }

    fn pop_rr(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.setReg16(r, self.popU16());
                self.cycles = 12;
            }
        }.handler;
    }

    fn ld_a_rr_ind(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.a = self.readByte(self.getReg16(r));
                self.cycles = 8;
            }
        }.handler;
    }

    fn ld_rr_ind_a(comptime r: Reg16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.writeByte(self.getReg16(r), self.a);
                self.cycles = 8;
            }
        }.handler;
    }

    // ── Condition templates ─────────────────────────────────────────

    fn jrCond(comptime cond: Cond) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                const n = self.getImmI8();
                if (self.checkCond(cond)) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n));
                    self.cycles = 12;
                } else {
                    self.cycles = 8;
                }
            }
        }.handler;
    }

    fn jpCond(comptime cond: Cond) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                const nn = self.getImmU16();
                if (self.checkCond(cond)) {
                    self.pc = nn;
                    self.cycles = 16;
                } else {
                    self.cycles = 12;
                }
            }
        }.handler;
    }

    fn callCond(comptime cond: Cond) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                const nn = self.getImmU16();
                if (self.checkCond(cond)) {
                    self.doCall(nn);
                    self.cycles = 24;
                } else {
                    self.cycles = 12;
                }
            }
        }.handler;
    }

    fn retCond(comptime cond: Cond) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                if (self.checkCond(cond)) {
                    self.doRet();
                    self.cycles = 20;
                } else {
                    self.cycles = 8;
                }
            }
        }.handler;
    }

    fn rstVec(comptime addr: u16) Handler {
        return &struct {
            fn handler(self: *CPU) void {
                self.doRst(addr);
                self.cycles = 16;
            }
        }.handler;
    }

    // ── Opcode table initialization ─────────────────────────────────

    const opcode_table: [256]Handler = initOpcodeTable();
    const cb_table: [256]Handler = initCBTable();

    fn initOpcodeTable() [256]Handler {
        var table: [256]Handler = .{&execUnimplemented} ** 256;

        // ── LD r,r' and LD r,(HL) and LD (HL),r (0x40-0x7F except 0x76=HALT) ──
        table[0x40] = ld_rr(.b, .b);
        table[0x41] = ld_rr(.b, .c);
        table[0x42] = ld_rr(.b, .d);
        table[0x43] = ld_rr(.b, .e);
        table[0x44] = ld_rr(.b, .h);
        table[0x45] = ld_rr(.b, .l);
        table[0x46] = ld_rr(.b, .hl_ind);
        table[0x47] = ld_rr(.b, .a);
        table[0x48] = ld_rr(.c, .b);
        table[0x49] = ld_rr(.c, .c);
        table[0x4A] = ld_rr(.c, .d);
        table[0x4B] = ld_rr(.c, .e);
        table[0x4C] = ld_rr(.c, .h);
        table[0x4D] = ld_rr(.c, .l);
        table[0x4E] = ld_rr(.c, .hl_ind);
        table[0x4F] = ld_rr(.c, .a);
        table[0x50] = ld_rr(.d, .b);
        table[0x51] = ld_rr(.d, .c);
        table[0x52] = ld_rr(.d, .d);
        table[0x53] = ld_rr(.d, .e);
        table[0x54] = ld_rr(.d, .h);
        table[0x55] = ld_rr(.d, .l);
        table[0x56] = ld_rr(.d, .hl_ind);
        table[0x57] = ld_rr(.d, .a);
        table[0x58] = ld_rr(.e, .b);
        table[0x59] = ld_rr(.e, .c);
        table[0x5A] = ld_rr(.e, .d);
        table[0x5B] = ld_rr(.e, .e);
        table[0x5C] = ld_rr(.e, .h);
        table[0x5D] = ld_rr(.e, .l);
        table[0x5E] = ld_rr(.e, .hl_ind);
        table[0x5F] = ld_rr(.e, .a);
        table[0x60] = ld_rr(.h, .b);
        table[0x61] = ld_rr(.h, .c);
        table[0x62] = ld_rr(.h, .d);
        table[0x63] = ld_rr(.h, .e);
        table[0x64] = ld_rr(.h, .h);
        table[0x65] = ld_rr(.h, .l);
        table[0x66] = ld_rr(.h, .hl_ind);
        table[0x67] = ld_rr(.h, .a);
        table[0x68] = ld_rr(.l, .b);
        table[0x69] = ld_rr(.l, .c);
        table[0x6A] = ld_rr(.l, .d);
        table[0x6B] = ld_rr(.l, .e);
        table[0x6C] = ld_rr(.l, .h);
        table[0x6D] = ld_rr(.l, .l);
        table[0x6E] = ld_rr(.l, .hl_ind);
        table[0x6F] = ld_rr(.l, .a);
        table[0x70] = ld_rr(.hl_ind, .b);
        table[0x71] = ld_rr(.hl_ind, .c);
        table[0x72] = ld_rr(.hl_ind, .d);
        table[0x73] = ld_rr(.hl_ind, .e);
        table[0x74] = ld_rr(.hl_ind, .h);
        table[0x75] = ld_rr(.hl_ind, .l);
        table[0x77] = ld_rr(.hl_ind, .a);
        table[0x78] = ld_rr(.a, .b);
        table[0x79] = ld_rr(.a, .c);
        table[0x7A] = ld_rr(.a, .d);
        table[0x7B] = ld_rr(.a, .e);
        table[0x7C] = ld_rr(.a, .h);
        table[0x7D] = ld_rr(.a, .l);
        table[0x7E] = ld_rr(.a, .hl_ind);
        table[0x7F] = ld_rr(.a, .a);

        // ── LD r,n (immediate 8-bit loads) ──
        table[0x06] = ld_r_imm(.b);
        table[0x0E] = ld_r_imm(.c);
        table[0x16] = ld_r_imm(.d);
        table[0x1E] = ld_r_imm(.e);
        table[0x26] = ld_r_imm(.h);
        table[0x2E] = ld_r_imm(.l);
        table[0x36] = ld_r_imm(.hl_ind);
        table[0x3E] = ld_r_imm(.a);

        // ── ALU r (0x80-0xBF) ──
        table[0x80] = read_reg(op_add, .b, 4);
        table[0x81] = read_reg(op_add, .c, 4);
        table[0x82] = read_reg(op_add, .d, 4);
        table[0x83] = read_reg(op_add, .e, 4);
        table[0x84] = read_reg(op_add, .h, 4);
        table[0x85] = read_reg(op_add, .l, 4);
        table[0x86] = read_reg(op_add, .hl_ind, 4);
        table[0x87] = read_reg(op_add, .a, 4);
        table[0x88] = read_reg(op_adc, .b, 4);
        table[0x89] = read_reg(op_adc, .c, 4);
        table[0x8A] = read_reg(op_adc, .d, 4);
        table[0x8B] = read_reg(op_adc, .e, 4);
        table[0x8C] = read_reg(op_adc, .h, 4);
        table[0x8D] = read_reg(op_adc, .l, 4);
        table[0x8E] = read_reg(op_adc, .hl_ind, 4);
        table[0x8F] = read_reg(op_adc, .a, 4);
        table[0x90] = read_reg(op_sub, .b, 4);
        table[0x91] = read_reg(op_sub, .c, 4);
        table[0x92] = read_reg(op_sub, .d, 4);
        table[0x93] = read_reg(op_sub, .e, 4);
        table[0x94] = read_reg(op_sub, .h, 4);
        table[0x95] = read_reg(op_sub, .l, 4);
        table[0x96] = read_reg(op_sub, .hl_ind, 4);
        table[0x97] = read_reg(op_sub, .a, 4);
        table[0x98] = read_reg(op_sbc, .b, 4);
        table[0x99] = read_reg(op_sbc, .c, 4);
        table[0x9A] = read_reg(op_sbc, .d, 4);
        table[0x9B] = read_reg(op_sbc, .e, 4);
        table[0x9C] = read_reg(op_sbc, .h, 4);
        table[0x9D] = read_reg(op_sbc, .l, 4);
        table[0x9E] = read_reg(op_sbc, .hl_ind, 4);
        table[0x9F] = read_reg(op_sbc, .a, 4);
        table[0xA0] = read_reg(op_and, .b, 4);
        table[0xA1] = read_reg(op_and, .c, 4);
        table[0xA2] = read_reg(op_and, .d, 4);
        table[0xA3] = read_reg(op_and, .e, 4);
        table[0xA4] = read_reg(op_and, .h, 4);
        table[0xA5] = read_reg(op_and, .l, 4);
        table[0xA6] = read_reg(op_and, .hl_ind, 4);
        table[0xA7] = read_reg(op_and, .a, 4);
        table[0xA8] = read_reg(op_xor, .b, 4);
        table[0xA9] = read_reg(op_xor, .c, 4);
        table[0xAA] = read_reg(op_xor, .d, 4);
        table[0xAB] = read_reg(op_xor, .e, 4);
        table[0xAC] = read_reg(op_xor, .h, 4);
        table[0xAD] = read_reg(op_xor, .l, 4);
        table[0xAE] = read_reg(op_xor, .hl_ind, 4);
        table[0xAF] = read_reg(op_xor, .a, 4);
        table[0xB0] = read_reg(op_or, .b, 4);
        table[0xB1] = read_reg(op_or, .c, 4);
        table[0xB2] = read_reg(op_or, .d, 4);
        table[0xB3] = read_reg(op_or, .e, 4);
        table[0xB4] = read_reg(op_or, .h, 4);
        table[0xB5] = read_reg(op_or, .l, 4);
        table[0xB6] = read_reg(op_or, .hl_ind, 4);
        table[0xB7] = read_reg(op_or, .a, 4);
        table[0xB8] = read_reg(op_cp, .b, 4);
        table[0xB9] = read_reg(op_cp, .c, 4);
        table[0xBA] = read_reg(op_cp, .d, 4);
        table[0xBB] = read_reg(op_cp, .e, 4);
        table[0xBC] = read_reg(op_cp, .h, 4);
        table[0xBD] = read_reg(op_cp, .l, 4);
        table[0xBE] = read_reg(op_cp, .hl_ind, 4);
        table[0xBF] = read_reg(op_cp, .a, 4);

        // ── ALU immediate ──
        table[0xC6] = read_imm(op_add, 8);
        table[0xCE] = read_imm(op_adc, 8);
        table[0xD6] = read_imm(op_sub, 8);
        table[0xDE] = read_imm(op_sbc, 8);
        table[0xE6] = read_imm(op_and, 8);
        table[0xEE] = read_imm(op_xor, 8);
        table[0xF6] = read_imm(op_or, 8);
        table[0xFE] = read_imm(op_cp, 8);

        // ── INC r ──
        table[0x04] = rmw_reg(op_inc8, .b, 4);
        table[0x0C] = rmw_reg(op_inc8, .c, 4);
        table[0x14] = rmw_reg(op_inc8, .d, 4);
        table[0x1C] = rmw_reg(op_inc8, .e, 4);
        table[0x24] = rmw_reg(op_inc8, .h, 4);
        table[0x2C] = rmw_reg(op_inc8, .l, 4);
        table[0x34] = rmw_reg(op_inc8, .hl_ind, 4);
        table[0x3C] = rmw_reg(op_inc8, .a, 4);

        // ── DEC r ──
        table[0x05] = rmw_reg(op_dec8, .b, 4);
        table[0x0D] = rmw_reg(op_dec8, .c, 4);
        table[0x15] = rmw_reg(op_dec8, .d, 4);
        table[0x1D] = rmw_reg(op_dec8, .e, 4);
        table[0x25] = rmw_reg(op_dec8, .h, 4);
        table[0x2D] = rmw_reg(op_dec8, .l, 4);
        table[0x35] = rmw_reg(op_dec8, .hl_ind, 4);
        table[0x3D] = rmw_reg(op_dec8, .a, 4);

        // ── JR cc,n ──
        table[0x20] = jrCond(.nz);
        table[0x28] = jrCond(.z);
        table[0x30] = jrCond(.nc);
        table[0x38] = jrCond(.c);

        // ── JP cc,nn ──
        table[0xC2] = jpCond(.nz);
        table[0xCA] = jpCond(.z);
        table[0xD2] = jpCond(.nc);
        table[0xDA] = jpCond(.c);

        // ── CALL cc,nn ──
        table[0xC4] = callCond(.nz);
        table[0xCC] = callCond(.z);
        table[0xD4] = callCond(.nc);
        table[0xDC] = callCond(.c);

        // ── RET cc ──
        table[0xC0] = retCond(.nz);
        table[0xC8] = retCond(.z);
        table[0xD0] = retCond(.nc);
        table[0xD8] = retCond(.c);

        // ── RST ──
        table[0xC7] = rstVec(0x00);
        table[0xCF] = rstVec(0x08);
        table[0xD7] = rstVec(0x10);
        table[0xDF] = rstVec(0x18);
        table[0xE7] = rstVec(0x20);
        table[0xEF] = rstVec(0x28);
        table[0xF7] = rstVec(0x30);
        table[0xFF] = rstVec(0x38);

        // ── Unique opcodes ──
        table[0x00] = &execNop;
        table[0x10] = &execStop;
        table[0x76] = &execHalt;
        table[0xF3] = &execDI;
        table[0xFB] = &execEI;
        table[0x27] = &execDAA;
        table[0x2F] = &execCPL;
        table[0x3F] = &execCCF;
        table[0x37] = &execSCF;

        // ── Rotates A ──
        table[0x07] = &execRLCA;
        table[0x17] = &execRLA;
        table[0x0F] = &execRRCA;
        table[0x1F] = &execRRA;

        // ── JP / JR unconditional ──
        table[0xC3] = &execJP;
        table[0xE9] = &execJPHL;
        table[0x18] = &execJR;

        // ── CALL / RET unconditional ──
        table[0xCD] = &execCALL;
        table[0xC9] = &execRET;
        table[0xD9] = &execRETI;

        // ── 16-bit register pair ops (BC/DE/HL/SP) ──
        table[0x01] = ld_rr16_imm(.bc);
        table[0x11] = ld_rr16_imm(.de);
        table[0x21] = ld_rr16_imm(.hl);
        table[0x31] = ld_rr16_imm(.sp);
        table[0x03] = inc16(.bc);
        table[0x13] = inc16(.de);
        table[0x23] = inc16(.hl);
        table[0x33] = inc16(.sp);
        table[0x09] = add_hl_rr(.bc);
        table[0x19] = add_hl_rr(.de);
        table[0x29] = add_hl_rr(.hl);
        table[0x39] = add_hl_rr(.sp);
        table[0x0B] = dec16(.bc);
        table[0x1B] = dec16(.de);
        table[0x2B] = dec16(.hl);
        table[0x3B] = dec16(.sp);

        // ── PUSH / POP (BC/DE/HL/AF) ──
        table[0xC5] = push_rr(.bc);
        table[0xD5] = push_rr(.de);
        table[0xE5] = push_rr(.hl);
        table[0xF5] = push_rr(.af);
        table[0xC1] = pop_rr(.bc);
        table[0xD1] = pop_rr(.de);
        table[0xE1] = pop_rr(.hl);
        table[0xF1] = pop_rr(.af);

        // ── 16-bit arithmetic (unique) ──
        table[0xE8] = &execADD_SP_n;

        // ── 16-bit loads (unique) ──
        table[0xF9] = &execLD_SP_HL;
        table[0xF8] = &execLD_HL_SPn;
        table[0x08] = &execLD_nn_SP;

        // ── Special loads ──
        table[0x0A] = ld_a_rr_ind(.bc);
        table[0x1A] = ld_a_rr_ind(.de);
        table[0x02] = ld_rr_ind_a(.bc);
        table[0x12] = ld_rr_ind_a(.de);
        table[0xFA] = &execLD_A_nn;
        table[0xEA] = &execLD_nn_A;
        table[0xF2] = &execLD_A_Cio;
        table[0xE2] = &execLD_Cio_A;
        table[0x3A] = &execLDD_A_HL;
        table[0x32] = &execLDD_HL_A;
        table[0x2A] = &execLDI_A_HL;
        table[0x22] = &execLDI_HL_A;
        table[0xE0] = &execLDH_n_A;
        table[0xF0] = &execLDH_A_n;

        // ── CB prefix ──
        table[0xCB] = &execCBPrefix;

        return table;
    }

    fn initCBTable() [256]Handler {
        var table: [256]Handler = .{&execUnimplemented} ** 256;

        // ── Shift/rotate operations (0x00-0x3F) ──
        table[0x00] = rmw_reg(op_rlc, .b, 8);
        table[0x01] = rmw_reg(op_rlc, .c, 8);
        table[0x02] = rmw_reg(op_rlc, .d, 8);
        table[0x03] = rmw_reg(op_rlc, .e, 8);
        table[0x04] = rmw_reg(op_rlc, .h, 8);
        table[0x05] = rmw_reg(op_rlc, .l, 8);
        table[0x06] = rmw_reg(op_rlc, .hl_ind, 8);
        table[0x07] = rmw_reg(op_rlc, .a, 8);
        table[0x08] = rmw_reg(op_rrc, .b, 8);
        table[0x09] = rmw_reg(op_rrc, .c, 8);
        table[0x0A] = rmw_reg(op_rrc, .d, 8);
        table[0x0B] = rmw_reg(op_rrc, .e, 8);
        table[0x0C] = rmw_reg(op_rrc, .h, 8);
        table[0x0D] = rmw_reg(op_rrc, .l, 8);
        table[0x0E] = rmw_reg(op_rrc, .hl_ind, 8);
        table[0x0F] = rmw_reg(op_rrc, .a, 8);
        table[0x10] = rmw_reg(op_rl, .b, 8);
        table[0x11] = rmw_reg(op_rl, .c, 8);
        table[0x12] = rmw_reg(op_rl, .d, 8);
        table[0x13] = rmw_reg(op_rl, .e, 8);
        table[0x14] = rmw_reg(op_rl, .h, 8);
        table[0x15] = rmw_reg(op_rl, .l, 8);
        table[0x16] = rmw_reg(op_rl, .hl_ind, 8);
        table[0x17] = rmw_reg(op_rl, .a, 8);
        table[0x18] = rmw_reg(op_rr, .b, 8);
        table[0x19] = rmw_reg(op_rr, .c, 8);
        table[0x1A] = rmw_reg(op_rr, .d, 8);
        table[0x1B] = rmw_reg(op_rr, .e, 8);
        table[0x1C] = rmw_reg(op_rr, .h, 8);
        table[0x1D] = rmw_reg(op_rr, .l, 8);
        table[0x1E] = rmw_reg(op_rr, .hl_ind, 8);
        table[0x1F] = rmw_reg(op_rr, .a, 8);
        table[0x20] = rmw_reg(op_sla, .b, 8);
        table[0x21] = rmw_reg(op_sla, .c, 8);
        table[0x22] = rmw_reg(op_sla, .d, 8);
        table[0x23] = rmw_reg(op_sla, .e, 8);
        table[0x24] = rmw_reg(op_sla, .h, 8);
        table[0x25] = rmw_reg(op_sla, .l, 8);
        table[0x26] = rmw_reg(op_sla, .hl_ind, 8);
        table[0x27] = rmw_reg(op_sla, .a, 8);
        table[0x28] = rmw_reg(op_sra, .b, 8);
        table[0x29] = rmw_reg(op_sra, .c, 8);
        table[0x2A] = rmw_reg(op_sra, .d, 8);
        table[0x2B] = rmw_reg(op_sra, .e, 8);
        table[0x2C] = rmw_reg(op_sra, .h, 8);
        table[0x2D] = rmw_reg(op_sra, .l, 8);
        table[0x2E] = rmw_reg(op_sra, .hl_ind, 8);
        table[0x2F] = rmw_reg(op_sra, .a, 8);
        table[0x30] = rmw_reg(op_swap, .b, 8);
        table[0x31] = rmw_reg(op_swap, .c, 8);
        table[0x32] = rmw_reg(op_swap, .d, 8);
        table[0x33] = rmw_reg(op_swap, .e, 8);
        table[0x34] = rmw_reg(op_swap, .h, 8);
        table[0x35] = rmw_reg(op_swap, .l, 8);
        table[0x36] = rmw_reg(op_swap, .hl_ind, 8);
        table[0x37] = rmw_reg(op_swap, .a, 8);
        table[0x38] = rmw_reg(op_srl, .b, 8);
        table[0x39] = rmw_reg(op_srl, .c, 8);
        table[0x3A] = rmw_reg(op_srl, .d, 8);
        table[0x3B] = rmw_reg(op_srl, .e, 8);
        table[0x3C] = rmw_reg(op_srl, .h, 8);
        table[0x3D] = rmw_reg(op_srl, .l, 8);
        table[0x3E] = rmw_reg(op_srl, .hl_ind, 8);
        table[0x3F] = rmw_reg(op_srl, .a, 8);

        // ── BIT (0x40-0x7F) ──
        table[0x40] = read_reg(bit_n(0), .b, 8);
        table[0x41] = read_reg(bit_n(0), .c, 8);
        table[0x42] = read_reg(bit_n(0), .d, 8);
        table[0x43] = read_reg(bit_n(0), .e, 8);
        table[0x44] = read_reg(bit_n(0), .h, 8);
        table[0x45] = read_reg(bit_n(0), .l, 8);
        table[0x46] = read_reg(bit_n(0), .hl_ind, 8);
        table[0x47] = read_reg(bit_n(0), .a, 8);
        table[0x48] = read_reg(bit_n(1), .b, 8);
        table[0x49] = read_reg(bit_n(1), .c, 8);
        table[0x4A] = read_reg(bit_n(1), .d, 8);
        table[0x4B] = read_reg(bit_n(1), .e, 8);
        table[0x4C] = read_reg(bit_n(1), .h, 8);
        table[0x4D] = read_reg(bit_n(1), .l, 8);
        table[0x4E] = read_reg(bit_n(1), .hl_ind, 8);
        table[0x4F] = read_reg(bit_n(1), .a, 8);
        table[0x50] = read_reg(bit_n(2), .b, 8);
        table[0x51] = read_reg(bit_n(2), .c, 8);
        table[0x52] = read_reg(bit_n(2), .d, 8);
        table[0x53] = read_reg(bit_n(2), .e, 8);
        table[0x54] = read_reg(bit_n(2), .h, 8);
        table[0x55] = read_reg(bit_n(2), .l, 8);
        table[0x56] = read_reg(bit_n(2), .hl_ind, 8);
        table[0x57] = read_reg(bit_n(2), .a, 8);
        table[0x58] = read_reg(bit_n(3), .b, 8);
        table[0x59] = read_reg(bit_n(3), .c, 8);
        table[0x5A] = read_reg(bit_n(3), .d, 8);
        table[0x5B] = read_reg(bit_n(3), .e, 8);
        table[0x5C] = read_reg(bit_n(3), .h, 8);
        table[0x5D] = read_reg(bit_n(3), .l, 8);
        table[0x5E] = read_reg(bit_n(3), .hl_ind, 8);
        table[0x5F] = read_reg(bit_n(3), .a, 8);
        table[0x60] = read_reg(bit_n(4), .b, 8);
        table[0x61] = read_reg(bit_n(4), .c, 8);
        table[0x62] = read_reg(bit_n(4), .d, 8);
        table[0x63] = read_reg(bit_n(4), .e, 8);
        table[0x64] = read_reg(bit_n(4), .h, 8);
        table[0x65] = read_reg(bit_n(4), .l, 8);
        table[0x66] = read_reg(bit_n(4), .hl_ind, 8);
        table[0x67] = read_reg(bit_n(4), .a, 8);
        table[0x68] = read_reg(bit_n(5), .b, 8);
        table[0x69] = read_reg(bit_n(5), .c, 8);
        table[0x6A] = read_reg(bit_n(5), .d, 8);
        table[0x6B] = read_reg(bit_n(5), .e, 8);
        table[0x6C] = read_reg(bit_n(5), .h, 8);
        table[0x6D] = read_reg(bit_n(5), .l, 8);
        table[0x6E] = read_reg(bit_n(5), .hl_ind, 8);
        table[0x6F] = read_reg(bit_n(5), .a, 8);
        table[0x70] = read_reg(bit_n(6), .b, 8);
        table[0x71] = read_reg(bit_n(6), .c, 8);
        table[0x72] = read_reg(bit_n(6), .d, 8);
        table[0x73] = read_reg(bit_n(6), .e, 8);
        table[0x74] = read_reg(bit_n(6), .h, 8);
        table[0x75] = read_reg(bit_n(6), .l, 8);
        table[0x76] = read_reg(bit_n(6), .hl_ind, 8);
        table[0x77] = read_reg(bit_n(6), .a, 8);
        table[0x78] = read_reg(bit_n(7), .b, 8);
        table[0x79] = read_reg(bit_n(7), .c, 8);
        table[0x7A] = read_reg(bit_n(7), .d, 8);
        table[0x7B] = read_reg(bit_n(7), .e, 8);
        table[0x7C] = read_reg(bit_n(7), .h, 8);
        table[0x7D] = read_reg(bit_n(7), .l, 8);
        table[0x7E] = read_reg(bit_n(7), .hl_ind, 8);
        table[0x7F] = read_reg(bit_n(7), .a, 8);

        // ── RES (0x80-0xBF) ──
        table[0x80] = rmw_reg(res_n(0), .b, 8);
        table[0x81] = rmw_reg(res_n(0), .c, 8);
        table[0x82] = rmw_reg(res_n(0), .d, 8);
        table[0x83] = rmw_reg(res_n(0), .e, 8);
        table[0x84] = rmw_reg(res_n(0), .h, 8);
        table[0x85] = rmw_reg(res_n(0), .l, 8);
        table[0x86] = rmw_reg(res_n(0), .hl_ind, 8);
        table[0x87] = rmw_reg(res_n(0), .a, 8);
        table[0x88] = rmw_reg(res_n(1), .b, 8);
        table[0x89] = rmw_reg(res_n(1), .c, 8);
        table[0x8A] = rmw_reg(res_n(1), .d, 8);
        table[0x8B] = rmw_reg(res_n(1), .e, 8);
        table[0x8C] = rmw_reg(res_n(1), .h, 8);
        table[0x8D] = rmw_reg(res_n(1), .l, 8);
        table[0x8E] = rmw_reg(res_n(1), .hl_ind, 8);
        table[0x8F] = rmw_reg(res_n(1), .a, 8);
        table[0x90] = rmw_reg(res_n(2), .b, 8);
        table[0x91] = rmw_reg(res_n(2), .c, 8);
        table[0x92] = rmw_reg(res_n(2), .d, 8);
        table[0x93] = rmw_reg(res_n(2), .e, 8);
        table[0x94] = rmw_reg(res_n(2), .h, 8);
        table[0x95] = rmw_reg(res_n(2), .l, 8);
        table[0x96] = rmw_reg(res_n(2), .hl_ind, 8);
        table[0x97] = rmw_reg(res_n(2), .a, 8);
        table[0x98] = rmw_reg(res_n(3), .b, 8);
        table[0x99] = rmw_reg(res_n(3), .c, 8);
        table[0x9A] = rmw_reg(res_n(3), .d, 8);
        table[0x9B] = rmw_reg(res_n(3), .e, 8);
        table[0x9C] = rmw_reg(res_n(3), .h, 8);
        table[0x9D] = rmw_reg(res_n(3), .l, 8);
        table[0x9E] = rmw_reg(res_n(3), .hl_ind, 8);
        table[0x9F] = rmw_reg(res_n(3), .a, 8);
        table[0xA0] = rmw_reg(res_n(4), .b, 8);
        table[0xA1] = rmw_reg(res_n(4), .c, 8);
        table[0xA2] = rmw_reg(res_n(4), .d, 8);
        table[0xA3] = rmw_reg(res_n(4), .e, 8);
        table[0xA4] = rmw_reg(res_n(4), .h, 8);
        table[0xA5] = rmw_reg(res_n(4), .l, 8);
        table[0xA6] = rmw_reg(res_n(4), .hl_ind, 8);
        table[0xA7] = rmw_reg(res_n(4), .a, 8);
        table[0xA8] = rmw_reg(res_n(5), .b, 8);
        table[0xA9] = rmw_reg(res_n(5), .c, 8);
        table[0xAA] = rmw_reg(res_n(5), .d, 8);
        table[0xAB] = rmw_reg(res_n(5), .e, 8);
        table[0xAC] = rmw_reg(res_n(5), .h, 8);
        table[0xAD] = rmw_reg(res_n(5), .l, 8);
        table[0xAE] = rmw_reg(res_n(5), .hl_ind, 8);
        table[0xAF] = rmw_reg(res_n(5), .a, 8);
        table[0xB0] = rmw_reg(res_n(6), .b, 8);
        table[0xB1] = rmw_reg(res_n(6), .c, 8);
        table[0xB2] = rmw_reg(res_n(6), .d, 8);
        table[0xB3] = rmw_reg(res_n(6), .e, 8);
        table[0xB4] = rmw_reg(res_n(6), .h, 8);
        table[0xB5] = rmw_reg(res_n(6), .l, 8);
        table[0xB6] = rmw_reg(res_n(6), .hl_ind, 8);
        table[0xB7] = rmw_reg(res_n(6), .a, 8);
        table[0xB8] = rmw_reg(res_n(7), .b, 8);
        table[0xB9] = rmw_reg(res_n(7), .c, 8);
        table[0xBA] = rmw_reg(res_n(7), .d, 8);
        table[0xBB] = rmw_reg(res_n(7), .e, 8);
        table[0xBC] = rmw_reg(res_n(7), .h, 8);
        table[0xBD] = rmw_reg(res_n(7), .l, 8);
        table[0xBE] = rmw_reg(res_n(7), .hl_ind, 8);
        table[0xBF] = rmw_reg(res_n(7), .a, 8);

        // ── SET (0xC0-0xFF) ──
        table[0xC0] = rmw_reg(set_n(0), .b, 8);
        table[0xC1] = rmw_reg(set_n(0), .c, 8);
        table[0xC2] = rmw_reg(set_n(0), .d, 8);
        table[0xC3] = rmw_reg(set_n(0), .e, 8);
        table[0xC4] = rmw_reg(set_n(0), .h, 8);
        table[0xC5] = rmw_reg(set_n(0), .l, 8);
        table[0xC6] = rmw_reg(set_n(0), .hl_ind, 8);
        table[0xC7] = rmw_reg(set_n(0), .a, 8);
        table[0xC8] = rmw_reg(set_n(1), .b, 8);
        table[0xC9] = rmw_reg(set_n(1), .c, 8);
        table[0xCA] = rmw_reg(set_n(1), .d, 8);
        table[0xCB] = rmw_reg(set_n(1), .e, 8);
        table[0xCC] = rmw_reg(set_n(1), .h, 8);
        table[0xCD] = rmw_reg(set_n(1), .l, 8);
        table[0xCE] = rmw_reg(set_n(1), .hl_ind, 8);
        table[0xCF] = rmw_reg(set_n(1), .a, 8);
        table[0xD0] = rmw_reg(set_n(2), .b, 8);
        table[0xD1] = rmw_reg(set_n(2), .c, 8);
        table[0xD2] = rmw_reg(set_n(2), .d, 8);
        table[0xD3] = rmw_reg(set_n(2), .e, 8);
        table[0xD4] = rmw_reg(set_n(2), .h, 8);
        table[0xD5] = rmw_reg(set_n(2), .l, 8);
        table[0xD6] = rmw_reg(set_n(2), .hl_ind, 8);
        table[0xD7] = rmw_reg(set_n(2), .a, 8);
        table[0xD8] = rmw_reg(set_n(3), .b, 8);
        table[0xD9] = rmw_reg(set_n(3), .c, 8);
        table[0xDA] = rmw_reg(set_n(3), .d, 8);
        table[0xDB] = rmw_reg(set_n(3), .e, 8);
        table[0xDC] = rmw_reg(set_n(3), .h, 8);
        table[0xDD] = rmw_reg(set_n(3), .l, 8);
        table[0xDE] = rmw_reg(set_n(3), .hl_ind, 8);
        table[0xDF] = rmw_reg(set_n(3), .a, 8);
        table[0xE0] = rmw_reg(set_n(4), .b, 8);
        table[0xE1] = rmw_reg(set_n(4), .c, 8);
        table[0xE2] = rmw_reg(set_n(4), .d, 8);
        table[0xE3] = rmw_reg(set_n(4), .e, 8);
        table[0xE4] = rmw_reg(set_n(4), .h, 8);
        table[0xE5] = rmw_reg(set_n(4), .l, 8);
        table[0xE6] = rmw_reg(set_n(4), .hl_ind, 8);
        table[0xE7] = rmw_reg(set_n(4), .a, 8);
        table[0xE8] = rmw_reg(set_n(5), .b, 8);
        table[0xE9] = rmw_reg(set_n(5), .c, 8);
        table[0xEA] = rmw_reg(set_n(5), .d, 8);
        table[0xEB] = rmw_reg(set_n(5), .e, 8);
        table[0xEC] = rmw_reg(set_n(5), .h, 8);
        table[0xED] = rmw_reg(set_n(5), .l, 8);
        table[0xEE] = rmw_reg(set_n(5), .hl_ind, 8);
        table[0xEF] = rmw_reg(set_n(5), .a, 8);
        table[0xF0] = rmw_reg(set_n(6), .b, 8);
        table[0xF1] = rmw_reg(set_n(6), .c, 8);
        table[0xF2] = rmw_reg(set_n(6), .d, 8);
        table[0xF3] = rmw_reg(set_n(6), .e, 8);
        table[0xF4] = rmw_reg(set_n(6), .h, 8);
        table[0xF5] = rmw_reg(set_n(6), .l, 8);
        table[0xF6] = rmw_reg(set_n(6), .hl_ind, 8);
        table[0xF7] = rmw_reg(set_n(6), .a, 8);
        table[0xF8] = rmw_reg(set_n(7), .b, 8);
        table[0xF9] = rmw_reg(set_n(7), .c, 8);
        table[0xFA] = rmw_reg(set_n(7), .d, 8);
        table[0xFB] = rmw_reg(set_n(7), .e, 8);
        table[0xFC] = rmw_reg(set_n(7), .h, 8);
        table[0xFD] = rmw_reg(set_n(7), .l, 8);
        table[0xFE] = rmw_reg(set_n(7), .hl_ind, 8);
        table[0xFF] = rmw_reg(set_n(7), .a, 8);

        return table;
    }

    // ── Unique opcode handlers ──────────────────────────────────────

    fn execNop(self: *CPU) void {
        self.cycles = 4;
    }

    fn execStop(self: *CPU) void {
        self.cycles = 4;
    }

    fn execHalt(self: *CPU) void {
        self.halted = true;
        self.cycles = 4;
    }

    fn execDI(self: *CPU) void {
        self.interrupt_master_enable = false;
        self.cycles = 4;
    }

    fn execEI(self: *CPU) void {
        self.ei_pending = true;
        self.cycles = 4;
    }

    fn execDAA(self: *CPU) void {
        self.daa();
        self.cycles = 4;
    }

    fn execCPL(self: *CPU) void {
        self.a = ~self.a;
        self.f.n = true;
        self.f.half = true;
        self.cycles = 4;
    }

    fn execCCF(self: *CPU) void {
        self.f.n = false;
        self.f.half = false;
        self.f.carry = !self.f.carry;
        self.cycles = 4;
    }

    fn execSCF(self: *CPU) void {
        self.f.n = false;
        self.f.half = false;
        self.f.carry = true;
        self.cycles = 4;
    }

    fn execRLCA(self: *CPU) void {
        self.a = self.op_rlc(self.a);
        self.f.zero = false;
        self.cycles = 4;
    }

    fn execRLA(self: *CPU) void {
        self.a = self.op_rl(self.a);
        self.f.zero = false;
        self.cycles = 4;
    }

    fn execRRCA(self: *CPU) void {
        self.a = self.op_rrc(self.a);
        self.f.zero = false;
        self.cycles = 4;
    }

    fn execRRA(self: *CPU) void {
        self.a = self.op_rr(self.a);
        self.f.zero = false;
        self.cycles = 4;
    }

    fn execJP(self: *CPU) void {
        self.pc = self.getImmU16();
        self.cycles = 16;
    }

    fn execJPHL(self: *CPU) void {
        self.pc = self.getHL();
        self.cycles = 4;
    }

    fn execJR(self: *CPU) void {
        const n = self.getImmI8();
        self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n));
        self.cycles = 12;
    }

    fn execCALL(self: *CPU) void {
        const nn = self.getImmU16();
        self.doCall(nn);
        self.cycles = 24;
    }

    fn execRET(self: *CPU) void {
        self.doRet();
        self.cycles = 16;
    }

    fn execRETI(self: *CPU) void {
        self.doRet();
        self.interrupt_master_enable = true;
        self.cycles = 16;
    }

    fn execLD_SP_HL(self: *CPU) void {
        self.sp = self.getHL();
        self.cycles = 8;
    }

    fn execLD_HL_SPn(self: *CPU) void {
        const r = self.add16Imm(self.sp);
        self.setHL(r);
        self.cycles = 12;
    }

    fn execLD_nn_SP(self: *CPU) void {
        const addr = self.getImmU16();
        self.writeByte(addr, @truncate(self.sp));
        self.writeByte(addr +% 1, @truncate(self.sp >> 8));
        self.cycles = 20;
    }

    fn execADD_SP_n(self: *CPU) void {
        self.sp = self.add16Imm(self.sp);
        self.cycles = 16;
    }

    fn execLD_A_nn(self: *CPU) void {
        const addr = self.getImmU16();
        self.a = self.readByte(addr);
        self.cycles = 16;
    }

    fn execLD_nn_A(self: *CPU) void {
        const addr = self.getImmU16();
        self.writeByte(addr, self.a);
        self.cycles = 16;
    }

    fn execLD_A_Cio(self: *CPU) void {
        self.a = self.readByte(0xff00 + @as(u16, self.c));
        self.cycles = 8;
    }

    fn execLD_Cio_A(self: *CPU) void {
        self.writeByte(0xff00 + @as(u16, self.c), self.a);
        self.cycles = 8;
    }

    fn execLDD_A_HL(self: *CPU) void {
        const hl = self.hld();
        self.a = self.readByte(hl);
        self.cycles = 8;
    }

    fn execLDD_HL_A(self: *CPU) void {
        const hl = self.hld();
        self.writeByte(hl, self.a);
        self.cycles = 8;
    }

    fn execLDI_A_HL(self: *CPU) void {
        const hl = self.hli();
        self.a = self.readByte(hl);
        self.cycles = 8;
    }

    fn execLDI_HL_A(self: *CPU) void {
        self.writeByte(self.getHL(), self.a);
        _ = self.hli();
        self.cycles = 8;
    }

    fn execLDH_n_A(self: *CPU) void {
        const n = self.getImmU8();
        self.writeByte(0xff00 + @as(u16, n), self.a);
        self.cycles = 12;
    }

    fn execLDH_A_n(self: *CPU) void {
        const n = self.getImmU8();
        self.a = self.readByte(0xff00 + @as(u16, n));
        self.cycles = 12;
    }

    fn execCBPrefix(self: *CPU) void {
        const cb_op = self.readByte(self.pc);
        self.pc +%= 1;
        cb_table[cb_op](self);
    }

    fn execUnimplemented(self: *CPU) void {
        std.debug.print("Unimplemented opcode at PC=0x{X:0>4}\n", .{self.pc -% 1});
        self.cycles = 4;
    }

    // ── Main step ───────────────────────────────────────────────────

    pub fn next(self: *CPU) u32 {
        if (self.ei_pending) {
            self.ei_pending = false;
            self.interrupt_master_enable = true;
        }
        if (self.checkAndExecuteInterrupts()) return 20;
        if (self.halted) return 4;

        const op = self.readByte(self.pc);
        self.pc +%= 1;
        opcode_table[op](self);
        return self.cycles;
    }
};
