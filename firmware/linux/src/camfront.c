/*============================================================================
 *  camfront.c  -  torchvision's Resize(256) for a camera frame, bit-exactly
 *
 *  See camfront.h for what this is and why. This file is a transcription of
 *  Pillow's libImaging/Resample.c - precompute_coeffs, normalize_coeffs_8bpc,
 *  ImagingResampleHorizontal_8bpc / Vertical_8bpc and ImagingResampleInner -
 *  restricted to 8-bit RGB, the BILINEAR filter and a full source box, which is
 *  what Image.resize((w, h), BILINEAR) runs and what torchvision calls.
 *
 *  ---- the places where "close" would not be the same -------------------
 *
 *  Each of these was changed on purpose, one at a time, and test_camfront.c
 *  failed every time (the notebook entry lists what each broke):
 *
 *    * Pillow's sample centres: center = (xx + 0.5) * scale. Corner-aligned
 *      xx * scale breaks 193,733 of the 196,608 window bytes.
 *    * The support WIDENS with the reduction (support = filterscale): this is
 *      the antialiasing. Without it - a naive bilinear - 194,270 bytes differ,
 *      which is the measurement DD-033 alluded to.
 *    * ... but filterscale is clamped to 1 when enlarging, or the upscale
 *      cases (320x240, 300x255) break.
 *    * xmin and xmax are rounded by (int)(v + 0.5): truncation toward zero
 *      after adding a half. floor instead breaks 126,196 bytes.
 *    * Each output's weights are normalised by their own sum (without it, all
 *      196,608 differ), then scaled to 22 fractional bits with
 *      (int)(0.5 + w * 2^22), rounded per weight. Truncating instead breaks
 *      only 1,385 bytes, each by one - the digests catch it all the same.
 *    * The accumulator starts at 2^21, the rounding half, and the result is
 *      the accumulator >> 22, clamped. Starting at 0 breaks 173,040 bytes.
 *    * Horizontal FIRST, into a uint8 intermediate, then vertical. One 2-D sum
 *      without the rounding in between gives 36,863 different bytes in
 *      261,888 (measured on a Python port that matches Pillow exactly WITH it).
 *    * The crop offset is Python's round, half to EVEN. Half-up moves the
 *      window a pixel in ten of the fifteen cases - every 341-wide one (VGA,
 *      SVGA, XGA, QVGA, portrait VGA) among them; 720p and 1080p happen to be
 *      immune, since 115.5 rounds to 116 either way.
 *
 *  And one that does NOT matter, kept anyway. Pillow multiplies the filter
 *  argument by ss = 1 / filterscale; dividing by filterscale is algebraically
 *  equal and could differ in a double's last bit. Enumerated rather than
 *  argued: the 22-bit weights come out identical for every short side from 2
 *  to 4096 and for 21,283 long-side size pairs from common aspect ratios. The
 *  reciprocal stays because it is Pillow's form BY CONSTRUCTION, not by a
 *  margin that belongs to these sizes - the same reasoning DD-033 gives for
 *  lrint.
 *
 *  ---- floating-point contraction ---------------------------------------
 *
 *  An aarch64 gcc fuses a*b + c into one FMA by default, and an FMA rounds once
 *  where the reference rounds twice. It cannot change THESE expressions - the
 *  source box starts at 0, so center has no "+ c" term, and the scale by 2^22 is
 *  exact - but the Makefile builds this file with -ffp-contract=off anyway, so
 *  that stays true if someone adds a box offset. Pillow's own x86-64 wheels are
 *  built without FMA, and that is the arithmetic the vectors come from.
 *==========================================================================*/
#include "camfront.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/*  Pillow: "8 bits for result. Filter can have negative areas. In one case the
 *  sum of the coefficients will be negative, in the other it will be more than
 *  1.0. That is why we need two extra bits for overflow and int type." */
#define PRECISION_BITS (32 - 8 - 2)

