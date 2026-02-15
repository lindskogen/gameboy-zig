const std = @import("std");
const glfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const gl = @cImport({
    @cInclude("glad/gl.h");
});
const ma = struct {
    const Device = opaque {};
    const DeviceConfig = extern struct { data: [512]u8 };
    const AudioCallback = *const fn (?*anyopaque, ?*anyopaque, ?*const anyopaque, u32) callconv(.c) void;

    extern "c" fn zig_ma_device_config_playback(sample_rate: u32, callback: AudioCallback, user_data: ?*anyopaque) DeviceConfig;
    extern "c" fn zig_ma_device_init(config: *const DeviceConfig) ?*Device;
    extern "c" fn zig_ma_device_start(device: *Device) void;
    extern "c" fn zig_ma_device_uninit(device: *Device) void;
    extern "c" fn zig_ma_device_get_sample_rate(device: *Device) u32;
};

const builtin = @import("builtin");
const Bus = @import("bus.zig").Bus;
const JoypadInput = @import("bus.zig").JoypadInput;
const CPU = @import("cpu.zig").CPU;
const APU = @import("apu.zig").APU;
const Renderer = @import("renderer.zig").Renderer;

const macos_icon = if (builtin.os.tag == .macos) struct {
    extern "c" fn setDockIcon(data: [*]const u8, len: c_ulong) void;
} else struct {};

const icon_png = @embedFile("icon.png");

const SCALE: comptime_int = 4;
const WIDTH: comptime_int = 160;
const HEIGHT: comptime_int = 144;
const SAMPLE_RATE: u32 = 44100;

fn audioCallback(_: ?*anyopaque, output: ?*anyopaque, _: ?*const anyopaque, frame_count: u32) callconv(.c) void {
    const apu: *APU = @ptrCast(@alignCast(audio_apu_ptr));
    const out: [*]f32 = @ptrCast(@alignCast(output.?));
    for (0..frame_count) |i| {
        out[i] = apu.ring_buffer.pop() orelse 0.0;
    }
}

var audio_apu_ptr: ?*anyopaque = null;

const gc = if (builtin.os.tag == .macos) struct {
    const GamepadState = extern struct {
        a: c_int = 0,
        b: c_int = 0,
        x: c_int = 0,
        y: c_int = 0,
        start: c_int = 0,
        select: c_int = 0,
        dpad_up: c_int = 0,
        dpad_down: c_int = 0,
        dpad_left: c_int = 0,
        dpad_right: c_int = 0,
        l_shoulder: c_int = 0,
        r_shoulder: c_int = 0,
        left_x: f32 = 0,
        left_y: f32 = 0,
        connected: c_int = 0,
    };
    extern "c" fn pollMacOSGamepad(state: *GamepadState) void;
    extern "c" fn getControllerName() ?[*:0]const u8;
} else struct {};

var gamepad_logged: bool = false;

fn pollGamepad(input: *JoypadInput) void {
    if (builtin.os.tag == .macos) {
        // Use native Game Controller framework on macOS
        // (GLFW's joystick backend can't read Bluetooth controller buttons)
        var state = gc.GamepadState{};
        gc.pollMacOSGamepad(&state);
        if (state.connected == 0) return;

        if (!gamepad_logged) {
            gamepad_logged = true;
            if (gc.getControllerName()) |name_ptr| {
                const name = std.mem.span(name_ptr);
                std.debug.print("Controller connected: {s}\n", .{name});
            }
        }

        if (state.a != 0) input.a = true;
        if (state.b != 0) input.b = true;
        if (state.x != 0) input.a = true;
        if (state.y != 0) input.b = true;
        if (state.start != 0) input.start = true;
        if (state.select != 0) input.select = true;
        if (state.dpad_up != 0) input.up = true;
        if (state.dpad_down != 0) input.down = true;
        if (state.dpad_left != 0) input.left = true;
        if (state.dpad_right != 0) input.right = true;

        // Left stick as D-Pad
        if (state.left_x < -0.5) input.left = true;
        if (state.left_x > 0.5) input.right = true;
        if (state.left_y < -0.5) input.down = true;
        if (state.left_y > 0.5) input.up = true;
    } else {
        // Non-macOS: use GLFW gamepad API
        var jid: c_int = glfw.GLFW_JOYSTICK_1;
        while (jid <= glfw.GLFW_JOYSTICK_LAST) : (jid += 1) {
            if (glfw.glfwJoystickPresent(jid) == 0) continue;
            if (glfw.glfwJoystickIsGamepad(jid) == 0) continue;

            var state: glfw.GLFWgamepadstate = undefined;
            if (glfw.glfwGetGamepadState(jid, &state) == 0) continue;

            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_A] != 0) input.a = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_B] != 0) input.b = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_X] != 0) input.a = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_Y] != 0) input.b = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_START] != 0) input.start = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_BACK] != 0) input.select = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_DPAD_UP] != 0) input.up = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_DPAD_DOWN] != 0) input.down = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_DPAD_LEFT] != 0) input.left = true;
            if (state.buttons[glfw.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT] != 0) input.right = true;
            return;
        }
    }
}

