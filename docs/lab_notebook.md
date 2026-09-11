# Lab Notebook

A lightweight log of what you did, what broke, and what's next. One short entry per work session
keeps momentum and makes the methodology chapter far easier to write later.

## Template
```
### YYYY-MM-DD — <focus>
- Did:
- Found / decided:
- Blocked on:
- Next:
```

---

### 2026-06-06 — Project kickoff
- Did: set up the repo scaffold, the plan, and the design-decision log (DD-001–007).
- Found / decided: tiered scope locked; verification will run on golden vectors.
- Blocked on: nothing.
- Next: install Vivado/Vitis, boot the board, read a file from SD (Phase 0); email field contacts for real vine images.


### 2026-06-07 — Chose the fixed-point format
- Did: Made a scheme with the dataflow of bits through a layer
- Found / decided: 8-bit data width (int8 quantization)
- Blocked on: nothing
- Next: Send to Konstantinos for the images and start implementing the MobileNet-V2 in python

### 2026-06-07 — Contact with Konstantinos and started model training
- Did: I spoke with Konstantinos and started model training with the help of claude (float32 training)
- Found / decided: 
- Blocked on: nothing
- Next: Build the model for int8 operations.

### 2026-06-08 - Model Evaluation
- Did: Completed float model training and the evaluation of the model
- Found / decided: 
    Overall accuracy: 1.0000 (4062/4062)
    Per-class accuracy:
    black_rot            1.0000  (n=1180)
    esca                 1.0000  (n=1383)
    healthy              1.0000  (n=423)
    leaf_blight          1.0000  (n=1076)
- Blocked on: nothing
- Next: Build the model for int8 operations.

### 2026-06-11 - Building the int8 Model
- Did: Claude created the quantize.py file that does the training in int8 quantization
- Found / decided: 
   INT8   val acc: 100.00%   (drop +0.00 pts)
   black_rot    100.0%
   esca         100.0%
   healthy      100.0%
   leaf_blight  100.0%

wrote quant_scales.json  (53 layers)
- Blocked on: nothing
- Next: Continue with exporting the golden vectors from the reference model

### 2026-06-13 - Understanding quantization and build of export.py
- Did: I watched a video that explained quantization in cnns and understood what the claude build for phase 2.
- Found / decided: exported int8 weights, int32 bias, int8 M0 variables, golden vectors for each layer.
- Blocked on: nothing
- Next: Build the axi4 light stream, just to transfer some data from PS to PL.

### 2026-06-18 - Understanding phase 2 in process
- Did: I tried to wrote everything i have understood from phase 1 and 2 in phase2_export_.. file.
- Found / decided: --
- Blocked on: nothing
- Next: Build the axi4 light stream, just to transfer some data from PS to PL.

### 2026-06-20 - C implemantation of the model int8 pipeline
- Did: I fixed the make in my environment, I began to study a c implemantation of a simple cnn
- Found / decided: The c implemantation will help me understand better the whole model.
- Blocked on: nothing
- Next: Continue with the study.

### 2026-07-1 - Implemantation of quantization layer of c model
- Did: Implemented the quantize function in c
- Found / decided: The maths and the rounding that were used is: (acc * m0 + (1 << (shift-1))) >> shift and then a clamp function to produce the int8 number in the range of [-128,127]
- Blocked on: nothing
- Next: Continue by implementing the conv in c.

### 2026-07-03 - C model: manifest loader, golden diff harness, first three ops
- Did: Added the JSON manifest loader and the golden-diff harness to the C model, then
  implemented conv3x3_std, bias_add and dwconv3x3.
- Found / decided: manifest.json is the single source of truth for shapes, scales, strides and
  the file map (DD-008). The C model reads it instead of hard-coding anything, and the Verilog
  testbenches will read the same files later. Nothing about the network is duplicated in code.
- Blocked on: nothing
- Next: conv1x1 and the residual path.

### 2026-07-06 - conv1x1 in C
- Did: Implemented the pointwise convolution. Spatially it is the identity (stride 1, pad 0), so
  all that is left per output element is a dot product over the input channels.