/*  The two coincidences the window relies on (camfront.h), as checks rather
 *  than comments: the Resize target equals the window preproc_rgb accepts, and
 *  preproc_rgb's crop is centred in it. */
_Static_assert(QP_CROP_SIZE == 224u,
               "CAMFRONT_RESIZE is int(round(224 * 256 / 224)); recompute it for a new crop");
_Static_assert(CAMFRONT_RESIZE == QP_SRC_SIZE,
               "the window must be the size preproc_rgb accepts");
_Static_assert(2u * QP_CROP_OFFSET + QP_CROP_SIZE == QP_SRC_SIZE,
               "preproc_rgb's crop must be centred in its 256x256 input");

/* ---- geometry: torchvision's arithmetic --------------------------------- */

/*  int(round((outer - inner) / 2.0)), with Python 3's round: a .5 goes to the
 *  EVEN neighbour. 341 - 224 = 117 gives 58.5, which is 58, and a half-up
 *  rounding would put the whole crop one pixel to the right. */
static unsigned center_offset(unsigned outer, unsigned inner)
{
    unsigned d    = outer - inner;
    unsigned half = d / 2u;

    if ((d & 1u) && (half & 1u))
        half++;
    return half;
}

int camfront_geometry(unsigned w, unsigned h, camfront_geom_t *g)
{
    unsigned short_side, long_side, new_long;

    if (g == NULL || w == 0u || h == 0u ||
        w > CAMFRONT_MAX_SIDE || h > CAMFRONT_MAX_SIDE)
        return -1;

    memset(g, 0, sizeof *g);
    g->src_w = w;
    g->src_h = h;

    /*  torchvision's _compute_resized_output_size, for an int size:
     *
     *      short, long = (w, h) if w <= h else (h, w)
     *      new_short, new_long = size, int(size * long / short)
     *
     *  size * long is an exact integer and `/` is a true division, i.e. the
     *  correctly rounded double of the quotient; int() truncates. Dividing two
     *  doubles here is that same operation. */
    if (w <= h) {
        short_side = w;
        long_side  = h;
    } else {
        short_side = h;
        long_side  = w;
    }
    new_long = (unsigned)((double)(CAMFRONT_RESIZE * long_side) /
                          (double)short_side);

    if (w <= h) {
        g->rs_w = CAMFRONT_RESIZE;
        g->rs_h = new_long;
    } else {
        g->rs_w = new_long;
        g->rs_h = CAMFRONT_RESIZE;
    }

    g->crop_x = center_offset(g->rs_w, QP_CROP_SIZE);
    g->crop_y = center_offset(g->rs_h, QP_CROP_SIZE);

    /*  The window starts QP_CROP_OFFSET before the crop, so that preproc_rgb's
     *  fixed crop at QP_CROP_OFFSET lands exactly on torchvision's. It fits for
     *  every rs side >= 256, which the short side always is; checked anyway,
     *  because an unsigned underflow here would be a crash far away. */
    if (g->crop_x < QP_CROP_OFFSET || g->crop_y < QP_CROP_OFFSET)
        return -1;
    g->win_x = g->crop_x - QP_CROP_OFFSET;
    g->win_y = g->crop_y - QP_CROP_OFFSET;
    if (g->win_x + CAMFRONT_WIN > g->rs_w || g->win_y + CAMFRONT_WIN > g->rs_h)
        return -1;
    return 0;
}

void camfront_crop_rect(const camfront_geom_t *g, int r[4])
{
    uint64_t x1 = (uint64_t)(g->crop_x + QP_CROP_SIZE) * g->src_w;
    uint64_t y1 = (uint64_t)(g->crop_y + QP_CROP_SIZE) * g->src_h;

    r[0] = (int)((uint64_t)g->crop_x * g->src_w / g->rs_w);
    r[1] = (int)((uint64_t)g->crop_y * g->src_h / g->rs_h);
    r[2] = (int)((x1 + g->rs_w - 1u) / g->rs_w);
    r[3] = (int)((y1 + g->rs_h - 1u) / g->rs_h);
}

