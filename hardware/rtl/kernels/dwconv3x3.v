`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  dwconv3x3.v  -  depthwise KxK convolution == pipelined K*K-tap MAC (one channel)
//
//  Hardware twin of the inner window of dwconv3x3() in
//      software/cmodel/src/mobilenet.c
//
//  Depthwise means each output channel depends only on the SAME input channel
//  (no sum across channels). For one output element (channel c, pixel oy,ox):
//        acc = sum_{ky,kx}  window[ky,kx] * kernel_c[ky,kx]      (up to KxK taps)
//
//  Zero-padding at image borders is the FEEDER's job: it drives 0 into any tap
//  that falls outside the image (0 * w = 0), exactly like the C `continue`. The
//  window generation / addressing lives in the controller, not here.
//
//  Tap ordering: index i = ky*K + kx (row-major within the window). `win` and
//  `wk` must use the SAME ordering; the sum is order-independent anyway.
//
//  ---- THE PIPELINE (L-1, L-2, L-9) ------------------------------------
//
//  This used to be a blocking for-loop over K*K taps, which describes a linear
//  DEPENDENCY CHAIN and mapped to nine unregistered DSP48E2s in a PCOUT->PCIN
//  cascade with MREG and PREG bypassed - the same shape DD-018 measured as the
//  critical path at 27 taps in conv3x3_std, and mac_lane carried at 16. It is
//  now the same three-part structure mac_lane uses:
//
//    stage 0            one registered product per tap, explicitly
//                       PROD_W = 2*DATA_W wide (L-9)
//    stages 1..LEVELS   a BALANCED adder tree, one register per level
//
//  There is no accumulate stage: a depthwise dot product is exactly K*K taps
//  and completes in one pass, unlike mac_lane which streams ceil(IC/Tn) tiles.
//  So DW_LAT = 1 + LEVELS = 5 at K=3, where mac_lane's MAC_LAT is 6.
//
//  ---- K*K = 9 is not a power of two ------------------------------------
//
//  The tree halves its node count per level, so it needs 2**LEVELS leaves.
//  LEVELS = clog2(9) = 4 gives 16, and the seven missing taps are padded with
//  ZERO on the BUSES rather than special-cased in the loop - padding the data is
//  one generate block, padding the loop means dynamic out-of-range array reads.
//  A zero product and the adds that consume it are constants, so synthesis
//  prunes them: the cost is nothing and the tree stays one shape.
//
//  ---- why this is bit-exact -------------------------------------------
//
//  Reassociation of integer addition, which is exact, plus padding with zeros,
//  which is the identity. Nothing truncates: TREE_W = PROD_W + LEVELS holds the
//  last level and therefore every earlier one. At K=3, DATA_W=8 the worst case
//  is 9 * 127 * 128 = 146,304, which needs 19 signed bits against TREE_W = 20.
//  dw_array's header already made this a BOUND rather than a precondition.
//
//  ---- the control does not live here ----------------------------------
//
//  The tree FREE-RUNS - it is not clock-enabled - so nothing here needs `valid`.
//  dw_array carries ONE valid shift register for all TC channels rather than TC
//  copies of the same thing, and that is also where the latency becomes visible
//  in a port list (A-2).
//
//  Run:  bash scripts/run_sim.sh dwconv3x3
//============================================================================
// NOTE on use_dsp: the attribute is on the PRODUCT REGISTER, and levels 2 and
// above of the tree are explicitly "no". Not on the module, and not on the whole
// tree - both were measured and both are worse. See DD-021; mac_lane carries the
// same arrangement and the same reasoning.
module dwconv3x3 #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter K      = 3,     // KxK kernel (3x3 depthwise)
    parameter ACC_W  = 26     // accumulator width (matches HW / requantize in)
)(
    input  wire                    clock,
    input  wire                    rst_n,   // SYNCHRONOUS (DD-020)
    input  wire [K*K*DATA_W-1:0]   win,     // KxK activation window, tap-major
    input  wire [K*K*DATA_W-1:0]   wk,      // KxK weights for this channel
    output wire signed [ACC_W-1:0] acc
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam NT      = K*K;                   // 9 real taps
    localparam LEVELS  = clog2(NT);             // 4
    localparam NPAD    = 1 << LEVELS;           // 16 tree leaves
    localparam PROD_W  = 2*DATA_W;              // 16
    localparam TREE_W  = PROD_W + LEVELS;       // 20
    localparam DW_LAT  = 1 + LEVELS;            // 5

    generate
        if (ACC_W < TREE_W) begin : chk_acc_w
            ERROR_DWCONV3X3_ACC_W_NARROWER_THAN_ONE_WINDOW_SUM u_err();
        end
        if (NPAD < 4) begin : chk_npad
            ERROR_DWCONV3X3_NEEDS_AT_LEAST_4_TREE_LEAVES u_err();
        end
    endgenerate

    // ---- pad the BUSES out to NPAD leaves -------------------------------
    wire [NPAD*DATA_W-1:0] win_p, wk_p;

    genvar g;
    generate
        for (g = 0; g < NPAD; g = g + 1) begin : pad
            if (g < NT) begin : real_tap
                assign win_p[g*DATA_W +: DATA_W] = win[g*DATA_W +: DATA_W];
                assign wk_p [g*DATA_W +: DATA_W] = wk [g*DATA_W +: DATA_W];
            end else begin : zero_tap
                assign win_p[g*DATA_W +: DATA_W] = {DATA_W{1'b0}};
                assign wk_p [g*DATA_W +: DATA_W] = {DATA_W{1'b0}};
            end
        end
    endgenerate

    integer i, k, lv, off, prev, cnt;

    // ================= stage 0 : one registered product per leaf ========
    (* use_dsp = "yes" *)
    reg signed [PROD_W-1:0] prod [0:NPAD-1];

    always @(posedge clock) begin
        if (!rst_n) begin
            for (i = 0; i < NPAD; i = i + 1) prod[i] <= {PROD_W{1'b0}};
        end else begin
            for (i = 0; i < NPAD; i = i + 1)
                prod[i] <= $signed(win_p[i*DATA_W +: DATA_W]) *
                           $signed(wk_p [i*DATA_W +: DATA_W]);
        end
    end

    // ================= stages 1..LEVELS : the balanced adder tree =======
    //  Split by level for the reason DD-021 measured: a DSP48E2's own ALU
    //  absorbs a LEVEL-1 add for free, and cannot absorb level 2 and above, so
    //  those would each take a whole DSP48E2 unless told not to.
    reg signed [TREE_W-1:0] n1 [0:NPAD/2-1];    // level 1

    (* use_dsp = "no" *)
    reg signed [TREE_W-1:0] nh [0:NPAD/2-2];    // levels 2..LEVELS

    always @(posedge clock) begin
        if (!rst_n) begin
            for (k = 0; k < NPAD/2;   k = k + 1) n1[k] <= {TREE_W{1'b0}};
            for (k = 0; k < NPAD/2-1; k = k + 1) nh[k] <= {TREE_W{1'b0}};
        end else begin
            for (k = 0; k < NPAD/2; k = k + 1)
                n1[k] <= $signed(prod[2*k]) + $signed(prod[2*k+1]);

            for (k = 0; k < NPAD/4; k = k + 1)
                nh[k] <= n1[2*k] + n1[2*k+1];

            off = 0;
            cnt = NPAD/4;
            for (lv = 3; lv <= LEVELS; lv = lv + 1) begin
                prev = off;
                off  = off + cnt;
                cnt  = cnt >> 1;
                for (k = 0; k < cnt; k = k + 1)
                    nh[off + k] <= nh[prev + 2*k] + nh[prev + 2*k + 1];
            end
        end
    end

    // signed, so the assignment sign-extends TREE_W into ACC_W
    assign acc = nh[NPAD/2-2];

endmodule

`default_nettype wire
