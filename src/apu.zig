const std = @import("std");

// ─── Duty table ──────────────────────────────────────────────────────────────
const DUTY_TABLE: [4][8]u1 = .{
    .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 1, 1, 1 },
    .{ 0, 1, 1, 1, 1, 1, 1, 0 },
};

// ─── Ring Buffer ─────────────────────────────────────────────────────────────
const RING_BUFFER_SIZE: usize = 16384;

pub const RingBuffer = struct {
    data: [RING_BUFFER_SIZE]f32 = [_]f32{0} ** RING_BUFFER_SIZE,
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    read_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn push(self: *RingBuffer, sample: f32) void {
        const wp = self.write_pos.load(.acquire);
        const next = (wp + 1) % RING_BUFFER_SIZE;
        if (next == self.read_pos.load(.acquire)) return;
        self.data[wp] = sample;
        self.write_pos.store(next, .release);
    }

    pub fn pop(self: *RingBuffer) ?f32 {
        const rp = self.read_pos.load(.acquire);
        if (rp == self.write_pos.load(.acquire)) return null;
        const sample = self.data[rp];
        self.read_pos.store((rp + 1) % RING_BUFFER_SIZE, .release);
        return sample;
    }
};

// ─── Volume Envelope ─────────────────────────────────────────────────────────
const VolumeEnvelope = struct {
    timer: u8 = 0,
    period: u8 = 0,
    add_mode: bool = false,
    starting_volume: u8 = 0,
    volume: u8 = 0,
    finished: bool = true,

    fn setNr12(self: *VolumeEnvelope, v: u8) void {
        self.starting_volume = v >> 4;
        self.add_mode = (v & 0x08) != 0;
        self.period = v & 0b111;
    }

    fn getNr12(self: *const VolumeEnvelope) u8 {
        return (self.starting_volume << 4) | (if (self.add_mode) @as(u8, 0x08) else 0) | self.period;
    }

    fn getVolume(self: *const VolumeEnvelope) u8 {
        return if (self.period > 0) self.volume else self.starting_volume;
    }

    fn trigger(self: *VolumeEnvelope) void {
        self.volume = self.starting_volume;
        self.finished = false;
        self.timer = if (self.period != 0) self.period else 8;
    }

    fn tick(self: *VolumeEnvelope) void {
        if (self.finished) return;

        self.timer = self.timer -| 1;
        if (self.timer == 0) {
            self.timer = if (self.period != 0) self.period else 8;
            if (self.add_mode and self.volume < 15) {
                self.volume += 1;
            }
            if (!self.add_mode and self.volume > 0) {
                self.volume -= 1;
            }
            if (self.volume == 0 or self.volume == 15) {
                self.finished = true;
            }
        }
    }

    fn powerOff(self: *VolumeEnvelope) void {
        self.finished = false;
        self.timer = 0;
        self.starting_volume = 0;
        self.add_mode = false;
        self.period = 0;
        self.volume = 0;
    }
};

// ─── Length Counter ──────────────────────────────────────────────────────────
const LengthCounter = struct {
    enabled: bool = false,
    length: u8 = 0,
    full_length: u8 = 64,
    frame_sequencer: u8 = 0,

    fn isZero(self: *const LengthCounter) bool {
        return self.length == 0;
    }

    fn isEnabled(self: *const LengthCounter) bool {
        return self.enabled;
    }

    fn setNr14(self: *LengthCounter, v: u8) void {
        const enable = (v & 0x40) != 0;
        const trig = (v & 0x80) != 0;

        if (self.enabled) {
            if (trig and self.isZero()) {
                self.length = if (enable and (self.frame_sequencer & 1) != 0)
                    self.full_length - 1
                else
                    self.full_length;
            }
        } else if (enable) {
            if ((self.frame_sequencer & 1) != 0) {
                if (self.length != 0) {
                    self.length -= 1;
                }
                if (trig and self.isZero()) {
                    self.length = self.full_length - 1;
                }
            }
        } else {
            if (trig and self.isZero()) {
                self.length = self.full_length;
            }
        }

        self.enabled = enable;
    }

    fn setLength(self: *LengthCounter, v: u8) void {
        self.length = self.full_length -| v;
    }

    fn tick(self: *LengthCounter) void {
        if (self.enabled and self.length > 0) {
            self.length -= 1;
        }
    }

    fn powerOff(self: *LengthCounter) void {
        self.enabled = false;
        self.frame_sequencer = 0;
    }
};

