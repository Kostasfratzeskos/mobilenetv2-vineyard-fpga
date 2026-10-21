/*============================================================================
 *  canvas.h  -  a picture in memory, and the few things drawn on it
 *
 *  The screen is composed here, as 0x00RRGGBB words, and only then converted
 *  to whatever the framebuffer wants (fbdev.c) or sent to a browser (httpview.c).
 *  Composing in one fixed format keeps the drawing code free of pixel formats,
 *  and it is portable C - so tools/render_ui.c can render the exact screen the
 *  board will show, on a PC, from a photograph, before there is a board.
 *
 *  Text is a 5x7 bitmap font drawn at an integer scale: no font files, no
 *  library, legible from the back of a room at scale 6 and up. Upper case only;
 *  lower case is drawn as upper case.
 *==========================================================================*/
#ifndef CANVAS_H
#define CANVAS_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t *px;               /* w * h words, 0x00RRGGBB, row-major          */
    unsigned  w, h;
} canvas_t;

int  canvas_init(canvas_t *c, unsigned w, unsigned h);
void canvas_free(canvas_t *c);

/*  Every primitive clips to the canvas, so a layout that overruns at an odd
 *  screen size draws less rather than writing past the buffer. */
void draw_fill(canvas_t *c, int x, int y, int w, int h, uint32_t rgb);
void draw_frame(canvas_t *c, int x, int y, int w, int h, int t, uint32_t rgb);

/*  Returns the width drawn. A glyph is 5x7 in a 6x9 cell, times `scale`. */
int  draw_text(canvas_t *c, int x, int y, int scale, uint32_t rgb, const char *s);
int  text_width(const char *s, int scale);
#define TEXT_HEIGHT(scale)  (7 * (scale))

/*  An RGB888 image (sw x sh, HWC), scaled nearest-neighbour into the dw x dh
 *  box at (dx, dy). If `keep` is not NULL it is a rectangle in IMAGE pixels
 *  (x0, y0, x1, y1); everything outside it is darkened to dim/256, so the
 *  part the network actually sees stands out. */
void draw_image(canvas_t *c, int dx, int dy, int dw, int dh,
                const uint8_t *rgb, unsigned sw, unsigned sh,
                const int keep[4], unsigned dim);

/*  Binary PPM (P6). For tools/render_ui.c and for looking at a dump. */
int  canvas_write_ppm(const canvas_t *c, const char *path);

#endif /* CANVAS_H */