/* ---- the coefficients: Pillow's precompute_coeffs ----------------------- */

static double bilinear_filter(double x)
{
    if (x < 0.0)
        x = -x;
    if (x < 1.0)
        return 1.0 - x;
    return 0.0;
}

static void axis_free(camfront_axis_t *a)
{
    free(a->lo);
    free(a->cnt);
    free(a->k);
    memset(a, 0, sizeof *a);
}

/*  Outputs [first, first + n) of an in_size -> out_size resize. Pillow computes
 *  all out_size of them; each one depends only on its own index and the full
 *  geometry, so computing a subset gives the same numbers for that subset. */
static int axis_init(camfront_axis_t *a, unsigned in_size, unsigned out_size,
                     unsigned first, unsigned n)
{
    double   scale, filterscale, support, ss;
    double  *w;
    unsigned i;
    int      ksize;

    memset(a, 0, sizeof *a);
    a->needed = (in_size != out_size);
    a->n      = n;

    /*  Pillow: filterscale = scale = (double)(in1 - in0) / outSize, with the
     *  box as floats. The box is (0, in_size) here, both exact in a float. */
    filterscale = scale = (double)in_size / (double)out_size;
    if (filterscale < 1.0)
        filterscale = 1.0;
    support = 1.0 * filterscale;              /* BILINEAR's support is 1.0 */
    ksize   = (int)ceil(support) * 2 + 1;

    a->ksize = (unsigned)ksize;
    a->lo    = malloc(n * sizeof *a->lo);
    a->cnt   = malloc(n * sizeof *a->cnt);
    a->k     = calloc((size_t)n * (size_t)ksize, sizeof *a->k);
    w        = malloc((size_t)ksize * sizeof *w);
    if (a->lo == NULL || a->cnt == NULL || a->k == NULL || w == NULL) {
        free(w);
        axis_free(a);
        return -1;
    }

    for (i = 0; i < n; i++) {
        unsigned xx = first + i;
        double   center, ww = 0.0;
        int      xmin, xmax, x;
        int32_t *k = a->k + (size_t)i * (size_t)ksize;

        center = 0.0 + (xx + 0.5) * scale;
        ss     = 1.0 / filterscale;

        xmin = (int)(center - support + 0.5);
        if (xmin < 0)
            xmin = 0;
        xmax = (int)(center + support + 0.5);
        if (xmax > (int)in_size)
            xmax = (int)in_size;
        xmax -= xmin;

        /*  Cannot exceed ksize: xmax - xmin <= 2*support + 1 <= ksize. Checked,
         *  because overrunning w[] here would be silent. */
        if (xmax > ksize || xmax < 1) {
            free(w);
            axis_free(a);
            return -1;
        }

        for (x = 0; x < xmax; x++) {
            double v = bilinear_filter((x + xmin - center + 0.5) * ss);
            w[x] = v;
            ww  += v;
        }
        for (x = 0; x < xmax; x++)
            if (ww != 0.0)
                w[x] /= ww;

        /*  normalize_coeffs_8bpc. Round half away from zero, per weight. */
        for (x = 0; x < xmax; x++) {
            if (w[x] < 0)
                k[x] = (int32_t)(-0.5 + w[x] * (1 << PRECISION_BITS));
            else
                k[x] = (int32_t)(0.5 + w[x] * (1 << PRECISION_BITS));
        }

        a->lo[i]  = xmin;
        a->cnt[i] = xmax;
    }

    free(w);
    return 0;
}

/* ---- the plan ------------------------------------------------------------ */

void camfront_free(camfront_t *cf)
{
    if (cf == NULL)
        return;
    axis_free(&cf->hx);
    axis_free(&cf->vy);
    free(cf->tmp);
    memset(cf, 0, sizeof *cf);
}

