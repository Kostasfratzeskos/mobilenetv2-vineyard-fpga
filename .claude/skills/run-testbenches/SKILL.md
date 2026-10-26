---
name: run-testbenches
description: Run the RTL testbenches in Vivado xsim and judge the results correctly, whether that is one testbench, a named subset or all 35. Use after any change under hardware/, software/export/ or software/golden/, or to the generated program; before committing RTL; or when asked to run, verify or re-check the simulations.
---

# Run the testbenches

Run in the Bash tool (Git Bash) from the repository root. In PowerShell, `bash` starts WSL's bash,
where the scripts can't find Vivado. `scripts/run_sim.sh` finds Vivado under
`/c/Xilinx/Vivado/*/bin` (override with `VIVADO_BIN`), and its work directories go to `sim/`,
which is gitignored.

## Choose the scope
- **One testbench:** use the `// Run:` line at the top of `hardware/tb/<name>_tb.sv`, e.g.
  `bash scripts/run_sim.sh requantize`. Source lists differ between testbenches, and a wrong list
  gives a confusing elaboration error instead of a clean failure.
- **A subset:** `bash scripts/run_all_sims.sh <pattern> ...`. A pattern matches any testbench
  name that contains it, where the name is the file name without `_tb.sv`. So
  `bash scripts/run_all_sims.sh accel` runs exactly the three full-network testbenches: `accel`,
  `accel_dma` and `accel_axi`.
- **Everything:** `bash scripts/run_all_sims.sh`. It takes a long time, so run it in the
  background. Do a full run after a change to the export, the golden sets or the program, and
  before committing an RTL change.
- **After an RTL change:** first the changed block's own testbenches, then
  `bash scripts/run_all_sims.sh accel`.

## Judge the result
- A testbench passes only if it exits 0 and prints a line that starts with `ALL PASS`. The
  message "SIMULATION INCONCLUSIVE ... no 'ALL PASS' marker" contains those words but is not a
  pass.
- `run_all_sims.sh` ends with a summary (`passed : N` with `[ok ]` lines, `FAILED : N` with
  `[ERR]` lines) and exits non-zero if anything failed.
- Spurious failures happen on this machine, most likely caused by the antivirus:
  - "Could not remove the obj directory ... being used by another process"
  - "Simulation engine failed to start ... child exe not found"

  Read the failing log first, because a lock can hide a real failure. Then re-run only those
  testbenches with `bash scripts/run_all_sims.sh <name> ...`.
- A real failure prints the first mismatches (layer, index, expected, got). Find the cause. Never
  loosen a check, change a golden file or edit a generated header to make a test pass.

## Report
Give the passed, failed and inconclusive counts out of N, each failing testbench with its first
error line, and which re-runs passed unchanged. Record a full run's result in the lab notebook
(`/log-session`).
