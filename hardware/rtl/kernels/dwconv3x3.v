`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  dwconv3x3.v  -  depthwise KxK convolution == parallel 9-tap MAC (one channel)
//
//  Hardware twin of the inner window of dwconv3x3() in
//      software/cmodel/src/mobilenet.c
//
//  Depthwise means each output channel depends only on the SAME input channel
//  (no sum across channels). For one output element (channel c, pixel oy,ox):
//        acc = sum_{ky,kx}  window[ky,kx] * kernel_c[ky,kx]      (up to KxK taps)
//
//  This engine computes ONE such windowed dot product, in parallel (a small
//  fixed KxK multiply-add tree). Unlike conv1x1 (large, variable channel depth
//  -> streamed one MAC/cycle), the depthwise window is a fixed 3x3 = 9 taps, so
//  a combinational tree fits the shape of the computation.
//
//  Zero-padding at image borders is the FEEDER's job: it drives 0 into any tap
//  that falls outside the image (0 * w = 0), exactly like the C `continue`. The
//  window generation / addressing lives in the controller, not here.
//
//  Tap ordering: index i = ky*K + kx (row-major within the window). `win` and
//  `wk` must use the SAME ordering; the sum is order-independent anyway.
//============================================================================
module dwconv3x3 #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter K      = 3,     // KxK kernel (3x3 depthwise)
    parameter ACC_W  = 21     // accumulator width (matches HW / requantize in)
)(
    input  wire [K*K*DATA_W-1:0]   win,   // KxK activation window, tap-major
    input  wire [K*K*DATA_W-1:0]   wk,    // KxK weights for this channel
    output wire signed [ACC_W-1:0] acc
);

    integer i;
    reg signed [ACC_W-1:0] sum;

    // combinational KxK multiply-accumulate. Each tap is sign-reinterpreted
    // ($signed on the part-select) so the product is a signed 16-bit value,
    // sign-extended into the ACC_W running sum.
    always @* begin
        sum = {ACC_W{1'b0}};
        for (i = 0; i < K*K; i = i + 1)
            sum = sum + $signed(win[i*DATA_W +: DATA_W]) *
                        $signed(wk [i*DATA_W +: DATA_W]);
    end

    assign acc = sum;

endmodule

`default_nettype wire
