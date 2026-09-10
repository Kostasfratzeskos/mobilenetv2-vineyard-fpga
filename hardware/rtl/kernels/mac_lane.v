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
//  does Tn MAC/cycle. The per-cycle Tn-product sum reuses the dwconv3x3 flat-MAC
//  structure; the first/last/done accumulate handshake is conv1x1's. Tm of these
//  lanes (sharing the same broadcast activations) form the P = Tm*Tn array.
//
//  Handshake (identical to conv1x1):
//    valid - a,w carry a valid Tn-wide tile this cycle -> accumulate
//    first - first tile of the dot product (acc <- 0)
//    last  - final tile -> `done` pulses next cycle (acc is then complete)
//
//  On the real ZCU104 the Tn products + sum map onto DSP48E2 cascades (int8
//  packing, PCOUT->PCIN). Here we describe it behaviourally and verify bit-exact.
//============================================================================
module mac_lane #(
    parameter DATA_W = 8,     // int8 activations and weights
    parameter TN     = 16,    // input channels processed per cycle
    parameter ACC_W  = 21     // accumulator width (matches HW / requantize in)
)(
    input  wire                     clock,
    input  wire                     rst_n,
    input  wire                     valid,               // Tn-wide tile valid
    input  wire                     first,               // first tile -> acc<-0
    input  wire                     last,                // final tile -> done
    input  wire [TN*DATA_W-1:0]     a,                   // Tn activations, packed
    input  wire [TN*DATA_W-1:0]     w,                   // Tn weights, packed
    output reg  signed [ACC_W-1:0]  acc,                 // running / final sum
    output reg                      done
);

    // ---- per-cycle Tn-product sum (combinational adder tree) ----------
    integer i;
    reg signed [ACC_W-1:0] partial;
    always @* begin
        partial = {ACC_W{1'b0}};
        for (i = 0; i < TN; i = i + 1)
            partial = partial + $signed(a[i*DATA_W +: DATA_W]) *
                                $signed(w[i*DATA_W +: DATA_W]);
    end

    // ---- accumulate across tiles (conv1x1 handshake) ------------------
    wire signed [ACC_W-1:0] base = first ? {ACC_W{1'b0}} : acc;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)     acc <= {ACC_W{1'b0}};
        else if (valid) acc <= base + partial;
    end

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) done <= 1'b0;
        else        done <= valid & last;
    end

endmodule

`default_nettype wire
