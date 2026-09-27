/*============================================================================
 *  main.c  -  the PS application: one image in, a disease class out
 *
 *  Not built by firmware/Makefile - it needs a standalone BSP with xilffs. See
 *  README.md. The part of this file worth reviewing is the SEQUENCE, and that
 *  sequence is verified: firmware/test/test_drv_seq.c drives the same driver
 *  calls in the same order against a mock of the CSR's guards, and
 *  hardware/tb/accel_axi_tb.sv drives the same register sequence against the
 *  actual RTL and gets 6,895,780 elements bit-exact.
 *
 *  ---- what it does -------------------------------------------------------
 *
 *      1. mount the SD card
 *      2. read the four static blobs into DDR              (2.26 MB, once)
 *      3. read the 512-word program into DDR
 *      4. check the accelerator's ID, load the program, point it at the blobs
 *      5. for each image: get it, hand it over, run, print the class
 *
 *  Step 5 is a loop on purpose. The blobs and the program are loaded ONCE; only
 *  the image changes per inference, which is what makes a 1.6-second UART
 *  transfer per image reasonable and a 2.26 MB reload per image not.
 *
 *  ---- where the image comes from ----------------------------------------
 *
 *  Behind img_src (firmware/include/img_src.h), with three implementations:
 *
 *      IMG_SRC_FILE    a .bin on the SD card. Needs no PC.
 *      IMG_SRC_UART    streamed from the PC over the USB-UART bridge. This is
 *                      the practical one for trying different leaves: the same
 *                      USB cable that programs the board carries it, and
 *                      150,528 bytes at 921600 baud is about 1.6 s.
 *      IMG_SRC_MEM     already in DDR - put there over JTAG with xsct's mwr, or
 *                      by a previous stage. Zero protocol code, good for bring-up.
 *
 *  The image must be HWC interleaved: byte (y*224 + x)*3 + c holds channel c.
 *  DD-032 explains why that layout and not channel-planar; the short version is
 *  that it makes the DMA one sequential read AND it is what a decoder produces.
 *
 *  ---- what this file does NOT do yet ------------------------------------
 *
 *  It does not PREPROCESS. It expects an image that is already 224x224x3 int8,
 *  quantised with the same scale export.py used. Decoding a JPEG, resizing,
 *  centre-cropping, normalising by the ImageNet mean/std and quantising is a
 *  separate piece of work, and a bigger one than this file - `predict.py` does
 *  it with torchvision and nothing in C does it at all yet.
 *
 *  That gap is worth stating plainly because it is also a gap in the project's
 *  verification: "6,895,780 elements bit-exact" is measured from
 *  software/golden/*/000_input.hex onward, i.e. from the quantised tensor. The
 *  resize and the quantisation in front of it are not covered by any check in
 *  this repository. Preprocessing has to be written AND verified against
 *  torchvision before an end-to-end claim means anything.
 *==========================================================================*/
#include <stdio.h>
#include <string.h>

#include "accel_drv.h"
#include "img_src.h"

#include "ff.h"              /* xilffs */
#include "xil_cache.h"
#include "xparameters.h"

/*  Where the CSR lives. scripts/make_bd.tcl places it here and writes the
 *  address map to build/bd_*/address_map.rpt; XPAR_* from the BSP is the same
 *  number, and using it means a change in the block design reaches this file
 *  through the BSP rather than by someone remembering to edit a literal. */
#ifdef XPAR_ACCEL_AXI_0_BASEADDR
#define CSR_BASE  XPAR_ACCEL_AXI_0_BASEADDR
#else
#define CSR_BASE  0xA0000000u
#endif

/* ---- the DDR buffers ----------------------------------------------------
 *  Statically placed and cache-line aligned. Aligned because accel_set_blobs
 *  refuses anything else, and it refuses because a cache flush works on whole
 *  lines - a buffer sharing its first or last line with another object cannot be
 *  flushed without either missing part of itself or writing back its neighbour.
 *
 *  Sizes come from the generator, not from here: scripts/gen_program.py prints
 *  them, and a mismatch is caught by accel_set_blobs rather than assumed. */
#define WGT_BYTES   2194880u
#define PARAM_CH    19264u
#define PB_BYTES    (PARAM_CH * 4u)
#define PM_BYTES    (PARAM_CH * 4u)
#define PS_BYTES    (PARAM_CH * 1u)

static uint8_t  blob_wgt[WGT_BYTES]  __attribute__((aligned(ACCEL_ALIGN)));
static uint8_t  blob_pb[PB_BYTES]    __attribute__((aligned(ACCEL_ALIGN)));
static uint8_t  blob_pm[PM_BYTES]    __attribute__((aligned(ACCEL_ALIGN)));
static uint8_t  blob_ps[PS_BYTES]    __attribute__((aligned(ACCEL_ALIGN)));
static uint8_t  image[ACCEL_IMG_BYTES] __attribute__((aligned(ACCEL_ALIGN)));
static uint32_t program[ACCEL_PROG_WORDS];

static const char *CLASS_NAME[ACCEL_N_CLASSES] = {
    "Black Rot", "ESCA", "Healthy", "Leaf Blight"
};

static FATFS fs;

