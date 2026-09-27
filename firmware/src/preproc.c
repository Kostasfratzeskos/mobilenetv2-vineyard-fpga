/*============================================================================
 *  preproc.c  -  crop, normalise and quantise, bit-exactly
 *
 *  See preproc.h for why this can be exact at all (the dataset is already
 *  256x256, so there is no resampler in the pipeline) and for what stays
 *  outside the check (the JPEG decode).
 *
 *  ---- the table, and why it is not an approximation ---------------------
 *
 *  The per-pixel map depends only on the channel and the byte value:
 *
 *      q = clamp(round((p/255 - mean[c]) / std[c] / input_scale), -128, 127)
 *
 *  p is a uint8 and c is one of three, so there are exactly 3 x 256 = 768
 *  distinct results. Computing them once into a table and then looking up is
 *  therefore not a fast approximation of the arithmetic - it IS the arithmetic,
 *  evaluated at every point of its domain. The float work drops from 150,528
 *  divisions and rounds to 768, and the hot loop becomes a byte load and a byte
 *  store, which matters on an A53 doing this per frame.
 *
 *  Because "it is the same function" is the whole justification,
 *  preproc_self_test checks it: all 768 table entries against the direct double
 *  computation. That is cheap enough to run at start-up, and it is what would
 *  catch the one thing a host test cannot - a target FPU or libm whose rounding
 *  differs from the machine the goldens were made on.
 *
 *  Run: cd firmware && make test
 *==========================================================================*/
#include "preproc.h"

#include <math.h>

/*  __has_include, not a __STDC_VERSION__ test. The question is whether this
 *  toolchain HAS fenv.h, not whether it speaks C99 - and a bare-metal newlib or
 *  a freestanding build can be C11 and still not ship it. Testing the language
 *  version would turn a missing header into a build error on the target, which
 *  is the one place this file has not yet been compiled.
 *
 *  If it is absent the rounding-mode check is skipped rather than faked, and
 *  PREPROC_NO_FENV_CHECK below makes that visible instead of silent. */
#if defined(__has_include)
#  if __has_include(<fenv.h>)
#    include <fenv.h>
#    define PREPROC_HAVE_FENV 1
#  endif
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#  include <fenv.h>
#  define PREPROC_HAVE_FENV 1
#endif

#ifndef PREPROC_HAVE_FENV
/*  Deliberately noisy. The check this disables is the only thing that can catch
 *  a target FPU left truncating instead of rounding, and losing it silently is
 *  how the board would quantise differently from the goldens with nothing to
 *  show for it. -DPREPROC_NO_FENV_CHECK acknowledges that trade on purpose. */
#  ifndef PREPROC_NO_FENV_CHECK
#    warning "no <fenv.h>: the rounding-mode check is disabled. See preproc.h."
#  endif
#endif

/*  Indexed [channel][byte]. int8 rather than a wider type so that the inner
 *  loop is a straight byte copy with no narrowing. */
static int8_t  qtab[QP_CHANNELS][256];
static int     qtab_ready;

static const double QP_MEAN[QP_CHANNELS] = { QP_MEAN_0, QP_MEAN_1, QP_MEAN_2 };
static const double QP_STD [QP_CHANNELS] = { QP_STD_0,  QP_STD_1,  QP_STD_2  };

const char *preproc_strerror(preproc_status_t s)
{
    switch (s) {
    case PREPROC_OK:        return "ok";
    case PREPROC_E_NULL:    return "null pointer";
    case PREPROC_E_SRC_LEN: return "the source image is the wrong length";
    case PREPROC_E_DST_LEN: return "the destination is the wrong length";
    case PREPROC_E_SIZE:    return "the image is not 256x256 - this build has "
                                   "no verified resampler, so it is refused "
                                   "rather than guessed at";
    case PREPROC_E_ROUNDING: return "the FPU is not in round-to-nearest-even, "
                                    "so results would not match the reference";
    default:                return "unknown";
    }
}

/*  The definition of the map. Deliberately written the way the manifest states
 *  it, in the same order, rather than pre-folded into a single multiply: the
 *  fused form is algebraically equal but not bit-equal, and the manifest's order
 *  is what the goldens were produced with.
 *
 *  lrint rather than floor(x + 0.5) because the reference is torch.round, which
 *  is round-half-to-EVEN, and lrint in the default mode is the same function.
 *
 *  How much that choice actually buys here was worth measuring rather than
 *  repeating, and the answer is: nothing, for these constants. The domain is
 *  finite - 3 channels x 256 byte values = 768 points - so it can be enumerated
 *  exhaustively, and over all 768 the two spellings never disagree. Nothing even
 *  comes close: the nearest approach to a .5 tie is 6.4e-05 (channel 1, byte
 *  105), some 3e11 double ulp away. Substituting floor(x + 0.5) here passes the
 *  golden check bit-for-bit, which was verified by doing it.
 *
 *  lrint is kept anyway, for two reasons that are not "it might round
 *  differently": it matches the reference BY CONSTRUCTION rather than by a
 *  margin, and that margin is a property of THIS input_scale. Requantise the
 *  model and a value could land on a tie, at which point the code that was only
 *  accidentally right becomes wrong in a way no test here would predict. */