fn getStatePath(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.state", .{rom_path});
}

fn saveState(cpu: *CPU, bus: *Bus, rom_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state_path = try getStatePath(allocator, rom_path);
    const file = try std.fs.cwd().createFile(state_path, .{});
    defer file.close();

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(&write_buf);

    // Write header
    try writer.interface.writeAll("GBZS");
    try writer.interface.writeAll(&[_]u8{ 0x01, 0, 0, 0 }); // version + reserved

    // Write component blocks with size prefixes
    try writeComponent(&writer.interface, cpu);
    try writeComponent(&writer.interface, &bus.ppu);
    try writeComponent(&writer.interface, &bus.apu);
    try writeComponent(&writer.interface, bus);
    try writeComponent(&writer.interface, &bus.cartridge);

    try writer.interface.flush();
    std.debug.print("State saved to {s}\n", .{state_path});
}

fn loadState(cpu: *CPU, bus: *Bus, rom_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const state_path = try getStatePath(allocator, rom_path);
    const file = try std.fs.cwd().openFile(state_path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    var fbs = std.io.fixedBufferStream(file_data);
    const reader = fbs.reader();

    // Validate header
    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, "GBZS")) return error.InvalidMagic;

    var header: [4]u8 = undefined;
    try reader.readNoEof(&header);
    const version = header[0];
    if (version != 0x01) return error.UnsupportedVersion;

    // Read component blocks
    try readComponent(reader, cpu);
    try readComponent(reader, &bus.ppu);
    try readComponent(reader, &bus.apu);
    try readComponent(reader, bus);
    try readComponent(reader, &bus.cartridge);

    std.debug.print("State loaded from {s}\n", .{state_path});
}

fn writeComponent(writer: anytype, component: anytype) !void {
    var count_buf: [100 * 1024]u8 = undefined;
    var count_stream = std.io.fixedBufferStream(&count_buf);
    var count_writer = count_stream.writer();

    try component.serialize(&count_writer);
    const size: u32 = @intCast(count_stream.pos);

    // Write size (as 4 bytes)
    const size_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, size));
    try writer.writeAll(&size_bytes);

    // Write component data
    try component.serialize(writer);
}

