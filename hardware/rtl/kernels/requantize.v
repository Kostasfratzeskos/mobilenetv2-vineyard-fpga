`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  requantize.v  -  int accumulator element  ->  int8 activation
//
//  Bit-exact hardware twin of requantize_elem() in
//      software/cmodel/src/requantize.c
//
//  Per element:
//      product = in_data * M0                  (full width, no truncation)
//      rounded = product + (1 << (shift-1))    (round half-up toward +inf)
//      r       = rounded >>> shift             (arithmetic shift = floor)
//      ACT_RELU6 : clamp to [0, relu6_qmax]
//      ACT_NONE  : clamp to [-128, 127]        (clamp_i8)
//
//  The math is combinational; the result is registered on `clock` when `en`.
//
//  NOTE: every operand in the arithmetic chain is `signed`. One unsigned
//  operand would silently turn the whole expression unsigned (breaking both
//  >>> and the compares), so the signedness here is load-bearing.
//============================================================================
module requantize #(
    parameter ACC_W   = 21,   // accumulator width (signed), matches the HW acc
    parameter M0_W    = 32,   // fixed-point multiplier width (signed), int32
    parameter SHIFT_W = 6     // shift-amount width (unsigned). export: shift>=1
)(
    input  wire                      clock,
    input  wire                      rst_n,       // async active-low reset
    input  wire                      en,          // load the result register
    input  wire                      act,         // 0 = ACT_NONE, 1 = ACT_RELU6
    input  wire signed [ACC_W-1:0]   in_data,     // accumulator element
    input  wire signed [M0_W-1:0]    M0,          // fixed-point multiplier
    input  wire        [SHIFT_W-1:0] shift,       // right-shift amount (>= 1)
    input  wire signed [7:0]         relu6_qmax,  // ReLU6 ceiling q6 (<= 127)
    output reg  signed [7:0]         quantized    // int8 activation output
);

    // ---- op-kind encoding (mirrors the `activation` enum) -------------
    localparam ACT_NONE  = 1'b0;
    localparam ACT_RELU6 = 1'b1;

    // ---- widths -------------------------------------------------------
    // PROD_W is sized so in_data*M0 can never truncate (the C uses int64 for
    // exactly this). ROUND_W adds one bit of headroom for the +half add.
    localparam PROD_W  = ACC_W + M0_W;
    localparam ROUND_W = PROD_W + 1;

    // ---- (1) product --------------------------------------------------
    wire signed [PROD_W-1:0]  product = in_data * M0;

    // ---- (2) round-to-nearest -----------------------------------------
    // half = 1 << (shift-1), built in a full-width signed vector BEFORE the
    // shift so a large shift (~40) cannot make it vanish to 0.
    // Precedence trap: `a + 1 << s` parses as `(a+1) << s` in Verilog, so the
    // parentheses around the shift are mandatory (kept explicit via `half`).
    wire signed [ROUND_W-1:0] one     = 1;
    wire signed [ROUND_W-1:0] half    = one << (shift - 1'b1);
    wire signed [ROUND_W-1:0] rounded = product + half;

    // ---- (3) arithmetic right shift (floor) ---------------------------
    // >>> is arithmetic ONLY because `rounded` is signed.
    wire signed [ROUND_W-1:0] shifted = rounded >>> shift;

    // ---- (4) activation + saturation (combinational) ------------------
    // Unsized literals (0, 127, -128) are 32-bit signed, so every compare
    // and assign below stays in signed arithmetic.
    reg signed [7:0] sat;
    always @(*) begin
        if (act == ACT_RELU6) begin
            // ReLU6 in quantized space: clamp to [0, relu6_qmax]. Since
            // 0 >= -128 and relu6_qmax <= 127, int8 saturation is subsumed.
            if      (shifted < 0)           sat = 0;
            else if (shifted > relu6_qmax)  sat = relu6_qmax;
            else                            sat = shifted[7:0];
        end else begin
            // linear bottleneck / projection / logits: clamp_i8 [-128, 127].
            if      (shifted < -128)        sat = -128;
            else if (shifted > 127)         sat = 127;
            else                            sat = shifted[7:0];
        end
    end

    // ---- registered output --------------------------------------------
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)   quantized <= 8'sd0;
        else if (en)  quantized <= sat;
    end

endmodule

`default_nettype wire
