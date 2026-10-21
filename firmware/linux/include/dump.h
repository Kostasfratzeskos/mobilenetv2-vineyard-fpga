/*============================================================================
 *  dump.h  -  a frame saved for scripts/check_camera_frame.py
 *
 *  Four files per frame, <dir>/vinecam_<n>_*:
 *
 *      _frame.ppm     the picture as the board had it: AFTER the YUV
 *                     conversion, so the one step outside the bit-exact chain
 *                     is already behind it, and the PC starts from the same RGB
 *      _rgb256.bin    the 256x256 window camfront_window produced
 *      _input.bin     the 150,528-byte int8 tensor that went to the DMA
 *      .txt           geometry, and - from the board - the four logits
 *
 *  The PC re-derives the window and the tensor with torchvision, and the
 *  logits with the integer reference model, from _frame.ppm alone, and must
 *  get every byte the board got. Shared by vinecam (the board) and
 *  tools/render_ui (a PC), so both write exactly the same format.
 *==========================================================================*/
#ifndef DUMP_H
#define DUMP_H

#include "accel_drv.h"
#include "camfront.h"

/*  `r` may be NULL (no accelerator: tools/render_ui). 0 on success. */
int dump_frame(const char *dir, unsigned n, const char *source,
               const uint8_t *rgb, const camfront_geom_t *g,
               const uint8_t *win, const int8_t *tensor,
               const accel_result_t *r, double accel_ms);

#endif /* DUMP_H */