/*  Read a whole file, and insist on its length. A short read here would
 *  otherwise become a partially-loaded blob, which the accelerator cannot
 *  detect - it would just compute with whatever the tail of the buffer held. */
static int read_exact(const char *path, void *dst, size_t want)
{
    FIL f;
    UINT got = 0;

    if (f_open(&f, path, FA_READ) != FR_OK) {
        printf("  ERROR: cannot open %s\n", path);
        return -1;
    }
    if (f_read(&f, dst, (UINT)want, &got) != FR_OK || got != want) {
        printf("  ERROR: %s is %u bytes, expected %u\n",
               path, (unsigned)got, (unsigned)want);
        f_close(&f);
        return -1;
    }
    f_close(&f);
    printf("  loaded %-20s %8u bytes\n", path, (unsigned)want);
    return 0;
}

static int load_blobs(void)
{
    /*  program.bin is little-endian uint32 per word, which is what the aperture
     *  takes and what an ARM load of a uint32 array gives - so this is a plain
     *  read with no byte swapping. gen_program.py's emit_bins says the same. */
    if (read_exact("program.bin",      program,  sizeof program))  return -1;
    if (read_exact("weights.bin",      blob_wgt, sizeof blob_wgt)) return -1;
    if (read_exact("params_b.bin",     blob_pb,  sizeof blob_pb))  return -1;
    if (read_exact("params_m0.bin",    blob_pm,  sizeof blob_pm))  return -1;
    if (read_exact("params_shift.bin", blob_ps,  sizeof blob_ps))  return -1;
    return 0;
}

static void report(const accel_result_t *r, uint32_t cycles_unknown)
{
    int i;
    (void)cycles_unknown;

    printf("  logits:");
    for (i = 0; i < (int)ACCEL_N_CLASSES; i++)
        printf(" %6d", r->logit[i]);
    printf("\n  class : %u = %s\n", r->argmax,
           (r->argmax < ACCEL_N_CLASSES) ? CLASS_NAME[r->argmax] : "?");
}

int main(void)
{
    accel_t        acc;
    accel_result_t res;
    accel_status_t s;
    img_src_t      src;
    unsigned       n = 0;

    /*  The caches are on and they are the reason accel_plat_flush exists. Not
     *  disabling them: 2.26 MB of blob loading and the image copy would crawl,
     *  and a flush in the one place it is needed is cheaper than losing the
     *  cache everywhere else. */
    Xil_DCacheEnable();

    printf("\n");
    printf("MobileNetV2 grape-leaf classifier - PS application\n");
    printf("  CSR at 0x%08x\n", (unsigned)CSR_BASE);

    if (f_mount(&fs, "0:/", 1) != FR_OK) {
        printf("  ERROR: cannot mount the SD card\n");
        return 1;
    }
    if (load_blobs())
        return 1;

    /*  The ID check first, because everything else fails confusingly if the PL
     *  is not programmed: reads come back as zeros and it looks like a broken
     *  accelerator rather than a missing bitstream. */
    s = accel_init(&acc, CSR_BASE);
    if (s != ACCEL_OK) {
        printf("  ERROR: %s\n", accel_strerror(s));
        return 1;
    }
    printf("  accelerator alive (ID reads VINE)\n");

    /*  Once per boot. 64 instructions, 512 words. */
    s = accel_load_program(&acc, program, ACCEL_PROG_WORDS, 64);
    if (s != ACCEL_OK) { printf("  ERROR: %s\n", accel_strerror(s)); return 1; }

    s = accel_set_blobs(&acc,
                        blob_wgt, sizeof blob_wgt,
                        blob_pb,  sizeof blob_pb,
                        blob_pm,  sizeof blob_pm,
                        blob_ps,  sizeof blob_ps);
    if (s != ACCEL_OK) { printf("  ERROR: %s\n", accel_strerror(s)); return 1; }
    printf("  program and blobs in DDR, flushed, bases written\n");

    if (img_src_open(&src) != 0) {
        printf("  ERROR: no image source\n");
        return 1;
    }
    printf("  image source: %s\n", img_src_name(&src));
    printf("\n");

    /*  One iteration per image. Only the image changes; the blobs stay. */
    for (;;) {
        int got = img_src_next(&src, image, sizeof image);
        if (got < 0) {
            printf("image source closed after %u inference(s)\n", n);
            break;
        }

        s = accel_load_image(&acc, image, sizeof image);
        if (s != ACCEL_OK) {
            printf("  ERROR loading the image: %s (STATUS 0x%08x)\n",
                   accel_strerror(s), (unsigned)acc.last_status);
            continue;
        }

        s = accel_run(&acc);
        if (s != ACCEL_OK) {
            printf("  ERROR running: %s (STATUS 0x%08x)\n",
                   accel_strerror(s), (unsigned)acc.last_status);
            continue;
        }

        s = accel_result(&acc, &res);
        if (s != ACCEL_OK) {
            printf("  ERROR reading the result: %s\n", accel_strerror(s));
            continue;
        }

        printf("inference %u:\n", n++);
        report(&res, 0);
        printf("\n");
    }

    img_src_close(&src);
    f_mount(NULL, "0:/", 1);
    return 0;
}
