`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  dw_array.v  -  TC parallel dwconv3x3 engines = the depthwise array
//
//  Build plan #5. DD-014 sizes the depthwise at TC=16 channels in parallel, so
//  this is 16 copies of dwconv3x3, each computing one channel's 9-tap windowed
//  dot product. TC x 9 = 144 multipliers.
//
//  Depthwise has NO cross-channel accumulation - each output channel sees only
//  the same-index input channel - so the 16 engines never interact. There is no
//  adder tree across them and no broadcast: the opposite of pe_array, where all
//  32 lanes share one activation bus. That is also why the only axis available
//  to parallelise depthwise is the channel count.
//
//  ---- this module is a TRANSPOSITION, plus the latency (A-2) -----------
//
//  Most of its content is putting two different bus orders in touch:
//
//      line_buffer gives  win[((ky*K + kx)*TC + c)*8]   tap-major, channel-minor
//                         (natural: a window column is TC channels wide)
//      wgt_buffer  gives  wk [((c*K*K) + i)*8]          channel-major, tap-minor
//                         (natural: bank c IS channel c, 9 bytes deep)
//      dwconv3x3 wants    win[i*8] for ONE channel      tap-major, one channel
//
//  So the weights arrive already contiguous per channel and pass straight
//  through, while the window has to be gathered with a TC-byte stride. Getting
//  that stride wrong would mix channels while still producing plausible sums,
//  which is what the testbench is built to catch.
//
//  ---- A-2: the latency is in the PORT LIST now ------------------------
//
//  This module had no clock, no valid and no done, and dw_feeder derived the
//  downstream valid as a one-line `assign os_acc_valid = win_valid;` - correct
//  only while the array was combinational. L-1 made dwconv3x3 a five-stage
//  pipeline, and the review's point was that adding that latency would have made
//  the feeder's line wrong by five cycles with no width mismatch, no elaboration
//  error and no standalone-testbench failure. Nothing would have said so.
//
//  So the latency is expressible here: `valid` in, `valid_out` out, and
//  DW_LAT derived from K the same way dwconv3x3 derives it. The feeder now
//  connects a wire instead of asserting an equality.
//
//  ONE shift register for all TC channels, not TC copies: every engine sees the
//  same window timing and none of them looks at its own data, so one 5-bit
//  register is the whole control cost of the array.
//
//  ---- ACC_W = 26 is PROVABLY enough here ------------------------------
//
//  Worth stating, because it differs from the pointwise side. A depthwise dot
//  product is always exactly K*K = 9 taps, so the worst case is
//
//      9 * 128 * 127 = 146,304   ->  needs 19 bits signed
//
//  against the 26-bit accumulator's +-33,554,432. Unlike pe_array, where IC
//  reaches 960 and 21 bits was a data-dependent PRECONDITION, here it is a
//  bound: no input can overflow it. The testbench therefore runs full-range
//  random int8 at the real width.
//
//  Run:  bash scripts/run_sim.sh dw_array dwconv3x3
//============================================================================
module dw_array #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TC     = 16,    // channels in parallel (DD-014)
    parameter K      = 3,     // KxK depthwise kernel
    parameter ACC_W  = 26     // accumulator width; provably sufficient, see above
)(
    input  wire                     clock,
    input  wire                     rst_n,     // SYNCHRONOUS (DD-020)
    input  wire                     valid,     // win/wk carry a real window
    input  wire [K*K*TC*DATA_W-1:0] win,       // from line_buffer: tap-major
    input  wire [TC*K*K*DATA_W-1:0] wk,        // from wgt_buffer: channel-major
    // A-4's counterpart: declared SIGNED, because these carry signed
    // accumulators and a part-select is unsigned whatever the parent bus is.
    // The consumers keep their own $signed() casts; this states the intent at
    // the source.
    output wire signed [TC*ACC_W-1:0] acc,     // one accumulator per channel
    output wire                       valid_out // `acc` is final this cycle
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam NT     = K*K;                // taps per channel (9)
    // dwconv3x3's latency, derived from the same inputs it derives it from:
    // one registered product stage plus clog2(NT) adder-tree levels. There is
    // no accumulate stage - a depthwise window completes in one pass.
    localparam DW_LAT = 1 + clog2(NT);      // 5 at K=3

    // ---- the control, travelling beside a free-running pipeline ---------
    reg [DW_LAT-1:0] v_sr;

    always @(posedge clock) begin
        if (!rst_n) v_sr <= {DW_LAT{1'b0}};
        else        v_sr <= {v_sr[DW_LAT-2:0], valid};
    end

    assign valid_out = v_sr[DW_LAT-1];

    genvar c, i;
    generate
        for (c = 0; c < TC; c = c + 1) begin : ch
            // gather this channel's nine taps out of the tap-major window
            wire [NT*DATA_W-1:0] win_c;
            for (i = 0; i < NT; i = i + 1) begin : tap
                assign win_c[i*DATA_W +: DATA_W] =
                       win[((i*TC) + c)*DATA_W +: DATA_W];
            end

            // the weights are already contiguous per channel
            dwconv3x3 #(
                .DATA_W (DATA_W),
                .K      (K),
                .ACC_W  (ACC_W)
            ) u_dw (
                .clock (clock),
                .rst_n (rst_n),
                .win   (win_c),
                .wk    (wk[c*NT*DATA_W +: NT*DATA_W]),
                .acc   (acc[c*ACC_W +: ACC_W])
            );
        end
    endgenerate

endmodule

`default_nettype wire
