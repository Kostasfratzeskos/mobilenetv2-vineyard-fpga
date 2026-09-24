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
//  NOTE: every operand in the arithmetic chain is `signed`. One unsigned
//  operand would silently turn the whole expression unsigned (breaking both
//  >>> and the compares), so the signedness here is load-bearing.
//
//  ---- THE PIPELINE (L-3) ----------------------------------------------
//
//  This was one clock: a 26x32 multiply (2 unregistered DSPs) into a 59-bit
//  add, into a 59-bit VARIABLE barrel shift, into the clamp, with only the
//  output registered - 2 DSPs and 8 flip-flops per instance, the 8 being the
//  output register alone. L-3 predicted it "becomes critical once L-1 is
//  fixed", and after Phase 2c it measurably is: the worst path at synthesis was
//  u_os/u_param -> u_os/u_rq, and post-route u_pwf/.../acc_reg ->
//  u_log/cls[2].u_r/quantized_reg. Both end in this module.
//
//  Four stages now, RQ_LAT = 4:
//
//    1  in_data      absorbs bias_add, which is combinational in front of this
//                    register and had nowhere to hide before (L-12 absorbed)
//    2  product      in_data * M0, the DSP multiply on its own
//    3  round+shift  + half, then the variable arithmetic shift
//    4  clamp        the activation and saturation, then the output register
//
//  ---- L-7: the parameters travel WITH the data ------------------------
//
//  Per-channel bias/m0/shift arrived one cycle late from param_buffer and were
//  correct; `act` and `relu6_qmax` arrived at ZERO delay from the instruction
//  word, yet all of them had to be valid in the same `en` cycle. That worked
//  only because top_seq does not refetch w[] until !op_busy - a timing
//  coincidence at the top level protecting an arithmetic unit four levels down.
//  With four stages the window in which a stale parameter can meet live data is
//  four times wider, so every parameter is now delayed to the stage that uses
//  it: M0 to stage 2, shift to stage 3, act and relu6_qmax to stage 4.
//  Structural instead of contractual, for 9 bits plus a few.
//
//  The datapath FREE-RUNS and only `en` is pipelined, exactly as in the MAC
//  kernels: the accumulators upstream are held between results, so a
//  free-running stage recomputes the same value, and `q_valid` marks which
//  cycle the output means something.
//
//  Run:  bash scripts/run_sim.sh requantize
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
    input  wire                      rst_n,       // SYNCHRONOUS (DD-020)
    input  wire                      en,          // in_data is a real element
    input  wire                      act,         // 0 = ACT_NONE, 1 = ACT_RELU6
    input  wire signed [ACC_W-1:0]   in_data,     // accumulator element, biased
    input  wire signed [M0_W-1:0]    M0,          // fixed-point multiplier
    input  wire        [SHIFT_W-1:0] shift,       // right-shift amount (>= 1)
    input  wire signed [7:0]         relu6_qmax,  // ReLU6 ceiling q6 (<= 127)
    output reg  signed [OUT_W-1:0]   quantized,   // int8 activation, or int16 logit
    output wire                      q_valid      // `quantized` is real this cycle
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

    // The number of register stages, which is what every drain counter and tag
    // depth in the design is ultimately sized from - see docs/latency_map.md.
    // out_stage adds one more (its accumulator capture), so OS_LAT = 1 + RQ_LAT.
    localparam RQ_LAT = 4;

    // ================= the control, one shift register ==================
    reg [RQ_LAT-1:0] en_sr;

    always @(posedge clock) begin
        if (!rst_n) en_sr <= {RQ_LAT{1'b0}};
        else        en_sr <= {en_sr[RQ_LAT-2:0], en};
    end

    assign q_valid = en_sr[RQ_LAT-1];

    // ================= the parameters, delayed to their stage (L-7) =====
    reg signed [M0_W-1:0]    m0_d1;
    reg        [SHIFT_W-1:0] sh_d1, sh_d2;
    reg                      act_d1, act_d2, act_d3;
    reg signed [7:0]         qmax_d1, qmax_d2, qmax_d3;

    always @(posedge clock) begin
        if (!rst_n) begin
            m0_d1 <= {M0_W{1'b0}};
            sh_d1 <= {SHIFT_W{1'b0}};  sh_d2 <= {SHIFT_W{1'b0}};
            act_d1 <= 1'b0; act_d2 <= 1'b0; act_d3 <= 1'b0;
            qmax_d1 <= 8'sd0; qmax_d2 <= 8'sd0; qmax_d3 <= 8'sd0;
        end else begin
            m0_d1 <= M0;                        // used by stage 2
            sh_d1 <= shift;  sh_d2 <= sh_d1;    // used by stage 3
            act_d1  <= act;      act_d2  <= act_d1;      act_d3  <= act_d2;
            qmax_d1 <= relu6_qmax; qmax_d2 <= qmax_d1;   qmax_d3 <= qmax_d2;
        end
    end

    // ================= stage 1 : capture the biased accumulator =========
    //  This register is what L-12 means by "bias_add absorbed": the add sits in
    //  front of it instead of in front of the whole multiply-shift-clamp chain.
    reg signed [ACC_W-1:0] d1;

    always @(posedge clock) begin
        if (!rst_n) d1 <= {ACC_W{1'b0}};
        else        d1 <= in_data;
    end

    // ================= stage 2 : the product ============================
    (* use_dsp = "yes" *)
    reg signed [PROD_W-1:0] p2;

    always @(posedge clock) begin
        if (!rst_n) p2 <= {PROD_W{1'b0}};
        else        p2 <= d1 * m0_d1;
    end

    // ================= stage 3 : round, then shift ======================
    //  ---- why the guard (L-4, L-5) -------------------------------------
    //
    //  `shift - 1'b1` is a SHIFT_W-bit UNSIGNED subtract, and the shift amount
    //  of `<<` is self-determined, so it stays SHIFT_W bits wide. Measured, by
    //  simulating this exact expression over all 64 values of shift:
    //
    //      shift = 0        ->  0 - 1 wraps to 63  ->  one << 63  =  0
    //      shift = 1..58    ->  half = 2**(shift-1)          (correct)
    //      shift = 59       ->  one << 58 lands on the SIGN bit -> -2**58
    //      shift = 60..63   ->  the one shifts out entirely  ->  0
    //
    //  L-4 is the first line: param_buffer zero-initialises unwritten entries
    //  and gen_program.py pads the parameter blob with zeros, so tail lanes
    //  legitimately carry shift=0 - three channel counts in this network leave a
    //  tail against TM=32 (16, 24 and 144). The rounding term silently
    //  disappeared there, and the only reason it never mattered is that those
    //  same lanes have m0=0. That is a correctness argument resting on two zeros
    //  agreeing, so `half = 0` is now EXPLICIT rather than emergent from an
    //  unsigned wraparound.
    //
    //  L-5 is the third line, and it is the dangerous one: at shift = 59 the
    //  rounding term becomes -2**58 and nothing says so. Unreachable with a
    //  valid manifest (this model's largest shift is 48), which is precisely why
    //  a corrupt one would produce silent nonsense.
    //
    //  NOT here: an assertion that shift != 0. It would fire on every tail lane.
    //  The contract is `shift >= 1 OR m0 == 0`, which the check below tests.
    //
    //  SH_MAX is ROUND_W-1: the largest shift whose rounding one still lands
    //  strictly below the sign bit of the ROUND_W-wide vector.
    localparam SH_MAX = ROUND_W - 1;

    wire sh_ok = (sh_d2 != {SHIFT_W{1'b0}}) && (sh_d2 <= SH_MAX);

    wire signed [ROUND_W-1:0] one  = 1;
    wire signed [ROUND_W-1:0] half = sh_ok ? (one << (sh_d2 - 1'b1))
                                           : {ROUND_W{1'b0}};

    reg signed [ROUND_W-1:0] s3;

    always @(posedge clock) begin
        if (!rst_n) s3 <= {ROUND_W{1'b0}};
        else        s3 <= (p2 + half) >>> sh_d2;    // >>> is arithmetic: signed
    end

`ifndef SYNTHESIS
    // ---- L-6 / DD-024: the one place this RTL and the C model disagree ----
    //
    //  requantize.c narrows to int32 BEFORE clamping - `(int32_t)(rounded >>
    //  shift)` - and this module does not: `s3` is the full ROUND_W-wide value
    //  and stage 4 clamps that. So for |s3| > 2^31 the C wraps and this
    //  saturates, and the two models produce different int8s.
    //
    //  DD-024 accepted that deviation deliberately, on a structural bound: a
    //  normalized manifest (2^30 <= m0 < 2^31, shift >= 31) forces |s3| < 2^25,
    //  six bits clear. This check is what makes the bound worth trusting - it
    //  turns "proven unreachable" into "checked on every vector we run",
    //  including every one of accel_tb's 6,895,780 elements.
    //
    //  If it ever fires, the golden vectors and the RTL have diverged and the
    //  vectors are the ones that are wrong, because the C is the model that
    //  wraps. That is the opposite of the usual direction, which is exactly why
    //  it says so here rather than leaving the next person to work it out.
    localparam signed [ROUND_W-1:0] I32_MAX =  (1 <<< 31) - 1;
    localparam signed [ROUND_W-1:0] I32_MIN = -(1 <<< 31);

    //  Respects CHECKS_ARE_FATAL, like L-4 and L-5 above and for the same reason:
    //  requantize_tb drives a second instance into exactly the corners that must
    //  NOT be reachable in a real build - shift=0 with a live m0, shift past
    //  SH_MAX - and those corners blow the int32 bound as a side effect. A
    //  100 * 2^30 product unshifted is 1.07e11, which is this check firing
    //  CORRECTLY on a deliberately illegal input. Fatal in the shipping
    //  configuration, a tripwire line in the testbench's guard instance.
    always @(posedge clock) begin
        if (rst_n && en_sr[2] && ((s3 > I32_MAX) || (s3 < I32_MIN))) begin
            if (CHECKS_ARE_FATAL) begin
                $display("ERROR: %m L-6 s3 = %0d leaves int32 range at time %0t. requantize.c narrows to int32 here and this module does not, so the C model and the RTL now disagree on this element. DD-024's bound (normalized m0 and shift >= 31 give |s3| < 2^25) has been violated - check the manifest, not this module.",
                         s3, $time);
                $finish;
            end else
                $display("  [tripwire] %m L-6 s3 = %0d leaves int32 range at time %0t",
                         s3, $time);
        end
    end
`endif

    // ================= stage 4 : activation, saturation, output =========
    // Unsized literals (0, 127, -128) are 32-bit signed, so every compare and
    // assign below stays in signed arithmetic.
    reg signed [OUT_W-1:0] sat;
    always @(*) begin
        if (act_d3 == ACT_RELU6) begin
            // ReLU6 in quantized space: clamp to [0, relu6_qmax]. Since
            // 0 >= -128 and relu6_qmax <= 127, int8 saturation is subsumed.
            if      (s3 < 0)         sat = 0;
            else if (s3 > qmax_d3)   sat = qmax_d3;
            else                     sat = s3[OUT_W-1:0];
        end else begin
            // linear bottleneck / projection / logits: saturate to the output
            // width. OUT_W=8 is clamp_i8; OUT_W=16 is the clamp_i16 that
            // requantize_logits() applies to the classifier (DD-011).
            if      (s3 < OUT_MIN)   sat = OUT_MIN[OUT_W-1:0];
            else if (s3 > OUT_MAX)   sat = OUT_MAX[OUT_W-1:0];
            else                     sat = s3[OUT_W-1:0];
        end
    end

    always @(posedge clock) begin
        if (!rst_n) quantized <= {OUT_W{1'b0}};
        else        quantized <= sat;
    end

    // ---- the tail contract, checked rather than assumed (L-4, L-5) ------
    //
    //  The guard above makes shift=0 produce a DEFINED result. Whether that
    //  result is the RIGHT one depends on a contract param_buffer documents: a
    //  lane with shift=0 must also have m0=0, because then the product is zero
    //  and the missing rounding term cannot change the answer. A tail lane
    //  satisfies it; a real channel whose shift got lost in transit does not,
    //  and would quietly lose its rounding.
    //
    //  Checked against the DELAYED copies, so the check sees the same parameter
    //  the arithmetic did - which is the whole point of L-7.
`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (rst_n && en_sr[1]) begin
            if ((sh_d2 == {SHIFT_W{1'b0}}) && (m0_d1 != {M0_W{1'b0}})) begin
                if (CHECKS_ARE_FATAL) begin
                    $display("ERROR: %m L-4 shift=0 with M0=%0d at time %0t: a real channel lost its rounding term. The tail contract is shift>=1 OR m0==0.",
                             m0_d1, $time);
                    $finish;
                end else
                    $display("  [tripwire] %m L-4 shift=0 with M0=%0d at time %0t", m0_d1, $time);
            end
            if (sh_d2 > SH_MAX) begin
                if (CHECKS_ARE_FATAL) begin
                    $display("ERROR: %m L-5 shift=%0d exceeds %0d at time %0t: the rounding term would land on the sign bit of the %0d-bit vector. Corrupt manifest or parameter load.",
                             sh_d2, SH_MAX, $time, ROUND_W);
                    $finish;
                end else
                    $display("  [tripwire] %m L-5 shift=%0d exceeds %0d at time %0t",
                             sh_d2, SH_MAX, $time);
            end
        end
    end
`endif

endmodule

`default_nettype wire