fn readComponent(reader: anytype, component: anytype) !void {
    var size_bytes: [4]u8 = undefined;
    try reader.readNoEof(&size_bytes);
    const size = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, &size_bytes));
    _ = size; // Could validate if needed
    try component.deserialize(reader);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Headless screenshot mode
    if (args.len > 2 and std.mem.eql(u8, args[1], "screenshot")) {
        const rom_name = args[2];
        const num_frames: u32 = if (args.len > 3) std.fmt.parseInt(u32, args[3], 10) catch 120 else 120;
        try runScreenshot(allocator, rom_name, num_frames);
        return;
    }

    // Headless Mooneye test runner mode
    if (args.len > 2 and std.mem.eql(u8, args[1], "mooneye")) {
        const rom_name = args[2];
        const pass = runMooneye(rom_name);
        std.process.exit(if (pass) 0 else 1);
    }

    // Headless WAV capture mode
    if (args.len > 2 and std.mem.eql(u8, args[1], "wav")) {
        const rom_name = args[2];
        const num_frames: u32 = if (args.len > 3) std.fmt.parseInt(u32, args[3], 10) catch 300 else 300;
        try runWavCapture(allocator, rom_name, num_frames);
        return;
    }

    const rom_name: []const u8 = if (args.len > 1) args[1] else {
        std.debug.print("Usage: gameboy_zig <rom.gb>\n", .{});
        return;
    };

    // Load ROM
    var rom_buffer: [1024 * 1024]u8 = undefined; // 1MB max
    const rom_data = try std.fs.cwd().readFile(rom_name, &rom_buffer);

    // Try loading boot ROM
    var boot_rom_buf: [256]u8 = undefined;
    const boot_rom: ?[]const u8 = std.fs.cwd().readFile("dmg_boot.bin", &boot_rom_buf) catch null;

    std.debug.print("Loaded {s} ({d} bytes)\n", .{ rom_name, rom_data.len });

    // Read ROM title
    var title_str: [16]u8 = undefined;
    var title_len: usize = 0;
    if (rom_data.len > 0x143) {
        for (0x134..0x143) |i| {
            if (rom_data[i] == 0) break;
            title_str[title_len] = rom_data[i];
            title_len += 1;
        }
    }
    const rom_title = title_str[0..title_len];
    std.debug.print("ROM title: {s}\n", .{rom_title});

    // Initialize emulator
    var bus = Bus.initWithRom(rom_data, boot_rom);
    var cpu = CPU{};
    cpu.bus = &bus;

    // Load battery-backed save data
    bus.cartridge.loadSav(rom_name);

    if (boot_rom == null) {
        cpu.skipBootRom();
    }

    // --- GLFW + OpenGL init ---
    if (glfw.glfwInit() == 0) {
        std.debug.print("Failed to initialize GLFW\n", .{});
        return;
    }
    defer glfw.glfwTerminate();

    // Set macOS dock icon
    if (builtin.os.tag == .macos) {
        macos_icon.setDockIcon(icon_png.ptr, icon_png.len);
    }

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, 1);

    var window_title_buf: [64]u8 = undefined;
    const window_title = std.fmt.bufPrintZ(&window_title_buf, "gameboy-zig - {s}", .{rom_title}) catch "gameboy-zig";

    const window = glfw.glfwCreateWindow(WIDTH * SCALE, HEIGHT * SCALE, window_title.ptr, null, null) orelse {
        std.debug.print("Failed to create GLFW window\n", .{});
        return;
    };
    defer glfw.glfwDestroyWindow(window);

    glfw.glfwMakeContextCurrent(window);

    if (gl.gladLoadGL(@ptrCast(&glfw.glfwGetProcAddress)) == 0) {
        std.debug.print("Failed to load OpenGL functions\n", .{});
        return;
    }

    var fb_width: c_int = 0;
    var fb_height: c_int = 0;
    glfw.glfwGetFramebufferSize(window, &fb_width, &fb_height);
    gl.glViewport(0, 0, fb_width, fb_height);
    gl.glClearColor(0.0, 0.0, 0.0, 1.0);

    glfw.glfwSwapInterval(0);

    var renderer = Renderer.init(@intCast(fb_width), @intCast(fb_height));
    defer renderer.deinit();

    // Init audio
    audio_apu_ptr = @ptrCast(&bus.apu);
    const audio_config = ma.zig_ma_device_config_playback(SAMPLE_RATE, audioCallback, null);
    const audio_device = ma.zig_ma_device_init(&audio_config);
    if (audio_device) |dev| {
        const actual_rate = ma.zig_ma_device_get_sample_rate(dev);
        if (actual_rate != SAMPLE_RATE) {
            std.debug.print("Audio: requested {d}Hz, device using {d}Hz\n", .{ SAMPLE_RATE, actual_rate });
        }
        bus.apu.setSampleRate(actual_rate);
        ma.zig_ma_device_start(dev);
    }
    defer {
        if (audio_device) |dev| ma.zig_ma_device_uninit(dev);
    }

    var fps_frame_count: u32 = 0;
    var fps_timer: i64 = std.time.milliTimestamp();
    var emu_time_acc: i64 = 0;
    var title_buf: [96]u8 = undefined;
    var prev_crt_key: bool = false;
    var prev_save_key: bool = false;
    var prev_load_key: bool = false;
    var next_frame: f64 = @floatFromInt(std.time.milliTimestamp());
    // Game Boy: ~59.7275 Hz
    const frame_duration: f64 = 1000.0 / 59.7275;

    while (glfw.glfwWindowShouldClose(window) == 0) {
        glfw.glfwPollEvents();

        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_ESCAPE) == glfw.GLFW_PRESS) break;

        // CRT toggle
        const crt_key = glfw.glfwGetKey(window, glfw.GLFW_KEY_C) == glfw.GLFW_PRESS;
        if (crt_key and !prev_crt_key) {
            renderer.toggleCrt();
            bus.ppu.dmg_colors = renderer.crt_enabled;
        }
        prev_crt_key = crt_key;

        // Save state (F5)
        const save_key = glfw.glfwGetKey(window, glfw.GLFW_KEY_F5) == glfw.GLFW_PRESS;
        if (save_key and !prev_save_key) {
            saveState(&cpu, &bus, rom_name) catch |err| {
                std.debug.print("Save state failed: {}\n", .{err});
            };
        }
        prev_save_key = save_key;

        // Load state (F9)
        const load_key = glfw.glfwGetKey(window, glfw.GLFW_KEY_F9) == glfw.GLFW_PRESS;
        if (load_key and !prev_load_key) {
            loadState(&cpu, &bus, rom_name) catch |err| {
                std.debug.print("Load state failed: {}\n", .{err});
            };
        }
        prev_load_key = load_key;

        // Update joypad
        var input = JoypadInput{};
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_Z) == glfw.GLFW_PRESS) input.a = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_X) == glfw.GLFW_PRESS) input.b = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_LEFT_SHIFT) == glfw.GLFW_PRESS or
            glfw.glfwGetKey(window, glfw.GLFW_KEY_RIGHT_SHIFT) == glfw.GLFW_PRESS) input.select = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_ENTER) == glfw.GLFW_PRESS) input.start = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_UP) == glfw.GLFW_PRESS) input.up = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_DOWN) == glfw.GLFW_PRESS) input.down = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_LEFT) == glfw.GLFW_PRESS) input.left = true;
        if (glfw.glfwGetKey(window, glfw.GLFW_KEY_RIGHT) == glfw.GLFW_PRESS) input.right = true;

        // Poll gamepad (adds to keyboard input)
        pollGamepad(&input);

        bus.input.update(input);

        const emu_start = std.time.milliTimestamp();

        // Run one frame
        var frame_done = false;
        while (!frame_done) {
            const elapsed = cpu.next();
            const should_render = bus.ppu.next(elapsed);
            for (0..elapsed) |_| {
                bus.apu.tick();
            }
            if (should_render) frame_done = true;
        }

        emu_time_acc += std.time.milliTimestamp() - emu_start;

        renderer.uploadFrame(&bus.ppu.frame_buffer);
        renderer.draw();
        glfw.glfwSwapBuffers(window);

        fps_frame_count += 1;
        if (fps_frame_count >= 60) {
            const elapsed_ms = std.time.milliTimestamp() - fps_timer;
            if (elapsed_ms > 0) {
                const emu_speed: u32 = if (emu_time_acc > 0)
                    @intFromFloat(998.4 / @as(f64, @floatFromInt(emu_time_acc)) * 100.0)
                else
                    9999;

                const title_slice = std.fmt.bufPrintZ(&title_buf, "gameboy-zig - {s} (emu: {d}%)", .{ rom_title, emu_speed }) catch "gameboy-zig";
                glfw.glfwSetWindowTitle(window, title_slice.ptr);
            }
            fps_frame_count = 0;
            fps_timer = std.time.milliTimestamp();
            emu_time_acc = 0;
        }

        // Sleep to match frame rate
        next_frame += frame_duration;
        const now: i64 = std.time.milliTimestamp();
        const sleep_ms: i64 = @as(i64, @intFromFloat(next_frame)) - now;
        if (sleep_ms > 0) {
            std.Thread.sleep(@intCast(sleep_ms * std.time.ns_per_ms));
        } else if (sleep_ms < -100) {
            next_frame = @floatFromInt(now);
        }
    }

    // Save battery-backed RAM on exit
    bus.cartridge.saveSav(rom_name);
}

