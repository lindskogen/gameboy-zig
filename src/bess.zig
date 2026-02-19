const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Bus = @import("bus.zig").Bus;
const Cartridge = @import("cartridge.zig").Cartridge;

const le = std.mem.littleToNative;
const native = std.mem.nativeToLittle;

// ── Block-level helpers ─────────────────────────────────────────────

fn writeBlock(writer: anytype, tag: *const [4]u8, payload: []const u8) !void {
    try writer.writeAll(tag);
    try writer.writeAll(&std.mem.toBytes(native(u32, @intCast(payload.len))));
    try writer.writeAll(payload);
}

const Block = struct { tag: *const [4]u8, payload: []const u8 };

const BlockIterator = struct {
    data: []const u8,
    pos: usize,
    end: usize,

    fn next(self: *BlockIterator) ?Block {
        if (self.pos + 8 > self.end) return null;
        const tag: *const [4]u8 = self.data[self.pos..][0..4];
        const size = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..4], .little);
        const block_end = self.pos + 8 + size;
        if (block_end > self.end) return null;
        const payload = self.data[self.pos + 8 .. block_end];
        self.pos = block_end;
        return .{ .tag = tag, .payload = payload };
    }
};

// ── Packed structs for BESS binary layout ───────────────────────────

const MemoryRegion = extern struct {
    size: u32,
    offset: u32,
};

const CoreHeader = extern struct {
    major: u16 align(1),
    minor: u16 align(1),
    model: [4]u8,
    pc: u16 align(1),
    af: u16 align(1),
    bc: u16 align(1),
    de: u16 align(1),
    hl: u16 align(1),
    sp: u16 align(1),
    ime: u8,
    ie: u8,
    execution_state: u8,
    _reserved: u8,
    io: [128]u8,
    wram: MemoryRegion,
    vram: MemoryRegion,
    mbc_ram: MemoryRegion,
    oam: MemoryRegion,
    hram: MemoryRegion,
    bg_palettes: MemoryRegion, // CGB only, 0 for DMG
    obj_palettes: MemoryRegion, // CGB only, 0 for DMG

    comptime {
        if (@sizeOf(CoreHeader) != 0xD0) @compileError("CoreHeader must be 0xD0 bytes");
    }
};


const InfoBlock = extern struct {
    title: [16]u8,
    checksum: [2]u8,

    comptime {
        if (@sizeOf(InfoBlock) != 0x12) @compileError("InfoBlock must be 0x12 bytes");
    }
};

// ── Write ───────────────────────────────────────────────────────────

