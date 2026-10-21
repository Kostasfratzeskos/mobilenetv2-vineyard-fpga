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

### DD-019 - Accumulator width from a provable bound, not a measurement (ACC_W = 26)
- Status: Accepted
- Date: 2026-09-22
- Context: `ACC_W=21` was justified by measurement. DD-015's integration note recorded
  "max |acc+bias| = 20,888 against a limit of +-1,048,576 -> 5 bits headroom", and
  logit_out.v recorded 355,971 at the classifier, the network's longest dot product.
  Both numbers were real. Both were observations of ONE image through ONE checkpoint.
- What broke it: the model was retrained on 2026-07-22, five weeks after
  `software/export/` was last regenerated. Running export.py again moved the weights to
  the new checkpoint and `features.3.conv.0.0` channel 110 came out with a bias of
  **1,184,089** - which does not fit a 21-bit signed accumulator ON ITS OWN, for any
  input whatsoever. The hardware wrapped it negative, ReLU6 clamped the result to 0, and
  2,215,904 of 6,895,780 elements were wrong downstream. Ops 0-5 were bit-exact, op 6
  was wrong in exactly 3,136 of 451,584 elements - one channel, every pixel - and
  everything after that was contamination. Nothing in the RTL detects accumulator
  overflow, so the only symptom was the golden comparison.
- Decision: **ACC_W = 26**, and the width is now checked against a bound rather than
  chosen from a measurement. export.py computes, per output channel,

      |acc + bias|  <=  ( sum_taps |w[oc,tap]| ) * max|a|  +  |bias_oc|

  and exits non-zero if the network's worst case does not fit the ACC_W it reads out of
  `hardware/rtl/control/accel_top.v`. `max|a|` is a property of the format, not the data:
  activations entering a layer are either a ReLU6 output in [0, relu6_qmax] or a plain
  int8 in [-128,127]. No image can exceed the bound, so fitting it is sufficient for
  every possible input, adversarial ones included.
- The numbers, this checkpoint:

  | | value | bits |
  |:--|--:|--:|
  | measured, one image | 1,198,084 | 22 |
  | **provable bound, any image** | **5,094,750** (classifier.1) | **24** |
  | loose geometric worst case (taps x 128 x 128) | 15,743,028 | 25 |
  | ACC_W=26 range | +-33,554,432 | 6.6x margin |

  Note that the measurement and the bound point at different layers - the measured worst
  was features.3.conv.0.0 (an outlier bias), the provable worst is the classifier (the
  longest dot product). Sizing from the measurement would have been wrong even with the
  right number.
- Rationale for 26 rather than 24 or 32: the requantize multiply is `ACC_W x M0_W`, i.e.
  ACC_W x 32, and the DSP48E2 multiplier is 27x18. At ACC_W <= 27 one operand fits whole
  and M0 splits 18+14, so it costs **2 DSP per lane**; at ACC_W >= 28 both operands split
  and it costs **4**, which over R=32 lanes is +64 DSP for nothing. So 27 bits is free and
  28 is expensive: 26 takes essentially all the headroom the free zone offers (6.6x)
  while 24 would take only 1.6x. ACC_W=32 buys no correctness the bound does not already
  guarantee, and costs those 64 DSPs.
- Alternatives considered: re-quantizing so the biases fit (changes accuracy, and leaves
  the same class of problem for the next retrain); saturating instead of wrapping (fails
  loudly rather than silently, but still fails); testing more images (cannot establish a
  bound, only raise confidence - and would have missed this, since the overflow was in
  the bias and independent of the image).
- Cost, MEASURED. Two synthesis runs at the SAME 4.000 ns constraint, so ACC_W is the
  only variable - the first attempt compared 21 @ 4 ns against 26 @ 25 ns and the relaxed
  constraint hid about 1,400 LUTs and 12.5 BRAM tiles of the difference:

  | | ACC_W=21 | ACC_W=26 | |
  |:--|--:|--:|--:|
  | CLB LUTs | 32,387 | 35,531 | +3,144 (+9.7%) |
  | CLB Registers | 5,705 | 6,187 | +482 (+8.4%) |
  | CARRY8 | 785 | 937 | +152 (+19.4%) |
  | Block RAM | 176 | 176 | 0 |
  | URAM | 52 | 52 | 0 |
  | **DSPs** | **944** | **944** | **0** |
  | WNS | -17.357 ns | -17.279 ns | +0.078 |

  The DSP count is the number this decision was made on and it did not move: 26 bits fits
  the DSP48E2's 27-bit operand port, so the requantize multiply is still 2 DSP per lane.
  Timing is marginally BETTER, which is expected - the critical path is DD-018's 27-deep
  DSP cascade, which the accumulator width does not touch; the extra bits land in the
  final adder and the feeder mux, nowhere near the bottleneck.

  The predicted cost was "about 160 extra flip-flops", counting only `out_stage`'s
  capture register. The real figure is 3x that, because `pw_out`'s pipeline register, the
  feeders' delay lines and `logit_out` all carry accumulators too. The LUT and CARRY8
  growth is the widened 5-way feeder mux and the wider adders in bias_add / requantize.
  At 9.7% of a 14% utilisation it is not a constraint.

  At the design's actual operating point (25.000 ns, the clock lowered to 40 MHz) the
  design MEETS timing: WNS +3.706 ns, 0 failing endpoints of 92,611, 34,159 LUTs and
  163.5 BRAM. That is the run left in `build/synth/`, so its utilisation report shows
  34,159 rather than the 35,531 in the table above - the table is the controlled 4 ns
  comparison, this is the operating point.
- Verification: all 31 testbenches pass at ACC_W=26 against a golden set regenerated from
  the current checkpoint, including the 6,895,780-element end-to-end check.
- Revisit if: never by measurement. The export-time check is the mechanism now; if it
  fires, widen ACC_W (staying <= 27) or fix the quantization.

### DD-020 - Reset style: asynchronous everywhere, or synchronous so the DSPs can absorb registers
- Status: **Accepted** - option B, validated by the experiment below before the wide edit
- Date: 2026-09-23
- Context: the RTL review's T-5 asks for a reset synchroniser on correctness grounds. `rst_n`
  is a raw top-level input driving `posedge clock or negedge rst_n` in every module.
  Asynchronous ASSERTION is fine; asynchronous DEASSERTION is not - recovery/removal is
  undefined, so an unknown subset of flip-flops leaves reset one cycle late. Measured
  post-route, that subset is **3,998 FDCE + 1 FDPE = 3,999** of the design's 6,180
  registers. For `pc`, `fw`, `st` and every `run`/`cx`/`cy`/`drain` that is a
  nondeterministic initial state. Vivado reports the path clean (+24.027 ns recovery slack
  at 25 ns) only because the XDC gives `rst_n` an input delay, which models a synchronous
  reset the design does not have.

  That much is T-5 and is not in question. What forces a DECISION is what Phase 0 found
  underneath it: the reset style also decides whether **L-1 can work at all**.

- The measurement that turns this from a bug fix into an architecture choice. Vivado's own
  methodology check, **10,940 times** in the post-route report:

      DPIR-2 Warning  Asynchronous driver check
      DSP u_dw/u_arr/ch[0].u_dw/acc0 input pin .../A[0] is connected to registers with an
      asynchronous reset. This is preventing the possibility of merging these registers in
      to the DSP Block since the DSP block registers only possess synchronous reset
      capability. It is suggested to recode or change these registers to remove the reset
      or use a synchronous reset to get the best optimization for performance, power and
      area.

  L-1's fix is "register the products (DSP MREG), then a balanced adder tree with one
  register per level". MREG, and the A/B input and P output registers, are **inside** the
  DSP48E2 and have synchronous reset only. While every flop in the design is async-reset,
  Vivado cannot put a pipeline register inside a DSP - it would place fabric flip-flops in
  FRONT of a cascade that is still unregistered internally, which costs area and buys
  nothing. DD-018 already identified "a 27-deep DSP cascade with nothing registered in it"
  as the critical path; this is the reason the tool cannot fix it for us.

  Confirmed from a second direction, which is stronger evidence than the warning count
  because it is the pass that would actually do the work. `phys_opt_design` runs a
  dedicated DSP register optimization phase, and in this design it finds nothing at all:

      Phase 2 DSP Register Optimization
      INFO: [Physopt 32-456] No candidate cells for DSP register optimization found
            in the design.
      INFO: [Physopt 32-775] End 2 Pass. Optimized 0 net or cell. Created 0 new cell,
            deleted 0 existing cell and moved 0 existing cell

  944 DSPs, 3,999 asynchronously-reset flip-flops feeding them, and **zero candidates**.

  CORRECTION, after the fact: this message is NOT a usable signal, and it is worth saying so
  because it looked like the obvious one. It reads identically after the fix - `phys_opt`
  still reports "no candidate cells", because by then SYNTHESIS has already absorbed the
  registers and there is nothing left for a physical-optimization pass to move. So it says
  "nothing to do" both when the work is impossible and when the work is already done. The
  signals that actually distinguish the two are the DPIR-2 count, the start point of the
  worst timing path, and the flip-flop count.

  Second consequence, available BEFORE L-1: the registers DPIR-2 names are the ones that
  already exist and already drive DSP inputs - `u_stem/win_q` (216 bits) and
  `u_dw/u_lb/wr` (1,152 bits). If they were synchronous-reset, Vivado could absorb them
  into the DSPs' A/B input registers, which moves the start point of the measured critical
  path inside the DSP. That is a timing gain from a reset change alone, with no pipeline
  restructuring and no latency change.

  Where the async registers are, from the hierarchical FF report - the majority are
  datapath, not control:

  | register | bits | drives |
  |:--|--:|:--|
  | `u_dw/u_lb/wr` (line_buffer window) | 1,152 | depthwise DSP A inputs |
  | `u_os/acc_q` | 832 | requantize DSP A inputs |
  | `u_gap` avgpool accumulators | 416 | adders (no DSP) |
  | `u_res` target delay line | 384 | fabric adders |
  | `u_os/u_rq` requantize outputs | 256 | fabric |
  | `u_stem/asm` | 256 | pool write |
  | `u_stem/win_q` | 216 | stem DSP A inputs |
  | control (FSMs, counters, tags, drains) | ~2,600 | - |

- Options.

  **A. T-5 exactly as the review prescribes.** Two-flop synchroniser (ASYNC_REG) at the top,
  async assert / sync deassert, distributed to all submodules; `set_false_path` on the raw
  input. Every module keeps `posedge clock or negedge rst_n`.
  - Fixes: recovery/removal, the 3,999 undefined endpoints, the nondeterministic FSM start.
  - Does NOT fix: DPIR-2. `negedge rst_n` is still in every sensitivity list, so all 10,940
    warnings stay and no register can enter a DSP. **L-1 would then add fabric flops in
    front of unregistered cascades.**
  - Cost: ~2 flip-flops, one XDC line, a rewire in `accel_top`. Diff touches 1 RTL file.

  **B. Synchronous reset throughout, from a two-flop synchroniser.** The synchroniser itself
  is the only thing with `negedge rst_n`; every other always block becomes
  `always @(posedge clock)` with `if (!rst_sync)`.
  - Fixes: recovery/removal AND DPIR-2, so L-1's registers can land inside the DSPs and the
    existing `win_q`/`acc_q` can be absorbed now.
  - Also fixes, for free: the three `[Synth 8-7137] ... has both Set and reset with same
    priority. This may cause simulation mismatches` warnings on `top_seq`'s `w[0:7]`,
    `out_stage`'s `acc_q` and `dw_feeder`'s `grp_wr_prev`. Those exist only because a
    register sits in an async-reset block with no assignment in the reset branch; in a
    synchronous block the construct is ordinary.
  - Cost: the sensitivity list of every clocked block in 24 RTL files. Mechanical, but wide,
    and it is exactly the kind of wide mechanical edit that hides a typo. The
    6,895,780-element end-to-end check is the thing that has to still pass, and it will
    catch a missed reset the moment that register's power-up value matters.
  - Loses: reset assertion now needs a running clock. Out of context that is free (the clock
    always runs); once the PS exists, `rst_n` comes from a PL reset block whose output is
    already clock-synchronous, so this is the normal arrangement rather than a compromise.

  **C. Hybrid - synchronous on the datapath, asynchronous on the control.** Convert only the
  registers that feed DSPs and the arrays around them; leave FSMs async.
  - Cost: smallest diff that unblocks L-1, ~8 files.
  - Loses: two reset conventions in one design, with the boundary defined by nothing a reader
    can see. Given that this project's recurring failure mode is a precondition stated in a
    comment and enforced nowhere (ACC_W=21, L-4's tail contract, A-3's lockstep), adding a
    convention boundary that is invisible is the wrong trade even though it is less typing.

  **D. No reset at all on the pure datapath registers.** What UG949 actually recommends for
  maximum performance: datapath registers are qualified by `valid`, so their power-up value
  never reaches an output.
  - Best for DSP folding and removes the reset net's fanout from ~3,999 endpoints.
  - Loses the property this project's verification leans on hardest: deterministic power-up
    and no X in simulation. Every memory here is zero-initialised on purpose for exactly
    that reason (`act_buffer`, `wgt_buffer`, `param_buffer`, `img_buffer`). Trading it for
    performance would make an X-propagation bug look like a golden-vector mismatch, which is
    the failure mode that already cost an afternoon in `dw_feeder` (`mem[X]` reading X).

