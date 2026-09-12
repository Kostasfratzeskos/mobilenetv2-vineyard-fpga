`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  dw_array.v  -  TC parallel dwconv3x3 engines = the depthwise array
//
//  Build plan #5. DD-014 sizes the depthwise at TC=16 channels in parallel, so
//  this is 16 copies of the already-proven dwconv3x3, each computing one
//  channel's 9-tap windowed dot product. TC x 9 = 144 multipliers = 72 DSP48E2
//  with int8 packing.
//
//  Depthwise has NO cross-channel accumulation - each output channel sees only
//  the same-index input channel - so the 16 engines never interact. There is no
//  adder tree across them and no broadcast: the opposite of pe_array, where all
//  32 lanes share one activation bus. That is also why the only axis available
//  to parallelise depthwise is the channel count.
//
//  ---- this module is a TRANSPOSITION ----------------------------------
//
//  Its whole content is putting two different bus orders in touch:
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
//  ---- ACC_W = 21 is PROVABLY enough here ------------------------------
//
//  Worth stating, because it differs from the pointwise side. A depthwise dot
//  product is always exactly K*K = 9 taps, so the worst case is
//
//      9 * 128 * 127 = 146,304   ->  needs 19 bits signed
//
//  against the 21-bit accumulator's +-1,048,576. Unlike pe_array, where IC
//  reaches 960 and 21 bits is a data-dependent PRECONDITION (measured at 5 bits
//  of headroom in pw_datapath_tb), here it is a bound: no input can overflow
//  it. The testbench therefore runs full-range random int8 at the real width.
//
//  Purely combinational, like the dwconv3x3 it wraps: it sits between
//  line_buffer's registered window and the requantize stage.
//============================================================================
module dw_array #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TC     = 16,    // channels in parallel (DD-014)
    parameter K      = 3,     // KxK depthwise kernel
    parameter ACC_W  = 21     // accumulator width; provably sufficient, see above
)(
    input  wire [K*K*TC*DATA_W-1:0] win,   // from line_buffer: tap-major
    input  wire [TC*K*K*DATA_W-1:0] wk,    // from wgt_buffer: channel-major
    output wire [TC*ACC_W-1:0]      acc    // one accumulator per channel
);

    localparam NT = K*K;      // taps per channel (9)

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
                .win (win_c),
                .wk  (wk[c*NT*DATA_W +: NT*DATA_W]),
                .acc (acc[c*ACC_W +: ACC_W])
            );
        end
    endgenerate

endmodule

`default_nettype wire
