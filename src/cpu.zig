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

    // ── Register pairs ──────────────────────────────────────────────────

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

    // ── Memory access ───────────────────────────────────────────────────

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

    // ── Stack operations ────────────────────────────────────────────────

    fn pushU8(self: *CPU, n: u8) void {
        self.sp -%= 1;
        self.writeByte(self.sp, n);
    }

    fn pushU16(self: *CPU, n: u16) void {
        self.pushU8(@truncate(n >> 8));
        self.pushU8(@truncate(n));
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

    // ── ALU helpers ─────────────────────────────────────────────────────

    fn getCarry(self: *const CPU) u8 {
        return if (self.f.carry) 1 else 0;
    }

    fn addA(self: *CPU, n: u8) void {
        const result = @addWithOverflow(self.a, n);
        self.f = .{
            .zero = result[0] == 0,
            .n = false,
            .half = ((self.a & 0xf) + (n & 0xf)) & 0x10 != 0,
            .carry = result[1] != 0,
        };
        self.a = result[0];
    }

    fn adcA(self: *CPU, n: u8) void {
        const carry = self.getCarry();
        const r = self.a +% n +% carry;
        self.f = .{
            .zero = r == 0,
            .n = false,
            .half = (self.a & 0xf) + (n & 0xf) + carry > 0xf,
            .carry = @as(u16, self.a) + @as(u16, n) + @as(u16, carry) > 0xff,
        };
        self.a = r;
    }

    fn subA(self: *CPU, n: u8) void {
        const result = @subWithOverflow(self.a, n);
        self.f = .{
            .zero = result[0] == 0,
            .n = true,
            .half = (self.a & 0xf) < (n & 0xf),
            .carry = result[1] != 0,
        };
        self.a = result[0];
    }

    fn sbcA(self: *CPU, n: u8) void {
        const carry = self.getCarry();
        const r = self.a -% n -% carry;
        self.f = .{
            .zero = r == 0,
            .n = true,
            .half = (self.a & 0x0f) < (n & 0x0f) + carry,
            .carry = @as(u16, self.a) < @as(u16, n) + @as(u16, carry),
        };
        self.a = r;
    }

    fn andA(self: *CPU, n: u8) void {
        self.a &= n;
        self.f = .{ .zero = self.a == 0, .half = true };
    }

    fn orA(self: *CPU, n: u8) void {
        self.a |= n;
        self.f = .{ .zero = self.a == 0 };
    }

    fn xorA(self: *CPU, n: u8) void {
        self.a ^= n;
        self.f = .{ .zero = self.a == 0 };
    }

    fn cpA(self: *CPU, n: u8) void {
        const result = @subWithOverflow(self.a, n);
        self.f = .{
            .zero = result[0] == 0,
            .n = true,
            .half = (self.a & 0xf) < (n & 0xf),
            .carry = result[1] != 0,
        };
    }

    fn incFlags(self: *CPU, prev: u8, new: u8) void {
        self.f.zero = new == 0;
        self.f.n = false;
        self.f.half = ((prev & 0xf) + 1) & 0x10 == 0x10;
    }

    fn decFlags(self: *CPU, prev: u8, new: u8) void {
        self.f.zero = new == 0;
        self.f.n = true;
        self.f.half = (prev & 0xf0) != (new & 0xf0);
    }

    fn addHL16(self: *CPU, n: u16) void {
        const hl = self.getHL();
        const result = @addWithOverflow(hl, n);
        self.f.n = false;
        self.f.half = ((hl & 0xfff) + (n & 0xfff)) & 0x1000 != 0;
        self.f.carry = result[1] != 0;
        self.setHL(result[0]);
    }

    fn add16Imm(self: *CPU, a: u16) u16 {
        const b_i8 = self.getImmI8();
        const b: u16 = @bitCast(@as(i16, b_i8));
        self.f = .{
            .half = (a & 0xf) + (b & 0xf) > 0xf,
            .carry = (a & 0xff) + (b & 0xff) > 0xff,
        };
        return a +% b;
    }

    // ── Rotate / Shift helpers ──────────────────────────────────────────

    fn rlc8(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        var r = v << 1;
        if (carry) r |= 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn rl8(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        var r = v << 1;
        if (self.f.carry) r |= 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn rrc8(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        var r = v >> 1;
        if (carry) r |= 0x80;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn rr8(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        var r = v >> 1;
        if (self.f.carry) r |= 0x80;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn sla8(self: *CPU, v: u8) u8 {
        const carry = (v & 0x80) != 0;
        const r = v << 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn sra8(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        const r = (v >> 1) | (v & 0x80);
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn srl8(self: *CPU, v: u8) u8 {
        const carry = (v & 1) != 0;
        const r = v >> 1;
        self.f = .{ .zero = r == 0, .carry = carry };
        return r;
    }

    fn swap(self: *CPU, n: u8) u8 {
        self.f = .{ .zero = n == 0 };
        return (n >> 4) | (n << 4);
    }

    fn bitTest(self: *CPU, bit: u3, reg: u8) void {
        self.f.zero = (reg >> bit) & 1 == 0;
        self.f.n = false;
        self.f.half = true;
    }

    fn setBit(bit: u3, reg: u8) u8 {
        return reg | (@as(u8, 1) << bit);
    }

    fn resBit(bit: u3, reg: u8) u8 {
        return reg & ~(@as(u8, 1) << bit);
    }

    // ── DAA ─────────────────────────────────────────────────────────────

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

    // ── Call / Ret / RST ────────────────────────────────────────────────

    fn call(self: *CPU, addr: u16) void {
        self.pushU16(self.pc);
        self.pc = addr;
    }

    fn ret(self: *CPU) void {
        self.pc = self.popU16();
    }

    fn rst(self: *CPU, addr: u16) void {
        self.pushU16(self.pc);
        self.pc = addr;
    }

    // ── HLI / HLD ───────────────────────────────────────────────────────

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

    // ── Interrupts ──────────────────────────────────────────────────────

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
                    self.call(addr);
                    return true;
                }
            }
        }

        return false;
    }

    // ── Main step ───────────────────────────────────────────────────────

    pub fn next(self: *CPU) u32 {
        if (self.ei_pending) {
            self.ei_pending = false;
            self.interrupt_master_enable = true;
        }
        if (self.checkAndExecuteInterrupts()) return 20;
        if (self.halted) return 4;

        const pc = self.pc;
        self.pc +%= 1;

        const op = self.readByte(pc);
        const cycles: u32 = switch (op) {
            // ── NOP ──
            0x00 => 4,

            // ── LD nn,n (8-bit immediate loads) ──
            0x06 => { self.b = self.getImmU8(); return 8; },
            0x0E => { self.c = self.getImmU8(); return 8; },
            0x16 => { self.d = self.getImmU8(); return 8; },
            0x1E => { self.e = self.getImmU8(); return 8; },
            0x26 => { self.h = self.getImmU8(); return 8; },
            0x2E => { self.l = self.getImmU8(); return 8; },
            0x3E => { self.a = self.getImmU8(); return 8; },

            // ── LD r,r (register to register) ──
            0x7F => { self.a = self.a; return 4; },
            0x78 => { self.a = self.b; return 4; },
            0x79 => { self.a = self.c; return 4; },
            0x7A => { self.a = self.d; return 4; },
            0x7B => { self.a = self.e; return 4; },
            0x7C => { self.a = self.h; return 4; },
            0x7D => { self.a = self.l; return 4; },
            0x7E => { self.a = self.readByte(self.getHL()); return 8; },

            0x0A => { self.a = self.readByte(self.getBC()); return 8; },
            0x1A => { self.a = self.readByte(self.getDE()); return 8; },
            0xFA => { const addr = self.getImmU16(); self.a = self.readByte(addr); return 16; },

            0x40 => { self.b = self.b; return 4; },
            0x41 => { self.b = self.c; return 4; },
            0x42 => { self.b = self.d; return 4; },
            0x43 => { self.b = self.e; return 4; },
            0x44 => { self.b = self.h; return 4; },
            0x45 => { self.b = self.l; return 4; },
            0x46 => { self.b = self.readByte(self.getHL()); return 8; },

            0x48 => { self.c = self.b; return 4; },
            0x49 => { self.c = self.c; return 4; },
            0x4A => { self.c = self.d; return 4; },
            0x4B => { self.c = self.e; return 4; },
            0x4C => { self.c = self.h; return 4; },
            0x4D => { self.c = self.l; return 4; },
            0x4E => { self.c = self.readByte(self.getHL()); return 8; },

            0x50 => { self.d = self.b; return 4; },
            0x51 => { self.d = self.c; return 4; },
            0x52 => { self.d = self.d; return 4; },
            0x53 => { self.d = self.e; return 4; },
            0x54 => { self.d = self.h; return 4; },
            0x55 => { self.d = self.l; return 4; },
            0x56 => { self.d = self.readByte(self.getHL()); return 8; },

            0x58 => { self.e = self.b; return 4; },
            0x59 => { self.e = self.c; return 4; },
            0x5A => { self.e = self.d; return 4; },
            0x5B => { self.e = self.e; return 4; },
            0x5C => { self.e = self.h; return 4; },
            0x5D => { self.e = self.l; return 4; },
            0x5E => { self.e = self.readByte(self.getHL()); return 8; },

            0x60 => { self.h = self.b; return 4; },
            0x61 => { self.h = self.c; return 4; },
            0x62 => { self.h = self.d; return 4; },
            0x63 => { self.h = self.e; return 4; },
            0x64 => { self.h = self.h; return 4; },
            0x65 => { self.h = self.l; return 4; },
            0x66 => { self.h = self.readByte(self.getHL()); return 8; },

            0x68 => { self.l = self.b; return 4; },
            0x69 => { self.l = self.c; return 4; },
            0x6A => { self.l = self.d; return 4; },
            0x6B => { self.l = self.e; return 4; },
            0x6C => { self.l = self.h; return 4; },
            0x6D => { self.l = self.l; return 4; },
            0x6E => { self.l = self.readByte(self.getHL()); return 8; },

            0x70 => { self.writeByte(self.getHL(), self.b); return 8; },
            0x71 => { self.writeByte(self.getHL(), self.c); return 8; },
            0x72 => { self.writeByte(self.getHL(), self.d); return 8; },
            0x73 => { self.writeByte(self.getHL(), self.e); return 8; },
            0x74 => { self.writeByte(self.getHL(), self.h); return 8; },
            0x75 => { self.writeByte(self.getHL(), self.l); return 8; },
            0x36 => { const n = self.getImmU8(); self.writeByte(self.getHL(), n); return 12; },

            // ── LD n,A ──
            0x47 => { self.b = self.a; return 4; },
            0x4F => { self.c = self.a; return 4; },
            0x57 => { self.d = self.a; return 4; },
            0x5F => { self.e = self.a; return 4; },
            0x67 => { self.h = self.a; return 4; },
            0x6F => { self.l = self.a; return 4; },
            0x02 => { self.writeByte(self.getBC(), self.a); return 8; },
            0x12 => { self.writeByte(self.getDE(), self.a); return 8; },
            0x77 => { self.writeByte(self.getHL(), self.a); return 8; },
            0xEA => { const addr = self.getImmU16(); self.writeByte(addr, self.a); return 16; },

            // ── LD A,(C) / LD (C),A ──
            0xF2 => { self.a = self.readByte(0xff00 + @as(u16, self.c)); return 8; },
            0xE2 => { self.writeByte(0xff00 + @as(u16, self.c), self.a); return 8; },

            // ── LDD / LDI ──
            0x3A => { const hl = self.hld(); self.a = self.readByte(hl); return 8; },
            0x32 => { const hl = self.hld(); self.writeByte(hl, self.a); return 8; },
            0x2A => { const hl = self.hli(); self.a = self.readByte(hl); return 8; },
            0x22 => { self.writeByte(self.getHL(), self.a); _ = self.hli(); return 8; },

            // ── LDH ──
            0xE0 => { const n = self.getImmU8(); self.writeByte(0xff00 + @as(u16, n), self.a); return 12; },
            0xF0 => { const n = self.getImmU8(); self.a = self.readByte(0xff00 + @as(u16, n)); return 12; },

            // ── 16-bit loads ──
            0x01 => { const nn = self.getImmU16(); self.setBC(nn); return 12; },
            0x11 => { const nn = self.getImmU16(); self.setDE(nn); return 12; },
            0x21 => { const nn = self.getImmU16(); self.setHL(nn); return 12; },
            0x31 => { self.sp = self.getImmU16(); return 12; },
            0xF9 => { self.sp = self.getHL(); return 8; },
            0xF8 => { const r = self.add16Imm(self.sp); self.setHL(r); return 12; },
            0x08 => {
                const addr = self.getImmU16();
                self.writeByte(addr, @truncate(self.sp));
                self.writeByte(addr +% 1, @truncate(self.sp >> 8));
                return 20;
            },

            // ── PUSH / POP ──
            0xC5 => { self.pushU16(self.getBC()); return 16; },
            0xD5 => { self.pushU16(self.getDE()); return 16; },
            0xE5 => { self.pushU16(self.getHL()); return 16; },
            0xF5 => { self.pushU16(self.getAF()); return 16; },
            0xC1 => { self.c = self.popU8(); self.b = self.popU8(); return 12; },
            0xD1 => { self.e = self.popU8(); self.d = self.popU8(); return 12; },
            0xE1 => { self.l = self.popU8(); self.h = self.popU8(); return 12; },
            0xF1 => { self.f = @bitCast(self.popU8() & 0xf0); self.a = self.popU8(); return 12; },

            // ── 8-bit ALU: ADD A,n ──
            0x87 => { self.addA(self.a); return 4; },
            0x80 => { self.addA(self.b); return 4; },
            0x81 => { self.addA(self.c); return 4; },
            0x82 => { self.addA(self.d); return 4; },
            0x83 => { self.addA(self.e); return 4; },
            0x84 => { self.addA(self.h); return 4; },
            0x85 => { self.addA(self.l); return 4; },
            0x86 => { self.addA(self.readByte(self.getHL())); return 8; },
            0xC6 => { const n = self.getImmU8(); self.addA(n); return 8; },

            // ── ADC A,n ──
            0x8F => { self.adcA(self.a); return 4; },
            0x88 => { self.adcA(self.b); return 4; },
            0x89 => { self.adcA(self.c); return 4; },
            0x8A => { self.adcA(self.d); return 4; },
            0x8B => { self.adcA(self.e); return 4; },
            0x8C => { self.adcA(self.h); return 4; },
            0x8D => { self.adcA(self.l); return 4; },
            0x8E => { self.adcA(self.readByte(self.getHL())); return 8; },
            0xCE => { const n = self.getImmU8(); self.adcA(n); return 8; },

            // ── SUB n ──
            0x97 => { self.subA(self.a); return 4; },
            0x90 => { self.subA(self.b); return 4; },
            0x91 => { self.subA(self.c); return 4; },
            0x92 => { self.subA(self.d); return 4; },
            0x93 => { self.subA(self.e); return 4; },
            0x94 => { self.subA(self.h); return 4; },
            0x95 => { self.subA(self.l); return 4; },
            0x96 => { self.subA(self.readByte(self.getHL())); return 8; },
            0xD6 => { const n = self.getImmU8(); self.subA(n); return 8; },

            // ── SBC A,n ──
            0x9F => { self.sbcA(self.a); return 4; },
            0x98 => { self.sbcA(self.b); return 4; },
            0x99 => { self.sbcA(self.c); return 4; },
            0x9A => { self.sbcA(self.d); return 4; },
            0x9B => { self.sbcA(self.e); return 4; },
            0x9C => { self.sbcA(self.h); return 4; },
            0x9D => { self.sbcA(self.l); return 4; },
            0x9E => { self.sbcA(self.readByte(self.getHL())); return 8; },
            0xDE => { const n = self.getImmU8(); self.sbcA(n); return 8; },

            // ── AND n ──
            0xA7 => { self.andA(self.a); return 4; },
            0xA0 => { self.andA(self.b); return 4; },
            0xA1 => { self.andA(self.c); return 4; },
            0xA2 => { self.andA(self.d); return 4; },
            0xA3 => { self.andA(self.e); return 4; },
            0xA4 => { self.andA(self.h); return 4; },
            0xA5 => { self.andA(self.l); return 4; },
            0xA6 => { self.andA(self.readByte(self.getHL())); return 8; },
            0xE6 => { const n = self.getImmU8(); self.andA(n); return 8; },

            // ── OR n ──
            0xB7 => { self.orA(self.a); return 4; },
            0xB0 => { self.orA(self.b); return 4; },
            0xB1 => { self.orA(self.c); return 4; },
            0xB2 => { self.orA(self.d); return 4; },
            0xB3 => { self.orA(self.e); return 4; },
            0xB4 => { self.orA(self.h); return 4; },
            0xB5 => { self.orA(self.l); return 4; },
            0xB6 => { self.orA(self.readByte(self.getHL())); return 8; },
            0xF6 => { const n = self.getImmU8(); self.orA(n); return 8; },

            // ── XOR n ──
            0xAF => { self.xorA(self.a); return 4; },
            0xA8 => { self.xorA(self.b); return 4; },
            0xA9 => { self.xorA(self.c); return 4; },
            0xAA => { self.xorA(self.d); return 4; },
            0xAB => { self.xorA(self.e); return 4; },
            0xAC => { self.xorA(self.h); return 4; },
            0xAD => { self.xorA(self.l); return 4; },
            0xAE => { self.xorA(self.readByte(self.getHL())); return 8; },
            0xEE => { const n = self.getImmU8(); self.xorA(n); return 8; },

            // ── CP n ──
            0xBF => { self.cpA(self.a); return 4; },
            0xB8 => { self.cpA(self.b); return 4; },
            0xB9 => { self.cpA(self.c); return 4; },
            0xBA => { self.cpA(self.d); return 4; },
            0xBB => { self.cpA(self.e); return 4; },
            0xBC => { self.cpA(self.h); return 4; },
            0xBD => { self.cpA(self.l); return 4; },
            0xBE => { self.cpA(self.readByte(self.getHL())); return 8; },
            0xFE => { const n = self.getImmU8(); self.cpA(n); return 8; },

            // ── INC n ──
            0x3C => { const p = self.a; self.a +%= 1; self.incFlags(p, self.a); return 4; },
            0x04 => { const p = self.b; self.b +%= 1; self.incFlags(p, self.b); return 4; },
            0x0C => { const p = self.c; self.c +%= 1; self.incFlags(p, self.c); return 4; },
            0x14 => { const p = self.d; self.d +%= 1; self.incFlags(p, self.d); return 4; },
            0x1C => { const p = self.e; self.e +%= 1; self.incFlags(p, self.e); return 4; },
            0x24 => { const p = self.h; self.h +%= 1; self.incFlags(p, self.h); return 4; },
            0x2C => { const p = self.l; self.l +%= 1; self.incFlags(p, self.l); return 4; },
            0x34 => {
                const hl = self.getHL();
                const n = self.readByte(hl);
                const nn = n +% 1;
                self.incFlags(n, nn);
                self.writeByte(hl, nn);
                return 12;
            },

            // ── DEC n ──
            0x3D => { const p = self.a; self.a -%= 1; self.decFlags(p, self.a); return 4; },
            0x05 => { const p = self.b; self.b -%= 1; self.decFlags(p, self.b); return 4; },
            0x0D => { const p = self.c; self.c -%= 1; self.decFlags(p, self.c); return 4; },
            0x15 => { const p = self.d; self.d -%= 1; self.decFlags(p, self.d); return 4; },
            0x1D => { const p = self.e; self.e -%= 1; self.decFlags(p, self.e); return 4; },
            0x25 => { const p = self.h; self.h -%= 1; self.decFlags(p, self.h); return 4; },
            0x2D => { const p = self.l; self.l -%= 1; self.decFlags(p, self.l); return 4; },
            0x35 => {
                const hl = self.getHL();
                const prev = self.readByte(hl);
                const r = prev -% 1;
                self.writeByte(hl, r);
                self.decFlags(prev, r);
                return 12;
            },

            // ── 16-bit arithmetic ──
            0x09 => { self.addHL16(self.getBC()); return 8; },
            0x19 => { self.addHL16(self.getDE()); return 8; },
            0x29 => { self.addHL16(self.getHL()); return 8; },
            0x39 => { self.addHL16(self.sp); return 8; },
            0xE8 => { self.sp = self.add16Imm(self.sp); return 16; },

            // ── INC nn ──
            0x03 => { self.setBC(self.getBC() +% 1); return 8; },
            0x13 => { self.setDE(self.getDE() +% 1); return 8; },
            0x23 => { self.setHL(self.getHL() +% 1); return 8; },
            0x33 => { self.sp +%= 1; return 8; },

            // ── DEC nn ──
            0x0B => { self.setBC(self.getBC() -% 1); return 8; },
            0x1B => { self.setDE(self.getDE() -% 1); return 8; },
            0x2B => { self.setHL(self.getHL() -% 1); return 8; },
            0x3B => { self.sp -%= 1; return 8; },

            // ── Misc ──
            0x27 => { self.daa(); return 4; },
            0x2F => { self.a = ~self.a; self.f.n = true; self.f.half = true; return 4; },
            0x3F => { self.f.n = false; self.f.half = false; self.f.carry = !self.f.carry; return 4; },
            0x37 => { self.f.n = false; self.f.half = false; self.f.carry = true; return 4; },
            0x76 => { self.halted = true; return 4; },
            0x10 => 4, // STOP
            0xF3 => { self.interrupt_master_enable = false; return 4; },
            0xFB => { self.ei_pending = true; return 4; },

            // ── Rotates (A register, zero flag cleared) ──
            0x07 => { self.a = self.rlc8(self.a); self.f.zero = false; return 4; },
            0x17 => { self.a = self.rl8(self.a); self.f.zero = false; return 4; },
            0x0F => { self.a = self.rrc8(self.a); self.f.zero = false; return 4; },
            0x1F => { self.a = self.rr8(self.a); self.f.zero = false; return 4; },

            // ── JP ──
            0xC3 => { self.pc = self.getImmU16(); return 16; },
            0xC2 => { const nn = self.getImmU16(); if (!self.f.zero) { self.pc = nn; return 16; } return 12; },
            0xCA => { const nn = self.getImmU16(); if (self.f.zero) { self.pc = nn; return 16; } return 12; },
            0xD2 => { const nn = self.getImmU16(); if (!self.f.carry) { self.pc = nn; return 16; } return 12; },
            0xDA => { const nn = self.getImmU16(); if (self.f.carry) { self.pc = nn; return 16; } return 12; },
            0xE9 => { self.pc = self.getHL(); return 4; },

            // ── JR ──
            0x18 => { const n = self.getImmI8(); self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n)); return 12; },
            0x20 => { const n = self.getImmI8(); if (!self.f.zero) { self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n)); return 12; } return 8; },
            0x28 => { const n = self.getImmI8(); if (self.f.zero) { self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n)); return 12; } return 8; },
            0x30 => { const n = self.getImmI8(); if (!self.f.carry) { self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n)); return 12; } return 8; },
            0x38 => { const n = self.getImmI8(); if (self.f.carry) { self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% @as(i16, n)); return 12; } return 8; },

            // ── CALL ──
            0xCD => { const nn = self.getImmU16(); self.call(nn); return 24; },
            0xC4 => { const nn = self.getImmU16(); if (!self.f.zero) { self.call(nn); return 24; } return 12; },
            0xCC => { const nn = self.getImmU16(); if (self.f.zero) { self.call(nn); return 24; } return 12; },
            0xD4 => { const nn = self.getImmU16(); if (!self.f.carry) { self.call(nn); return 24; } return 12; },
            0xDC => { const nn = self.getImmU16(); if (self.f.carry) { self.call(nn); return 24; } return 12; },

            // ── RST ──
            0xC7 => { self.rst(0x00); return 16; },
            0xCF => { self.rst(0x08); return 16; },
            0xD7 => { self.rst(0x10); return 16; },
            0xDF => { self.rst(0x18); return 16; },
            0xE7 => { self.rst(0x20); return 16; },
            0xEF => { self.rst(0x28); return 16; },
            0xF7 => { self.rst(0x30); return 16; },
            0xFF => { self.rst(0x38); return 16; },

            // ── RET ──
            0xC9 => { self.ret(); return 16; },
            0xC0 => { if (!self.f.zero) { self.ret(); return 20; } return 8; },
            0xC8 => { if (self.f.zero) { self.ret(); return 20; } return 8; },
            0xD0 => { if (!self.f.carry) { self.ret(); return 20; } return 8; },
            0xD8 => { if (self.f.carry) { self.ret(); return 20; } return 8; },
            0xD9 => { self.ret(); self.interrupt_master_enable = true; return 16; },

            // ── CB prefix ──
            0xCB => self.executeCB(pc),

            else => blk: {
                std.debug.print("Unimplemented opcode: 0x{X:0>2} at PC=0x{X:0>4}\n", .{ op, pc });
                break :blk 4;
            },
        };

        return cycles;
    }

    fn executeCB(self: *CPU, pc: u16) u32 {
        const cb_op = self.readByte(pc + 1);
        self.pc += 1;

        switch (cb_op) {
            // ── SWAP ──
            0x37 => { self.a = self.swap(self.a); return 8; },
            0x30 => { self.b = self.swap(self.b); return 8; },
            0x31 => { self.c = self.swap(self.c); return 8; },
            0x32 => { self.d = self.swap(self.d); return 8; },
            0x33 => { self.e = self.swap(self.e); return 8; },
            0x34 => { self.h = self.swap(self.h); return 8; },
            0x35 => { self.l = self.swap(self.l); return 8; },
            0x36 => { const hl = self.getHL(); const r = self.swap(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── RLC ──
            0x07 => { self.a = self.rlc8(self.a); return 8; },
            0x00 => { self.b = self.rlc8(self.b); return 8; },
            0x01 => { self.c = self.rlc8(self.c); return 8; },
            0x02 => { self.d = self.rlc8(self.d); return 8; },
            0x03 => { self.e = self.rlc8(self.e); return 8; },
            0x04 => { self.h = self.rlc8(self.h); return 8; },
            0x05 => { self.l = self.rlc8(self.l); return 8; },
            0x06 => { const hl = self.getHL(); const r = self.rlc8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── RL ──
            0x17 => { self.a = self.rl8(self.a); return 8; },
            0x10 => { self.b = self.rl8(self.b); return 8; },
            0x11 => { self.c = self.rl8(self.c); return 8; },
            0x12 => { self.d = self.rl8(self.d); return 8; },
            0x13 => { self.e = self.rl8(self.e); return 8; },
            0x14 => { self.h = self.rl8(self.h); return 8; },
            0x15 => { self.l = self.rl8(self.l); return 8; },
            0x16 => { const hl = self.getHL(); const r = self.rl8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── RRC ──
            0x0F => { self.a = self.rrc8(self.a); return 8; },
            0x08 => { self.b = self.rrc8(self.b); return 8; },
            0x09 => { self.c = self.rrc8(self.c); return 8; },
            0x0A => { self.d = self.rrc8(self.d); return 8; },
            0x0B => { self.e = self.rrc8(self.e); return 8; },
            0x0C => { self.h = self.rrc8(self.h); return 8; },
            0x0D => { self.l = self.rrc8(self.l); return 8; },
            0x0E => { const hl = self.getHL(); const r = self.rrc8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── RR ──
            0x1F => { self.a = self.rr8(self.a); return 8; },
            0x18 => { self.b = self.rr8(self.b); return 8; },
            0x19 => { self.c = self.rr8(self.c); return 8; },
            0x1A => { self.d = self.rr8(self.d); return 8; },
            0x1B => { self.e = self.rr8(self.e); return 8; },
            0x1C => { self.h = self.rr8(self.h); return 8; },
            0x1D => { self.l = self.rr8(self.l); return 8; },
            0x1E => { const hl = self.getHL(); const r = self.rr8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── SLA ──
            0x27 => { self.a = self.sla8(self.a); return 8; },
            0x20 => { self.b = self.sla8(self.b); return 8; },
            0x21 => { self.c = self.sla8(self.c); return 8; },
            0x22 => { self.d = self.sla8(self.d); return 8; },
            0x23 => { self.e = self.sla8(self.e); return 8; },
            0x24 => { self.h = self.sla8(self.h); return 8; },
            0x25 => { self.l = self.sla8(self.l); return 8; },
            0x26 => { const hl = self.getHL(); const r = self.sla8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── SRA ──
            0x2F => { self.a = self.sra8(self.a); return 8; },
            0x28 => { self.b = self.sra8(self.b); return 8; },
            0x29 => { self.c = self.sra8(self.c); return 8; },
            0x2A => { self.d = self.sra8(self.d); return 8; },
            0x2B => { self.e = self.sra8(self.e); return 8; },
            0x2C => { self.h = self.sra8(self.h); return 8; },
            0x2D => { self.l = self.sra8(self.l); return 8; },
            0x2E => { const hl = self.getHL(); const r = self.sra8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── SRL ──
            0x3F => { self.a = self.srl8(self.a); return 8; },
            0x38 => { self.b = self.srl8(self.b); return 8; },
            0x39 => { self.c = self.srl8(self.c); return 8; },
            0x3A => { self.d = self.srl8(self.d); return 8; },
            0x3B => { self.e = self.srl8(self.e); return 8; },
            0x3C => { self.h = self.srl8(self.h); return 8; },
            0x3D => { self.l = self.srl8(self.l); return 8; },
            0x3E => { const hl = self.getHL(); const r = self.srl8(self.readByte(hl)); self.writeByte(hl, r); return 16; },

            // ── BIT / SET / RES (0x40-0xFF) ──
            else => {
                const r: u3 = @truncate(cb_op & 0b111);
                const b: u3 = @truncate((cb_op >> 3) & 0b111);

                if (cb_op >= 0x40 and cb_op <= 0x7F) {
                    // BIT
                    const val = self.getCBReg(r);
                    self.bitTest(b, val);
                    return if (r == 6) 12 else 8;
                } else if (cb_op >= 0xC0) {
                    // SET
                    const val = setBit(b, self.getCBReg(r));
                    self.setCBReg(r, val);
                    return if (r == 6) 16 else 8;
                } else {
                    // RES (0x80-0xBF)
                    const val = resBit(b, self.getCBReg(r));
                    self.setCBReg(r, val);
                    return if (r == 6) 16 else 8;
                }
            },
        }
    }

    fn getCBReg(self: *CPU, r: u3) u8 {
        return switch (r) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => self.readByte(self.getHL()),
            7 => self.a,
        };
    }

    fn setCBReg(self: *CPU, r: u3, val: u8) void {
        switch (r) {
            0 => self.b = val,
            1 => self.c = val,
            2 => self.d = val,
            3 => self.e = val,
            4 => self.h = val,
            5 => self.l = val,
            6 => self.writeByte(self.getHL(), val),
            7 => self.a = val,
        }
    }
};
