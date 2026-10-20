/*============================================================================
 *  ppm.h  -  binary PPM (P6), the one image file format needing no library
 *
 *  Used three ways: `vinecam --image leaf.ppm` classifies a still of any size
 *  through the same front end as the camera; a dumped camera frame is written
 *  as one, so scripts/check_camera_frame.py can run torchvision on exactly the
 *  RGB the board used; and tools/render_ui.c reads one to draw the screen on a
 *  PC. Pillow reads and writes P6 natively, so nothing on the PC side needs a
 *  decoder either.
 *==========================================================================*/
#ifndef PPM_H
#define PPM_H

#include <stddef.h>
#include <stdint.h>

/*  RGB888, HWC, malloc'd - or NULL. Only maxval 255 is accepted. */
uint8_t *ppm_read(const char *path, unsigned *w, unsigned *h);

/*  0 on success. */
int      ppm_write(const char *path, const uint8_t *rgb, unsigned w, unsigned h);

#endif /* PPM_H */
