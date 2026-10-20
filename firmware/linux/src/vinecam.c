/*============================================================================
 *  vinecam.c  -  live grape-leaf classification on the ZCU104, under Linux
 *
 *      USB webcam -> YUYV -> RGB -> Resize(256) window -> preproc_rgb
 *                 -> the DMA region -> accelerator -> class -> screen
 *
 *  The baremetal application (firmware/src/main.c) classifies files; this one
 *  classifies whatever is in front of a USB camera, because a webcam needs a
 *  USB host stack and a UVC driver, and those come with Linux. Everything the
 *  accelerator sees still goes through the same verified pieces:
 *
 *      accel_drv.c   the same driver, with plat_linux.c's five hooks instead
 *                    of plat_zynq.c's - test_drv_seq covers both
 *      preproc.c     the same bit-exact crop and quantise (DD-033)
 *      camfront.c    NEW: torchvision's Resize(256), bit-exact against Pillow
 *                    on fifteen frame sizes (test_camfront)
 *
 *  ---- three ways to run it, in the order to try them on a new board ------
 *
 *  1. A known answer, no camera:
 *
 *       vinecam --image image_rgb.bin --expect EXPECTED.txt
 *
 *     The SD card's golden images (scripts/make_sdcard.py). The four logits
 *     must equal EXPECTED.txt's - the numbers the RTL produced in simulation.
 *     This is the Linux port's whole check: UIO, the DMA region, the address
 *     translation, the ordering barrier. If this passes and the camera path
 *     misbehaves, the problem is in front of the accelerator, not in it.
 *
 *  2. A still photo of any size, through the camera's front end:
 *
 *       vinecam --image leaf.ppm --dump-dir /tmp
 *
 *  3. Live:
 *
 *       vinecam                       camera, DisplayPort monitor
 *       vinecam --http 8080           ... and in a browser on the laptop
 *       vinecam --no-display          camera, results on the console only
 *
 *     Keys on the console: SPACE freezes the picture (and the answer) while
 *     you talk about it, S saves the current frame for checking on the PC,
 *     Q quits.
 *
 *  ---- what a saved frame is for ----------------------------------------
 *
 *  'S' writes the frame as the board saw it (after the YUV conversion, so the
 *  one step outside the bit-exact chain is already behind it), the 256x256
 *  window, the int8 tensor that went to the DMA, and the logits. On the PC,
 *
 *       python scripts/check_camera_frame.py <dump>
 *
 *  re-runs torchvision and the integer reference model on that frame and must
 *  get the same window, the same tensor and the same four logits. That turns
 *  "it looked right during the demo" into a statement about specific frames.
 *==========================================================================*/
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "accel_drv.h"
#include "camfront.h"
#include "canvas.h"
#include "dmaregion.h"
#include "dump.h"
#include "fbdev.h"
#include "httpview.h"
#include "plat_linux.h"
#include "ppm.h"
#include "preproc.h"
#include "quant_params.h"
#include "ui.h"
#include "v4l2cam.h"
#include "vine_uio.h"

/* ---- the blobs: the same sizes firmware/src/main.c loads ----------------
 *  From scripts/gen_program.py, which prints them. A file of any other length
 *  is refused: a short read would be a partly-loaded blob, which the
 *  accelerator cannot detect - it would compute with whatever the rest of the
 *  buffer held. */
#define PROG_BYTES  (ACCEL_PROG_WORDS * 4u)
#define WGT_BYTES   2194880u
#define PARAM_CH    19264u
#define PB_BYTES    (PARAM_CH * 4u)
#define PM_BYTES    (PARAM_CH * 4u)
#define PS_BYTES    (PARAM_CH * 1u)
#define N_INSTR     64u                 /* 64 instructions, 512 words      */

/*  Polls of STATUS before the driver gives up. Each poll is an uncached read
 *  across M_AXI_HPM0_FPD, a few hundred nanoseconds; the run is ~1.15 M PL
 *  cycles, ~6 ms. The driver's default of 200,000 polls leaves too little
 *  margin for a DDR shared with a camera and a display, so this allows
 *  seconds: a dead PL then costs a few seconds, not forever. */
#define POLL_LIMIT_LINUX 20000000u

static const char *CLASS_NAME[QP_N_CLASSES] = QP_CLASS_NAMES;

