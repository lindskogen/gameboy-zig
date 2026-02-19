const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Bus = @import("bus.zig").Bus;
const InterruptFlags = @import("ppu.zig").InterruptFlags;
const mbc = @import("mbc.zig");

fn writeU32LE(buf: []u8, val: u32) void {
    @memcpy(buf[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
}

fn readU32LE(buf: []const u8) u32 {
    return std.mem.littleToNative(u32, std.mem.bytesToValue(u32, buf[0..4]));
}

fn writeU16LE(buf: []u8, val: u16) void {
    @memcpy(buf[0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
}

fn readU16LE(buf: []const u8) u16 {
    return std.mem.littleToNative(u16, std.mem.bytesToValue(u16, buf[0..2]));
}

fn writeBlock(writer: anytype, tag: *const [4]u8, payload: []const u8) !void {
    try writer.writeAll(tag);
    var size_buf: [4]u8 = undefined;
    writeU32LE(&size_buf, @intCast(payload.len));
    try writer.writeAll(&size_buf);
    try writer.writeAll(payload);
}

pub fn write(writer: anytype, cpu: *const CPU, bus: *const Bus) !void {
    // Track file position manually for memory blob offsets
    var pos: u32 = 0;

    // 1. Write memory blobs
    const wram_offset = pos;
    const wram_size: u32 = 0x2000;
    try writer.writeAll(bus.wram[0..wram_size]);
    pos += wram_size;

    const vram_offset = pos;
    const vram_size: u32 = 0x2000;
    try writer.writeAll(bus.ppu.vram[0..vram_size]);
    pos += vram_size;

    const mbc_ram_offset = pos;
    const mbc_ram_size: u32 = @intCast(bus.cartridge.ram_len);
    if (mbc_ram_size > 0) {
        try writer.writeAll(bus.cartridge.ram[0..mbc_ram_size]);
        pos += mbc_ram_size;
    }

    const oam_offset = pos;
    const oam_size: u32 = 0xA0;
    try writer.writeAll(bus.ppu.oam[0..oam_size]);
    pos += oam_size;

    const hram_offset = pos;
    const hram_size: u32 = 0x7F;
    try writer.writeAll(bus.zram[0..hram_size]);
    pos += hram_size;

    // Record start of first block (for footer)
    const first_block_offset = pos;

    // 2. NAME block
    const name = "gameboy-zig";
    try writeBlock(writer, "NAME", name);
    pos += 8 + name.len;

    // 3. INFO block (0x12 bytes): ROM title (16 bytes) + global checksum (2 bytes)
    {
        var info_buf: [0x12]u8 = [_]u8{0} ** 0x12;
        // ROM title at 0x134-0x143 (16 bytes)
        if (bus.cartridge.rom.len > 0x143) {
            @memcpy(info_buf[0..16], bus.cartridge.rom[0x134 .. 0x134 + 16]);
        }
        // Global checksum at 0x14E-0x14F (2 bytes)
        if (bus.cartridge.rom.len > 0x14F) {
            info_buf[16] = bus.cartridge.rom[0x14E];
            info_buf[17] = bus.cartridge.rom[0x14F];
        }
        try writeBlock(writer, "INFO", &info_buf);
        pos += 8 + 0x12;
    }

    // 4. CORE block (0xD0 bytes)
    {
        var core: [0xD0]u8 = [_]u8{0} ** 0xD0;

        // Version major/minor at offset 0-1
        writeU16LE(core[0..2], 1); // major
        writeU16LE(core[2..4], 1); // minor

        // Model: "GD  " (DMG) at offset 4-7
        core[4] = 'G';
        core[5] = 'D';
        core[6] = ' ';
        core[7] = ' ';

        // CPU registers
        writeU16LE(core[8..10], cpu.pc); // PC
        const af = (@as(u16, cpu.a) << 8) | @as(u16, @as(u8, @bitCast(cpu.f)));
        writeU16LE(core[10..12], af); // AF
        writeU16LE(core[12..14], (@as(u16, cpu.b) << 8) | @as(u16, cpu.c)); // BC
        writeU16LE(core[14..16], (@as(u16, cpu.d) << 8) | @as(u16, cpu.e)); // DE
        writeU16LE(core[16..18], (@as(u16, cpu.h) << 8) | @as(u16, cpu.l)); // HL
        writeU16LE(core[18..20], cpu.sp); // SP

        // IME at offset 20
        core[20] = if (cpu.interrupt_master_enable) 1 else 0;

        // IE at offset 21
        core[21] = @bitCast(bus.interrupt_enable);

        // Execution state at offset 22: 0=running, 1=halted, 2=stopped
        core[22] = if (cpu.halted) 1 else 0;

        // Reserved byte at offset 23
        core[23] = 0;

        // IO registers (128 bytes at offset 24): FF00-FF7F
        var io: *[128]u8 = core[24..152];

        // Fill with 0xFF default for unmapped
        @memset(io, 0xFF);

        // FF00: Joypad
        io[0x00] = bus.input.readByte();

        // FF01-FF02: Serial
        io[0x01] = bus.serial.value;
        io[0x02] = 0x00;

        // FF04-FF07: Timer
        io[0x04] = @truncate(bus.ppu.internal_counter >> 8); // DIV
        io[0x05] = bus.ppu.tima_counter; // TIMA
        io[0x06] = bus.ppu.tma_modulo; // TMA
        io[0x07] = bus.ppu.tac; // TAC

        // FF0F: IF
        io[0x0F] = @as(u8, @bitCast(bus.ppu.interrupt_flag)) | 0xE0;

        // FF10-FF3F: APU registers (read via APU)
        for (0x10..0x40) |i| {
            io[i] = bus.apu.readByte(@intCast(0xFF00 + i));
        }

        // FF40-FF4B: PPU registers
        io[0x40] = @bitCast(bus.ppu.lcdc); // LCDC
        io[0x41] = bus.ppu.readVram(0xFF41); // STAT
        io[0x42] = bus.ppu.scy; // SCY
        io[0x43] = bus.ppu.scx; // SCX
        io[0x44] = bus.ppu.ly; // LY
        io[0x45] = bus.ppu.lc; // LYC
        io[0x46] = 0x00; // DMA (write-only, not meaningful in save)
        io[0x47] = bus.ppu.bgp; // BGP
        io[0x48] = bus.ppu.pal0; // OBP0
        io[0x49] = bus.ppu.pal1; // OBP1
        io[0x4A] = bus.ppu.wy; // WY
        io[0x4B] = bus.ppu.wx; // WX

        // FF4C: KEY0 — DMG mode indicator
        io[0x4C] = 0x04;

        // FF50: BANK — boot ROM disabled
        io[0x50] = 0x01;

        // Memory offsets/sizes (at offset 152)
        writeU32LE(core[152..156], wram_size);
        writeU32LE(core[156..160], wram_offset);
        writeU32LE(core[160..164], vram_size);
        writeU32LE(core[164..168], vram_offset);
        writeU32LE(core[168..172], mbc_ram_size);
        writeU32LE(core[172..176], mbc_ram_offset);
        writeU32LE(core[176..180], oam_size);
        writeU32LE(core[180..184], oam_offset);
        writeU32LE(core[184..188], hram_size);
        writeU32LE(core[188..192], hram_offset);

        try writeBlock(writer, "CORE", &core);
        pos += 8 + 0xD0;
    }

    // 5. MBC block
    switch (bus.cartridge.mbc_state) {
        .mbc1 => |s| {
            // 4 register writes × 3 bytes each = 12 bytes
            var mbc_buf: [12]u8 = undefined;
            // RAM enable
            mbc_buf[0] = 0x00;
            mbc_buf[1] = 0x00;
            mbc_buf[2] = if (bus.cartridge.ram_on) 0x0A else 0x00;
            // ROM bank low
            mbc_buf[3] = 0x00;
            mbc_buf[4] = 0x20;
            mbc_buf[5] = @truncate(bus.cartridge.rom_bank & 0x1F);
            // RAM bank / upper bits
            mbc_buf[6] = 0x00;
            mbc_buf[7] = 0x40;
            mbc_buf[8] = @truncate(bus.cartridge.ram_bank);
            // Mode
            mbc_buf[9] = 0x00;
            mbc_buf[10] = 0x60;
            mbc_buf[11] = s.mode;
            try writeBlock(writer, "MBC ", &mbc_buf);
            pos += 8 + 12;
        },
        .mbc3 => |s| {
            // 4 register writes × 3 bytes each = 12 bytes
            var mbc_buf: [12]u8 = undefined;
            // RAM enable
            mbc_buf[0] = 0x00;
            mbc_buf[1] = 0x00;
            mbc_buf[2] = if (bus.cartridge.ram_on) 0x0A else 0x00;
            // ROM bank
            mbc_buf[3] = 0x00;
            mbc_buf[4] = 0x20;
            mbc_buf[5] = @truncate(bus.cartridge.rom_bank);
            // RTC register / RAM bank
            mbc_buf[6] = 0x00;
            mbc_buf[7] = 0x40;
            mbc_buf[8] = s.rtc_register;
            // RTC latch
            mbc_buf[9] = 0x00;
            mbc_buf[10] = 0x60;
            mbc_buf[11] = s.rtc_latch;
            try writeBlock(writer, "MBC ", &mbc_buf);
            pos += 8 + 12;
        },
        .no_mbc => {},
    }

    // 6. RTC block (only for MBC3)
    switch (bus.cartridge.mbc_state) {
        .mbc3 => |s| {
            var rtc_buf: [0x30]u8 = [_]u8{0} ** 0x30;
            // Current RTC values (offsets 0-4)
            rtc_buf[0] = s.rtc_s;
            rtc_buf[4] = s.rtc_m;
            rtc_buf[8] = s.rtc_h;
            rtc_buf[12] = s.rtc_dl;
            rtc_buf[16] = s.rtc_dh;
            // Latched RTC values (offsets 20-24) — same as current
            rtc_buf[20] = s.rtc_s;
            rtc_buf[24] = s.rtc_m;
            rtc_buf[28] = s.rtc_h;
            rtc_buf[32] = s.rtc_dl;
            rtc_buf[36] = s.rtc_dh;
            // UNIX timestamp at offset 40 (8 bytes) — 0
            try writeBlock(writer, "RTC ", &rtc_buf);
            pos += 8 + 0x30;
        },
        else => {},
    }

    // 7. END block
    try writeBlock(writer, "END ", &[_]u8{});
    pos += 8;

    // 8. Footer: offset to first block (u32 LE) + "BESS"
    var footer: [8]u8 = undefined;
    writeU32LE(footer[0..4], first_block_offset);
    footer[4] = 'B';
    footer[5] = 'E';
    footer[6] = 'S';
    footer[7] = 'S';
    try writer.writeAll(&footer);
}

const BlockIterator = struct {
    file_data: []const u8,
    offset: usize,
    data_end: usize, // file_data.len - 8 (before footer)

    fn next(self: *BlockIterator) ?struct { tag: []const u8, payload: []const u8 } {
        if (self.offset + 8 > self.data_end) return null;
        const tag = self.file_data[self.offset .. self.offset + 4];
        const block_size = readU32LE(self.file_data[self.offset + 4 .. self.offset + 8]);
        const block_end = self.offset + 8 + block_size;
        if (block_end > self.data_end) return null;
        const payload = self.file_data[self.offset + 8 .. block_end];
        self.offset = block_end;
        return .{ .tag = tag, .payload = payload };
    }
};

pub fn read(file_data: []const u8, cpu: *CPU, bus: *Bus) !void {
    if (file_data.len < 8) return error.InvalidFormat;

    // Check for BESS footer
    const footer = file_data[file_data.len - 8 ..];
    if (!std.mem.eql(u8, footer[4..8], "BESS")) {
        if (file_data.len >= 4 and std.mem.eql(u8, file_data[0..4], "GBZS")) {
            return error.LegacyFormat;
        }
        return error.InvalidFormat;
    }

    const first_block_offset = readU32LE(footer[0..4]);
    if (first_block_offset >= file_data.len - 8) return error.InvalidFormat;
    const data_end = file_data.len - 8;

    // Validation pass: check ROM checksum and verify memory blob bounds
    {
        var iter = BlockIterator{ .file_data = file_data, .offset = first_block_offset, .data_end = data_end };
        while (iter.next()) |block| {
            if (std.mem.eql(u8, block.tag, "INFO")) {
                try validateInfo(block.payload, bus);
            } else if (std.mem.eql(u8, block.tag, "CORE")) {
                try validateCore(block.payload, file_data);
            } else if (std.mem.eql(u8, block.tag, "END ")) {
                break;
            }
        }
    }

    // Apply pass: actually restore state
    var iter = BlockIterator{ .file_data = file_data, .offset = first_block_offset, .data_end = data_end };
    while (iter.next()) |block| {
        if (std.mem.eql(u8, block.tag, "CORE")) {
            applyCore(block.payload, file_data, cpu, bus);
        } else if (std.mem.eql(u8, block.tag, "MBC ")) {
            readMBC(block.payload, &bus.cartridge);
        } else if (std.mem.eql(u8, block.tag, "RTC ")) {
            readRTC(block.payload, &bus.cartridge);
        } else if (std.mem.eql(u8, block.tag, "END ")) {
            break;
        }
    }
}

fn validateInfo(payload: []const u8, bus: *const Bus) !void {
    if (payload.len < 0x12) return error.InvalidFormat;
    // Check global checksum (bytes 16-17 of INFO = ROM bytes 0x14E-0x14F)
    if (bus.cartridge.rom.len > 0x14F) {
        if (payload[16] != bus.cartridge.rom[0x14E] or payload[17] != bus.cartridge.rom[0x14F]) {
            return error.RomMismatch;
        }
    }
}

fn validateCore(payload: []const u8, file_data: []const u8) !void {
    if (payload.len < 0xD0) return error.InvalidFormat;

    // Validate all memory blob offsets are in bounds
    const checks = [_]struct { size_off: usize, off_off: usize }{
        .{ .size_off = 152, .off_off = 156 }, // WRAM
        .{ .size_off = 160, .off_off = 164 }, // VRAM
        .{ .size_off = 168, .off_off = 172 }, // MBC RAM
        .{ .size_off = 176, .off_off = 180 }, // OAM
        .{ .size_off = 184, .off_off = 188 }, // HRAM
    };
    for (checks) |c| {
        const size = readU32LE(payload[c.size_off..][0..4]);
        const off = readU32LE(payload[c.off_off..][0..4]);
        if (size > 0 and off + size > file_data.len) return error.InvalidFormat;
    }
}

fn applyCore(payload: []const u8, file_data: []const u8, cpu: *CPU, bus: *Bus) void {
    // CPU registers
    cpu.pc = readU16LE(payload[8..10]);
    const af = readU16LE(payload[10..12]);
    cpu.a = @truncate(af >> 8);
    cpu.f = @bitCast(@as(u8, @truncate(af)) & 0xF0);
    const bc = readU16LE(payload[12..14]);
    cpu.b = @truncate(bc >> 8);
    cpu.c = @truncate(bc);
    const de = readU16LE(payload[14..16]);
    cpu.d = @truncate(de >> 8);
    cpu.e = @truncate(de);
    const hl = readU16LE(payload[16..18]);
    cpu.h = @truncate(hl >> 8);
    cpu.l = @truncate(hl);
    cpu.sp = readU16LE(payload[18..20]);

    cpu.interrupt_master_enable = payload[20] != 0;
    bus.interrupt_enable = @bitCast(payload[21]);
    cpu.halted = payload[22] != 0;
    cpu.ei_pending = false;

    // IO registers (128 bytes at offset 24)
    restoreRegisters(payload[24..152], bus);

    // Memory blobs (bounds already validated)
    const wram_size = readU32LE(payload[152..156]);
    const wram_off = readU32LE(payload[156..160]);
    if (wram_size > 0) {
        const n = @min(wram_size, 0x2000);
        @memcpy(bus.wram[0..n], file_data[wram_off..][0..n]);
    }

    const vram_size = readU32LE(payload[160..164]);
    const vram_off = readU32LE(payload[164..168]);
    if (vram_size > 0) {
        const n = @min(vram_size, 0x2000);
        @memcpy(bus.ppu.vram[0..n], file_data[vram_off..][0..n]);
    }

    const mbc_ram_size = readU32LE(payload[168..172]);
    const mbc_ram_off = readU32LE(payload[172..176]);
    if (mbc_ram_size > 0) {
        const n: usize = @min(mbc_ram_size, bus.cartridge.ram_len);
        if (n > 0) @memcpy(bus.cartridge.ram[0..n], file_data[mbc_ram_off..][0..n]);
    }

    const oam_size = readU32LE(payload[176..180]);
    const oam_off = readU32LE(payload[180..184]);
    if (oam_size > 0) {
        const n = @min(oam_size, 0xA0);
        @memcpy(bus.ppu.oam[0..n], file_data[oam_off..][0..n]);
    }

    const hram_size = readU32LE(payload[184..188]);
    const hram_off = readU32LE(payload[188..192]);
    if (hram_size > 0) {
        const n = @min(hram_size, 0x7F);
        @memcpy(bus.zram[0..n], file_data[hram_off..][0..n]);
    }
}

fn restoreRegisters(io: []const u8, bus: *Bus) void {
    // Joypad (FF00) — bits 4-5 select mode
    if ((io[0x00] & 0x10) == 0) {
        bus.input.mode = .direction;
    } else {
        bus.input.mode = .action;
    }

    // Serial (FF01)
    bus.serial.value = io[0x01];

    // Timer (FF04-FF07) — restore directly without side effects
    bus.ppu.internal_counter = @as(u16, io[0x04]) << 8;
    bus.ppu.tima_counter = io[0x05];
    bus.ppu.tma_modulo = io[0x06];
    bus.ppu.tac = io[0x07];
    bus.ppu.prev_timer_bit = bus.ppu.timerBit();

    // IF (FF0F) — restore directly
    bus.ppu.interrupt_flag = @bitCast(io[0x0F] & 0x1F);

    // APU (FF10-FF3F) — use writeByte, side effects are acceptable
    for (0x10..0x40) |i| {
        bus.apu.writeByte(@intCast(0xFF00 + i), io[i]);
    }

    // PPU registers — write directly to avoid LCD toggle/STAT side effects
    bus.ppu.lcdc = @bitCast(io[0x40]);
    // Decode STAT byte
    bus.ppu.stat.enable_ly_interrupt = (io[0x41] & 0x40) != 0;
    bus.ppu.stat.enable_m2_interrupt = (io[0x41] & 0x20) != 0;
    bus.ppu.stat.enable_m1_interrupt = (io[0x41] & 0x10) != 0;
    bus.ppu.stat.enable_m0_interrupt = (io[0x41] & 0x08) != 0;
    bus.ppu.stat.mode = @enumFromInt(@as(u2, @truncate(io[0x41])));
    bus.ppu.scy = io[0x42];
    bus.ppu.scx = io[0x43];
    bus.ppu.ly = io[0x44];
    bus.ppu.lc = io[0x45];
    bus.ppu.bgp = io[0x47];
    bus.ppu.pal0 = io[0x48];
    bus.ppu.pal1 = io[0x49];
    bus.ppu.wy = io[0x4A];
    bus.ppu.wx = io[0x4B];

    // Recompute stat_line from restored state
    bus.ppu.stat_line = bus.ppu.computeStatLine();
}

fn readMBC(payload: []const u8, cartridge: *@import("cartridge.zig").Cartridge) void {
    // Each entry is 3 bytes: addr_lo, addr_hi, value
    var i: usize = 0;
    while (i + 2 < payload.len) {
        const addr = @as(u16, payload[i]) | (@as(u16, payload[i + 1]) << 8);
        const value = payload[i + 2];
        cartridge.writeRom(addr, value);
        i += 3;
    }
}

fn readRTC(payload: []const u8, cartridge: *@import("cartridge.zig").Cartridge) void {
    if (payload.len < 0x30) return;
    switch (cartridge.mbc_state) {
        .mbc3 => |*s| {
            // Current RTC values (each at 4-byte intervals as u32 LE, we take low byte)
            s.rtc_s = payload[0];
            s.rtc_m = payload[4];
            s.rtc_h = payload[8];
            s.rtc_dl = payload[12];
            s.rtc_dh = payload[16];
        },
        else => {},
    }
}