fn runScreenshot(allocator: std.mem.Allocator, rom_name: []const u8, num_frames: u32) !void {
    _ = allocator;
    var rom_buffer: [1024 * 1024]u8 = undefined;
    const rom_data = try std.fs.cwd().readFile(rom_name, &rom_buffer);

    var bus = Bus.initWithRom(rom_data, null);
    var cpu = CPU{};
    cpu.bus = &bus;
    cpu.skipBootRom();

    var frames: u32 = 0;
    while (frames < num_frames) {
        const elapsed = cpu.next();
        if (bus.ppu.next(elapsed)) {
            frames += 1;
        }
        for (0..elapsed) |_| {
            bus.apu.tick();
        }
    }

    const file = try std.fs.cwd().createFile("framebuffer.ppm", .{});
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(&write_buf);
    try writer.interface.print("P3\n{d} {d}\n255\n", .{ WIDTH, HEIGHT });
    for (0..HEIGHT) |y| {
        for (0..WIDTH) |x| {
            const color = bus.ppu.frame_buffer[y * WIDTH + x];
            const r = (color >> 16) & 0xFF;
            const g = (color >> 8) & 0xFF;
            const b = color & 0xFF;
            try writer.interface.print("{d} {d} {d}\n", .{ r, g, b });
        }
    }
    try writer.interface.flush();
    std.debug.print("Screenshot saved to framebuffer.ppm ({d} frames)\n", .{frames});
}

