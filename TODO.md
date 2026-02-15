# TODO

## Mooneye Test Status: 27/66 passing

### Still failing timer tests (2)
- `timer/tima_write_reloading` - Requires more precise sub-M-cycle timing for writes during the TIMA reload cycle
- `timer/tma_write_reloading` - Same: writing TMA during the exact reload T-cycle needs finer granularity

### Instruction timing tests (16)
- `add_sp_e_timing`, `call_cc_timing`, `call_cc_timing2`, `call_timing`, `call_timing2`
- `jp_cc_timing`, `jp_timing`, `ld_hl_sp_e_timing`
- `pop_timing`, `push_timing`
- `ret_cc_timing`, `ret_timing`, `reti_intr_timing`, `reti_timing`, `rst_timing`
- `ei_sequence`

These all need **per-M-cycle bus access timing**: multi-cycle instructions must perform reads/writes at the correct M-cycle within the instruction, not all at once. This is a significant architectural change to the CPU — each instruction would need to be split into M-cycle steps that interleave with PPU/timer ticks.

### EI/DI timing tests (3)
- `ei_timing` - EI's delayed enable needs exact M-cycle placement
- `rapid_di_ei` - May need the per-M-cycle architecture to pass
- `ei_sequence` - Same

### PPU timing tests (8)
- `ppu/hblank_ly_scx_timing-GS` - HBlank duration varies with SCX, need per-scanline SCX-dependent timing
- `ppu/intr_2_mode0_timing`, `ppu/intr_2_mode0_timing_sprites` - Mode 0 interrupt timing off
- `ppu/intr_2_mode3_timing`, `ppu/intr_2_oam_ok_timing` - Mode 2/3 transition timing
- `ppu/lcdon_timing-GS`, `ppu/lcdon_write_timing-GS` - LCD enable timing not accurate
- `ppu/stat_lyc_onoff` - LYC compare enable/disable mid-frame
- `ppu/vblank_stat_intr-GS` - VBlank STAT interrupt timing

### OAM DMA tests (5)
- `oam_dma/reg_read`, `oam_dma/sources-GS`
- `oam_dma_restart`, `oam_dma_start`, `oam_dma_timing`

Need proper **cycle-accurate DMA**: DMA should transfer 1 byte per M-cycle over 160 M-cycles, blocking CPU access to certain memory regions during transfer. Currently DMA is instant.

### Boot ROM tests (2)
- `boot_div-dmgABCmgb` - DIV value after boot ROM must match hardware (requires running actual boot ROM or setting correct initial internal_counter value)
- `boot_hwio-dmgABCmgb` - All hardware registers must match post-boot state exactly

### Other (3)
- `bits/unused_hwio-GS` - Reads/writes to unmapped I/O registers need correct behavior (some return 0xFF, some have specific bit patterns)
- `interrupts/ie_push` - Tests obscure behavior where IE register value changes during interrupt dispatch push
- `serial/boot_sclk_align-dmgABCmgb` - Serial clock alignment after boot

## Architecture improvements needed (ordered by impact)

1. **Per-M-cycle CPU execution** - Would fix ~16 instruction timing tests. Each instruction split into M-cycle steps; PPU/timer tick between each step. Major refactor.
2. **Cycle-accurate OAM DMA** - Would fix ~5 tests. DMA transfers 1 byte/M-cycle, blocks bus access.
3. **PPU mode transition timing** - Would fix ~8 tests. More accurate cycle counts for mode transitions, especially Mode 3 duration with sprites.
4. **TIMA write-during-reload precision** - Would fix 2 tests. Need to model exactly which T-cycle within the M-cycle the reload happens vs when CPU writes land.