pub fn write(writer: anytype, cpu: *const CPU, bus: *const Bus) !void {
    var pos: u32 = 0;

    // Memory blobs
    const wram_region = MemoryRegion{ .size = 0x2000, .offset = pos };
    try writer.writeAll(bus.wram[0..0x2000]);
    pos += 0x2000;

    const vram_region = MemoryRegion{ .size = 0x2000, .offset = pos };
    try writer.writeAll(bus.ppu.vram[0..0x2000]);
    pos += 0x2000;

    const ram_len: u32 = @intCast(bus.cartridge.ram_len);
    const mbc_ram_region = MemoryRegion{ .size = ram_len, .offset = pos };
    if (ram_len > 0) {
        try writer.writeAll(bus.cartridge.ram[0..ram_len]);
        pos += ram_len;
    }

    const oam_region = MemoryRegion{ .size = 0xA0, .offset = pos };
    try writer.writeAll(bus.ppu.oam[0..0xA0]);
    pos += 0xA0;

    const hram_region = MemoryRegion{ .size = 0x7F, .offset = pos };
    try writer.writeAll(bus.zram[0..0x7F]);
    pos += 0x7F;

    const first_block_offset = pos;

    // NAME
    try writeBlock(writer, "NAME", "gameboy-zig");

    // INFO
    var info = InfoBlock{ .title = [_]u8{0} ** 16, .checksum = .{ 0, 0 } };
    if (bus.cartridge.rom.len > 0x143) {
        @memcpy(&info.title, bus.cartridge.rom[0x134..0x144]);
    }
    if (bus.cartridge.rom.len > 0x14F) {
        info.checksum = bus.cartridge.rom[0x14E..0x150].*;
    }
    try writeBlock(writer, "INFO", std.mem.asBytes(&info));

    // CORE
    var core = CoreHeader{
        .major = native(u16, 1),
        .minor = native(u16, 1),
        .model = "GD  ".*,
        .pc = native(u16, cpu.pc),
        .af = native(u16, cpu.getAF()),
        .bc = native(u16, cpu.getBC()),
        .de = native(u16, cpu.getDE()),
        .hl = native(u16, cpu.getHL()),
        .sp = native(u16, cpu.sp),
        .ime = @intFromBool(cpu.interrupt_master_enable),
        .ie = @bitCast(bus.interrupt_enable),
        .execution_state = @intFromBool(cpu.halted),
        ._reserved = 0,
        .io = buildIoRegisters(bus),
        .wram = wram_region,
        .vram = vram_region,
        .mbc_ram = mbc_ram_region,
        .oam = oam_region,
        .hram = hram_region,
        .bg_palettes = .{ .size = 0, .offset = 0 },
        .obj_palettes = .{ .size = 0, .offset = 0 },
    };
    // Memory regions need LE byte order
    inline for (&.{ &core.wram, &core.vram, &core.mbc_ram, &core.oam, &core.hram }) |region| {
        region.size = native(u32, region.size);
        region.offset = native(u32, region.offset);
    }
    try writeBlock(writer, "CORE", std.mem.asBytes(&core));

    // MBC
    try writeMbcBlock(writer, bus);

    // RTC (MBC3 only)
    try writeRtcBlock(writer, bus);

    // END
    try writeBlock(writer, "END ", &.{});

    // Footer
    try writer.writeAll(&std.mem.toBytes(native(u32, first_block_offset)));
    try writer.writeAll("BESS");
}

fn buildIoRegisters(bus: *const Bus) [128]u8 {
    var io: [128]u8 = .{0xFF} ** 128;

    io[0x00] = bus.input.readByte();
    io[0x01] = bus.serial.value;
    io[0x02] = 0x00;
    io[0x04] = @truncate(bus.ppu.internal_counter >> 8);
    io[0x05] = bus.ppu.tima_counter;
    io[0x06] = bus.ppu.tma_modulo;
    io[0x07] = bus.ppu.tac;
    io[0x0F] = @as(u8, @bitCast(bus.ppu.interrupt_flag)) | 0xE0;

    for (0x10..0x40) |i| io[i] = bus.apu.readByte(@intCast(0xFF00 + i));

    io[0x40] = @bitCast(bus.ppu.lcdc);
    io[0x41] = bus.ppu.readVram(0xFF41);
    io[0x42] = bus.ppu.scy;
    io[0x43] = bus.ppu.scx;
    io[0x44] = bus.ppu.ly;
    io[0x45] = bus.ppu.lc;
    io[0x46] = 0x00;
    io[0x47] = bus.ppu.bgp;
    io[0x48] = bus.ppu.pal0;
    io[0x49] = bus.ppu.pal1;
    io[0x4A] = bus.ppu.wy;
    io[0x4B] = bus.ppu.wx;
    io[0x4C] = 0x04; // KEY0 — DMG mode
    io[0x50] = 0x01; // BANK — boot ROM disabled

    return io;
}

fn mbcEntry(addr: u16, value: u8) [3]u8 {
    return std.mem.toBytes(native(u16, addr)) ++ .{value};
}

