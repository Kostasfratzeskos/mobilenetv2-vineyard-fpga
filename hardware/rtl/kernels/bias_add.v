`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  bias_add.v  -  add a per-output-channel int32 bias to an accumulator
//
//  Hardware twin of bias_add() in software/cmodel/src/mobilenet.c :
//        acc[i] += bias[i % C]
//
//  As a HW engine this is ONE add: acc_out = acc_in + bias. The per-channel
//  selection (i % C -> which bias) is the controller's job, exactly like
//  conv1x1 computes one dot product and the controller sequences it.
//
//  Pure COMBINATIONAL, stateless: no clock, no accumulation. It sits between
//  the conv accumulator register and the requantize register.
//
//  Widths: acc_in / acc_out are ACC_W - the 26-bit HW accumulator that feeds
//  requantize (26 since d5fb32b / DD-019, and this comment said 21 until
//  L-15 caught it). The manifest bias is int32, so BIAS_W defaults to 32; the
//  signed add sign-extends acc_in and the ACC_W result truncates the sum.
//
//  PRECONDITION, and it is load-bearing: the post-bias accumulator never
//  overflows ACC_W, so the truncation is exact. That precondition is the one
//  the 2026-07 regression violated - a bias of 1,184,089 did not fit ACC_W=21
//  on its own, wrapped negative here, and corrupted 2.2M elements downstream in
//  silence. It is enforced by export.py's provable bound (DD-019) and, since
//  L-12, WATCHED in simulation by rq_bank and logit_out, which are this
//  module's only two instantiators. The check is not in here because this module
//  is combinational with no clock and no enable, so it cannot tell a real sum
//  from a settling transient; those two can.
//============================================================================
module bias_add #(
    parameter ACC_W  = 26,    // accumulator width (in and out)
    parameter BIAS_W = 32     // int32 bias as stored in the manifest
)(
    input  wire signed [ACC_W-1:0]  acc_in,
    input  wire signed [BIAS_W-1:0] bias,
    output wire signed [ACC_W-1:0]  acc_out
);

    // signed add: acc_in is sign-extended to the wider operand, the sum is
    // truncated back to ACC_W (exact while it does not overflow).
    assign acc_out = acc_in + bias;

endmodule

`default_nettype wire
