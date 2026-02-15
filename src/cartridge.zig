const std = @import("std");
const mbc = @import("mbc.zig");

pub const Cartridge = struct {
    rom: []const u8,
    ram: [0x20000]u8 = [_]u8{0} ** 0x20000, // max 128KB RAM (16 banks * 8KB)
    ram_len: usize = 0,

    mbc_state: mbc.Type = .no_mbc,
    rom_bank: usize = 1,
    ram_bank: usize = 0,
    ram_on: bool = false,
    num_rom_banks: usize = 2,
    num_ram_banks: usize = 0,
    has_battery: bool = false,
    ram_dirty: bool = false,

    pub fn init(rom: []const u8) Cartridge {
        const cart_type = if (rom.len > 0x147) rom[0x147] else 0;
        const rom_bank_code = if (rom.len > 0x148) rom[0x148] else 0;
        const ram_bank_code = if (rom.len > 0x149) rom[0x149] else 0;

        const num_rom = mbc.romBanks(rom_bank_code);
        const num_ram = mbc.ramBanks(ram_bank_code);

        return .{
            .rom = rom,
            .mbc_state = mbc.fromCartType(cart_type),
            .num_rom_banks = num_rom,
            .num_ram_banks = num_ram,
            .ram_len = num_ram * 0x2000,
            .rom_bank = 1,
            .has_battery = mbc.hasBattery(cart_type),
        };
    }

    pub fn loadSav(self: *Cartridge, rom_path: []const u8) void {
        if (!self.has_battery or self.ram_len == 0) return;

        var sav_path_buf: [256]u8 = undefined;
        const sav_path = savPath(&sav_path_buf, rom_path) orelse return;

        const file = std.fs.cwd().openFile(sav_path, .{}) catch return;
        defer file.close();

        _ = file.readAll(self.ram[0..self.ram_len]) catch return;

        std.debug.print("Loaded save data from {s}\n", .{sav_path});
    }

    pub fn saveSav(self: *const Cartridge, rom_path: []const u8) void {
        if (!self.has_battery or self.ram_len == 0) return;

        var sav_path_buf: [256]u8 = undefined;
        const sav_path = savPath(&sav_path_buf, rom_path) orelse return;

        const file = std.fs.cwd().createFile(sav_path, .{}) catch return;
        defer file.close();

        file.writeAll(self.ram[0..self.ram_len]) catch return;

        std.debug.print("Saved data to {s}\n", .{sav_path});
    }

    fn savPath(buf: *[256]u8, rom_path: []const u8) ?[]const u8 {
        const dir = std.fs.path.dirname(rom_path);
        const stem = std.fs.path.stem(rom_path);
        if (dir) |d| {
            if (d.len + 1 + stem.len + 4 > buf.len) return null;
            @memcpy(buf[0..d.len], d);
            buf[d.len] = std.fs.path.sep;
            @memcpy(buf[d.len + 1 ..][0..stem.len], stem);
            @memcpy(buf[d.len + 1 + stem.len ..][0..4], ".sav");
            return buf[0 .. d.len + 1 + stem.len + 4];
        } else {
            if (stem.len + 4 > buf.len) return null;
            @memcpy(buf[0..stem.len], stem);
            @memcpy(buf[stem.len..][0..4], ".sav");
            return buf[0 .. stem.len + 4];
        }
    }

    // Shared banked memory helpers

    fn romRead(self: *const Cartridge, bank: usize, addr: usize) u8 {
        const idx = bank * 0x4000 | (addr & 0x3fff);
        return if (idx < self.rom.len) self.rom[idx] else 0xff;
    }

    fn ramRead(self: *const Cartridge, bank: usize, addr: usize) u8 {
        const idx = bank * 0x2000 | (addr & 0x1fff);
        return if (idx < self.ram_len) self.ram[idx] else 0xff;
    }

    fn ramWrite(self: *Cartridge, bank: usize, addr: usize, value: u8) void {
        const idx = bank * 0x2000 | (addr & 0x1fff);
        if (idx < self.ram_len) {
            self.ram[idx] = value;
            self.ram_dirty = true;
        }
    }

    // Public bus interface

    pub fn readRom(self: *const Cartridge, addr: u16) u8 {
        const a = @as(usize, addr);
        return switch (self.mbc_state) {
            .no_mbc => if (a < self.rom.len) self.rom[a] else 0xff,
            .mbc1 => |s| self.romRead(
                if (a < 0x4000) (if (s.mode == 0) self.rom_bank & 0xe0 else 0) else self.rom_bank,
                a,
            ),
            .mbc3 => self.romRead(if (a < 0x4000) 0 else self.rom_bank, a),
        };
    }

    pub fn readRam(self: *const Cartridge, addr: u16) u8 {
        const a = @as(usize, addr);
        return switch (self.mbc_state) {
            .no_mbc => 0x00,
            .mbc1 => |s| if (self.ram_on) self.ramRead(if (s.mode == 1) self.ram_bank else 0, a) else 0xff,
            .mbc3 => |s| blk: {
                if (!self.ram_on) break :blk 0xff;
                break :blk if (s.rtc_register <= 3) self.ramRead(s.rtc_register, a) else s.rtcRead();
            },
        };
    }

    pub fn writeRom(self: *Cartridge, addr: u16, value: u8) void {
        const a = @as(usize, addr);
        switch (self.mbc_state) {
            .no_mbc => {},
            .mbc1 => |*s| switch (a) {
                0x0000...0x1fff => self.ram_on = (value & 0xf) == 0xa,
                0x2000...0x3fff => {
                    const lower = @max(@as(usize, value) & 0x1f, 1);
                    self.rom_bank = ((self.rom_bank & 0x60) | lower) % self.num_rom_banks;
                },
                0x4000...0x5fff => {
                    if (self.num_rom_banks > 0x20) {
                        const upper = (@as(usize, value) & 0x03) % (self.num_rom_banks >> 5);
                        self.rom_bank = (self.rom_bank & 0x1f) | (upper << 5);
                    }
                    if (self.num_ram_banks > 1) {
                        self.ram_bank = @as(usize, value) & 0x03;
                    }
                },
                0x6000...0x7fff => s.mode = @intCast(value & 0x01),
                else => {},
            },
            .mbc3 => |*s| switch (a) {
                0x0000...0x1fff => self.ram_on = (value & 0xf) == 0xa,
                0x2000...0x3fff => self.rom_bank = @max(@as(usize, value) & 0x7f, 1) % self.num_rom_banks,
                0x4000...0x5fff => {
                    s.rtc_register = value;
                    if (value <= 3) self.ram_bank = @as(usize, value);
                },
                0x6000...0x7fff => {
                    defer s.rtc_latch = value;
                    if (s.rtc_latch == 0 and value == 1) {
                        // Latch RTC (no-op since we don't advance RTC)
                    }
                },
                else => {},
            },
        }
    }

    pub fn writeRam(self: *Cartridge, addr: u16, value: u8) void {
        if (!self.ram_on) return;
        const a = @as(usize, addr);
        switch (self.mbc_state) {
            .no_mbc => {},
            .mbc1 => |s| self.ramWrite(if (s.mode == 1) self.ram_bank else 0, a, value),
            .mbc3 => |*s| {
                if (s.rtc_register <= 3) self.ramWrite(s.rtc_register, a, value) else s.rtcWrite(value);
            },
        }
    }

    pub fn serialize(self: *const Cartridge, writer: anytype) !void {
        // Write MBC state
        try writer.writeInt(u64, @intCast(self.rom_bank), .little);
        try writer.writeInt(u64, @intCast(self.ram_bank), .little);
        try writer.writeByte(if (self.ram_on) 1 else 0);
        const mode: u8 = switch (self.mbc_state) {
            .mbc1 => |s| s.mode,
            else => 0,
        };
        try writer.writeInt(u8, mode, .little);

        // Write RAM length
        try writer.writeInt(u64, @intCast(self.ram_len), .little);

        // Write RAM contents
        if (self.ram_len > 0) {
            try writer.writeAll(self.ram[0..self.ram_len]);
        }
    }

    pub fn deserialize(self: *Cartridge, reader: anytype) !void {
        // Read MBC state
        var rom_bank_bytes: [8]u8 = undefined;
        try reader.readNoEof(&rom_bank_bytes);
        self.rom_bank = @intCast(std.mem.littleToNative(u64, std.mem.bytesToValue(u64, &rom_bank_bytes)));

        var ram_bank_bytes: [8]u8 = undefined;
        try reader.readNoEof(&ram_bank_bytes);
        self.ram_bank = @intCast(std.mem.littleToNative(u64, std.mem.bytesToValue(u64, &ram_bank_bytes)));

        self.ram_on = (try reader.readByte()) != 0;

        var mode_bytes: [1]u8 = undefined;
        try reader.readNoEof(&mode_bytes);
        switch (self.mbc_state) {
            .mbc1 => |*s| s.mode = @truncate(mode_bytes[0]),
            else => {},
        }

        // Read RAM length
        var ram_len_bytes: [8]u8 = undefined;
        try reader.readNoEof(&ram_len_bytes);
        const ram_len: usize = @intCast(std.mem.littleToNative(u64, std.mem.bytesToValue(u64, &ram_len_bytes)));

        // Read RAM contents
        if (ram_len > 0 and ram_len == self.ram_len) {
            try reader.readNoEof(self.ram[0..ram_len]);
        }
    }
};