fn runWavCapture(allocator: std.mem.Allocator, rom_name: []const u8, num_frames: u32) !void {
    var rom_buffer: [1024 * 1024]u8 = undefined;
    const rom_data = try std.fs.cwd().readFile(rom_name, &rom_buffer);

    var bus = Bus.initWithRom(rom_data, null);
    var cpu = CPU{};
    cpu.bus = &bus;
    cpu.skipBootRom();

    const estimated_samples = @as(usize, SAMPLE_RATE) * num_frames / 60 + 44100;
    var samples = try std.ArrayList(f32).initCapacity(allocator, estimated_samples);
    defer samples.deinit(allocator);

    var frames: u32 = 0;
    while (frames < num_frames) {
        const elapsed = cpu.next();
        if (bus.ppu.next(elapsed)) {
            frames += 1;
        }
        for (0..elapsed) |_| {
            bus.apu.tick();
            while (bus.apu.ring_buffer.pop()) |s| {
                samples.append(allocator, s) catch break;
            }
        }
    }

    const wav_file = try std.fs.cwd().createFile("output.wav", .{});
    defer wav_file.close();
    var wav_buf: [4096]u8 = undefined;
    var w = wav_file.writer(&wav_buf);

    const num_samples: u32 = @intCast(samples.items.len);
    const data_size: u32 = num_samples * 2;
    const file_size: u32 = 36 + data_size;

    try w.interface.writeAll("RIFF");
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, file_size)));
    try w.interface.writeAll("WAVE");
    try w.interface.writeAll("fmt ");
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, 16)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, 1)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, 1)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, SAMPLE_RATE)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, SAMPLE_RATE * 2)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, 2)));
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, 16)));
    try w.interface.writeAll("data");
    try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, data_size)));

    for (samples.items) |sample| {
        const clamped = std.math.clamp(sample, -1.0, 1.0);
        const int_sample: i16 = @intFromFloat(clamped * 32767.0);
        try w.interface.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(i16, int_sample)));
    }
    try w.interface.flush();

    std.debug.print("WAV saved to output.wav ({d} frames, {d} samples)\n", .{ frames, num_samples });
}

fn runMooneye(rom_name: []const u8) bool {
    var rom_buffer: [1024 * 1024]u8 = undefined;
    const rom_data = std.fs.cwd().readFile(rom_name, &rom_buffer) catch |err| {
        std.debug.print("Failed to load ROM: {}\n", .{err});
        return false;
    };

    var bus = Bus.initWithRom(rom_data, null);
    var cpu = CPU{};
    cpu.bus = &bus;
    cpu.skipBootRom();

    // Run until LD B,B breakpoint or timeout (~7200 frames ≈ 120s emulated)
    const max_frames: u32 = 7200;
    var frames: u32 = 0;
    while (frames < max_frames) {
        const elapsed = cpu.next();
        if (bus.ppu.next(elapsed)) {
            frames += 1;
        }
        for (0..elapsed) |_| {
            bus.apu.tick();
        }
        if (cpu.halted_at_breakpoint) break;
    }

    // Extract test name from ROM path
    const test_name = extractTestName(rom_name);

    // Check Fibonacci sequence: B=3, C=5, D=8, E=13, H=21, L=34
    const pass = cpu.b == 3 and cpu.c == 5 and cpu.d == 8 and cpu.e == 13 and cpu.h == 21 and cpu.l == 34;

    if (pass) {
        std.debug.print("PASS: {s}\n", .{test_name});
    } else if (!cpu.halted_at_breakpoint) {
        std.debug.print("FAIL: {s} (timeout after {d} frames)\n", .{ test_name, max_frames });
    } else {
        std.debug.print("FAIL: {s} (B={X:0>2} C={X:0>2} D={X:0>2} E={X:0>2} H={X:0>2} L={X:0>2})\n", .{ test_name, cpu.b, cpu.c, cpu.d, cpu.e, cpu.h, cpu.l });
    }

    // Print serial output if any
    if (bus.serial.log_len > 0) {
        std.debug.print("Serial: {s}\n", .{bus.serial.log[0..bus.serial.log_len]});
    }

    return pass;
}

fn extractTestName(path: []const u8) []const u8 {
    // Try to extract path after "acceptance/"
    if (std.mem.indexOf(u8, path, "acceptance/")) |idx| {
        const after = path[idx + "acceptance/".len ..];
        // Strip .gb extension
        if (std.mem.endsWith(u8, after, ".gb")) {
            return after[0 .. after.len - 3];
        }
        return after;
    }
    // Fallback: just the filename without extension
    const base = if (std.mem.lastIndexOf(u8, path, "/")) |idx| path[idx + 1 ..] else path;
    if (std.mem.endsWith(u8, base, ".gb")) {
        return base[0 .. base.len - 3];
    }
    return base;
}
