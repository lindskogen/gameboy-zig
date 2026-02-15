#!/bin/bash
# Run all applicable Mooneye acceptance tests and report results

SUITE="game-boy-test-roms-v7.0/mooneye-test-suite/acceptance"
PASS=0
FAIL=0
ERRORS=""

run_test() {
    local test_path="$1"
    local output
    output=$(zig-out/bin/gameboy_zig mooneye "$SUITE/$test_path" 2>&1)
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "  PASS  $test_path"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $test_path"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  $output"
    fi
}

# Build first
echo "Building..."
zig build 2>&1
if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi
echo ""

echo "Running Mooneye acceptance tests..."
echo ""

# bits
run_test "bits/mem_oam.gb"
run_test "bits/reg_f.gb"
run_test "bits/unused_hwio-GS.gb"

# boot
run_test "boot_div-dmgABCmgb.gb"
run_test "boot_hwio-dmgABCmgb.gb"
run_test "boot_regs-dmgABC.gb"

# cpu
run_test "add_sp_e_timing.gb"
run_test "call_cc_timing.gb"
run_test "call_cc_timing2.gb"
run_test "call_timing.gb"
run_test "call_timing2.gb"
run_test "di_timing-GS.gb"
run_test "div_timing.gb"
run_test "ei_sequence.gb"
run_test "ei_timing.gb"
run_test "halt_ime0_ei.gb"
run_test "halt_ime0_nointr_timing.gb"
run_test "halt_ime1_timing.gb"
run_test "halt_ime1_timing2-GS.gb"
run_test "if_ie_registers.gb"
run_test "jp_cc_timing.gb"
run_test "jp_timing.gb"
run_test "ld_hl_sp_e_timing.gb"
run_test "pop_timing.gb"
run_test "push_timing.gb"
run_test "rapid_di_ei.gb"
run_test "ret_cc_timing.gb"
run_test "ret_timing.gb"
run_test "reti_intr_timing.gb"
run_test "reti_timing.gb"
run_test "rst_timing.gb"

# instructions
run_test "instr/daa.gb"

# interrupts
run_test "interrupts/ie_push.gb"
run_test "intr_timing.gb"

# oam_dma
run_test "oam_dma/basic.gb"
run_test "oam_dma/reg_read.gb"
run_test "oam_dma/sources-GS.gb"
run_test "oam_dma_restart.gb"
run_test "oam_dma_start.gb"
run_test "oam_dma_timing.gb"

# ppu
run_test "ppu/hblank_ly_scx_timing-GS.gb"
run_test "ppu/intr_1_2_timing-GS.gb"
run_test "ppu/intr_2_0_timing.gb"
run_test "ppu/intr_2_mode0_timing.gb"
run_test "ppu/intr_2_mode0_timing_sprites.gb"
run_test "ppu/intr_2_mode3_timing.gb"
run_test "ppu/intr_2_oam_ok_timing.gb"
run_test "ppu/lcdon_timing-GS.gb"
run_test "ppu/lcdon_write_timing-GS.gb"
run_test "ppu/stat_irq_blocking.gb"
run_test "ppu/stat_lyc_onoff.gb"
run_test "ppu/vblank_stat_intr-GS.gb"

# serial
run_test "serial/boot_sclk_align-dmgABCmgb.gb"

# timer
run_test "timer/div_write.gb"
run_test "timer/rapid_toggle.gb"
run_test "timer/tim00.gb"
run_test "timer/tim00_div_trigger.gb"
run_test "timer/tim01.gb"
run_test "timer/tim01_div_trigger.gb"
run_test "timer/tim10.gb"
run_test "timer/tim10_div_trigger.gb"
run_test "timer/tim11.gb"
run_test "timer/tim11_div_trigger.gb"
run_test "timer/tima_reload.gb"
run_test "timer/tima_write_reloading.gb"
run_test "timer/tma_write_reloading.gb"

# Summary
echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed ($(($PASS + $FAIL)) total)"
echo "========================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