int camfront_init(camfront_t *cf, unsigned w, unsigned h)
{
    unsigned i, y0, y1;

    if (cf == NULL)
        return -1;
    memset(cf, 0, sizeof *cf);

    if (camfront_geometry(w, h, &cf->g))
        return -1;
    if (axis_init(&cf->hx, w, cf->g.rs_w, cf->g.win_x, CAMFRONT_WIN) ||
        axis_init(&cf->vy, h, cf->g.rs_h, cf->g.win_y, CAMFRONT_WIN)) {
        camfront_free(cf);
        return -1;
    }

    /*  Resize(256) never needs exactly ONE pass. If the short side is 256 the
     *  long side maps to int(256 * long / 256) = long and neither pass runs.
     *  If it is not, the short side changes, and the long side would only stay
     *  put if 256 / short were in [1, 1 + 1/long) - which needs short <= 256
     *  and long < short / (256 - short), impossible for an integer short < 256
     *  with long >= short. Pillow handles the one-pass cases; this does not need
     *  to, so it refuses them rather than carrying code no geometry can reach
     *  and no test can cover. */
    if (cf->hx.needed != cf->vy.needed) {
        camfront_free(cf);
        return -1;
    }
    if (!cf->hx.needed)
        return 0;

    /*  The source rows the vertical pass reads: Pillow's ybox_first/last,
     *  restricted to the window's rows. */
    y0 = (unsigned)cf->vy.lo[0];
    y1 = 0u;
    for (i = 0; i < CAMFRONT_WIN; i++) {
        unsigned lo = (unsigned)cf->vy.lo[i];
        unsigned hi = lo + (unsigned)cf->vy.cnt[i];
        if (lo < y0) y0 = lo;
        if (hi > y1) y1 = hi;
    }
    cf->tmp_y0   = y0;
    cf->tmp_rows = y1 - y0;

    cf->tmp = malloc((size_t)cf->tmp_rows * CAMFRONT_WIN * QP_CHANNELS);
    if (cf->tmp == NULL) {
        camfront_free(cf);
        return -1;
    }
    return 0;
}

/* ---- the two passes: ImagingResample{Horizontal,Vertical}_8bpc ---------- */

static uint8_t clip8(int v)
{
    /*  Pillow: clip8_lookups[in >> PRECISION_BITS]. The shift of a negative
     *  int is arithmetic on every compiler this builds with, as Pillow also
     *  relies on; BILINEAR never produces one, since its weights are >= 0. */
    v >>= PRECISION_BITS;
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return (uint8_t)v;
}

/*  One source row through the horizontal filter, window columns only. */
static void hpass_row(const camfront_axis_t *a, const uint8_t *src_row,
                      uint8_t *dst_row)
{
    unsigned j;

    for (j = 0; j < a->n; j++) {
        const int32_t *k = a->k + (size_t)j * a->ksize;
        const uint8_t *s = src_row + (size_t)a->lo[j] * QP_CHANNELS;
        int ss0 = 1 << (PRECISION_BITS - 1);
        int ss1 = ss0, ss2 = ss0;
        int x;

        for (x = 0; x < a->cnt[j]; x++) {
            ss0 += s[3 * x + 0] * k[x];
            ss1 += s[3 * x + 1] * k[x];
            ss2 += s[3 * x + 2] * k[x];
        }
        dst_row[3 * j + 0] = clip8(ss0);
        dst_row[3 * j + 1] = clip8(ss1);
        dst_row[3 * j + 2] = clip8(ss2);
    }
}

/*  The vertical filter over the horizontal pass's output, whose first row is
 *  source row `row0`. Each output row accumulates its taps in turn - integer
 *  addition is exact, so the order of the sum cannot change the result, and
 *  this order walks memory forwards. */
