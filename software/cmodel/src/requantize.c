#include "requantize.h"
#include "mobilenet.h"

int32_t requant_mul_shift(int32_t acc, int32_t m0, int shift) {
    /* (1) product MUST be 64-bit: acc is ~21-bit, m0 is ~31-bit, so the
     *     product reaches ~2^52 and would overflow a 32-bit int. */
    int64_t prod = (int64_t)acc * (int64_t)m0;

    /* (2) add half an output-LSB before the shift -> round to nearest. */
    int64_t rounded = prod + ((int64_t)1 << (shift - 1));

    /* (3) ARITHMETIC right shift (= floor). gcc/clang guarantee this for
     *     signed types; it matches numpy >>, Python >>, and Verilog >>>.
     *     Floor applied after the +half gives round-half-UP toward +inf,
     *     which is why negative ties go up (-2.5 -> -2, not -3).        */

    /* (4) L-6 / DD-024: this cast NARROWS to 32 bits before any clamp, and the
     *     RTL does not - requantize.v keeps the full ROUND_W = ACC_W + M0_W + 1
     *     = 59-bit value and clamps THAT. The two therefore disagree for
     *     |rounded >> shift| > 2^31, where this wraps and the RTL saturates.
     *
     *     That is a DELIBERATE, documented deviation, not an oversight, and it
     *     is unreachable by a structural bound rather than by observation:
     *     export.py emits a NORMALIZED multiplier, 2^30 <= m0 < 2^31, and the
     *     same normalization forces shift >= 31 because every real scale
     *     M = m0 * 2^-shift in this network is < 1. So
     *
     *         |r| = |acc * m0 >> shift| <= |acc| * (m0 / 2^shift) < |acc| <= 2^25
     *
     *     which is six bits clear of 2^31, whatever the input data. The bound
     *     depends only on the manifest being normalized - not on a measurement,
     *     which is the distinction DD-019 exists to record.
     *
     *     Do NOT "fix" this into agreement by widening the return type or by
     *     narrowing the RTL. The RTL is the more correct of the two, nothing
     *     reads a wider value here, and requantize.v carries a simulation check
     *     that fires if the disagreement is ever actually reached. */
    return (int32_t)(rounded >> shift);
}

int8_t clamp_i8(int32_t v) {
    if (v < -128) return -128;
    if (v >  127) return  127;
    return (int8_t)v;
}

int16_t clamp_i16(int32_t v) {
    if (v < -32768) return -32768;
    if (v >  32767) return  32767;
    return (int16_t)v;
}

int8_t requantize_elem(int32_t acc, int32_t m0, int shift,
                       activation act, int relu6_qmax) {
    int32_t r = requant_mul_shift(acc, m0, shift);
    if (act == ACT_RELU6) {
        /* ReLU6 in quantized space: clamp to [0, q6]. Matches the Python
         * order (clip(0, q6) then clamp_i8); since q6 <= 127 and 0 >= -128
         * the int8 saturation is already subsumed. */
        if (r < 0)          r = 0;
        if (r > relu6_qmax) r = relu6_qmax;
        return (int8_t)r;
    }
    /* linear bottleneck / projection / logits: no lower clamp at 0. */
    return clamp_i8(r);
}