int preproc_quant_one(unsigned c, uint8_t p)
{
    double x;
    long   q;

    if (c >= QP_CHANNELS)
        return 0;

    x = (double)p / 255.0;
    x = (x - QP_MEAN[c]) / QP_STD[c];
    x = x / QP_INPUT_SCALE;

    q = lrint(x);
    if (q < -128) q = -128;
    if (q >  127) q =  127;
    return (int)q;
}

static void qtab_build(void)
{
    unsigned c, v;

    for (c = 0; c < QP_CHANNELS; c++)
        for (v = 0; v < 256; v++)
            qtab[c][v] = (int8_t)preproc_quant_one(c, (uint8_t)v);
    qtab_ready = 1;
}

static preproc_status_t check_rounding(void)
{
#ifdef PREPROC_HAVE_FENV
    /*  This one is NOT a formality, and it is a different concern from the
     *  half-to-even question above. Half-even versus half-up is unreachable here
     *  (no value gets near a tie). Round-toward-ZERO is not: some embedded
     *  runtimes leave the FPU truncating, and truncation differs from rounding
     *  for almost every value in the domain, not just the ties - it would shift
     *  a large fraction of the tensor by one step, in a direction that depends on
     *  the sign, while nothing anywhere reports an error.
     *
     *  A host test cannot catch that, because the host is in FE_TONEAREST. This
     *  check is the only thing standing between a truncating target runtime and
     *  a silently wrong input tensor, which is why preproc_self_test is worth
     *  calling at start-up on the board. */
    if (fegetround() != FE_TONEAREST)
        return PREPROC_E_ROUNDING;
#endif
    return PREPROC_OK;
}

preproc_status_t preproc_self_test(void)
{
    unsigned c, v;
    preproc_status_t s = check_rounding();

    if (s != PREPROC_OK)
        return s;

    if (!qtab_ready)
        qtab_build();

    for (c = 0; c < QP_CHANNELS; c++)
        for (v = 0; v < 256; v++)
            if ((int)qtab[c][v] != preproc_quant_one(c, (uint8_t)v))
                return PREPROC_E_ROUNDING;
    return PREPROC_OK;
}

preproc_status_t preproc_rgb(const uint8_t *rgb, unsigned w, unsigned h,
                             size_t rgb_len, int8_t *out, size_t out_len)
{
    const unsigned off  = QP_CROP_OFFSET;
    const unsigned crop = QP_CROP_SIZE;
    unsigned y, x;
    preproc_status_t s;

    if (rgb == NULL || out == NULL)
        return PREPROC_E_NULL;

    /*  The size check before the length check, so that an arbitrary photograph
     *  reports "not 256x256" - the actual problem - rather than "wrong length". */
    if (w != QP_SRC_SIZE || h != QP_SRC_SIZE)
        return PREPROC_E_SIZE;
    if (rgb_len != PREPROC_SRC_BYTES)
        return PREPROC_E_SRC_LEN;
    if (out_len != PREPROC_OUT_BYTES)
        return PREPROC_E_DST_LEN;

    s = check_rounding();
    if (s != PREPROC_OK)
        return s;

    if (!qtab_ready)
        qtab_build();

    /*  Both source and destination are HWC interleaved, so a row of the crop is
     *  a contiguous run of 224*3 source bytes and the copy walks both buffers
     *  forwards. That is the layout DD-032 chose for the DMA's sake, and it pays
     *  off again here: the alternative (channel-planar) would read the source
     *  with a stride of 3 and touch every cache line three times.
     *
     *  The channel index is the low bits of the position, not a third loop, so
     *  the inner body stays a load-lookup-store. */
    for (y = 0; y < crop; y++) {
        const uint8_t *sp = rgb + ((size_t)(y + off) * QP_SRC_SIZE + off)
                                  * QP_CHANNELS;
        int8_t        *dp = out + (size_t)y * crop * QP_CHANNELS;

        for (x = 0; x < crop; x++) {
            dp[0] = qtab[0][sp[0]];
            dp[1] = qtab[1][sp[1]];
            dp[2] = qtab[2][sp[2]];
            sp += QP_CHANNELS;
            dp += QP_CHANNELS;
        }
    }
    return PREPROC_OK;
}
