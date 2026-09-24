`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  conv3x3_std.v  -  standard KxK convolution == pipelined MAC over window x channels
//
//  Hardware twin of the inner sums of conv3x3_std() in
//      software/cmodel/src/mobilenet.c   (the stem: Cin=3, OC=32, K=3, S=2)
//
//  For one output element (channel oc, pixel oy,ox), a standard conv sums over
//  BOTH the KxK spatial window AND the input channels:
//        acc = sum_{ky,kx,ic}  a[iy,ix,ic] * w[oc,ic,ky,kx]
//  i.e. a dot product over NT = K*K*CIN taps. This is the depthwise 9-tap MAC
//  generalized with the channel dimension - same flat multiply-add structure,
//  just more taps. Kept as its own named engine for the 1:1 mapping to the C op
//  and the golden vectors.
//
//  Zero-padding at image borders is the FEEDER's job (drive 0 into padded taps).
//  Tap ordering is arbitrary but `win` and `wk` must agree; the sum is
//  order-independent. The C uses i = (ic*K + ky)*K + kx within an oc block.
//
//  ---- THIS WAS THE CRITICAL PATH (L-1, L-2, L-9) ----------------------
//
//  27 taps summed in a blocking for-loop, i.e. a linear DEPENDENCY CHAIN, which
//  mapped to 27 unregistered DSP48E2s in a PCOUT->PCIN cascade with MREG and
//  PREG bypassed. DD-018 measured it and it has been the worst path in every
//  run of this project: 21.275 ns at synthesis, 24.315 ns post-route, and still
//  19.2 of 20.4 ns after Phase 2a and 2b pipelined the other two kernels. 27
//  DSPs and ZERO flip-flops in a module whose header claimed a "parallel
//  combinational tree" - it was neither parallel nor a tree.
//
//  It is now the structure mac_lane and dwconv3x3 already use:
//
//    stage 0            one registered product per tap, PROD_W = 2*DATA_W (L-9)
//    stages 1..LEVELS   a BALANCED adder tree, one register per level
//
//  No accumulate stage - like the depthwise, a standard-conv output element
//  completes in one pass - so ST_LAT = 1 + LEVELS = 6 at CIN=3, K=3.
//
//  ---- 27 taps is not a power of two ------------------------------------
//
//  LEVELS = clog2(27) = 5, so the tree wants 32 leaves and five are padded with
//  ZERO on the BUSES rather than special-cased in the loop - a dynamic index
//  past the end of `win` reads X, whereas a zero product and the adds that
//  consume it are constants synthesis prunes.
//
//  ---- why this is bit-exact -------------------------------------------
//
//  Reassociation of integer addition, which is exact, plus padding with zeros,
//  which is the identity. TREE_W = PROD_W + LEVELS = 21 holds the last level and
//  therefore every earlier one: the worst case is 27 * 127 * 128 = 438,912,
//  which needs 20 signed bits. That was already stated as a BOUND rather than a
//  precondition in stem_array's header and it still is.
//
//  ---- the control does not live here ----------------------------------
//
//  The tree FREE-RUNS, so nothing here needs `valid`. stem_array carries ONE
//  valid shift register for all TS lanes rather than TS copies, which is also
//  where the latency becomes visible in a port list.
//
//  Run:  bash scripts/run_sim.sh conv3x3_std
//============================================================================
// NOTE on use_dsp: the attribute is on the PRODUCT REGISTER, and levels 2 and
// above of the tree are explicitly "no". Not on the module, and not on the whole
// tree - both were measured and both are worse. DD-021 has the four-way table;
// mac_lane and dwconv3x3 carry the same arrangement.
module conv3x3_std #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter K      = 3,     // KxK spatial kernel
    parameter CIN    = 3,     // input channels (3 for the stem)
    parameter ACC_W  = 26     // accumulator width (matches HW / requantize in)
)(
    input  wire                      clock,
    input  wire                      rst_n,   // SYNCHRONOUS (DD-020)
    input  wire [K*K*CIN*DATA_W-1:0] win,     // window x channels, tap-major
    input  wire [K*K*CIN*DATA_W-1:0] wk,      // matching weights for this oc
    output wire signed [ACC_W-1:0]   acc
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam NT      = K*K*CIN;               // 27 taps per output element
    localparam LEVELS  = clog2(NT);             // 5
    localparam NPAD    = 1 << LEVELS;           // 32 tree leaves
    localparam PROD_W  = 2*DATA_W;              // 16
    localparam TREE_W  = PROD_W + LEVELS;       // 21
    localparam ST_LAT  = 1 + LEVELS;            // 6

    generate
        if (ACC_W < TREE_W) begin : chk_acc_w
            ERROR_CONV3X3_STD_ACC_W_NARROWER_THAN_ONE_ELEMENT_SUM u_err();
        end
        if (NPAD < 4) begin : chk_npad
            ERROR_CONV3X3_STD_NEEDS_AT_LEAST_4_TREE_LEAVES u_err();
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
    //  Split by level per DD-021: a DSP48E2's own ALU absorbs a LEVEL-1 add for
    //  free and cannot absorb level 2 and above, so those would each take a
    //  whole DSP48E2 unless told not to. At 8 lanes that is 8 x (NPAD/2 - 1)
    //  DSPs of pure waste.
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
