`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  conv3x3_std.v  -  standard KxK convolution == flat MAC over window x channels
//
//  Hardware twin of the inner sums of conv3x3_std() in
//      software/cmodel/src/mobilenet.c   (the stem: Cin=3, OC=32, K=3, S=2)
//
//  For one output element (channel oc, pixel oy,ox), a standard conv sums over
//  BOTH the KxK spatial window AND the input channels:
//        acc = sum_{ky,kx,ic}  a[iy,ix,ic] * w[oc,ic,ky,kx]
//  i.e. a dot product over NT = K*K*CIN taps. This is the depthwise 9-tap MAC
//  (dwconv3x3) generalized with the channel dimension -- same flat multiply-add
//  structure, just more taps. Kept as its own named engine for the 1:1 mapping
//  to the C op / golden vectors; a production design might share one MAC.
//
//  Because the stem window x channels (3*3*3 = 27) is small and fixed, this is a
//  parallel combinational tree (like dwconv3x3), not a streamed accumulator.
//
//  Zero-padding at image borders is the FEEDER's job (drive 0 into padded taps).
//  Tap ordering is arbitrary but `win` and `wk` must agree; the sum is
//  order-independent. The C uses i = (ic*K + ky)*K + kx within an oc block.
//============================================================================
module conv3x3_std #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter K      = 3,     // KxK spatial kernel
    parameter CIN    = 3,     // input channels (3 for the stem)
    parameter ACC_W  = 21     // accumulator width (matches HW / requantize in)
)(
    input  wire [K*K*CIN*DATA_W-1:0] win,   // window x channels, tap-major
    input  wire [K*K*CIN*DATA_W-1:0] wk,    // matching weights for this oc
    output wire signed [ACC_W-1:0]   acc
);

    localparam NT = K*K*CIN;   // taps per output element (27 for the stem)

    integer i;
    reg signed [ACC_W-1:0] sum;

    always @* begin
        sum = {ACC_W{1'b0}};
        for (i = 0; i < NT; i = i + 1)
            sum = sum + $signed(win[i*DATA_W +: DATA_W]) *
                        $signed(wk [i*DATA_W +: DATA_W]);
    end

    assign acc = sum;

endmodule

`default_nettype wire
