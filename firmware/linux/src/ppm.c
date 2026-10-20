/*============================================================================
 *  ppm.c  -  read and write binary PPM
 *==========================================================================*/
#include "ppm.h"

#include <stdio.h>
#include <stdlib.h>

#include "camfront.h"

/*  The next header number, skipping whitespace and # comments. */
static int next_num(FILE *fh, unsigned *v)
{
    int c;

    for (;;) {
        c = fgetc(fh);
        if (c == '#') {
            while (c != '\n' && c != EOF)
                c = fgetc(fh);
        } else if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
            break;
        }
    }
    if (c < '0' || c > '9')
        return -1;
    *v = 0;
    while (c >= '0' && c <= '9') {
        if (*v > 100000u)
            return -1;
        *v = *v * 10u + (unsigned)(c - '0');
        c = fgetc(fh);
    }
    /*  Exactly one whitespace byte ends the header; the pixels follow. */
    return (c == ' ' || c == '\t' || c == '\n' || c == '\r') ? 0 : -1;
}

uint8_t *ppm_read(const char *path, unsigned *w, unsigned *h)
{
    FILE    *fh = fopen(path, "rb");
    unsigned maxval;
    size_t   n;
    uint8_t *rgb;

    if (fh == NULL)
        return NULL;
    if (fgetc(fh) != 'P' || fgetc(fh) != '6' ||
        next_num(fh, w) || next_num(fh, h) || next_num(fh, &maxval) ||
        maxval != 255u || *w == 0u || *h == 0u ||
        *w > CAMFRONT_MAX_SIDE || *h > CAMFRONT_MAX_SIDE) {
        fclose(fh);
        return NULL;
    }
    n   = (size_t)*w * *h * 3u;
    rgb = malloc(n);
    if (rgb == NULL || fread(rgb, 1, n, fh) != n) {
        free(rgb);
        fclose(fh);
        return NULL;
    }
    fclose(fh);
    return rgb;
}

int ppm_write(const char *path, const uint8_t *rgb, unsigned w, unsigned h)
{
    FILE  *fh = fopen(path, "wb");
    size_t n  = (size_t)w * h * 3u;

    if (fh == NULL)
        return -1;
    fprintf(fh, "P6\n%u %u\n255\n", w, h);
    if (fwrite(rgb, 1, n, fh) != n) {
        fclose(fh);
        return -1;
    }
    return fclose(fh);
}