- Recommendation: **B**, and do it as its own commit with no other change in it, so the
  end-to-end check isolates it. A is not sufficient - it would have to be redone as B before
  L-1, and doing the wide edit twice is worse than doing it once. D can be applied later to
  individual datapath registers if L-1 still misses timing, but it should not be the default.

- Sequencing. This changes the plan the review gives. The review has T-5 in Phase 1 as a
  safety item and L-1 in Phase 2 as a timing item, with no link between them. If B is
  accepted, Phase 1 should implement B rather than A, because Phase 2 depends on it and
  Phase 1 is the phase that is explicitly allowed to change no latency - which B does not.

- Validation, RUN, and it changed which leaf to convert. The proposal said "convert
  `dwconv3x3` + `dw_array`", which is not possible: both are purely combinational and own
  no registers at all. The registers DPIR-2 actually names are the ones DRIVING the DSP
  inputs, and grouping the 10,940 violations by instance says exactly where they are:

  | violations | instance | the register driving it |
  |--:|:--|:--|
  | 6,480 (59%) | `u_stem/u_arr` (216 DSPs) | `stem_feeder`'s `win_q`, 216 bits |
  | 4,320 (39%) | `u_dw/u_arr` (144 DSPs) | `line_buffer`'s `wr[]`, 1,152 bits |
  | 140 (1%) | `u_log/cls[*].u_r` | `logit_out`'s parameter registers |

  `pe_array`'s 512 DSPs and `out_stage`'s 64 are ABSENT from the list, and the reason is
  worth keeping: their inputs come from `act_buffer`, `wgt_buffer` and `param_buffer` `dout`
  registers, which have no reset at all, plus `out_stage`'s `acc_q`, which has no assignment
  in its reset branch. So the registers that were already mergeable are precisely the ones
  with no reset - option D's argument, measured, without anyone having chosen it.

  The experiment was therefore `stem_feeder`'s `win_q`: one register, the largest share, and
  it sits on the design's measured critical path. Two synthesis runs at 4.000 ns, that one
  register the only difference:

  | | async `win_q` | sync `win_q` | |
  |:--|:--|:--|:--|
  | worst path FROM | `u_stem/win_q_reg[7]/C` | `u_stem/u_arr/lane[0].u_conv/acc26/`**`DSP_A_B_DATA_INST/CLK`** | inside the DSP |
  | WNS | -17.279 ns | **-17.036 ns** | +0.243 |
  | `u_stem` flip-flops | 847 | **638** | -209 of win_q's 216 |
  | total flip-flops | 6,174 | 5,966 | -208 |
  | total LUTs | 35,625 | 35,540 | -85 |
  | DSPs | 944 | 944 | 0 |

  The start point of the critical path moved from a fabric flip-flop INTO the DSP48E2's A/B
  input register. That is the mechanism L-1 depends on, demonstrated on real silicon
  geometry rather than argued from the datasheet. `stem_datapath_tb` passes unchanged.

  Note what the experiment does NOT show: a large timing win. +0.243 ns on a path that is
  22.8 ns long, because the register moved into the DSP's INPUT stage and the 27-deep
  unregistered ALU cascade behind it is untouched. That is the expected result and it is the
  point - the cascade is L-1's job, and L-1 can now put its registers where they belong.

- The whole design, measured. 49 always blocks across 16 files, post-route at 4.000 ns:

  | | baseline | Phase 1 | **option B** | |
  |:--|--:|--:|--:|:--|
  | **DPIR-2** | 10,940 | 10,940 | **0** | the goal |
  | `[Synth 8-7137]` sim-mismatch | 10 | 10 | **0** | free |
  | CLB LUTs | 34,834 | 34,957 | **32,919** | -2,038 (-5.8%) |
  | CLB Registers | 6,863 | 6,702 | **4,959** | -1,743 (-26%) |
  | CARRY8 | 937 | 940 | 952 | +12 |
  | Block RAM / URAM | 176 / 52 | 176 / 52 | 178 / 52 | +2 BRAM |
  | **DSPs** | 944 | 944 | **976** | **+32** |
  | WNS | -18.821 | -18.463 | **-18.282** | +0.181 |
  | TNS | -71,607 | -67,421 | -70,411 | worse, see below |
  | real Fmax | 43.8 MHz | 44.5 MHz | **44.8 MHz** | |

  The `[Synth 8-7137]` warnings going to zero was predicted and is worth collecting: all ten
  existed only because a register sat in an asynchronous-reset block with no assignment in
  the reset branch (`out_stage`'s `acc_q`, `dw_feeder`'s `grp_wr_prev`, `top_seq`'s `w[0:7]`).
  In a synchronous block the construct is ordinary, so a class of
  simulation-versus-synthesis mismatch is gone rather than documented.

  Where the **+32 DSPs** went, located rather than assumed: `mac_lane` is 17 DSPs per lane
  instead of 16, times TM=32 lanes. Sixteen of those are the taps; the seventeenth is the
  accumulate stage, which previously had to share the last tap's DSP and now has its own P
  register. That is a good trade twice over - 32 DSPs (1.9% of the device) for 1,743
  flip-flops and 2,038 LUTs, and the accumulator gaining a DSP register stage is exactly the
  direction L-1 is going.

  TNS got worse while WNS got better, which is not a contradiction: the endpoint count grew
  94,308 -> 97,060 because 32 more DSPs and the absorbed registers add timing endpoints, and
  in a design that misses its constraint by 4.5x more endpoints means more failing endpoints.
  The worst path improved and nothing new appeared on it - the ten worst paths are still the
  stem cascade, and the synchronous reset net is on none of them.

- Alternatives considered: leaving `rst_n` as is and relying on the XDC's input delay to
  keep the report clean - that is what happens today, and it is the reason the problem is
  invisible; constraining the reset properly with `set_max_delay` instead of synchronising
  it - makes the timing report honest without making the circuit correct.

- Implemented as: 49 always blocks across 16 files converted from
  `always @(posedge clock or negedge rst_n)` to `always @(posedge clock)`, keeping the same
  `if (!rst_n)` body. The synchroniser in `accel_top` is the ONE block that keeps its
  asynchronous reset, and the convention is documented there rather than in a design note,
  because that is the file a reader is in when they need it. All 31 testbenches pass and
  `accel_tb` is bit-exact at 6,895,780 elements, which is the check that a wide mechanical
  edit did not drop a reset somewhere it mattered.

- Revisit if: a PS-side reset arrives that is already synchronous to this clock (the
  synchroniser then becomes a formality and only the sensitivity lists matter), or if L-1
  still misses timing after pipelining - at which point option D applied to individual
  datapath registers is the next lever, and the measurement above shows why it would work.

### DD-021 - L-8: where the DSP budget actually went, and what `use_dsp` should be attached to
- Status: **Accepted** - variant D implemented; the M0 narrowing REJECTED
- Date: 2026-09-23
- Context: L-8 says the blanket `(* use_dsp = "yes" *)` "solved the LUT problem (191k -> 34k)
  by creating a DSP-budget and timing one: 944 DSPs = 54.6% vs the ~442 (26%) documented in
  rq_bank", and to re-evaluate after L-1/L-3. Phase 2a forced the question earlier than
  planned, because L-1's adder tree is NEW arithmetic and the attribute is on the MODULE, so
  it claims the tree too. The first synthesis after pipelining `mac_lane` came back at
  **1,200 DSPs (69.4%)**, up 224 from 976, i.e. +7 per lane - and the depthwise (144 DSPs)
  and stem (216) trees are still to come in Phase 2b and 2c, so this compounds.

- What the attribute is actually doing. `use_dsp="yes"` on a module applies to every
  arithmetic operator in it. Before L-1 that was only multiplies, so "module" and "the
  multiplies" were the same set and the distinction never came up. After L-1 the module also
  contains 15 adders per lane of TREE_W = 20 bits, and Vivado put about half of them in
  DSP48E2s. A 20-bit add is roughly 20 LUTs and three CARRY8; a DSP48E2 is 1/1728th of the
  scarcest resource on this device.

- Measured. FOUR variants, all at 4.000 ns, all bit-exact - the attribute is invisible to
  xsim, so all 31 testbenches and `accel_tb`'s 6,895,780 elements pass identically in every
  one. The differences below are purely what the tool builds:

  | | pre-2a | A: module | B: tree="no" | C: prod="yes" | **D: split by level** |
  |:--|--:|--:|--:|--:|--:|
  | **DSPs** | 976 | 1,200 | 688 | 1,168 | **944 (54.6%)** |
  | CLB LUTs | 32,954 | 33,085 | 51,581 | 33,922 | **30,095 (13.1%)** |
  | CLB Registers | 4,929 | 4,951 | 18,417 | 5,789 | 9,926 (2.2%) |
  | CARRY8 | 952 | 952 | 4,568 | 1,080 | 1,752 |
  | WNS, synth | -17.036 | -17.036 | -16.275 | -17.036 | **-16.296** |
  | DSPs per `mac_lane` | - | ~24 | 8 | 23 | **16** |
  | DSPs in `u_pwf` | 544 | - | 256 | 736 | **512** |

    A  the attribute on the module, which is what Phase 2a committed
    B  `use_dsp="yes"` on the product register, `"no"` on the whole tree
    C  no module attribute, `"yes"` on the product register, tree left to "auto"
    D  `"yes"` on the product, level 1 left to "auto", levels 2.. forced `"no"`

- What the four runs actually establish, which is not what the finding assumes.

  The module-level attribute is NOT the cause. C removed it and still came back at 23 DSPs
  per lane. The cause is that a DSP48E2 has an ALU behind its multiplier, so Vivado absorbs a
  LEVEL-1 tree add into the same DSP that produced the two products - that add is free - and
  cannot do so for level 2 and above, whose inputs are two DSP outputs. It then allocates a
  whole DSP48E2 per adder: seven more per lane, 224 across the array.

  B, which looked best on DSPs, is the one to reject. 688 cannot be 16 multiplies per lane: a
  DSP48E2 has ONE 27x18 multiplier and two int8 products can only share it if they share an
  operand, which `mac_lane`'s taps do not. `u_pwf` measured 256 DSPs - 8 per lane - so the
  other eight multiplies are in FABRIC, which is precisely what DD-018 diagnosed and fixed.
  Much smaller than the 191k-LUT original (51.6k, 22%, against 83% then), and arriving by
  accident rather than by decision, which is how the first one happened too.

  **D is strictly better than all of them, and better than not pipelining at all.**
  `u_pwf` lands on exactly TM*TN = 512 DSPs - the theoretical minimum for 512 int8 multiplies
  with no packing - so L-1's adder tree costs ZERO extra DSPs. And 30,095 LUTs is 2,859 FEWER
  than the 32,954 the design used before `mac_lane` was pipelined at all, because the 27-tap
  and 16-tap combinational cascades that used to be spread across DSP ALUs are now a compact
  registered tree. The 4,997 extra flip-flops over A are the tree registers, which is the
  thing being bought.

- The OTHER half of L-8, and it is a harder no than the review implies. L-8 says
  "requantize's 2 DSPs/lane can drop to 1 if M0 narrows to 27 bits - measure against golden
  vectors first". Measured, over every per-channel multiplier this model exports:

      per-channel M0 values : 36,324
      max |M0|              : 2,147,461,603   (features.14.conv.0.0)
      bits needed, signed   : 32
      values fitting in signed 27 bits : 124 / 36,324  (0.3%)

  That is not a near miss and it is not data-dependent. M0 is a NORMALIZED fixed-point
  multiplier: the exporter scales it into the top of int32 on purpose, which is what buys the
  mantissa precision, so by construction it occupies 31 bits. Narrowing `M0_W` to 27 requires
  re-normalising M0 into [2**26, 2**27) and reducing `shift` by four to compensate - which
  drops four bits of multiplier precision, changes results, and invalidates every golden
  vector in the repository.

  So this is not an RTL parameter change that needs a golden-vector check. It is a
  QUANTIZATION change that needs an accuracy study, and it belongs with DD-005 and DD-011,
  not here. The 64 DSPs it would save are 3.7% of the device; the thing it spends is the
  bit-exactness chain the whole verification method rests on. **Recommend NOT doing it**, and
  recording why, so it stops being re-proposed.

- Recommendation: **D**. And the general rule it establishes, which matters more than this
  one module: attach `use_dsp` to the OPERATION at the granularity the tool reasons about -
  here, per tree level - never to the module. Phase 2b and 2c give `dwconv3x3` (9 taps, 144
  DSPs) and `conv3x3_std` (27 taps, 216 DSPs) the same tree, and A's +7 DSPs per instance
  would have repeated there at 16 and 8 instances respectively.

  There is no trade to make: D dominates A, B and C on DSPs, LUTs and WNS simultaneously. The
  only column where it is not first is flip-flops, at 2.2% of the device.

- D post-route, which is the number the acceptance test asks for:

  | | baseline | Phase 1 | DD-020 | **2a + D** |
  |:--|--:|--:|--:|--:|
  | CLB LUTs | 34,834 | 34,957 | 32,919 | **29,935 (13.0%)** |
  | CLB Registers | 6,863 | 6,702 | 4,959 | 9,940 (2.2%) |
  | CARRY8 | 937 | 940 | 952 | 1,752 |
  | Block RAM / URAM | 176 / 52 | 176 / 52 | 178 / 52 | 178 / 52 |
  | DSPs | 944 | 944 | 976 | **944 (54.6%)** |
  | WNS | -18.821 | -18.463 | -18.282 | **-16.411** |
  | real Fmax | 43.8 MHz | 44.5 MHz | 44.8 MHz | **49.0 MHz** |
  | DPIR-2 | 10,940 | 10,940 | 0 | **0** |

  So pipelining ONE of the three MAC kernels, with the attribute attached to the right thing,
  is worth 4.2 MHz and costs 4,981 flip-flops and nothing else - the DSP count is identical
  to the pre-review baseline and the LUT count is 4,899 LOWER. The worst path is still the
  STEM, 27 unregistered DSP_ALU levels and 19.233 ns of the 20.362 total, which is Phase 2c's
  job and the reason this is 49 MHz and not 250.

- Revisit if: Phase 2c's conv3x3_std tree changes the DSP total enough to matter, or L-3's
  requantize pipelining changes the 2-DSP-per-lane requantize cost (the `[Synth 8-5845] Not
  enough pipeline registers after wide multiplier. Recommended levels of pipeline registers
  is 2` note appears once per requantize lane today, and L-3 adds exactly those registers -
  so the requantize DSP count may move on its own).


### DD-022 - A-1/A-3: where to put the register that breaks the activation broadcast
- Status: **Accepted** - option B implemented; option A not needed, A-3 does not fire
- Date: 2026-09-24
- Approved: 2026-09-24. One amendment made during implementation, recorded at the end:
  `w` is registered alongside `a`, not left to arrive fresh.
- Context: A-1 says `pe_array`/`dw_array`/`stem_array` have "no pipeline stage and no port to
  add one", that the 128-bit broadcast has "fanout 32 per bit, unregistered, across ~30% of
  the device's DSP columns", and that post-route route delay grew 1.892 -> 5.144 ns. Its
  recommendation is to "split lanes into groups with a registered broadcast chain (a and
  controls delayed one cycle per group), then de-skew accumulators on the way out", and it
  notes this contradicts `pe_array`'s "structural wiring only" constraint - an architecture
  decision. A-3 is the consequence: lane 0 would finish G-1 cycles early, so `done` must come
  from the last group.

