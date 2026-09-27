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
 *                   cable that programs the board carries it. It shares that UART
 *                   with the console, so it runs at the CONSOLE's baud rate and
 *                   does NOT raise it on its own - see IMG_UART_BAUD in
 *                   img_src.c for why that matters. ~13 s per frame at the BSP
 *                   default of 115200; ~2.1 s once both ends are set to 921600.
 *                   A tiny framed protocol, below.
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
 *  A source hands over one of TWO formats, and says which:
 *
 *    IMG_FMT_Q8      224 x 224 x 3 int8, HWC interleaved, already quantised with
 *                    export.py's scale. Exactly ACCEL_IMG_BYTES = 150,528 bytes,
 *                    and it goes straight to the accelerator. This is the
 *                    bring-up format: nothing between the PC and the DMA.
 *
 *    IMG_FMT_RGB256  256 x 256 x 3 uint8 RGB, HWC interleaved, 196,608 bytes -
 *                    a decoded image, NOT preprocessed. main.c runs
 *                    preproc_rgb (firmware/src/preproc.c) over it, which crops,
 *                    normalises and quantises bit-exactly. This is the format
 *                    that makes the board do its own front end.
 *
 *  Both are HWC interleaved: byte (y*W + x)*3 + c holds channel c. DD-032
 *  explains why, and it pays twice - the DMA reads one sequential stream, and
 *  preproc_rgb walks both buffers forwards.
 *
 *  RGB256 is the interesting one and it took a measurement to justify. The
 *  torchvision pipeline is Resize(256) -> CenterCrop(224) -> Normalize, and
 *  every image in this dataset is already 256x256 - so Resize is the identity,
 *  the crop is an integer crop, and the C front end reproduces the golden
 *  tensors bit-exactly (firmware/test/test_preproc.c). An image that is NOT
 *  256x256 is refused rather than resampled; see preproc.h.
 *
 *  The buffer a caller passes to img_src_next must therefore be
 *  IMG_SRC_BUF_BYTES, the larger of the two, not ACCEL_IMG_BYTES.
 *
 *  ---- the UART framing ---------------------------------------------------
 *
 *  Deliberately the simplest thing that cannot silently half-transfer:
 *
 *      magic   4 bytes  'I','M','G','1'  (Q8)  or  'I','M','G','2'  (RGB256)
 *      length  4 bytes  little-endian, must match the magic's format exactly
 *      payload length bytes
 *      sum     4 bytes  little-endian sum of every payload byte
 *
 *  The format is in the MAGIC and the length is checked against it, rather than
 *  inferred from the length alone. Two independent statements of the same fact
 *  mean a sender and a receiver that disagree about the format produce a dropped
 *  frame and a message, instead of 196,608 bytes being read as a quantised
 *  tensor - which would be a perfectly plausible image and a wrong class.
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
#include "preproc.h"

typedef enum {
    IMG_SRC_FILE = 0,
    IMG_SRC_UART,
    IMG_SRC_MEM
} img_src_kind_t;

typedef enum {
    IMG_FMT_Q8 = 0,     /* 150,528 B, already quantised - straight to the DMA  */
    IMG_FMT_RGB256      /* 196,608 B, decoded RGB - preproc_rgb must run first */
} img_fmt_t;

/*  One buffer serves both formats, so it is sized for the larger. */
#define IMG_SRC_BUF_BYTES  PREPROC_SRC_BYTES

#define IMG_FMT_BYTES(f)   ((f) == IMG_FMT_RGB256 ? PREPROC_SRC_BYTES                                                   : (size_t)ACCEL_IMG_BYTES)

typedef struct {
    img_src_kind_t kind;
    const char    *path;      /* FILE: the .bin to read                       */
    img_fmt_t      mem_fmt;   /* MEM : what is at `mem` - it has no length to
                               *       infer from, so it must be told         */
    const void    *mem;       /* MEM : where it already is                    */
    unsigned       served;    /* how many images this source has handed over  */
    int            once;      /* FILE/MEM: stop after one, rather than loop    */
    void          *priv;      /* UART: the driver instance                    */
} img_src_t;

/*  Pick a source and get it ready. Returns 0 on success. */
int  img_src_open(img_src_t *s);

/*  Fill buf with the next image and say which format it is in. Returns the byte
 *  count, or -1 when the source is finished (a single file already served, or the
 *  UART closed). len must be IMG_SRC_BUF_BYTES.
 *
 *  A source that cannot supply a whole frame returns -1 rather than a short one,
 *  because a short image is a wrong answer and not an error the hardware can
 *  see. `fmt` is always written when the return value is positive. */
int  img_src_next(img_src_t *s, void *buf, size_t len, img_fmt_t *fmt);

void img_src_close(img_src_t *s);

const char *img_src_name(const img_src_t *s);

#endif /* IMG_SRC_H */
