# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build                                    # Compile
zig build run -- <rom.gb>                    # Run in windowed mode
zig build run -- screenshot <rom.gb> <frames> # Headless PPM screenshot
zig build run -- wav <rom.gb> <frames>       # Headless WAV audio capture
sips -s format png screenshot.ppm --out screenshot.png  # Convert PPM to PNG (macOS)
```

Test ROMs are available in `game-boy-test-roms-v7.0/`. Commercial ROMs: `tetris.gb`, `mario.gb`, `zelda.gb`.

## Architecture

Game Boy DMG emulator.

**Core loop**: CPU executes one instruction → returns cycle count → PPU and APU advance by that many cycles → repeat until PPU signals VBlank → render frame.

**Component hierarchy**:
- **CPU** (`cpu.zig`): LR35902 processor. Instruction dispatch via comptime-generated `opcode_table`. Heavy use of comptime templates (`ld_rr`, `rmw_reg`, etc.) to reduce duplication across similar opcodes.
- **Bus** (`bus.zig`): Central memory router. Owns all other components. Maps addresses to the correct component (cartridge, PPU, APU, WRAM, etc.). Also handles joypad input and DMA transfers.
- **PPU** (`ppu.zig`): Mode-based state machine (OAM→Transfer→HBlank→VBlank). Renders one scanline at end of Mode 3. Also manages timer registers (DIV/TIMA) and interrupt flags (IF). Outputs 160x144 BGRA8888 framebuffer.
- **APU** (`apu.zig`): 4-channel synthesis (2 square, 1 wavetable, 1 noise). Frame sequencer at 512 Hz. Downsamples to 44.1 kHz. Lock-free ring buffer feeds audio callback on separate thread.
- **Cartridge** (`cartridge.zig`): ROM/RAM banking with MBC1 support. Battery-backed `.sav` files.
- **Renderer** (`renderer.zig`): OpenGL 3.3 with CRT shader effect (toggleable). Uses GLFW for windowing.

**Key data flow**: CPU ↔ Bus ↔ {Cartridge, PPU, APU}. Interrupts: PPU sets IF flags → CPU checks IF & IE at start of `next()`.

## Critical Implementation Details

- **EI (0xFB) delayed enable**: Most opcodes `return` cycle count from the switch, bypassing post-switch code. The `ei_pending` → `IME=true` conversion must happen at the START of the next `next()` call.
- **Interrupt dispatch**: `interruptAddress()` must check `IF & IE`, not just `IF`.
- **Scroll register latching**: SCX/SCY are latched once per frame at end of VBlank and used for the entire frame (games like Link's Awakening update them during VBlank).
- **PPU Mode 3 duration**: Varies with `SCX % 8` for accurate horizontal scroll timing.
- **STAT interrupt**: Uses rising-edge detection via `stat_line` boolean.

## Zig Patterns Used

Always prefer idiomatic Zig patterns. Use `std.mem` functions (`readInt`, `writeInt`, `asBytes`, `sliceAsBytes`, `toBytes`) over manual byte manipulation. Use `extern struct` with comptime size assertions for binary format layouts. Use `@bitCast`, `@intFromBool`, packed structs, and comptime features where they reduce boilerplate.

- **Packed structs** for hardware registers (Flags, InterruptFlags, JoypadInput) — enables direct `@bitCast` with hardware values.
- **Extern structs** for binary format layouts (BESS save state) — with `comptime` size assertions.
- **Comptime metaprogramming** for CPU instruction table — `Reg` enum + template functions generate all register-to-register operation handlers at compile time.
- **Minimal allocation** — fixed-size arrays throughout, `page_allocator` only for CLI args.
- **Zig 0.15 writer interface** — `file.writer(&buf)` returns a buffered writer; the actual writer methods are on `.interface` (e.g. `writer.interface.writeAll(...)`, `writer.interface.flush()`).

## Mooneye Test Suite

Tests are in `game-boy-test-roms-v7.0/mooneye-test-suite/acceptance/`. Only tests applicable to DMG are listed (skipping `-S`, `-sgb`, `-sgb2`, `-dmg0`, `-mgb` variants).

**How to run**: Use headless screenshot mode with enough frames for the test to complete (300 is usually sufficient, some may need more):
```bash
zig build run -- screenshot game-boy-test-roms-v7.0/mooneye-test-suite/acceptance/<test>.gb 300
sips -s format png framebuffer.ppm --out framebuffer.png
```

**How to verify**: The serial port outputs test results to stderr. Mooneye tests send 6 bytes via link cable: `3, 5, 8, 13, 21, 34` (Fibonacci) = pass, or `0x42` x6 = fail. The screen also displays "Test OK", or assertion results with `OK`/`!` markers, or explicit "Test failed"/"FAIL:" messages.

**Passing tests** (18/66):
- `bits/mem_oam`, `bits/reg_f`
- `boot_regs-dmgABC`
- `di_timing-GS`, `div_timing`
- `halt_ime0_ei`, `halt_ime0_nointr_timing`, `halt_ime1_timing`, `halt_ime1_timing2-GS`
- `instr/daa`, `intr_timing`
- `oam_dma/basic`
- `ppu/intr_1_2_timing-GS`, `ppu/intr_2_0_timing`, `ppu/stat_irq_blocking`
- `timer/tim00_div_trigger`, `timer/tim01`, `timer/tim11_div_trigger`

**Failing tests** (48/66):
- `add_sp_e_timing`, `bits/unused_hwio-GS`
- `boot_div-dmgABCmgb`, `boot_hwio-dmgABCmgb`
- `call_cc_timing`, `call_cc_timing2`, `call_timing`, `call_timing2`
- `ei_sequence`, `ei_timing`
- `if_ie_registers`, `interrupts/ie_push`
- `jp_cc_timing`, `jp_timing`
- `ld_hl_sp_e_timing`
- `oam_dma/reg_read`, `oam_dma/sources-GS`, `oam_dma_restart`, `oam_dma_start`, `oam_dma_timing`
- `pop_timing`, `push_timing`
- `ppu/hblank_ly_scx_timing-GS`, `ppu/intr_2_mode0_timing`, `ppu/intr_2_mode0_timing_sprites`
- `ppu/intr_2_mode3_timing`, `ppu/intr_2_oam_ok_timing`
- `ppu/lcdon_timing-GS`, `ppu/lcdon_write_timing-GS`, `ppu/stat_lyc_onoff`, `ppu/vblank_stat_intr-GS`
- `rapid_di_ei`
- `ret_cc_timing`, `ret_timing`, `reti_intr_timing`, `reti_timing`, `rst_timing`
- `serial/boot_sclk_align-dmgABCmgb`
- `timer/div_write`, `timer/rapid_toggle`
- `timer/tim00`, `timer/tim10`, `timer/tim11`
- `timer/tim01_div_trigger`, `timer/tim10_div_trigger`
- `timer/tima_reload`, `timer/tima_write_reloading`, `timer/tma_write_reloading`

## Platform Integration

- macOS: Objective-C files for dock icon (`macos_icon.m`) and GameController framework (`macos_gamepad.m`)
- Vendor directory: `vendor/glad/` (OpenGL loader), `vendor/miniaudio.{c,h}` (audio)
- Save states: [BESS](https://github.com/LIJI32/SameBoy/blob/master/BESS.md) format for cross-emulator compatibility (F5 save, F9 load). Implementation in `src/bess.zig`.