static void vpass(const camfront_axis_t *a, const uint8_t *rows, unsigned row0,
                  uint8_t *out)
{
    enum { ROW = CAMFRONT_WIN * QP_CHANNELS };
    int      acc[ROW];
    unsigned i, j;

    for (i = 0; i < a->n; i++) {
        const int32_t *k = a->k + (size_t)i * a->ksize;
        int x;

        for (j = 0; j < ROW; j++)
            acc[j] = 1 << (PRECISION_BITS - 1);

        for (x = 0; x < a->cnt[i]; x++) {
            const uint8_t *r = rows + (size_t)((unsigned)a->lo[i] + (unsigned)x
                                               - row0) * ROW;
            int kx = k[x];
            for (j = 0; j < ROW; j++)
                acc[j] += r[j] * kx;
        }

        for (j = 0; j < ROW; j++)
            out[(size_t)i * ROW + j] = clip8(acc[j]);
    }
}

void camfront_window(const camfront_t *cf, const uint8_t *rgb, size_t stride,
                     uint8_t *out)
{
    const size_t ROW = (size_t)CAMFRONT_WIN * QP_CHANNELS;
    unsigned     i;

    if (!cf->hx.needed) {
        /*  The short side is already 256: torchvision returns the image as it
         *  is, so the window is a plain crop - the dataset's own case. */
        for (i = 0; i < CAMFRONT_WIN; i++)
            memcpy(out + i * ROW,
                   rgb + (size_t)(cf->g.win_y + i) * stride
                       + (size_t)cf->g.win_x * QP_CHANNELS,
                   ROW);
        return;
    }

    for (i = 0; i < cf->tmp_rows; i++)
        hpass_row(&cf->hx, rgb + (size_t)(cf->tmp_y0 + i) * stride,
                  cf->tmp + i * ROW);
    vpass(&cf->vy, cf->tmp, cf->tmp_y0, out);
}

/* ---- YUV 4:2:2 to RGB ---------------------------------------------------- */

/*  OpenCV's ITU-R BT.601 constants (color_yuv.simd.hpp), 20 fractional bits:
 *
 *      R = 1.164(Y-16)                + 1.596(V-128)
 *      G = 1.164(Y-16) - 0.391(U-128) - 0.813(V-128)
 *      B = 1.164(Y-16) + 2.018(U-128)
 *
 *  Limited range, which is what UVC cameras send for YUYV. Outside the
 *  bit-exact chain (camfront.h says why); chosen so a PC can reproduce it with
 *  cv2.cvtColor(..., COLOR_YUV2RGB_YUYV) if it ever needs to. */
#define BT601_CY   1220542
#define BT601_CUB  2116026
#define BT601_CUG  (-409993)
#define BT601_CVG  (-852492)
#define BT601_CVR  1673527
#define BT601_SH   20

static uint8_t sat8(int v)
{
    return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}

static void put_rgb(uint8_t *d, int y, int ruv, int guv, int buv)
{
    int yy = (y - 16 > 0 ? y - 16 : 0) * BT601_CY;

    d[0] = sat8((yy + ruv) >> BT601_SH);
    d[1] = sat8((yy + guv) >> BT601_SH);
    d[2] = sat8((yy + buv) >> BT601_SH);
}

void camfront_yuv422_to_rgb(const uint8_t *src, size_t stride,
                            unsigned w, unsigned h, int uyvy, uint8_t *rgb)
{
    const int iy0 = uyvy ? 1 : 0, iu = uyvy ? 0 : 1;
    const int iy1 = uyvy ? 3 : 2, iv = uyvy ? 2 : 3;
    unsigned  x, y;

    for (y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * stride;
        uint8_t       *d = rgb + (size_t)y * w * 3u;

        for (x = 0; x + 1u < w; x += 2u, s += 4, d += 6) {
            int u   = s[iu] - 128;
            int v   = s[iv] - 128;
            int ruv = (1 << (BT601_SH - 1)) + BT601_CVR * v;
            int guv = (1 << (BT601_SH - 1)) + BT601_CVG * v + BT601_CUG * u;
            int buv = (1 << (BT601_SH - 1)) + BT601_CUB * u;

            put_rgb(d,     s[iy0], ruv, guv, buv);
            put_rgb(d + 3, s[iy1], ruv, guv, buv);
        }
    }
}
