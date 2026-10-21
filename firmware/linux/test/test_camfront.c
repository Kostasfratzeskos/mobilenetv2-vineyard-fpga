/*============================================================================
 *  test_camfront.c  -  the camera front end against torchvision, bit for bit
 *
 *  camfront.c claims to compute torchvision's Resize(256) - Pillow's
 *  antialiased BILINEAR - exactly, on the 256x256 window preproc_rgb takes.
 *  This checks that claim against test/camfront_vectors.txt, which
 *  scripts/gen_camfront_vectors.py made with the real torchvision and Pillow:
 *
 *    * the frame is rebuilt here from the same integer formula, and its digest
 *      must match - so a disagreement is never blamed on the resampler when it
 *      is really the test pattern
 *    * the GEOMETRY must match: the resized size, the crop offsets (measured in
 *      Python against CenterCrop's actual output) and the window
 *    * the WINDOW's 196,608 bytes must match, by digest
 *
 *  Fifteen frame sizes: every common webcam one, an upscale, a portrait frame,
 *  the dataset's own 256x256 (where no pass may run at all), and the half-to-
 *  even crop offsets that a half-up rounding would get wrong.
 *
 *  A failing case writes its window to build/host/<w>x<h>_<pattern>_<seed>.bin,
 *  and `python scripts/gen_camfront_vectors.py --diff <that file>` counts the
 *  bytes that differ, which a digest alone cannot.
 *
 *  Then the parts with no Python reference: the YUV conversion's fixed points
 *  (black, white, the BT.601 primaries), YUYV and UYVY agreeing, and the sizes
 *  camfront_init must refuse.
 *
 *  Run: cd firmware/linux && make test
 *==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "camfront.h"

#define VECTORS "test/camfront_vectors.txt"
#define OUTDIR  "build/host"

static int fails = 0;

static void ck(int cond, const char *what)
{
    if (!cond) {
        printf("  [ERR] %s\n", what);
        fails++;
    }
}

/* ---- the frame generator: gen_camfront_vectors.py's make_frame ---------- */

static uint32_t lowbias32(uint32_t x)
{
    x ^= x >> 16;
    x *= 0x7FEB352Du;
    x ^= x >> 15;
    x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}

static int make_frame(uint8_t *f, unsigned w, unsigned h, const char *pattern,
                      unsigned seed)
{
    unsigned x, y, c;
    size_t   i;

    if (strcmp(pattern, "noise") == 0) {
        uint32_t key = (uint32_t)seed * 0x9E3779B9u;
        for (i = 0; i < (size_t)w * h * 3u; i++)
            f[i] = (uint8_t)(lowbias32((uint32_t)i ^ key) >> 24);
        return 0;
    }
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
            for (c = 0; c < 3u; c++) {
                unsigned v;
                if (strcmp(pattern, "smooth") == 0)
                    v = ((x * 255u) / (w - 1u) * (c + 1u) +
                         (y * 255u) / (h - 1u) * (3u - c)) / 4u;
                else if (strcmp(pattern, "bars") == 0)
                    v = ((x / 3u + y / 5u + c) & 1u) * 255u;
                else
                    return -1;
                f[((size_t)y * w + x) * 3u + c] = (uint8_t)v;
            }
    return 0;
}

/*  FNV-1a 64, as 16 hex digits. Formatted from two 32-bit halves rather than
 *  with %llx, which the Windows host's C runtime does not reliably support -
 *  and a digest compared as text cannot be misparsed on the way in either. */
static void fnv1a64_hex(const uint8_t *p, size_t n, char out[17])
{
    uint64_t h = 0xCBF29CE484222325ull;
    size_t   i;

    for (i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001B3ull;
    }
    snprintf(out, 17, "%08x%08x", (unsigned)(h >> 32), (unsigned)(h & 0xFFFFFFFFu));
}

/* ---- part 1: the vectors ----------------------------------------------- */