fn writeMbcBlock(writer: anytype, bus: *const Bus) !void {
    const ram_en: u8 = if (bus.cartridge.ram_on) 0x0A else 0x00;
    switch (bus.cartridge.mbc_state) {
        .mbc1 => |s| {
            const payload = mbcEntry(0x0000, ram_en) ++
                mbcEntry(0x2000, @truncate(bus.cartridge.rom_bank & 0x1F)) ++
                mbcEntry(0x4000, @truncate(bus.cartridge.ram_bank)) ++
                mbcEntry(0x6000, s.mode);
            try writeBlock(writer, "MBC ", &payload);
        },
        .mbc3 => |s| {
            const payload = mbcEntry(0x0000, ram_en) ++
                mbcEntry(0x2000, @truncate(bus.cartridge.rom_bank)) ++
                mbcEntry(0x4000, s.rtc_register) ++
                mbcEntry(0x6000, s.rtc_latch);
            try writeBlock(writer, "MBC ", &payload);
        },
        .no_mbc => {},
    }
}

fn writeRtcBlock(writer: anytype, bus: *const Bus) !void {
    switch (bus.cartridge.mbc_state) {
        .mbc3 => |s| {
            // 5 current u32 LE + 5 latched u32 LE + 8-byte UNIX timestamp = 0x30
            var buf: [0x30]u8 = .{0} ** 0x30;
            const vals = [5]u8{ s.rtc_s, s.rtc_m, s.rtc_h, s.rtc_dl, s.rtc_dh };
            for (vals, 0..) |v, i| {
                buf[i * 4] = v; // current
                buf[20 + i * 4] = v; // latched (same)
            }
            try writeBlock(writer, "RTC ", &buf);
        },
        else => {},
    }
}

// ── Read ────────────────────────────────────────────────────────────

pub fn read(file_data: []const u8, cpu: *CPU, bus: *Bus) !void {
    if (file_data.len < 8) return error.InvalidFormat;

    const footer = file_data[file_data.len - 8 ..];
    if (!std.mem.eql(u8, footer[4..8], "BESS")) {
        if (file_data.len >= 4 and std.mem.eql(u8, file_data[0..4], "GBZS"))
            return error.LegacyFormat;
        return error.InvalidFormat;
    }

    const start = std.mem.readInt(u32, footer[0..4], .little);
    if (start >= file_data.len - 8) return error.InvalidFormat;
    const data_end = file_data.len - 8;

    // Validation pass — no state mutation
    {
        var iter = BlockIterator{ .data = file_data, .pos = start, .end = data_end };
        while (iter.next()) |block| {
            if (std.mem.eql(u8, block.tag, "INFO")) {
                try validateInfo(block.payload, bus);
            } else if (std.mem.eql(u8, block.tag, "CORE")) {
                try validateCore(block.payload, file_data);
            } else if (std.mem.eql(u8, block.tag, "END ")) break;
        }
    }

    // Apply pass
    var iter = BlockIterator{ .data = file_data, .pos = start, .end = data_end };
    while (iter.next()) |block| {
        if (std.mem.eql(u8, block.tag, "CORE")) {
            applyCore(block.payload, file_data, cpu, bus);
        } else if (std.mem.eql(u8, block.tag, "MBC ")) {
            applyMbc(block.payload, &bus.cartridge);
        } else if (std.mem.eql(u8, block.tag, "RTC ")) {
            applyRtc(block.payload, &bus.cartridge);
        } else if (std.mem.eql(u8, block.tag, "END ")) break;
    }
}

fn validateInfo(payload: []const u8, bus: *const Bus) !void {
    if (payload.len < @sizeOf(InfoBlock)) return error.InvalidFormat;
    if (bus.cartridge.rom.len > 0x14F) {
        if (payload[16] != bus.cartridge.rom[0x14E] or payload[17] != bus.cartridge.rom[0x14F])
            return error.RomMismatch;
    }
}

fn validateCore(payload: []const u8, file_data: []const u8) !void {
    if (payload.len < @sizeOf(CoreHeader)) return error.InvalidFormat;
    const core: *const CoreHeader = @ptrCast(@alignCast(payload.ptr));
    inline for (&.{ core.wram, core.vram, core.mbc_ram, core.oam, core.hram }) |region| {
        const size = le(u32, region.size);
        const offset = le(u32, region.offset);
        if (size > 0 and offset + size > file_data.len) return error.InvalidFormat;
    }
}

