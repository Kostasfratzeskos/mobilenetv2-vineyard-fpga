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

### 2026-09-12 - Build plan #4: the output half, and the first real integration
- Did: Finished the pointwise datapath and ran the whole of features.1.conv.1 through it,
  bit-exact against the golden. rq_bank (32 parallel bias_add + requantize), param_buffer
  (per-channel bias/m0/shift, banked by oc_tile), pw_out (the glue + writeback), and
  pw_datapath_tb, which wires pw_feeder and pw_out together on real data at the real
  ACC_W=21. 200,704 elements match the software model exactly.
- Found / decided:
  - **DD-015: R = Tm = 32 requantize units.** Measured with the new `requant` section of
    analyze_workload.py: R=16 is the knee on cycles (+6.6% for half the DSPs), but at
    R=32 an entire control path stops existing - no shadow register, no drain counter, no
    stall path back into addr_gen, and the 32 results already ARE the 256-bit word
    act_buffer wants. 32 extra DSPs is 1.9% of the chip; the logic they remove is a place
    for bugs. (The single layer R=16 would stall is features.2.conv.0.0 with IC=16 - the
    same outlier that forced the 256-bit activation entries. Third time that layer has
    driven a decision.)
  - The output-side write address needs no multiplier either, and for a cleaner reason
    than in the feeder: entries per pixel on the output side equal n_oc, which is also how
    many results each pixel produces, so results land on consecutive addresses forever.
    A counter incrementing once per write IS the address.
  - Since the tag is therefore NOT needed for addressing, it became a self-check instead:
    pw_out keeps its own expected (pix, oct) and raises a sticky tag_error on any
    disagreement. Cheap tripwire for the two pipelines drifting apart.
  - **The 21-bit accumulator is no longer an assumption.** The integration testbench
    computes the true int64 dot product over a sample of the layer: max |acc + bias| =
    20,888 against a limit of +-1,048,576, i.e. 5 bits of headroom. It FAILS if a layer
    would not fit, so every future integration re-measures this.
  - Mutation testing paid for itself again, twice. On pw_out it found two real holes in my
    own testbench: "acc not registered" passed because the testbench held the accumulator
    bus stable until the next result (the real pe_array reuses it immediately - feed() now
    scribbles the bus), and "tag check ignores pix" passed because the wrong-tag case had
    BOTH fields wrong. Both closed; all five mutations now caught.
  - Two testbench bugs worth remembering, both caught by the reference disagreeing with
    the DUT when the DUT was right: the parameter generator overflowed int32 for high
    channel indices (pl_m0 arrived negative), and earlier the wgt_buffer latency check
    read the same address twice so old and new data were identical by construction.
- Blocked on: nothing
- Next: build plan #5 - the depthwise engine at Tc=16 (DD-014) plus the line-buffer window
  generator, which is what finally replaces the hand-built windows in the dwconv and stem
  testbenches. After that #6, the top sequencer over all 74 ops.
### 2026-09-12 (later) - Build plan #5: the depthwise path, bit-exact
- Did: line_buffer, dw_array, dw_feeder, and the integration. The whole of
  features.1.conv.0.0 (401,408 elements) now matches the golden exactly, with each
  input pixel read ONCE instead of nine times. Also lifted act_buffer to the top
  level and gave it half writes, because the activation pool is shared with the
  pointwise path.
- Found / decided:
  - Corrected DD-014's cycle model. It counted OUTPUT pixels, but a line-buffer
    generator must consume every INPUT pixel to slide the window even at stride 2,
    and four depthwise layers are stride 2 where the input grid is 4x the output
    grid. The depthwise costs 1.63x more: 0.94 ms not 0.58, 19% of runtime not 13%,
    ~208 fps overall not 225. Tc=16 is still the knee, so the decision stands and
    only the numbers move.
  - act_buffer had to move OUT of pw_feeder. The activation pool is a shared
    resource - the depthwise reads and writes the same feature maps - and a second
    instance would duplicate 1.5 MB for nothing. wgt_buffer stayed inside pw_feeder
    because the pointwise weights genuinely belong to it; the depthwise weights are
    a different shape entirely (16 banks of 9 taps, not 32 of 16). The pointwise
    integration was the safety net for that refactor and still reported 200,704
    elements bit-exact afterwards - which is exactly what an integration test is for.
  - The depthwise output stage needed NO new RTL: rq_bank and param_buffer are
    parameterized by TM, so TM=16 instances serve it directly. DD-003 paying off.
  - Group-boundary hazard, and how it was avoided. The channel group has to be the
    OUTER loop, because line_buffer holds two rows of ONE group and switching
    mid-row would mean re-reading rows or keeping a line buffer per group (30 of
    them at C=960). So the weights and parameters change at group boundaries while
    the last windows of the old group are still in flight. Reading both memories
    EVERY cycle, addressed by the pipelined group index, removes the hazard;
    reading once per pass would need a 4-cycle drain per group, 6% of the 7x7
    layers with their 60 groups.
  - For depthwise ACC_W=21 is PROVABLY enough for the 9-tap sum (9*128*127 =
    146,304, 19 bits) rather than the data-dependent precondition it is on the
    pointwise side. The int32 bias still has to fit, so the integration measures
    |acc + bias| anyway: 11,833, six bits of headroom.
  - Two mutation-testing findings worth keeping:
    (a) Removing line_buffer's left-column clear passes the WHOLE testbench. The
        virtual column already injects a zero that arrives in the leftmost position
        exactly when the first window of the next row is emitted, so the clear is
        measurably redundant. Kept anyway, with the reasoning in the header:
        deleting it would make left-edge padding depend on the virtual-column
        invariant too, so a later change that skipped that column would break two
        things instead of one.
    (b) Tying aw_full high passed everything, because the monitor was checking the
        write BUS and wr_full only affects what is STORED. Added a read-back phase
        that reads the pool after the run and verifies both halves of sampled
        entries; it now catches that mutation on the first pixel. Lesson worth
        carrying: an integration test that never reads its own output back is only
        testing half the path.
- Blocked on: nothing
- Next: build plan #6, the top sequencer. All the compute is bit-exact now; what is
  left is the program that schedules the 74 ops of the manifest, plus the
  residual/avgpool/classifier tail and the stem's own feeder.
### 2026-09-12 (later still) - Build plan #6 complete: all six opcodes and the sequencer
- Did: finished every remaining feeder and the program sequencer. All six opcodes now
  have a bit-exact datapath against the golden vectors: STEM 405,408 elements, PW
  200,704, DW 405,568, RES_ADD 76,512, GAP all 1,280 channels, LINEAR the accumulators,
  the int16 logits and the predicted class. top_seq executes the real 64-instruction
  program from gen_program.py.
