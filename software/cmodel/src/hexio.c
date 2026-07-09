#include "hexio.h"

#include <stdio.h>
#include <stdlib.h>

long hex_count(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long n = 0;
    char line[64];
    while (fgets(line, sizeof line, f)) {
        /* count only lines that carry a hex digit */
        for (char *p = line; *p; p++)
            if ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')) { n++; break; }
    }
    fclose(f);
    return n;
}

/* read up to n values via strtoul (base 16, two's complement) */
static int hex_read_u32(const char *path, uint32_t *dst, int n) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "hexio: cannot open %s\n", path); return -1; }
    int i = 0;
    char line[64];
    while (i < n && fgets(line, sizeof line, f)) {
        char *end = NULL;
        unsigned long v = strtoul(line, &end, 16);
        if (end == line) continue;              /* blank line */
        dst[i++] = (uint32_t)v;
    }
    fclose(f);
    if (i != n) { fprintf(stderr, "hexio: %s: got %d values, expected %d\n", path, i, n); return -1; }
    return n;
}

int hex_read_i8(const char *path, int8_t *dst, int n) {
    uint32_t *tmp = malloc((size_t)n * sizeof *tmp);
    if (!tmp) return -1;
    int r = hex_read_u32(path, tmp, n);
    if (r == n) for (int i = 0; i < n; i++) dst[i] = (int8_t)(uint8_t)tmp[i];
    free(tmp);
    return r;
}

int hex_read_i16(const char *path, int16_t *dst, int n) {
    uint32_t *tmp = malloc((size_t)n * sizeof *tmp);
    if (!tmp) return -1;
    int r = hex_read_u32(path, tmp, n);
    if (r == n) for (int i = 0; i < n; i++) dst[i] = (int16_t)(uint16_t)tmp[i];
    free(tmp);
    return r;
}

int hex_read_i32(const char *path, int32_t *dst, int n) {
    uint32_t *tmp = malloc((size_t)n * sizeof *tmp);
    if (!tmp) return -1;
    int r = hex_read_u32(path, tmp, n);
    if (r == n) for (int i = 0; i < n; i++) dst[i] = (int32_t)tmp[i];
    free(tmp);
    return r;
}

int hex_write_i8(const char *path, const int8_t *src, int n) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "hexio: cannot write %s\n", path); return -1; }
    for (int i = 0; i < n; i++) fprintf(f, "%02x\n", (uint8_t)src[i]);
    fclose(f);
    return n;
}

int hex_write_i16(const char *path, const int16_t *src, int n) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "hexio: cannot write %s\n", path); return -1; }
    for (int i = 0; i < n; i++) fprintf(f, "%04x\n", (uint16_t)src[i]);
    fclose(f);
    return n;
}

int hex_write_i32(const char *path, const int32_t *src, int n) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "hexio: cannot write %s\n", path); return -1; }
    for (int i = 0; i < n; i++) fprintf(f, "%08x\n", (uint32_t)src[i]);
    fclose(f);
    return n;
}

void nchw_to_nhwc_i8(const int8_t *nchw, int8_t *nhwc, int C, int H, int W) {
    for (int c = 0; c < C; c++)
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                nhwc[(y * W + x) * C + c] = nchw[(c * H + y) * W + x];
}

void nhwc_to_nchw_i8(const int8_t *nhwc, int8_t *nchw, int C, int H, int W) {
    for (int c = 0; c < C; c++)
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                nchw[(c * H + y) * W + x] = nhwc[(y * W + x) * C + c];
}

int hex_read_activation_nhwc(const char *path, int8_t *nhwc, int C, int H, int W) {
    int n = C * H * W;
    int8_t *nchw = malloc((size_t)n);
    if (!nchw) return -1;
    int r = hex_read_i8(path, nchw, n);
    if (r == n) nchw_to_nhwc_i8(nchw, nhwc, C, H, W);
    free(nchw);
    return r;
}

int hex_write_activation_nchw(const char *path, const int8_t *nhwc, int C, int H, int W) {
    int n = C * H * W;
    int8_t *nchw = malloc((size_t)n);
    if (!nchw) return -1;
    nhwc_to_nchw_i8(nhwc, nchw, C, H, W);
    int r = hex_write_i8(path, nchw, n);
    free(nchw);
    return r;
}
