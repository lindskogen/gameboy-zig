#!/usr/bin/env bash
# Run all applicable Mooneye acceptance tests and report results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="game-boy-test-roms-v7.0/mooneye-test-suite/acceptance"
EXPECTED_FILE="$SCRIPT_DIR/test_expected.txt"
PASS=0
FAIL=0
NEW_PASSES=""
REGRESSIONS=""
ACTUAL_RESULTS=""

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BOLD="\033[1m"
RESET="\033[0m"

if [ ! -f "$EXPECTED_FILE" ]; then
    echo -e "${RED}Missing expected results file: $EXPECTED_FILE${RESET}"
    exit 1
fi

# Build first
echo "Building..."
zig build 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${RESET}"
    exit 1
fi
echo ""

echo "Running Mooneye acceptance tests..."
echo ""

while read -r test_path expected; do
    [ -z "$test_path" ] && continue

    output=$(zig-out/bin/gameboy_zig mooneye "$SUITE/$test_path" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        PASS=$((PASS + 1))
        ACTUAL_RESULTS="$ACTUAL_RESULTS$test_path pass\n"
        if [ "$expected" = "pass" ]; then
            echo -e "  ${GREEN}PASS${RESET}  $test_path"
        else
            echo -e "  ${GREEN}${BOLD}PASS${RESET}  $test_path  ${YELLOW}(NEW PASS!)${RESET}"
            NEW_PASSES="$NEW_PASSES\n    $test_path"
        fi
    else
        FAIL=$((FAIL + 1))
        ACTUAL_RESULTS="$ACTUAL_RESULTS$test_path fail\n"
        if [ "$expected" = "fail" ]; then
            echo -e "  ${RED}FAIL${RESET}  $test_path"
        else
            echo -e "  ${RED}${BOLD}FAIL${RESET}  $test_path  ${RED}(REGRESSION!)${RESET}"
            REGRESSIONS="$REGRESSIONS\n    $test_path"
        fi
    fi
done < "$EXPECTED_FILE"

# Summary
echo ""
echo "========================================="
echo -e "  ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET} ($(($PASS + $FAIL)) total)"
echo "========================================="

if [ -n "$NEW_PASSES" ]; then
    echo ""
    echo -e "  ${GREEN}${BOLD}New passes:${RESET}"
    echo -e "$NEW_PASSES"
    echo ""
    read -p "  Update test_expected.txt? [y/N] " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        printf "%b" "$ACTUAL_RESULTS" > "$EXPECTED_FILE"
        echo -e "  ${GREEN}Updated!${RESET}"
    fi
fi

if [ -n "$REGRESSIONS" ]; then
    echo ""
    echo -e "  ${RED}${BOLD}Regressions:${RESET}"
    echo -e "$REGRESSIONS"
    exit 1
fi
