`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  stem_array.v  -  TS parallel conv3x3_std engines for the network's stem
//
//  Build plan #6, the STEM opcode. TS=8 copies of the already-proven
//  conv3x3_std, each computing one output channel of one pixel from the same
//  27-tap window: 3 input channels x 3x3.
//
//  ---- why TS = 8 (DD-016) ---------------------------------------------
//
//  The stem streams 225x225 input pixel-groups (the image plus the virtual
//  edge) and emits 112x112 windows, so there are exactly 4 input cycles per
//  window. With OC=32 that means 32/4 = 8 output channels per cycle is the
//  point where the compute stops being the limit and the input stream becomes
//  it. Measured over the whole network:
//
//      Ts   DSPs   stem ms   total ms   fps
//       1     14      1.76       4.97   201
//       4     54      0.55       3.76   266
//       8    108      0.35       3.56   281   <-- knee
//      16    216      0.25       3.46   289
//      32    432      0.20       3.41   293
//
//  Past 8 the input streaming dominates and more DSPs buy almost nothing: 16
//  costs another 108 DSPs for 3% of runtime.
//
//  ---- broadcast, like pe_array, not per-lane like dw_array ------------
//
//  A standard convolution sums over BOTH the window and the input channels, so
//  every output channel reads the SAME 27 activations and differs only in its
//  weights - the pe_array arrangement. The depthwise is the opposite: no
//  cross-channel sum, so each lane gets its own window. Both arrays are 27 or
//  9 taps wide; what differs is whether the activations are shared.
//
//  ---- the transposition ------------------------------------------------
//
//  line_buffer emits tap-major, channel-minor, because a window column is
//  naturally CIN channels wide:
//        win[((ky*K + kx)*CIN + c)*8]
//  conv3x3_std wants the C model's order, channel-major:
//        win[((c*K + ky)*K + kx)*8]
//  So the window is transposed ONCE here and then broadcast, rather than per
//  lane. The weights already arrive in conv3x3_std's order because the
//  manifest stores (OC, IC, KH, KW) row-major, which is the same thing.
//
//  ---- ACC_W = 21 -------------------------------------------------------
//
//  27 taps bound the sum at 27*128*127 = 439,  well inside 21 bits:
//  27 * 128 * 127 = 438,912, which needs 20 bits signed. Tighter than the
//  depthwise's 9 taps but still a bound rather than a precondition, unlike the
//  pointwise array where IC reaches 1280.
//
//  Purely combinational, like the conv3x3_std it wraps.
//============================================================================
module stem_array #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TS     = 8,     // output channels in parallel (DD-016)
    parameter CIN    = 3,     // input channels (the image)
    parameter K      = 3,     // KxK spatial kernel
    parameter ACC_W  = 21
)(
    input  wire [K*K*CIN*DATA_W-1:0]    win,  // from line_buffer: tap-major
    input  wire [TS*CIN*K*K*DATA_W-1:0] wk,   // per-lane, already conv-ordered
    output wire [TS*ACC_W-1:0]          acc
);

    localparam NT = CIN*K*K;      // 27 taps per output element

    // ---- transpose once, then broadcast ---------------------------------
    wire [NT*DATA_W-1:0] win_c;

    genvar c, ky, kx, m;
    generate
        for (c = 0; c < CIN; c = c + 1) begin : ch
            for (ky = 0; ky < K; ky = ky + 1) begin : row
                for (kx = 0; kx < K; kx = kx + 1) begin : col
                    assign win_c[((c*K + ky)*K + kx)*DATA_W +: DATA_W] =
                           win[(((ky*K + kx)*CIN) + c)*DATA_W +: DATA_W];
                end
            end
        end
    endgenerate

    // ---- TS lanes sharing that window -----------------------------------
    generate
        for (m = 0; m < TS; m = m + 1) begin : lane
            conv3x3_std #(
                .DATA_W (DATA_W),
                .K      (K),
                .CIN    (CIN),
                .ACC_W  (ACC_W)
            ) u_conv (
                .win (win_c),                              // shared
                .wk  (wk[m*NT*DATA_W +: NT*DATA_W]),       // per lane
                .acc (acc[m*ACC_W +: ACC_W])
            );
        end
    endgenerate

endmodule

`default_nettype wire
