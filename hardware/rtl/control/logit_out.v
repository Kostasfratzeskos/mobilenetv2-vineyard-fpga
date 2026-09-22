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
    output wire [NLOG*LOG_W-1:0]     logits,
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
    always @(posedge clock or negedge rst_n) begin
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

    // ---- bias + requantize to int16, one chain per class ----------------
    genvar c;
    generate
        for (c = 0; c < NLOG; c = c + 1) begin : cls
            wire signed [ACC_W-1:0] biased;

            bias_add #(.ACC_W(ACC_W), .BIAS_W(BIAS_W)) u_b (
                .acc_in  (acc[c*ACC_W +: ACC_W]),
                .bias    (p_bias[c]),
                .acc_out (biased)
            );

            requantize #(
                .ACC_W(ACC_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .OUT_W(LOG_W)
            ) u_r (
                .clock      (clock),
                .rst_n      (rst_n),
                .en         (acc_valid),
                .act        (ACT_NONE),      // logits never take an activation
                .in_data    (biased),
                .M0         (p_m0[c]),
                .shift      (p_shift[c]),
                .relu6_qmax (8'sd0),
                .quantized  (logits[c*LOG_W +: LOG_W])
            );
        end
    endgenerate

    reg lv;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)     lv <= 1'b0;
        else if (start) lv <= 1'b0;
        else            lv <= acc_valid;
    end
    assign logits_valid = lv;

    // ---- argmax over the shared logit scale (DD-011) --------------------
    // A plain signed comparison is enough because every class shares S_logit.
    // `>` keeps the lower index on a tie, which is what argmax_i16() does.
    reg [IDX_W-1:0]      best_i;
    reg signed [LOG_W-1:0] best_v;
    integer k;
    always @* begin
        best_i = {IDX_W{1'b0}};
        best_v = $signed(logits[0 +: LOG_W]);
        for (k = 1; k < NLOG; k = k + 1)
            if ($signed(logits[k*LOG_W +: LOG_W]) > best_v) begin
                best_v = $signed(logits[k*LOG_W +: LOG_W]);
                best_i = k[IDX_W-1:0];
            end
    end

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            argmax <= {IDX_W{1'b0}};  argmax_valid <= 1'b0;
        end else if (start) begin
            argmax_valid <= 1'b0;
        end else begin
            argmax_valid <= lv;
            if (lv) argmax <= best_i;
        end
    end

endmodule

`default_nettype wire