// ─── Frequency Sweep ─────────────────────────────────────────────────────────
const FrequencySweep = struct {
    enabled: bool = false,
    overflow: bool = false,
    has_negated: bool = false,
    timer: u8 = 0,
    frequency: u16 = 0,
    shadow_frequency: u16 = 0,
    period: u8 = 0,
    negate: bool = false,
    shift: u8 = 0,

    fn calculate(self: *FrequencySweep) u16 {
        var new_freq = self.shadow_frequency >> @intCast(self.shift);

        if (self.negate) {
            new_freq = self.shadow_frequency - new_freq;
            self.has_negated = true;
        } else {
            new_freq = self.shadow_frequency + new_freq;
        }

        if (new_freq > 2047) {
            self.overflow = true;
        }

        return new_freq;
    }

    fn getFrequency(self: *const FrequencySweep) u32 {
        return @as(u32, self.frequency);
    }

    fn getNr10(self: *const FrequencySweep) u8 {
        return 0x80 | (self.period << 4) | (if (self.negate) @as(u8, 0b100) else 0) | self.shift;
    }

    fn setNr10(self: *FrequencySweep, v: u8) void {
        self.period = (v >> 4) & 0b111;
        self.negate = (v & 0x08) != 0;
        self.shift = v & 0b111;

        if (self.has_negated and !self.negate) {
            self.overflow = true;
        }
    }

    fn isEnabled(self: *const FrequencySweep) bool {
        return !self.overflow;
    }

    fn setNr13(self: *FrequencySweep, v: u8) void {
        self.frequency = (self.frequency & 0x700) | @as(u16, v);
    }

    fn setNr14(self: *FrequencySweep, v: u8) void {
        self.frequency = (self.frequency & 0xff) | (@as(u16, v & 0b111) << 8);
    }

    fn trigger(self: *FrequencySweep) void {
        self.overflow = false;
        self.has_negated = false;
        self.shadow_frequency = self.frequency;
        self.timer = if (self.period != 0) self.period else 8;
        self.enabled = self.period != 0 or self.shift != 0;

        if (self.shift > 0) {
            _ = self.calculate();
        }
    }

    fn tick(self: *FrequencySweep) void {
        if (!self.enabled) return;

        self.timer = self.timer -| 1;
        if (self.timer == 0) {
            self.timer = if (self.period != 0) self.period else 8;

            if (self.period != 0) {
                const new_freq = self.calculate();

                if (!self.overflow and self.shift != 0) {
                    self.shadow_frequency = new_freq;
                    self.frequency = new_freq;
                    _ = self.calculate();
                }
            }
        }
    }

    fn powerOff(self: *FrequencySweep) void {
        self.enabled = false;
        self.overflow = false;
        self.has_negated = false;
        self.timer = 0;
        self.frequency = 0;
        self.shadow_frequency = 0;
        self.period = 0;
        self.negate = false;
        self.shift = 0;
    }
};

