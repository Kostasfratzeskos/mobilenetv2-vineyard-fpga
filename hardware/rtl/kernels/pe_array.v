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
//  adder-tree levels, and the accumulator. `done` and `acc` therefore arrive
//  MAC_LAT = 1 + clog2(TN) + 1 = 6 cycles after the tile that produced them,
//  where they used to arrive in 1. The feeder's tag pipeline and drain counter
//  are defined against that number - see docs/latency_map.md, which lists
//  every constant that moves when it changes.
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
//  A-1 will deliberately BREAK this invariant: a registered broadcast makes
//  lane 0 finish G-1 cycles before the last group, so `done` would strobe
//  while two thirds of the 832-bit acc bus is still stale. When that lands,
//  `done` must come from the LAST group and the early groups' accumulators
//  must be de-skewed. The check below is what will say so, loudly, on the
//  first simulation rather than as a bit-exactness failure downstream.
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
    input  wire                       last,      // final tile -> done in MAC_LAT
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
                .valid (valid),
                .first (first),
                .last  (last),
                .a     (a),                                 // shared
                .w     (w  [m*TN*DATA_W +: TN*DATA_W]),     // per lane
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
            $display("ERROR: %m A-3 the lanes are NOT in lockstep at time %0t: lane_done = %b. `done` is taken from lane 0, so it is now announcing a result while other lanes' accumulators are still stale. If a registered broadcast was just added (A-1), `done` must come from the LAST group and the early groups' accumulators must be de-skewed.",
                     $time, lane_done);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