- Found / decided:
  - out_stage: ONE requantize stage shared by every feeder, because only one op runs at
    a time. Without it the budget was heading for ~634 DSP (37% of the chip); with it,
    442 (26%), and one block to verify instead of five. The nice part is that a 16-channel
    feeder uses the 32-lane bank by placing its results in lanes (g&1)*16 and reading
    parameters at g>>1 - the parameter banks and act_buffer's half write then line up with
    no rotation at all.
  - DD-015: R=32 requantize units. R=16 is the knee on cycles (+6.6% for half the DSPs),
    but at 32 an entire control path stops existing - no shadow register, no drain counter,
    no stall path - and the 32 results already ARE the 256-bit word act_buffer wants.
  - DD-016: TS=8 for the stem, derived from geometry rather than feel. 225x225 input
    pixels against 112x112 windows is exactly 4 input cycles per window, so ceil(32/TS)<=4
    means TS>=8. Past that the input streaming dominates and more DSPs buy ~3%.
  - res_feeder adds NO multiplier: the rescale of the skip branch is a requantize with
    bias=0, so it runs on out_stage and only 16 adders and saturations remain. gap_feeder
    adds no DSP either - 16 copies of avgpool.v, plain adders.
  - The classifier needed no new feeder at all. It IS a 1x1 conv (n_pix=1, n_oc=1,
    n_ic=80), so pw_feeder runs it unchanged and only the tail differs. requantize.v
    gained an OUT_W parameter so the same module does clamp_i8 and clamp_i16.
  - The tightest accumulator in the network is the classifier at 33% of the 21-bit range
    (355,971 of 1,048,575), because IC=1280 is the longest dot product. Every other layer
    measured sits below 3%. Worth re-measuring if the model is retrained.
  - Three mutations across this stretch were NOT caught at first and each exposed a real
    testbench gap rather than a design flaw: an integration that never read its own output
    back (fixed with a read-back pass), a sequencer test that checked decoded fields but
    not handshake ORDER (fixed by tracking what happens between op_starts), and a busy
    handshake that only looked redundant because every feeder built so far raises busy in
    exactly one cycle (fixed by giving the stub variable latency, which is the contract
    top_seq actually documents).
  - Two width traps, same failure mode both times: an expression narrower than its port
    leaves the top bits undriven in xsim and the memory reads X. Both were parameter
    addresses. Resizing now goes through an explicit wide intermediate.
- Blocked on: nothing
- Next: the datapath top that muxes the six feeders around the shared out_stage and the
  one activation pool, the weight DMA behind top_seq's ld_req handshake, and then Vivado
  synthesis - timing at 250 MHz and the real resource numbers are still unknown.

### 2026-09-13 - accel_top: the sharing becomes real, and two busy bugs
- Did: wrote accel_top.v (the datapath top) and accel_tb.sv (the first multi-op
  integration test), and fixed the two bugs it found. Also wrote run_all_sims.sh.
- Found / decided:
  - The DSP saving out_stage was factored out for had never actually been collected.
    out_stage was shared as a MODULE while every feeder still instantiated its own,
    so five 32-lane requantize banks were still being inferred. Making it real meant
    giving each feeder os_acc / os_acc_valid / os_param_addr out and os_q / os_q_valid
    back, and lifting the stage itself to the top. The five datapath testbenches now
    instantiate out_stage themselves, which means they exercise the same split
    accel_top uses - all five still bit-exact, so the split is faithful.
  - act and relu6_qmax went with it. Three feeders hardwired them (res/gap ACT_NONE,
    stem ACT_RELU6); with one shared stage they come from the instruction word, so
    what was an RTL property is now an obligation on gen_program.py. It already emits
    exactly those values, and accel_tb checks it against the real program.
  - DD-017, from accel_tb: `busy` has to mean "my writes have landed", not "I stopped
    reading". Four feeders had a ONE-CYCLE hole in busy - `drain` is loaded by
    layer_done, which pulses in the same cycle `run` drops, so for one cycle both read
    zero. top_seq leaves S_RUN on the first !busy, so it took the hole for completion
    and started loading the next layer's parameters over the scales the in-flight
    results were about to use. pw_feeder had the same bug in a different shape: no
    drain counter at all, because addr_gen exposes a busy of its own and wiring it
    straight to the port looked like plumbing rather than a decision. That one cost
    the last two pixels of every pointwise layer - 32 of 200,704 elements, which is
    exactly the kind of tail a spot check misses.
  - Both bugs needed a SECOND op to exist before they could do damage. No standalone
    testbench could have found them: they all wait on layer_done or run to a fixed
    time, so none ever samples busy at that cycle. This is the first thing the
    integration level has caught that the unit level structurally could not.
  - accel_tb now counts busy pulses - exactly one per op - so both stay fixed.
  - The three ops chain correctly on the allocator's addresses alone: op 1 reads from
    base=12544 with nothing telling it to except the instruction word.
- Blocked on: nothing
- Next: the weight DMA behind ld_req/ld_done, and a generator fix - RES_ADD and GAP
  are emitted with pchan=0, so top_seq takes its no_load path and never asks for the
  (m0, shift) they need, one value broadcast to every channel. That is why accel_tb
  stops at three ops rather than running all 64. Then Vivado synthesis: timing at
  250 MHz and the real resource numbers are still unknown.

### 2026-09-13 (later) - the whole network runs, bit-exact
- Did: extended accel_tb from 3 ops to all 64 and fixed the three things that stopped it.
  One image in, four logits out, every intermediate tensor compared: 6,895,780 elements
  bit-exact, logits -2278/11929/-6915/-2884 exactly as the software model, predicted
  class 1 = esca.