- **The measurement A-1 predates.** After Phase 2d the worst post-route path at 4.000 ns is
  the activation read feeding a MAC product, WNS -2.126, and all 25 reported worst paths are
  that one path. Decomposed from the routed timing report:

  | segment | delay | share |
  |:--|--:|--:|
  | `act_buffer` URAM cascade, 8 x URAM288 (1.318 launch + 7 x 0.194 `CAS_OUT_DOUT_A`) | 2.682 ns | 44% |
  | `sel_q` half-entry mux (one LUT5) + the route into it | 0.700 ns | 12% |
  | **activation broadcast - ONE net, fanout 115, pure route** | **1.279 ns** | **21%** |
  | DSP48E2 multiply, A pin -> ALU_OUT, AREG transparent | 1.405 ns | 23% |
  | | **6.066 ns** | (= the report's Data Path Delay) |

  Required time is 4.023 ns, so 2.126 ns has to come out.

- **A-1's diagnosis is confirmed; its arithmetic no longer is.** The broadcast is real and it
  is on the critical path - 1.279 ns of pure route on a single net at fanout 115, which is the
  second-largest term. But it is not the largest: the URAM cascade is. Removing the broadcast
  delay ENTIRELY would leave 4.79 ns and still miss 4.000 ns. A-1 is necessary and not
  sufficient, and the sufficient part is not among the review's 43 findings (see DD-023).

  Also worth correcting for the record: the fanout is 115 on this net, not the "32 per bit"
  the finding describes. `a` is signed int8 sign-extended into a 27-bit DSP A port, so the
  high bits of one activation byte drive many A-port bits per lane as well as many lanes.

- **Three places the register could go**, with the measured budget for each. Every option adds
  exactly one cycle to the `a` path, so `MAC_LAT` goes 6 -> 7 and `TAG_LAT` and `DRAIN_CYC`
  follow from it - one `localparam`, per docs/latency_map.md's rule.

  | | where the register goes | stage 1 | stage 2 | closes 4.023? |
  |:--|:--|--:|--:|:--|
  | **A** | G groups down a chain, per A-1 | URAM+mux+bcast/G | ... | needs G tuning |
  | **B** | ONE 128-bit register on `a` at `pe_array`'s input | 3.382 ns | 2.684 ns | **yes, both** |
  | **C** | per-lane, absorbed into the DSP's own AREG/BREG | 4.661 ns | 1.405 ns | no |

  - **B** splits the path exactly where the delay is: URAM cascade + mux on one side (3.382 ns),
    broadcast route + DSP multiply on the other (2.684 ns). Both sides fit under 4.023 ns with
    margin. Cost is 128 flip-flops plus the three control bits, and `pe_array` stops being
    "structural wiring only" by one register rather than by a grouped chain.
  - **C** looks attractive because DD-020 made reset synchronous precisely so the DSPs could
    absorb registers, and DPIR-2 is 0 - so a lane-input register should cost zero fabric. But
    it puts the register on the WRONG SIDE of the broadcast: the 1.279 ns route stays with the
    URAM cascade and stage 1 is 4.661 ns. It fails on this path.
  - **A** is B generalised to G groups. It only buys something if, after B, the broadcast route
    ALONE still does not fit - and after B the broadcast shares its stage only with the DSP
    multiply, at 2.684 ns total. There is no measured need for it today.

- **Recommendation: implement B, and treat A as contingent.** B satisfies A-1's intent - the
  broadcast is registered and no longer shares a stage with the memory read - at one register
  instead of a grouped chain with accumulator de-skew.

  **A-3 then does not fire at all.** Every lane still sees the same `valid`/`first`/`last` one
  cycle later, so the lockstep invariant behind lane-0 `done` holds unchanged, and the Phase 2a
  lockstep check will confirm it rather than fail. A-3 reduces to the header paragraph in
  `pe_array.v` that currently says "A-1 will deliberately BREAK this invariant" - which, under
  B, becomes wrong and needs rewriting. That is the whole of A-3 under this option.

- **What this proposal does NOT claim.** The budget above is one path. Fixing it makes something
  else critical - most likely the weight path into the DSP B port, which has the same shape
  (`wgt_buffer` read -> per-lane B pins) but was never the worst path and so has never been
  decomposed. The estimate for stage 1 and stage 2 assumes routing no worse than today's for
  segments that are not moving, which is an assumption about the placer, not arithmetic. The
  only honest claim is: B is the cheapest change that removes the measured 1.279 ns broadcast
  from the memory-read stage, and whether the design then reaches 250 MHz is the next
  measurement.

- Consequences if accepted: `pe_array` gains `clock`, `rst_n` and a registered `a`/control
  input (A-2's shape, one level up, and the same argument - a latency that is a wire the
  feeder connects rather than a number it asserts); `MAC_LAT` 6 -> 7 with `TAG_LAT` 8 and
  `pw_feeder`'s `DRAIN_CYC` 12, all derived; `dw_array` and `stem_array` get the same
  treatment only if measurement says their broadcasts are critical, which today it does not;
  `pe_array.v`'s A-1/A-3 header paragraph is rewritten to describe what was built.

- **MEASURED after implementation.** Post-route at 4.000 ns, against Phase 2d:

  | | Phase 2d | Phase 3 (A-1 option B) |
  |:--|--:|--:|
  | WNS | -2.126 ns | **-1.587 ns** |
  | Fmax | 163.2 MHz | **179.0 MHz** |
  | CLB LUTs | 34,062 | 34,168 (+106) |
  | CLB Registers | 18,243 | 19,716 (+1,473) |
  | DSPs | 944 | 944 |
  | DPIR-2 | 0 | 0 |

  All 31 testbenches pass, `accel_tb` bit-exact at 6,895,780 elements. `pe_array_tb` asserts
  `ARR_LAT` = 7 as an EQUALITY, `pw_feeder_tb` measures the drain at 7, and `pw_feeder`'s own
  runtime check times the real array latency - three independent witnesses on the one number
  that moved.

- **The broadcast is gone from the worst path, which is what B was for.** Phase 2d's worst
  path ended at a MAC product register with 1.279 ns of fanout-115 route in it. No path like
  that appears now. A-1 is resolved and option A - the grouped chain with accumulator de-skew -
  was never needed. **A-3 never fired**: the input register feeds every lane the same controls
  on the same cycle, so the lockstep check passed unchanged, and A-3 reduced to rewriting the
  `pe_array.v` header paragraph that predicted the opposite.

- **The register cost about a third of what this DD predicted, and the reason is DD-020.**
  Predicted +4,224 flip-flops (128 for `a_q`, 4,096 for `w_q`, 3 controls). Measured +1,473,
  and by hierarchy `pe_array`'s OWN level carries **zero** flip-flops - the whole stage was
  absorbed or retimed:
  - `w_q`'s 4,096 bits went into the DSP48E2 B-side input registers at zero fabric cost, with
    the DSP count unchanged at 944 and DPIR-2 still 0. That is precisely the merge DD-020 made
    reset synchronous to enable, and this is the first change to collect on it.
  - The remainder was retimed backwards into `act_buffer`'s hierarchy (`u_act` flip-flops
    5 -> 1,525). The tool chose where to place the stage boundary; the LOGICAL pipeline is what
    the RTL says, which is what the golden vectors confirm.

  So the DD-022 amendment - registering `w` here rather than re-timing the feeder's weight read
  to save 4,096 flip-flops - cost almost nothing in the end. It was argued on robustness and
  happened to be nearly free.

- **What it did NOT fix.** 179.0 MHz is not 250 MHz. The new worst path is
  `u_act/mem_reg_0_uram_0/CLK` -> `u_dw/u_lb/...psdsp/D`: the same `act_buffer` URAM read, now
  feeding the DEPTHWISE line buffer instead of the pointwise array. The URAM cascade is
  unchanged at 2.673 ns and is now 48% of a 5.514 ns path, the rest being 2.085 ns of pure
  route through two LUTs into `u_dw/u_lb` (route 2.778 ns exceeds logic 2.736 ns - this one is
  a placement problem as much as a logic one). See DD-023, whose condition this resolves.

### DD-023 - The `act_buffer` URAM cascade, which is the largest term and is not in the review
- Status: **Deferred** - the condition resolved in favour of doing it, and the decision was
  taken NOT to. 2026-09-24: clock work stops at 179.0 MHz and the review's remaining effort
  goes to correctness. This entry stays because the analysis is the reason 250 MHz was not
  reached, and whoever picks the clock back up should start here rather than re-deriving it.
- Date: 2026-09-24
- Context: not one of the 43 findings. It entered the project as a synthesis warning noted in
  docs/latency_map.md before Phase 2 started, on the grounds that it might have to change and
  should not be discovered mid-phase:

      WARNING: [Synth 8-6057] Memory: "mem_reg" defined in module: "u_act" implemented as
      Ultra-Ram has no pipeline registers. It is recommended to use pipeline registers to
      achieve high performance.

  It is still emitted, twice, after Phase 2d.

- Measured: it is now the single largest contributor to the worst path - 2.682 ns of 6.066 ns
  (44%). `act_buffer` is a 256-bit x 65,536-entry array with `ram_style = "ultra"` and one
  output register (`dout <= mem[rd_addr]`). Vivado builds the depth as a `CAS_OUT_DOUT_A`
  cascade and the worst path walks EIGHT URAM288 tiles: one 1.318 ns launch plus seven 0.194 ns
  cascade hops, all inside one clock cycle.

- The fix is the URAM output pipeline register the warning asks for, i.e. read latency 1 -> 2.
  That is a latency change of the same class as L-1 and L-3: it moves **every feeder's stage-1
  delay** (`v_d`, `v_d1`) and every tag pipeline behind it, in five feeders. It is not a
  one-module edit.

- **Why this was PROPOSED and not scheduled, and how it resolved.** The condition was: under
  DD-022 option B the URAM cascade plus the `sel_q` mux becomes a stage of its own at 3.382 ns,
  which fits under the requirement - so if that held, this change would buy only margin and not
  be needed for 250 MHz.

  **It did not hold, and the estimate was wrong in an instructive way.** DD-022 B shipped and
  measured 179.0 MHz, WNS -1.587. The new worst path is the same URAM read, but its consumer is
  the DEPTHWISE line buffer rather than the pointwise array:

      u_act URAM cascade, 8 tiles     2.673 ns   (48%)
      route + sel mux (LUT5)          0.721 ns
      route to u_dw/u_lb + LUT6       1.140 ns
      route to the line-buffer FF     0.980 ns
                                      -------
                                      5.514 ns   against a 4.010 ns requirement

  The 3.382 ns figure costed the stage against ONE consumer - the pointwise broadcast, at
  1.279 ns. But `act_buffer`'s output feeds all five feeders, and the depthwise path after the
  mux is 2.12 ns, not 1.28. Costing a shared resource against its cheapest consumer is the
  mistake; the cascade has to fit alongside the WORST of them.

  So the URAM cascade is the shared root of the remaining worst paths - 44% of Phase 2d's and
  48% of Phase 3's - and it is the next thing to fix. Note also that this path is
  route-dominated (2.778 ns route vs 2.736 ns logic), so `act_buffer` and the depthwise line
  buffer are placed far apart; a pipeline register helps that directly, by giving the router a
  cycle to cross the die in.

- Consequences if accepted: `act_buffer` read latency 1 -> 2; `v_d`/`v_d1` and every tag
  pipeline in `pw_feeder`, `dw_feeder`, `stem_feeder`, `res_feeder` and `gap_feeder` grow by
  one, all derived from one parameter the way `OS_LAT` is; `line_buffer`'s and `wgt_buffer`'s
  alignment against the activation path must be re-checked, since only ONE of the two operands
  would get slower.


