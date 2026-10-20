/*============================================================================
 *  ui.c  -  the demo screen
 *
 *  Every size here is a fraction of the canvas height, so the same code lays
 *  out a 1920x1080 monitor, a 1280x720 projector and the half-size picture the
 *  browser view gets. Nothing in it touches hardware.
 *
 *  The class names come from quant_params.h, which gen_program.py generates
 *  from the manifest - not from a table here. A second list of names is how a
 *  screen ends up labelling ESCA as Black Rot with every number correct.
 *==========================================================================*/
#include "ui.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "quant_params.h"

#define C_BG      0x0D1117u
#define C_PANEL   0x161B22u
#define C_LINE    0x30363Du
#define C_TEXT    0xE6EDF3u
#define C_MUTED   0x8B949Eu
#define C_ACCENT  0x58A6FFu
#define C_GOOD    UI_GOOD
#define C_BAD     UI_BAD
#define C_WARN    0xD29922u

_Static_assert(QP_N_CLASSES == ACCEL_N_CLASSES,
               "the generated class list and the hardware's class count differ");

static const char *CLASS_NAME[QP_N_CLASSES] = QP_CLASS_NAMES;

void ui_softmax(const int16_t logit[ACCEL_N_CLASSES], double p[ACCEL_N_CLASSES])
{
    double   zmax = -1e300, sum = 0.0;
    unsigned i;

    for (i = 0; i < ACCEL_N_CLASSES; i++) {
        double z = logit[i] * QP_LOGIT_SCALE;
        if (z > zmax)
            zmax = z;
    }
    for (i = 0; i < ACCEL_N_CLASSES; i++) {
        p[i] = exp(logit[i] * QP_LOGIT_SCALE - zmax);
        sum += p[i];
    }
    for (i = 0; i < ACCEL_N_CLASSES; i++)
        p[i] /= sum;
}

/*  "Healthy" is the one class that is good news. Found by name, so it follows
 *  the manifest's order rather than assuming one. */
static int is_healthy(const char *name)
{
    const char *h = "HEALTHY";
    size_t      i;

    for (i = 0; name[i] && h[i]; i++) {
        char c = name[i];
        if (c >= 'a' && c <= 'z')
            c = (char)(c - 'a' + 'A');
        if (c != h[i])
            return 0;
    }
    return h[i] == '\0';
}

static int imax(int a, int b) { return a > b ? a : b; }
static int imin(int a, int b) { return a < b ? a : b; }

