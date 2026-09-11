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
//  Run:  bash scripts/run_sim.sh pe_array mac_lane conv1x1
//============================================================================
module pe_array #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TM     = 32,    // output channels (lanes) in parallel
    parameter TN     = 16,    // input channels per cycle, per lane
    parameter ACC_W  = 21     // accumulator width (matches HW / requantize in)
)(
    input  wire                       clock,
    input  wire                       rst_n,     // async active-low reset
    input  wire                       valid,     // a,w carry a valid tile
    input  wire                       first,     // first tile -> acc <- 0
    input  wire                       last,      // final tile -> done next cycle
    input  wire [TN*DATA_W-1:0]       a,         // BROADCAST to every lane
    input  wire [TM*TN*DATA_W-1:0]    w,         // per-lane weight slices
    output wire [TM*ACC_W-1:0]        acc,       // Tm accumulators, packed
    output wire                       done       // 1 the cycle acc becomes final
);

    // Per-lane done. Every lane sees the same valid/first/last, so they run in
    // lockstep and these are all identical; lane 0 is taken as representative
    // and the rest are left for synthesis to prune. Deriving `done` from a real
    // lane (rather than re-deriving it here) keeps it aligned with `acc` by
    // construction - the two update on the same clock edge inside mac_lane.
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

endmodule

`default_nettype wire
