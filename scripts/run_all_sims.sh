#!/usr/bin/env bash
#=============================================================================
#  run_all_sims.sh  -  run every testbench in the repo and summarise
#
#  Each testbench header carries the exact command that runs it:
#
#      //  Run:  bash scripts/run_sim.sh dw_datapath dw_feeder line_buffer \
#      //          dwconv3x3 wgt_buffer out_stage ...
#
#  That line is the source of truth - it has to be, because the source list
#  differs per testbench and getting it wrong produces a confusing elaboration
#  error rather than a failure. This script reads it (following the backslash
#  continuations) and runs it, so the documented command and the executed
#  command cannot drift apart.
#
#  Usage:
#     bash scripts/run_all_sims.sh              # everything
#     bash scripts/run_all_sims.sh dw res       # only testbenches matching
#
#  Exit status is non-zero if any testbench failed, so it works as a gate.
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ---- pull the Run: command out of a testbench header ----------------------
extract_cmd() {
    awk '
        /Run:[ \t]*bash/ {
            line = $0
            sub(/^.*Run:[ \t]*/, "", line)
            while (line ~ /\\[ \t]*$/) {
                sub(/\\[ \t]*$/, "", line)
                if ((getline nxt) <= 0) break
                sub(/^[ \t]*\/\/[ \t]*/, "", nxt)
                line = line " " nxt
            }
            gsub(/[ \t]+/, " ", line)
            print line
            exit
        }
    ' "$1"
}

PATTERNS=("$@")

matches() {
    [[ ${#PATTERNS[@]} -eq 0 ]] && return 0
    local name="$1" p
    for p in "${PATTERNS[@]}"; do
        [[ "$name" == *"$p"* ]] && return 0
    done
    return 1
}

PASSED=(); FAILED=(); SKIPPED=()

for tb in "$ROOT"/hardware/tb/*_tb.sv "$ROOT"/hardware/tb/*_tb.v; do
    [[ -f "$tb" ]] || continue
    base="$(basename "$tb")"
    name="${base%_tb.*}"
    matches "$name" || continue

    cmd="$(extract_cmd "$tb")"
    if [[ -z "$cmd" ]]; then
        SKIPPED+=("$name (no Run: line)")
        continue
    fi

    printf '\n=============== %s ===============\n' "$name"
    out="$(eval "$cmd" 2>&1)"
    status=$?
    echo "$out" | grep -E '^(ALL PASS|FAILED|  \[ERR\])' | head -8
    if [[ $status -eq 0 ]] && echo "$out" | grep -q "ALL PASS"; then
        PASSED+=("$name")
    else
        FAILED+=("$name")
        echo "$out" | tail -15
    fi
done

printf '\n\n================== SUMMARY ==================\n'
printf 'passed : %d\n' "${#PASSED[@]}"
for n in ${PASSED[@]+"${PASSED[@]}"}; do printf '   [ok ] %s\n' "$n"; done
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf 'skipped: %d\n' "${#SKIPPED[@]}"
    for n in "${SKIPPED[@]}"; do printf '   [--] %s\n' "$n"; done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf 'FAILED : %d\n' "${#FAILED[@]}"
    for n in "${FAILED[@]}"; do printf '   [ERR] %s\n' "$n"; done
    exit 1
fi
printf '\nall %d testbenches pass\n' "${#PASSED[@]}"
