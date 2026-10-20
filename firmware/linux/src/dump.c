/*============================================================================
 *  dump.c  -  write a frame in the format check_camera_frame.py reads
 *==========================================================================*/
#include "dump.h"

#include <stdio.h>

#include "ppm.h"
#include "quant_params.h"

static const char *CLASS_NAME[QP_N_CLASSES] = QP_CLASS_NAMES;

static int write_bin(const char *path, const void *p, size_t n)
{
    FILE *fh = fopen(path, "wb");
    int   bad;

    if (fh == NULL)
        return -1;
    bad = fwrite(p, 1, n, fh) != n;
    return (fclose(fh) || bad) ? -1 : 0;
}

int dump_frame(const char *dir, unsigned n, const char *source,
               const uint8_t *rgb, const camfront_geom_t *g,
               const uint8_t *win, const int8_t *tensor,
               const accel_result_t *r, double accel_ms)
{
    char  base[512], path[600];
    FILE *fh;
    int   bad = 0;

    snprintf(base, sizeof base, "%s/vinecam_%04u", dir, n);

    snprintf(path, sizeof path, "%s_frame.ppm", base);
    bad |= ppm_write(path, rgb, g->src_w, g->src_h);
    snprintf(path, sizeof path, "%s_rgb256.bin", base);
    bad |= write_bin(path, win, CAMFRONT_WIN_BYTES);
    snprintf(path, sizeof path, "%s_input.bin", base);
    bad |= write_bin(path, tensor, ACCEL_IMG_BYTES);

    snprintf(path, sizeof path, "%s.txt", base);
    fh = fopen(path, "w");
    if (fh == NULL)
        return -1;
    fprintf(fh, "vinecam frame dump - check with scripts/check_camera_frame.py\n");
    fprintf(fh, "source   : %s\n", source);
    fprintf(fh, "frame    : %u %u\n", g->src_w, g->src_h);
    fprintf(fh, "resize   : %u %u\n", g->rs_w, g->rs_h);
    fprintf(fh, "crop     : %u %u\n", g->crop_x, g->crop_y);
    fprintf(fh, "window   : %u %u\n", g->win_x, g->win_y);
    if (r != NULL) {
        fprintf(fh, "logits   : %d %d %d %d\n", r->logit[0], r->logit[1],
                r->logit[2], r->logit[3]);
        fprintf(fh, "argmax   : %u = %s\n", r->argmax,
                r->argmax < QP_N_CLASSES ? CLASS_NAME[r->argmax] : "?");
        fprintf(fh, "accel_ms : %.3f\n", accel_ms);
    }
    bad |= fclose(fh);

    if (bad == 0)
        printf("  saved %s_*\n", base);
    else
        fprintf(stderr, "  ERROR: could not write all of %s_*\n", base);
    return bad ? -1 : 0;
}
