const std = @import("std");

pub const VRAM_SIZE: usize = 0x2000;
pub const OAM_SIZE: usize = 0xA0;
pub const SCREEN_W: usize = 160;
pub const SCREEN_H: usize = 144;

const StatMode = enum(u2) {
    hblank = 0,
    vblank = 1,
    oam_read = 2,
    transfer = 3,
};

const Lcdc = packed struct(u8) {
    bg_and_window_display: bool = false,
    obj_display_enable: bool = false,
    obj_size: bool = false, // false = 8x8, true = 8x16
    bg_tile_map_select: bool = false, // false = 9800, true = 9C00
    bg_and_window_tile_data_select: bool = false, // false = 8800, true = 8000
    window_display_enable: bool = false,
    window_tile_map_select: bool = false, // false = 9800, true = 9C00
    lcd_display_enable: bool = false,

    fn bgTileDataBase(self: Lcdc) u16 {
        return if (self.bg_and_window_tile_data_select) 0x8000 else 0x8800;
    }

    fn bgTileMapBase(self: Lcdc) u16 {
        return if (self.bg_tile_map_select) 0x9c00 else 0x9800;
    }

    fn windowTileMapBase(self: Lcdc) u16 {
        return if (self.window_tile_map_select) 0x9c00 else 0x9800;
    }

    fn objHeight(self: Lcdc) u16 {
        return if (self.obj_size) 16 else 8;
    }
};

const Stat = struct {
    enable_ly_interrupt: bool = false,
    enable_m2_interrupt: bool = false,
    enable_m1_interrupt: bool = false,
    enable_m0_interrupt: bool = false,
    mode: StatMode = .hblank,
};

pub const InterruptFlags = packed struct(u8) {
    vblank: bool = false,
    lcd_stat: bool = false,
    timer: bool = false,
    serial: bool = false,
    joypad: bool = false,
    _pad: u3 = 0,

    pub fn highestPrioBit(self: InterruptFlags) InterruptFlags {
        if (self.vblank) return .{ .vblank = true };
        if (self.lcd_stat) return .{ .lcd_stat = true };
        if (self.timer) return .{ .timer = true };
        if (self.serial) return .{ .serial = true };
        if (self.joypad) return .{ .joypad = true };
        return .{};
    }

    pub fn interruptAddress(self: InterruptFlags) ?u16 {
        const prio = self.highestPrioBit();
        if (prio.vblank) return 0x40;
        if (prio.lcd_stat) return 0x48;
        if (prio.timer) return 0x50;
        if (prio.serial) return 0x58;
        if (prio.joypad) return 0x60;
        return null;
    }

    pub fn anySet(self: InterruptFlags) bool {
        return self.vblank or self.lcd_stat or self.timer or self.serial or self.joypad;
    }

    pub fn bitwiseAnd(a: InterruptFlags, b: InterruptFlags) InterruptFlags {
        return @bitCast(@as(u8, @bitCast(a)) & @as(u8, @bitCast(b)));
    }

    pub fn remove(self: *InterruptFlags, mask: InterruptFlags) void {
        self.* = @bitCast(@as(u8, @bitCast(self.*)) & ~@as(u8, @bitCast(mask)));
    }

    pub fn insert(self: *InterruptFlags, mask: InterruptFlags) void {
        self.* = @bitCast(@as(u8, @bitCast(self.*)) | @as(u8, @bitCast(mask)));
    }
};

fn paletteColor(palette: u8, color_idx: u8, dmg_colors: bool) u32 {
    const shade: u2 = @truncate(palette >> (@as(u3, @truncate(color_idx)) * 2));
    if (dmg_colors) {
        return switch (shade) {
            0b00 => 0xff9BBC0F, // Lightest
            0b01 => 0xff8BAC0F, // Light
            0b10 => 0xff306230, // Dark
            0b11 => 0xff0F380F, // Darkest
        };
    } else {
        return switch (shade) {
            0b00 => 0xffE0F8D0, // White
            0b01 => 0xff88C070, // Light gray
            0b10 => 0xff356856, // Dark gray
            0b11 => 0xff091820, // Black
        };
    }
}