static volatile sig_atomic_t g_stop;

static void on_signal(int s)
{
    (void)s;
    g_stop = 1;
}

static double now_ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

/* ======================================================================
 *  options
 * ====================================================================== */
typedef struct {
    char        blobs[PATH_MAX];
    const char *image, *expect, *video, *fbdev, *dump_dir, *uio;
    unsigned    cam_w, cam_h, repeat, frames;
    int         list, no_display, http_port, restore, dump_given;
} opts_t;

static void usage(void)
{
    printf(
"vinecam - grape-leaf disease classification on the ZCU104's accelerator\n"
"\n"
"  vinecam [options]                 live: USB camera -> FPGA -> screen\n"
"  vinecam --image FILE [--expect EXPECTED.txt] [--repeat N]\n"
"\n"
"  -i, --image FILE      classify one file and exit: image_q8.bin (150,528 B),\n"
"                        image_rgb.bin (196,608 B, 256x256 RGB) or a .ppm of any\n"
"                        size, which goes through the camera's front end\n"
"  -e, --expect FILE     with --image: compare against EXPECTED.txt; exit 2 if\n"
"                        the four logits differ\n"
"  -r, --repeat N        with --image: run N times and report the timing\n"
"  -d, --device DEV      the camera (default /dev/video0)\n"
"  -s, --size WxH        the capture size to ask for (default 640x480)\n"
"  -l, --list            list what the camera offers, and exit\n"
"  -f, --fb DEV          the framebuffer (default /dev/fb0)\n"
"  -n, --no-display      no monitor: results on the console only\n"
"  -p, --http PORT       also serve the screen to a browser on PORT\n"
"  -o, --dump-dir DIR    where S saves frames (default: the current directory)\n"
"  -N, --frames N        stop after N frames (for timing runs)\n"
"  -b, --blobs DIR       program.bin, weights.bin, params_*.bin (default: the\n"
"                        directory this program is in)\n"
"  -u, --uio NAME        the UIO device's name (default " VINE_UIO_NAME ")\n"
"      --restore-console put the text console back after a crash, and exit\n"
"\n"
"  keys, live: SPACE freeze/unfreeze   S save the frame   Q quit\n");
}

static int parse_opts(int argc, char **argv, opts_t *o)
{
    static const struct option L[] = {
        { "image", 1, 0, 'i' }, { "expect", 1, 0, 'e' }, { "repeat", 1, 0, 'r' },
        { "device", 1, 0, 'd' }, { "size", 1, 0, 's' }, { "list", 0, 0, 'l' },
        { "fb", 1, 0, 'f' }, { "no-display", 0, 0, 'n' }, { "http", 1, 0, 'p' },
        { "dump-dir", 1, 0, 'o' }, { "frames", 1, 0, 'N' }, { "blobs", 1, 0, 'b' },
        { "uio", 1, 0, 'u' }, { "restore-console", 0, 0, 'R' },
        { "help", 0, 0, 'h' }, { 0, 0, 0, 0 }
    };
    int     c;
    ssize_t n;

    memset(o, 0, sizeof *o);
    o->video    = "/dev/video0";
    o->fbdev    = "/dev/fb0";
    o->dump_dir = ".";
    o->uio      = VINE_UIO_NAME;
    o->cam_w    = 640;
    o->cam_h    = 480;
    o->repeat   = 1;

    /*  The blobs default to wherever this program is, so copying vinecam and
     *  the SD card's blobs into one directory is all the setup there is. */
    n = readlink("/proc/self/exe", o->blobs, sizeof o->blobs - 1u);
    if (n > 0) {
        char *slash;
        o->blobs[n] = '\0';
        slash = strrchr(o->blobs, '/');
        if (slash)
            *slash = '\0';
    } else {
        strcpy(o->blobs, ".");
    }

    while ((c = getopt_long(argc, argv, "i:e:r:d:s:lf:np:o:N:b:u:h", L, NULL)) != -1) {
        switch (c) {
        case 'i': o->image = optarg; break;
        case 'e': o->expect = optarg; break;
        case 'r': o->repeat = (unsigned)atoi(optarg); break;
        case 'd': o->video = optarg; break;
        case 's':
            if (sscanf(optarg, "%ux%u", &o->cam_w, &o->cam_h) != 2) {
                fprintf(stderr, "--size wants WxH, e.g. 640x480\n");
                return -1;
            }
            break;
        case 'l': o->list = 1; break;
        case 'f': o->fbdev = optarg; break;
        case 'n': o->no_display = 1; break;
        case 'p': o->http_port = atoi(optarg); break;
        case 'o': o->dump_dir = optarg; o->dump_given = 1; break;
        case 'N': o->frames = (unsigned)atoi(optarg); break;
        case 'b': snprintf(o->blobs, sizeof o->blobs, "%s", optarg); break;
        case 'u': o->uio = optarg; break;
        case 'R': o->restore = 1; break;
        case 'h': usage(); exit(0);
        default:  usage(); return -1;
        }
    }
    if (o->repeat == 0u)
        o->repeat = 1u;
    if (o->expect && !o->image) {
        fprintf(stderr, "--expect needs --image\n");
        return -1;
    }
    return 0;
}