- Found / decided:
  - The DMA needs NO per-layer table. top_seq hands out (wgt_off, wgt_bytes, pchan), and
    taps-per-output-channel = wgt_bytes/pchan - 27 for the stem, 9 for a depthwise, and
    for a pointwise it is IC itself. So the same three numbers that say WHERE to read also
    say HOW to deal the bytes into banks. That was not designed in; it fell out of the
    instruction format and is worth keeping.
  - RES_ADD and GAP were emitted with pchan=0, so top_seq took its no_load path and never
    asked for their (m0, shift). They need one triple broadcast to every channel, so pchan
    is now the channel count and the parameter blob carries the constant repeated. No RTL
    change: no_load = (wgt_bytes==0 && pchan==0) already meant the right thing.
  - GAP was getting n_pix=1. The field means "spatial positions the feeder WALKS", which
    equals the output pixel count for every op except global pooling, where the feeder
    consumes h*w inputs to emit one. It was averaging a single pixel. 1157 of 1280 channels
    wrong - and ops 0..61 were all bit-exact, which is what made it obvious where to look.
  - The compiler now emits the two blobs a real DMA reads: weights.hex (random access by
    wgt_off) and params_*.hex (sequential, because ops run in program order). The parameter
    padding to a whole TM tile is IN the blob, so the DMA does no arithmetic beyond the
    round-up. weights.hex is gitignored - 8.8 MB that is a byte-for-byte concatenation of
    the per-layer files already tracked.
  - program_ops.svh is generated too, and cross-checks itself: the golden file comes from
    golden_manifest.json matched by name, and the shape it declares is compared against the
    shape the compiler derived independently by replaying the network. If those disagree
    the build stops - comparing against the WRONG tensor is the one failure a bit-exact
    check cannot see by itself.
  - FIRST REAL CYCLE MEASUREMENT: 951,833 cycles with a feeder busy = 3.807 ms at 250 MHz.
    The cycle model predicted 3.56 ms, so +7% - good agreement for a model with no pipeline
    fill/drain in it. 250 MHz is still a TARGET; nothing has been synthesised.
- Blocked on: nothing
- Next: the weight DMA itself (accel_tb shows the ld_req/ld_done interface is sufficient),
  then Vivado synthesis - timing and real resource numbers are still unknown.

### 2026-09-13 (later still) - first synthesis: the numbers stop being estimates
- Did: wrote scripts/synth.tcl + run_synth.sh + an OOC constraints file and synthesised
  accel_top for xczu7ev-ffvc1156-2-e. Two runs; the first one's failure told me what to
  change. Written up as DD-018.
- Found / decided:
  - Run 1, everything left to the tool: Block RAM 560 tiles of 312 = 179%, DOES NOT FIT,
    with all 96 URAMs idle. 191,372 LUTs (83%). Only 72 DSPs. WNS -7.123 ns.
  - The activation pool is 12.85 Mbit and the whole device has 11.0 Mbit of BRAM, so
    mapping it to BRAM cannot fit - and the tool did it anyway. Forced it to URAM.
    The multipliers were going to fabric too; forced them to DSP. Both are attributes,
    so xsim ignores them and all 31 testbenches stay valid exactly as written (checked).
  - Run 2: LUTs 191,372 -> 32,387 (14%). BRAM 560 -> 176 (56%). URAM 0 -> 52 (54%).
    DSP 72 -> 944 (55%). The design FITS.
  - 944 DSPs against the 442 the docs predicted. Not a surprise once looked at: 442
    assumed int8 packing, two MACs per DSP48E2, which was never implemented. Unpacked
    the count is 512 + 144 + 216 + requantize = 944. The estimate was right about the
    arithmetic and wrong about assuming an optimisation that does not exist yet.
  - TIMING GOT WORSE: -7.123 -> -17.357 ns. That is the real result. The worst path is
    65 logic levels with DSP_ALU=27 and DSP_OUTPUT=27 - a 27-deep DSP cascade with
    nothing registered inside it, which is the stem's 27 taps summed combinationally in
    one cycle. mac_lane does the same with 16. A DSP48E2 is only fast with its internal
    pipeline registers used, so forcing DSPs fixed area and exposed the real problem.
  - So 250 MHz is not reachable by constraint or attribute. It needs the MAC trees
    pipelined. Not doing that in the same change: latency is a contract that every
    feeder's drain counter, every busy deadline (DD-017) and every testbench's expected
    ordering depends on. It is its own build step, gated by the 6.9M-element end-to-end
    check still passing.
  - Also: my synth.tcl counted resources with get_cells -filter PRIMITIVE_TYPE because it
    looked tidier than parsing a report. It reported 8,496 DSPs and 0 LUTs where
    report_utilization said 944 and 32,387 - the filter matches sub-cells of a macro.
    Removed; run_synth.sh greps the report, which is authoritative.
- Blocked on: nothing
- Next: pipeline the MAC trees, re-synthesise, then place-and-route (the only thing that
  gives a real Fmax). The weight DMA is still outstanding too.

### 2026-09-22 - a second image, and what it found
- Did: made the testbenches image-agnostic, generated a golden set for a second image
  (a Healthy leaf), and ran the whole suite against it. Written up as DD-019.
- Found / decided:
  - FIRST: the export in git was five weeks older than the checkpoint on disk. The model
    was retrained 2026-07-22; `software/export/` was last regenerated 2026-06-15. Running
    export.py to make the new golden set moved the weights to the new checkpoint while
    accel_tb still loaded image_1's June goldens - 4.4M mismatches, starting at op 0.
    Neither artefact said which model it came from. Both manifests carry `ckpt_sha256`
    now, and gen_program.py refuses to build the testbench table if the two disagree.
  - `image_1` CANNOT be regenerated: its source file is gone from data/ (the dataset was
    resplit and the classes renamed), and the checkpoint it came from has been
    overwritten. The set the whole project was verified against for three months is
    unreproducible. Marked `stale` in its manifest; everything now uses healthy_hl6025.
  - SECOND, and the real finding: with weights and goldens finally from the same
    checkpoint, ops 0-5 were bit-exact and op 6 was wrong in exactly 3,136 of 451,584
    elements - one channel, every pixel, hardware 0 where the model said 63 (= the ReLU6
    ceiling). That is an accumulator wrapping negative and being clamped. Confirmed:
    features.3.conv.0.0 channel 110 has bias = 1,184,089, and ACC_W=21 holds +-1,048,576.
    The bias alone does not fit, for ANY image. See DD-019.
  - So the answer to "does a second image test anything?" is yes, but not for the reason
    I expected. It did not find a data-dependent edge case; it found that the accumulator
    was sized from a measurement rather than a bound, and the retrain had invalidated the
    measurement months earlier. Every run since 2026-07-22 would have been wrong the
    moment the export was refreshed.
  - ACC_W 21 -> 26. The provable bound sum|w|*max|a| + |bias| is 5,094,750 (24 bits) at
    classifier.1; 26 gives 6.6x margin and stays inside the DSP48E2's 27-bit operand, so
    the requantize multiply stays at 2 DSP/lane instead of 4. export.py computes the
    bound every run and exits non-zero if the RTL cannot hold it - verified by feeding it
    ACC_W=21, which it correctly refuses.
  - Two testbench bugs this exposed, both of the same kind - a constant typed in one
    place that another place was free to change: the input image and expected logits were
    hardcoded to image_1 while the compiler pointed elsewhere, and the expected class was
    hardcoded to "1 (esca)" so the failure message named the wrong class. Both are
    generated into program_ops.svh now, from the golden manifest.