### DD-024 - L-6: the C model narrows to int32 before clamping, the RTL does not
- Status: **Accepted** - logged as a deliberate proven-unreachable deviation; neither side's
  arithmetic changed. Comment added to the C, simulation check added to the RTL.
- Date: 2026-09-24
- Context: L-6 says `requantize.c` computes `(int32_t)(rounded >> shift)` and only then clamps,
  while the RTL clamps the full ROUND_W-wide value; the two disagree for |r| > 2^31; the case
  is unreachable and "the RTL is the more correct of the two", but the project methodology says
  every deviation is critical, and "silently differing is the only unacceptable option".

- Confirmed in the source. `software/cmodel/src/requantize.c`:

      int32_t requant_mul_shift(int32_t acc, int32_t m0, int shift) {
          ...
          return (int32_t)(rounded >> shift);      /* <- narrows HERE */
      }

  and `requantize_elem` then calls `clamp_i8(r)` on the already-narrowed value. In the RTL,
  `requantize.v` stage 3 keeps the full ROUND_W = ACC_W + M0_W + 1 = 59-bit value in `s3` and
  stage 4 clamps THAT. So for any r outside int32, C wraps and the RTL saturates.

- **Why it is unreachable, stated as a bound rather than an observation.** This matters because
  DD-019 exists precisely because a measurement-based safety argument failed once. The bound
  here is structural, not measured:
    * `m0` is a NORMALIZED multiplier by construction - export.py emits 2^30 <= m0 < 2^31 - and
      `shift >= 31` follows from the same normalization, because M = m0 * 2^-shift is the real
      scale and every scale in this network is < 1.
    * so |r| = |acc * m0 >> shift| <= |acc| * (m0 / 2^shift) < |acc| * 1 <= 2^25.
  2^25 against 2^31 is six bits of headroom, and it does not depend on the data - only on the
  manifest being normalized. A corrupt manifest could break it, which is what the L-4/L-5 shift
  guards already watch for from the other direction.

- **Recommendation: log it as a deliberate, proven-unreachable deviation. Do not change either
  side.** Narrowing the RTL to 32 bits to match the C would be adding a truncation to the more
  correct implementation in order to reproduce a C artefact - and it would cost an extra guard
  on a path that Phase 2d just finished making the critical one. Widening the C to 64 bits would
  be harmless but pointless: nothing reads the wider value.

  What the deviation needs is to stop being silent, and there are two cheap ways to do that,
  both proposed:
    1. A comment in `requantize.c` at the narrowing, naming the bound above and pointing at this
       DD, so the next reader does not "fix" it into agreement by mistake.
    2. A `` `ifndef SYNTHESIS `` check in `requantize.v` that fires if `s3` ever leaves int32
       range. That is the assertion that turns "proven unreachable" into "checked on every
       vector we run", which is the only form of unreachability worth trusting. It costs nothing
       in synthesis and it would have caught the 2026-07 retrain class of problem.

- Consequences if accepted: one comment in `software/cmodel/src/requantize.c` (a comment only -
  no behaviour change, so this does not touch the chain of trust); one simulation check in
  `hardware/rtl/kernels/requantize.v`; an entry in the deviations list. L-6 closes as
  "deliberate, documented, checked" rather than "fixed".

### DD-025 - L-13: the residual add - three implementations, and the C is the wrong one
- Status: **Accepted** - the C model is corrected to clamp, matching Python and the RTL.
  Approved 2026-09-24, including the C-model edit.
- Date: 2026-09-24
- Context: L-13 says the C narrows the int8+int8 residual sum to `int8_t` (wrapping) while the
  RTL and `res_feeder` clamp; that `residual_add`'s header defends this with "on real data the
  sum fits int8", which is a MEASUREMENT - "the exact reasoning that already failed once for
  ACC_W"; and gives the example 100 + 100, where C gives -56 and the RTL gives 127.

- **Three implementations, and they do not agree two-to-one the way the review assumes - they
  agree two-to-one AGAINST the C.** Checked all three:

  | | what it does | 100 + 100 |
  |:--|:--|--:|
  | Python, `export.py:303` | `q = clamp_i8(q.astype(np.int64) + res)` | **127** |
  | RTL, `res_feeder.v` + `residual_add.v` | clamps to [-128, 127] | **127** |
  | C, `mobilenet.c:135` | `out->data[idx] = requantize_elem(...) + target->data[idx];` assigned to `int8_t` | **-56** |

  `clamp_i8` in Python is `np.clip(a, QMIN, QMAX)`. So Python - which is the head of this
  project's chain of trust, the thing the quantization was designed in and the thing export.py
  validates the manifest against - clamps. The RTL agrees with Python. The C is the only one
  that wraps, and it wraps by C's implicit-narrowing rules rather than by a decision anyone
  wrote down.

  That reframes the finding. This is not "pick the authoritative semantics"; the authoritative
  semantics were already picked, in Python, and the C model departed from them silently.

- **Why it has never shown up.** The golden vectors are generated from the C, and `accel_tb`
  compares the RTL against those vectors and passes at 6,895,780 elements - so on THIS
  checkpoint no residual sum leaves int8 range, in any of the four residual layers, for the test
  image. That is exactly the "on real data it fits" argument, and DD-019 is the record of that
  argument failing: the 2026-07 retrain gave one channel a bias of 1,184,089 and 2.2M elements
  went wrong in silence. A retrain that pushes one residual sum to 130 would make the C and the
  RTL disagree, and the first symptom would be a golden-vector failure in a layer nobody
  touched.

- **Recommendation: correct the C to clamp, and add the RTL check the finding asks for.**
    1. `software/cmodel/src/mobilenet.c` `residual_add`: clamp the sum with the existing
       `clamp_i8` before storing, so C matches Python and the RTL.
    2. Regenerate the golden vectors. **This is the part that needs care**, and it is why this DD
       exists rather than just a patch: the vectors are the chain of trust, and the rule for this
       whole review has been that they are never edited to make a test pass. Regenerating them
       after a deliberate, approved C fix is a different act from editing them - but it must be
       done as its own commit, with the diff inspected and reported. My expectation is that the
       regenerated vectors are BYTE-IDENTICAL, because the clamp changes nothing that this
       checkpoint reaches; if they are not identical, that is a finding in itself and I stop and
       report rather than proceeding.
    3. Add the `` `ifndef SYNTHESIS `` check in `res_feeder` that L-13 asks for: report when the
       pre-clamp sum leaves [-128, 127]. Then a future retrain that reaches the disagreement is
       reported by name instead of silently diverging.
    4. Rewrite `residual_add.v`'s header, which currently defends the wrap with the measurement
       argument.

- **What I will NOT do without being told to.** Change the RTL to wrap. It would match the C and
  contradict Python, and it would mean a real activation of 130 becoming -126 in hardware - a
  sign flip in a residual path, which is the worst place in the network for one.

- Consequences if accepted: an edit to `software/cmodel/src/mobilenet.c`; a regeneration of the
  golden vectors with the diff reported (expected empty); a simulation check in `res_feeder.v`;
  a header rewrite in `residual_add.v`. If L-11 is also approved, `residual_add.v` is deleted
  instead and only `res_feeder` gets the check.

### DD-026 - L-11 / L-14: two dead modules, and whether to delete them
- Status: **Accepted** - KEEP both, marked as verified reference models; L-14 fixed in place.
  Nothing deleted.
- Date: 2026-09-24
- Context: L-11 says `conv1x1.v` and `residual_add.v` are both dead - no RTL instantiation -
  with `residual_add` deliberately so (documented at `res_feeder.v:18`) and `conv1x1` superseded
  by `mac_lane`; both are still referenced by testbenches and headers, "so they read as live".
  L-14 says `residual_add` contains a SECOND independent copy of L-4's `shift - 1'b1` underflow,
  with no live impact because the code is dead, but "the same defect now exists in two files and
  only one is on a fix list".

- The state of play, verified: neither module is instantiated by any RTL. Both have their own
  passing testbenches (`conv1x1_tb`, `residual_add_tb`), and both are named in the `Run:` lines
  of other testbenches' headers, which is why they still look alive.

- **The two options, and why this is a judgement call rather than a defect.**

  **Delete both.** Removes L-14 for free - the duplicate shift underflow goes away with the file
  rather than having to be fixed twice and kept in sync. Removes two testbenches from the suite
  (31 -> 29). The cost is that `conv1x1` is the only remaining *independent* implementation of
  the dot product that `mac_lane` computes; `conv1x1_tb` is a second opinion about the same
  arithmetic, and Phase 2a's pipelining was checked against it.

  **Keep both, marked.** A header line on each saying REFERENCE MODEL - NOT INSTANTIATED, and
  L-14 fixed in `residual_add` the same way L-4 was fixed in `requantize`. Keeps the second
  opinion. The cost is carrying two files that must not drift from the modules they shadow, and
  the review's own point stands: they currently read as live.

- **Recommendation: keep both, marked as reference models, and fix L-14.** The deciding argument
  is that this is a thesis: `conv1x1_tb` and `residual_add_tb` are evidence that the arithmetic
  was validated independently of the pipelined implementations that replaced them, and deleting
  the modules deletes that evidence from the repository even though it stays in the git history.
  L-14 costs one line to fix and the same guard already exists in `requantize`, so keeping the
  file is cheap.

  I would rather be told to delete them than delete them and be wrong, because the deletion is
  the irreversible direction and the marking is not.

- Consequences if "keep" is accepted: a header block on `conv1x1.v` and `residual_add.v` stating
  they are verified reference models with no RTL instantiation, and naming what each one shadows;
  L-14's `shift - 1'b1` guard added to `residual_add.v` matching `requantize.v`'s; the suite
  stays at 31. If "delete" is chosen instead: both `.v` files and both `_tb.sv` files go, the
  `Run:` lines that name them are corrected, L-14 closes as "removed with the file", and
  DD-025's `residual_add.v` header rewrite becomes unnecessary.


### DD-027 - T-6: the pointwise write address is a counter, and the tag is only watched
- Status: **PROPOSED** - awaiting approval, nothing implemented
- Date: 2026-09-24
- Context: T-6 says `pw_out`'s write address is a pulse counter while the tag is checked and not
  used to form it; that `acc_pix`/`acc_oct` arrive exactly the pipeline's depth ahead of
  `q_valid`; and that with T-3 already terminating the run on a tag mismatch, "detect but
  neither correct nor stop" is the one combination with no benefit. Its recommendation is to
  derive `aw_addr` from the tag, or act on `tag_error`.

- **The premise moved under this finding during Phase 1.** T-6 was written when the tag
  comparator reported and continued. T-3 was implemented in Phase 1: `pw_out` now terminates on
  a mismatch (`op_error` into `top_seq`, which faults). So the "no benefit" combination the
  finding describes no longer exists - the design currently DETECTS AND STOPS, which is one of
  the two dispositions T-6 asks for. T-6 is therefore not a live defect; it is a choice between
  two defensible designs, which is why it needs a decision rather than a patch.

