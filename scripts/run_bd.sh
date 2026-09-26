#!/usr/bin/env bash
#=============================================================================
#  run_bd.sh  -  build the BOARD design: accel_axi wired to the ZCU104's PS
#
#  Usage:
#     bash scripts/run_bd.sh                    # 200 MHz PL clock
#     PL_MHZ=150 bash scripts/run_bd.sh         # a comfortable bitstream
#     BD_ONLY=1    bash scripts/run_bd.sh       # stop after the block design
#     SYNTH_ONLY=1 bash scripts/run_bd.sh       # stop after synthesis
#
#  Writes build/bd_<TAG>/ with the reports, the bitstream and - the one that
#  matters for what comes next - accel_bd_wrapper.xsa, the hardware handoff a PS
#  application is compiled against.
#
#  ---- how this differs from run_impl.sh --------------------------------
#
#  run_impl.sh implements one top OUT OF CONTEXT against an invented clock and
#  budgeted pins. This builds the real system: the PS block, its DDR controller,
#  the AXI interconnect and accel_axi, with the clock coming from the PS's PLL
#  and every interface internal. Until DD-032 removed the last non-AXI port
#  group it was not possible to run this at all - see scripts/impl.tcl:22 for the
#  841-port problem it took three design decisions to dismantle.
#
#  So the number this produces is the first IN-CONTEXT result in the project, and
#  the first honest answer to `08_OPEN_ITEMS` risk 1.
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

PL_MHZ="${PL_MHZ:-200}"
export PL_MHZ
TAG="${TAG:-${PL_MHZ}mhz}"
export TAG

OUT="$ROOT/build/bd_$TAG"
mkdir -p "$OUT"

echo "== vivado   : $VIVADO_BIN"
echo "== PL clock : $PL_MHZ MHz"
echo "== tag      : $TAG"
echo "== running block design + synthesis + implementation (this takes a while)"
echo

#  The -log path is RELATIVE, and that is not cosmetic. Passing an ABSOLUTE log
#  path under this repository breaks create_bd_design:
#
#      couldn't read file "configure_noc.tcl": No error
#      ERROR: [BD 41-68] Error sourcing TCL file
#
#  Vivado sources that helper with a relative path and an absolute non-ASCII -log
#  argument (this tree lives under .../\u03a3\u03a7\u039f\u039b\u0397/...) leaves it unable to find it.
#  run_synth.sh and run_impl.sh pass an absolute -log quite happily because
#  neither builds a block design. Verified both ways: relative works, absolute
#  fails at create_bd_design before anything else runs.
"$VIVADO_BIN/vivado.bat" -mode batch -nojournal \
    -log "build/bd_$TAG/vivado.log" \
    -source "scripts/make_bd.tcl"
status=$?

echo
if [[ -f "$OUT/utilization.rpt" ]]; then
    echo "=============== POST-ROUTE UTILIZATION (in context) ==============="
    grep -E "^\| (CLB LUTs|CLB Registers|CARRY8|Block RAM Tile|URAM|DSPs)" \
        "$OUT/utilization.rpt" || true
    echo
fi

if [[ $status -ne 0 ]]; then
    echo ">> BOARD BUILD FAILED (see $OUT/vivado.log)"
    exit 1
fi

[[ -f "$OUT/accel_bd_wrapper.bit" ]] && echo ">> bitstream: build/bd_$TAG/accel_bd_wrapper.bit"
[[ -f "$OUT/accel_bd_wrapper.xsa" ]] && echo ">> handoff  : build/bd_$TAG/accel_bd_wrapper.xsa"
echo ">> reports in build/bd_$TAG/"
