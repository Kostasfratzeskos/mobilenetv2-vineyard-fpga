/*============================================================================
 *  fbdev.c  -  /dev/fb0, in whatever pixel format it reports
 *
 *  Linux only. See fbdev.h.
 *==========================================================================*/
#define _GNU_SOURCE
#include "fbdev.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/fb.h>
#include <linux/kd.h>

int fbdev_open(fbdev_t *f, const char *dev, char *err, size_t errlen)
{
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo x;
    void *m;

    memset(f, 0, sizeof *f);
    f->fd  = -1;
    f->tty = -1;

    f->fd = open(dev, O_RDWR);
    if (f->fd < 0) {
        snprintf(err, errlen, "%s: %s - no monitor at boot, or no DisplayPort "
                 "in the device tree? (--no-display runs without one)",
                 dev, strerror(errno));
        return -1;
    }
    if (ioctl(f->fd, FBIOGET_VSCREENINFO, &v) < 0 ||
        ioctl(f->fd, FBIOGET_FSCREENINFO, &x) < 0) {
        snprintf(err, errlen, "%s: cannot read the screen geometry", dev);
        fbdev_close(f);
        return -1;
    }
    if (v.bits_per_pixel != 16u && v.bits_per_pixel != 24u &&
        v.bits_per_pixel != 32u) {
        snprintf(err, errlen, "%s: %u bits per pixel is not supported", dev,
                 v.bits_per_pixel);
        fbdev_close(f);
        return -1;
    }

    f->w    = v.xres;
    f->h    = v.yres;
    f->bpp  = v.bits_per_pixel;
    f->line = x.line_length;
    f->roff = v.red.offset;   f->rlen = v.red.length;
    f->goff = v.green.offset; f->glen = v.green.length;
    f->boff = v.blue.offset;  f->blen = v.blue.length;
    if (f->rlen == 0u || f->rlen > 8u || f->glen == 0u || f->glen > 8u ||
        f->blen == 0u || f->blen > 8u) {
        snprintf(err, errlen, "%s: a %u/%u/%u-bit RGB layout is not supported",
                 dev, f->rlen, f->glen, f->blen);
        fbdev_close(f);
        return -1;
    }
    f->xrgb8888 = f->bpp == 32u && f->roff == 16u && f->goff == 8u &&
                  f->boff == 0u && f->rlen == 8u && f->glen == 8u && f->blen == 8u;
    f->len  = x.smem_len;

    m = mmap(NULL, f->len, PROT_READ | PROT_WRITE, MAP_SHARED, f->fd, 0);
    if (m == MAP_FAILED) {
        snprintf(err, errlen, "%s: mmap failed: %s", dev, strerror(errno));
        fbdev_close(f);
        return -1;
    }
    f->mem    = (uint8_t *)m;
    /*  The console may have panned the buffer; draw where it is LOOKING. */
    f->origin = f->mem + (size_t)v.yoffset * f->line
                       + (size_t)v.xoffset * (f->bpp / 8u);
    if ((size_t)(f->origin - f->mem) + (size_t)f->h * f->line > f->len) {
        snprintf(err, errlen, "%s: the visible area is outside the mapping", dev);
        fbdev_close(f);
        return -1;
    }

    (void)ioctl(f->fd, FBIOBLANK, FB_BLANK_UNBLANK);

    /*  Stop fbcon drawing over us. Needs root; without it the picture still
     *  shows, with a cursor blinking in a corner. */
    f->tty = open("/dev/tty0", O_RDWR);
    if (f->tty >= 0 && ioctl(f->tty, KDSETMODE, KD_GRAPHICS) < 0) {
        close(f->tty);
        f->tty = -1;
    }
    return 0;
}

static uint32_t pack(const fbdev_t *f, uint32_t rgb)
{
    uint32_t r = (rgb >> 16) & 0xFFu, g = (rgb >> 8) & 0xFFu, b = rgb & 0xFFu;

    return ((r >> (8u - f->rlen)) << f->roff) |
           ((g >> (8u - f->glen)) << f->goff) |
           ((b >> (8u - f->blen)) << f->boff);
}

void fbdev_show(fbdev_t *f, const canvas_t *cv)
{
    unsigned w = cv->w < f->w ? cv->w : f->w;
    unsigned h = cv->h < f->h ? cv->h : f->h;
    unsigned x, y;

    for (y = 0; y < h; y++) {
        const uint32_t *src = cv->px + (size_t)y * cv->w;
        uint8_t        *dst = f->origin + (size_t)y * f->line;

        if (f->xrgb8888) {
            memcpy(dst, src, (size_t)w * 4u);
            continue;
        }
        for (x = 0; x < w; x++) {
            uint32_t v = pack(f, src[x]);
            switch (f->bpp) {
            case 32: memcpy(dst + 4u * x, &v, 4); break;
            case 24: dst[3u * x]      = (uint8_t)v;
                     dst[3u * x + 1u] = (uint8_t)(v >> 8);
                     dst[3u * x + 2u] = (uint8_t)(v >> 16); break;
            default: { uint16_t s = (uint16_t)v; memcpy(dst + 2u * x, &s, 2); }
            }
        }
    }
}

void fbdev_close(fbdev_t *f)
{
    if (f->tty >= 0) {
        (void)ioctl(f->tty, KDSETMODE, KD_TEXT);
        close(f->tty);
    }
    if (f->mem != NULL)
        munmap(f->mem, f->len);
    if (f->fd >= 0)
        close(f->fd);
    memset(f, 0, sizeof *f);
    f->fd  = -1;
    f->tty = -1;
}

void fbdev_restore_console(void)
{
    int tty = open("/dev/tty0", O_RDWR);
    int fb  = open("/dev/fb0", O_RDWR);

    if (tty >= 0) {
        (void)ioctl(tty, KDSETMODE, KD_TEXT);
        close(tty);
    }
    if (fb >= 0) {
        (void)ioctl(fb, FBIOBLANK, FB_BLANK_UNBLANK);
        close(fb);
    }
}