- Result: ALL 31 testbenches pass on the current checkpoint, including the 6,895,780
  element end-to-end check. `[ok] logits -4950 -6177 15185 -5486 bit-exact`,
  `[ok] predicted class 2 = Healthy`.
- Synthesised, same day. ACC_W=26 costs +3,144 LUTs (+9.7%), +482 registers (+8.4%),
  +152 CARRY8, and ZERO DSPs, BRAM or URAM - measured against ACC_W=21 at the SAME 4 ns
  constraint. The first comparison I ran was 21 @ 4 ns against 26 @ 25 ns, which is two
  variables, and the relaxed constraint hid ~1,400 LUTs and 12.5 BRAM tiles of the real
  difference. Worth remembering: a relaxed timing constraint is not a neutral background,
  the tool spends the slack on area.
  My prediction was "about 160 flops" - low by 3x, because I counted out_stage's capture
  register and forgot pw_out's pipeline register, the feeders' delay lines and logit_out.
  Timing is marginally BETTER at 26 (WNS -17.279 vs -17.357 at 4 ns): the critical path
  is DD-018's DSP cascade, which the accumulator width does not touch.
  At the real operating point of 25 ns the design MEETS timing - WNS +3.706 ns, 0 failing
  endpoints of 92,611, Fmax 47.0 MHz.
- Found while doing it: scripts/synth.tcl had 4.000 hardcoded in its Fmax line while the
  xdc had moved to 25.000, so it reported "Fmax 3401.4 MHz - meets 250 MHz" for a design
  with +3.706 ns of slack. It reads the period off the design now. Same failure mode as
  the two testbench constants above, third instance this session: a value typed in one
  place that another place was free to change.
- One image per class, end to end. The question "will another image give correct
  results" has two halves and they have different answers, so both were measured.

  Bit-exactness against the software model - the accelerator's actual contract:

      image           class         argmax  logits                        result
      blackrot_0376   Black Rot     0       12405  -2762  -5686  -3679    ALL PASS
      esca_4399       ESCA          1       -8592  23216 -10575  -3925    ALL PASS
      healthy_6067    Healthy       2       -5175  -6069  14216  -4695    ALL PASS
      blight_1461     Leaf Blight   3       -1751  -7243  -4688  13659    ALL PASS

  6,895,780 elements each. All four argmax indices occur, so logit_out's 4-way
  comparator was exercised with every possible winner rather than always the same one.

  Accuracy, which is a different question and not the hardware's to answer -
  export.py --check 32, integer pipeline against float and against fake-quant:

      agree with FLOAT     model: 32/32
      agree with FAKE-QUANT model: 32/32

  So on this val sample quantization costs nothing in predicted class. Worth being
  precise about what that means: the accelerator reproduces the int8 model exactly,
  including any mistake it makes. "Correct prediction" is a property of the model,
  measured here, not of the RTL.
- Independent confirmation of the DD-019 bound, from the same --check run:
  max |accumulator| over 32 images = 1,209,578 (22 bits), against the provable bound of
  5,094,750 (24 bits) and ACC_W=26's +-33,554,432. Two things follow. Real data reaches
  only 24% of the bound, which is why a measurement looked safe for so long. And
  1,209,578 > 1,048,576, so ACC_W=21 would have overflowed across this sample too - the
  failure was never specific to one image.
- Audited the other fixed widths for the same failure mode - a width chosen from
  observation rather than from a limit. SHIFT_W=6 holds 0..63 against a model max of 48;
  M0_W=32 holds the fixed-point multipliers by construction (max 2,147,461,603, which is
  99.999% of the range because that is how a normalized fixed-point multiplier is built,
  not because it is close to breaking); BIAS_W=32 against max |bias| 1,184,089. All three
  are properties of the MODEL, not of the image, so no input can move them.
- Repo hygiene, both consequences of DD-019: the checkpoint is in Git LFS now (its LFS
  OID is its sha256, so it is literally the string the manifests carry), and exactly one
  golden set is tracked - the one hardware/tb points at. The rest are gitignored with
  the regeneration command in the comment, since export.py reproduces any of them byte
  for byte from the checkpoint. Verified: four re-exports in a row left all 215 weight
  files identical.
- Blocked on: nothing
- Next: the MAC-tree pipelining of DD-018, for which the async resets need to become
  synchronous first (DPIR-2, 10,940 warnings) or Vivado cannot fold the new registers
  into the DSPs.

### 2026-09-23 - Phase 0 of the RTL review: baseline, and a latency inventory
- Did: read all 28 RTL files, the 31 testbenches, `gen_program.py` and the XDC against
  `docs/references/rtl_review.md` (43 findings). Ran the whole testbench suite. Recorded the
  40 MHz baseline from the existing reports and started a second run at the real target.
  Wrote `docs/latency_map.md` - every constant in the design that encodes a pipeline depth,
  with what it depends on. Added `scripts/run_impl.sh` + `scripts/impl.tcl`, because until
  today place-and-route only existed inside a GUI project and a number that cannot be
  reproduced from a shell cannot go in the thesis.
- Tests, baseline: **31/31 testbenches pass**, including `accel_tb` at 6,895,780 elements
  bit-exact over 64 ops. So every Phase 2 regression from here is mine.
- Not Icarus. The review's flow and the task both say Icarus Verilog; the testbenches are
  SystemVerilog (`logic`, `localparam string`, `task automatic`) and the repo's own
  `run_sim.sh` drives xsim. Icarus is not installed and converting 31 testbenches would
  violate "existing testbenches keep their current language". Verification stays on xsim.
- Baseline confirmed the review's critical path EXACTLY, which is worth recording because it
  means the review was measuring this tree and not an older one:

  | | synthesis | post-route |
  |:--|--:|--:|
  | constraint | 25.000 ns (40 MHz) | 25.000 ns |
  | WNS | +3.706 ns | **+0.665 ns** (Fmax 41.1 MHz) |
  | worst path | `u_stem/win_q_reg[7]` -> `u_os/acc_q_reg[568]` | `u_stem/win_q_reg[0]` -> `u_os/acc_q_reg[474]` |
  | data path delay | 21.275 ns (logic 91%, route 9%) | 24.315 ns (logic 79%, route 21%) |
  | logic levels | 64 (DSP_ALU=27) | 62 (DSP_ALU=27) |

  LUT 34,159 / FF 6,171 / BRAM 163.5 / URAM 52 / DSP 944 at synthesis; 33,400 / 6,180 /
  163.5 / 52 / 944 post-route. The path is `conv3x3_std`'s 27-tap combinational cascade,
  exactly as the review says.