// ─── Channel 1 (Pulse with Sweep) ───────────────────────────────────────────
const Channel1 = struct {
    ch_enabled: bool = false,
    dac_enabled: bool = false,
    output: u8 = 0,
    length_counter: LengthCounter = .{},
    duty: u8 = 0,
    timer: u32 = 0,
    sequence: usize = 0,
    volume_envelope: VolumeEnvelope = .{},
    frequency_sweep: FrequencySweep = .{},

    fn isChannelEnabled(self: *const Channel1) bool {
        return self.dac_enabled and self.ch_enabled;
    }

    fn tickChannelLength(self: *Channel1) void {
        self.length_counter.tick();
        if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
            self.ch_enabled = false;
        }
    }

    fn readByte(self: *const Channel1, addr: u16) u8 {
        return switch (addr) {
            0xff10 => self.frequency_sweep.getNr10(),
            0xff11 => (self.duty << 6) | 0x3f,
            0xff12 => self.volume_envelope.getNr12(),
            0xff13 => 0xff,
            0xff14 => 0xbf | (if (self.length_counter.isEnabled()) @as(u8, 0x40) else 0),
            else => 0xff,
        };
    }

    fn writeByte(self: *Channel1, addr: u16, v: u8) void {
        switch (addr) {
            0xff10 => {
                self.frequency_sweep.setNr10(v);
                if (!self.frequency_sweep.isEnabled()) {
                    self.ch_enabled = false;
                }
            },
            0xff11 => {
                self.duty = v >> 6;
                self.length_counter.setLength(v & 0x3f);
            },
            0xff12 => {
                self.dac_enabled = (v & 0xf8) != 0;
                self.ch_enabled = self.isChannelEnabled();
                self.volume_envelope.setNr12(v);
            },
            0xff13 => self.frequency_sweep.setNr13(v),
            0xff14 => {
                self.frequency_sweep.setNr14(v);
                self.length_counter.setNr14(v);

                if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
                    self.ch_enabled = false;
                } else if ((v & 0x80) != 0) {
                    self.trigger();
                }
            },
            else => {},
        }
    }

    fn tick(self: *Channel1) void {
        self.timer = self.timer -| 1;
        if (self.timer == 0) {
            self.timer = (2048 - self.frequency_sweep.getFrequency()) << 2;
            self.sequence = (self.sequence + 1) % 8;

            self.output = if (self.isChannelEnabled()) blk: {
                break :blk if (DUTY_TABLE[self.duty][self.sequence] == 1)
                    self.volume_envelope.getVolume()
                else
                    0;
            } else 0;
        }
    }

    fn trigger(self: *Channel1) void {
        self.timer = (2048 - self.frequency_sweep.getFrequency()) << 2;
        self.volume_envelope.trigger();
        self.frequency_sweep.trigger();
        if (self.frequency_sweep.isEnabled()) {
            self.ch_enabled = self.dac_enabled;
        } else {
            self.ch_enabled = false;
        }
    }

    fn tickFrequencySweep(self: *Channel1) void {
        self.frequency_sweep.tick();
        if (!self.frequency_sweep.isEnabled()) {
            self.ch_enabled = false;
        }
    }

    fn powerOff(self: *Channel1) void {
        self.frequency_sweep.powerOff();
        self.volume_envelope.powerOff();
        self.length_counter.powerOff();
        self.ch_enabled = false;
        self.dac_enabled = false;
        self.sequence = 0;
        self.duty = 0;
    }
};

// ─── Channel 2 (Pulse) ──────────────────────────────────────────────────────
const Channel2 = struct {
    ch_enabled: bool = false,
    dac_enabled: bool = false,
    output: u8 = 0,
    length_counter: LengthCounter = .{},
    duty: u8 = 0,
    timer: u32 = 0,
    sequence: usize = 0,
    frequency: u32 = 0,
    volume_envelope: VolumeEnvelope = .{},

    fn isChannelEnabled(self: *const Channel2) bool {
        return self.dac_enabled and self.ch_enabled;
    }

    fn tickChannelLength(self: *Channel2) void {
        self.length_counter.tick();
        if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
            self.ch_enabled = false;
        }
    }

    fn readByte(self: *const Channel2, addr: u16) u8 {
        return switch (addr) {
            0xff15 => 0xff,
            0xff16 => (self.duty << 6) | 0x3f,
            0xff17 => self.volume_envelope.getNr12(),
            0xff18 => 0xff,
            0xff19 => 0xbf | (if (self.length_counter.isEnabled()) @as(u8, 0x40) else 0),
            else => 0xff,
        };
    }

    fn writeByte(self: *Channel2, addr: u16, v: u8) void {
        switch (addr) {
            0xff15 => {},
            0xff16 => {
                self.duty = v >> 6;
                self.length_counter.setLength(v & 0x3f);
            },
            0xff17 => {
                self.dac_enabled = (v & 0xf8) != 0;
                self.ch_enabled = self.isChannelEnabled();
                self.volume_envelope.setNr12(v);
            },
            0xff18 => {
                self.frequency = (self.frequency & 0x700) | @as(u32, v);
            },
            0xff19 => {
                self.frequency = (self.frequency & 0xff) | (@as(u32, v & 0b111) << 8);
                self.length_counter.setNr14(v);

                if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
                    self.ch_enabled = false;
                } else if ((v & 0x80) != 0) {
                    self.trigger();
                }
            },
            else => {},
        }
    }

    fn tick(self: *Channel2) void {
        self.timer = self.timer -| 1;
        if (self.timer == 0) {
            self.timer = (2048 - self.frequency) << 2;
            self.sequence = (self.sequence + 1) % 8;

            self.output = if (self.ch_enabled) blk: {
                break :blk if (DUTY_TABLE[self.duty][self.sequence] == 1)
                    self.volume_envelope.getVolume()
                else
                    0;
            } else 0;
        }
    }

    fn trigger(self: *Channel2) void {
        self.timer = (2048 - self.frequency) << 2;
        self.volume_envelope.trigger();
        self.ch_enabled = self.dac_enabled;
    }

    fn powerOff(self: *Channel2) void {
        self.volume_envelope.powerOff();
        self.length_counter.powerOff();
        self.ch_enabled = false;
        self.dac_enabled = false;
        self.sequence = 0;
        self.frequency = 0;
        self.duty = 0;
    }
};