/* ======================================================================
 *  the accelerator, set up once
 * ====================================================================== */
typedef struct {
    vine_uio_t  uio;
    dmaregion_t region;
    accel_t     acc;
    void       *img;                    /* ACCEL_IMG_BYTES in the region */
} board_t;

/*  A whole file, of exactly `want` bytes, or NULL. */
static uint8_t *read_exact(const char *dir, const char *name, size_t want)
{
    char     path[PATH_MAX + 64];
    FILE    *fh;
    long     sz;
    uint8_t *buf;

    snprintf(path, sizeof path, "%s/%s", dir, name);
    fh = fopen(path, "rb");
    if (fh == NULL) {
        fprintf(stderr, "  ERROR: cannot open %s: %s\n", path, strerror(errno));
        return NULL;
    }
    fseek(fh, 0, SEEK_END);
    sz = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    if (sz != (long)want) {
        fprintf(stderr, "  ERROR: %s is %ld bytes, expected %zu\n", path, sz, want);
        fclose(fh);
        return NULL;
    }
    buf = malloc(want);
    if (buf == NULL || fread(buf, 1, want, fh) != want) {
        fprintf(stderr, "  ERROR: cannot read %s\n", path);
        free(buf);
        fclose(fh);
        return NULL;
    }
    fclose(fh);
    printf("  loaded %-18s %9zu bytes\n", name, want);
    return buf;
}

/*  Into the region, and read back. dmaregion.h says why the read-back. */
static void *place(board_t *b, const char *what, const uint8_t *src, size_t len)
{
    void  *dst = dmaregion_alloc(&b->region, len);
    size_t bad;

    if (dst == NULL) {
        fprintf(stderr, "  ERROR: the DMA region is too small for %s\n", what);
        return NULL;
    }
    if (dmaregion_write(dst, src, len)) {
        fprintf(stderr, "  ERROR: %s is not 8-byte aligned in the region\n", what);
        return NULL;
    }
    bad = dmaregion_verify(dst, src, len);
    if (bad != len) {
        fprintf(stderr, "  ERROR: %s did not read back from the DMA region (first "
                "difference at byte %zu) - the region is not memory, or not this "
                "memory\n", what, bad);
        return NULL;
    }
    return dst;
}

