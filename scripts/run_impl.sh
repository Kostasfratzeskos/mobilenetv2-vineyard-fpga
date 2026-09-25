#!/usr/bin/env bash
#=============================================================================
#  run_impl.sh  -  synthesise AND place-and-route one top out of context
#
#  Usage:
#     bash scripts/run_impl.sh                               # accel_top, XDC period
#     PERIOD=4.000 bash scripts/run_impl.sh                  # the 250 MHz target
#     TOP=accel_axi PERIOD=4.000 bash scripts/run_impl.sh    # + DMA + CSR
#     PERIOD=25.000 TAG=40mhz bash scripts/run_impl.sh
#
#  Writes build/impl_<TAG>/{utilization,utilization_hier,timing_summary,
#  timing_paths}.rpt plus post_synth.dcp / post_route.dcp, and prints the
#  headline numbers. TAG defaults to <TOP>_<period>, so neither two constraints
#  nor two tops ever overwrite each other's reports.
#
#  run_synth.sh stops at synthesis, where the route delay is a wireload
#  estimate. This is the flow that produces a REAL Fmax, which is the only kind
#  the thesis can quote (DD-018).
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

TOP="${TOP:-accel_top}"
export TOP

# TAG defaults to <top>_<period>, so both "which top" and "which constraint"
# are in the path. A post-route number that cannot be traced to its top and its
# constraint is not a measurement.
if [[ -z "${TAG:-}" ]]; then
    if [[ -n "${PERIOD:-}" ]]; then TAG="${TOP}_${PERIOD//./p}"; else TAG="$TOP"; fi
fi
export TAG

OUT="$ROOT/build/impl_$TAG"
mkdir -p "$OUT"

echo "== vivado : $VIVADO_BIN"
echo "== top    : $TOP"
echo "== tag    : $TAG"
echo "== period : ${PERIOD:-<as committed in the XDC>}"
echo "== running synthesis + implementation (this takes a while)"
echo

"$VIVADO_BIN/vivado.bat" -mode batch -nojournal \
    -log "$OUT/vivado.log" \
    -source "$ROOT/scripts/impl.tcl"
status=$?

echo
if [[ -f "$OUT/utilization.rpt" ]]; then
    echo "=============== POST-ROUTE UTILIZATION ==============="
    grep -E "^\| (CLB LUTs|CLB Registers|CARRY8|Block RAM Tile|URAM|DSPs)" \
        "$OUT/utilization.rpt" || true
    echo
fi

if [[ $status -ne 0 ]]; then
    echo ">> IMPLEMENTATION FAILED (see $OUT/vivado.log)"
    exit 1
fi
echo ">> reports in build/impl_$TAG/"
