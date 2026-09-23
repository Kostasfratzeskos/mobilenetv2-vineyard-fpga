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