static int board_init(board_t *b, const char *blobs, const char *uio_name)
{
    char           err[512];
    accel_status_t s;
    uint8_t       *prog = NULL, *wgt = NULL, *pb = NULL, *pm = NULL, *ps = NULL;
    uint32_t       words[ACCEL_PROG_WORDS];
    void          *d_wgt, *d_pb, *d_pm, *d_ps;
    int            rc = -1;

    memset(b, 0, sizeof *b);
    b->uio.fd = -1;                 /* not 0: closing that would close stdin */

    /*  Before anything depends on it, as main.c does: the only check that
     *  catches a target whose FPU rounds differently from the reference. */
    {
        preproc_status_t ps_ = preproc_self_test();
        if (ps_ != PREPROC_OK) {
            fprintf(stderr, "  ERROR: preprocessing self-test: %s\n",
                    preproc_strerror(ps_));
            return -1;
        }
    }
    printf("  preprocessing self-test passed (768 entries, round-to-nearest)\n");

    if (vine_uio_open(&b->uio, uio_name, err, sizeof err)) {
        fprintf(stderr, "  ERROR: %s\n", err);
        return -1;
    }
    printf("  /dev/uio%d: CSR at 0x%08llx, DMA region 0x%08llx + %zu KB\n",
           b->uio.index, (unsigned long long)b->uio.csr_phys,
           (unsigned long long)b->uio.dma_phys, b->uio.dma_len / 1024u);

    if (dmaregion_init(&b->region, b->uio.dma, b->uio.dma_phys, b->uio.dma_len)) {
        fprintf(stderr, "  ERROR: the DMA region is not page-aligned\n");
        return -1;
    }
    plat_linux_set_region(&b->region);

    /*  The ID first: if the PL is not programmed the reads come back as zeros
     *  and everything after this would look like a broken accelerator. (If the
     *  PL is not CLOCKED, the read never comes back at all and this line is
     *  where the board stops - see the README's troubleshooting.) */
    printf("  reading the accelerator's ID ...\n");
    fflush(stdout);
    s = accel_init(&b->acc, (uintptr_t)b->uio.csr);
    if (s != ACCEL_OK) {
        fprintf(stderr, "  ERROR: %s\n", accel_strerror(s));
        return -1;
    }
    b->acc.poll_limit = POLL_LIMIT_LINUX;
    printf("  accelerator alive (ID reads VINE)\n");

    if ((prog = read_exact(blobs, "program.bin", PROG_BYTES)) == NULL ||
        (wgt  = read_exact(blobs, "weights.bin", WGT_BYTES)) == NULL ||
        (pb   = read_exact(blobs, "params_b.bin", PB_BYTES)) == NULL ||
        (pm   = read_exact(blobs, "params_m0.bin", PM_BYTES)) == NULL ||
        (ps   = read_exact(blobs, "params_shift.bin", PS_BYTES)) == NULL)
        goto out;

    if ((d_wgt = place(b, "weights.bin", wgt, WGT_BYTES)) == NULL ||
        (d_pb  = place(b, "params_b.bin", pb, PB_BYTES)) == NULL ||
        (d_pm  = place(b, "params_m0.bin", pm, PM_BYTES)) == NULL ||
        (d_ps  = place(b, "params_shift.bin", ps, PS_BYTES)) == NULL)
        goto out;
    b->img = dmaregion_alloc(&b->region, ACCEL_IMG_BYTES);
    if (b->img == NULL) {
        fprintf(stderr, "  ERROR: no room for the image in the DMA region\n");
        goto out;
    }
    printf("  blobs written to the DMA region and read back intact\n");

    /*  Little-endian uint32 per word, which is what an aarch64 load gives. */
    memcpy(words, prog, sizeof words);
    s = accel_load_program(&b->acc, words, ACCEL_PROG_WORDS, N_INSTR);
    if (s == ACCEL_OK)
        s = accel_set_blobs(&b->acc, d_wgt, WGT_BYTES, d_pb, PB_BYTES,
                            d_pm, PM_BYTES, d_ps, PS_BYTES);
    if (s != ACCEL_OK) {
        fprintf(stderr, "  ERROR: %s\n", accel_strerror(s));
        goto out;
    }
    printf("  program loaded, blob bases written (physical addresses)\n");
    rc = 0;

out:
    free(prog);
    free(wgt);
    free(pb);
    free(pm);
    free(ps);
    return rc;
}

/*  One inference on a finished int8 tensor. *accel_ms is the accelerator's
 *  part - the image DMA plus the run - and excludes the copy into the region,
 *  which is the CPU's. */
static int infer(board_t *b, const int8_t *tensor, accel_result_t *r,
                 double *copy_ms, double *accel_ms)
{
    accel_status_t s;
    double         t0 = now_ms(), t1;

    if (dmaregion_write(b->img, tensor, ACCEL_IMG_BYTES)) {
        fprintf(stderr, "  ERROR: the image buffer is misaligned\n");
        return -1;
    }
    t1 = now_ms();
    s = accel_load_image(&b->acc, b->img, ACCEL_IMG_BYTES);
    if (s == ACCEL_OK)
        s = accel_run(&b->acc);
    if (s == ACCEL_OK)
        s = accel_result(&b->acc, r);
    if (s != ACCEL_OK) {
        fprintf(stderr, "  ERROR: %s (STATUS 0x%08x)\n", accel_strerror(s),
                (unsigned)b->acc.last_status);
        return -1;
    }
    if (copy_ms)
        *copy_ms = t1 - t0;
    if (accel_ms)
        *accel_ms = now_ms() - t1;
    return 0;
}

