#!/usr/bin/env bash
#=============================================================================
#  run_sim.sh  -  compile + elaborate + run one kernel's testbench in xsim
#
#  Convention (matches the repo layout):
#     RTL source : hardware/rtl/**/<module>.v        (Verilog-2001)
#     testbench  : hardware/tb/<module>_tb.sv|.v     (SystemVerilog ok)
#     work dir   : sim/xsim_<module>/                (gitignored, regenerable)
#
#  Usage:
#     bash scripts/run_sim.sh <module> [extra_rtl ...]
#     WAVES=1 bash scripts/run_sim.sh <module>          # open waveform GUI
#
#  Examples:
#     bash scripts/run_sim.sh requantize
#     bash scripts/run_sim.sh conv1x1 requantize        # pull in a 2nd module
#     WAVES=1 bash scripts/run_sim.sh requantize         # inspect signals
#
#  Extra sources may be a bare module name (found under hardware/rtl) or a path.
#  Vivado is auto-detected under /c/Xilinx/Vivado/*/bin; override with VIVADO_BIN.
#  Default run is headless: exit status is non-zero if the TB prints [ERR]/FAILED.
#  WAVES=1 elaborates with -debug and launches the xsim GUI instead.
#=============================================================================
set -euo pipefail

MODULE="${1:?usage: run_sim.sh <module> [extra_rtl ...]}"
shift || true
EXTRA=("$@")

# ---- repo root = parent of scripts/ ----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- locate Vivado bin (override with VIVADO_BIN) --------------------------
VIVADO_BIN="${VIVADO_BIN:-}"
if [[ -z "$VIVADO_BIN" ]]; then
    for d in /c/Xilinx/Vivado/*/bin; do
        [[ -d "$d" ]] && VIVADO_BIN="$d"      # last match = newest version
    done
fi
[[ -d "$VIVADO_BIN" ]] || { echo "ERROR: Vivado bin not found. Set VIVADO_BIN=/path/to/Vivado/<ver>/bin"; exit 1; }

# ---- locate RTL source (optional: integration TBs have no like-named module)
RTL="$(find "$ROOT/hardware/rtl" -name "$MODULE.v" | head -1)"
if [[ ! -f "$RTL" ]]; then
    RTL=""
    echo "note: no hardware/rtl/**/$MODULE.v -- treating as integration TB (extra sources only)"
fi

TB=""
for ext in sv v; do
    cand="$ROOT/hardware/tb/${MODULE}_tb.$ext"
    [[ -f "$cand" ]] && { TB="$cand"; break; }
done
[[ -n "$TB" ]] || { echo "ERROR: testbench 'hardware/tb/${MODULE}_tb.(sv|v)' not found"; exit 1; }

# ---- resolve extra sources (bare module name or explicit path) ------------
EXTRA_SRCS=()
for e in ${EXTRA[@]+"${EXTRA[@]}"}; do
    if [[ -f "$e" ]]; then
        EXTRA_SRCS+=("$e")
    else
        p="$(find "$ROOT/hardware/rtl" -name "$e.v" | head -1)"
        [[ -f "$p" ]] || { echo "ERROR: extra source '$e' not found"; exit 1; }
        EXTRA_SRCS+=("$p")
    fi
done

# ---- fresh work dir --------------------------------------------------------
WORK="$ROOT/sim/xsim_${MODULE}"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
cd "$WORK"

# ---- assemble the source list (TB + optional RTL + extras) ----------------
SRCS=("$TB")
[[ -n "$RTL" ]] && SRCS+=("$RTL")
SRCS+=(${EXTRA_SRCS[@]+"${EXTRA_SRCS[@]}"})

echo "== module     : $MODULE"
echo "== rtl        : ${RTL:-<none>}"
echo "== testbench  : $TB"
echo "== extra src  : ${EXTRA_SRCS[*]:-<none>}"
echo "== vivado bin : $VIVADO_BIN"
echo

echo "== xvlog =="
"$VIVADO_BIN/xvlog.bat" -sv "${SRCS[@]}"

# -debug typical makes signals probeable in the GUI; only needed for waves
DEBUG_FLAG=()
[[ "${WAVES:-0}" == "1" ]] && DEBUG_FLAG=(-debug typical)

echo "== xelab =="
"$VIVADO_BIN/xelab.bat" "${MODULE}_tb" -s sim_snap --timescale 1ns/1ps ${DEBUG_FLAG[@]+"${DEBUG_FLAG[@]}"}

echo "== xsim =="
if [[ "${WAVES:-0}" == "1" ]]; then
    # Populate the Wave window, but skip objects too large to display -- big
    # $readmemh memory arrays in integration TBs exceed the wave display limit,
    # so add each object under a catch and let those be silently skipped.
    cat > waves.tcl <<'TCL'
if { [catch { set objs [get_objects -recursive * ] }] } { set objs [get_objects *] }
foreach obj $objs { catch { add_wave $obj } }
run all
TCL
    echo ">> launching xsim GUI (close the window to return to the shell)…"
    "$VIVADO_BIN/xsim.bat" sim_snap --gui --tclbatch waves.tcl
    exit 0
fi

"$VIVADO_BIN/xsim.bat" sim_snap -runall | tee sim.log

echo
# Pass requires a POSITIVE marker (the TB prints "ALL PASS"): absence of the
# word FAILED is not enough -- a sim that never started prints neither.
if grep -qE '\[ERR\]|FAILED|^ERROR:|Simulation engine failed' sim.log; then
    echo ">> SIMULATION FAILED ($MODULE)"
    exit 1
elif grep -q 'ALL PASS' sim.log; then
    echo ">> SIMULATION PASSED ($MODULE)"
else
    echo ">> SIMULATION INCONCLUSIVE ($MODULE): no 'ALL PASS' marker -- did the sim run?"
    exit 1
fi
