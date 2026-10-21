/*============================================================================
 *  test_ui.c  -  the demo screen at every size it might meet
 *
 *  What can go wrong with a screen that matters on the day:
 *
 *    * a layout that overruns at a resolution nobody tried writes past the
 *      canvas - so every size here renders between guard words, from 4K down
 *      to 64x48, and a single overwritten guard fails the test
 *    * the label in the wrong colour - green is the healthy class, and only
 *      the healthy class; a disease shown in green, or "Healthy" in red, is
 *      read by the audience before any number is. Checked for every class.
 *    * a softmax that does not sum to one, or whose largest entry is not the
 *      accelerator's argmax
 *    * text_width disagreeing with what draw_text draws, which the layout
 *      uses to right-align and to size the label
 *
 *  tools/render_ui writes the same screen to a file, for looking at.
 *
 *  Run: cd firmware/linux && make test
 *==========================================================================*/
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quant_params.h"
#include "ui.h"

#define GUARD      4096u
#define GUARD_WORD 0xDEADBEEFu

static int fails = 0;

static void ck(int cond, const char *what)
{
    if (!cond) {
        printf("  [ERR] %s\n", what);
        fails++;
    }
}

static int has_colour(const canvas_t *c, uint32_t rgb)
{
    size_t i, n = (size_t)c->w * c->h;

    for (i = 0; i < n; i++)
        if (c->px[i] == rgb)
            return 1;
    return 0;
}