// ─── Channel 3 (Wave) ───────────────────────────────────────────────────────
const Channel3 = struct {
    ch_enabled: bool = false,
    dac_enabled: bool = false,
    output: u8 = 0,
    length_counter: LengthCounter = .{ .full_length = 255 },
    timer: u32 = 0,
    position: usize = 4,
    ticks_since_read: u32 = 0,
    frequency: u32 = 0,
    volume_code: u8 = 0,
    last_address: usize = 0,
    wave_table: [16]u8 = [_]u8{0} ** 16,

    fn isChannelEnabled(self: *const Channel3) bool {
        return self.dac_enabled and self.ch_enabled;
    }

    fn tickChannelLength(self: *Channel3) void {
        self.length_counter.tick();
        if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
            self.ch_enabled = false;
        }
    }

    fn readByte(self: *const Channel3, addr: u16) u8 {
        return switch (addr) {
            0xff30...0xff3f => blk: {
                if (self.isChannelEnabled()) {
                    break :blk if (self.ticks_since_read < 2) self.wave_table[self.last_address] else 0xff;
                }
                break :blk self.wave_table[addr - 0xff30];
            },
            0xff1a => 0x7f | (if (self.dac_enabled) @as(u8, 0x80) else 0),
            0xff1b => 0xff,
            0xff1c => (self.volume_code << 5) | 0x9f,
            0xff1d => 0xff,
            0xff1e => 0xbf | (if (self.length_counter.isEnabled()) @as(u8, 0x40) else 0),
            else => 0xff,
        };
    }

    fn writeByte(self: *Channel3, addr: u16, v: u8) void {
        switch (addr) {
            0xff30...0xff3f => {
                if (self.isChannelEnabled()) {
                    if (self.ticks_since_read < 2) {
                        self.wave_table[self.last_address] = v;
                    }
                } else {
                    self.wave_table[addr - 0xff30] = v;
                }
            },
            0xff1a => {
                self.dac_enabled = (v & 0x80) != 0;
                self.ch_enabled = self.isChannelEnabled();
            },
            0xff1b => self.length_counter.setLength(v),
            0xff1c => self.volume_code = (v >> 5) & 0b11,
            0xff1d => self.frequency = (self.frequency & 0x700) | @as(u32, v),
            0xff1e => {
                self.length_counter.setNr14(v);
                self.frequency = (self.frequency & 0xff) | (@as(u32, v & 0b111) << 8);

                if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
                    self.ch_enabled = false;
                } else if ((v & 0x80) != 0) {
                    self.trigger();
                }
            },
            else => {},
        }
    }

    fn tick(self: *Channel3) void {
        self.ticks_since_read += 1;
        self.timer = self.timer -| 1;

        if (self.timer == 0) {
            self.timer = (2048 - self.frequency) << 1;

            if (self.isChannelEnabled()) {
                self.ticks_since_read = 0;
                self.last_address = self.position >> 1;
                self.output = self.wave_table[self.last_address];

                if ((self.position & 1) != 0) {
                    self.output &= 0x0f;
                } else {
                    self.output >>= 4;
                }

                if (self.volume_code > 0) {
                    self.output >>= @intCast(self.volume_code - 1);
                } else {
                    self.output = 0;
                }

                self.position = (self.position + 1) & 31;
            } else {
                self.output = 0;
            }
        }
    }

    fn trigger(self: *Channel3) void {
        if (self.isChannelEnabled() and self.timer == 2) {
            var pos = self.position >> 1;
            if (pos < 4) {
                self.wave_table[0] = self.wave_table[pos];
            } else {
                pos &= ~@as(usize, 0b11);
                const src_end = @min(pos + 4, 16);
                const copy_len = src_end - pos;
                @memcpy(self.wave_table[0..copy_len], self.wave_table[pos..src_end]);
            }
        }

        self.timer = 6;
        self.position = 0;
        self.last_address = 0;
        self.ch_enabled = self.dac_enabled;
    }

    fn powerOff(self: *Channel3) void {
        self.length_counter.powerOff();
        self.ch_enabled = false;
        self.dac_enabled = false;
        self.position = 0;
        self.frequency = 0;
        self.volume_code = 0;
        self.ticks_since_read = 0;
        self.last_address = 0;
    }
};