- Found / decided: This shape (long, variable-length dot product) is what later pushed conv1x1.v
  to be a streamed single-MAC engine while dwconv3x3.v became a parallel tree.
- Blocked on: nothing
- Next: residual add.

### 2026-07-08 - Residual add in C
- Did: Implemented residual_add and added the original MobileNetV2 paper to docs/references.
- Found / decided: DD-009. The two branches carry different per-tensor scales, so they cannot
  just be added. The saved (skip) branch is requantized onto the main branch's scale with its own
  (m0, shift), then the two int8 tensors are added in int32 and saturated. Rescaling the skip
  branch is cheaper than rescaling the larger main branch. Known consequence: a second rounding
  on the skip branch, so the result may differ from the Stage-1 fake-quant model by <= 1 LSB.
  The integer executor is the authoritative spec, not fake-quant.
- Blocked on: nothing
- Next: the tail of the network.

### 2026-07-09 - C reference model complete
- Did: avgpool + the int16 classifier tail. The C model now runs the whole network end to end.
- Found / decided:
  - DD-010: global average pool is an int32 sum over the 49 positions, and the /49 is folded into
    the requantize multiplier M = S_in / (49 * S_out). No divider in hardware, the averaging comes
    for free inside a multiply-shift that was needed anyway.
  - DD-011: the classifier outputs are requantized to one shared int16 scale S_logit, so argmax
    over the 4 classes is a plain 4-way comparator.
- Blocked on: nothing
- Next: go back over the whole software model and verify it properly.

### 2026-07-24 - Software reference reviewed end to end
- Did: Went back over the whole software model layer by layer and confirmed the C output matches
  the Python golden for every dump.
- Found / decided: Phase 1 is closed. 74 ops in the manifest (52 conv, 10 save, 10 res_add,
  1 gap, 1 linear), 213 hex files, 66 golden vectors. From here the software model only gets
  read, never changed - it is the source of truth for everything that follows.
- Blocked on: nothing
- Next: start the RTL.

### 2026-07-26 - First RTL day: run_sim.sh, requantize, conv1x1, bias_add
- Did: Wrote scripts/run_sim.sh (xvlog -> xelab -> xsim wrapper that auto-detects Vivado), then
  requantize.v, conv1x1.v and bias_add.v, each with a self-checking unit testbench. Finished the
  day with the first integration testbench, pointwise_layer_tb: conv1x1 -> bias_add -> requantize
  reproducing the real layer features.1.conv.1 against golden 003, bit-exact.
- Found / decided:
  - The design principle for the whole accelerator: the engines do ONLY arithmetic. Addressing,
    windowing, padding, stride and feeding belong to the controller. That is what keeps every
    engine small enough to be trivially bit-exact.
  - run_sim.sh requires a POSITIVE "ALL PASS" marker to report success. The absence of errors is
    not enough, because a simulation that never started prints neither.
  - The signedness in requantize.v is load-bearing: a single unsigned operand silently turns the
    whole expression unsigned and breaks both the >>> and the comparisons.
- Blocked on: nothing
- Next: the depthwise and the stem.

### 2026-07-27 - The remaining four engines, with integration tests against real layers
- Did: dwconv3x3.v (parallel 9-tap), conv3x3_std.v (parallel 27-tap stem), residual_add.v and
  avgpool.v, each with a unit testbench and an integration testbench against a real layer:
  - dwconv_layer_tb                                    17920 elements
  - stem_layer_tb, features.0.0, stride 2 + zero pad   17920 elements
  - residual_layer_tb, features.3.add                  75264 elements
  - avgpool_layer_tb, 7x7x1280 -> 1280                 all 1280 channels
  All pass. That is all 7 arithmetic engines done and verified.
- Found / decided:
  - residual_layer_tb settled the clamp-vs-truncate question empirically. The C reference assigns
    the sum to int8_t, which truncates, while its own comment says "clamped". The RTL clamps, and
    all 75264 golden elements match - so the golden clamps too (or never overflows on real data).
    Kept the saturating clamp, since that is the standard quantized-add semantics.
  - The integration testbenches build the windows and the addresses by hand. That means they are
    already the specification of the controller: what the TB does with nested loops is what the
    FSM will do with counters.
