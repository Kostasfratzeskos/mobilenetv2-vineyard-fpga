`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  rq_bank.v  -  Tm parallel bias_add + requantize = one 256-bit output word
//
//  Build plan #4, first piece: the output half of the pointwise datapath.
//  pe_array hands over Tm=32 finished accumulators; this turns them into 32
//  int8 activations, packed into exactly the 256-bit word act_buffer stores.
//
//  ---- why ONE unit per lane (R = Tm = 32) -----------------------------
//
//  The array finishes Tm accumulators every n_ic cycles. With R requantize
//  units the drain takes ceil(Tm/R) cycles, so an output tile costs
//  max(n_ic, ceil(Tm/R)). Measured over all 35 pointwise layers with
//  scripts/analyze_workload.py (section `requant`):
//
//      R    DSPs   drain   cycles      vs base   layers stalled
//      1      2      32    4,359,316   +667%     28/35
//      8     16       4      797,016    +40%      7/35
//     16     32       2      605,720     +6.6%    1/35
//     32     64       1      568,088      0%      0/35
//
//  R=16 is the knee, but R=32 was chosen for a reason that is not in the
//  table: at R=32 an entire control path stops existing. With R<32 this
//  module would need a shadow register to hold the accumulators while the
//  array moves on, a drain counter, a stall path back into addr_gen, and
//  logic to assemble the 256-bit word in pieces. At R=32 all 32 results
//  appear in one cycle and are already the word act_buffer wants. The extra
//  32 DSPs are 1.9% of the chip; the control logic they remove is a place
//  for bugs. Total budget stays ~442 DSP = 26% of the XCZU7EV.
//
//  (The one layer R=16 would stall is features.2.conv.0.0, IC=16 - the same
//  outlier that forced act_buffer's 256-bit entries. Designing the whole
//  drain around one layer is what R=32 avoids.)
//
//  ---- structure --------------------------------------------------------
//
//  Per lane, nothing new is invented: the already-proven bias_add (pure
//  combinational add) feeds the already-proven requantize (multiply by M0,
//  round, arithmetic shift, clamp). Both come straight from kernels/, so the
//  arithmetic is the same silicon that passed the golden-vector integration
//  tests in July. This module is the Tm-wide wrapper around them.
//
//      acc[m] ──► bias_add(bias[m]) ──► requantize(m0[m], shift[m]) ──► q[m]
//
//  Bias, M0 and shift are PER OUTPUT CHANNEL, so they arrive as Tm-wide
//  buses indexed the same way as everything else: lane m holds output
//  channel oct*Tm + m. `act` and `relu6_qmax` are per LAYER, so they are
//  scalars - every channel of a layer shares the same activation function.
//
//  Timing: combinational bias, registered requantize. `q` is valid the cycle
//  after `en`, and `q_valid` marks it - the same convention requantize uses,
//  so this drops in behind pe_array's `done` with no extra alignment.
//
//  Run:  bash scripts/run_sim.sh rq_bank bias_add requantize
//============================================================================
module rq_bank #(
    parameter TM      = 32,    // lanes, one requantize each
    parameter ACC_W   = 26,    // accumulator width from pe_array
    parameter BIAS_W  = 32,    // int32 bias, as exported
    parameter M0_W    = 32,    // int32 fixed-point multiplier
    parameter SHIFT_W = 6,     // right-shift amount
    parameter DATA_W  = 8      // int8 output
)(
    input  wire                      clock,
    input  wire                      rst_n,
    input  wire                      en,           // latch this result

    // ---- per-layer -----------------------------------------------------
    input  wire                      act,          // 0 = NONE, 1 = RELU6
    input  wire signed [7:0]         relu6_qmax,   // ReLU6 ceiling, q6

    // ---- per-output-channel, Tm wide -----------------------------------
    input  wire [TM*ACC_W-1:0]       acc,          // from pe_array
    input  wire [TM*BIAS_W-1:0]      bias,
    input  wire [TM*M0_W-1:0]        m0,
    input  wire [TM*SHIFT_W-1:0]     shift,

    // ---- result --------------------------------------------------------
    output wire [TM*DATA_W-1:0]      q,            // the act_buffer word
    output reg                       q_valid
);

    genvar m;
    generate
        for (m = 0; m < TM; m = m + 1) begin : ch
            // combinational: acc + per-channel int32 bias
            wire signed [ACC_W-1:0] biased;

            bias_add #(
                .ACC_W  (ACC_W),
                .BIAS_W (BIAS_W)
            ) u_bias (
                .acc_in  (acc [m*ACC_W  +: ACC_W]),
                .bias    (bias[m*BIAS_W +: BIAS_W]),
                .acc_out (biased)
            );

            // registered: multiply by M0, round, shift, clamp
            requantize #(
                .ACC_W   (ACC_W),
                .M0_W    (M0_W),
                .SHIFT_W (SHIFT_W)
            ) u_rq (
                .clock      (clock),
                .rst_n      (rst_n),
                .en         (en),
                .act        (act),
                .in_data    (biased),
                .M0         (m0   [m*M0_W    +: M0_W]),
                .shift      (shift[m*SHIFT_W +: SHIFT_W]),
                .relu6_qmax (relu6_qmax),
                .quantized  (q    [m*DATA_W  +: DATA_W])
            );
        end
    endgenerate

    // marks the cycle on which `q` holds the finished word
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) q_valid <= 1'b0;
        else        q_valid <= en;
    end

endmodule

`default_nettype wire