static const char *class_name(unsigned k)
{
    return k < QP_N_CLASSES ? CLASS_NAME[k] : "?";
}

static void print_result(const accel_result_t *r)
{
    unsigned i;
    double   p[ACCEL_N_CLASSES];

    ui_softmax(r->logit, p);
    printf("  logits:");
    for (i = 0; i < ACCEL_N_CLASSES; i++)
        printf(" %6d", r->logit[i]);
    printf("\n  class : %u = %s (%.1f %%)\n", r->argmax, class_name(r->argmax),
           100.0 * p[r->argmax]);
}

/* ======================================================================
 *  --image: one file, a known answer
 * ====================================================================== */
/*  EXPECTED.txt's "logits : a b c d" and "argmax : k = NAME" lines, as
 *  scripts/make_sdcard.py writes them. Both are required: the argmax comes
 *  from the RTL's own comparator, not from the logits, so it is checked too. */
static int parse_expected(const char *path, int16_t want[ACCEL_N_CLASSES],
                          unsigned *want_argmax)
{
    FILE *fh = fopen(path, "r");
    char  ln[256];
    int   v[4], have_l = 0, have_a = 0;

    if (fh == NULL)
        return -1;
    while (fgets(ln, sizeof ln, fh)) {
        const char *colon = strchr(ln, ':');
        if (colon == NULL)
            continue;
        if (strncmp(ln, "logits", 6) == 0 &&
            sscanf(colon + 1, "%d %d %d %d", &v[0], &v[1], &v[2], &v[3]) == 4) {
            int i;
            for (i = 0; i < 4; i++)
                want[i] = (int16_t)v[i];
            have_l = 1;
        } else if (strncmp(ln, "argmax", 6) == 0 &&
                   sscanf(colon + 1, "%u", want_argmax) == 1) {
            have_a = 1;
        }
    }
    fclose(fh);
    return (have_l && have_a) ? 0 : -1;
}