- Blocked on: nothing
- Next: work out the controller.

### 2026-08-02 - Controller architecture study + mac_lane.v
- Did: Read Angel-Eye (TCAD 2018), WP486 and UG579, then wrote docs/controller_design.md - four
  candidate architectures with their sources, the ZCU104 resource table, a roofline analysis, the
  parallelism decision, and a detailed spec of the pointwise MAC array with a build plan. Then
  wrote mac_lane.v, step 1 of that build plan, plus its testbench.
- Found / decided:
  - Architecture: a program-driven controller with per-type sub-controllers, in the spirit of
    Angel-Eye. A top sequencer reads one instruction per op (op-type, shapes, stride, pad,
    addresses, m0/shift) and activates the right sub-controller. The op_type enum of the C model
    becomes the opcode, so the manifest is already most of the program.
  - Roofline: with the activations kept on-chip, the arithmetic intensity sits well above the
    ridge point, so the design is compute-bound. The bottleneck is the DSPs, not the memory -
    which means parallelism is the lever, not smarter data movement.
  - Size: P = 512 MAC/cycle (Tm=32 x Tn=16), about 256 DSP48E2 with int8 packing, roughly 15% of
    the chip. ~2.3 ms per inference at 250 MHz.
  - Memory: activations 100% on-chip in URAM with ping-pong between layers (largest feature map
    1.15 MB against 3.4 MB of URAM), so no activation tiling at all. Weights DMA'd per layer.
  - mac_lane_tb checks against TWO oracles at once: an independent reference sum computed in the
    testbench, and the already-proven conv1x1 engine. The same dot product is streamed 1/cycle
    into conv1x1 and Tn/cycle into the lane, and all three must agree. 24/24 pass.
- Blocked on: nothing
- Next: pe_array.v - Tm instances of mac_lane sharing one activation broadcast.

### 2026-09-10 - Picking the thesis back up after six weeks
- Did: Re-read the repo after a long gap, reconstructed the state of play, committed the August
  work (mac_lane.v + controller_design.md + the three new reference PDFs) which had been sitting
  untracked, and backfilled the July and August entries above.
- Found / decided: The weights figure in controller_design.md section 3 is wrong for this model.
  It says ~3.4 MB, which is the ImageNet MobileNetV2 (3.4 M parameters). Our classifier is
  1280x4 instead of 1280x1000, so about 1.27 M parameters are gone. Recomputed straight from
  manifest.json:
  - 299,499,392 MACs per inference, so the "~300 M" was right to within 0.2%
  - 2.19 MB of int8 weights + 0.07 MB of int32 bias, not 3.4 MB
  - 89.4% of all MACs are in the pointwise 1x1 layers, 6.9% depthwise, 3.6% stem - which is why
    the pointwise array is the right thing to build first
  The correction makes the design MORE compute-bound (intensity 124 MAC/byte against a ridge
  point of 72), so the P=512 decision stands and the throughput table is unaffected - it depends
  only on MACs, P and clock, not on the weights. Section 3 still needs editing.
- Blocked on: nothing
- Next: finalize Tm/Tn (32x16 vs 64x8 - Tn=8 divides every MobileNetV2 channel count, so less
  tail padding), fix the weights figure in controller_design.md, then write pe_array.v.

### 2026-09-10 - Closed the Tm/Tn decision, found the real bottleneck
- Did: Wrote scripts/analyze_workload.py, which replays the network from manifest.json and
  recomputes every architectural number - the roofline inputs, the Tm/Tn sweep, the tail-padding
  breakdown and the depthwise cycle count. Nothing is hard-coded, so the numbers follow if the
  network is ever re-exported. Then used it to settle the two open decisions and updated
  controller_design.md (sections 3, 5, 6, 8) and design_decisions.md (DD-013, DD-014).
