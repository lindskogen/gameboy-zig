const std = @import("std");

const MBCType = enum {
    no_mbc,
    mbc1,
};

fn romBanks(v: u8) usize {
    if (v <= 8) {
        return @as(usize, 2) << @intCast(v);
    }
    return 0;
}

fn ramBanks(v: u8) usize {
    return switch (v) {
        1, 2 => 1,
        3 => 4,
        4 => 16,
        5 => 8,
        else => 0,
    };
}

pub const Cartridge = struct {
    rom: []const u8,
    ram: [0x20000]u8 = [_]u8{0} ** 0x20000, // max 128KB RAM (16 banks * 8KB)
    ram_len: usize = 0,

    mbc_type: MBCType = .no_mbc,
    rom_bank: usize = 1,
    ram_bank: usize = 0,
    ram_on: bool = false,
    num_rom_banks: usize = 2,
    num_ram_banks: usize = 0,
    mode: u1 = 0, // 0 = ROM mode, 1 = RAM mode
    has_battery: bool = false,
    ram_dirty: bool = false,

    pub fn init(rom: []const u8) Cartridge {
        const cart_type = if (rom.len > 0x147) rom[0x147] else 0;
        const rom_bank_code = if (rom.len > 0x148) rom[0x148] else 0;
        const ram_bank_code = if (rom.len > 0x149) rom[0x149] else 0;

        const num_rom = romBanks(rom_bank_code);
        const num_ram = ramBanks(ram_bank_code);

        const mbc: MBCType = switch (cart_type) {
            0x00, 0x08, 0x09 => .no_mbc,
            0x01, 0x02, 0x03 => .mbc1,
            else => .no_mbc,
        };

        const battery = switch (cart_type) {
            0x03, 0x06, 0x09, 0x0D, 0x0F, 0x10, 0x13, 0x1B, 0x1E, 0xFF => true,
            else => false,
        };

        return .{
            .rom = rom,
            .mbc_type = mbc,
            .num_rom_banks = num_rom,
            .num_ram_banks = num_ram,
            .ram_len = num_ram * 0x2000,
            .rom_bank = 1,
            .has_battery = battery,
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

    pub fn readRom(self: *const Cartridge, addr: u16) u8 {
        const address = @as(usize, addr);
        return switch (self.mbc_type) {
            .no_mbc => if (address < self.rom.len) self.rom[address] else 0xff,
            .mbc1 => self.mbc1ReadRom(address),
        };
    }

    pub fn readRam(self: *const Cartridge, addr: u16) u8 {
        return switch (self.mbc_type) {
            .no_mbc => 0x00,
            .mbc1 => self.mbc1ReadRam(@as(usize, addr)),
        };
    }

    pub fn writeRom(self: *Cartridge, addr: u16, value: u8) void {
        switch (self.mbc_type) {
            .no_mbc => {},
            .mbc1 => self.mbc1WriteRom(@as(usize, addr), value),
        }
    }

    pub fn writeRam(self: *Cartridge, addr: u16, value: u8) void {
        switch (self.mbc_type) {
            .no_mbc => {},
            .mbc1 => self.mbc1WriteRam(@as(usize, addr), value),
        }
    }

    // MBC1 implementation

    fn mbc1ReadRom(self: *const Cartridge, addr: usize) u8 {
        const bank = if (addr < 0x4000)
            (if (self.mode == 0) self.rom_bank & 0xe0 else 0)
        else
            self.rom_bank;

        const idx = bank * 0x4000 | (addr & 0x3fff);
        return if (idx < self.rom.len) self.rom[idx] else 0xff;
    }

    fn mbc1ReadRam(self: *const Cartridge, addr: usize) u8 {
        if (!self.ram_on) return 0xff;
        const bank = if (self.mode == 1) self.ram_bank else 0;
        const idx = (bank * 0x2000) | (addr & 0x1fff);
        return if (idx < self.ram_len) self.ram[idx] else 0xff;
    }

    fn mbc1WriteRam(self: *Cartridge, addr: usize, value: u8) void {
        if (!self.ram_on) return;
        const bank = if (self.mode == 1) self.ram_bank else 0;
        const idx = (bank * 0x2000) | (addr & 0x1fff);
        if (idx < self.ram_len) {
            self.ram[idx] = value;
            self.ram_dirty = true;
        }
    }

    fn mbc1WriteRom(self: *Cartridge, addr: usize, value: u8) void {
        switch (addr) {
            0x0000...0x1fff => {
                self.ram_on = (value & 0xf) == 0xa;
            },
            0x2000...0x3fff => {
                const lower_bits = blk: {
                    const masked = @as(usize, value) & 0x1f;
                    break :blk if (masked == 0) 1 else masked;
                };
                self.rom_bank = ((self.rom_bank & 0x60) | lower_bits) % self.num_rom_banks;
            },
            0x4000...0x5fff => {
                if (self.num_rom_banks > 0x20) {
                    const upper_bits = (@as(usize, value) & 0x03) % (self.num_rom_banks >> 5);
                    self.rom_bank = (self.rom_bank & 0x1f) | (upper_bits << 5);
                }
                if (self.num_ram_banks > 1) {
                    self.ram_bank = @as(usize, value) & 0x03;
                }
            },
            0x6000...0x7fff => {
                self.mode = @intCast(value & 0x01);
            },
            else => {},
        }
    }

    pub fn serialize(self: *const Cartridge, writer: anytype) !void {
        // Write MBC state
        try writer.writeInt(u64, @intCast(self.rom_bank), .little);
        try writer.writeInt(u64, @intCast(self.ram_bank), .little);
        try writer.writeByte(if (self.ram_on) 1 else 0);
        try writer.writeInt(u8, self.mode, .little);

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
        self.mode = @truncate(mode_bytes[0]);

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
