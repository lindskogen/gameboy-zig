const MBC = @This();

pub const Type = union(enum) {
    no_mbc,
    mbc1: MBC1,
    mbc3: MBC3,

    pub const MBC1 = struct {
        mode: u1 = 0, // 0 = ROM mode, 1 = RAM mode
    };

    pub const MBC3 = struct {
        rtc_register: u8 = 0, // RAM bank (0-3) or RTC register (0x08-0x0C)
        rtc_latch: u8 = 0,
        rtc_s: u8 = 0,
        rtc_m: u8 = 0,
        rtc_h: u8 = 0,
        rtc_dl: u8 = 0,
        rtc_dh: u8 = 0,

        pub fn rtcRead(s: MBC3) u8 {
            return switch (s.rtc_register) {
                0x08 => s.rtc_s,
                0x09 => s.rtc_m,
                0x0A => s.rtc_h,
                0x0B => s.rtc_dl,
                0x0C => s.rtc_dh,
                else => 0xff,
            };
        }

        pub fn rtcWrite(s: *MBC3, value: u8) void {
            switch (s.rtc_register) {
                0x08 => s.rtc_s = value,
                0x09 => s.rtc_m = value,
                0x0A => s.rtc_h = value,
                0x0B => s.rtc_dl = value,
                0x0C => s.rtc_dh = value,
                else => {},
            }
        }
    };
};

/// Map cart type byte (0x147) to MBC variant.
pub fn fromCartType(cart_type: u8) Type {
    return switch (cart_type) {
        0x00, 0x08, 0x09 => .no_mbc,
        0x01, 0x02, 0x03 => .{ .mbc1 = .{} },
        0x0F, 0x10, 0x11, 0x12, 0x13 => .{ .mbc3 = .{} },
        else => .no_mbc,
    };
}

/// Map cart type byte to whether it has a battery.
pub fn hasBattery(cart_type: u8) bool {
    return switch (cart_type) {
        0x03, 0x06, 0x09, 0x0D, 0x0F, 0x10, 0x13, 0x1B, 0x1E, 0xFF => true,
        else => false,
    };
}

/// Map ROM size code (0x148) to number of 16KB banks.
pub fn romBanks(code: u8) usize {
    if (code <= 8) {
        return @as(usize, 2) << @intCast(code);
    }
    return 0;
}

/// Map RAM size code (0x149) to number of 8KB banks.
pub fn ramBanks(code: u8) usize {
    return switch (code) {
        1, 2 => 1,
        3 => 4,
        4 => 16,
        5 => 8,
        else => 0,
    };
}
