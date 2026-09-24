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
//  ---- L-11 / DD-026: THIS MODULE IS A VERIFIED REFERENCE MODEL ---------
//
//  It is NOT INSTANTIATED by any RTL. Nothing in accel_top reaches it, and no
//  synthesis run includes it. It is kept deliberately, with its own passing
//  testbench, because it is an INDEPENDENT implementation of arithmetic that the
//  shipping design computes a different way - so the testbench is evidence that
//  the arithmetic was validated separately from the implementation that replaced
//  it, which matters for a thesis in a way it would not for a product.
//
//  DD-026 considered deleting it and chose not to. What that decision costs is
//  the obligation below; read it before changing anything here.
//
//  What this module shadows: `res_feeder`'s inline add-and-clamp, which is what
//  the hardware actually runs.
//
//  ---- the final saturation, and how L-13 resolved it -------------------
//
//  This header used to say: "the C reference assigns the sum to int8_t, which
//  TRUNCATES (wraps) rather than clamps -- its header comment says 'clamped'. On
//  real data the residual sum fits int8 so the two agree; we implement the
//  saturating CLAMP here because it matches the intended / standard quantized-add
//  semantics (and thus the Python golden)."
//
//  The conclusion was right and the ARGUMENT was not, and L-13 was raised
//  against the argument: "on real data the sum fits int8" is a MEASUREMENT, and
//  DD-019 is this project's record of a measurement-based safety claim failing -
//  the 2026-07 retrain put a bias outside a 21-bit accumulator and 2.2M elements
//  went wrong in silence.
//
//  Resolved by DD-025: the C model was simply WRONG and is now fixed. All three
//  implementations clamp - Python at export.py:303, the C at mobilenet.c, and
//  this module and `res_feeder` here. The reachability is no longer the argument
//  for anything; it is just a fact worth knowing, so: the residual rescale has
//  max M = 0.909 across the ten res_add ops in this manifest, so |res| <= 115,
//  and target is a full int8 - a sum of 242 is arithmetically available and a
//  future retrain may well produce one. `res_feeder` reports it if that happens,
//  and `gen_program.py` asserts M <= 1 at build time (which is what keeps the
//  INTERMEDIATE clamp, where Python differs from both implementations,
//  unreachable - see DD-025).
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
    //  ---- L-14: the same underflow L-4 fixed in requantize.v --------------
    //
    //  `shift - 1'b1` is a SHIFT_W-bit UNSIGNED subtract and `<<`'s amount is
    //  self-determined, so at shift=0 it wraps to 63 and `one << 63` is 0 - the
    //  rounding term silently disappears. Past ROUND_W-1 the rounding one lands
    //  on or above the sign bit instead.
    //
    //  This is the SECOND independent copy of that defect: L-4 fixed it in
    //  requantize.v during Phase 1 and this file was not on that list, so for one
    //  phase the same bug existed in two places with only one of them tracked.
    //  L-14 is exactly that observation. It has no live impact - this module is
    //  not instantiated - which is precisely why it would have survived
    //  indefinitely, and why DD-026's decision to KEEP the file carries the
    //  obligation to keep it correct.
    //
    //  Guarded the same way requantize.v is, deliberately: two copies that differ
    //  in their guards are worse than two copies that agree.
    localparam SH_MAX = ROUND_W - 1;

    wire sh_ok = (shift != {SHIFT_W{1'b0}}) && (shift <= SH_MAX);

    wire signed [ROUND_W-1:0] half    = sh_ok ? (one << (shift - 1'b1))
                                              : {ROUND_W{1'b0}};
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
