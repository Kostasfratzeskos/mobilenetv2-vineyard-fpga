`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  requantize.v  -  int accumulator element  ->  int8 activation
//
//  Bit-exact hardware twin of requantize_elem() in
//      software/cmodel/src/requantize.c
//
//  Parameterised by OUT_W: 8 for activations (clamp_i8) and 16 for the
//  classifier's logits, where requantize_logits() applies clamp_i16 instead
//  (DD-011). Everything else about the arithmetic is identical - the logit path
//  is the ACT_NONE path with a wider saturation.
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
    parameter ACC_W   = 26,   // accumulator width (signed), matches the HW acc
    parameter M0_W    = 32,   // fixed-point multiplier width (signed), int32
    parameter SHIFT_W = 6,    // shift-amount width (unsigned). export: shift>=1
    parameter OUT_W   = 8,    // output width: 8 for activations, 16 for logits

    // Simulation only; the checks it guards live inside `ifndef SYNTHESIS`, so
    // synthesis is identical either way. 1 stops the simulation where the
    // evidence is. Pass 0 only in a testbench whose PURPOSE is to fire the
    // check and then verify that it fired. Same name and meaning as pw_out's.
    parameter CHECKS_ARE_FATAL = 1
)(
    input  wire                      clock,
    input  wire                      rst_n,       // async active-low reset
    input  wire                      en,          // load the result register
    input  wire                      act,         // 0 = ACT_NONE, 1 = ACT_RELU6
    input  wire signed [ACC_W-1:0]   in_data,     // accumulator element
    input  wire signed [M0_W-1:0]    M0,          // fixed-point multiplier
    input  wire        [SHIFT_W-1:0] shift,       // right-shift amount (>= 1)
    input  wire signed [7:0]         relu6_qmax,  // ReLU6 ceiling q6 (<= 127)
    output reg  signed [OUT_W-1:0]   quantized    // int8 activation, or int16 logit
);

    // ---- op-kind encoding (mirrors the `activation` enum) -------------
    localparam ACT_NONE  = 1'b0;
    localparam ACT_RELU6 = 1'b1;

    // ---- widths -------------------------------------------------------
    // PROD_W is sized so in_data*M0 can never truncate (the C uses int64 for
    // exactly this). ROUND_W adds one bit of headroom for the +half add.
    // saturation bounds for the output width: +-2^(OUT_W-1)
    localparam signed [63:0] OUT_MAX = (64'sd1 <<< (OUT_W-1)) - 64'sd1;
    localparam signed [63:0] OUT_MIN = -(64'sd1 <<< (OUT_W-1));

    localparam PROD_W  = ACC_W + M0_W;
    localparam ROUND_W = PROD_W + 1;

    // ---- (1) product --------------------------------------------------
    wire signed [PROD_W-1:0]  product = in_data * M0;

    // ---- (2) round-to-nearest -----------------------------------------
    // half = 1 << (shift-1), built in a full-width signed vector BEFORE the
    // shift so a large shift (~40) cannot make it vanish to 0.
    // Precedence trap: `a + 1 << s` parses as `(a+1) << s` in Verilog, so the
    // parentheses around the shift are mandatory (kept explicit via `half`).
    //
    // ---- why the guard (L-4, L-5) -------------------------------------
    //
    // `shift - 1'b1` is a SHIFT_W-bit UNSIGNED subtract, and the shift amount
    // of `<<` is self-determined, so it stays SHIFT_W bits wide. Measured, by
    // simulating this exact expression over all 64 values of shift:
    //
    //     shift = 0        ->  0 - 1 wraps to 63  ->  one << 63  =  0
    //     shift = 1..58    ->  half = 2**(shift-1)          (correct)
    //     shift = 59       ->  one << 58 lands on the SIGN bit -> -2**58
    //     shift = 60..63   ->  the one shifts out entirely  ->  0
    //
    // L-4 is the first line. param_buffer zero-initialises unwritten entries
    // and gen_program.py pads the parameter blob with zeros, so tail lanes
    // legitimately carry shift=0 - three channel counts in this network leave a
    // tail against TM=32 (16, 24 and 144). The rounding term silently
    // disappeared there, and the only reason it never mattered is that those
    // same lanes have m0=0, so the product is 0 and 0 >>> 0 is 0 either way.
    // That is a correctness argument resting on two zeros agreeing, which is
    // exactly the class of precondition this review is about, so `half = 0` is
    // now EXPLICIT rather than emergent from an unsigned wraparound.
    //
    // L-5 is the third line, and it is the dangerous one: at shift = 59 the
    // rounding term becomes -2**58, so `rounded` is catastrophically wrong and
    // nothing says so. Unreachable with a valid manifest (this model's largest
    // shift is 48, and SHIFT_W=6 admits 63), which is precisely why a corrupt
    // manifest or a bad DMA transfer would produce silent nonsense.
    //
    // Note what is NOT here: an assertion that shift != 0. The review is
    // explicit about that, and it is right - it would fire on every tail lane
    // of every layer with a tail. The real contract is `shift >= 1 OR m0 == 0`,
    // and that is what the simulation check at the bottom of this file tests.
    //
    // SH_MAX is ROUND_W-1 = 58: the largest shift whose rounding one still
    // lands strictly below the sign bit of the ROUND_W-wide vector.
    localparam SH_MAX = ROUND_W - 1;

    wire sh_ok = (shift != {SHIFT_W{1'b0}}) && (shift <= SH_MAX);

    wire signed [ROUND_W-1:0] one     = 1;
    wire signed [ROUND_W-1:0] half    = sh_ok ? (one << (shift - 1'b1))
                                              : {ROUND_W{1'b0}};
    wire signed [ROUND_W-1:0] rounded = product + half;

    // ---- (3) arithmetic right shift (floor) ---------------------------
    // >>> is arithmetic ONLY because `rounded` is signed.
    wire signed [ROUND_W-1:0] shifted = rounded >>> shift;

    // ---- (4) activation + saturation (combinational) ------------------
    // Unsized literals (0, 127, -128) are 32-bit signed, so every compare
    // and assign below stays in signed arithmetic.
    reg signed [OUT_W-1:0] sat;
    always @(*) begin
        if (act == ACT_RELU6) begin
            // ReLU6 in quantized space: clamp to [0, relu6_qmax]. Since
            // 0 >= -128 and relu6_qmax <= 127, int8 saturation is subsumed.
            if      (shifted < 0)           sat = 0;
            else if (shifted > relu6_qmax)  sat = relu6_qmax;
            else                            sat = shifted[OUT_W-1:0];
        end else begin
            // linear bottleneck / projection / logits: saturate to the output
            // width. OUT_W=8 is clamp_i8; OUT_W=16 is the clamp_i16 that
            // requantize_logits() applies to the classifier (DD-011).
            if      (shifted < OUT_MIN)     sat = OUT_MIN[OUT_W-1:0];
            else if (shifted > OUT_MAX)     sat = OUT_MAX[OUT_W-1:0];
            else                            sat = shifted[OUT_W-1:0];
        end
    end

    // ---- registered output --------------------------------------------
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)   quantized <= {OUT_W{1'b0}};
        else if (en)  quantized <= sat;
    end

    // ---- the tail contract, checked rather than assumed (L-4, L-5) ------
    //
    //  The guard above makes shift=0 produce a DEFINED result. Whether that
    //  result is the RIGHT one is a different question, and it depends on a
    //  contract param_buffer documents: a lane with shift=0 must also have
    //  m0=0, because then the product is zero and the missing rounding term
    //  cannot change the answer. A tail lane satisfies it. A real channel whose
    //  shift got lost in transit does not, and would quietly lose its rounding.
    //
    //  This is `shift >= 1 OR m0 == 0`, which is the contract - not
    //  `shift != 0`, which would fire on every tail lane of every layer.
`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (rst_n && en) begin
            if ((shift == {SHIFT_W{1'b0}}) && (M0 != {M0_W{1'b0}})) begin
                if (CHECKS_ARE_FATAL) begin
                    $display("ERROR: %m L-4 shift=0 with M0=%0d at time %0t: a real channel lost its rounding term. The tail contract is shift>=1 OR m0==0.",
                             M0, $time);
                    $finish;
                end else
                    $display("  [tripwire] %m L-4 shift=0 with M0=%0d at time %0t", M0, $time);
            end
            if (shift > SH_MAX) begin
                if (CHECKS_ARE_FATAL) begin
                    $display("ERROR: %m L-5 shift=%0d exceeds %0d at time %0t: the rounding term would land on the sign bit of the %0d-bit vector. Corrupt manifest or parameter load.",
                             shift, SH_MAX, $time, ROUND_W);
                    $finish;
                end else
                    $display("  [tripwire] %m L-5 shift=%0d exceeds %0d at time %0t",
                             shift, SH_MAX, $time);
            end
        end
    end
`endif

endmodule

`default_nettype wire
