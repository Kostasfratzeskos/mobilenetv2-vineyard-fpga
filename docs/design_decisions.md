# Design Decision Log

A running record of the non-trivial choices in this thesis and *why* they were made. Update it
whenever you decide something you might be asked to defend — bit-widths, dataflow, quantization,
scope. Keep the `DD-NNN` ids sequential.

## How to add an entry
Copy the template below, give it the next id, and fill it in.

```
### DD-NNN — <short title>
- Status: Proposed | Accepted | Superseded by DD-XXX
- Date: YYYY-MM-DD
- Context: what question forced a choice.
- Decision: what you decided.
- Rationale: why, in a sentence or two.
- Alternatives considered: what you rejected, and why.
- Revisit if: the condition that would reopen this.
```

---

### DD-001 — Target platform: Zynq UltraScale+ MPSoC
- Status: Accepted
- Date: 2026-06-06
- Context: need a platform that can hold the full MobileNetV2, load images from SD, and (later) a camera.
- Decision: Zynq UltraScale+ MPSoC (ZCU / Kria / Ultra96 class).
- Rationale: enough DSP/BRAM/URAM for the full network, plus a hard ARM (PS) + DDR for image loading and orchestration, and MIPI support for the camera stretch goal.
- Alternatives considered: small Zynq-7000 (too tight for the full network); non-Zynq Artix/Kintex (no hard ARM/DDR, harder SD + camera).
- Revisit if: the specific board runs out of DSP/BRAM at synthesis (Phase 2) → reduce parallelism or tile harder.

### DD-002 — RTL language: Verilog-2001
- Status: Accepted
- Date: 2026-06-06
- Context: must simulate and implement in Vivado; the thesis is about hand-written RTL.
- Decision: Verilog-2001.
- Rationale: fully supported by Vivado; hand-written RTL gives the layer-level control and understanding the work is about.
- Alternatives considered: HLS / SystemVerilog — faster to write but less control, and not the hand-RTL goal.
- Revisit if: timeline pressure makes HLS worthwhile for non-critical glue logic (a scoped exception only).

### DD-003 — Reusable parameterized engines, not per-layer hardware
- Status: Accepted
- Date: 2026-06-06
- Context: MobileNetV2 has dozens of layers; one module per layer is infeasible in the timeframe.
- Decision: a small set of parameterized engines (1×1 conv, 3×3 depthwise, requantize+ReLU6, residual-add, bias) sequenced by a controller across all blocks.
- Rationale: write ~6 modules once and reuse them via parameters and weights — this is what makes the full network achievable.
- Alternatives considered: a fully unrolled per-layer pipeline (enormous area, infeasible).
- Revisit if: a specific layer needs a specialized datapath for performance.

### DD-004 — Tiered success criteria
- Status: Accepted
- Date: 2026-06-06
- Context: full network + live camera from zero in ~5.5 months is high-risk if treated as all-or-nothing.
- Decision: core = full network bit-exact in simulation, plus image-from-SD on the board; stretch = live camera.
- Rationale: guarantees a defensible result even if on-board / camera work runs late.
- Alternatives considered: aiming straight for live camera (a single point of failure).
- Revisit if: ahead of schedule by the end of Phase 4 → pull the camera work forward.

### DD-005 — Quantization scheme: int8, TFLite-style
- Status: Accepted
- Date: 2026-06-06
- Context: FPGA arithmetic must be integer; MobileNetV2 is sensitive to quantization, especially depthwise layers.
- Decision: int8 with **per-channel weights** and **per-tensor activations**; requantize via a fixed-point multiplier + shift; clamp to the ReLU6 range; **batch-norm folded into conv weights/bias offline**.
- Rationale: the canonical, accuracy-preserving recipe for MobileNetV2; an integer-only path maps cleanly to hardware.
- Alternatives considered: float / 16-bit fixed (more area and memory); per-tensor weights (worse depthwise accuracy).
- Revisit if: post-training quantization drops accuracy too far → switch to quantization-aware training.

### DD-006 — Verification by golden vectors (bit-exact, layer by layer)
- Status: Accepted
- Date: 2026-06-06
- Context: need an objective, incremental way to confirm the hardware is correct.
- Decision: the software int8 model emits the exact integer output of every layer; each RTL block and the full network are checked against these bit-for-bit.
- Rationale: removes guesswork, localizes bugs to a single layer, and provides the thesis's hardware-vs-software comparison.
- Alternatives considered: comparing only final accuracy (hides per-layer bugs, hard to debug).
- Revisit if: never — this is the backbone. Extend it as layers are added.