fn paletteShade(palette: u8, color_idx: u8) u2 {
    return @truncate(palette >> (@as(u3, @truncate(color_idx)) * 2));
}

pub const PPU = struct {
    lcdc: Lcdc = @bitCast(@as(u8, 0x48)),
    stat: Stat = .{},
    dmg_colors: bool = true,

    vram: [VRAM_SIZE]u8 = [_]u8{0} ** VRAM_SIZE,
    oam: [OAM_SIZE]u8 = [_]u8{0} ** OAM_SIZE,

    scy: u8 = 0,
    scx: u8 = 0,
    wy: u8 = 0,
    wx: u8 = 0,
    ly: u8 = 0,
    lc: u8 = 0, // LYC
    bgp: u8 = 0,
    pal0: u8 = 0, // OBP0
    pal1: u8 = 0, // OBP1

    win_y_trigger: bool = false,
    wc: i32 = 0, // window internal line counter

    // Timer registers
    div: u8 = 0,
    tima_counter: u8 = 0,
    tma_modulo: u8 = 0,
    tac: u8 = 0,

    // Cycle counters
    cycles: u32 = 0,
    div_cycles: u32 = 0,
    timer_clock: u32 = 0,

    interrupt_flag: InterruptFlags = .{},

    frame_buffer: [SCREEN_W * SCREEN_H]u32 = [_]u32{0} ** (SCREEN_W * SCREEN_H),

    pub fn readVram(self: *const PPU, addr: u16) u8 {
        return switch (addr) {
            0x8000...0x9fff => self.vram[addr & 0x1fff],
            0xfe00...0xfe9f => self.oam[addr - 0xfe00],
            0xff40 => @bitCast(self.lcdc),
            0xff41 => blk: {
                var v: u8 = 0;
                if (self.stat.enable_ly_interrupt) v |= 0x40;
                if (self.stat.enable_m2_interrupt) v |= 0x20;
                if (self.stat.enable_m1_interrupt) v |= 0x10;
                if (self.stat.enable_m0_interrupt) v |= 0x08;
                if (self.ly == self.lc) v |= 0x04;
                const mode: u8 = if (!self.lcdc.lcd_display_enable) 0 else @intFromEnum(self.stat.mode);
                v |= mode;
                break :blk v;
            },
            0xff42 => self.scy,
            0xff43 => self.scx,
            0xff44 => if (!self.lcdc.lcd_display_enable) 0 else self.ly,
            0xff45 => self.lc,
            0xff47 => self.bgp,
            0xff48 => self.pal0,
            0xff49 => self.pal1,
            0xff4a => self.wy,
            0xff4b => self.wx,
            0xff4f => 0xfe,
            0xff04 => self.div,
            0xff05 => self.tima_counter,
            0xff06 => self.tma_modulo,
            0xff07 => self.tac,
            0xff0f => @bitCast(self.interrupt_flag),
            else => 0xff,
        };
    }

    pub fn writeVram(self: *PPU, addr: u16, value: u8) void {
        switch (addr) {
            0x8000...0x9fff => self.vram[addr & 0x1fff] = value,
            0xfe00...0xfe9f => self.oam[addr - 0xfe00] = value,
            0xff40 => self.lcdc = @bitCast(value),
            0xff41 => {
                self.stat.enable_ly_interrupt = (value & 0x40) != 0;
                self.stat.enable_m2_interrupt = (value & 0x20) != 0;
                self.stat.enable_m1_interrupt = (value & 0x10) != 0;
                self.stat.enable_m0_interrupt = (value & 0x08) != 0;
            },
            0xff42 => self.scy = value,
            0xff43 => self.scx = value,
            0xff44 => self.ly = value,
            0xff45 => self.lc = value,
            0xff47 => self.bgp = value,
            0xff48 => self.pal0 = value,
            0xff49 => self.pal1 = value,
            0xff4a => self.wy = value,
            0xff4b => self.wx = value,
            0xff4f => {}, // VRAM bank (CGB only)
            0xff04 => {
                self.div_cycles = 0;
                self.div = 0;
            },
            0xff05 => self.tima_counter = value,
            0xff06 => self.tma_modulo = value,
            0xff07 => self.tac = value,
            0xff68, 0xff69, 0xff6a, 0xff6b => {}, // CGB only
            0xff0f => self.interrupt_flag = @bitCast(value),
            else => {},
        }
    }

    fn updateDiv(self: *PPU, elapsed: u32) void {
        self.div_cycles += elapsed;
        while (self.div_cycles >= 256) {
            self.div_cycles -= 256;
            self.div +%= 1;
        }
    }

    fn handleTimer(self: *PPU, elapsed: u32) void {
        self.updateDiv(elapsed);

        const timer_enabled = (self.tac & 0x04) != 0;
        if (!timer_enabled) return;

        self.timer_clock += elapsed;

        const step: u32 = switch (self.tac & 0b11) {
            1 => 16,
            2 => 64,
            3 => 256,
            else => 1024,
        };

        while (self.timer_clock >= step) {
            self.timer_clock -= step;

            const result = @addWithOverflow(self.tima_counter, 1);
            self.tima_counter = result[0];
            if (result[1] != 0) {
                self.tima_counter = self.tma_modulo;
                self.interrupt_flag.insert(.{ .timer = true });
            }
        }
    }

    pub fn next(self: *PPU, elapsed: u32) bool {
        self.cycles += elapsed;
        self.handleTimer(elapsed);

        if (!self.lcdc.lcd_display_enable) return false;

        var should_render = false;

        switch (self.stat.mode) {
            .oam_read => {
                if (self.ly >= self.wy) {
                    self.win_y_trigger = true;
                }
                if (self.cycles >= 80) {
                    self.cycles -= 80;
                    self.stat.mode = .transfer;
                }
            },
            .transfer => {
                if (self.cycles >= 172) {
                    self.cycles -= 172;
                    self.stat.mode = .hblank;
                    if (self.stat.enable_m0_interrupt) {
                        self.interrupt_flag.insert(.{ .lcd_stat = true });
                    }
                    self.renderLine();
                }
            },
            .hblank => {
                if (self.cycles >= 204) {
                    self.cycles -= 204;
                    self.ly += 1;

                    if (self.stat.enable_ly_interrupt and self.ly == self.lc) {
                        self.interrupt_flag.insert(.{ .lcd_stat = true });
                    }

                    if (self.ly == 144) {
                        self.stat.mode = .vblank;
                        self.interrupt_flag.insert(.{ .vblank = true });
                        if (self.stat.enable_m1_interrupt) {
                            self.interrupt_flag.insert(.{ .lcd_stat = true });
                        }
                        should_render = true;
                    } else {
                        self.stat.mode = .oam_read;
                        if (self.stat.enable_m2_interrupt) {
                            self.interrupt_flag.insert(.{ .lcd_stat = true });
                        }
                    }
                }
            },
            .vblank => {
                if (self.cycles >= 456) {
                    self.cycles -= 456;
                    self.ly += 1;

                    if (self.stat.enable_ly_interrupt and self.ly == self.lc) {
                        self.interrupt_flag.insert(.{ .lcd_stat = true });
                    }

                    if (self.ly > 153) {
                        self.interrupt_flag.remove(.{ .vblank = true });
                        self.stat.mode = .oam_read;
                        if (self.stat.enable_m2_interrupt) {
                            self.interrupt_flag.insert(.{ .lcd_stat = true });
                        }
                        self.ly = 0;
                        self.wc = 0;
                        self.win_y_trigger = false;
                    }
                }
            },
        }

        return should_render;
    }

    fn readVramInternal(self: *const PPU, addr: u16) u8 {
        return switch (addr) {
            0x8000...0x9fff => self.vram[addr & 0x1fff],
            0xfe00...0xfe9f => self.oam[addr - 0xfe00],
            else => 0xff,
        };
    }

    fn getTileLocation(self: *const PPU, tx: u8, ty: u8, base: u16) u16 {
        const tile_base = self.lcdc.bgTileDataBase();
        const tile_addr = base + @as(u16, ty) * 32 + @as(u16, tx);
        const tile_number = self.readVramInternal(tile_addr);

        const tile_offset: u16 = if (self.lcdc.bg_and_window_tile_data_select)
            @as(u16, tile_number) * 16
        else
            @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(tile_number))) +% 128)) *% 16;

        return tile_base +% tile_offset;
    }

    fn getPixelColor(self: *const PPU, tile_location: u16, tile_y: u8, tile_x: u8) u8 {
        const a = self.readVramInternal(tile_location + @as(u16, tile_y) * 2);
        const b = self.readVramInternal(tile_location + @as(u16, tile_y) * 2 + 1);

        const bit: u3 = @intCast(7 - @as(u8, tile_x & 0x07));
        const color_l: u8 = if ((a >> bit) & 1 != 0) 1 else 0;
        const color_h: u8 = if ((b >> bit) & 1 != 0) 2 else 0;
        return color_h | color_l;
    }

    fn drawBgPixel(self: *const PPU, x: u16, y: u16, win_x_trigger: bool) u32 {
        if (!self.lcdc.bg_and_window_display) {
            return paletteColor(self.bgp, 0, self.dmg_colors); // White
        }

        if (win_x_trigger) {
            const wx_adj: u8 = @intCast((x + 7 -% @as(u16, self.wx)) & 0xff);
            const wy_adj: u8 = @intCast(@as(u32, @bitCast(self.wc)) & 0xff);
            const tile_loc = self.getTileLocation(wx_adj / 8, wy_adj / 8, self.lcdc.windowTileMapBase());
            const color_idx = self.getPixelColor(tile_loc, wy_adj % 8, wx_adj % 8);
            return paletteColor(self.bgp, color_idx, self.dmg_colors);
        }

        const scroll_x: u8 = @intCast((@as(u16, self.scx) + x) & 0xff);
        const scroll_y: u8 = @intCast((@as(u16, self.scy) + y) & 0xff);
        const tile_loc = self.getTileLocation(scroll_x / 8, scroll_y / 8, self.lcdc.bgTileMapBase());
        const color_idx = self.getPixelColor(tile_loc, scroll_y % 8, scroll_x % 8);
        return paletteColor(self.bgp, color_idx, self.dmg_colors);
    }

    fn bgShade(self: *const PPU, x: u16, y: u16, win_x_trigger: bool) u2 {
        if (!self.lcdc.bg_and_window_display) return 0;

        if (win_x_trigger) {
            const wx_adj: u8 = @intCast((x + 7 -% @as(u16, self.wx)) & 0xff);
            const wy_adj: u8 = @intCast(@as(u32, @bitCast(self.wc)) & 0xff);
            const tile_loc = self.getTileLocation(wx_adj / 8, wy_adj / 8, self.lcdc.windowTileMapBase());
            const color_idx = self.getPixelColor(tile_loc, wy_adj % 8, wx_adj % 8);
            return paletteShade(self.bgp, color_idx);
        }

        const scroll_x: u8 = @intCast((@as(u16, self.scx) + x) & 0xff);
        const scroll_y: u8 = @intCast((@as(u16, self.scy) + y) & 0xff);
        const tile_loc = self.getTileLocation(scroll_x / 8, scroll_y / 8, self.lcdc.bgTileMapBase());
        const color_idx = self.getPixelColor(tile_loc, scroll_y % 8, scroll_x % 8);
        return paletteShade(self.bgp, color_idx);
    }

    fn populateSprites(self: *const PPU, line: u16) struct { sprites: [10][3]i32, len: usize } {
        var sprites: [10][3]i32 = undefined;
        var index: usize = 0;
        const sprite_size = self.lcdc.objHeight();

        for (0..40) |i| {
            const addr: u16 = 0xfe00 + @as(u16, @intCast(i)) * 4;
            const sprite_y: i32 = @as(i32, self.readVramInternal(addr)) - 16;
            const line_i: i32 = @intCast(line);

            if (line_i < sprite_y or line_i >= sprite_y + @as(i32, @intCast(sprite_size))) continue;

            const sprite_x: i32 = @as(i32, self.readVramInternal(addr + 1)) - 8;
            sprites[index] = .{ sprite_x, sprite_y, @intCast(i) };
            index += 1;
            if (index >= 10) break;
        }

        // Sort by x position
        if (index > 1) {
            std.mem.sort([3]i32, sprites[0..index], {}, struct {
                fn lessThan(_: void, a: [3]i32, b: [3]i32) bool {
                    return a[0] < b[0];
                }
            }.lessThan);
        }

        return .{ .sprites = sprites, .len = index };
    }

    fn drawSpriteAt(self: *const PPU, sprites: []const [3]i32, x: u8, y: u8, bg_is_white: bool) ?u32 {
        const sprite_size = self.lcdc.objHeight();

        for (sprites) |sprite| {
            const sprite_x = sprite[0];
            const sprite_y = sprite[1];
            const i: u16 = @intCast(sprite[2]);

            const tile_x_i = @as(i32, x) - sprite_x;
            if (tile_x_i < 0 or tile_x_i > 7) continue;

            const addr = 0xfe00 + i * 4;
            var tile_num = @as(u16, self.readVramInternal(addr + 2));
            if (sprite_size == 16) tile_num &= 0xfe;
            const flags = self.readVramInternal(addr + 3);
            const use_pal1 = (flags & 0x10) != 0;
            const x_flip = (flags & 0x20) != 0;
            const y_flip = (flags & 0x40) != 0;
            const behind_non_white_bg = (flags & 0x80) != 0;

            if (@as(i32, y) - sprite_y > @as(i32, @intCast(sprite_size)) - 1) continue;

            const tile_y: u16 = if (y_flip)
                sprite_size - 1 - @as(u16, @intCast(@as(i32, y) - sprite_y))
            else
                @intCast(@as(i32, y) - sprite_y);

            const tile_addr = @as(u16, 0x8000) + tile_num * 16 + tile_y * 2;

            const b1 = self.readVramInternal(tile_addr);
            const b2 = self.readVramInternal(tile_addr + 1);

            const x_bit_pos: u3 = @intCast(if (x_flip) tile_x_i else 7 - tile_x_i);
            const x_bit: u8 = @as(u8, 1) << x_bit_pos;

            const color: u8 = (if (b1 & x_bit != 0) @as(u8, 1) else 0) | (if (b2 & x_bit != 0) @as(u8, 2) else 0);

            if (color == 0) continue;
            if (!bg_is_white and behind_non_white_bg) continue;

            const palette = if (use_pal1) self.pal1 else self.pal0;
            return paletteColor(palette, color, self.dmg_colors);
        }

        return null;
    }

    fn renderLine(self: *PPU) void {
        const y = @as(u16, self.ly);
        const sprite_data = self.populateSprites(y);
        var win_x_trigger = false;

        for (0..SCREEN_W) |xi| {
            const x: u16 = @intCast(xi);
            const index = @as(usize, y) * SCREEN_W + xi;

            if (self.lcdc.window_display_enable and self.win_y_trigger and !win_x_trigger) {
                win_x_trigger = self.wx > 0 and x + 7 >= @as(u16, self.wx);
            }

            var pixel = self.drawBgPixel(x, y, win_x_trigger);

            if (self.lcdc.obj_display_enable and sprite_data.len > 0) {
                const bg_is_white = self.bgShade(x, y, win_x_trigger) == 0;
                if (self.drawSpriteAt(sprite_data.sprites[0..sprite_data.len], @intCast(x), @intCast(y), bg_is_white)) |color| {
                    pixel = color;
                }
            }

            self.frame_buffer[index] = pixel;
        }

        if (win_x_trigger) {
            self.wc += 1;
        }
    }
};