static int run_vectors(void)
{
    FILE    *fh = fopen(VECTORS, "r");
    char     line[512];
    int      n = 0;
    uint8_t *win = malloc(CAMFRONT_WIN_BYTES);

    if (fh == NULL || win == NULL) {
        /*  Missing is a FAILURE, not a skip: a front-end check that quietly
         *  stops running is how a claim stops being true without anyone
         *  noticing. The same rule test_preproc follows. */
        printf("  [ERR] cannot read %s - run scripts/gen_camfront_vectors.py\n",
               VECTORS);
        fails++;
        free(win);
        if (fh) fclose(fh);
        return 0;
    }

    while (fgets(line, sizeof line, fh)) {
        unsigned w, h, seed, rs_w, rs_h, cx, cy, wx, wy;
        char     pattern[32], what[160];
        char     in_d[17], win_d[17], got_in[17], got_win[17];
        camfront_t cf;
        uint8_t   *frame;
        int        bad = 0;

        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r')
            continue;
        if (sscanf(line, "%u %u %31s %u %u %u %u %u %u %u %16s %16s",
                   &w, &h, pattern, &seed, &rs_w, &rs_h, &cx, &cy, &wx, &wy,
                   in_d, win_d) != 12) {
            printf("  [ERR] unparseable line: %s", line);
            fails++;
            continue;
        }
        n++;

        frame = malloc((size_t)w * h * 3u);
        if (frame == NULL || make_frame(frame, w, h, pattern, seed)) {
            printf("  [ERR] %ux%u %s: cannot build the frame\n", w, h, pattern);
            fails++;
            free(frame);
            continue;
        }

        fnv1a64_hex(frame, (size_t)w * h * 3u, got_in);
        if (strcmp(got_in, in_d) != 0) {
            printf("  [ERR] %ux%u %s: the FRAME differs from Python's (%s vs %s) "
                   "- the generator, not the resampler\n", w, h, pattern,
                   got_in, in_d);
            fails++;
            free(frame);
            continue;
        }

        if (camfront_init(&cf, w, h)) {
            printf("  [ERR] %ux%u: camfront_init refused a size torchvision takes\n",
                   w, h);
            fails++;
            free(frame);
            continue;
        }

        if (cf.g.rs_w != rs_w || cf.g.rs_h != rs_h || cf.g.crop_x != cx ||
            cf.g.crop_y != cy || cf.g.win_x != wx || cf.g.win_y != wy) {
            printf("  [ERR] %ux%u: geometry rs %ux%u crop (%u,%u) win (%u,%u), "
                   "torchvision says rs %ux%u crop (%u,%u) win (%u,%u)\n",
                   w, h, cf.g.rs_w, cf.g.rs_h, cf.g.crop_x, cf.g.crop_y,
                   cf.g.win_x, cf.g.win_y, rs_w, rs_h, cx, cy, wx, wy);
            fails++;
            bad = 1;
        }

        camfront_window(&cf, frame, (size_t)w * 3u, win);
        fnv1a64_hex(win, CAMFRONT_WIN_BYTES, got_win);
        if (strcmp(got_win, win_d) != 0) {
            char path[128];
            FILE *o;
            snprintf(path, sizeof path, OUTDIR "/%ux%u_%s_%u.bin", w, h, pattern, seed);
            o = fopen(path, "wb");
            if (o) {
                fwrite(win, 1, CAMFRONT_WIN_BYTES, o);
                fclose(o);
            }
            printf("  [ERR] %ux%u %s: the WINDOW differs from torchvision's - "
                   "python scripts/gen_camfront_vectors.py --diff %s\n",
                   w, h, pattern, path);
            fails++;
            bad = 1;
        }

        if (!bad) {
            snprintf(what, sizeof what, "%ux%u %s", w, h, pattern);
            printf("  [ok ] %-18s -> %ux%u, window (%u,%u), %s\n", what,
                   cf.g.rs_w, cf.g.rs_h, cf.g.win_x, cf.g.win_y,
                   cf.hx.needed ? "196,608 bytes bit-exact"
                                : "no resample, a plain crop - as torchvision");
        }
        camfront_free(&cf);
        free(frame);
    }
    fclose(fh);
    free(win);
    return n;
}

/* ---- part 2: YUV, which has no Python reference here -------------------- */

static void yuv_px(uint8_t y, uint8_t u, uint8_t v, uint8_t rgb[3])
{
    uint8_t px[4] = { y, u, y, v };          /* YUYV: two equal pixels */
    uint8_t out[6];

    camfront_yuv422_to_rgb(px, 4, 2, 1, 0, out);
    memcpy(rgb, out, 3);
    ck(memcmp(out, out + 3, 3) == 0, "the two pixels of a YUYV pair differ");
}

