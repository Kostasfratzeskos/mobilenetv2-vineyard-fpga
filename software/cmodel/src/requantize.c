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
    return (int32_t)(rounded >> shift);
}

int8_t clamp_i8(int32_t v) {
    if (v < -128) return -128;
    if (v >  127) return  127;
    return (int8_t)v;
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
