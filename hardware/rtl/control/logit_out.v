`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  logit_out.v  -  the classifier tail: int16 logits and the predicted class
//
//  Build plan #6, the LINEAR opcode. This is where the accelerator stops
//  producing feature maps and produces an answer.
//
//  ---- there is no new feeder ------------------------------------------
//
//  The classifier IS a 1x1 convolution: 1 pixel, IC=1280, OC=4. pw_feeder
//  executes it unchanged - n_pix=1, n_oc=1, n_ic=80 - and only the TAIL
//  differs, because the output is not an int8 activation going back into the
//  pool but four int16 logits going to a register the PS reads. So this module
//  replaces out_stage for that one op rather than replacing anything upstream.
//
//  ---- what differs from out_stage -------------------------------------
//
//  Two things, both small:
//
//    * clamp_i16 instead of clamp_i8. requantize.v is now parameterised by
//      OUT_W, and this instantiates it at 16; the arithmetic is otherwise the
//      ACT_NONE path unchanged, which is exactly what requantize_logits() does
//      in the C model (DD-011).
//    * four channels instead of thirty-two, so the parameters are plain
//      registers written by index rather than a banked memory. Twelve values
//      total; a param_buffer would be ceremony.
//
//  ---- argmax ----------------------------------------------------------
//
//  DD-011 chose one shared logit scale precisely so the classes can be compared
//  directly, and this is where that pays off: the prediction is a 4-way signed
//  comparator, no rescaling. Ties keep the lower index, matching argmax_i16()
//  in the C model, which advances only on a strict `>`.
//
//  ---- a note on the accumulator ---------------------------------------
//
//  This op has the network's longest dot product, IC=1280, and it IS the
//  tightest point in the network - 5,094,750 against the provable bound. The
//  header used to say so on the strength of a measurement, and that is the
//  part that was wrong.
//
//  ACC_W used to be 21, sized from what ONE image through ONE checkpoint
//  happened to produce: the post-bias accumulator peaked at 355,971 here
//  against a limit of 1,048,576, and every other layer sat below 3% of the
//  range. This header said "worth re-measuring if the model is retrained" -
//  right instinct, wrong mechanism. The 2026-07 retrain gave
//  features.3.conv.0.0 channel 110 a bias of 1,184,089, which does not fit a
//  21-bit accumulator ON ITS OWN, whatever the image. It wrapped negative,
//  ReLU6 clamped it to 0, and 2.2M elements downstream went wrong in silence.
//  A measurement cannot catch that, because the failure was never about data.
//
//  ACC_W is 26 now, and it is not a measurement any more. export.py computes
//  the PROVABLE bound - sum|w| * max|a| + |bias| per channel, which no input
//  can exceed, adversarial included - and refuses to export a model that does
//  not fit the RTL's width. Network worst case 5,094,750 needs 24 signed bits;
//  26 gives 6.6x margin and stays inside the DSP48E2's 27-bit operand port, so
//  the requantize multiply is still 2 DSPs per lane rather than 4.
//
//  Run:  bash scripts/run_sim.sh logit_out bias_add requantize
//============================================================================
module logit_out #(
    parameter TM      = 32,    // lanes arriving from pe_array
    parameter NLOG    = 4,     // classes
    parameter IDX_W   = 2,     // clog2(NLOG)
    parameter ACC_W   = 26,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter LOG_W   = 16     // logit width
)(
    input  wire                      clock,
    input  wire                      rst_n,
    input  wire                      start,       // clear before an op

    // ---- per-class parameters, written by index -------------------------
    input  wire                      pl_en,
    input  wire [IDX_W-1:0]          pl_idx,
    input  wire signed [BIAS_W-1:0]  pl_bias,
    input  wire signed [M0_W-1:0]    pl_m0,
    input  wire [SHIFT_W-1:0]        pl_shift,

    // ---- from pw_feeder: the low NLOG lanes are the classes -------------
    input  wire [TM*ACC_W-1:0]       acc,
    input  wire                      acc_valid,

    // ---- the answer -----------------------------------------------------
    output wire [NLOG*LOG_W-1:0]     logits,       // zeroed until this inference answers (T-10)
    output wire                      logits_valid,
    output reg  [IDX_W-1:0]          argmax,
    output reg                       argmax_valid
);

    localparam ACT_NONE = 1'b0;

    // ---- twelve registers, not a memory ---------------------------------
    reg signed [BIAS_W-1:0]  p_bias  [0:NLOG-1];
    reg signed [M0_W-1:0]    p_m0    [0:NLOG-1];
    reg [SHIFT_W-1:0]        p_shift [0:NLOG-1];

    integer i;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (i = 0; i < NLOG; i = i + 1) begin
                p_bias[i]  <= {BIAS_W{1'b0}};
                p_m0[i]    <= {M0_W{1'b0}};
                p_shift[i] <= {SHIFT_W{1'b0}};
            end
        end else if (pl_en) begin
            p_bias[pl_idx]  <= pl_bias;
            p_m0[pl_idx]    <= pl_m0;
            p_shift[pl_idx] <= pl_shift;
        end
    end

    // ---- T-10: the outputs do not survive a new inference ---------------
    //  `logits` and `argmax` used to hold the PREVIOUS inference's answer from
    //  `start` until the new one emerged, ARR_LAT + RQ_LAT cycles later. Both
    //  valid flags were already cleared on start, so nothing that reads the
    //  contract correctly was wrong - but the PS reads these over AXI, and a
    //  poll that arrives between `start` and the first `logits_valid` gets a
    //  complete, plausible, four-class answer belonging to the previous image.
    //  That is the worst shape a stale value can take: not an x, not a zero, but
    //  last frame's confident prediction of a healthy leaf.
    //
    //  `stale` is set by start and cleared by the first real result, so the
    //  window reads as zeros instead. It is a gate on the output rather than a
    //  register on it, because `logits_valid` means "logits are good THIS cycle"
    //  and inserting a register would have moved that by one.
    //  The update is further down, next to `lv`, which it depends on - a net has
    //  to be declared before it is read, and `lv` comes from cls_valid.
    reg stale;

    // ---- bias + requantize to int16, one chain per class ----------------
    wire [NLOG-1:0]          cls_valid;
    wire [NLOG*LOG_W-1:0]    logits_raw;


    genvar c;
    generate
        for (c = 0; c < NLOG; c = c + 1) begin : cls
            wire signed [ACC_W-1:0] biased;

            bias_add #(.ACC_W(ACC_W), .BIAS_W(BIAS_W)) u_b (
                .acc_in  (acc[c*ACC_W +: ACC_W]),
                .bias    (p_bias[c]),
                .acc_out (biased)
            );

            wire cls_qv;

            requantize #(
                .ACC_W(ACC_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .OUT_W(LOG_W)
            ) u_r (
                .clock      (clock),
                .rst_n      (rst_n),
                .en         (acc_valid),
                //  C-10: `start` is this module's flush. The classifier's
                //  requantize copy has the same in-flight problem out_stage's
                //  had, and the same answer - and it finishes T-10's "clear the
                //  logit outputs on start": the `stale` gate hides the old
                //  value, this stops a half-finished new one from arriving.
                .flush      (start),
                .act        (ACT_NONE),      // logits never take an activation
                .in_data    (biased),
                .M0         (p_m0[c]),
                .shift      (p_shift[c]),
                .relu6_qmax (8'sd0),
                .quantized  (logits_raw[c*LOG_W +: LOG_W]),
                .q_valid    (cls_qv)
            );

            assign cls_valid[c] = cls_qv;
        end
    endgenerate

    // ---- `lv` is requantize's own q_valid now (L-3) ----------------------
    //  It used to be a single register mirroring requantize's single register.
    //  L-3 made requantize four stages deep, so a one-cycle `lv` would have
    //  marked the logits valid three cycles before they existed - and T-8 is
    //  why that matters here specifically: this is a SECOND copy of the
    //  requantize datapath that no shared testbench covers, and after Phase 2c
    //  it is on the design's critical path. Taking the valid from the module
    //  itself means the copy cannot drift from the original.
    //
    //  `start` still forces it low, so a new op cannot inherit the previous
    //  answer while the pipeline refills.
    reg lv_gate;
    always @(posedge clock) begin
        if (!rst_n)     lv_gate <= 1'b0;
        else if (start) lv_gate <= 1'b0;
        else            lv_gate <= 1'b1;
    end

    wire lv = cls_valid[0] & lv_gate;
    assign logits_valid = lv;

    //  T-10's `stale` gate, declared above and updated here: set by start,
    //  cleared by the first real result of this inference.
    always @(posedge clock) begin
        if (!rst_n)     stale <= 1'b1;
        else if (start) stale <= 1'b1;
        else if (lv)    stale <= 1'b0;
    end

    //  `stale && !lv`, not bare `stale`: `stale` is a REGISTER, so it is still
    //  high during the very cycle `lv`/`logits_valid` asserts - gating on it alone
    //  zeroed the logits exactly when the contract says they are good, which
    //  lin_datapath_tb caught immediately. The `!lv` term lets the first real
    //  result through in its own cycle.
    //
    //  After that first result this passes logits_raw straight through, which is
    //  what it always did: requantize's output register free-runs, so `logits`
    //  only ever means anything in a `logits_valid` cycle. T-10's complaint was
    //  the window from `start` to the FIRST result, and that is the window this
    //  closes - it deliberately does not turn `logits` into a latched output,
    //  because that would move `logits_valid` by a cycle.
    assign logits = (stale && !lv) ? {NLOG*LOG_W{1'b0}} : logits_raw;

`ifndef SYNTHESIS
    //  Lockstep, checked - the four classes see the same acc_valid and none
    //  looks at its own data. Also gives the other NLOG-1 bits a reader.
    always @(posedge clock) begin
        if (rst_n && (cls_valid != {NLOG{cls_valid[0]}})) begin
            $display("ERROR: %m L-3 the classifier lanes are NOT in lockstep at time %0t: cls_valid = %b.",
                     $time, cls_valid);
            $finish;
        end
    end
