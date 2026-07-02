#ifndef REQUANTIZE_H
#define REQUANTIZE_H

#include <stdint.h>
#include "mobilenet.h"

/* --- the bit-exact core --------------------------------------------------
 * Reproduces quantize.requantize_int() EXACTLY:
 *     (acc * m0 + (1 << (shift-1))) >> shift
 * Round-half-up toward +inf (arithmetic shift = floor, applied after +half).
 * Precondition: shift >= 1  (export guarantees shift ~ [28, 48]).          */
int32_t requant_mul_shift(int32_t acc, int32_t m0, int shift);

/* saturate an int32 to the int8 range [-128, 127]  (== quantize.clamp_i8) */
int8_t  clamp_i8(int32_t v);

/* full per-element tail:  core -> activation/clamp -> int8.
 *   ACT_RELU6 : clamp to [0, relu6_qmax]   (relu6_qmax = q6 from manifest)
 *   ACT_NONE  : clamp to [-128, 127]                                       */
int8_t  requantize_elem(int32_t acc, int32_t m0, int shift,
                        activation act, int relu6_qmax);

#endif /* REQUANTIZE_H */