- **The two designs.**

  **A - counter plus terminating check (what exists).** `aw_addr` counts `q_valid` pulses;
  `exp_pix`/`exp_oct` predict the tag independently and a disagreement stops the run. A drift is
  caught and the inference is abandoned.

  **B - tag-derived address (T-6's suggestion).** `aw_addr` is computed from `acc_pix`/`acc_oct`,
  delayed to `q_valid`. A drift becomes HARMLESS rather than fatal: the write still lands where
  the data belongs, because the address and the data travel together.

- **Recommendation: keep A, and do not implement B.** Three reasons, in order of weight.

  1. **B makes a class of bug invisible instead of fatal.** If the tag pipeline's depth is wrong,
     A stops and names the mismatch; B writes to whatever the tag says and produces a correct
     tensor from a broken pipeline - until the tag pipeline is wrong in a way that is NOT a pure
     delay error, at which point there is no check left, because the check has become the
     address. The whole content of Phase 2 was that latency bookkeeping errors are the failure
     mode of this design, and A is the thing that catches them. Four times this review a
     `*_LAT` was wrong and a witness said so by name; that is not a capability to trade away.
  2. **B costs an adder and a multiply on the writeback path.** `aw_addr` is
     `base_out + pix*n_ent + oct_half`, which is a multiply A gets for free by accumulating.
     The pointwise writeback is not on the critical path today, and I would rather not put
     arithmetic there while the design is at 202 MHz against a 250 MHz target.
  3. **A is already verified end to end.** `pw_out`'s comparator, `accel_tb`'s 6,895,780
     elements and the C-2 witnesses in the other feeders all exercise A. B would be new logic on
     the one path where a mistake writes to the wrong pool address, for no measured gain.

- What I propose INSTEAD, and it is small: `pw_out`'s header should state that the counter is
  deliberate and that the tag is a checker rather than a source, so the next reader does not
  re-raise T-6. The finding is closed as "considered, rejected with reasons" rather than fixed.

- Consequences if this recommendation is accepted: a header paragraph in `pw_out.v`; T-6 marked
  rejected-with-reasons in the final report. If B is chosen instead: `aw_addr` derived from the
  delayed tag, `n_ent` needed in `pw_out` (it is not there today), the drift check keeps its
  terminating behaviour anyway because it costs nothing to keep, and a new implementation run to
  confirm the writeback path still closes.

### DD-028 - T-8: the classifier's duplicate requantize datapath
- Status: **PROPOSED** - awaiting approval, nothing implemented
- Date: 2026-09-24
- Context: T-8 says `logit_out` duplicates the requantize datapath that `out_stage` exists to
  eliminate - the consolidation DD-015 justified as "634 -> 442 DSPs, one block to verify instead
  of five" - as 4 lanes / 8 DSPs with its own parameter registers; that it is a second copy which
  must stay bit-exact and which no shared testbench covers; and that it inherits L-3's timing
  problem plus a combinational 4-way argmax. Recommendation: parameterize `rq_bank`'s OUT_W and
  route LINEAR through `out_stage`, or accept the split and add explicit cross-verification.

- **What has changed since the finding was written**, both halves measured:
  * **The timing half is gone.** At Phase 2c the post-route worst path ENDED in
    `u_log/cls[2].u_r/quantized_reg` - the classifier's own requantize - which is what made T-8
    load-bearing rather than tidy. After L-3 (Phase 2d) and A-1 (Phase 3) nothing in `logit_out`
    appears in the worst-path list at all; the path is the `act_buffer` URAM cascade. So routing
    LINEAR through `out_stage` would buy no clock frequency.
  * **The bit-exactness half is now structurally handled.** L-3 gave `requantize` its own
    `q_valid` and Phase 5's C-10 gave it a `flush`; `logit_out` takes both from the module rather
    than re-deriving them, so the two copies cannot drift on depth or on flush behaviour - which
    is where a duplicate actually diverges. `lin_datapath_tb` covers the classifier path
    end to end (accumulators, logits and the predicted class, all bit-exact), and `accel_tb`
    covers it as op 63.

- **Recommendation: accept the split, and record why, rather than route LINEAR through
  out_stage.**

  The reason is OUT_W. `out_stage` produces `TM*DATA_W` = 32 int8 activations destined for the
  activation pool; the classifier produces `NLOG*LOG_W` = 4 int16 logits destined for a register
  the PS reads. Parameterizing `rq_bank` on OUT_W is easy; making `out_stage` carry a 512-bit
  int8 word AND a 64-bit int16 word, with two different writeback destinations and two different
  valid meanings, is not a consolidation - it is a multiplexer in the one block DD-015 created to
  avoid having five of them. The saving would be 8 DSPs out of 944 and four parameter registers,
  against making the shared block conditional on opcode.

  What T-8's second option asks for - "explicit cross-verification" - is the part worth having,
  and two thirds of it now exists: the shared `q_valid`, the shared `flush`, and
  `lin_datapath_tb`. What is missing is a test that the two copies agree on the SAME input, which
  is the actual risk. I propose adding that to `rq_bank_tb`: instantiate a `requantize` at
  OUT_W=16 beside the bank's OUT_W=8 lanes, drive both with identical (acc, m0, shift) and assert
  that the int16 result equals the int8 result wherever the int8 does not saturate. That is a
  direct test of "the second copy computes the same arithmetic", which no existing test makes.

- Consequences if accepted: a cross-verification test in `rq_bank_tb`; a header paragraph in
  `logit_out.v` recording that the split is deliberate, what makes it safe (shared q_valid,
  shared flush, the cross-check) and what would change the decision (a second int16 consumer, or
  the classifier returning to the critical path). T-8 closes as "accepted split, cross-verified".
  If instead LINEAR is routed through `out_stage`: `rq_bank` gains OUT_W, `out_stage` gains a
  second output word and a second valid, `accel_top`'s writeback mux grows a case, `logit_out`
  reduces to argmax plus the logit register, and every layer testbench needs re-checking because
  the shared block's behaviour becomes opcode-dependent.

### DD-029 - C-11: the weight buffer has no second bank, and the header says it does
- Status: **PROPOSED** - proposal only, per the review's own scoping. Not recommended for this
  review.
- Date: 2026-09-24
- Context: C-11 says `wgt_buffer`'s header claims the fill "is meant to be overlapped with the
  previous layer's compute (double buffer)"; there is no second bank and `top_seq` is strictly
  serial; `features.18.0` spends 25,600 fill cycles against 39,200 compute, 65% overhead with
  none of it hidden. It also notes the fix "requires C-3", which Phase 5 has now done.

- **The cost, computed over the whole network rather than the worst layer.** From
  `gen_program.py`'s own numbers: the weight blob is 2,194,880 bytes and the buffer holds 800 of
  1024 entries worst case. Fill cycles are the blob divided by the load width; compute cycles are
  what `analyze_workload.py` reports per layer. The worst single layer is the one C-11 names, but
  the network total matters more for a thesis claim about throughput, and that number is not in
  the review. It should be measured before anyone builds a second bank.

- **Why this is proposal-only and not recommended now.** Three things, and the third is the
  decisive one.
  1. It is a THROUGHPUT change, not a correctness one, and this review's remaining budget went to
     correctness by decision (DD-023 records the same call for the clock).
  2. It needs a second physical bank: `wgt_buffer` is 800/1024 entries at TM banks of TN width,
     so a second bank is close to doubling the largest BRAM structure in the design. Current
     utilization is 178 of 312 BRAM tiles (57%). A second full bank may not fit, and "may not
     fit" has to be answered by synthesis before any RTL is written.
  3. **It changes what `busy` means, and that is where this design has been bitten repeatedly.**
     Prefetching the next layer's weights while the current one computes means `top_seq` issues a
     load for op N+1 while op N is still running - so the sequencer stops being strictly serial,
     and `op_busy`, `ld_req`/`ld_done` and the parameter banks all become concurrent with compute.
     DD-017 exists because `busy` meaning the wrong thing cost the last two pixels of every
     pointwise layer. T-10's `ld_done` edge case, T-7's triple-meaning `ld_pchan` and C-3's
     shape latching are all in the same area, and all three were fixed in this review on the
     assumption of serial execution. Double buffering is the change that tests every one of them
     at once.

- **Recommendation: do not implement in this review.** If it is picked up, the order should be:
  measure the network-wide overhead first; then synthesize a second bank alone to see whether it
  fits; then implement the prefetch, with C-3's shape latching (now done) as the precondition the
  finding names. Correcting the header is worth doing NOW and independently - it currently
  describes a double buffer that does not exist, which is the kind of comment that makes a reader
  trust a capability they do not have.

- Consequences if the header fix alone is accepted: one paragraph in `wgt_buffer.v` stating that
  the fill is serial, what it costs on the worst layer, and that C-11/DD-029 is the record of why.
  C-11 closes as "documented, deferred with a plan".

### DD-030 — The parameter blob's DDR addressing: three regions, not one interleaved record
- Status: Accepted
- Date: 2026-09-25
- Context: the weight DMA is the first thing that has to actually *read* the parameter blob out of
  PS-DDR. `top_seq` hands it `(ld_off, ld_bytes, ld_pchan)`, and `ld_off`/`ld_bytes` describe the
  weight blob only — there is deliberately no parameter offset in the instruction, because ops
  execute in program order and a running index advanced by `ceil(pchan/TM)*TM` after every load is
  sufficient (`gen_program.py`, "the two blobs the DMA reads"). What the instruction does *not*
  settle is that the parameters are **three separate arrays** on disk — `params_b.hex` (32-bit
  bias), `params_m0.hex` (32-bit multiplier), `params_shift.hex` (8-bit shift) — while
  `param_buffer` has **one** write port that takes bias, m0 and shift *together*
  (`param_buffer.v:74-79`, one packed `{wr_shift, wr_m0, wr_bias}` per bank). Something has to
  bridge those two facts, and where it is bridged is the decision.
- Decision: **three DDR regions with three base-address registers** (`pb_base`, `pm_base`,
  `ps_base`), read as three sequential streams per TM-channel tile into a 32-entry staging buffer,
  which is then emitted as TM `pl_*` writes. `gen_program.py` and the export format do not change.
- Rationale: four reasons, strongest first.
  1. **It adds no second source of truth.** The three `.hex` files are what `export.py` writes and
     what `gen_program.py` already *validates* — it checks each layer's three parameter files are
     all exactly `pchan` long and pads to `ceil(pchan/TM)*TM` with explicit zeros. An interleaved
     blob would be a fourth artefact encoding the same numbers, with its field offsets living in
     the RTL and its layout living in a new emitter. This project has already paid for that class
     of drift twice: DD-019 (a retrain silently invalidating measurements) and the stale
     `software/golden/image_1` set found in Phase 6, whose *missing* checkpoint hash walked past
     the guard written to catch exactly that.
  2. **The parameter path is 1.1% of the traffic.** Weights are 2,194,880 bytes; the parameter
     blob is 19,264 channels × 9 bytes = 173,376. In cycles: ~192,000 bank writes for weights
     against ~37,000 for parameters over the whole 64-op network. Optimising the smaller number's
     bus efficiency buys nothing that can be measured.
  3. **Interleaving wastes 44% of every record.** bias + m0 + shift is 4+4+1 = 9 bytes; the record
     has to be 16 to make one beat one channel. 308 KB in DDR against 173 KB, to save cycles on
     the path that item 2 says does not matter.
  4. **Three bases are three CSRs later.** The AXI-Lite block (a separate open item) gains three
     32-bit registers instead of one, and the PS-side layout stays "three files, three memcpys",
     which is what the export directory already looks like.
- Alternatives considered:
  - **One interleaved 16-byte record per channel.** Rejected — but it is the option that is
    *simpler in RTL*, and that has to be said plainly. One beat would carry one channel's complete
    parameters: no staging buffer, no stream switching, and the parameter phase would collapse to
    "read `npad` beats, emit one `pl_*` write per beat". The three-region choice pays for its
    cleanliness with a 32-entry staging buffer (32 × (32+32+8) = 2,304 bits of LUTRAM) and a
    three-way stream sequencer inside `wgt_dma`. The trade is ~2.3 Kbit and one state machine
    against inventing a binary format with no other consumer. That is the whole argument, and it
    is a judgement call, not an obvious win.
  - **Three concurrent read streams, interleaved on the R channel.** Rejected on the protocol.
    AXI4 removed AXI3's read-data interleaving: beats of one transaction are contiguous, and
    out-of-order return is per-ID only. Serving three streams at once would need three ARIDs plus
    a descriptor queue to reattribute beats — significant logic, for the 1.1% path.
  - **Buffer the whole op's parameters, then emit.** Rejected on size: the deepest op is GAP at
    `pchan` 1280, so 1280 × 72 bits = 92 Kbit of staging against 2.3 Kbit for one tile.
- Why a staging buffer is unavoidable here: `param_buffer` writes one bank per cycle with all
  three fields in one word, and a 128-bit beat of `params_b.hex` carries 4 channels' bias and
  nothing else. The three arrays cannot arrive together on one in-order read channel, so the
  first two have to wait somewhere for the third. One tile is the smallest "somewhere" that keeps
  the emit loop's `pl_bank = ch % TM` / `pl_addr = ch / TM` mapping trivial.
- Also recorded here: **`ld_op`, and what it does to T-7.** The DMA needs the opcode and could not
  get it. `accel_tb` reads `u_dut.op_code` hierarchically; an AXI master at the pin boundary
  cannot, and the opcode is *not* derivable from the load fields — `taps = ld_bytes/ld_pchan` is
  1280 for the LINEAR op and there is no `taps` value that separates PW from LINEAR, yet those two
  route their parameters to different ports (`pl_*` versus `lg_pl_*`). So `top_seq` now exposes a
  4-bit `ld_op`, held valid alongside `ld_req`, and `accel_top` passes it through. It is the same
  bits as `op_code`, deliberately: the point is not new information, it is that the load
  handshake's contract becomes a *group* — `{ld_op, ld_off, ld_bytes, ld_pchan}` — instead of a
  reader having to know that `op_code` happens to be stable during `S_LOAD`. Against T-7's three
  meanings of `ld_pchan`: meaning (3), the stem's oc-tile count, was closed in Phase 5
  (`accel_top.v:347-380`, derived structurally as `POOL_TM/TS`); meaning (2), `top_seq`'s `no_load`
  decision, is unchanged and unreachable in this program; meaning (1), the DMA's parameter count,
  is now **real** rather than hypothetical, and `ld_op` is what stops it also having to imply the
  shape and the destination port.
- **What it actually cost, measured after the fact.** The estimate above said the parameter path
  is 1.1% of the traffic and that optimising it "buys nothing that can be measured". The traffic
  claim holds; the *cycle* claim was too generous, and the honest number is worth recording.

  Each TM-channel tile needs three sequential streams - 8 beats of bias, 8 of m0, 2 of shift - and
  each pays an AR turnaround before its first beat, because a single ARID with in-order attribution
  means the next stream cannot be requested until the current one has drained. Measured on the
  params-only GAP op (`pchan` 1280, 40 tiles, no weights at all): **3,656 cycles for 1,280
  parameter writes, 2.85 cycles per channel**, against ~1.0 cycles per weight word. Over the whole
  64-op network that is roughly 55,000 of the 199,285 load cycles `accel_dma_tb` reports:

  | | writes | share of load cycles |
  |:--|--:|--:|
  | weights | ~142,900 | ~73% |
  | parameters | ~19,200 | **~27%** |

  So the three-region choice spends 27% of load time on 12% of the writes. The interleaved
  16-byte record would have made one beat one channel: one stream, no staging, no AR turnaround
  per tile, and the parameter phase would have been roughly 1.0 cycles per channel instead of 2.85
  - about 42,000 cycles saved out of a 1,151,347-cycle run, or **3.6% of the inference**.

  That does not change the decision, and the reasoning is unchanged: 3.6% is not worth a fourth
  encoding of data `export.py` already writes and `gen_program.py` already validates. But the
  original entry implied the cost was unmeasurable, and it is not - it is small. If the parameter
  path is ever revisited, the cheaper fix is not the interleaved record: it is issuing the three
  streams for tile *n+1* while tile *n* is being written, which needs a descriptor queue but no
  change to the blob format at all. That is the thing to try first.

- Revisit if: the parameter path stops being 1.1% of the traffic — a model with a 1000-class head
  would make the classifier's parameters 1000 channels instead of 4, still negligible, so the
  realistic trigger is a *per-pixel* or per-tile parameter scheme rather than per-channel. Or if
  AXI-Lite register space becomes tight enough that three bases versus one matters, which it will
  not. Or if the staging buffer ever shows up in a utilization report, which at 2,304 bits it
  will not.

### DD-031 — The AXI-Lite register map, and where the result gets latched
- Status: Accepted
- Date: 2026-09-25
- Context: after DD-030 the accelerator could fetch its own weights, but nothing could
  *operate* it. `accel_sys` still exposed `start`, `n_instr`, four DDR base addresses and the
  whole 42-bit program-load port as pins with no driver; `accel_dma_tb` drove them from a
  testbench. `firmware/README.md` has always said the PS "configures the PL accelerator over
  AXI-Lite, runs inference, reads the result" — this is the decision about what that interface
  actually is. No register map existed anywhere in the repository, so there was nothing to
  honour and everything to choose.
- Decision: a 13-bit (8 KB) AXI4-Lite slave, `hardware/rtl/axi/axi_lite_csr.v`, wired to
  `accel_sys` by a third top, `hardware/rtl/top/accel_axi.v`. Thirteen 32-bit registers at
  `0x00`–`0x30` and the 512 program words as a 2 KB **aperture** at `0x1000`. An `irq` output
  driven by the sticky status bits under an enable mask.

- **The part that is not bookkeeping: the result has to be latched, and this is the only place
  left to do it.** `logit_out.v:212-217` states plainly that it does not hold its output:

  > "requantize's output register free-runs, so `logits` only ever means anything in a
  > `logits_valid` cycle... it deliberately does not turn `logits` into a latched output,
  > because that would move `logits_valid` by a cycle."

  That is the right call *for logit_out* — moving `logits_valid` would have been worse — but it
  means a register somewhere has to convert a one-cycle event into readable state, and a
  processor polling over AXI cannot be the thing that does it. Finding T-10 had already noticed
  half of this and described the failure exactly: "a poll that arrives between `start` and the
  first `logits_valid` gets a complete, plausible, four-class answer belonging to the previous
  image. That is the worst shape a stale value can take: not an x, not a zero, but last frame's
  confident prediction of a healthy leaf." T-10's `stale` gate closed the window from `start` to
  the first result by zeroing it; the CSR's latch closes the rest, holding this image's answer
  until the next `start`. Between the two there is no window in which `RESULT_LO/HI` reads as
  anything but zeros or this inference's logits.

  `done` is the same problem in miniature: a one-cycle pulse from `top_seq` that a polling PS
  would essentially never observe, so `STATUS[1]` is sticky.

  `axi_lite_csr_tb` case 7 tests this specifically, by pulsing `logits_valid` with one value and
  then **changing `logits` while valid is low** — which is what requantize's free-running
  register does on real hardware. A testbench that drove `logits` once would pass against a
  plain wire.

- Rationale for the shape of the map:
  1. **An aperture for the program, not an address/data register pair.** The program is 2 KB
     written once per boot, so the PS side is a plain loop over an array with no pointer state
     to get out of step. A pointer register one word behind produces a program that *executes* —
     the same class of failure T-1 and the checkpoint-hash guard exist to make impossible, and
     not introducing another one is worth 2 KB of address space that costs nothing.
  2. **`N_INSTR` resets to zero.** `top_seq`'s T-1 check refuses `n_instr == 0` and raises
     `fault`, so a PS that forgets to write it gets a loud refusal instead of an assumed 64 that
     happens to be correct for this network today.
  3. **`SLVERR`, not silent acceptance**, on six conditions: an unmapped address (read or
     write), a write to a read-only register, a program or config write while `running`, a
     partial program word (`WSTRB != 0xF`), a read of the write-only program aperture, and START
     while running. The repository's convention is that a silent wrong answer is the outcome
     worth spending logic to avoid, and a bus error is the loudest thing a slave can say to a
     processor. In particular the program-while-running case turns T-10's silently *dropped*
     write into a reported one.
  4. **AW and W are captured independently.** The compact form — asserting both readies only
     when both valids are present — deadlocks against a master that waits for `AWREADY` before
     driving `WVALID`. AXI4 forbids a master from doing that, but "correct against every legal
     master" is worth fifteen lines in the one module a processor talks to.

- **The guard that is not obvious, and is the reason this module is the right place for it:
  START while `running` must be REFUSED, not ignored.** `top_seq` only looks at `start` in
  `S_IDLE`/`S_ERR`, so a mid-run START appears harmless. But `wgt_dma`'s `start` is
  *unconditional* and resets its running parameter index to zero. A mid-run START would
  therefore leave the sequencer running while every subsequent parameter load read from the
  wrong place in the blob — and the run would **finish**, with wrong biases from that layer
  onward. The CSR is the only place that can see both modules at once, so it is where the
  refusal belongs. `axi_lite_csr_tb` case 12 drives it and checks that `start` did not pulse.

- Alternatives considered:
  - **Fold the CSR into `accel_sys`** rather than adding a third top. Rejected for the same
    reason `wgt_dma` is a sibling of `accel_top` and not inside it: it would have meant
    rewriting `accel_dma_tb` to drive AXI-Lite, and the entire value of that testbench is that
    it changes exactly *one* thing against `accel_tb`. Three tops cost three XDCs and three
    synthesis runs; they buy the ability to say which layer a number belongs to.
  - **The image load over AXI-Lite too**, via an auto-incrementing data register, which would
    have made `accel_axi` a complete board-ready top immediately. Rejected as a stopgap that
    would then have to be removed: 50,176 single writes is 1–2.5 ms against 5.8 ms of inference,
    17–43% overhead, and the right answer is a second AXI4 read channel sharing `wgt_dma`'s
    burst logic. It is the next item of work and `im_wr_*` stays a port until then — the one
    remaining non-AXI port group, 41 of `accel_axi`'s 354 port bits.
  - **Poll-only, with no interrupt.** The `irq` line is ten lines of logic and a PS that prefers
    polling leaves `IRQ_EN` at zero and ignores the pin, so there was no reason to refuse it.
  - **Returning OKAY and zeros for unmapped reads**, which is what many CSR blocks do. Rejected
    on the same ground as (3): a PS built against a stale map should find out.

- Consequences: `accel_axi` is 354 port bits, of which 196 are the AXI4 master, 114 the AXI-Lite
  slave, 41 the image load, and 3 are clock, reset and interrupt. There is nothing on the module
  that is not an AXI interface, a clock, a reset, an interrupt or the image. `STATUS_CLR` cannot
  clear a sticky bit whose source is still asserted — the copy re-sets on the next cycle — which
  is deliberate and means the only way out of a `fault` really is a new run, matching what
  `top_seq` and `wgt_dma` already do with their own sticky bits.
- Revisit if: the image load path lands, at which point `im_wr_*` disappears and this becomes the
  board top with no other change. Or if a second consumer needs the register block, which would
  make the fixed `0x1000` aperture offset worth parameterising further than `CSR_ADDR_W` already
  does. Or if the PS ever needs to *read* the program back for a bug report, which would mean
  giving `top_seq`'s program memory a read port — it has none today, which is why the aperture is
  write-only.

### DD-032 — The image load: HWC in DDR, on the weight DMA's master
- Status: Accepted
- Date: 2026-09-26
- Context: after DD-031 `accel_axi` had exactly one port group that was not an AXI interface, a
  clock, a reset or an interrupt: `im_wr_*`, 41 bits, the image load. 224×224×3 = 147 KB that the
  PS has to get into `img_buffer` before every inference. Two questions had to be answered
  together — what layout the PS writes into DDR, and which master reads it.

- **Decision 1: the DDR layout is HWC (interleaved), not CHW (planar).** The PS writes byte
  `(y*IW + x)*CIN + c` for channel `c`.

- **Decision 2: `wgt_dma` reads it, over the same AXI master as the weights.** No second master
  and no arbiter. The module keeps its name.

- Rationale for HWC — and it is the rare case where both sides get simpler:
  1. **It is one sequential stream.** `img_buffer`'s write port takes `CIN*DATA_W` = 24 bits, one
     pixel per entry, `wr_data[c*8 +: 8]` = channel `c`. With HWC, three *consecutive* DDR bytes
     are exactly that word, so the image reuses the byte-granular realigner already in `wgt_dma`
     with `need = CIN` and no new gather logic at all.
  2. **CHW would need three concurrent streams 50,176 bytes apart** — precisely the AXI4
     read-interleaving problem DD-030 had to solve for the parameter blob with per-tile staging,
     and there the records were 4+4+1 bytes rather than 50 KB apart.
  3. **It is also what the PS already has.** A JPEG decoder produces interleaved RGB. CHW would
     force the PS to transpose what its decoder handed it in the right order, to make the
     hardware's job harder.

- **The contrast with DD-030 is the point of this entry.** That decision faced the same question —
  interleave or keep planar — and answered it the other way. The difference is not taste:
  - In DD-030 the artifact **already existed on disk**. `params_b.hex` / `params_m0.hex` /
    `params_shift.hex` are written by `export.py` and *validated* by `gen_program.py` against each
    layer's `pchan`. Inventing an interleaved fourth blob would have been a second encoding of
    numbers that already had one, and this project has twice paid for that class of drift
    (DD-019, and the stale `image_1` golden set found in Phase 4).
  - Here the buffer is **produced at run time** by firmware that does not exist yet. There is no
    artifact to preserve and no validator to keep in step, so the convenient layout is free.

  The golden `software/golden/*/000_input.hex` stays CHW, untouched. `axi_ddr_model.svh`'s
  `load_img` transposes when it fills the model — deliberately in the model rather than in the
  testbench, because the model *is* the PS-side contract and the transpose belongs beside the
  little-endian parameter packing it sits next to. `wgt_dma_tb` then computes its expectation from
  the CHW golden *independently*, indexed the long way round, so a swapped index shows up as a
  mismatch instead of cancelling out.

- Rationale for one master rather than two:
  1. **They are never concurrent, and one master makes that structural.** The image is loaded
     *before* `start`; the weights are read *during* the run. With one master there is no bus to
     contend for. Two masters behind a mux would be correct only for as long as the PS behaved,
     and "correct while the software behaves" is what the CSR's guards exist to stop relying on.
  2. **No duplicated realigner.** The two-beat window and the byte barrel shift are the fiddliest
     logic in `wgt_dma`; a second copy is a second place for an off-by-one that only shows up on
     an unaligned base.
  3. Measured cost of the image phase: a state, a pixel counter, `need = CIN`, one write port.

- **The name did not change, and that is deliberate.** `wgt_dma` now loads weights, parameters
  *and* the image, which is broader than its name. DD-030, DD-031 and three dated lab-notebook
  entries all refer to `wgt_dma`; rewriting dated records to tidy a name is worse than a name that
  needs one sentence of explanation, and that sentence is in the module header.

- **The image size is structural, not a register.** `CIN * IDEPTH` bytes and `IDEPTH` writes,
  derived from the parameters `img_buffer` is built with, with an elaboration check tying them.
  Deliberately *not* a CSR field: a PS that wrote the wrong pixel count would half-fill the image
  buffer and the run would complete, on a tensor built partly from the previous picture. That is
  the failure shape T-7 is about, and the fix is the same — do not let a number that can be wrong
  decide a shape the hardware already knows. An `IMG_PIXELS` register is the extension point if a
  variable input size is ever wanted, and it would need a bound check against `IDEPTH`.

- **One new guard, and it is the same class as DD-031's START-while-running.** `START` is refused
  while `img_busy`, and `LOAD_IMAGE` is refused while `running` or while a load is already in
  flight. The stem reads `img_buffer` from its first cycle, so starting on a half-written image
  produces a complete, plausible feature map built partly from another photograph, and nothing
  downstream could notice. `img_busy` is high from the moment the request is *latched*, so there is
  no window in which a polling PS can see "not busy" between writing LOAD_IMAGE and the load
  beginning.

  Related: `img_done` is a one-cycle pulse that fires **only on success**, rather than the CSR
  deriving "loaded" from `img_busy` falling. `img_busy` also falls when a bus error abandons the
  load, and those two must not read the same to a PS.

- Alternatives considered:
  - **The image through the AXI-Lite CSR**, as an auto-incrementing data register. It would have
    made `accel_axi` a complete board-ready top a day earlier, with no new AXI logic at all.
    Rejected as a stopgap that would then have to be removed: 50,176 single AXI-Lite writes is
    1–2.5 ms against 5.8 ms of inference, 17–43% overhead, where the DMA is 50,176 cycles ≈
    0.25 ms, about 4%. Measured: `wgt_dma_tb` case 12 does the whole image in 50,193 cycles,
    **1.00 pixels per cycle even with the slave inserting R-channel holes** — the write rate is
    floored by `img_buffer`'s single 24-bit port, not by the bus, since 3 bytes per cycle are
    consumed out of 16 available.
  - **A separate `img_dma.v` plus an AXI read mux.** Honest naming and smaller files, at the cost
    of a duplicated AR generator, FIFO and realigner (~120 lines) and a mux whose correctness
    depends on the PS never overlapping a load with a run.
  - **Factoring out `axi_rd_stream.v`** shared by both — which is the condition `wgt_dma`'s own
    header said would justify the split it originally declined. Still declined: the second consumer
    lives in the same module and is covered by the same testbench, so a separable module would gain
    a name and no coverage, and it would refactor 1,300 lines of verified RTL mid-feature.

- Consequences: `accel_axi` drops from 354 to **313 port bits — 196 AXI4 master, 114 AXI-Lite
  slave, and 3 for clock, reset and interrupt.** There is nothing else on it. That makes it
  droppable into a block design wired to the PS's `S_AXI_HP` and `M_AXI_HPM`, and
  `accel_axi_ooc.xdc` has no placeholder input delays left. `accel_sys` goes 499 → 493 (41 bits of
  image out, 35 of image control in). The remaining gap to a board result is not RTL: it is the
  implementation run that proves it fits and closes timing with the PS in the picture.
- Revisit if: frame pipelining is ever wanted — loading image *n+1* while inference *n* runs would
  make the two phases concurrent and break the "one master is enough" argument, needing either a
  second master or a proper arbiter, plus a second image buffer. Or if the input size becomes
  variable, per the `IMG_PIXELS` note above. Or if a camera replaces the SD-card path, in which
  case the pixel source changes but the HWC layout is if anything more natural.

### DD-033 — Preprocessing in C: bit-exact, because the dataset turned out to make it possible
- Status: Accepted
- Date: 2026-09-27
- Context: the project's headline verification claim is "6,895,780 elements bit-exact", and it was
  measured **from `software/golden/<set>/000_input.hex` onward** — i.e. from the already-quantised
  input tensor. Everything in front of that tensor (JPEG decode, `Resize(256)`,
  `CenterCrop(224)`, `ToTensor`, `Normalize`, quantise) was done by torchvision on a PC and covered
  by no check anywhere. `firmware/README.md` said so and called it a gap worth naming. With the PS
  application in place, that gap was the last thing standing between the repository and an
  end-to-end claim.

- **The decision turned on a measurement, and the measurement changed the decision.** The expected
  outcome was *not* bit-exactness. `Resize(256)` on a PIL image uses Pillow's antialiased
  resampler, whose filter support scales with the reduction ratio; reimplementing it in C to the
  last bit is not a reasonable thing to attempt, and a first probe confirmed a naive bilinear
  differs from it substantially. So the plan was a **bounded difference** — implement a
  reasonable resize in C, characterise the error, and state it honestly.

  Then: **all 13,089 images in `data/grape` and `data/grape_clean` are 256×256.** Every one.
  `Resize(256)` is therefore the *identity*, and `CenterCrop(224)` is a pure integer crop at offset
  `(256−224)/2 = 16`. **No pixel is ever interpolated in this pipeline.** The front end is a crop
  plus a per-pixel map, and both are exactly reproducible in C.

  That is the whole entry. Had the measurement not been taken, the repository would contain a
  resampler, a tolerance, and a weaker claim — all of it unnecessary.

- What was built:
  - **`firmware/src/preproc.c`** — crop at offset 16, then
    `q = clamp(round((p/255 − mean[c]) / std[c] / input_scale), −128, 127)`, written in the
    manifest's order rather than folded into one constant (the fused form is algebraically equal
    and not bit-equal). Output is HWC, which DD-032 already chose for the DMA's sake and which pays
    again here: both buffers are walked forwards.
  - **`scripts/gen_preproc_vectors.py`** — the measurement, kept as a tracked script rather than a
    scratch probe, because it is what the design rests on. It re-derives each golden set's
    `000_input.hex` from its source JPEG and reports the match; all five reproducible sets come out
    bit-exact, 150,528 values each. It also writes `000_rgb256.bin`, the decoded source image, as
    the C test's input vector.
  - **`firmware/test/test_preproc.c`** — 16 cases. Case 5 is the one that matters: all 150,528
    values equal to the tracked golden set's tensor.

