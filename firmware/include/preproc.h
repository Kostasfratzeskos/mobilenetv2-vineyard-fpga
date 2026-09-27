/*============================================================================
 *  preproc.h  -  a decoded RGB image into the int8 tensor the accelerator wants
 *
 *  This closes the gap the rest of the firmware was written around. Until now
 *  main.c expected an image that was ALREADY 224x224x3 int8, quantised with
 *  export.py's scale, and scripts/send_image.py did the front end on the PC.
 *  That left the project's headline claim - "6,895,780 elements bit-exact" -
 *  measured from software/golden/<set>/000_input.hex onward, with the resize,
 *  normalise and quantise in front of it covered by no check at all.
 *
 *  ---- why this can be bit-exact, which was not obvious ------------------
 *
 *  predict.py's pipeline is Resize(256) -> CenterCrop(224) -> ToTensor ->
 *  Normalize, and reimplementing Pillow's antialiased resampler in C to the last
 *  bit is not a reasonable thing to attempt. So the first question was whether
 *  bit-exactness was even available, or whether the honest goal was a bounded
 *  difference.
 *
 *  Measured, not assumed: all 13,089 images in data/grape and data/grape_clean
 *  are already 256x256. Resize(256) is therefore the IDENTITY, and CenterCrop
 *  (224) is a pure integer crop at offset 16. There is no resampling anywhere in
 *  the pipeline, so the whole front end is an integer crop followed by a
 *  per-pixel map - and both are exactly reproducible.
 *
 *  Confirmed end to end: crop + normalise + quantise reproduces all five golden
 *  000_input.hex files bit-exactly from their source JPEGs, and
 *  firmware/test/test_preproc.c re-checks that in C against the tracked goldens.
 *  The C front end therefore starts from the very tensor the hardware's
 *  6,895,780-element check starts from, and the two claims join up.
 *
 *  ---- what is still outside the check -----------------------------------
 *
 *  The JPEG decode. That stays on the PC, and it is the one step this file
 *  cannot make claims about: libjpeg's IDCT is not bit-defined and two decoders
 *  can legitimately differ by a least-significant bit. The board is handed
 *  decoded RGB. Naming that is the point - it is the remaining unverified link,
 *  and it is outside the embedded path rather than hidden inside it.
 *
 *  And the refusal below matters for the same reason: a camera, or any arbitrary
 *  photograph, is NOT 256x256, and would need a resampler that no check in this
 *  repository covers. preproc_rgb therefore REFUSES such an image rather than
 *  quietly doing a naive bilinear that differs from the reference. A refusal is a
 *  visible failure; a plausible wrong tensor is not.
 *
 *  ---- the arithmetic -----------------------------------------------------
 *
 *      q = clamp(round((p/255 - mean[c]) / std[c] / input_scale), -128, 127)
 *
 *  verbatim from software/export/manifest.json, with every constant GENERATED
 *  into quant_params.h by scripts/gen_program.py --emit so there is no second
 *  copy of a scale to drift.
 *
 *  `round` there is torch.round: round-half-to-EVEN, which is lrint() in C's
 *  default rounding mode, and that is what preproc.c uses.
 *
 *  The usual warning about floor(x + 0.5) being a different function is true in
 *  general but does NOT bite here, and the difference is worth stating precisely
 *  rather than left as a caution. The domain is finite - 768 (channel, byte)
 *  pairs - so it was enumerated: the two spellings agree at every one of them,
 *  and the closest any value comes to a .5 tie is 6.4e-05, about 3e11 double ulp
 *  away. lrint is kept because it is right by construction rather than by that
 *  margin, since the margin belongs to this particular input_scale.
 *
 *  What WOULD bite is a target FPU left in round-toward-zero, which differs from
 *  rounding on most of the domain rather than on ties. preproc_self_test checks
 *  for it, because a host test never can.
 *
 *  Run: cd firmware && make test
 *==========================================================================*/
#ifndef PREPROC_H
#define PREPROC_H

#include <stddef.h>
#include <stdint.h>

#include "quant_params.h"

/*  The source: a decoded, full-size RGB image, HWC interleaved, 8 bits per
 *  channel - what any decoder hands over and what send_image.py --raw sends. */
#define PREPROC_SRC_BYTES \
    ((size_t)QP_SRC_SIZE * QP_SRC_SIZE * QP_CHANNELS)      /* 196,608 */

/*  The destination: exactly what the accelerator reads (ACCEL_IMG_BYTES). */
#define PREPROC_OUT_BYTES \
    ((size_t)QP_CROP_SIZE * QP_CROP_SIZE * QP_CHANNELS)    /* 150,528 */

typedef enum {
    PREPROC_OK = 0,
    PREPROC_E_NULL,      /* a null pointer                                   */
    PREPROC_E_SRC_LEN,   /* the source is not PREPROC_SRC_BYTES              */
    PREPROC_E_DST_LEN,   /* the destination is not PREPROC_OUT_BYTES         */
    PREPROC_E_SIZE,      /* not QP_SRC_SIZE square - a resampler would be
                          * needed, and none here is verified               */
    PREPROC_E_ROUNDING   /* the FPU is not in round-to-nearest-even, so this
                          * would not match the reference                   */
} preproc_status_t;

const char *preproc_strerror(preproc_status_t s);

/*  The one to call. `w` and `h` are the decoded image's real dimensions, passed
 *  so that a wrongly-sized image is REFUSED rather than reinterpreted: without
 *  them a 512x512 photo is just a source buffer of the wrong length, and the
 *  most likely mistake - feeding an arbitrary photograph - would produce a
 *  confident wrong answer instead of an error. */
preproc_status_t preproc_rgb(const uint8_t *rgb, unsigned w, unsigned h,
                             size_t rgb_len, int8_t *out, size_t out_len);

/*  The quantisation of a single channel sample, computed directly in double
 *  precision from the manifest constants. This is the DEFINITION; preproc_rgb
 *  goes through a table, and preproc_self_test checks the two agree. Exposed so
 *  the test can check the table rather than trusting it. */
int preproc_quant_one(unsigned c, uint8_t p);

/*  Check the 3x256 table against preproc_quant_one for every input, and check
 *  the FPU's rounding mode. 768 operations, so it is cheap enough to call at
 *  start-up on the board - which is the point: it is the only thing that can
 *  catch a target toolchain whose default rounding differs from the host's,
 *  which would otherwise show up as an occasional wrong class and nothing else. */
preproc_status_t preproc_self_test(void);

#endif /* PREPROC_H */
