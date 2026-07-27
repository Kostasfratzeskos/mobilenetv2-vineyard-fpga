`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  conv1x1.v  -  pointwise (1x1) convolution == streaming dot-product MAC
//
//  Hardware twin of the inner loop of conv1x1() in
//      software/cmodel/src/mobilenet.c
//
//  A 1x1 conv has stride=1, pad=0, so spatially it is the identity: every
//  output pixel maps to one input pixel. All that remains, per output element
//  (one output channel `oc` at one pixel), is a dot product over the input
//  channels:
//        acc = sum_ic  a[ic] * w[oc,ic]        (i8 * i8 -> accumulate)
//
//  This engine computes ONE dot product, streamed one (a,w) pair per cycle.
//  The controller sequences it over pixels x output-channels and feeds the
//  accumulator to bias_add / requantize. Keeping it a single-MAC stream makes
//  it trivially bit-exact; widening to N MACs/cycle is a later optimization.
//
//  Handshake:
//    valid  - `a` and `w` carry a valid pair this cycle -> accumulate
//    first  - this valid pair is the first of a new dot product (acc <- 0)
//    last   - this valid pair is the final element -> `done` pulses next cycle
//  When `done` is high, `acc` holds the completed dot product (same edge).
//============================================================================
module conv1x1 #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter ACC_W  = 21     // accumulator width (matches HW / requantize in)
)(
    input  wire                     clock,
    input  wire                     rst_n,     // async active-low reset
    input  wire                     valid,     // a,w are a valid pair this cycle
    input  wire                     first,     // start a fresh dot product
    input  wire                     last,      // final element of the dot product
    input  wire signed [DATA_W-1:0] a,         // activation element
    input  wire signed [DATA_W-1:0] w,         // weight element
    output reg  signed [ACC_W-1:0]  acc,       // running / final accumulator
    output reg                      done       // 1 the cycle acc becomes final
);

    // i8 * i8 -> 16-bit signed product (both operands signed => signed result)
    wire signed [2*DATA_W-1:0] prod = a * w;

    // base = 0 on the first element, else the running accumulator. Signed add
    // sign-extends `prod` up to ACC_W automatically.
    wire signed [ACC_W-1:0] base = first ? {ACC_W{1'b0}} : acc;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)     acc <= {ACC_W{1'b0}};
        else if (valid) acc <= base + prod;
    end

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) done <= 1'b0;
        else        done <= valid & last;   // aligned with the final acc update
    end

endmodule

`default_nettype wire
