/*============================================================================
 *  fbdev.h  -  the canvas onto the DisplayPort monitor
 *
 *  The ZCU104's DisplayPort output is driven by the PS's own DisplayPort
 *  controller, and Linux presents it - through the zynqmp-dpsub DRM driver's
 *  fbdev emulation - as /dev/fb0. That is the simplest way onto a screen that
 *  exists: open, ask for the resolution and pixel layout, mmap, copy.
 *
 *  Two things the console would otherwise do to the picture are stopped:
 *
 *    * fbcon draws the text console - and its blinking cursor, and any kernel
 *      message - on the same framebuffer. Switching the virtual terminal to
 *      KD_GRAPHICS tells it to stop; fbdev_close switches it back.
 *    * the console blanks the screen after ten minutes without a key press,
 *      which during a talk is a black screen at the worst moment. vinecam.dtsi
 *      sets consoleblank=0, and fbdev_open unblanks in case it already has.
 *
 *  If the program is killed with SIGKILL the terminal stays in graphics mode
 *  and the console looks dead: `vinecam --restore-console` puts it back.
 *==========================================================================*/
#ifndef FBDEV_H
#define FBDEV_H

#include <stddef.h>
#include <stdint.h>

#include "canvas.h"

typedef struct {
    int       fd;
    uint8_t  *mem;
    size_t    len;
    uint8_t  *origin;          /* the first visible pixel                     */
    unsigned  w, h;            /* the visible resolution                      */
    unsigned  bpp;             /* 16, 24 or 32                                */
    unsigned  line;            /* bytes per row                               */
    unsigned  roff, rlen, goff, glen, boff, blen;
    int       xrgb8888;        /* rows can be copied as they are              */
    int       tty;             /* /dev/tty0, for KDSETMODE, or -1             */
} fbdev_t;

int  fbdev_open(fbdev_t *f, const char *dev, char *err, size_t errlen);

/*  The canvas, top-left aligned, clipped to the screen. */
void fbdev_show(fbdev_t *f, const canvas_t *cv);

void fbdev_close(fbdev_t *f);

/*  For --restore-console: put tty0 back in text mode and unblank. */
void fbdev_restore_console(void);

#endif /* FBDEV_H */