int main(void)
{
    static const unsigned sizes[][2] = {
        { 3840, 2160 }, { 1920, 1080 }, { 1280, 1024 }, { 1280, 720 },
        { 1024, 768 }, { 800, 600 }, { 800, 480 }, { 640, 480 },
        { 320, 240 }, { 64, 48 },
    };
    static const char *names[QP_N_CLASSES] = QP_CLASS_NAMES;
    const unsigned FW = 640, FH = 480;
    uint8_t   *frame = malloc((size_t)FW * FH * 3u);
    ui_state_t st;
    unsigned   s, k, i;
    int        before;

    printf("UNIT: the demo screen - bounds, colours, softmax, text metrics\n\n");

    for (i = 0; i < FW * FH * 3u; i++)
        frame[i] = (uint8_t)(i * 7u);

    memset(&st, 0, sizeof st);
    st.frame   = frame;
    st.fw      = FW;
    st.fh      = FH;
    st.crop[0] = 102; st.crop[1] = 30; st.crop[2] = 523; st.crop[3] = 451;
    st.have_result = 1;
    st.logit[0] = -8592; st.logit[1] = 23216; st.logit[2] = -10575; st.logit[3] = -3925;
    st.argmax   = 1;
    st.accel_ms = 6.21;
    st.fps      = 17.9;
    st.source   = "HD WEBCAM C270  640X480";
    st.note     = "A NOTE AT THE BOTTOM";

    /* ---- bounds -------------------------------------------------------- */
    before = fails;
    for (s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        unsigned  w = sizes[s][0], h = sizes[s][1];
        size_t    n = (size_t)w * h;
        uint32_t *mem = malloc((n + 2u * GUARD) * sizeof *mem);
        canvas_t  cv;
        int       f;

        for (i = 0; i < GUARD; i++)
            mem[i] = mem[GUARD + n + i] = GUARD_WORD;
        cv.px = mem + GUARD;
        cv.w  = w;
        cv.h  = h;

        for (f = 0; f < 4; f++) {
            st.frozen      = f & 1;
            st.frame       = (f & 2) ? NULL : frame;
            ui_render(&cv, &st);
        }
        for (i = 0; i < GUARD; i++)
            if (mem[i] != GUARD_WORD || mem[GUARD + n + i] != GUARD_WORD) {
                printf("  [ERR] %ux%u: the screen was drawn OUTSIDE the canvas\n", w, h);
                fails++;
                break;
            }
        free(mem);
    }
    st.frame  = frame;
    st.frozen = 0;
    if (fails == before)
        printf("  [ok ] ten sizes, 3840x2160 to 64x48, with and without a picture "
               "and frozen: nothing drawn outside the canvas\n");

    /* ---- nothing runs into the bottom margin ---------------------------- *
     *  The guard words cannot see an overrun that the clipping hides at the
     *  canvas edge - a panel that slid down past the bottom of the screen is
     *  "inside" the canvas, just wrong. The last row is margin, below the
     *  footer text, so it must be one colour. Both frame shapes: a 16:9 frame
     *  is letterboxed in its box, which is how this broke once. */
    before = fails;
    {
        static const unsigned shapes[2][2] = { { 640, 480 }, { 1280, 720 } };
        uint8_t *wide = malloc((size_t)1280 * 720 * 3u);
        unsigned sh;

        for (i = 0; i < 1280u * 720u * 3u; i++)
            wide[i] = (uint8_t)(i * 5u);
        for (s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
            unsigned w = sizes[s][0], h = sizes[s][1];
            if (h < 240u)
                continue;
            for (sh = 0; sh < 2; sh++) {
                canvas_t cv;
                unsigned x;
                canvas_init(&cv, w, h);
                st.frame = sh ? wide : frame;
                st.fw    = shapes[sh][0];
                st.fh    = shapes[sh][1];
                st.note  = NULL;
                ui_render(&cv, &st);
                for (x = 1; x < w; x++)
                    if (cv.px[(size_t)(h - 1u) * w + x] != cv.px[(size_t)(h - 1u) * w]) {
                        printf("  [ERR] %ux%u, a %ux%u frame: something reaches the "
                               "bottom row at x=%u\n", w, h, st.fw, st.fh, x);
                        fails++;
                        break;
                    }
                canvas_free(&cv);
            }
        }
        free(wide);
        st.frame = frame;
        st.fw    = FW;
        st.fh    = FH;
        st.note  = "A NOTE AT THE BOTTOM";
    }
    if (fails == before)
        printf("  [ok ] 4:3 and 16:9 frames: nothing runs into the bottom margin\n");

    /* ---- the label's colour, for every class ----------------------------- */
    before = fails;
    for (k = 0; k < QP_N_CLASSES; k++) {
        canvas_t cv;
        int      healthy = strcmp(names[k], "Healthy") == 0;
        char     msg[160];

        canvas_init(&cv, 1920, 1080);
        memset(st.logit, 0, sizeof st.logit);
        st.logit[k] = 20000;
        st.argmax   = k;
        ui_render(&cv, &st);
        snprintf(msg, sizeof msg, "class %u (%s) is drawn in the wrong colour",
                 k, names[k]);
        ck(healthy ? (has_colour(&cv, UI_GOOD) && !has_colour(&cv, UI_BAD))
                   : (has_colour(&cv, UI_BAD) && !has_colour(&cv, UI_GOOD)), msg);
        canvas_free(&cv);
    }
    if (fails == before)
        printf("  [ok ] green for Healthy and only Healthy, red for every disease\n");

    /* ---- softmax ------------------------------------------------------- */
    before = fails;
    {
        static const int16_t L[3][4] = {
            { -8592, 23216, -10575, -3925 },     /* EXPECTED.txt, esca_4399 */
            { 0, 0, 0, 0 },
            { 32767, -32768, 32767, -32768 },    /* the extremes, a tie */
        };
        unsigned t;
        for (t = 0; t < 3; t++) {
            double p[4], sum = 0.0;
            unsigned best = 0;
            ui_softmax(L[t], p);
            for (i = 0; i < 4; i++) {
                sum += p[i];
                if (L[t][i] > L[t][best])
                    best = i;
                ck(p[i] >= 0.0 && p[i] <= 1.0 && !isnan(p[i]),
                   "a softmax entry is outside [0, 1]");
            }
            ck(fabs(sum - 1.0) < 1e-12, "the softmax does not sum to one");
            for (i = 0; i < 4; i++)
                ck(p[i] <= p[best], "the largest probability is not the largest logit");
        }
    }
    if (fails == before)
        printf("  [ok ] softmax: sums to one, in range, largest at the argmax - "
               "including saturated logits\n");

    /* ---- text metrics --------------------------------------------------- */
    before = fails;
    {
        canvas_t   cv;
        const char *t = "LEAF BLIGHT 97.5%";
        int         sc;
        canvas_init(&cv, 400, 100);
        for (sc = 1; sc <= 4; sc++)
            ck(draw_text(&cv, 0, 0, sc, 0xFFFFFFu, t) == text_width(t, sc),
               "draw_text drew a different width from text_width");
        canvas_free(&cv);
    }
    if (fails == before)
        printf("  [ok ] text_width matches what draw_text draws, at every scale\n");

    free(frame);
    printf("\n");
    if (fails == 0) {
        printf("ALL PASS\n");
        return 0;
    }
    printf("FAILED    (%d problems)\n", fails);
    return 1;
}