- **The 768-entry table is not an optimisation with a correctness cost.** The map depends only on
  `(channel, byte)`, and both are finite, so there are exactly 3 × 256 = 768 possible results.
  Tabulating them is the arithmetic *evaluated over its entire domain*, not an approximation of it —
  and the hot loop becomes a byte load and a byte store, 768 float operations instead of 150,528.
  Because "it is the same function" is the entire justification, `preproc_self_test` checks all 768
  entries against the direct double computation, and `main.c` calls it at start-up.

- **A claim this repository previously made twice, and which is false.** Both `firmware/README.md`
  and the first draft of `preproc.c`'s header warned that `floor(x + 0.5)` differs from
  `torch.round` "enough to flip a borderline classification". The domain is 768 points, so this was
  settled by enumeration rather than argument: **the two spellings agree at every one of them**, and
  the nearest approach to a `.5` tie is `6.4e-05` — about `3e11` double ulp away. Substituting
  `floor(x + 0.5)` passes the golden check bit-for-bit, which was verified by doing it.

  `lrint` is kept anyway, for a reason that survives scrutiny where the old one did not: it matches
  the reference **by construction** rather than by a margin, and that margin is a property of *this*
  `input_scale`. Requantise the model and a value could land on a tie, at which point code that was
  only accidentally right becomes wrong in a way no test here would predict.

  What *does* bite is a different concern entirely: a target FPU left in **round-toward-zero**.
  Truncation differs from rounding across most of the domain rather than only at ties, and a host
  test can never catch it because the host is in `FE_TONEAREST`. Hence the `fegetround` check.

