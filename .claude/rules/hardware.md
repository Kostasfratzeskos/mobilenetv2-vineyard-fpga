---
paths:
  - "hardware/**"
---

# RTL and testbenches (`hardware/`)

## RTL (`hardware/rtl/`)
- Verilog-2001 only (DD-002), synthesizable. Every file starts with `` `timescale 1ns / 1ps `` and
  `` `default_nettype none ``. No SystemVerilog constructs.
- A module's header comment states what it computes, its software twin where it has one (the
  function in `software/cmodel/src/` it mirrors), and its handshake. Keep the header true when the
  module changes.
- The engines are a small set of parameterized blocks reused across all layers (DD-003). Engines
  only do arithmetic; addressing, windowing, padding and stride belong to the feeders.
- Latency is a contract. `docs/latency_map.md` lists every constant that encodes a pipeline depth
  and what it depends on. When a module's latency changes, every row that depends on it changes in
  the same commit.
- Widths come from a provable bound (DD-019). `ACC_W = 26` is justified by the exporter's
  worst-case accumulator bound, which `scripts/thesis_numbers.py` replays.
- `firmware/include/accel_csr.h` mirrors `rtl/axi/axi_lite_csr.v` (register map: DD-031, DD-032),
  and `firmware/test/test_csr_map.c` checks it. Change both together.

## Testbenches (`hardware/tb/`)
- SystemVerilog, self-checking, named `<module>_tb.sv`. A pass prints a line starting with
  `ALL PASS`. A failure prints `FAILED` or `[ERR]`, and the run exits non-zero.
- The header's `// Run:` line is the exact command, with the full source list.
  `scripts/run_all_sims.sh` executes that line, so update it whenever the source list changes.
- `model_scalars.svh` and `program_ops.svh` are generated (`python scripts/gen_program.py --emit`).
  Never type a model scalar into a testbench. Typed scalars went stale once and failed four
  testbenches.
- Write directed cases that give every lane and tap a value that can be told apart, because random
  data hides symmetric wiring faults. Check against two oracles where possible. Prove that a new
  check works by mutation: inject the fault and confirm the check catches it.
- `before` is a reserved word in xsim.
- The three full-network testbenches share one pass criterion through `accel_check.svh`. After any
  RTL change, run the changed block's testbenches, then those three with
  `bash scripts/run_all_sims.sh accel`. `/run-testbenches` has the procedure.
