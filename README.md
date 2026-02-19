# gameboy-zig

A Game Boy (DMG) emulator written in Zig, ported from [gameboy-rust](../gameboy-rust).

## How to run?

1. Make sure you have Zig installed (0.15+), otherwise follow the guide on https://ziglang.org/download/
2. Then run:

```shell
$ zig build run -- rom.gb
```

## Controls

- Joypad: Arrow keys
- A: <kbd>Z</kbd>
- B: <kbd>X</kbd>
- SELECT: <kbd>Shift</kbd>
- START: <kbd>Enter</kbd>
- Save state: <kbd>F5</kbd>
- Load state: <kbd>F9</kbd>
- Toggle DMG LCD shader: <kbd>C</kbd>
- Quit: <kbd>Escape</kbd>

## Save States

Save states use the [BESS](https://github.com/LIJI32/SameBoy/blob/master/BESS.md) (Best Effort Save State) format, enabling cross-emulator compatibility. States saved in gameboy-zig can be loaded in other BESS-compatible emulators (SameBoy, Gambatte, etc.) and vice versa.

Save files are written to `<rom>.state` alongside the ROM file. On load, the ROM's global checksum is validated to prevent loading a state from a different game.