static void run_yuv(void)
{
    uint8_t rgb[3];
    char    msg[128];

    /*  The fixed points of limited-range BT.601: Y=16 is black, Y=235 white,
     *  and neutral chroma leaves R = G = B. */
    yuv_px(16, 128, 128, rgb);
    ck(rgb[0] == 0 && rgb[1] == 0 && rgb[2] == 0, "Y=16 is not black");
    yuv_px(235, 128, 128, rgb);
    ck(rgb[0] == 255 && rgb[1] == 255 && rgb[2] == 255, "Y=235 is not white");
    yuv_px(126, 128, 128, rgb);
    ck(rgb[0] == rgb[1] && rgb[1] == rgb[2] && rgb[0] == 128,
       "neutral chroma at Y=126 is not grey 128");
    /*  Below black clamps rather than wrapping. */
    yuv_px(0, 128, 128, rgb);
    ck(rgb[0] == 0 && rgb[1] == 0 && rgb[2] == 0, "Y=0 did not clamp to black");

    /*  The BT.601 primaries. Their 8-bit YCbCr codes are themselves rounded, so
     *  a primary lands within one step of the pure colour, and the float form
     *  of the standard says where: red is (254.41, -0.54, -1.02), green
     *  (0.13, 255.51, 0.82), blue (0.37, -0.06, 255.12). Rounded, those are
     *  the values below - which is a check of the integer constants against
     *  the standard's own definition. Red: Y=81 Cb=90 Cr=240. */
    yuv_px(81, 90, 240, rgb);
    snprintf(msg, sizeof msg, "BT.601 red came out %u,%u,%u, expected 254,0,0",
             rgb[0], rgb[1], rgb[2]);
    ck(rgb[0] == 254 && rgb[1] == 0 && rgb[2] == 0, msg);
    /*  Green: Y=145 Cb=54 Cr=34. The 1 in blue is the standard's 0.82. */
    yuv_px(145, 54, 34, rgb);
    snprintf(msg, sizeof msg, "BT.601 green came out %u,%u,%u, expected 0,255,1",
             rgb[0], rgb[1], rgb[2]);
    ck(rgb[0] == 0 && rgb[1] == 255 && rgb[2] == 1, msg);
    /*  Blue: Y=41 Cb=240 Cr=110. */
    yuv_px(41, 240, 110, rgb);
    snprintf(msg, sizeof msg, "BT.601 blue came out %u,%u,%u, expected 0,0,255",
             rgb[0], rgb[1], rgb[2]);
    ck(rgb[0] == 0 && rgb[1] == 0 && rgb[2] == 255, msg);

    /*  YUYV and UYVY are the same samples in a different order, so the same
     *  frame in both must give identical RGB - over every byte value. */
    {
        enum { W = 256, H = 4 };
        static uint8_t yuyv[W * 2 * H], uyvy[W * 2 * H];
        static uint8_t a[W * 3 * H], b[W * 3 * H];
        unsigned i;

        for (i = 0; i < W * H / 2u; i++) {
            uint8_t y0 = (uint8_t)(lowbias32(4u * i + 0u) >> 24);
            uint8_t u  = (uint8_t)(lowbias32(4u * i + 1u) >> 24);
            uint8_t y1 = (uint8_t)(lowbias32(4u * i + 2u) >> 24);
            uint8_t v  = (uint8_t)(lowbias32(4u * i + 3u) >> 24);
            yuyv[4 * i + 0] = y0; yuyv[4 * i + 1] = u;
            yuyv[4 * i + 2] = y1; yuyv[4 * i + 3] = v;
            uyvy[4 * i + 0] = u;  uyvy[4 * i + 1] = y0;
            uyvy[4 * i + 2] = v;  uyvy[4 * i + 3] = y1;
        }
        camfront_yuv422_to_rgb(yuyv, W * 2, W, H, 0, a);
        camfront_yuv422_to_rgb(uyvy, W * 2, W, H, 1, b);
        ck(memcmp(a, b, sizeof a) == 0, "YUYV and UYVY of the same samples differ");
    }
    if (fails == 0)
        printf("  [ok ] YUV: black, white, grey, clamping, the three primaries, "
               "and YUYV == UYVY\n");
}

/* ---- part 3: what must be refused --------------------------------------- */

static void run_refusals(void)
{
    camfront_t      cf;
    camfront_geom_t g;
    int before = fails;

    ck(camfront_geometry(0, 480, &g) != 0, "a zero width was accepted");
    ck(camfront_geometry(640, 0, &g) != 0, "a zero height was accepted");
    ck(camfront_geometry(CAMFRONT_MAX_SIDE + 1u, 480, &g) != 0,
       "an absurd width was accepted - a garbage driver size would be allocated");
    ck(camfront_init(&cf, 640, 0) != 0, "camfront_init accepted a zero height");
    /*  The largest size allowed must work: 4096x2160 is a real 4K webcam. */
    ck(camfront_init(&cf, 4096, 2160) == 0, "camfront_init refused 4096x2160");
    camfront_free(&cf);
    if (fails == before)
        printf("  [ok ] zero and oversized frames are refused; 4096x2160 is not\n");
}

int main(void)
{
    int n;

    printf("UNIT: the camera front end against torchvision's Resize(256)\n\n");
    n = run_vectors();
    printf("\n");
    run_yuv();
    run_refusals();

    printf("\n");
    if (fails == 0 && n > 0) {
        printf("ALL PASS  (%d frame sizes bit-exact against torchvision + Pillow)\n", n);
        return 0;
    }
    printf("FAILED    (%d problems)\n", fails);
    return 1;
}