static int has_suffix(const char *s, const char *suf)
{
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

static int run_image(board_t *b, const opts_t *o)
{
    static int8_t   tensor[ACCEL_IMG_BYTES];
    accel_result_t  r;
    camfront_geom_t g;
    uint8_t        *rgb = NULL, *win = NULL;
    double          tmin = 1e9, tmax = 0.0, tsum = 0.0, copy_ms = 0.0, accel_ms = 0.0;
    unsigned        k;
    int             rc = 1;

    memset(&g, 0, sizeof g);
    printf("\nimage: %s\n", o->image);

    if (has_suffix(o->image, ".ppm") || has_suffix(o->image, ".PPM")) {
        /*  Any size, through the camera's front end - the same code path a
         *  camera frame takes, from the RGB onwards. */
        unsigned   w, h;
        camfront_t cf;
        preproc_status_t ps;

        rgb = ppm_read(o->image, &w, &h);
        if (rgb == NULL) {
            fprintf(stderr, "  ERROR: %s is not a binary (P6) PPM\n", o->image);
            return 1;
        }
        if (camfront_init(&cf, w, h)) {
            fprintf(stderr, "  ERROR: %ux%u cannot be resized\n", w, h);
            free(rgb);
            return 1;
        }
        g   = cf.g;
        win = malloc(CAMFRONT_WIN_BYTES);
        if (win == NULL) {
            camfront_free(&cf);
            free(rgb);
            return 1;
        }
        camfront_window(&cf, rgb, (size_t)w * 3u, win);
        camfront_free(&cf);
        ps = preproc_rgb(win, CAMFRONT_WIN, CAMFRONT_WIN, CAMFRONT_WIN_BYTES,
                         tensor, sizeof tensor);
        if (ps != PREPROC_OK) {
            fprintf(stderr, "  ERROR: %s\n", preproc_strerror(ps));
            goto out;
        }
        printf("  %ux%u -> Resize(256) %ux%u -> CenterCrop(224) at (%u,%u)\n",
               w, h, g.rs_w, g.rs_h, g.crop_x, g.crop_y);
    } else {
        /*  The SD card's formats, told apart by length as img_src does. */
        FILE *fh = fopen(o->image, "rb");
        long  sz;
        if (fh == NULL) {
            fprintf(stderr, "  ERROR: cannot open %s\n", o->image);
            return 1;
        }
        fseek(fh, 0, SEEK_END);
        sz = ftell(fh);
        fseek(fh, 0, SEEK_SET);
        if (sz == (long)ACCEL_IMG_BYTES) {
            if (fread(tensor, 1, sizeof tensor, fh) != sizeof tensor)
                sz = -1;
            else
                printf("  int8 224x224x3 - straight to the DMA, no preprocessing\n");
        } else if (sz == (long)PREPROC_SRC_BYTES) {
            uint8_t *src = malloc(PREPROC_SRC_BYTES);
            preproc_status_t ps = PREPROC_E_NULL;
            if (src && fread(src, 1, PREPROC_SRC_BYTES, fh) == PREPROC_SRC_BYTES)
                ps = preproc_rgb(src, QP_SRC_SIZE, QP_SRC_SIZE, PREPROC_SRC_BYTES,
                                 tensor, sizeof tensor);
            free(src);
            if (ps != PREPROC_OK)
                sz = -1;
            else
                printf("  256x256 RGB - preprocessed here, by preproc_rgb\n");
        } else {
            fprintf(stderr, "  ERROR: %s is %ld bytes - neither %u (int8) nor %zu "
                    "(256x256 RGB). Any other image: convert it to .ppm\n",
                    o->image, sz, (unsigned)ACCEL_IMG_BYTES, PREPROC_SRC_BYTES);
            fclose(fh);
            return 1;
        }
        fclose(fh);
        if (sz < 0) {
            fprintf(stderr, "  ERROR: cannot read or preprocess %s\n", o->image);
            return 1;
        }
    }

    for (k = 0; k < o->repeat; k++) {
        if (infer(b, tensor, &r, &copy_ms, &accel_ms))
            goto out;
        tsum += accel_ms;
        if (accel_ms < tmin) tmin = accel_ms;
        if (accel_ms > tmax) tmax = accel_ms;
    }
    print_result(&r);
    if (o->repeat > 1u)
        printf("  accelerator: %.3f ms mean, %.3f min, %.3f max over %u runs "
               "(image DMA + run; the copy into the region is %.3f ms more)\n",
               tsum / o->repeat, tmin, tmax, o->repeat, copy_ms);
    else
        printf("  accelerator: %.3f ms (image DMA + run)\n", accel_ms);

    /*  A still through the camera front end can be checked on the PC exactly
     *  like a saved camera frame. */
    if (win != NULL && o->dump_given)
        dump_frame(o->dump_dir, 0, o->image, rgb, &g, win, tensor, &r, accel_ms);

    rc = 0;
    if (o->expect) {
        int16_t  want[ACCEL_N_CLASSES];
        unsigned i, want_argmax = 0;
        int      same = 1;

        if (parse_expected(o->expect, want, &want_argmax)) {
            fprintf(stderr, "  ERROR: %s has no 'logits :' and 'argmax :' lines\n",
                    o->expect);
            rc = 1;
            goto out;
        }
        for (i = 0; i < ACCEL_N_CLASSES; i++)
            same &= want[i] == r.logit[i];
        same &= want_argmax == r.argmax;
        if (same) {
            printf("\n  PASS - all four logits and the class equal %s, bit for bit\n",
                   o->expect);
        } else {
            printf("\n  FAIL - expected %d %d %d %d, class %u (%s)\n", want[0],
                   want[1], want[2], want[3], want_argmax, o->expect);
            printf("         This is a bug, not rounding: the datapath is integer. If\n"
                   "         image_q8.bin passes and image_rgb.bin does not, look at\n"
                   "         the preprocessing; if both fail, at the DMA region.\n");
            rc = 2;
        }
    }
out:
    free(rgb);
    free(win);
    return rc;
}

/* ======================================================================
 *  live
 * ====================================================================== */
static struct termios g_tty_saved;
static int            g_tty_raw;

static void tty_restore(void)
{
    if (g_tty_raw) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_tty_saved);
        g_tty_raw = 0;
    }
}

static void tty_raw(void)
{
    struct termios t;

    if (!isatty(STDIN_FILENO) || tcgetattr(STDIN_FILENO, &g_tty_saved) < 0)
        return;
    t = g_tty_saved;
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0) {
        g_tty_raw = 1;
        atexit(tty_restore);
    }
}

