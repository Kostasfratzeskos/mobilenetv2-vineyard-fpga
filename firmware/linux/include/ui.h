/*============================================================================
 *  ui.h  -  what the screen shows during the demo
 *
 *  The camera picture on the left, with the 224x224 square the network
 *  actually sees left bright and everything else dimmed. On the right the
 *  class, a softmax per class, and the two numbers worth saying out loud: how
 *  long the FPGA took and how many frames a second the whole loop runs.
 *
 *  One function, from a plain struct, onto a canvas - so the same layout is
 *  rendered by the board (vinecam.c) and by tools/render_ui.c on a PC, which
 *  is how it was checked before there was a board to check it on.
 *==========================================================================*/
#ifndef UI_H
#define UI_H

#include <stdint.h>

#include "accel_csr.h"
#include "canvas.h"

/*  The two colours that carry meaning: the class label is drawn in UI_GOOD
 *  for the healthy class and UI_BAD for every disease. test_ui.c checks that
 *  coupling, since it is the part of the screen an audience reads first. */
#define UI_GOOD  0x3FB950u
#define UI_BAD   0xF85149u

typedef struct {
    const uint8_t *frame;        /* the camera picture, RGB888, or NULL      */
    unsigned       fw, fh;
    int            crop[4];      /* the network's input, in frame pixels:
                                  * x0, y0, x1, y1 (half-open)               */

    int            have_result;
    int16_t        logit[ACCEL_N_CLASSES];
    unsigned       argmax;

    double         accel_ms;     /* image load + run, as the PS timed it     */
    double         fps;          /* the whole loop                           */
    int            frozen;
    const char    *source;       /* e.g. "USB CAMERA 640X480"                */
    const char    *note;         /* one line at the bottom, or NULL          */
} ui_state_t;

void ui_render(canvas_t *cv, const ui_state_t *st);

/*  The softmax of the int16 logits at QP_LOGIT_SCALE - what predict.py prints
 *  as a percentage, from the integers the accelerator returned. */
void ui_softmax(const int16_t logit[ACCEL_N_CLASSES], double p[ACCEL_N_CLASSES]);

#endif /* UI_H */