// ─── Channel 4 (Noise) ──────────────────────────────────────────────────────
const DIVISORS: [8]u8 = .{ 8, 16, 32, 48, 64, 80, 96, 112 };

const Channel4 = struct {
    ch_enabled: bool = false,
    dac_enabled: bool = false,
    output: u8 = 0,
    length_counter: LengthCounter = .{},
    timer: u32 = 0,
    clock_shift: u8 = 0,
    width_mode: bool = false,
    divisor_code: u8 = 0,
    lfsr: u16 = 0x7fff,
    volume_envelope: VolumeEnvelope = .{},

    fn isChannelEnabled(self: *const Channel4) bool {
        return self.dac_enabled and self.ch_enabled;
    }

    fn tickChannelLength(self: *Channel4) void {
        self.length_counter.tick();
        if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
            self.ch_enabled = false;
        }
    }

    fn readByte(self: *const Channel4, addr: u16) u8 {
        return switch (addr) {
            0xff1f => 0xff,
            0xff20 => 0xff,
            0xff21 => self.volume_envelope.getNr12(),
            0xff22 => (self.clock_shift << 4) | (if (self.width_mode) @as(u8, 0x08) else 0) | self.divisor_code,
            0xff23 => 0xbf | (if (self.length_counter.isEnabled()) @as(u8, 0x40) else 0),
            else => 0xff,
        };
    }

    fn writeByte(self: *Channel4, addr: u16, v: u8) void {
        switch (addr) {
            0xff1f => {},
            0xff20 => self.length_counter.setLength(v & 0x3f),
            0xff21 => {
                self.dac_enabled = (v & 0xf8) != 0;
                self.ch_enabled = self.isChannelEnabled();
                self.volume_envelope.setNr12(v);
            },
            0xff22 => {
                self.clock_shift = v >> 4;
                self.width_mode = (v & 0x08) != 0;
                self.divisor_code = v & 0b111;
            },
            0xff23 => {
                self.length_counter.setNr14(v);
                if (self.length_counter.isEnabled() and self.length_counter.isZero()) {
                    self.ch_enabled = false;
                } else if ((v & 0x80) != 0) {
                    self.trigger();
                }
            },
            else => {},
        }
    }

    fn tick(self: *Channel4) void {
        self.timer = self.timer -| 1;
        if (self.timer == 0) {
            self.timer = @as(u32, DIVISORS[self.divisor_code]) << @intCast(self.clock_shift);

            const result: bool = ((self.lfsr & 1) ^ ((self.lfsr >> 1) & 1)) != 0;
            self.lfsr >>= 1;
            self.lfsr |= if (result) @as(u16, 1) << 14 else 0;

            if (self.width_mode) {
                self.lfsr &= ~@as(u16, 0x40);
                self.lfsr |= if (result) 0x40 else 0;
            }

            self.output = if (self.isChannelEnabled() and (self.lfsr & 1) == 0)
                self.volume_envelope.getVolume()
            else
                0;
        }
    }

    fn trigger(self: *Channel4) void {
        self.volume_envelope.trigger();
        self.timer = @as(u32, DIVISORS[self.divisor_code]) << @intCast(self.clock_shift);
        self.lfsr = 0x7fff;
        self.ch_enabled = self.dac_enabled;
    }

    fn powerOff(self: *Channel4) void {
        self.volume_envelope.powerOff();
        self.length_counter.powerOff();
        self.ch_enabled = false;
        self.dac_enabled = false;
        self.clock_shift = 0;
        self.width_mode = false;
        self.divisor_code = 0;
    }
};