- **What is deliberately still not claimed**, because the honest boundary matters more than a
  bigger number:
  - **The JPEG decode.** `libjpeg`'s IDCT is not bit-defined; two conforming decoders may differ in
    the last bit, so there is nothing to be exact *against*. It stays on the PC
    (`scripts/send_image.py`), and the board is handed decoded RGB. One clearly-bounded step,
    outside the embedded path rather than hidden inside it.
  - **Any image that is not 256×256.** `preproc_rgb` takes `w` and `h` *precisely so that it can
    refuse one*. A camera or an arbitrary photograph would need a resampler that no check here
    covers, and the tempting fallback — a naive bilinear — is exactly the thing already measured not
    to match Pillow. A refusal is a visible failure; a plausible wrong tensor is not. This is the
    same reasoning as DD-032's refusal to make the image size a CSR field.

- Alternatives considered:
  - **Leave preprocessing on the PC permanently.** It was already there and already correct. Rejected
    because it leaves the deployed system unable to classify an image without a PC running
    torchvision, which undercuts the point of an embedded accelerator — and because the measurement
    above made the C version cheap.
  - **Implement a full Pillow-compatible resampler**, so arbitrary images work. Rejected as
    substantial work (support scaling, per-axis passes, fixed-point coefficient tables) for a
    capability nothing in this project needs: the dataset does not require it, and the refusal path
    makes its absence loud rather than silent. Noted as the extension point if a camera is ever
    fitted.
  - **Fixed-point instead of double.** Tempting on an A53 and unnecessary — the table means only 768
    float operations run per boot, so the hot loop has no arithmetic in it at all. Fixed-point would
    have risked a different answer for no measurable gain.
  - **Hand-writing the constants into a C header.** Rejected for the reason DD-030 gives about the
    blobs: a second copy of a scale is how a deployed tensor ends up silently different from the one
    the goldens were made with. `firmware/include/quant_params.h` is generated by
    `gen_program.py --emit` from `manifest.json`. It is *also* committed, since the Vitis build and
    `make test` both need it — so `test_preproc` checks every constant in it against the manifest,
    the way `test_csr_map` checks `accel_csr.h` against the RTL. Verified to bite: permuting two
    class names fails, and so does moving the scale.

- Consequences: the verification chain now joins end to end — **RGB in → the golden tensor → 6.9 M
  elements bit-exact → the argmax** — with the JPEG decode named as the one link outside it.
  `img_src` carries a format per frame instead of assuming one (UART magic `'IMG1'`/`'IMG2'` with the
  length checked against it; SD infers from the file length; DDR takes a build-time knob), and
  `send_image.py --rgb` sends decoded RGB for the board to preprocess. `--rgb` and `--image` reach
  the same tensor by completely different routes — C on the board versus torchvision on the PC — so
  on a live board they are a cross-check on each other.

  Verified to bite, since a test that cannot fail is worse than none: crop offset 16 → 15 breaks
  142,927 of 150,528 values; RGB → BGR breaks 97,576.

- Revisit if: a camera replaces the file path, which is the case that needs a verified resampler and
  is the reason the refusal exists. Or if the model is requantised — `test_preproc`'s manifest check
  will catch a stale header, but the `lrint` margin above should be re-measured rather than assumed
  to survive. Or if the input size becomes variable, which would interact with DD-032's note about
  `IMG_PIXELS`.

### DD-034 — Accuracy: split by LEAF, three ways, and the test split scored once
- Status: Accepted
- Date: 2026-10-13
- Context: the only accuracy figures in the repository were 100.00% float and 100.00% int8, from
  `data/grape` — a split **per file** of a set that holds rotated and flipped copies of every image,
  so copies of one image sat on both sides. `resplit_dataset.py` had produced `data/grape_clean`
  (one original per image id, split 80/20 by id) on 2026-07-22, and it was believed leak-free;
  nothing had been measured on it. Two more things were wrong with the protocol itself: there was no
  test set — `train.py` chose the checkpoint on val and printed that same val accuracy as "the float
  baseline" — and the deployed checkpoint (`268f85f714d3`) records `best_acc: 1.0` but not what it was
  trained on, so its numbers could not be re-derived by anyone.

- **The measurement that changed the plan.** Before building a third split on top of `grape_clean`, a
  near-duplicate scan (a 64-bit difference hash under all eight rotations and flips, over the 4,062
  originals) found no identical pair — but its closest pair, `HL 9127` / `HL 9129`, two different
  image ids in the healthy class, is the **same physical leaf** photographed twice. That led to
  PlantVillage's own leaf grouping (`leaf_grouping/leaf_maps` in spMohanty/PlantVillage-Dataset), which
  covers every diseased grape image:

  ```
  3,639 diseased images  ->  910 leaves, four photos each, as consecutive frame numbers
                             (292/295, 336/346, 263/269 leaves exactly consecutive)
  grape_clean            ->  532 of those 910 leaves on BOTH sides of its split (2,128 images)
  ```

  So `grape_clean`'s validation set was mostly other photos of leaves the model had trained on. The
  first fix had removed the augmented copies and kept the larger leak.

- Decision:
  - **The unit of splitting is the leaf.** Black Rot, ESCA and Leaf Blight are grouped by
    PlantVillage's leaf maps; leaves are shuffled (seed 42) and split 70/15/15 within each class. The
    maps are pinned to upstream commit `40789680` by sha256 and **not committed** — the upstream
    repository declares no licence — so they live in `data/` beside the images.
  - **Healthy has no leaf map**, so it is split into contiguous **frame ranges**: every mapped leaf
    occupies one unbroken stretch of the frame sequence (no two of the 910 interleave), healthy was
    visibly shot the same way, and so a leaf can only cross a split at a cut. Each of the four cuts sits where margin and lobing change between two
    frames, which no rotation or exposure can explain (`6150|6151`, `6181|6182`, `9062|9063`,
    `9090|9091`) — not at the nominal 15% marks, where consecutive frames look alike. Both photo
    sessions (6020–6212 and 8903–9132), which look visibly different, contribute to every split.
  - **Three splits, each with one job.** train trains; val only chooses the epoch (best accuracy,
    ties to the lower loss — val accuracy saturates at 1.000); test is scored **once**, by
    `evaluate.py --split test`, after the checkpoint and the int8 scales are fixed. The training
    recipe is unchanged (20 epochs, SGD 0.01 cosine, batch 32), so val selects and nothing is tuned.
  - **int8 accuracy is the integer pipeline's**, `export.py`'s `IntExecutor` — the arithmetic the RTL
    reproduces bit for bit — not the fake-quant proxy (DD-009). `evaluate.py` builds it through the
    same `build_int_plan()` the exporter now uses, and checks the checkpoint's provable accumulator
    bound (DD-019) against the RTL's `ACC_W`, because the integer numbers are the hardware's only if
    nothing overflows. A re-export of the deployed checkpoint after that refactor is byte-identical
    to `software/export/` in all 213 files the exporter writes.
  - **Two intervals, because the photos are not independent.** 95% Wilson per image (each photo an
    observation: too narrow) and per leaf (each leaf once: conservative). Wilson rather than
    ±1.96σ because it stays inside [0,1] and is not zero-width at 100%.
  - **The report is the source.** `evaluate.py --report` writes JSON; `scripts/thesis_numbers.py`
    turns it into the `\thAcc*` macros, which leave `manual_numbers.tex`. It warns in `numbers.tex`
    while the measured checkpoint is not the one `software/export/` is built from.
  - **Provenance.** Checkpoints now record their data and settings; `train.py` refuses to replace an
    existing checkpoint without `--overwrite` (its default `--out` is the deployed one — the DD-019
    retrain); `quantize.py` seeds its calibration, which drew shuffled, augmented batches unseeded.

