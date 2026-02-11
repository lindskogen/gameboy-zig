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
- Toggle DMG LCD shader: <kbd>C</kbd>
- Quit: <kbd>Escape</kbd>