void ui_render(canvas_t *cv, const ui_state_t *st)
{
    const int W = (int)cv->w, H = (int)cv->h;
    const int m  = imax(4, H / 36);              /* margin                  */
    const int ts = imax(1, H / 270);             /* title text scale        */
    const int bs = imax(1, H / 360);             /* body text scale         */
    const int th = TEXT_HEIGHT(ts) + 2 * m;      /* title bar height        */
    const int fh = TEXT_HEIGHT(bs) + m;          /* footer height           */
    int  px, py, pw, ph, qx, qw, y, i, ls, name_w = 0, longest = 0;
    char buf[96];
    double p[ACCEL_N_CLASSES];

    draw_fill(cv, 0, 0, W, H, C_BG);

    /* ---- title bar ----------------------------------------------------- */
    draw_fill(cv, 0, 0, W, th, C_PANEL);
    draw_fill(cv, 0, th - imax(1, bs / 2), W, imax(1, bs / 2), C_LINE);
    draw_text(cv, m, m, ts, C_TEXT, "GRAPEVINE LEAF DISEASE DETECTION");
    {
        const char *r = "MOBILENETV2 INT8 ON THE FPGA";
        draw_text(cv, W - m - text_width(r, bs), (th - TEXT_HEIGHT(bs)) / 2,
                  bs, C_MUTED, r);
    }

    /* ---- the camera picture, fitted into the left two-thirds ------------ */
    pw = W * 2 / 3 - 2 * m;
    ph = H - th - fh - 2 * m;
    px = m;
    py = th + m;
    if (st->frame != NULL && st->fw > 0u && st->fh > 0u && pw > 0 && ph > 0) {
        int dw = pw, dh = (int)((long long)pw * st->fh / st->fw);
        if (dh > ph) {
            dh = ph;
            dw = (int)((long long)ph * st->fw / st->fh);
        }
        /*  Centred in its box; the panel on the right keeps the box's top. */
        int iy = py + (ph - dh) / 2;

        px += (pw - dw) / 2;
        draw_image(cv, px, iy, dw, dh, st->frame, st->fw, st->fh, st->crop, 96u);

        /*  The square the network sees, outlined. */
        {
            int x0 = px + (int)((long long)st->crop[0] * dw / (int)st->fw);
            int y0 = iy + (int)((long long)st->crop[1] * dh / (int)st->fh);
            int x1 = px + (int)((long long)st->crop[2] * dw / (int)st->fw);
            int y1 = iy + (int)((long long)st->crop[3] * dh / (int)st->fh);
            int t  = imax(2, bs);
            draw_frame(cv, x0 - t, y0 - t, x1 - x0 + 2 * t, y1 - y0 + 2 * t, t,
                       C_ACCENT);
            if (y1 + t + bs + TEXT_HEIGHT(bs) < iy + dh)
                draw_text(cv, x0, y1 + 2 * t, bs, C_ACCENT, "WHAT THE NETWORK SEES");
        }
        pw = dw;
    } else {
        draw_frame(cv, px, py, pw, ph, imax(1, bs), C_LINE);
        draw_text(cv, px + m, py + m, bs, C_MUTED, "NO PICTURE");
    }

    /* ---- the result panel ------------------------------------------------ */
    qx = px + pw + m;
    qw = W - qx - m;
    if (qw <= 0)
        return;
    draw_fill(cv, qx, py, qw, ph, C_PANEL);
    qx += m;
    qw -= 2 * m;
    y   = py + m;

    draw_text(cv, qx, y, bs, C_MUTED, "PREDICTION");
    y += TEXT_HEIGHT(bs) + m;

    /*  One label scale for every class, from the longest name, so the label
     *  does not jump in size when the class changes. */
    for (i = 0; i < (int)ACCEL_N_CLASSES; i++) {
        longest = imax(longest, text_width(CLASS_NAME[i], 1));
        name_w  = imax(name_w, text_width(CLASS_NAME[i], bs));
    }
    ls = imax(1, imin(H / 90, longest ? qw / longest : 1));

    if (st->have_result && st->argmax < ACCEL_N_CLASSES) {
        const char *name = CLASS_NAME[st->argmax];
        uint32_t    col  = is_healthy(name) ? C_GOOD : C_BAD;

        ui_softmax(st->logit, p);
        draw_text(cv, qx, y, ls, col, name);
        y += TEXT_HEIGHT(ls) + m / 2;
        snprintf(buf, sizeof buf, "%.1f %%", 100.0 * p[st->argmax]);
        draw_text(cv, qx, y, 2 * bs, C_TEXT, buf);
        y += TEXT_HEIGHT(2 * bs) + m;

        /*  A bar per class: name, bar, percentage. */
        for (i = 0; i < (int)ACCEL_N_CLASSES; i++) {
            int bx = qx + name_w + m / 2;
            int bw = qw - name_w - m / 2 - text_width("100.0%", bs) - m / 2;
            int bh = TEXT_HEIGHT(bs);
            uint32_t bc = (unsigned)i == st->argmax ? col : C_MUTED;

            draw_text(cv, qx, y, bs, (unsigned)i == st->argmax ? C_TEXT : C_MUTED,
                      CLASS_NAME[i]);
            if (bw > 0) {
                draw_fill(cv, bx, y, bw, bh, C_LINE);
                draw_fill(cv, bx, y, (int)(bw * p[i] + 0.5), bh, bc);
            }
            snprintf(buf, sizeof buf, "%.1f%%", 100.0 * p[i]);
            draw_text(cv, qx + qw - text_width(buf, bs), y, bs, C_TEXT, buf);
            y += bh + bs * 4;
        }
    } else {
        draw_text(cv, qx, y, 2 * bs, C_MUTED, "WAITING");
        y += TEXT_HEIGHT(2 * bs) + m;
    }

    /* ---- the numbers --------------------------------------------------- */
    y += m;
    draw_fill(cv, qx, y, qw, imax(1, bs / 2), C_LINE);
    y += m;
    snprintf(buf, sizeof buf, "FPGA INFERENCE  %.1f MS", st->accel_ms);
    draw_text(cv, qx, y, bs, C_TEXT, buf);
    y += TEXT_HEIGHT(bs) + bs * 4;
    snprintf(buf, sizeof buf, "WHOLE LOOP      %.1f FPS", st->fps);
    draw_text(cv, qx, y, bs, C_TEXT, buf);
    y += TEXT_HEIGHT(bs) + m;

    if (st->frozen && y + TEXT_HEIGHT(2 * bs) < py + ph) {
        draw_text(cv, qx, y, 2 * bs, C_WARN, "FROZEN");
    }

    /* ---- footer --------------------------------------------------------- */
    if (st->source)
        draw_text(cv, m, H - fh, bs, C_MUTED, st->source);
    if (st->note)
        draw_text(cv, W - m - text_width(st->note, bs), H - fh, bs, C_WARN, st->note);
}
