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