// ─── Channel Enabled Flags ──────────────────────────────────────────────────
const ChannelEnabled = packed struct(u8) {
    right_4: bool = false,
    right_3: bool = false,
    right_2: bool = false,
    right_1: bool = false,
    left_4: bool = false,
    left_3: bool = false,
    left_2: bool = false,
    left_1: bool = false,
};

// ─── High-pass filter ───────────────────────────────────────────────────────
const HP_FILTER_ALPHA: f32 = 0.995;

// ─── APU ─────────────────────────────────────────────────────────────────────
pub const APU = struct {
    master_volume: f32 = 0.1,
    enabled: bool = false,

    vin_left_enable: bool = false,
    vin_right_enable: bool = false,
    left_volume: u8 = 0,
    right_volume: u8 = 0,

    channel_enabled: ChannelEnabled = .{},

    frame_sequencer_counter: u32 = 8192,
    frame_sequencer: u8 = 0,

    channel1: Channel1 = .{},
    channel2: Channel2 = .{},
    channel3: Channel3 = .{},
    channel4: Channel4 = .{},

    // Sampler state
    sample_clock: u32 = 0,
    cycles_per_sample: f32 = 4194304.0 / 44100.0,
    sample_counter: f32 = 0,
    ring_buffer: RingBuffer = .{},
    samples_produced: u64 = 0,

    // High-pass filter state
    prev_input: f32 = 0,
    prev_output: f32 = 0,

    pub fn setSampleRate(self: *APU, rate: u32) void {
        self.cycles_per_sample = 4194304.0 / @as(f32, @floatFromInt(rate));
    }

    pub fn tick(self: *APU) void {
        if (!self.enabled) return;

        self.frame_sequencer_counter -|= 1;

        if (self.frame_sequencer_counter == 0) {
            self.frame_sequencer_counter = 8192;

            switch (self.frame_sequencer) {
                0 => self.tickAllChannelLengths(),
                2 => {
                    self.channel1.frequency_sweep.tick();
                    self.tickAllChannelLengths();
                },
                4 => self.tickAllChannelLengths(),
                6 => {
                    self.channel1.tickFrequencySweep();
                    self.tickAllChannelLengths();
                },
                7 => {
                    self.channel1.volume_envelope.tick();
                    self.channel2.volume_envelope.tick();
                    self.channel4.volume_envelope.tick();
                },
                else => {},
            }

            self.frame_sequencer = (self.frame_sequencer + 1) & 7;
            self.channel1.length_counter.frame_sequencer = self.frame_sequencer;
            self.channel2.length_counter.frame_sequencer = self.frame_sequencer;
        }

        self.channel1.tick();
        self.channel2.tick();
        self.channel3.tick();
        self.channel4.tick();

        // Downsample to output
        self.sample_counter += 1;
        if (self.sample_counter >= self.cycles_per_sample) {
            self.sample_counter -= self.cycles_per_sample;
            const raw = self.sample();

            // High-pass filter
            const filtered = raw - self.prev_input + HP_FILTER_ALPHA * self.prev_output;
            self.prev_input = raw;
            self.prev_output = filtered;

            const clamped = std.math.clamp(filtered, -1.0, 1.0);
            self.ring_buffer.push(clamped);
            self.samples_produced += 1;
        }
    }

    fn sample(self: *const APU) f32 {
        var mixed: f32 = 0;

        if (self.channel_enabled.left_1) mixed += @floatFromInt(self.channel1.output);
        if (self.channel_enabled.left_2) mixed += @floatFromInt(self.channel2.output);
        if (self.channel_enabled.left_3) mixed += @floatFromInt(self.channel3.output);
        if (self.channel_enabled.left_4) mixed += @floatFromInt(self.channel4.output);
        if (self.channel_enabled.right_1) mixed += @floatFromInt(self.channel1.output);
        if (self.channel_enabled.right_2) mixed += @floatFromInt(self.channel2.output);
        if (self.channel_enabled.right_3) mixed += @floatFromInt(self.channel3.output);
        if (self.channel_enabled.right_4) mixed += @floatFromInt(self.channel4.output);

        return (mixed / 16.0) * self.master_volume;
    }

    fn tickAllChannelLengths(self: *APU) void {
        self.channel1.tickChannelLength();
        self.channel2.tickChannelLength();
        self.channel3.tickChannelLength();
        self.channel4.tickChannelLength();
    }

    fn clearAllRegisters(self: *APU) void {
        self.vin_left_enable = false;
        self.vin_right_enable = false;
        self.left_volume = 0;
        self.right_volume = 0;
        self.enabled = false;
        self.channel1.powerOff();
        self.channel2.powerOff();
        self.channel3.powerOff();
        self.channel4.powerOff();
        self.channel_enabled = .{};
    }

    pub fn readByte(self: *const APU, addr: u16) u8 {
        return switch (addr) {
            0xff10...0xff14 => self.channel1.readByte(addr),
            0xff15...0xff19 => self.channel2.readByte(addr),
            0xff1a...0xff1e => self.channel3.readByte(addr),
            0xff1f...0xff23 => self.channel4.readByte(addr),
            0xff24 => blk: {
                var v: u8 = 0;
                if (self.vin_left_enable) v |= 0x80;
                v |= self.left_volume << 4;
                if (self.vin_right_enable) v |= 0x08;
                v |= self.right_volume;
                break :blk v;
            },
            0xff25 => @bitCast(self.channel_enabled),
            0xff26 => blk: {
                var v: u8 = 0x70;
                if (self.enabled) v |= 0x80;
                if (self.channel1.ch_enabled) v |= 0x01;
                if (self.channel2.ch_enabled) v |= 0x02;
                if (self.channel3.ch_enabled) v |= 0x04;
                if (self.channel4.ch_enabled) v |= 0x08;
                break :blk v;
            },
            0xff27...0xff2f => 0xff,
            0xff30...0xff3f => self.channel3.readByte(addr),
            else => 0xff,
        };
    }

    pub fn writeByte(self: *APU, addr: u16, v: u8) void {
        switch (addr) {
            0xff26 => {
                const enable_apu = (v & 0x80) != 0;
                if (self.enabled and !enable_apu) {
                    self.clearAllRegisters();
                } else if (!self.enabled and enable_apu) {
                    self.frame_sequencer = 0;
                }
                self.enabled = enable_apu;
            },
            0xff30...0xff3f => self.channel3.writeByte(addr, v),
            0xff10...0xff14 => self.channel1.writeByte(addr, v),
            0xff15...0xff19 => self.channel2.writeByte(addr, v),
            0xff1a...0xff1e => self.channel3.writeByte(addr, v),
            0xff1f...0xff23 => self.channel4.writeByte(addr, v),
            0xff27...0xff2f => {},
            0xff24 => {
                self.right_volume = v & 0b111;
                self.vin_right_enable = (v & 0x08) != 0;
                self.left_volume = (v >> 4) & 0b111;
                self.vin_left_enable = (v & 0x80) != 0;
            },
            0xff25 => self.channel_enabled = @bitCast(v),
            else => {},
        }
    }
};
