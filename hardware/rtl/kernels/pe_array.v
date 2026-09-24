`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  pe_array.v  -  Tm parallel mac_lane lanes = the pointwise MAC array
//
//  Build plan #2 of docs/controller_design.md section 5. Tm output-channel
//  lanes share ONE broadcast activation tile, so the array computes Tm dot
//  products at once, Tn terms per cycle each:
//        P = Tm * Tn = 32 * 16 = 512 MACs/cycle        (DD-013)
//
//  Why the shape is asymmetric: a 1x1 conv reuses the SAME input activations
//  for every output channel, so `a` is wired to all Tm lanes while each lane
//  keeps its own weights. That asymmetry is also the buffer-bandwidth story -
//  activations are Tn*8 = 128 bit/cycle (one URAM word, trivial), weights are
//  Tm*Tn*8 = 4096 bit/cycle (the hard one: Tm banks, Tn wide).
//
//  This module is pure structural wiring - no arithmetic of its own. All the
//  math, and the first/last/done handshake, live in mac_lane.
//
//  Bus layout (the feeder must produce exactly this):
//    a  [j*DATA_W +: DATA_W]            input channel j of the tile
//    w  [(m*TN + j)*DATA_W +: DATA_W]   lane m's weight for input channel j
//    acc[m*ACC_W +: ACC_W]              lane m's accumulator
//  Weights are oc-major / ic-minor, which is exactly the manifest's
//  w[oc*IC + ic] ordering, so the feeder can copy a contiguous run per lane.
//
//  Tail tiles (OC not a multiple of Tm, or IC not a multiple of Tn) are the
//  FEEDER's job: it drives zero weights into the unused lanes and taps, which
//  contribute 0 to the sum. Bit-exact; only utilization is lost - 7.9% over
//  the whole network, measured in scripts/analyze_workload.py (DD-013).
//
//  ---- LATENCY: this array is no longer transparent ---------------------
//
//  mac_lane is pipelined now (L-1): a registered product stage, clog2(TN)
//  adder-tree levels, and the accumulator, so MAC_LAT = 1 + clog2(TN) + 1 = 6.
//  A-1 then added ONE more stage in front of the lanes, here in this module
//  (see below), so the array's latency is ARR_LAT = 1 + MAC_LAT = 7 - where it
//  used to be 1. The feeder's tag pipeline and drain counter are defined
//  against ARR_LAT, not MAC_LAT - see docs/latency_map.md, which lists every
//  constant that moves when either changes.
//
//  ---- lane 0's `done`, and the invariant behind it (A-3) ---------------
//
//  Every lane sees the same valid/first/last and none of them looks at its own
//  data, so they run in lockstep and their `done` outputs are identical. Lane
//  0 is taken as representative. Deriving `done` from a real lane rather than
//  re-deriving it here keeps it aligned with `acc` by construction - the two
//  update on the same clock edge inside mac_lane.
//
//  That lockstep used to be asserted in this comment and enforced nowhere.
//  It is CHECKED now, in simulation, against all TM lanes - which also gives
//  the other TM-1 `done` bits a reader, so they stop tripping unused-signal
//  lint every run (A-6). Training yourself to ignore that warning is how a
//  genuinely disconnected lane gets missed.
//
//  This paragraph used to predict that A-1 would deliberately BREAK the
//  invariant - that a registered broadcast would make lane 0 finish G-1 cycles
//  before the last group, so `done` would strobe over a stale acc bus, and that
//  `done` would have to come from the LAST group with the early groups'
//  accumulators de-skewed. A-1 has landed and NONE of that happened, because
//  the register went somewhere else. DD-022 measured the path first:
//
//      act_buffer URAM cascade    2.682 ns   (44%)
//      sel_q half-entry mux       0.700 ns   (12%)
//      the broadcast itself       1.279 ns   (21%)   one net, fanout 115
//      DSP48E2 multiply           1.405 ns   (23%)
//                                 -------
//                                 6.066 ns   against a 4.023 ns requirement
//
//  The broadcast is real, and it is NOT the dominant term - so a grouped chain
//  was solving the wrong 21%. What the budget asked for was a register between
//  the MEMORY READ and the broadcast, and one is enough: the input stage below
//  splits 6.066 into 3.382 (URAM + mux) and 2.684 (broadcast + multiply), and
//  both fit. One register, not G groups.
//
//  And because that register is in front of ALL the lanes, every lane still
//  sees the same valid/first/last on the same cycle. The lockstep invariant is
//  untouched, `done = lane_done[0]` stays correct, and there is no de-skew to
//  do. A-3's fix was never needed; A-3's complaint - that the invariant was
//  asserted in a comment and enforced nowhere - was, and the check below is it.
//
//  Run:  bash scripts/run_sim.sh pe_array mac_lane conv1x1
//============================================================================
module pe_array #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TM     = 32,    // output channels (lanes) in parallel
    parameter TN     = 16,    // input channels per cycle, per lane
    parameter ACC_W  = 26     // accumulator width (matches HW / requantize in)
)(
    input  wire                       clock,
    input  wire                       rst_n,     // SYNCHRONOUS (DD-020)
    input  wire                       valid,     // a,w carry a valid tile
    input  wire                       first,     // first tile -> acc <- 0
    input  wire                       last,      // final tile -> done in ARR_LAT
    input  wire [TN*DATA_W-1:0]       a,         // BROADCAST to every lane
    input  wire [TM*TN*DATA_W-1:0]    w,         // per-lane weight slices
    // A-4: declared SIGNED. Every one of the six consumer sites already passes
    // these part-selects into a signed formal, so there is no live defect - but
    // a part-select is unsigned whatever the parent bus is, so the safety
    // depended on every future consumer remembering, with no compile error if
    // one forgot. Declaring the bus signed states the intent at the source; the
    // consumers keep their own $signed() casts, which is what actually binds.
    output wire signed [TM*ACC_W-1:0] acc,       // Tm accumulators, packed
    output wire                       done       // 1 the cycle acc becomes final
);

    // ---- A-5: parameters that the wiring silently depends on ------------
    //  Verilog extends or truncates a mismatched port connection without a
    //  word, and wgt_buffer is instantiated three times with three different
    //  shapes, so a transposed or stale pair is a realistic mistake. What this
    //  module can check is its OWN consistency; the width of the `w` bus it is
    //  handed is checked at the other end, by wgt_buffer's C-6 guards.
    //  Verilog-2001 has no $fatal at elaboration, so a failing guard
    //  instantiates a module that does not exist and the tool prints its name.
    generate
        if (TM <= 0) begin : chk_tm
            ERROR_PE_ARRAY_TM_MUST_BE_POSITIVE u_err();
        end
        if (TN <= 0) begin : chk_tn
            ERROR_PE_ARRAY_TN_MUST_BE_POSITIVE u_err();
        end
        if ((TN & (TN - 1)) != 0) begin : chk_tn_pow2
            // mac_lane's adder tree halves the node count per level
            ERROR_PE_ARRAY_TN_MUST_BE_A_POWER_OF_TWO u_err();
        end
        if (TM < TN) begin : chk_shape
            // the array is Tm lanes of Tn taps; TM < TN means the weight bus
            // layout in the header no longer describes the wiring
            ERROR_PE_ARRAY_TM_MUST_BE_AT_LEAST_TN u_err();
        end
    endgenerate

    // ---- A-1: the registered broadcast input stage (DD-022, option B) ---
    //
    //  This is the one register the measured budget asked for, and the reason
    //  this module is no longer "pure structural wiring". See the header for
    //  the path decomposition; the short version is that the activation read
    //  and the fanout-115 broadcast were in the SAME clock cycle, and they are
    //  now in two.
    //
    //  `w` is registered here too, and that is a deliberate amendment to
    //  DD-022 as proposed. The alternative was to leave `w` alone and issue the
    //  weight read one cycle later in the feeder, which is 4,096 flip-flops
    //  cheaper - but it re-times two independent read streams against each
    //  other inside the feeder's address arithmetic, to save 0.9% of this
    //  device's registers, in a phase whose whole discipline is that no value
    //  may change. It also happens to be worse for timing: registering `w`
    //  here puts wgt_buffer's read in stage 1 and the per-lane B pins in stage
    //  2, which pre-empts the weight path becoming the next critical one - the
    //  exact risk DD-022 named as unquantified. Cheaper is not the same as
    //  better when the cheap version buys a new unknown.
    //
    //  a_q and w_q must move TOGETHER or the lanes pair operands from different
    //  tiles, which is a wrong VALUE rather than a wrong time - so they share
    //  one always block and always will.
    localparam LAT_IN = 1;                  // this stage, in cycles

    reg [TN*DATA_W-1:0]    a_q;
    reg [TM*TN*DATA_W-1:0] w_q;
    reg                    v_q, f_q, l_q;

    always @(posedge clock) begin
        if (!rst_n) begin
            a_q <= {TN*DATA_W{1'b0}};
            w_q <= {TM*TN*DATA_W{1'b0}};
            v_q <= 1'b0;  f_q <= 1'b0;  l_q <= 1'b0;
        end else begin
            a_q <= a;
            w_q <= w;
            v_q <= valid;  f_q <= first;  l_q <= last;
        end
    end

    wire [TM-1:0] lane_done;

    genvar m;
    generate
        for (m = 0; m < TM; m = m + 1) begin : lane
            mac_lane #(
                .DATA_W (DATA_W),
                .TN     (TN),
                .ACC_W  (ACC_W)
            ) u_lane (
                .clock (clock),
                .rst_n (rst_n),
                .valid (v_q),
                .first (f_q),
                .last  (l_q),
                .a     (a_q),                                 // shared
                .w     (w_q[m*TN*DATA_W +: TN*DATA_W]),       // per lane
                .acc   (acc[m*ACC_W    +: ACC_W]),
                .done  (lane_done[m])
            );
        end
    endgenerate

    assign done = lane_done[0];

`ifndef SYNTHESIS
    // ---- A-3 / A-6: the lockstep invariant, checked ---------------------
    //  This is the whole reason `done = lane_done[0]` is allowed. It also
    //  READS every lane_done bit, so the TM-1 "unused signal" lint warnings
    //  that used to appear on every run are gone without a waiver.
    always @(posedge clock) begin
        if (rst_n && (lane_done != {TM{lane_done[0]}})) begin
            $display("ERROR: %m A-3 the lanes are NOT in lockstep at time %0t: lane_done = %b. `done` is taken from lane 0, so it is now announcing a result while other lanes' accumulators are still stale. A-1's input register feeds every lane the same v_q/f_q/l_q on the same cycle, so the only ways to reach this are a per-lane gate on that register or a lane whose controls are wired separately.",
                     $time, lane_done);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