fn applyCore(payload: []const u8, file_data: []const u8, cpu: *CPU, bus: *Bus) void {
    const core: *const CoreHeader = @ptrCast(@alignCast(payload.ptr));

    const af = le(u16, core.af);
    cpu.a = @truncate(af >> 8);
    cpu.f = @bitCast(@as(u8, @truncate(af)) & 0xF0);
    const bc = le(u16, core.bc);
    cpu.b = @truncate(bc >> 8);
    cpu.c = @truncate(bc);
    const de = le(u16, core.de);
    cpu.d = @truncate(de >> 8);
    cpu.e = @truncate(de);
    const hl = le(u16, core.hl);
    cpu.h = @truncate(hl >> 8);
    cpu.l = @truncate(hl);
    cpu.pc = le(u16, core.pc);
    cpu.sp = le(u16, core.sp);
    cpu.interrupt_master_enable = core.ime != 0;
    cpu.halted = core.execution_state != 0;
    cpu.ei_pending = false;
    bus.interrupt_enable = @bitCast(core.ie);

    restoreIoRegisters(&core.io, bus);

    // Copy memory blobs (bounds already validated)
    const regions = .{
        .{ le(u32, core.wram.offset), le(u32, core.wram.size), bus.wram[0..0x2000] },
        .{ le(u32, core.vram.offset), le(u32, core.vram.size), bus.ppu.vram[0..0x2000] },
        .{ le(u32, core.oam.offset), le(u32, core.oam.size), bus.ppu.oam[0..0xA0] },
        .{ le(u32, core.hram.offset), le(u32, core.hram.size), bus.zram[0..0x7F] },
    };
    inline for (regions) |r| {
        const off, const size, const dest = r;
        if (size > 0) @memcpy(dest[0..@min(size, dest.len)], file_data[off..][0..@min(size, dest.len)]);
    }

    // MBC RAM separately (variable size)
    const mbc_off = le(u32, core.mbc_ram.offset);
    const mbc_size = le(u32, core.mbc_ram.size);
    if (mbc_size > 0) {
        const n: usize = @min(mbc_size, bus.cartridge.ram_len);
        if (n > 0) @memcpy(bus.cartridge.ram[0..n], file_data[mbc_off..][0..n]);
    }
}

fn restoreIoRegisters(io: *const [128]u8, bus: *Bus) void {
    // Joypad
    bus.input.mode = if ((io[0x00] & 0x10) == 0) .direction else .action;

    // Serial
    bus.serial.value = io[0x01];

    // Timer — write fields directly (no DIV reset / falling-edge side effects)
    bus.ppu.internal_counter = @as(u16, io[0x04]) << 8;
    bus.ppu.tima_counter = io[0x05];
    bus.ppu.tma_modulo = io[0x06];
    bus.ppu.tac = io[0x07];
    bus.ppu.prev_timer_bit = bus.ppu.timerBit();

    // IF
    bus.ppu.interrupt_flag = @bitCast(io[0x0F] & 0x1F);

    // APU — writeByte is fine, sound channel triggers are harmless
    for (0x10..0x40) |i| bus.apu.writeByte(@intCast(0xFF00 + i), io[i]);

    // PPU — write directly to avoid LCD toggle / STAT interrupt side effects
    bus.ppu.lcdc = @bitCast(io[0x40]);
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
    bus.ppu.stat_line = bus.ppu.computeStatLine();
}

fn applyMbc(payload: []const u8, cartridge: *Cartridge) void {
    var i: usize = 0;
    while (i + 2 < payload.len) : (i += 3) {
        const addr = std.mem.readInt(u16, payload[i..][0..2], .little);
        cartridge.writeRom(addr, payload[i + 2]);
    }
}

fn applyRtc(payload: []const u8, cartridge: *Cartridge) void {
    if (payload.len < 0x30) return;
    switch (cartridge.mbc_state) {
        .mbc3 => |*s| {
            s.rtc_s = payload[0];
            s.rtc_m = payload[4];
            s.rtc_h = payload[8];
            s.rtc_dl = payload[12];
            s.rtc_dh = payload[16];
        },
        else => {},
    }
}
