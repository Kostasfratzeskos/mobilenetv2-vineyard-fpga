`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  mac_lane.v  -  one lane of the pointwise MAC array (Tn-wide streamed MAC)
//
//  A single output-channel lane: each cycle it multiplies Tn input activations
//  by Tn weights, sums them (adder tree), and accumulates across cycles. A full
//  dot product of length IC is streamed as ceil(IC/Tn) cycles (Tn taps each).
//
//  This is the parallel evolution of conv1x1.v: conv1x1 does 1 MAC/cycle, this
//  does Tn MAC/cycle. Tm of these lanes (sharing the same broadcast
//  activations) form the P = Tm*Tn array.
//
//  Handshake (identical to conv1x1 in meaning, NOT in timing - see below):
//    valid - a,w carry a valid Tn-wide tile this cycle -> accumulate
//    first - first tile of the dot product (acc <- 0)
//    last  - final tile -> `done` pulses MAC_LAT cycles later
//
//  ---- THE PIPELINE, and why it exists (L-1, L-2) ----------------------
//
//  This module used to sum the Tn products in a blocking for-loop:
//
//      for (i = 0; i < TN; i = i + 1) partial = partial + a[i]*w[i];
//
//  which describes a linear DEPENDENCY CHAIN, not a tree. With
//  use_dsp="yes" that maps to TN unregistered DSP48E2s in a PCOUT->PCIN
//  cascade with MREG and PREG bypassed - measured at 0.72 ns per hop, so 16
//  hops is 11.5 ns before the accumulator even sees the sum. DD-018 measured
//  the same shape at 27 taps in conv3x3_std and called it the critical path.
//
//  It is now three things:
//
//    stage 0            one registered product per tap. Explicitly
//                       PROD_W = 2*DATA_W wide (L-9), so the multiply is a
//                       16-bit signed product rather than two operands
//                       sign-extended to ACC_W and multiplied at 26 bits.
//    stages 1..LEVELS   a BALANCED adder tree, one register per level.
//                       LEVELS = clog2(TN) = 4 at TN=16, so the longest
//                       combinational run is one adder, not sixteen.
//    stage LEVELS+1     the accumulator, the only stage `valid` gates.
//
//  MAC_LAT = 1 + LEVELS + 1 = 6 at TN=16. It is a localparam DERIVED from TN,
//  not a number, because six other constants in the design are defined as
//  functions of it - see docs/latency_map.md.
//
//  ---- why this is bit-exact -------------------------------------------
//
//  Reassociation of integer addition, which is exact. Nothing is truncated on
//  the way: a tap product needs PROD_W bits, and a level-L node holds at most
//  2**L of them, so PROD_W + L bits always suffice. TREE_W = PROD_W + LEVELS
//  covers the last level and therefore every earlier one. At TN=16, DATA_W=8
//  the worst case is 16 * 127 * 128 = 260,096, which needs 19 signed bits
//  against TREE_W = 20.
//
//  ---- the control travels with the data (L-2) -------------------------
//
//  The tree FREE-RUNS: it is not clock-enabled. Only the accumulator is gated.
//  That is deliberate and it is what makes a stall safe - the activation and
//  weight buffers hold their outputs when their read enable is low, so the
//  held value simply propagates through the tree, and the `valid` that travels
//  beside it in a shift register of the same depth arrives with it. Gating the
//  tree instead would need a clock enable on every level for no benefit.
//
//  Getting that delay wrong is the classic bug here: if valid/first/last
//  reached the accumulator early, `first` would clear it on the wrong tile and
//  every dot product in the network would be silently short.
//
//  ---- done, and the armed bit (L-10) ----------------------------------
//
//  `done` used to be `valid & last` unconditionally, so a `last` with no
//  preceding `first` announced a stale partial sum as a finished dot product.
//  A sticky `armed` bit now records that a `first` was actually seen. The
//  single-tile case (first and last in the same cycle - real here, IC=16
//  layers have n_ic=1) is covered by testing `armed | first` rather than
//  `armed`.
//
//  Run:  bash scripts/run_sim.sh mac_lane conv1x1
//============================================================================
// Force the multipliers into DSP48E2. Left on "auto", Vivado put almost all of
// them in fabric: the first synthesis run of accel_top used 191,372 LUTs (83%
// of the device) and only 72 DSPs, for a datapath that needs 512 multipliers
// in the pointwise array alone.
(* use_dsp = "yes" *)
module mac_lane #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TN     = 16,    // input channels processed per cycle
    parameter ACC_W  = 26     // accumulator width (matches HW / requantize in)
)(
    input  wire                     clock,
    input  wire                     rst_n,               // SYNCHRONOUS (DD-020)
    input  wire                     valid,               // Tn-wide tile valid
    input  wire                     first,               // first tile -> acc<-0
    input  wire                     last,                // final tile -> done
    input  wire [TN*DATA_W-1:0]     a,                   // Tn activations, packed
    input  wire [TN*DATA_W-1:0]     w,                   // Tn weights, packed
    output reg  signed [ACC_W-1:0]  acc,                 // running / final sum
    output reg                      done
);

    // ---- clog2, because Verilog-2001 has no $clog2 ---------------------
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam PROD_W  = 2*DATA_W;              // 16: an exact int8 x int8
    localparam LEVELS  = clog2(TN);             // 4 at TN=16
    localparam TREE_W  = PROD_W + LEVELS;       // 20: proven above
    localparam CTRL_LAT = 1 + LEVELS;           // product + tree = 5
    localparam MAC_LAT  = CTRL_LAT + 1;         // + accumulate = 6

    // ---- TN must be a power of two -------------------------------------
    //  The tree halves the node count at every level, so an odd count would
    //  silently drop a tap. Verilog-2001 has no $fatal at elaboration, so the
    //  check instantiates a module that does not exist and the tool prints its
    //  name, which IS the error message.
    generate
        if ((1 << LEVELS) != TN) begin : chk_tn_pow2
            ERROR_MAC_LANE_TN_MUST_BE_A_POWER_OF_TWO u_err();
        end
        if (ACC_W < TREE_W) begin : chk_acc_w
            ERROR_MAC_LANE_ACC_W_NARROWER_THAN_ONE_TILE_SUM u_err();
        end
    endgenerate

    integer i;

    // ================= stage 0 : one registered product per tap =========
    //  Explicitly PROD_W wide (L-9). The old code multiplied inside an ACC_W
    //  assignment, which sign-extended both operands to 26 bits first; exact,
    //  but it made the width a property of the surrounding expression rather
    //  than of the arithmetic.
    reg signed [PROD_W-1:0] prod [0:TN-1];

    always @(posedge clock) begin
        if (!rst_n) begin
            for (i = 0; i < TN; i = i + 1) prod[i] <= {PROD_W{1'b0}};
        end else begin
            for (i = 0; i < TN; i = i + 1)
                prod[i] <= $signed(a[i*DATA_W +: DATA_W]) *
                           $signed(w[i*DATA_W +: DATA_W]);
        end
    end

    // ================= stages 1..LEVELS : the balanced adder tree =======
    //  One flat array of TN-1 nodes holding every level, because Verilog-2001
    //  cannot declare a ragged array of per-level vectors. Level 1 occupies the
    //  first TN/2 slots, level 2 the next TN/4, and so on; the total is
    //  TN/2 + TN/4 + ... + 1 = TN-1 and the final sum is the last slot.
    //
    //  Non-blocking assignment is what makes this a pipeline: level L reads the
    //  slots level L-1 wrote on the PREVIOUS edge, so each level is one clock.
    reg signed [TREE_W-1:0] node [0:TN-2];

    integer lv, k, off, prev, cnt;

    always @(posedge clock) begin
        if (!rst_n) begin
            for (k = 0; k < TN-1; k = k + 1) node[k] <= {TREE_W{1'b0}};
        end else begin
            // level 1 reads the products
            for (k = 0; k < TN/2; k = k + 1)
                node[k] <= $signed(prod[2*k]) + $signed(prod[2*k+1]);

            // levels 2..LEVELS read the level below them
            off = 0;
            cnt = TN/2;
            for (lv = 2; lv <= LEVELS; lv = lv + 1) begin
                prev = off;
                off  = off + cnt;
                cnt  = cnt >> 1;
                for (k = 0; k < cnt; k = k + 1)
                    node[off + k] <= node[prev + 2*k] + node[prev + 2*k + 1];
            end
        end
    end

    wire signed [TREE_W-1:0] tile_sum = node[TN-2];

    // ================= the control, delayed to meet the sum (L-2) =======
    //  A free-running shift register of exactly CTRL_LAT stages, because the
    //  tree it shadows free-runs too. Depth is derived from LEVELS, so it
    //  cannot drift from the structure it describes.
    reg [CTRL_LAT-1:0] v_sr, f_sr, l_sr;

    always @(posedge clock) begin
        if (!rst_n) begin
            v_sr <= {CTRL_LAT{1'b0}};
            f_sr <= {CTRL_LAT{1'b0}};
            l_sr <= {CTRL_LAT{1'b0}};
        end else begin
            v_sr <= {v_sr[CTRL_LAT-2:0], valid};
            f_sr <= {f_sr[CTRL_LAT-2:0], first};
            l_sr <= {l_sr[CTRL_LAT-2:0], last};
        end
    end

    wire v_q = v_sr[CTRL_LAT-1];       // aligned with tile_sum
    wire f_q = f_sr[CTRL_LAT-1];
    wire l_q = l_sr[CTRL_LAT-1];

    // ================= stage LEVELS+1 : accumulate ======================
    //  The ONE stage `valid` gates. tile_sum is TREE_W wide and signed, so the
    //  add sign-extends it into ACC_W.
    wire signed [ACC_W-1:0] base = f_q ? {ACC_W{1'b0}} : acc;

    always @(posedge clock) begin
        if (!rst_n)    acc <= {ACC_W{1'b0}};
        else if (v_q)  acc <= base + tile_sum;
    end

    // ================= done, with the armed bit (L-10) ==================
    reg armed;

    always @(posedge clock) begin
        if (!rst_n) begin
            armed <= 1'b0;
            done  <= 1'b0;
        end else begin
            // `armed | f_q` rather than `armed`: a dot product of ONE tile has
            // first and last in the same cycle and is legitimate - every layer
            // with IC <= TN has n_ic = 1.
            done <= v_q & l_q & (armed | f_q);

            if      (v_q & f_q) armed <= 1'b1;
            else if (v_q & l_q) armed <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // L-10, stated as a check rather than as a comment: a `last` with no
    // preceding `first` is a stale partial sum being announced as final.
    always @(posedge clock) begin
        if (rst_n && v_q && l_q && !armed && !f_q) begin
            $display("ERROR: %m L-10 `last` accumulated with no preceding `first` at time %0t: the accumulator holds a stale partial sum and `done` is being suppressed.",
                     $time);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