- Second baseline, at the real target. `PERIOD=4.000 bash scripts/run_impl.sh`, synthesis:

  | | 4.000 ns (250 MHz) |
  |:--|--:|
  | WNS | **-17.279 ns** (Fmax 47.0 MHz) |
  | TNS | -32,575.918 ns over 2,856 failing endpoints of 92,767 |
  | worst path | `u_stem/win_q_reg[7]` -> `u_os/acc_q_reg[184]`, 21.260 ns (logic 19.413 / 91.3%, route 1.847 / 8.7%), 64 levels, DSP_ALU=27 |
  | LUT / FF / CARRY8 | 35,531 / 6,187 / 937 |
  | BRAM / URAM / DSP | 176 / 52 / 944 |

  These reproduce DD-019's ACC_W=26 column exactly, which is the check that the two runs
  are the same tree (and that this baseline is the pre-Phase-1 tree: Vivado read the
  sources before the Phase 1 edits existed).

  And post-route at 4.000 ns, which is the number the acceptance test asks for:

  | | 4.000 ns post-route |
  |:--|--:|
  | WNS | **-18.821 ns** -> real **Fmax 43.8 MHz** |
  | TNS | -71,607.492 ns over 16,290 failing endpoints of 94,788 |
  | worst path | `u_stem/win_q_reg[7]_replica_1` -> `u_os/acc_q_reg[740]`, 22.801 ns (logic 19.371 / 85.0%, route 3.430 / 15.0%), 63 levels, DSP_ALU=27 |
  | LUT / FF / CARRY8 | 34,834 / 6,863 / 937 |
  | BRAM / URAM / DSP | 176 / 52 / 944 |

  Two things in there are worth keeping. The flip-flop count grew 6,187 -> 6,863 between
  synthesis and routing, and the worst path's source is `win_q_reg[7]_replica_1`: the tool
  REPLICATED registers chasing 4 ns, spending 676 flops on a path it could not fix. And the
  route delay went DOWN, 5.144 ns at the 25 ns constraint to 3.430 ns at 4 ns, because the
  tighter constraint made the placer pack the cascade tighter. So the honest Fmax is
  **43.8 MHz**, not the 41.1 MHz the 25 ns run reports - constraining at 40 MHz was costing
  about 2.7 MHz of pessimism on top of everything else. Neither number is within 5x of the
  target, and 19.4 ns of the 22.8 is logic that only L-1 can remove. Per DSP_ALU hop: 19.413/27 = **0.719 ns** at synthesis, 19.171/27 =
  0.710 ns of logic post-route, 0.901 ns including route. The review quotes 0.682 / 0.847,
  which is the same measurement divided by 28 hops rather than 27.
- Worth recording because it bounds what L-1 can be expected to prove: **all ten worst
  post-route paths are the same stem path.** `mac_lane`'s own 16-deep cascade and
  `requantize`'s chain never appear, so neither has ever been measured. L-3's "~9 ns" and
  L-1's "0.682 ns/hop" for the pointwise array are inferences from the stem's 27 hops, not
  observations of those modules. A-1 cites the route-delay growth 1.892 -> 5.144 ns as
  evidence for pe_array's unregistered 128-bit fanout-32 broadcast; that growth is on the
  STEM path, so it is evidence about spreading a 27-deep cascade across the die and says
  nothing about pe_array. Measure pe_array's own path before acting on A-1 - it is the one
  finding that contradicts a stated design constraint.
