/*============================================================================
 *  canvas.c  -  rectangles, a bitmap font, and a scaled image
 *
 *  See canvas.h. The font is written out as pictures, one string per row, so
 *  a wrong glyph is visible in the source rather than hidden in a hex table.
 *==========================================================================*/
#include "canvas.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the font ----------------------------------------------------------- */

typedef struct {
    char        ch;
    const char *row[7];
} glyph_src_t;

static const glyph_src_t FONT[] = {
    { 'A', { ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    { 'B', { "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." } },
    { 'C', { ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###." } },
    { 'D', { "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." } },
    { 'E', { "#####", "#....", "#....", "####.", "#....", "#....", "#####" } },
    { 'F', { "#####", "#....", "#....", "####.", "#....", "#....", "#...." } },
    { 'G', { ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####" } },
    { 'H', { "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    { 'I', { ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    { 'J', { "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.." } },
    { 'K', { "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" } },
    { 'L', { "#....", "#....", "#....", "#....", "#....", "#....", "#####" } },
    { 'M', { "#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#" } },
    { 'N', { "#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#" } },
    { 'O', { ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    { 'P', { "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." } },
    { 'Q', { ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" } },
    { 'R', { "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" } },
    { 'S', { ".####", "#....", "#....", ".###.", "....#", "....#", "####." } },
    { 'T', { "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." } },
    { 'U', { "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    { 'V', { "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.." } },
    { 'W', { "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#." } },
    { 'X', { "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" } },
    { 'Y', { "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." } },
    { 'Z', { "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" } },
    { '0', { ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." } },
    { '1', { "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    { '2', { ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" } },
    { '3', { "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###." } },
    { '4', { "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#." } },
    { '5', { "#####", "#....", "####.", "....#", "....#", "#...#", ".###." } },
    { '6', { "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." } },
    { '7', { "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." } },
    { '8', { ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###." } },
    { '9', { ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." } },
    { ' ', { ".....", ".....", ".....", ".....", ".....", ".....", "....." } },
    { '.', { ".....", ".....", ".....", ".....", ".....", ".##..", ".##.." } },
    { ',', { ".....", ".....", ".....", ".....", ".##..", "..#..", ".#..." } },
    { ':', { ".....", ".##..", ".##..", ".....", ".##..", ".##..", "....." } },
    { '-', { ".....", ".....", ".....", "#####", ".....", ".....", "....." } },
    { '+', { ".....", "..#..", "..#..", "#####", "..#..", "..#..", "....." } },
    { '%', { "##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##" } },
    { '/', { ".....", "....#", "...#.", "..#..", ".#...", "#....", "....." } },
    { '(', { "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#." } },
    { ')', { ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..." } },
    { '[', { ".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###." } },
    { ']', { ".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###." } },
    { '_', { ".....", ".....", ".....", ".....", ".....", ".....", "#####" } },
    { '=', { ".....", ".....", "#####", ".....", "#####", ".....", "....." } },
    { '!', { "..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.." } },
    { '?', { ".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.." } },
    { '\'',{ "..#..", "..#..", ".#...", ".....", ".....", ".....", "....." } },
    { '#', { ".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#." } },
    { '<', { "...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#." } },
    { '>', { ".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..." } },
    { '*', { ".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....." } },
};

/*  Built once from FONT: bit 4 is the leftmost column. 0xFF marks a code with
 *  no glyph, which is drawn as a hollow box - visible, not blank. */
static uint8_t glyph[128][7];
static int     glyph_ready;

static void font_build(void)
{
    size_t i;
    int    r, x;

    memset(glyph, 0xFF, sizeof glyph);
    for (i = 0; i < sizeof FONT / sizeof FONT[0]; i++) {
        unsigned char ch = (unsigned char)FONT[i].ch;
        for (r = 0; r < 7; r++) {
            uint8_t bits = 0;
            for (x = 0; x < 5; x++)
                if (FONT[i].row[r][x] == '#')
                    bits |= (uint8_t)(1u << (4 - x));
            glyph[ch][r] = bits;
        }
    }
    glyph_ready = 1;
}

static const uint8_t *glyph_of(char ch)
{
    static const uint8_t box[7] = { 0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F };
    unsigned char c = (unsigned char)ch;

    if (!glyph_ready)
        font_build();
    if (c >= 'a' && c <= 'z')
        c = (unsigned char)(c - 'a' + 'A');
    if (c >= 128u || glyph[c][0] == 0xFF)
        return box;
    return glyph[c];
}

/* ---- the canvas --------------------------------------------------------- */

int canvas_init(canvas_t *c, unsigned w, unsigned h)
{
    c->w  = w;
    c->h  = h;
    c->px = calloc((size_t)w * h, sizeof *c->px);
    return c->px ? 0 : -1;
}

void canvas_free(canvas_t *c)
{
    free(c->px);
    memset(c, 0, sizeof *c);
}

void draw_fill(canvas_t *c, int x, int y, int w, int h, uint32_t rgb)
{
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w, y1 = y + h, i, j;

    if (x1 > (int)c->w) x1 = (int)c->w;
    if (y1 > (int)c->h) y1 = (int)c->h;
    for (j = y0; j < y1; j++) {
        uint32_t *row = c->px + (size_t)j * c->w;
        for (i = x0; i < x1; i++)
            row[i] = rgb;
    }
}

void draw_frame(canvas_t *c, int x, int y, int w, int h, int t, uint32_t rgb)
{
    draw_fill(c, x, y, w, t, rgb);
    draw_fill(c, x, y + h - t, w, t, rgb);
    draw_fill(c, x, y, t, h, rgb);
    draw_fill(c, x + w - t, y, t, h, rgb);
}

int text_width(const char *s, int scale)
{
    size_t n = strlen(s);
    /*  A 6-wide cell per character, less the trailing column of the last. */
    return n ? (int)(n * 6u - 1u) * scale : 0;
}

int draw_text(canvas_t *c, int x, int y, int scale, uint32_t rgb, const char *s)
{
    int x0 = x;

    for (; *s; s++, x += 6 * scale) {
        const uint8_t *g = glyph_of(*s);
        int r, col;
        for (r = 0; r < 7; r++)
            for (col = 0; col < 5; col++)
                if (g[r] & (1u << (4 - col)))
                    draw_fill(c, x + col * scale, y + r * scale, scale, scale, rgb);
    }
    return x - x0 - (x > x0 ? scale : 0);
}

/*  The widest box draw_image will fill. Wider than any framebuffer this board
 *  drives; a wider request is clipped to it rather than refused. */
#define DRAW_MAX_W 4096

void draw_image(canvas_t *c, int dx, int dy, int dw, int dh,
                const uint8_t *rgb, unsigned sw, unsigned sh,
                const int keep[4], unsigned dim)
{
    /*  The source column of every destination column, worked out once per
     *  call: a 64-bit divide per PIXEL would cost tens of milliseconds a frame
     *  on the A53 at 1280x960, more than the accelerator's whole inference. */
    static unsigned xmap[DRAW_MAX_W];
    static uint8_t  xin[DRAW_MAX_W];
    int i, j;

    if (dw <= 0 || dh <= 0 || sw == 0u || sh == 0u)
        return;
    if (dw > DRAW_MAX_W)
        dw = DRAW_MAX_W;
    for (i = 0; i < dw; i++) {
        xmap[i] = (unsigned)((uint64_t)i * sw / (unsigned)dw);
        xin[i]  = keep == NULL || ((int)xmap[i] >= keep[0] && (int)xmap[i] < keep[2]);
    }

    for (j = 0; j < dh; j++) {
        int       y  = dy + j;
        unsigned  sy = (unsigned)((uint64_t)j * sh / (unsigned)dh);
        const uint8_t *src = rgb + (size_t)sy * sw * 3u;
        uint32_t *row;
        int       y_in;

        if (y < 0 || y >= (int)c->h)
            continue;
        row  = c->px + (size_t)y * c->w;
        y_in = keep == NULL || ((int)sy >= keep[1] && (int)sy < keep[3]);
        for (i = 0; i < dw; i++) {
            int            x = dx + i;
            const uint8_t *p = src + (size_t)xmap[i] * 3u;
            unsigned       r = p[0], g = p[1], b = p[2];

            if (x < 0 || x >= (int)c->w)
                continue;
            if (!(y_in && xin[i])) {
                r = r * dim >> 8;
                g = g * dim >> 8;
                b = b * dim >> 8;
            }
            row[x] = (r << 16) | (g << 8) | b;
        }
    }
}

int canvas_write_ppm(const canvas_t *c, const char *path)
{
    FILE    *fh = fopen(path, "wb");
    unsigned x, y;

    if (fh == NULL)
        return -1;
    fprintf(fh, "P6\n%u %u\n255\n", c->w, c->h);
    for (y = 0; y < c->h; y++)
        for (x = 0; x < c->w; x++) {
            uint32_t v = c->px[(size_t)y * c->w + x];
            unsigned char px[3] = { (unsigned char)(v >> 16),
                                    (unsigned char)(v >> 8),
                                    (unsigned char)v };
            fwrite(px, 1, 3, fh);
        }
    return fclose(fh);
}