`endif

    // ---- argmax over the shared logit scale (DD-011) --------------------
    // A plain signed comparison is enough because every class shares S_logit.
    // `>` keeps the lower index on a tie, which is what argmax_i16() does.
    //  Over logits_RAW, not the gated `logits`: the comparison happens in the
    //  cycle `lv` is high, when `stale` is already being cleared, and reading the
    //  gated copy would make the winner depend on which of the two updated first.
    reg [IDX_W-1:0]      best_i;
    reg signed [LOG_W-1:0] best_v;
    integer k;
    always @* begin
        best_i = {IDX_W{1'b0}};
        best_v = $signed(logits_raw[0 +: LOG_W]);
        for (k = 1; k < NLOG; k = k + 1)
            if ($signed(logits_raw[k*LOG_W +: LOG_W]) > best_v) begin
                best_v = $signed(logits_raw[k*LOG_W +: LOG_W]);
                best_i = k[IDX_W-1:0];
            end
    end

    //  T-10: `argmax` itself is cleared on start, not just its valid flag - same
    //  argument as `logits` above. A class index is one of four legal values
    //  whatever it holds, so a stale one is unfalsifiable from the outside.
    always @(posedge clock) begin
        if (!rst_n) begin
            argmax <= {IDX_W{1'b0}};  argmax_valid <= 1'b0;
        end else if (start) begin
            argmax       <= {IDX_W{1'b0}};
            argmax_valid <= 1'b0;
        end else begin
            argmax_valid <= lv;
            if (lv) argmax <= best_i;
        end
    end

    // ---- L-12: the same bias-overflow watch as rq_bank -------------------
    //
    //  This module is the second instantiator of bias_add, and it is the one
    //  that matters most: the header above records that the classifier has the
    //  network's longest dot product, IC=1280, and is the tightest point
    //  against the provable bound at 5,094,750. T-8's complaint is exactly that
    //  this path is a second copy of the requantize datapath that no shared
    //  testbench covers - so it gets the same check, not a weaker one.
    //
    //  Zero synthesis cost; see rq_bank for why the check is not in bias_add.
`ifndef SYNTHESIS
    localparam signed [BIAS_W:0] ACC_MAX =  (1 <<< (ACC_W-1)) - 1;
    localparam signed [BIAS_W:0] ACC_MIN = -(1 <<< (ACC_W-1));

    genvar cc;
    generate
        for (cc = 0; cc < NLOG; cc = cc + 1) begin : chk
            wire signed [BIAS_W:0] full =
                 $signed(acc[cc*ACC_W +: ACC_W]) + $signed(p_bias[cc]);

            always @(posedge clock) begin
                if (rst_n && acc_valid && ((full > ACC_MAX) || (full < ACC_MIN))) begin
                    $display("ERROR: %m L-12 class %0d: acc+bias = %0d leaves the ACC_W=%0d range [%0d, %0d] at time %0t. bias_add truncates, so this logit is already corrupt.",
                             cc, full, ACC_W, ACC_MIN, ACC_MAX, $time);
                    $finish;
                end
            end
        end
    endgenerate
`endif

endmodule

`default_nettype wire
