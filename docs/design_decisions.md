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