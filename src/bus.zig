const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const PPU = @import("ppu.zig").PPU;
const InterruptFlags = @import("ppu.zig").InterruptFlags;
const APU = @import("apu.zig").APU;

const WRAM_SIZE: usize = 0x8000;
const ZRAM_SIZE: usize = 0x7F;

// ── Joypad ──────────────────────────────────────────────────────────────────

pub const JoypadInput = packed struct(u8) {
    down: bool = false,
    left: bool = false,
    up: bool = false,
    right: bool = false,
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
};

const JoypadMode = enum { action, direction };

const Joypad = struct {
    mode: JoypadMode = .action,
    input: JoypadInput = .{},

    pub fn update(self: *Joypad, input: JoypadInput) void {
        self.input = input;
    }

    fn readByte(self: *const Joypad) u8 {
        var output: u8 = 0x0f; // all buttons released (active low)
        if (self.mode == .action) {
            if (self.input.start) output &= ~@as(u8, 0x08);
            if (self.input.select) output &= ~@as(u8, 0x04);
            if (self.input.a) output &= ~@as(u8, 0x01);
            if (self.input.b) output &= ~@as(u8, 0x02);
        } else {
            if (self.input.down) output &= ~@as(u8, 0x08);
            if (self.input.up) output &= ~@as(u8, 0x04);
            if (self.input.right) output &= ~@as(u8, 0x01);
            if (self.input.left) output &= ~@as(u8, 0x02);
        }
        return output;
    }

    fn writeByte(self: *Joypad, value: u8) void {
        if ((value & 0x10) == 0) {
            self.mode = .direction;
        } else if ((value & 0x20) == 0) {
            self.mode = .action;
        }
    }
};

// ── Serial (stub) ───────────────────────────────────────────────────────────

const Serial = struct {
    value: u8 = 0,

    fn readByte(self: *const Serial, addr: u16) u8 {
        _ = self;
        return switch (addr) {
            0xff01, 0xff02 => 0x00,
            else => 0xff,
        };
    }

    fn writeByte(self: *Serial, addr: u16, v: u8) void {
        switch (addr) {
            0xff01 => self.value = v,
            0xff02 => {
                if ((v & 0x80) != 0) {
                    // Transfer requested — print for debug
                    std.debug.print("{c}", .{self.value});
                }
            },
            else => {},
        }
    }
};

// ── Memory Bus ──────────────────────────────────────────────────────────────

pub const Bus = struct {
    wram: [WRAM_SIZE]u8 = [_]u8{0} ** WRAM_SIZE,
    zram: [ZRAM_SIZE]u8 = [_]u8{0} ** ZRAM_SIZE,
    boot_rom: [256]u8 = [_]u8{0} ** 256,
    boot_rom_disabled: bool = false,
    wram_bank: usize = 1,

    cartridge: Cartridge = undefined,
    serial: Serial = .{},
    input: Joypad = .{},
    ppu: PPU = .{},
    apu: APU = .{},
    interrupt_enable: InterruptFlags = .{},

    has_cartridge: bool = false,

    pub fn initWithRom(rom: []const u8, boot_rom: ?[]const u8) Bus {
        var bus = Bus{};
        bus.cartridge = Cartridge.init(rom);
        bus.has_cartridge = true;

        if (boot_rom) |br| {
            const len = @min(br.len, 256);
            @memcpy(bus.boot_rom[0..len], br[0..len]);
        } else {
            bus.boot_rom_disabled = true;
            // Initialize PPU registers when skipping boot ROM
            bus.ppu.writeVram(0xff40, 0x91); // LCDC
            bus.ppu.writeVram(0xff47, 0xFC); // BGP (standard DMG palette)
        }

        return bus;
    }

    pub fn checkInterrupt(self: *const Bus) bool {
        const ie: u8 = @bitCast(self.interrupt_enable);
        const iflag: u8 = @bitCast(self.ppu.interrupt_flag);
        return (ie & iflag) != 0;
    }

    fn dmaTransfer(self: *Bus, addr_byte: u8) void {
        const base: u16 = @as(u16, addr_byte) << 8;
        for (0..0xA0) |i| {
            const offset: u16 = @intCast(i);
            const v = self.readByte(base + offset);
            self.writeByte(0xfe00 + offset, v);
        }
    }

    pub fn readByte(self: *Bus, addr: u16) u8 {
        const address = @as(usize, addr);

        if (address < 0x100 and !self.boot_rom_disabled) {
            return self.boot_rom[address];
        }

        return switch (address) {
            0x0000...0x7fff => if (self.has_cartridge) self.cartridge.readRom(addr) else 0xff,
            0xa000...0xbfff => if (self.has_cartridge) self.cartridge.readRam(addr) else 0xff,
            0xc000...0xcfff, 0xe000...0xefff => self.wram[address & 0x0fff],
            0xd000...0xdfff, 0xf000...0xfdff => self.wram[(self.wram_bank * 0x1000) | (address & 0x0fff)],
            0xff51...0xff55, 0xff6c, 0xff70, 0xff7f => 0xff,
            0xff00 => self.input.readByte(),
            0xff01...0xff02 => self.serial.readByte(addr),
            0x8000...0x9fff => self.ppu.readVram(addr),
            0xfe00...0xfe9f => self.ppu.readVram(addr),
            0xff40...0xff4f => self.ppu.readVram(addr),
            0xff68...0xff6b => self.ppu.readVram(addr),
            0xff04...0xff07 => self.ppu.readVram(addr),
            0xff10...0xff3f => self.apu.readByte(addr),
            0xfea0...0xfeff => 0xff,
            0xff80...0xfffe => self.zram[address & 0x007f],
            0xff0f => self.ppu.readVram(addr),
            0xffff => @bitCast(self.interrupt_enable),
            else => 0xff,
        };
    }

    pub fn writeByte(self: *Bus, addr: u16, value: u8) void {
        const address = @as(usize, addr);

        switch (address) {
            0x0000...0x7fff => if (self.has_cartridge) self.cartridge.writeRom(addr, value),
            0xc000...0xcfff, 0xe000...0xefff => self.wram[address & 0x0fff] = value,
            0xd000...0xdfff, 0xf000...0xfdff => self.wram[(self.wram_bank * 0x1000) | (address & 0x0fff)] = value,
            0xff7f => {},
            0xff00 => self.input.writeByte(value),
            0xff01...0xff02 => self.serial.writeByte(addr, value),
            0xa000...0xbfff => if (self.has_cartridge) self.cartridge.writeRam(addr, value),
            0x8000...0x9fff => self.ppu.writeVram(addr, value),
            0xfe00...0xfe9f => self.ppu.writeVram(addr, value),
            0xff46 => self.dmaTransfer(value),
            0xff40...0xff45, 0xff47...0xff4f => self.ppu.writeVram(addr, value),
            0xff68...0xff6b => self.ppu.writeVram(addr, value),
            0xff04...0xff07 => self.ppu.writeVram(addr, value),
            0xff10...0xff3f => self.apu.writeByte(addr, value),
            0xff0f => self.ppu.writeVram(addr, value),
            0xff50 => self.boot_rom_disabled = (value == 1),
            0xfea0...0xfeff => {},
            0xff80...0xfffe => self.zram[address & 0x007f] = value,
            0xffff => self.interrupt_enable = @bitCast(value),
            else => {},
        }
    }
};