### DD-007 — Memory & dataflow: weights in DDR, activations on-chip
- Status: Accepted
- Date: 2026-06-06
- Context: ~3.4M parameters will not fit on-chip; activations can.
- Decision: stream weights from DDR over AXI4 (HP ports) + DMA; keep activations in BRAM/URAM with tiling.
- Rationale: matches the paper's memory-efficient inference (≤ ~400K activations to materialize at once) and avoids heavy off-chip activation traffic.
- Alternatives considered: all-on-chip weights (won't fit); all-off-chip activations (bandwidth-bound).
- Revisit if: a layer's activation tile exceeds on-chip capacity → add activation streaming for that layer.

---

## DD-008 — Memory layout & export format
**Decision:** Activations stored (N,C,H,W) row-major; weights (OC, IC/groups, KH, KW)
row-major. All hardware artifacts exported as ASCII hex, one value per line, two's
complement, for Verilog $readmemh. Per layer: <name>_w (int8), _b (int32, BN folded),
_m0 (int32 per-out-channel requant multiplier), _shift (uint8 per-out-channel).
manifest.json is the single source of truth (shapes, scales, strides, file map) for
both testbenches and the PS-side C code.
**Rationale:** $readmemh is the native, simulator-agnostic, human-inspectable init
format; per-channel m0/shift as loadable files (not RTL constants) lets weights be
reloaded after retraining without re-synthesis (see DD: dynamic scales).
**Status:** Implemented in export.py (Stage 2). Verified: selftest + 8/8 crosscheck.

## DD-009 — Residual add via integer rescale
**Decision:** At each residual add, the saved (skip) branch is requantized to the
main branch's scale using its own (m0, shift), then the two int8 tensors are added in
int32 and saturated to [-128,127].
**Rationale:** The two branches carry different per-tensor scales; they must be
brought to a common scale before integer addition. Rescaling the skip branch is
cheaper than rescaling the (larger) main branch.
**Consequence / known deviation:** Introduces a second rounding on the skip branch,
so the integer result may differ from the Stage-1 fake-quant model by ≤1 LSB per
element. The integer executor (export.py) is the authoritative spec; fake-quant was
only an accuracy proxy. Crosscheck tolerates a small number of such disagreements.
**Status:** Implemented. Watch crosscheck "agree with FAKE-QUANT" for >2 deltas.

## DD-010 — Global average pool with folded division
**Decision:** GAP computed as an int32 sum over the 49 (7×7) spatial positions,
followed by a single per-tensor requantize whose multiplier M = S_in / (49 · S_out)
folds the ÷49 into the rescale. The conv18 output feeding GAP uses the fixed scale
S_RELU6 = 6/127 (full ReLU6 range, no clipping possible).
**Rationale:** Avoids a hardware divider; the average is obtained for free inside the
requantize multiply-shift already required.
**Status:** Implemented and exported (gap op carries m0, shift, window=49).

## DD-011 — Integer logits & argmax
**Decision:** Classifier outputs are requantized to a common int16 scale S_logit,
calibrated from the float model's max |logit| over a few batches with 1.2× headroom.
argmax over the 4 int16 logits is the predicted class.
**Rationale:** A shared logit scale lets the hardware compare classes directly with a
4-way comparator; int16 gives ample range for the small 4-class head.
**Status:** Implemented. S_logit printed at export time and stored in manifest.json.


### DD-012 — Future Improvements
- Status: Proposed
- Date: 2026-07-06
- Context: Add operations to the platform (add some humidity sensors, or whatever monitors climate changes)
- Decision: If there is enough time or if I continue with that project
- Rationale: More complete work and there is a chance to get the product to the market
- Alternatives considered: --
- Revisit if: --

### DD-013 — Pointwise MAC array shape: Tm=32 × Tn=16
- Status: Accepted
- Date: 2026-09-10
- Context: with P = Tm·Tn = 512 MACs/cycle fixed, the split between output-channel
  parallelism (Tm) and input-channel parallelism (Tn) is free. The earlier note in
  `controller_design.md` argued for Tn=8 because 8 divides every MobileNetV2 channel
  count, so tail-padding would vanish.
- Decision: **Tm=32, Tn=16.**
- Rationale: ran the cycle model `HW · ceil(OC/Tm) · ceil(IC/Tn)` over all 35 pointwise
  layers. 32×16 reaches **92.1%** utilization; 16×32 gives 88.6%, 64×8 gives 74.9% and
  8×64 gives 66.1%. The Tn=8 argument only looked at the *input* dimension: with P fixed,
  Tn=8 forces Tm=64, which wrecks the *output* dimension, because MobileNetV2's bottleneck
  layers are narrow on output (OC = 16, 24, 32, 96) while the expand layers are wide on
  input. Small Tm + large Tn matches that asymmetry. 32×16 also beats 16×32 on cost:
  128-bit activation broadcast instead of 256, adder tree of depth 4 instead of 5. Weight
  bandwidth (4096 bit/cycle) is identical for every split since Tm·Tn is constant.
- Alternatives considered: 64×8 (the earlier proposal, 23% slower); 16×32 (close on
  cycles, worse on broadcast width); a pixel-parallel fallback for layers with OC < Tm,
  which recovers only 2.2% for a substantial control complication — rejected.
- Revisit if: the network is retrained with different channel widths, or P changes.

### DD-014 — Dedicated depthwise engine with Tc=16 channels in parallel
- Status: Accepted
- Date: 2026-09-10
- Context: the depthwise layers are only 6.9% of the MACs, so they were treated as a
  detail. With `dwconv3x3.v` as it stands (one output element per cycle), the cycle model
  says they would take 9.21 ms against 2.27 ms for the entire 512-MAC pointwise array —
  **70% of the runtime for 6.9% of the arithmetic**. The 256-DSP array would sit idle
  waiting for them.
- Decision: a **separate** depthwise engine processing **Tc=16 channels per cycle**
  (~72 DSPs with int8 packing).
- Rationale: depthwise has zero channel reuse — each output channel sees only the
  same-index input channel — so there is no cross-channel accumulation to parallelize and
  the only available axis is channel count. Tc=16 drops the depthwise to 0.58 ms (13% of
  runtime) and the total to 4.45 ms (~225 fps); Tc=32 buys only 7% more for twice the
  DSPs. Kept separate rather than sharing DSPs with the pointwise array: although
  `pw → dw → pw` means the two never run at once, the whole budget is ~380 DSPs (22% of
  the chip), so sharing would add datapath muxing to save a resource that is not scarce.
- Alternatives considered: Tc=8 (half the DSPs, 12% less throughput); Tc=32 (diminishing
  returns); sharing the pointwise array's DSPs (complexity without need).
- Revisit if: the DSP budget gets tight once the stem and the buffers are placed and
  routed, or timing closure fails at 250 MHz.
- **Correction, 2026-09-12 (the decision stands, the numbers were optimistic).** The cycle
  model above counted OUTPUT pixels. A line-buffer window generator has to consume every
  INPUT pixel to slide the window, even at stride 2 where only every other window is
  emitted, and four depthwise layers are stride 2 (features.2/4/7/14.conv.1.0), where the
  input grid is 4x the output grid. Corrected in analyze_workload.py, the depthwise costs
  1.63x more than stated:

      Tc    DSPs   dw ms   total ms   fps   dw share
       1       5   14.96      18.84    53      79%
       8      36    1.87       5.75   174      33%
      16      72    0.94       4.81   208      19%   <-- still the knee
      32     144    0.48       4.36   229      11%

  Tc=16 remains the right choice: Tc=8 leaves the depthwise at a third of the runtime,
  and Tc=32 buys 8 points of share for twice the DSPs. Total latency is 4.81 ms and
  ~208 fps rather than 4.45 ms and 225 fps.

### DD-015 - One requantize unit per lane (R = Tm = 32)
- Status: Accepted
- Date: 2026-09-12
- Context: pe_array finishes Tm=32 accumulators every n_ic cycles, and each has to go
  through bias_add + requantize before it can be stored. With R parallel requantize units
  the drain takes ceil(Tm/R) cycles, so an output tile costs max(n_ic, ceil(Tm/R)).
  Each unit is a 21x32 multiply, which is 2 DSP48E2 - so R is a real area decision.
- Decision: **R = 32, one unit per lane.**
- Rationale: measured over all 35 pointwise layers with
  `python scripts/analyze_workload.py requant`:

      R    DSPs   drain   cycles       vs base   layers stalled
      1      2      32    4,359,316    +667%     28/35
      8     16       4      797,016     +40%      7/35
     16     32       2      605,720      +6.6%    1/35
     32     64       1      568,088       0%      0/35

  R=16 is the knee on cycles, but the reason for R=32 is not in the table: at R=32 an
  entire control path stops existing. With R<32 the output stage needs a shadow register
  to hold the accumulators while the array moves on (32x21 = 672 bit), a drain counter, a
  stall path back into addr_gen, and logic to assemble the 256-bit act_buffer word in
  pieces. At R=32 all 32 results appear in one cycle and already ARE that word. The extra
  32 DSPs are 1.9% of the chip; the control logic they remove is a place for bugs, and
  DSPs are not the scarce resource here - the whole budget is ~442 DSP = 26% of the
  XCZU7EV (array 256 + requantize 64 + depthwise 72 + stem ~50).
- Alternatives considered: R=16 (half the DSPs, +6.6% runtime, but needs the whole drain
  machine); R=8 (16 DSPs but +40% and 7 layers stalled). Note the single layer that R=16
  would stall is features.2.conv.0.0 with IC=16 - the same outlier that forced
  act_buffer's 256-bit entries (DD: act_buffer width). Designing a drain FSM around one
  layer is what R=32 avoids.
- Revisit if: synthesis shows DSPs are tight after the stem and buffers are placed, or the
  requantize multiplier fails timing at 250 MHz and needs pipelining anyway.

### DD-016 - Stem parallelism: TS = 8 output channels
- Status: Accepted
- Date: 2026-09-12
- Context: the stem (features.0.0) is a standard 3x3 convolution, 224x224x3 -> 112x112x32
  at stride 2, so each output element is a 27-tap dot product (3 channels x 3x3). Running
  it one element per cycle costs 401,408 cycles, 1.76 ms, about a quarter of the whole
  network. Each lane costs CIN*K*K = 27 multipliers, so TS is a real area decision.
- Decision: **TS = 8 output channels in parallel** (216 multipliers, 108 DSP48E2).
- Rationale: a line-buffer front end streams 225x225 input pixel-groups (the image plus
  the virtual edge) and emits 112x112 windows, so there are exactly
  50,625 / 12,544 = 4 input cycles per window. With OC=32 that makes ceil(32/TS) <= 4,
  i.e. TS >= 8, the point where the compute stops exceeding the input stream. Measured
  over the whole network with the cycle model:

      TS   DSPs   stem ms   total ms   fps
       1     14      1.76       4.97   201
       2     27      0.96       4.16   240
       4     54      0.55       3.76   266
       8    108      0.35       3.56   281   <-- knee
      16    216      0.25       3.46   289
      32    432      0.20       3.41   293

  Past 8 the input streaming dominates: TS=16 costs another 108 DSPs to buy 3% of
  runtime. Below 8 the compute is the limit and the line buffer sits idle.
- Alternatives considered: TS=32 (one window per cycle, no stalling at all, but 432 DSPs
  for 4% over TS=8); TS=4 (half the DSPs but the stem climbs back to 15% of runtime).
- Consequence: the stem stalls its input stream for 3 cycles per emitted window, since
  windows arrive every 2 cycles inside an odd row rather than evenly spread. That is what
  the 88,257-cycle figure already accounts for.
- Revisit if: the DSP budget tightens after place-and-route, or the input resolution
  changes (the 4-input-cycles-per-window ratio is a property of stride 2, not of 224).

### DD-017 - `busy` means "my writes have landed", not "I stopped reading"

- Context: `top_seq` is sequential. It starts a feeder, waits for `busy` to rise, waits
  for it to fall, idles GAP_CYC cycles, then fetches the next instruction and asks the DMA
  to refill the weight and parameter memories. Every feeder exposes `busy`, so what that
  signal promises is the entire interface between the sequencer and the datapath.
- Decision: `busy` stays high until the last result of the layer has been WRITTEN to the
  activation pool - not until the address generator has issued its last read.

      assign busy = run || layer_done || (drain != 0);

  All five feeders now use this shape, including the three terms.
- Why all three terms are load-bearing:
  - `run` covers the body of the layer.
  - `drain` covers the pipeline behind it: results are still in the arrays, and two more
    stages behind that in the shared `out_stage`.
  - `layer_done` covers the ONE cycle between them. `drain` is loaded by `layer_done`, but
    a register loaded at the end of a cycle is not readable until the next one, and `run`
    has already dropped by then. Without this term `busy` reads low for exactly one cycle
    in the middle of the op.
- What that one cycle cost: `top_seq` leaves S_RUN on the first `!busy` it sees, so it took
  the hole for completion. It then spent GAP_CYC + 8 fetch cycles and began LOADING THE
  NEXT LAYER'S PARAMETERS while the previous op still had its whole drain to go - writing
  over the scales that the in-flight results were about to be requantized with.
- How it was found: only by `accel_tb`. Every standalone datapath testbench waits on
  `layer_done` or runs to a fixed time, so none of them ever samples `busy` at that cycle.
  The bug needed a second op to exist before it could do any damage, which is precisely
  what the integration testbench adds.
- `pw_feeder` was the same mistake wearing different clothes: it had no drain counter at
  all, because `addr_gen` happens to expose a `busy` of its own and connecting it straight
  to the port looked like wiring rather than a decision. It stops a full pipeline depth
  early, which cost the last two pixels of every pointwise layer.
- Consequence: a layer now costs ~7 extra cycles of `busy`. Against 64 instructions that is
  under 500 cycles on a ~3.5 ms inference - unmeasurable - and it buys a handshake whose
  meaning does not depend on the caller knowing each feeder's pipeline depth.
- Revisit if: a feeder is ever given a deeper tail than 7 cycles, the counter has to grow
  with it. The testbench guards this by counting `busy` pulses: exactly one per op.

### DD-018 - The MAC trees need pipelining before the clock target means anything

- Context: everything the docs said about area and frequency was arithmetic on a
  spreadsheet - ~442 DSP, 26% of the XCZU7EV, 250 MHz. `scripts/run_synth.sh` synthesises
  `accel_top` out of context for xczu7ev-ffvc1156-2-e and turns those into measurements.
  Two runs, because the first one's failure said what to change.
- Measured, run 1 (everything left to the tool):

  | | measured | |
  |:--|--:|:--|
  | CLB LUTs | 191,372 | 83.06% |
  | Block RAM | 560 tiles | **179.49% - does not fit** |
  | URAM | 0 | 0% |
  | DSPs | 72 | 4.17% |
  | WNS | -7.123 ns | Fmax 89.9 MHz |

  Two things were wrong at once. The activation pool is 50,176 x 256 bit = 12.85 Mbit,
  which is more than every BRAM on the device put together (11.0 Mbit) - and the tool
  mapped it to BRAM anyway while leaving all 96 URAMs idle. And the multipliers went to
  fabric: 72 DSPs for a datapath that needs 512 in the pointwise array alone, which is
  where the 191k LUTs came from.

- Decision, and run 2: two synthesis DIRECTIVES, no behavioural change (xsim ignores
  attributes, so all 31 testbenches stay valid as written):
  - `(* ram_style = "ultra" *)` on act_buffer's memory.
  - `(* use_dsp = "yes" *)` on mac_lane, conv1x1, dwconv3x3 and conv3x3_std.

  | | run 1 | run 2 | |
  |:--|--:|--:|:--|
  | CLB LUTs | 191,372 (83%) | **32,387** | 14.06% |
  | CLB Registers | 13,342 | 5,705 | 1.24% |
  | Block RAM | 560 (**179%**) | **176** | 56.41% |
  | URAM | 0 | **52** | 54.17% |
  | DSPs | 72 (4%) | **944** | 54.63% |
  | WNS | -7.123 ns | **-17.357 ns** | Fmax 46.8 MHz |

  The design now FITS. 944 DSPs is 2.1x the 442 the docs predicted, and the gap is
  explained exactly: 442 assumed int8 packing, two MACs per DSP48E2 (WP486), which is
  not implemented. Without packing the count is 512 (pointwise) + 144 (depthwise 16x9)
  + 216 (stem 8x27) + the requantize stage, which is 944 to within a few.

- TIMING GOT WORSE, and that is the real finding. The worst path:

      Slack -17.357 ns, logic 19.454 ns (91%), route 1.884 ns (9%)
      Logic Levels: 65  (DSP_ALU=27, DSP_OUTPUT=27, ...)

  A 27-deep DSP cascade with nothing registered in it - the stem's 27 taps
  (CIN*K*K = 3*3*3), summed combinationally in ONE clock cycle. `mac_lane` has the same
  shape with 16. A DSP48E2 only reaches its rated speed with its internal A/B/M/P
  registers used; chained combinationally it is slow, which is why forcing DSPs improved
  area and hurt timing.
- Consequence: 250 MHz is not reachable by constraint or attribute. It needs the MAC
  trees PIPELINED - register the products, then a balanced adder tree with registers
  between stages, so each DSP uses its own pipeline registers and the cascade is broken
  into clocked stages. mac_lane.v's own header already anticipated this ("on the real
  ZCU104 the Tn products + sum map onto DSP48E2 cascades... here we describe it
  behaviourally and verify bit-exact"); this puts a number on what that costs.
- Why it is not done in the same change: pipelining adds latency, and latency is a
  contract. Every feeder's drain counter, every `busy` deadline (DD-017) and every
  testbench's expected result ordering depends on it. It is a build step of its own,
  with the 6,895,780-element end-to-end check as the thing that has to still pass.
- Note on the route numbers: run 1's delay was 65% routing, which at synthesis is an
  estimate from a wireload model and is pessimistic. Run 2's is 9% routing and 91% logic,
  so this conclusion does not depend on that estimate at all.
- Revisit: after pipelining, and again after place-and-route, which is the only thing
  that produces a real Fmax.