- Found / decided:
  - **DD-013: Tm=32 x Tn=16, confirmed.** Ran the cycle model over all 35 pointwise layers:
    32x16 = 92.1%, 16x32 = 88.6%, 64x8 = 74.9%, 8x64 = 66.1%. The old note in the design doc
    argued for Tn=8 because 8 divides every channel count - true, but it only looks at the INPUT
    dimension. With P fixed, Tn=8 forces Tm=64, and MobileNetV2's bottleneck layers are narrow on
    output (OC = 16, 24, 32, 96), so the output dimension is where you lose. Small Tm + large Tn
    matches the network's asymmetry. mac_lane.v needs no change.
  - The remaining 7.9% of tail padding sits in five early layers with big H*W. A pixel-parallel
    fallback for OC < Tm recovers only 2.2% for real control complexity - rejected, and recorded
    as a measured cost rather than an unknown.
  - **DD-014: the depthwise is the real bottleneck.** At the current 1 element/cycle it would be
    9.21 ms against 2.27 ms for the whole 512-MAC pointwise array: 6.9% of the arithmetic
    becoming 70% of the runtime, with the big array idle. Depthwise has zero channel reuse, so
    the only axis to parallelize is channel count. Chose Tc=16 in a separate engine (~72 DSPs):
    depthwise drops to 0.58 ms, total 4.45 ms, ~225 fps. Kept separate rather than sharing DSPs
    with the pointwise array - the whole budget is ~380 DSPs, 22% of the chip, so sharing would
    buy complexity for a resource that is not scarce.
  - Worth remembering for the write-up: none of this is needed to hit the Core goal (one image
    from SD). Even the un-parallelized 76 fps is 70x more than required. The value of these
    decisions is a defensible throughput number and evidence that the bottleneck was located.
- Blocked on: nothing
- Next: pe_array.v - 32 instances of mac_lane sharing one 128-bit activation broadcast, with a
  unit TB against 32 independent dot products. Then the feeders.

### 2026-09-11 - pe_array.v: 32 lanes, 512 MAC/cycle
- Did: Wrote hardware/rtl/kernels/pe_array.v (build plan #2) and its testbench. 32 mac_lane
  instances sharing ONE broadcast activation tile, each with its own weight slice, giving
  Tm*Tn = 32*16 = 512 MACs per cycle. Pure structural wiring - no arithmetic of its own, all
  the math and the first/last/done handshake stay in mac_lane. 19 cases, 608 lane-checks, PASS.
- Found / decided:
  - Because pe_array is only wiring, the bugs it can have are wiring bugs: a lane reading
    another lane's weight slice, an accumulator landing in the wrong slot, taps swapped inside
    a lane, or a broadcast that is not really shared. Random data hides some of those - a
    symmetric mistake still sums to the right number - so the directed cases give every lane
    and every tap a distinguishable value: lane m weighted (m+1), one-hot taps, a single active
    lane, and identical weights across lanes (which forces all 32 accumulators to be equal and
    so proves the broadcast really is shared).
  - **Verified the testbench itself by mutation testing.** A test that passes proves nothing
    until you know it can fail, so I deliberately broke the DUT three ways and confirmed each
    was caught: (a) weight slices shifted by one lane, (b) acc slices shifted by one lane,
    (c) odd lanes seeing the two halves of `a` swapped. Worth noting which case caught what -
    (a) and (b) were caught by "lane identity", but (c) sailed through it (uniform weights make
    tap order irrelevant) and was caught only by "one-hot tap". That is exactly why both cases
    exist, and it is a good argument to reuse for the other engines.
  - `before` is a reserved SystemVerilog keyword - xsim rejects it as a variable name. Renamed
    to fails0.
  - done is taken from lane 0 rather than re-derived in pe_array: all lanes see the same
    valid/first/last so they run in lockstep, and sourcing it from a real lane keeps it aligned
    with acc by construction. The 31 unused done registers are pruned by synthesis.
  - Bus layout locked for the feeder: w[(m*TN + j)*DATA_W +: DATA_W] is lane m's weight for
    input channel j, i.e. oc-major / ic-minor, which is exactly the manifest's w[oc*IC + ic].
    The feeder can copy a contiguous run per lane.
- Blocked on: nothing
- Next: build plan #3, the feeders and buffers - activation buffer (NHWC banked), weight buffer,
  and the pixel / oc_tile / ic_tile address counters. Then #4, integration against the same
  golden the pointwise_layer_tb uses, but at 512 MACs/cycle and ACC_W=21.
