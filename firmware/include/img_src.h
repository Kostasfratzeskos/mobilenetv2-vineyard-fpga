/*============================================================================
 *  img_src.h  -  where the image comes from
 *
 *  One interface, three implementations, because the practical answer depends on
 *  what is plugged in and there is no reason for the application to care:
 *
 *    IMG_SRC_FILE   a .bin on the SD card. Needs no PC, and is how a standalone
 *                   demo runs. One file per inference, or one file replayed.
 *
 *    IMG_SRC_UART   streamed from the PC over the ZCU104's USB-UART bridge. The
 *                   practical one for trying different leaves: the SAME USB
 *                   cable that programs the board carries it, and 150,528 bytes
 *                   at 921600 baud is about 1.6 s. A tiny framed protocol, below.
 *
 *    IMG_SRC_MEM    already in DDR. Put there over JTAG with xsct's `mwr`, or by
 *                   a bootloader, or by a previous run. Zero protocol code and
 *                   nothing to get wrong, which makes it the right one for the
 *                   first bring-up: if this works and UART does not, the problem
 *                   is the UART and not the accelerator.
 *
 *  Which one is compiled in is an -D at build time; which one is USED can also be
 *  decided at run time by img_src_open, so a single binary can fall back from
 *  UART to SD. See README.md.
 *
 *  ---- the image format, in every case -----------------------------------
 *
 *  224 x 224 x 3 int8, HWC INTERLEAVED: byte (y*224 + x)*3 + c holds channel c.
 *  Exactly ACCEL_IMG_BYTES = 150,528 bytes, and the driver refuses anything
 *  else because the length is structural in the hardware (DD-032) and so cannot
 *  be checked there.
 *
 *  Already quantised, with the same input scale export.py used. This layer does
 *  NOT preprocess - see the note at the top of main.c about that gap and why it
 *  matters for the project's verification story.
 *
 *  ---- the UART framing ---------------------------------------------------
 *
 *  Deliberately the simplest thing that cannot silently half-transfer:
 *
 *      magic   4 bytes  'I','M','G','1'
 *      length  4 bytes  little-endian, must equal ACCEL_IMG_BYTES
 *      payload length bytes
 *      sum     4 bytes  little-endian sum of every payload byte
 *
 *  The checksum is there because a dropped byte on a serial line shifts every
 *  channel afterwards by one, which produces a plausible image and a confident
 *  wrong classification - the same failure shape this project keeps finding in
 *  other places. A mismatch is reported and the frame is dropped.
 *
 *  scripts/send_image.py is the PC side.
 *==========================================================================*/
#ifndef IMG_SRC_H
#define IMG_SRC_H

#include <stddef.h>
#include <stdint.h>

#include "accel_csr.h"

typedef enum {
    IMG_SRC_FILE = 0,
    IMG_SRC_UART,
    IMG_SRC_MEM
} img_src_kind_t;

typedef struct {
    img_src_kind_t kind;
    const char    *path;      /* FILE: the .bin to read                       */
    const void    *mem;       /* MEM : where it already is                    */
    unsigned       served;    /* how many images this source has handed over  */
    int            once;      /* FILE/MEM: stop after one, rather than loop    */
    void          *priv;      /* UART: the driver instance                    */
} img_src_t;

/*  Pick a source and get it ready. Returns 0 on success. */
int  img_src_open(img_src_t *s);

/*  Fill buf with the next image. Returns the byte count, or -1 when the source
 *  is finished (a single file already served, or the UART closed). len must be
 *  ACCEL_IMG_BYTES; a source that cannot supply exactly that returns -1 rather
 *  than a short image, because a short image is a wrong answer and not an error
 *  the hardware can see. */
int  img_src_next(img_src_t *s, void *buf, size_t len);

void img_src_close(img_src_t *s);

const char *img_src_name(const img_src_t *s);

#endif /* IMG_SRC_H */
