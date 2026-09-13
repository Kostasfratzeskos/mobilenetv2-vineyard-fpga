#!/usr/bin/env bash
#=============================================================================
#  run_synth.sh  -  synthesise accel_top out of context and report
#
#  Usage:
#     bash scripts/run_synth.sh
#
#  Writes build/synth/{utilization,utilization_hier,timing_summary,timing_paths}.rpt
#  plus a checkpoint, and prints the headline numbers.
#
#  This is the first measurement of anything in the design. Until it runs, the
#  ~442 DSP / 26% / 250 MHz figures in the docs are arithmetic, not results.
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VIVADO_BIN="${VIVADO_BIN:-}"
if [[ -z "$VIVADO_BIN" ]]; then
    for d in /c/Xilinx/Vivado/*/bin; do
        [[ -d "$d" ]] && VIVADO_BIN="$d"
    done
fi
[[ -d "$VIVADO_BIN" ]] || { echo "ERROR: Vivado bin not found. Set VIVADO_BIN=/path/to/Vivado/<ver>/bin"; exit 1; }

OUT="$ROOT/build/synth"
mkdir -p "$OUT"

echo "== vivado : $VIVADO_BIN"
echo "== running synthesis (this takes a while)"
echo

"$VIVADO_BIN/vivado.bat" -mode batch -nojournal \
    -log "$OUT/vivado.log" \
    -source "$ROOT/scripts/synth.tcl"
status=$?

echo
if [[ -f "$OUT/utilization.rpt" ]]; then
    echo "=============== UTILIZATION (from the report) ==============="
    # The device totals live in the "1. CLB Logic" / "3. BLOCKRAM" / "4. ARITHMETIC"
    # tables; print the rows that matter with their percentages.
    grep -E "^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)" "$OUT/utilization.rpt" || true
    echo
fi

if [[ $status -ne 0 ]]; then
    echo ">> SYNTHESIS FAILED (see $OUT/vivado.log)"
    exit 1
fi

grep -E "^(WNS|TNS|WHS)" "$OUT/timing_summary.rpt" 2>/dev/null | head -3 || true
echo ">> reports in build/synth/"
