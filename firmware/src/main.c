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
 *  ---- preprocessing, and what is still outside the check ----------------
 *
 *  A source may hand over either format, and says which:
 *
 *      IMG_FMT_Q8      224x224x3 int8, already quantised. Straight to the DMA.
 *      IMG_FMT_RGB256  256x256x3 uint8 RGB, decoded but not preprocessed.
 *                      preproc_rgb crops, normalises and quantises it here.
 *
 *  firmware/src/preproc.c does that front end bit-exactly, and
 *  firmware/test/test_preproc.c proves it: the C code reproduces a tracked
 *  golden set's 000_input.hex exactly, all 150,528 values, from the decoded
 *  source JPEG. Since 000_input.hex is where accel_axi_tb.sv's 6,895,780-element
 *  check STARTS, the two halves now join: RGB in, the golden tensor, 6.9 M
 *  elements bit-exact, the argmax.
 *
 *  What is still outside any check is the JPEG DECODE, which stays on the PC.
 *  libjpeg's IDCT is not bit-defined, so two decoders may legitimately differ in
 *  the last bit, and there is nothing to be exact against. Naming it is the
 *  point: it is one clearly-bounded step, outside the embedded path rather than
 *  hidden inside it.
 *
 *  An image that is not 256x256 is REFUSED rather than resampled - see preproc.h
 *  for why (no resampler here is verified against Pillow's antialiased one).
 *==========================================================================*/
#include <stdio.h>
#include <string.h>

#include "accel_drv.h"
#include "img_src.h"
#include "preproc.h"

#include "ff.h"              /* xilffs */
#include "xil_cache.h"
#include "xparameters.h"

/*  Where the CSR lives. scripts/make_bd.tcl places it here and writes the
 *  address map to build/bd_<cfg>/address_map.rpt; XPAR_* from the BSP is the
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

/*  What a source delivers, before any preprocessing. Sized for the larger of the
 *  two formats, so one buffer serves both.
 *
 *  Kept separate from `image` rather than preprocessing in place. In-place would
 *  in fact be safe - the read pointer runs at least 12,336 bytes ahead of the
 *  write pointer for every row - but it costs 192 KB of a 2 GB DDR to not have to
 *  rely on that, and `image` is the buffer the DMA reads and the one that gets
 *  flushed, so keeping it holding only finished data is worth more than the
 *  space. */
static uint8_t  frame[IMG_SRC_BUF_BYTES] __attribute__((aligned(ACCEL_ALIGN)));
static uint32_t program[ACCEL_PROG_WORDS];

/*  From quant_params.h, which scripts/gen_program.py generates from
 *  manifest.json - so the label printed here cannot drift from the class order
 *  the model was trained with. That ordering is not a detail: getting it wrong
 *  renames every prediction and changes no number anywhere. */
static const char *CLASS_NAME[QP_N_CLASSES] = QP_CLASS_NAMES;

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
           (r->argmax < QP_N_CLASSES) ? CLASS_NAME[r->argmax] : "?");
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

    /*  768 operations, and the only check that can catch a target runtime whose
     *  FPU rounds differently from the machine the goldens were made on. A host
     *  test cannot: the host is in round-to-nearest. Truncation instead of
     *  rounding would shift much of the input tensor by one step and report
     *  nothing, so this runs before anything else can depend on it. */
    {
        preproc_status_t ps = preproc_self_test();
        if (ps != PREPROC_OK) {
            printf("  ERROR: preprocessing self-test failed: %s\n",
                   preproc_strerror(ps));
            return 1;
        }
    }
    printf("  preprocessing self-test passed (768 table entries, "
           "round-to-nearest)\n");

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
        img_fmt_t fmt;
        int got = img_src_next(&src, frame, sizeof frame, &fmt);
        if (got < 0) {
            printf("image source closed after %u inference(s)\n", n);
            break;
        }

        if (fmt == IMG_FMT_RGB256) {
            /*  The board's own front end: crop, normalise, quantise. Verified
             *  bit-exact against the golden tensor by
             *  firmware/test/test_preproc.c. */
            preproc_status_t ps = preproc_rgb(frame, QP_SRC_SIZE, QP_SRC_SIZE,
                                              (size_t)got,
                                              (int8_t *)image, sizeof image);
            if (ps != PREPROC_OK) {
                printf("  ERROR preprocessing: %s\n", preproc_strerror(ps));
                continue;
            }
        } else {
            /*  Already quantised - straight through. */
            memcpy(image, frame, sizeof image);
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
