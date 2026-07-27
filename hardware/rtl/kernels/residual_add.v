`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  residual_add.v  -  quantized residual (skip) add: rescale `saved`, then add
//
//  Hardware twin of residual_add() in software/cmodel/src/mobilenet.c :
//        out = clamp_i8( requantize_elem(saved, m0, shift, ACT_NONE) + target )
//
//  `target` is the main-path output (int8), already at the output scale.
//  `saved`  is the block input / skip activation (int8) at a DIFFERENT scale;
//  (m0,shift) rescale it onto the output scale (the requantize core, no ReLU).
//  Then the two int8 values are added and saturated back to int8.
//
//  NOTE on the final saturation: the C reference assigns the sum to int8_t,
//  which TRUNCATES (wraps) rather than clamps -- its header comment says
//  "clamped". On real data the residual sum fits int8 so the two agree; we
//  implement the saturating CLAMP here because it matches the intended /
//  standard quantized-add semantics (and thus the Python golden). Switching to
//  truncation would just be dropping the final clamp below.
//
//  Pure COMBINATIONAL, stateless (like bias_add). Reuses the requantize math.
//============================================================================
module residual_add #(
    parameter DATA_W  = 8,     // int8 target / saved / out
    parameter M0_W    = 32,    // rescale multiplier width
    parameter SHIFT_W = 6      // rescale shift width (>=1)
)(
    input  wire signed [DATA_W-1:0]  target,   // main path (already at out scale)
    input  wire signed [DATA_W-1:0]  saved,    // skip input (different scale)
    input  wire signed [M0_W-1:0]    m0,       // rescale multiplier for `saved`
    input  wire        [SHIFT_W-1:0] shift,    // rescale shift (>= 1)
    output reg  signed [DATA_W-1:0]  out
);

    localparam PROD_W  = DATA_W + M0_W;   // saved * m0, no truncation
    localparam ROUND_W = PROD_W + 1;      // +1 for the +half add

    // ---- rescale `saved` onto the output scale (requantize core, ACT_NONE) --
    wire signed [PROD_W-1:0]  prod    = saved * m0;
    wire signed [ROUND_W-1:0] one     = 1;
    wire signed [ROUND_W-1:0] half    = one << (shift - 1'b1);
    wire signed [ROUND_W-1:0] shifted = (prod + half) >>> shift;

    // clamp_i8 the rescaled saved (literals are 32-bit signed -> signed compare)
    reg signed [DATA_W-1:0] saved_q;
    always @* begin
        if      (shifted < -128) saved_q = -128;
        else if (shifted >  127) saved_q =  127;
        else                     saved_q = shifted[DATA_W-1:0];
    end

    // ---- add target, then saturate to int8 ---------------------------------
    // sum needs one extra bit: int8 + int8 spans [-256, 254].
    wire signed [DATA_W:0] sum = saved_q + target;
    always @* begin
        if      (sum < -128) out = -128;
        else if (sum >  127) out =  127;
        else                 out = sum[DATA_W-1:0];
    end

endmodule

`default_nettype wire