- Result — the test split, scored once, on checkpoint `1b536a3033c8` (selected at epoch 10, val
  100.00%), from `software/runs/mobilenetv2_grape_leafsplit_test.json`. (Run a second time after
  `evaluate.py` was committed, only so the report's commit stamp names the code that wrote it; the
  evaluation is deterministic and both reports agree in every other field.)

  ```
  617 test images, 155 leaves      accuracy            95% CI per image   95% CI per leaf   macro-F1
  float                            99.84%  (616/617)   [99.09, 99.97]     [97.27, 99.99]    0.9987
  int8, the integer pipeline       99.68%  (615/617)   [98.83, 99.91]     [96.98, 99.97]    0.9974
  ```

  Both errors are Black Rot ↔ ESCA; Healthy and Leaf Blight are perfect. The float error
  (`ESCA 1828` → Black Rot) is the over-exposed one of its leaf's four photos — the other three are
  right. **int8 and float disagree on one image** (`Black Rot 0400`), on which the float model was
  itself nearly tied, 0.586 against 0.414: the second-smallest margin of the 617, and only 3 test
  images have a float margin below 0.5. The quantisation cost one decision, at the decision boundary
  — 0.16 points.

  The new checkpoint's provable accumulator bound is **8,971,923 (25 bits)**, set almost entirely by
  one folded bias — channel 80 of `features.9.conv.0.0`, 8,590,995, against a layer median of 4,337 —
  the DD-019 failure mode again. It fits `ACC_W = 26` with a 3.7× margin, so these int8 figures are the
  accelerator's for this checkpoint; and it is a second retrain moving the bound (24 → 25 bits), which
  is DD-019's point: the bound was recomputed and checked, not remembered.

- Alternatives considered:
  - **Evaluate the deployed checkpoint on `grape_clean`'s val.** Rejected three times over: the split
    leaks leaves, val chose that checkpoint, and nobody can say what it was trained on.
  - **Recover healthy's leaf groups from the images.** Tried, measured against the leaf maps on the
    diseased classes, and rejected. An ImageNet MobileNetV2 embedding (best cosine over the eight
    rotations/flips) separates same-leaf from next-leaf frames with AUC 0.88 — a threshold that cuts
    no leaf misses 870 of 907 boundaries. SIFT on the leaf region with a RANSAC similarity fit finds a
    median of **2** inliers between photos of the same leaf, the same as between different leaves:
    at 256×256 there is no matchable vein texture. Frame ranges need no detector at all.
  - **Guard bands** (dropping a few frames at each healthy cut) instead of placing the cuts by eye.
    Unnecessary where the leaf visibly changes, and they cost data in the smallest class.
  - **k-fold cross-validation.** A steadier estimate, but five trainings for one number, and the
    hardware runs one checkpoint; a single held-out test ties the figure to the weights deployed.

- Consequences: `data/grape_leafsplit` (2,842 / 603 / 617 images) replaces `grape_clean`, which stays
  on disk unused; `data/README.md` says which folder is which. **The accuracy is measured on a
  retrained checkpoint, `mobilenetv2_grape_leafsplit.pth`, while `software/export/`, the golden
  vectors and every simulation are built from `mobilenetv2_grape.pth`.** Until those are regenerated
  from the new checkpoint, the accuracy and the bit-exactness results are about two different
  models, and the thesis must not present them as one — `thesis_numbers.py` writes a WARNING line
  into `numbers.tex` for as long as that is true.

- Revisit if: field photographs arrive — they are the real test of deployment, and they get their own
  number rather than being pooled; a leaf map for the healthy class turns up; or the export is
  regenerated from the new checkpoint, which closes the consequence above.

### DD-035 — The live camera on the board: Linux, a fifth platform hook, and a Pillow-exact resize
- Status: Accepted — built and tested on the PC; **not yet run on the board**
- Date: 2026-10-20
- Numbering: DD-034 is the accuracy entry on branch `accuracy-test-split`; this one follows it so
  the two branches merge without a collision.
- Context: the stretch tier — live camera → disease class — for the presentation, with the camera
  plugged into the **board** (option B) rather than into a laptop that relays frames over the UART
  (option A, ~2 s a frame). DD-033 had named exactly what this would need and left it out on
  purpose: a camera frame is not 256×256, so `Resize(256)` is a real resampling, and `preproc_rgb`
  refuses such a frame rather than guess at it.

- **Linux, because of the camera.** A UVC webcam needs a USB host stack and a UVC driver; the
  standalone BSP has neither. PetaLinux 2022.2 (matching Vivado 2022.2), built from the ZCU104 BSP
  plus our XSA, provides both — plus a DisplayPort framebuffer and the network — and keeps the
  bitstream in `BOOT.BIN`, so the PL is configured by the FSBL exactly as for baremetal. **The FPGA
  design does not change.** The board preset already enables USB 3.0, DisplayPort, Ethernet and SD
  (read back from the `.hwh` in the XSA).

- **A fifth platform hook, `accel_plat_phys`, and a new refusal, `ACCEL_ERR_ADDR`.** The driver
  wrote `(uint32_t)(uintptr_t)pointer` into the base registers. That is correct only where a pointer
  is a physical address — baremetal, by identity map. Under Linux it would point the DMA at an
  unrelated physical page and the run would complete on whatever was there: the failure shape this
  project designs out everywhere else. The driver now asks the platform, translates **all four**
  blobs before writing **any** base register (a refusal half way would leave a mixed set), checks
  the physical address fits the 32-bit registers end to end and is aligned, and refuses before
  `LOAD_IMAGE` otherwise. `plat_zynq.c` returns the pointer; `plat_linux.c` translates through the
  one region it mapped and refuses everything else. `test_drv_seq` gained six cases, with the mock
  deliberately mapping buffers to addresses that differ from their pointers, so a driver still
  writing pointers fails rather than passing by coincidence.

- **The DMA region: `no-map` reserved memory, mapped through UIO, never cached.** 16 MB at
  `0x3800_0000` (`firmware/linux/petalinux/vinecam.dtsi`), exposed with the CSR as one UIO device
  with two maps. `no-map` takes it out of the kernel's linear map, and UIO maps physical memory
  Device-nGnRnE — so no cache anywhere can hold a line of it, the baremetal flush becomes a `DSB`
  (wait for the writes to reach DDR before the CSR write that starts the DMA), and stale data is
  impossible by construction rather than by remembering to flush. The costs are known and accepted:
  every write must be an aligned store (`dmaregion_write`: 64-bit stores, verified in the
  disassembly — no `stp`, no `dc zva`, no `memcpy`), and the 150 KB image copy per frame runs at
  uncached speed, a millisecond or two. `vine_uio.c` refuses a region above 2 GB (HP0 reaches only
  DDR_LOW), unaligned, or listed as System RAM in `/proc/iomem` — the signature of a forgotten
  `no-map`.

- **The resize: Pillow's `Resample.c`, transcribed — the extension point DD-033 named.**
  `camfront.c` computes torchvision's `Resize(256)` (on a PIL image, Pillow BILINEAR with its
  antialiasing support) on just the 256×256 window whose centre is `CenterCrop(224)`, and hands
  that window to `preproc_rgb` unchanged. Evidence, all measured:
  - **15 frame sizes bit-exact**, 196,608 bytes each, against vectors that
    `scripts/gen_camfront_vectors.py` makes with the real torchvision 0.27.1 / Pillow 11.1.0 —
    which itself checks torchvision's crop offsets against `CenterCrop`'s output pixels and its
    resize against a direct `Image.resize`. Every common webcam size, an upscale, a portrait frame,
    and the half-to-even crop offsets.
  - **4 photographs** (two classes × 640×480 and 1280×720, a real dataset leaf in a camera-style
    frame): window *and* int8 tensor identical to torchvision + `export.py`
    (`tools/render_ui --dump` → `scripts/check_camera_frame.py`).
  - **Verified to bite**, nine deliberate mistakes:

    | mutation | 640×480 bytes that differ | caught |
    |:--|--:|:--|
    | xmin/xmax by `floor` instead of `(int)(v + 0.5)` | 126,196 | yes (12 checks) |
    | accumulator starts at 0, not the rounding half | 173,040 | yes (13) |
    | weights truncated to 22 bits, not rounded | **1,385**, each by 1 | yes (11) |
    | naive bilinear: support not widened when shrinking | 194,270 | yes (11) |
    | corner-aligned centres, `xx * scale` | 193,733 | yes (13) |
    | `filterscale` not clamped to 1 when enlarging | — (only the upscales) | yes (2) |
    | crop offset rounded half **up** | 194,198 | yes (20, 10 of them geometry) |
    | weights not normalised by their sum | 196,608 | yes (12) |
    | divide by `filterscale` instead of multiplying by its reciprocal | 0 | **no** |

    The last one was then settled by enumeration rather than argument, as DD-033 did for
    `floor(x + 0.5)`: the 22-bit weights are identical for every short side from 2 to 4096 and for
    21,283 long-side size pairs from common aspect ratios. The reciprocal stays because it is
    Pillow's form by construction, not by a margin belonging to these sizes. Likewise measured, not
    asserted: dropping the uint8 rounding **between** the two passes changes 36,863 of 261,888
    bytes, on a Python port that matches Pillow exactly with it.

- **A measurement that strengthens DD-033.** The reference normalises in float32 (`ToTensor`,
  `Normalize`, `quantize_input`), `preproc.c` in float64. DD-033 showed agreement on five golden
  images; that does not cover every input. All 768 (channel, byte) inputs now agree, and the
  float32 path never comes closer than **6.6e-05** to a rounding tie — so a camera frame's tensor
  can be required to match torchvision's byte for byte.

- **What stays outside the bit-exact chain, named:** the camera's YUV→RGB conversion (BT.601,
  OpenCV's integer constants), the camera path's equivalent of the JPEG decode. There is no
  reference to be exact against. A frame saved with `S` is saved *after* it, so
  `check_camera_frame.py` re-derives window, tensor and logits from the RGB the board actually used,
  and a frame that passes is one where the board's answer is provably the model's answer for that
  picture.

- Display and the talk: the DisplayPort monitor through fbdev (with the console switched to
  graphics mode so its cursor and messages stay off the picture), and `--http`, the same screen as
  a BMP to a browser on the presenting laptop — because the board's output is DisplayPort, a
  projector usually takes HDMI from the laptop, and a DP→HDMI adapter here must be an active one.
  The class names on screen come from the generated `quant_params.h`, and its softmax uses a new
  generated constant, `QP_LOGIT_SCALE` (manifest `s_logit`), which `test_preproc` checks against
  the manifest like every other constant in that header.

- Alternatives considered:
  - **Option A, the camera on the laptop** (frames over the UART). The least work, and it remains
    the fallback; rejected as the primary demo because the board is then not what sees the leaf, and
    at ~2 s a frame it is not live.
  - **A MIPI camera** through an FMC card and the CSI-2 / demosaic / frame-buffer IP chain. The
    ZCU104 has no MIPI connector of its own; weeks of PL work and re-implementation. Rejected.
  - **Certified Ubuntu or PYNQ images instead of building PetaLinux.** No Linux build, which is
    attractive on a Windows machine. Rejected: both load the bitstream at run time through a device
    tree *overlay*, and `reserved-memory` cannot come from an overlay (it is processed at early
    boot); PYNQ's route to DMA buffers is its own Python allocator, which would mean a second
    implementation of the driver's protocol — the duplication DD-030 argues against.
  - **u-dma-buf** (an out-of-tree kernel module) for cacheable buffers with explicit sync. Faster
    copies; one more kernel module to build and trust. Not needed at one 150 KB image per frame.
  - **Make the DMA coherent** (`S_AXI_HPC0_FPD` with coherent AxCACHE). The cleanest in principle,
    but a hardware change to a verified design, for a demo. Noted as the place to go if the copy
    ever matters.
  - **A naive bilinear "close enough" resize.** Exactly what the mutation table shows is not close:
    194,270 of 196,608 bytes differ.
  - **The interrupt** (`pl_ps_irq0`, SPI 89) instead of polling. The run is ~6 ms, shorter than a
    scheduler tick; polling, as baremetal does, with the poll limit raised to seconds.

- Consequences: the verification chain now reaches camera frames — **the RGB frame → the window
  (bit-exact against torchvision) → the tensor → 6.9 M elements bit-exact → the argmax** — with the
  YUV conversion named as the one link outside it, and the frame-dump check making it testable on
  any frame from the board itself. `vinecam` is one static aarch64 binary, so it needs nothing from
  the root filesystem.

- What is **not** yet true: nothing has run on a board. The PetaLinux build, V4L2, UIO, the
  framebuffer and the HTTP view are compiled (`-Werror`) but unexercised; the device-tree fragment
  was not compiled on the development PC (the Vitis `dtc` is a Linux binary), and `build.sh` checks
  the built `system.dtb` instead. The first board run is `vinecam --image image_q8.bin --expect
  EXPECTED.txt`, a known answer with no camera, before anything new is trusted.

- Revisit if: the board run shows the poll limit or the copy mattering (then u-dma-buf, or HPC0);
  a camera that offers only MJPEG has to be supported; a larger root filesystem makes U-Boot place
  the ramdisk over `0x3800_0000` (the kernel then refuses the initrd at boot — move the carve-out);
  or the model is redeployed from the leaf-split checkpoint (DD-034), which regenerates
  `quant_params.h`, `QP_LOGIT_SCALE` and the blobs, and needs the known answers remade.