static int read_key(void)
{
    unsigned char c;

    if (!g_tty_raw)
        return -1;
    return read(STDIN_FILENO, &c, 1) == 1 ? c : -1;
}

static void upper(char *s)
{
    for (; *s; s++)
        if (*s >= 'a' && *s <= 'z')
            *s = (char)(*s - 'a' + 'A');
}

static int run_live(board_t *b, const opts_t *o)
{
    char            err[512], source[160];
    cam_t           cam;
    camfront_t      cf;
    fbdev_t         fb;
    canvas_t        cv;
    httpview_t     *http = NULL;
    ui_state_t      st;
    accel_result_t  res;
    uint8_t        *rgb = NULL, *win = NULL;
    static int8_t   tensor[ACCEL_IMG_BYTES];
    const uint8_t  *yuv;
    int             have_fb = 0, frozen = 0, rc = 1, save = 0, failed = 0;
    unsigned        frames = 0, saved = 0;
    double          t_last = 0.0, t_report, fps = 0.0, accel_ms = 0.0, copy_ms = 0.0;
    double          t_front = 0.0;

    memset(&cv, 0, sizeof cv);
    memset(&st, 0, sizeof st);
    memset(&res, 0, sizeof res);

    if (cam_open(&cam, o->video, o->cam_w, o->cam_h, err, sizeof err)) {
        fprintf(stderr, "  ERROR: %s\n", err);
        return 1;
    }
    printf("  camera: %s, %ux%u %s%s\n", cam.card, cam.w, cam.h,
           cam.uyvy ? "UYVY" : "YUYV",
           (cam.w != o->cam_w || cam.h != o->cam_h) ? " (its nearest to the request)" : "");

    if (camfront_init(&cf, cam.w, cam.h)) {
        fprintf(stderr, "  ERROR: cannot set up the front end for %ux%u\n", cam.w, cam.h);
        cam_close(&cam);
        return 1;
    }
    printf("  front end: %ux%u -> Resize(256) %ux%u -> CenterCrop(224) at (%u,%u)\n",
           cam.w, cam.h, cf.g.rs_w, cf.g.rs_h, cf.g.crop_x, cf.g.crop_y);

    rgb = malloc((size_t)cam.w * cam.h * 3u);
    win = malloc(CAMFRONT_WIN_BYTES);
    if (rgb == NULL || win == NULL)
        goto out;

    if (!o->no_display) {
        if (fbdev_open(&fb, o->fbdev, err, sizeof err) == 0) {
            have_fb = 1;
            printf("  display: %s, %ux%u, %u bpp\n", o->fbdev, fb.w, fb.h, fb.bpp);
        } else {
            fprintf(stderr, "  warning: %s - carrying on without a monitor\n", err);
        }
    }
    if (o->http_port > 0) {
        http = httpview_start(o->http_port, err, sizeof err);
        if (http == NULL)
            fprintf(stderr, "  warning: browser view: %s\n", err);
        else
            printf("  browser view: http://<board-ip>:%d/\n", o->http_port);
    }
    if (have_fb || http) {
        unsigned w = have_fb ? fb.w : 1280u, h = have_fb ? fb.h : 720u;
        if (canvas_init(&cv, w, h)) {
            fprintf(stderr, "  ERROR: no memory for a %ux%u screen\n", w, h);
            goto out;
        }
    }

    /*  The footer is for the audience: what is looking at the leaf. The keys
     *  are the presenter's business and go to the console below. */
    snprintf(source, sizeof source, "USB CAMERA: %s  %uX%u", cam.card, cam.w, cam.h);
    upper(source);
    st.fw     = cam.w;
    st.fh     = cam.h;
    st.source = source;
    camfront_crop_rect(&cf.g, st.crop);

    if (cam_start(&cam, err, sizeof err)) {
        fprintf(stderr, "  ERROR: %s\n", err);
        goto out;
    }
    tty_raw();
    printf("\n  running - SPACE freezes, S saves a frame, Q quits\n\n");

    t_report = now_ms();
    while (!g_stop && (o->frames == 0u || frames < o->frames)) {
        int key = read_key();
        if (key == 'q' || key == 'Q')
            break;
        if (key == ' ') {
            frozen = !frozen;
            printf("  %s\n", frozen ? "frozen" : "live");
        }
        if (key == 's' || key == 'S')
            save = 1;

        if (!frozen) {
            int r = cam_grab(&cam, 1000, &yuv);
            if (r < 0) {
                fprintf(stderr, "  ERROR: the camera stopped (unplugged?)\n");
                failed = 1;
                break;
            }
            /*  A timeout is shown, not just waited out: on a stage, a frozen
             *  picture with no explanation looks like a crash. */
            st.note = r == 0 ? "NO FRAMES FROM THE CAMERA - CHECK THE USB CABLE"
                             : NULL;
        }
        if (!frozen && st.note == NULL) {
            double t0, t1;

            t0 = now_ms();
            camfront_yuv422_to_rgb(yuv, cam.stride, cam.w, cam.h, cam.uyvy, rgb);
            camfront_window(&cf, rgb, (size_t)cam.w * 3u, win);
            if (preproc_rgb(win, CAMFRONT_WIN, CAMFRONT_WIN, CAMFRONT_WIN_BYTES,
                            tensor, sizeof tensor) != PREPROC_OK) {
                fprintf(stderr, "  ERROR: preprocessing refused the window\n");
                failed = 1;
                break;
            }
            t1 = now_ms();
            if (infer(b, tensor, &res, &copy_ms, &accel_ms)) {
                failed = 1;
                break;
            }
            t_front = t1 - t0;
            frames++;

            {
                double t = now_ms();
                if (t_last > 0.0) {
                    double inst = 1000.0 / (t - t_last);
                    fps = fps > 0.0 ? 0.9 * fps + 0.1 * inst : inst;
                }
                t_last = t;
            }

            st.frame       = rgb;
            st.have_result = 1;
            memcpy(st.logit, res.logit, sizeof st.logit);
            st.argmax   = res.argmax;
            st.accel_ms = accel_ms;
            st.fps      = fps;
        } else if (frozen) {
            /*  Frozen: the picture and the answer stay; do not spin. */
            struct timespec ts = { 0, 30 * 1000000L };
            nanosleep(&ts, NULL);
        }
        st.frozen = frozen;

        if (save && st.have_result) {
            dump_frame(o->dump_dir, saved++, source, rgb, &cf.g, win, tensor,
                       &res, accel_ms);
            save = 0;
        }

        if (cv.px != NULL) {
            ui_render(&cv, &st);
            if (have_fb)
                fbdev_show(&fb, &cv);
            if (http)
                httpview_publish(http, &cv);
        }

        /*  Once a second on the console - the serial line cannot carry more. */
        if (now_ms() - t_report >= 1000.0 && st.have_result) {
            double p[ACCEL_N_CLASSES];
            ui_softmax(res.logit, p);
            printf("  %-12s %5.1f %%   fpga %6.2f ms   front end %5.1f ms   "
                   "copy %4.2f ms   loop %5.1f fps\n",
                   class_name(res.argmax), 100.0 * p[res.argmax], accel_ms,
                   t_front, copy_ms, fps);
            fflush(stdout);
            t_report = now_ms();
        }
    }
    rc = failed ? 1 : 0;

out:
    tty_restore();
    if (http)
        httpview_stop(http);
    if (have_fb)
        fbdev_close(&fb);
    canvas_free(&cv);
    camfront_free(&cf);
    cam_close(&cam);
    free(rgb);
    free(win);
    printf("\n  %u frame(s) classified\n", frames);
    return rc;
}

/* ====================================================================== */
int main(int argc, char **argv)
{
    opts_t  o;
    board_t b;
    int     rc;

    if (parse_opts(argc, argv, &o))
        return 1;
    if (o.restore) {
        fbdev_restore_console();
        return 0;
    }
    if (o.list)
        return cam_list(o.video, stdout) ? 1 : 0;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    printf("\nvinecam - MobileNetV2 grape-leaf classifier, ZCU104 accelerator under Linux\n");
    printf("  blobs from %s\n", o.blobs);
    if (board_init(&b, o.blobs, o.uio)) {
        vine_uio_close(&b.uio);
        return 1;
    }

    rc = o.image ? run_image(&b, &o) : run_live(&b, &o);

    plat_linux_set_region(NULL);
    vine_uio_close(&b.uio);
    return rc;
}