- Found, and it changes the plan: **T-5 is not only a safety item, it gates L-1.** Vivado
  says so itself, 10,940 times:

      DPIR-2: DSP u_dw/u_arr/ch[0].u_dw/acc0 input pin .../A[0] is connected to registers
      with an asynchronous reset. This is preventing the possibility of merging these
      registers in to the DSP Block since the DSP block registers only possess
      synchronous reset capability.

  L-1's whole point is to use the DSP48E2's own A/B/M/P registers. While every flop in the
  design is `posedge clock or negedge rst_n` (3,998 FDCE + 1 FDPE = the review's 3,999),
  Vivado cannot put a pipeline register inside a DSP - it would add fabric flops in FRONT of
  an unregistered cascade and buy nothing. The review has T-5 in Phase 1 for recovery/removal
  reasons only and never connects the two. Worse, the fix it prescribes (two-flop
  synchroniser, async assert / **sync deassert**) keeps `negedge rst_n` in every always block,
  so it does **not** clear DPIR-2. Getting L-1's DSP folding needs the datapath registers on a
  *synchronous* reset. That is a design-wide change and a DD, not a bug fix.
- Found, also not in the review: three registers where Vivado warns of a simulation mismatch
  in the same class as T-4 - `[Synth 8-7137] ... has both Set and reset with same priority` on
  `top_seq`'s instruction register `w[0:7]`, `out_stage`'s `acc_q` and `dw_feeder`'s
  `grp_wr_prev`. All three sit in an async-reset always block with no assignment in the reset
  branch. T-10 lists `acc_q` alone and for a different reason.
- Found: `act_buffer`'s URAM has no output pipeline register (`[Synth 8-6057]`), which is free
  at 25 ns and probably is not at 4 ns - and fixing it is a read-latency change, i.e. a Phase
  2 item the review does not list. Added to the latency map so it is not discovered mid-phase.
  Relatedly, `img_buffer` lands in BRAM (35.5 tiles) because URAM would need 3 pipeline
  stages (`[Synth 8-6793]`) - which is the concrete number T-10's "pin img_buffer's RAM
  style" is missing.
- Verified L-4 and L-5 by simulating `requantize`'s exact `half` expression over all 64 shift
  values rather than reasoning about Verilog's self-determined shift-amount rule: shift=0 ->
  half=0 (L-4 confirmed), shift=59 -> half=-2^58 (L-5's catastrophic case), shift 60..63 ->
  half=0. So L-5's "shift in [59,63] gives -2^58" is true for 59 only.
- Blocked on: nothing yet. Phase 1 needs no decision; Phase 2 needs the reset decision above.
- Next: the 4.000 ns baseline, then Phase 1 (T-1, T-2, T-5, T-3, T-4, then the assertion-only
  items). Phase 1 changes no datapath and no latency, which is the point - it makes Phase 2
  debuggable.

### 2026-09-23 (later) - Phase 1 of the RTL review: silent failures become loud
- Did: T-1, T-2, T-5, then T-3, T-4, then the assertion block - L-12, L-4/L-5, C-4, C-6,
  C-2 - in three commits. No datapath change, no latency change, and `docs/latency_map.md`
  section 1-3 has exactly the values it had before. That was the point: Phase 2 is where
  bit-exactness is easiest to lose, and this is the phase that makes losing it diagnosable.
- Tests: all 31 testbenches pass after every commit, `accel_tb` bit-exact at 6,895,780
  elements each time.
- Cost, measured at 4.000 ns against the Phase 0 baseline - the whole point being that the
  answer is "nothing":

  | | baseline | Phase 1 | |
  |:--|--:|--:|:--|
  | CLB LUTs, synth | 35,531 | 35,625 | +94 (+0.26%) |
  | CLB Registers, synth | 6,187 | 6,174 | **-13** |
  | WNS, synth | -17.279 ns | **-17.279 ns** | 0 |
  | worst path, synth | `win_q_reg[7]` -> `acc_q_reg[184]`, 21.260 ns | identical | identical |
  | CLB LUTs, post-route | 34,834 | 34,957 | +123 (+0.35%) |
  | CLB Registers, post-route | 6,863 | 6,702 | **-161** |
  | CARRY8 | 937 | 940 | +3 |
  | BRAM / URAM / DSP | 176 / 52 / 944 | 176 / 52 / 944 | **0** |
  | WNS, post-route | -18.821 ns | **-18.463 ns** | **+0.358 ns** |
  | TNS, post-route | -71,607 ns | -67,421 ns | +4,186 |
  | real Fmax | 43.8 MHz | **44.5 MHz** | +0.7 |
  | worst path, post-route | 22.801 ns (logic 85%) | 22.444 ns (logic 86%) | same path |

  +94 LUTs at synthesis buys a 20-bit watchdog, an S_ERR state, a sticky fault bit, an
  opcode-validity comparator and a reset synchroniser. Everything else - the L-12 range
  checks on 36 lanes, both C-2 address witnesses, the C-4 collision trap, the L-4/L-5 shift
  guard - is inside `ifndef SYNTHESIS` and costs exactly zero, which the identical
  DSP/BRAM/URAM columns confirm.

  The interesting column is post-route, where Phase 1 came out AHEAD: 161 fewer flip-flops
  and 0.358 ns better WNS. That is T-5 paying for itself twice. `rst_n` used to be a
  top-level pin fanning out to 3,999 asynchronous clear pins; it is now one net from two
  flops, so the tool needed fewer register replications to route it and had more room for
  the paths that matter. A correctness fix that also buys 0.7 MHz is not the usual trade.

- **T-4 is measurably fixed**: `WARNING: [Synth 8-589] replacing case/wildcard equality
  operator !== with logical equality operator !=` is gone from the synthesis log. It
  appeared twice before. The circuit that ships is now the circuit the testbench verifies.

- The three guards that found real things, which is the only evidence that a guard works:

  1. **C-2 rediscovered T-9 from the inside.** `accel_tb` reported the depthwise writeback
     address disagreeing with `line_buffer`'s own coordinates ONE CYCLE BEFORE the first
     depthwise op started. Tracing it: no `win_valid`, no `start` - the two `q_valid`
     pulses were the STEM's last results arriving on the shared `os_q_valid`, which is
     broadcast to all five feeders, advancing an idle `dw_feeder`'s `opix_off`. T-9 calls
     that "functionally correct" and it is, but only because `start` resets `opix_off` and
     `wrote_any` before the counter next matters. That is a SECOND coincidence stacked on
     the write mux and the finding does not mention it. Both C-2 checks are now qualified
     by the feeder's own `busy`.
  2. **C-2 caught its own alignment twice**, which is worth recording because Phase 2 has
     to redo exactly this arithmetic. In `dw_feeder` the witness needs OS_LAT registers
     where `grp_*` needed OS_LAT+1, because capturing a `line_buffer` OUTPUT already costs
     a cycle. In `stem_feeder` a plain hold was not enough: the stall releases on the LAST
     sweep cycle, so the next window overwrites the held coordinates in the same cycle
     `entry_done` fires for this one.
  3. **top_seq's own negative tests** found that S_ERR needed to admit `start` on the same
     terms as S_IDLE. Routing recovery through S_IDLE took TWO start pulses, because the
     first left S_ERR with `fault` still set - correct in the RTL and wrong in every caller.

- Two conventions established, both because a check that cannot be exercised is worthless:
  - `CHECKS_ARE_FATAL` (on `requantize` and `pw_out`, simulation-only): 1 everywhere except
    in the testbench whose PURPOSE is to fire that tripwire. `pw_out_tb`'s header already
    said "a self-check that cannot fire is indistinguishable from one that does not work";
    an unconditional `$finish` would have made that passing negative test unrunnable.
  - `ERROR:` + `$finish` for conditions with no correct continuation (L-12, C-2, C-4, T-3,
    L-4, L-5); `[FAULT]` with no `$finish` for the three the HARDWARE handles (T-1, T-2,
    T-3's sequencer side), where `fault` is the verdict and a testbench asserts on it.
    `scripts/run_sim.sh` greps for `^ERROR:`, so the first kind fails a run by its text as
    well as by the missing ALL PASS - verified, the C-2 false positive above did exactly
    that.

- Verified the elaboration-guard technique properly before relying on it for T-1 and C-6,
  since Verilog-2001 has no `$fatal` at elaboration: a `generate if` instantiating a module
  that does not exist fails LOUDLY in both tools and names the condition - xsim gives
  `ERROR: [VRFC 10-2063] Module <ERROR_DEPTH_EXCEEDS_ADDR_WIDTH> not found`, Vivado
  synthesis gives `ERROR: [Synth 8-439] module ... not found`. It does NOT silently become
  a black box, which was the thing worth checking.

- `gen_program.py` now prints both ceilings on every run rather than only failing at them:

      sequencer ceiling   : 64/64 instructions (0 spare, PGA_W=9)
      weight buffer       : 800/1024 entries worst case (78%, features.18.0, WA_W=10)

  The first of those is T-1's severity in one line - the network sits exactly on the limit.

- Blocked on: **DD-020**, and it is now measured rather than predicted. T-5 as implemented
  is async assert / sync deassert, which keeps `negedge rst_n` in every sensitivity list, so
  it fixes deassertion and nothing else. Post-route `report_methodology` on the Phase 1
  checkpoint:

      DPIR-2  Warning  Asynchronous driver check   10940      <- unchanged from baseline
      [Synth 8-7137]  set and reset with same priority   10   <- unchanged

  And from the other direction, `phys_opt_design`'s own pass:

      Phase 2 DSP Register Optimization
      INFO: [Physopt 32-456] No candidate cells for DSP register optimization found
            in the design.

  944 DSPs, 3,999 async-reset flops feeding them, zero candidates. L-1's whole purpose is to
  put pipeline registers inside those DSPs, and the tool is saying it cannot. DD-020 is
  PROPOSED with four options and a one-leaf experiment to run before the wide edit; the
  message to watch in that experiment is 32-456's candidate count leaving zero.

  `report_methodology` is in `scripts/impl.tcl` now, and the DPIR-2 count prints on stdout.
  It had been measured by hand once, which is exactly how a number stops being measured.
- Next: Phase 2a, which needs the reset decision first.

### 2026-09-23 (later still) - DD-020 accepted: synchronous reset, and DPIR-2 goes to zero
- Did: ran the DD-020 validation experiment, then implemented option B - 49 always blocks
  across 16 files from `always @(posedge clock or negedge rst_n)` to `always @(posedge clock)`,
  keeping the same `if (!rst_n)` body. The synchroniser in `accel_top` is the one block that
  keeps its asynchronous reset, and the convention is documented there, in the file a reader
  is in when they need it.
- The experiment first, because it corrected its own premise. DD-020 said "convert
  `dwconv3x3` + `dw_array`", which cannot be done: both are purely combinational and own no
  registers. The registers DPIR-2 names are the ones DRIVING the DSP inputs. Grouping all
  10,940 violations by instance:

      6,480 (59%)  u_stem/u_arr  (216 DSPs)  <- stem_feeder's win_q, 216 bits
      4,320 (39%)  u_dw/u_arr    (144 DSPs)  <- line_buffer's wr[], 1,152 bits
        140  (1%)  u_log/cls[*].u_r          <- logit_out's parameter registers

  `pe_array`'s 512 DSPs and `out_stage`'s 64 are ABSENT, and that is the interesting part:
  their inputs come from `act_buffer`/`wgt_buffer`/`param_buffer` `dout` registers, which have
  no reset at all, plus `out_stage`'s `acc_q`, which has no assignment in its reset branch. So
  the registers that were already mergeable were precisely the ones with no reset. Nobody
  chose that; it is option D happening by accident in the places it happened.
- So the experiment was `win_q`: one register, the largest share, sitting on the measured
  critical path. Two synthesis runs at 4.000 ns with that one register as the only difference:

      before : worst path from u_stem/win_q_reg[7]/C                        WNS -17.279
      after  : worst path from u_stem/u_arr/lane[0].u_conv/acc26/
                                   DSP_A_B_DATA_INST/CLK                   WNS -17.036

  The start point moved from a fabric flip-flop INTO the DSP48E2's A/B input register, and
  209 of win_q's 216 flip-flops disappeared. That is the mechanism L-1 depends on, shown on
  real geometry rather than quoted from the datasheet.
- Then the whole design. Post-route at 4.000 ns:

  | | baseline | Phase 1 | option B | |
  |:--|--:|--:|--:|:--|
  | **DPIR-2** | 10,940 | 10,940 | **0** | the goal |
  | `[Synth 8-7137]` | 10 | 10 | **0** | free |
  | CLB LUTs | 34,834 | 34,957 | **32,919** | -2,038 (-5.8%) |
  | CLB Registers | 6,863 | 6,702 | **4,959** | -1,743 (-26%) |
  | Block RAM / URAM | 176 / 52 | 176 / 52 | 178 / 52 | +2 BRAM |
  | DSPs | 944 | 944 | **976** | +32 |
  | WNS | -18.821 | -18.463 | **-18.282** | +0.181 |
  | real Fmax | 43.8 | 44.5 | **44.8 MHz** | |

- Tests: all 31 testbenches pass, `accel_tb` bit-exact at 6,895,780 elements. For a
  16-file mechanical edit that is the only check worth anything, and it is why the whole
  conversion went in as one commit with nothing else in it.
- Found, and it is a correction to something I wrote in DD-020 before measuring:
  `INFO: [Physopt 32-456] No candidate cells for DSP register optimization found` is NOT a
  usable signal. It reads identically after the fix, because by then synthesis has already
  absorbed the registers and there is nothing for a physical-optimization pass to move. It
  says "nothing to do" both when the work is impossible and when it is already done. The
  signals that distinguish the two are the DPIR-2 count, the start point of the worst path,
  and the flip-flop count.
- Located the +32 DSPs rather than waving at them: `mac_lane` is 17 DSPs per lane instead of
  16, times TM=32. Sixteen are the taps; the seventeenth is the accumulate stage, which used
  to share the last tap's DSP and now has its own P register. 32 DSPs (1.9% of the device)
  for 1,743 flip-flops and 2,038 LUTs, and the accumulator gaining a DSP register stage is
  the direction L-1 is going anyway.
- TNS went the other way (-67,421 -> -70,411) while WNS improved, which is not a
  contradiction: endpoints grew 94,308 -> 97,060 because 32 more DSPs and the absorbed
  registers add timing endpoints, and in a design missing its constraint by 4.5x more
  endpoints means more failing ones. The ten worst paths are still the stem cascade and the
  synchronous reset net is on none of them, so nothing new became critical.
- Still true, and still the point: 19.4 ns of the worst path's 22.2 ns is LOGIC across 27
  unregistered DSP_ALU levels. Nothing here touched that. What changed is that L-1 can now
  put its pipeline registers inside the DSPs instead of in front of them.
- Blocked on: nothing. Phase 2a is unblocked.
- Next: Phase 2a - mac_lane (L-1, L-2, L-9, L-10), pw_feeder's tag pipeline and drain, A-3
  done sourcing, and A-4/A-5/A-6 for pe_array.

### 2026-09-23 (evening) - Phase 2a: mac_lane pipelined, and L-8 turns out to be an attribute
- Did: L-1, L-2, L-9, L-10 in `mac_lane`; A-3, A-4, A-5, A-6 in `pe_array`; and every constant
  that encoded mac_lane's old one-cycle latency, in the same commit. A reassociation and a
  latency change, never a change of value.
- Tests: all 31 pass. `accel_tb` bit-exact at 6,895,780 elements, `pw_datapath` at 200,704.
  `mac_lane` and `pe_array` check against both oracles (an independent reference sum and the
  proven `conv1x1`), and all three pointwise testbenches now assert the latency as an
  EQUALITY rather than a ceiling - the old drain check was `> 4` against a 1-cycle pipeline,
  so it could not have caught this change in either direction.
- The structure: one registered product per tap (PROD_W = 2*DATA_W, L-9), a balanced adder
  tree with one register per level (clog2(TN) = 4), then the accumulator - the only stage
  `valid` gates. MAC_LAT = 1 + clog2(TN) + 1 = 6, a localparam derived from TN.
- Constants that moved with it: `pw_feeder`'s tag pipeline 2 -> 7, its drain from a literal
  3'd7 to `MAC_LAT + OS_LAT` = 8, and `OS_LAT` became a parameter of `accel_top` passed down,
  because out_stage is instantiated at the top and a feeder cannot see its depth.
- **A correction to pw_feeder's own header.** It said "each tag stage advances on ITS OWN
  valid, never on the bare clock, or a stall would slide the tags past the data". That is
  right for a combinational array and BACKWARDS for the stages inside a pipelined one:
  mac_lane's tree is not clock-enabled, so a held buffer output propagates through it every
  cycle and a valid-gated tag falls behind it. Only the buffer-read stage stays gated, and
  for the opposite reason - the buffers it shadows are the thing that holds.
- Three bugs, none of them found by the golden vectors, which is the point of Phase 1:
  1. My own latency check armed on the FIRST tile, but `done` only fires on a LAST tile, so
     it measured MAC_LAT plus the dot product's length. Then it stayed armed and re-checked
     against a counter that had kept running.
  2. The tag pipeline had one stage too many: `acc_pix` IS the last register.
  3. **`wait (!busy)` is delta-cycle sensitive, in all SIX datapath testbenches.**
     `addr_gen`'s `run` drops and `layer_done` rises on the same clock edge and `busy` is a
     continuous OR of the two, so inside the non-blocking update region it can momentarily
     read 0. Real consumers sample it at a clock edge and never see it - `top_seq`'s
     `S_RUN: if (!op_busy)` is inside `always @(posedge clock)` - so the RTL is fine. It was
     invisible while the pipeline drained in 1-2 cycles because the fixed `repeat (8)` after
     it covered the gap. At 8 cycles `pw_datapath_tb` lost THE LAST WRITE of the layer:
     12,543 of 12,544 pixels, every one of them correct. That is exactly the failure shape
     the review warns about for this phase, and the bookkeeping that was wrong was the
     testbench's. All six now sample it the way hardware does. Phase 2b and 2c would have
     walked into it twice more.
- **L-8 is not a DSP-budget decision, it is an attribute scope bug**, and Phase 2a is what
  made that visible. Synthesis at 4.000 ns with the tree in place:

      DSPs   976 -> 1,200   (+224, i.e. +7 per lane, 56.5% -> 69.4% of the device)

  `(* use_dsp = "yes" *)` sits on the MODULE, so it applies to every operation in it - and
  once an adder tree existed, Vivado started putting tree ADDS into DSP48E2s. A TREE_W=20
  adder is about 20 LUTs and three CARRY8. Spending a DSP on it is 1/1728th of the scarcest
  resource on the device doing what 20 LUTs would, and the depthwise (144 DSPs) and stem
  (216) trees are still to come in 2b and 2c - this compounds.
  Fixed by scoping the attribute to the operation instead of the module: `use_dsp="yes"` on
  the product register, `use_dsp="no"` on the tree nodes. Saying which operation wants a DSP
  instead of saying "this module does" is the whole difference, and it is half of what L-8 is
  actually about. The blanket attribute was never wrong about the MULTIPLIERS.
- WNS did NOT move: -17.036 ns, and the worst path is still
  `u_stem/u_arr/lane[0].u_conv/acc26/DSP_A_B_DATA_INST` -> `u_os/acc_q_reg`. That is the
  correct result and worth stating plainly: the critical path is `conv3x3_std`'s 27-tap
  cascade in the STEM, which Phase 2a did not touch. mac_lane's 16-deep cascade was never the
  worst path - Phase 0 recorded that all ten worst paths were the stem - so pipelining it
  buys headroom that only becomes visible once 2c removes the stem's. Phase 2c is where the
  clock target moves.
- Followed it up properly, because the first answer was wrong twice. FOUR variants, all
  bit-exact (the attribute is invisible to xsim), all at 4.000 ns - the table is in DD-021.
  The short version:

      A  attribute on the MODULE                 1,200 DSP  33,085 LUT  WNS -17.036
      B  "yes" on product, "no" on WHOLE tree      688 DSP  51,581 LUT  WNS -16.275
      C  no module attribute, "yes" on product   1,168 DSP  33,922 LUT  WNS -17.036
      D  "yes" on product, level 1 auto,           944 DSP  30,095 LUT  WNS -16.296
         levels 2.. forced "no"

  The module attribute was NOT the cause - C removed it and still got 23 DSPs per lane. A
  DSP48E2 has an ALU behind its multiplier, so Vivado absorbs a LEVEL-1 tree add into the same
  DSP that made the two products (free) and cannot for level 2 and above, so it spends a whole
  DSP per adder: seven per lane.

  B looked best and is the one to reject. 688 cannot be 16 multiplies per lane - one 27x18
  multiplier, and mac_lane's taps share no operand, so packing is impossible. u_pwf measured
  256 DSPs = 8 per lane, so half the multiplies were in FABRIC. That is DD-018's mistake
  arriving by accident, and taking it because the numbers looked good is how the first one
  happened.

  D is strictly best: u_pwf lands on exactly TM*TN = 512 DSPs, the theoretical minimum, so
  L-1's tree costs ZERO extra DSPs - and 30,095 LUTs is 2,859 FEWER than before mac_lane was
  pipelined at all.
- Post-route, cumulative, at 4.000 ns:

      baseline    WNS -18.821   43.8 MHz   34,834 LUT   944 DSP   DPIR-2 10,940
      Phase 1     WNS -18.463   44.5 MHz   34,957 LUT   944 DSP   DPIR-2 10,940
      DD-020      WNS -18.282   44.8 MHz   32,919 LUT   976 DSP   DPIR-2 0
      2a + D      WNS -16.411   49.0 MHz   29,935 LUT   944 DSP   DPIR-2 0

  Pipelining ONE of the three MAC kernels is worth 4.2 MHz and costs 4,981 flip-flops and
  nothing else. The worst path is still the STEM - 27 unregistered DSP_ALU levels, 19.233 of
  20.362 ns - which is Phase 2c, and the reason this is 49 MHz and not 250.
- Also settled, and it is a firmer no than the review implies: L-8's "narrow M0 to 27 bits to
  halve requantize's DSPs". Over all 36,324 exported multipliers, max |M0| is 2,147,461,603
  (32 bits) and 124 of them - 0.3% - fit signed 27 bits. Not a near miss and not
  data-dependent: M0 is NORMALIZED into the top of int32 by construction, which is what buys
  its precision. Narrowing it means renormalising and dropping four bits, i.e. a QUANTIZATION
  change that invalidates every golden vector, for 64 DSPs (3.7% of the device). Rejected in
  DD-021 with the numbers, so it stops being re-proposed.
- Blocked on: nothing.
- Next: Phase 2b (dwconv3x3, dw_array, dw_feeder), applying DD-021's rule from the start.
