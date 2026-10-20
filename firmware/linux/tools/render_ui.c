/*============================================================================
 *  render_ui.c  -  the board's demo screen, rendered on a PC from a photograph
 *
 *      render_ui FRAME.ppm OUT.ppm [--size WxH] [--logits a,b,c,d]
 *                                  [--accel-ms X] [--fps Y] [--frozen]
 *                                  [--dump DIR]
 *
 *  Runs the photograph through exactly the code the board runs - the
 *  Resize(256) window (camfront.c) and the bit-exact crop and quantise
 *  (preproc.c) - and draws the screen (ui.c) the way vinecam would, with the
 *  logits given on the command line, since there is no accelerator here.
 *
 *  Two uses:
 *
 *    * to look at the screen before there is a board, at the monitor's
 *      resolution, and decide whether it reads from the back of the room
 *    * with --dump, to write the frame in the board's dump format WITHOUT
 *      logits, so scripts/check_camera_frame.py can check the C front end on
 *      a real photograph rather than on test patterns:
 *
 *        python scripts/check_camera_frame.py DIR/vinecam_0000
 *
 *  Build: cd firmware/linux && make tools
 *==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "camfront.h"
#include "canvas.h"
#include "dump.h"
#include "ppm.h"
#include "preproc.h"
#include "ui.h"

int main(int argc, char **argv)
{
    unsigned   w, h, cw = 1920, ch = 1080, i;
    uint8_t   *rgb, *win;
    static int8_t tensor[PREPROC_OUT_BYTES];
    camfront_t cf;
    canvas_t   cv;
    ui_state_t st;
    const char *dump = NULL;
    int        a;

    if (argc < 3) {
        fprintf(stderr, "usage: render_ui FRAME.ppm OUT.ppm [--size WxH] "
                "[--logits a,b,c,d] [--accel-ms X] [--fps Y] [--frozen] [--dump DIR]\n");
        return 1;
    }

    memset(&st, 0, sizeof st);
    st.source = "RENDERED ON A PC - NO ACCELERATOR";
    for (a = 3; a < argc; a++) {
        if (!strcmp(argv[a], "--size") && a + 1 < argc) {
            if (sscanf(argv[++a], "%ux%u", &cw, &ch) != 2)
                return 1;
        } else if (!strcmp(argv[a], "--logits") && a + 1 < argc) {
            int l[4];
            if (sscanf(argv[++a], "%d,%d,%d,%d", &l[0], &l[1], &l[2], &l[3]) != 4)
                return 1;
            for (i = 0; i < 4; i++)
                st.logit[i] = (int16_t)l[i];
            st.argmax = 0;
            for (i = 1; i < 4; i++)
                if (st.logit[i] > st.logit[st.argmax])
                    st.argmax = i;
            st.have_result = 1;
        } else if (!strcmp(argv[a], "--accel-ms") && a + 1 < argc) {
            st.accel_ms = atof(argv[++a]);
        } else if (!strcmp(argv[a], "--fps") && a + 1 < argc) {
            st.fps = atof(argv[++a]);
        } else if (!strcmp(argv[a], "--frozen")) {
            st.frozen = 1;
        } else if (!strcmp(argv[a], "--dump") && a + 1 < argc) {
            dump = argv[++a];
        } else {
            fprintf(stderr, "unknown option %s\n", argv[a]);
            return 1;
        }
    }

    rgb = ppm_read(argv[1], &w, &h);
    if (rgb == NULL) {
        fprintf(stderr, "%s: not a binary (P6) PPM\n", argv[1]);
        return 1;
    }
    if (camfront_init(&cf, w, h)) {
        fprintf(stderr, "%ux%u cannot be resized\n", w, h);
        return 1;
    }
    win = malloc(CAMFRONT_WIN_BYTES);
    camfront_window(&cf, rgb, (size_t)w * 3u, win);
    if (preproc_rgb(win, CAMFRONT_WIN, CAMFRONT_WIN, CAMFRONT_WIN_BYTES,
                    tensor, sizeof tensor) != PREPROC_OK) {
        fprintf(stderr, "preproc_rgb refused the window\n");
        return 1;
    }
    printf("%ux%u -> Resize(256) %ux%u -> CenterCrop(224) at (%u,%u), window (%u,%u)\n",
           w, h, cf.g.rs_w, cf.g.rs_h, cf.g.crop_x, cf.g.crop_y, cf.g.win_x, cf.g.win_y);

    if (dump && dump_frame(dump, 0, argv[1], rgb, &cf.g, win, tensor, NULL, 0.0))
        return 1;

    st.frame = rgb;
    st.fw    = w;
    st.fh    = h;
    camfront_crop_rect(&cf.g, st.crop);
    if (canvas_init(&cv, cw, ch))
        return 1;
    ui_render(&cv, &st);
    if (canvas_write_ppm(&cv, argv[2])) {
        fprintf(stderr, "cannot write %s\n", argv[2]);
        return 1;
    }
    printf("wrote %s (%ux%u)\n", argv[2], cw, ch);

    canvas_free(&cv);
    camfront_free(&cf);
    free(win);
    free(rgb);
    return 0;
}
