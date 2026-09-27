/*============================================================================
 *  img_src.c  -  the three image sources. See img_src.h for the contract.
 *
 *  Not built by firmware/Makefile: needs xilffs and xuartps from a standalone
 *  BSP. The interface exists so that main.c does not care which of these is
 *  compiled in, and so the host tests can use a fourth (a plain buffer) without
 *  any of this being present.
 *
 *  Which one is compiled in:
 *
 *      -DIMG_SRC_DEFAULT=IMG_SRC_UART      the practical one (see README)
 *      -DIMG_SRC_DEFAULT=IMG_SRC_FILE      SD card, no PC needed
 *      -DIMG_SRC_DEFAULT=IMG_SRC_MEM       already in DDR, e.g. via JTAG
 *==========================================================================*/
#include "img_src.h"

#include <string.h>

#ifndef IMG_SRC_DEFAULT
#define IMG_SRC_DEFAULT IMG_SRC_UART
#endif

#ifndef IMG_SRC_FILE_PATH
#define IMG_SRC_FILE_PATH "image.bin"
#endif

/*  Where a JTAG-loaded image is expected to be. Chosen to sit clear of the
 *  blobs main.c places in .bss; xsct writes it with, for example
 *      mwr -bin -file leaf.bin 0x10000000 37632
 *  (37,632 words = 150,528 bytes). */
#ifndef IMG_SRC_MEM_ADDR
#define IMG_SRC_MEM_ADDR 0x10000000u
#endif

/*  A JTAG-loaded buffer has no length to infer its format from, so it is stated
 *  here rather than guessed. Q8 by default because IMG_SRC_MEM exists for first
 *  bring-up, and the point of that is to have nothing at all between the PC and
 *  the DMA - including this preprocessing. Use
 *  -DIMG_SRC_MEM_FMT=IMG_FMT_RGB256 to preload a decoded 256x256 image. */
#ifndef IMG_SRC_MEM_FMT
#define IMG_SRC_MEM_FMT IMG_FMT_Q8
#endif

#include "ff.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xuartps.h"

/* ======================================================================
 *  UART
 * ====================================================================== */
static XUartPs uart;

/*  The PS UART the CP2108 bridge is wired to. UART0 on the ZCU104; if a board
 *  brings the console out on UART1 instead, this is the one line to change. */
#ifndef IMG_UART_DEVICE_ID
#define IMG_UART_DEVICE_ID XPAR_XUARTPS_0_DEVICE_ID
#endif

/*  ZERO MEANS "LEAVE THE BAUD RATE ALONE", and that is the default on purpose.
 *
 *  This is the same UART the console prints on. main.c uses printf, which the BSP
 *  routes to psu_uart_0, and IMG_UART_DEVICE_ID above is psu_uart_0 - one device.
 *  So calling XUartPs_SetBaudRate here would not just configure the image
 *  transfer, it would reconfigure the CONSOLE underneath the terminal that is
 *  watching it. Every printf after img_src_open would then arrive at a rate the
 *  terminal is no longer set to - as garbage - starting exactly at the line that
 *  names the image source. On a bench that reads as a crash during start-up, and
 *  it is not one: the application is running perfectly.
 *
 *  Inheriting whatever the BSP configured keeps the console readable, and the
 *  image arrives at the console's rate. At the BSP default of 115200 that is about
 *  13 s for a 196,608-byte RGB frame: slow, correct, readable, and the right trade
 *  for first bring-up.
 *
 *  To go faster, set BOTH ends deliberately - raise the BSP's STDIN/STDOUT baud to
 *  921600, build with -DIMG_UART_BAUD=921600 so this agrees with it, and open the
 *  terminal at 921600. That puts an RGB frame at ~2.1 s. Setting only one of the
 *  two is the trap above. */
#ifndef IMG_UART_BAUD
#define IMG_UART_BAUD 0u
#endif

static int uart_open(void)
{
    XUartPs_Config *cfg = XUartPs_LookupConfig(IMG_UART_DEVICE_ID);

    if (!cfg)
        return -1;
    if (XUartPs_CfgInitialize(&uart, cfg, cfg->BaseAddress) != XST_SUCCESS)
        return -1;

    if (IMG_UART_BAUD != 0u) {
        /*  Announced BEFORE the change, because afterwards this very message
         *  would be the unreadable thing it is warning about. */
        xil_printf("  UART: switching this console to %u baud - reopen the"
                   " terminal at that rate\r\n",
                   (unsigned)IMG_UART_BAUD);
        XUartPs_SetBaudRate(&uart, IMG_UART_BAUD);
    }
    /*  Polled. An interrupt-driven receiver would be better if the PS had
     *  anything else to do, and it has not: it is waiting for this image. */
    XUartPs_SetOperMode(&uart, XUARTPS_OPER_MODE_NORMAL);
    return 0;
}

/*  Blocking read of exactly n bytes. XUartPs_Recv returns what is available, so
 *  this loops - a single call returning short is the normal case at 921600 baud
 *  and treating its return as "all of it" is the classic way to get a shifted
 *  image and a confident wrong answer. */
static int uart_read_exact(uint8_t *dst, size_t n)
{
    size_t got = 0;

    while (got < n) {
        u32 r = XUartPs_Recv(&uart, dst + got, (u32)(n - got));
        got += r;
    }
    return 0;
}

/*  Resynchronise on the 4-byte magic, and report which format it announced.
 *  Without this, one spurious byte at power-up offsets every frame that follows
 *  for the rest of the session.
 *
 *  'IMG1' is an already-quantised tensor; 'IMG2' is decoded RGB that the board
 *  preprocesses itself. Scanning for both in the same pass rather than for one
 *  and then the other keeps the resynchronisation property: whichever arrives, a
 *  garbage prefix is skipped and the frame is still found. */
static void uart_wait_magic(img_fmt_t *fmt)
{
    static const uint8_t m_q8[4]  = { 'I', 'M', 'G', '1' };
    static const uint8_t m_rgb[4] = { 'I', 'M', 'G', '2' };
    uint8_t win[4] = { 0, 0, 0, 0 };

    for (;;) {
        uint8_t b;
        uart_read_exact(&b, 1);
        win[0] = win[1]; win[1] = win[2]; win[2] = win[3]; win[3] = b;
        if (memcmp(win, m_q8, 4) == 0)  { *fmt = IMG_FMT_Q8;     return; }
        if (memcmp(win, m_rgb, 4) == 0) { *fmt = IMG_FMT_RGB256; return; }
    }
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int uart_next(uint8_t *buf, size_t cap, img_fmt_t *fmt)
{
    uint8_t  hdr[4];
    uint32_t n, sum, want_sum;
    size_t   i, want_len;

    for (;;) {
        sum = 0;
        uart_wait_magic(fmt);
        want_len = IMG_FMT_BYTES(*fmt);

        uart_read_exact(hdr, 4);
        n = le32(hdr);
        if (n != (uint32_t)want_len) {
            /*  Not a short read - the length contradicts the format the magic
             *  announced. The two are deliberately redundant: a sender and a
             *  receiver that disagree about the format produce a dropped frame
             *  and this message, instead of 196,608 RGB bytes being read as a
             *  quantised tensor, which would be a plausible image and a
             *  confident wrong class. */
            xil_printf("  %s frame says %u bytes, expected %u - dropped\r\n",
                       (*fmt == IMG_FMT_RGB256) ? "RGB" : "int8",
                       (unsigned)n, (unsigned)want_len);
            continue;
        }
        if (want_len > cap)         /* unreachable with IMG_SRC_BUF_BYTES */
            return -1;

        uart_read_exact(buf, want_len);
        uart_read_exact(hdr, 4);
        want_sum = le32(hdr);

        for (i = 0; i < want_len; i++)
            sum += buf[i];

        if (sum != want_sum) {
            /*  A dropped byte shifts every channel after it, which yields a
             *  plausible image. Refusing the frame is the whole reason the
             *  checksum is in the protocol. */
            xil_printf("  image checksum 0x%08x, expected 0x%08x - dropped\r\n",
                       (unsigned)sum, (unsigned)want_sum);
            continue;
        }
        return (int)want_len;
    }
}

/* ======================================================================
 *  SD file
 * ====================================================================== */
/*  The format comes from the file's LENGTH, which is unambiguous here: the two
 *  are 150,528 and 196,608 bytes and nothing else is accepted. That keeps one
 *  filename on the card, and a file of any other size is refused outright rather
 *  than read as far as it goes - a truncated read would be a valid-looking image
 *  with a garbage tail. */
static int file_next(const char *path, uint8_t *buf, size_t cap, img_fmt_t *fmt)
{
    FIL     f;
    UINT    got = 0;
    FSIZE_t sz;
    size_t  want;

    if (f_open(&f, path, FA_READ) != FR_OK)
        return -1;

    sz = f_size(&f);
    if (sz == (FSIZE_t)ACCEL_IMG_BYTES) {
        *fmt = IMG_FMT_Q8;
    } else if (sz == (FSIZE_t)PREPROC_SRC_BYTES) {
        *fmt = IMG_FMT_RGB256;
    } else {
        xil_printf("  %s is %u bytes - expected %u (int8) or %u (RGB)\r\n",
                   path, (unsigned)sz, (unsigned)ACCEL_IMG_BYTES,
                   (unsigned)PREPROC_SRC_BYTES);
        f_close(&f);
        return -1;
    }

    want = IMG_FMT_BYTES(*fmt);
    if (want > cap) { f_close(&f); return -1; }

    if (f_read(&f, buf, (UINT)want, &got) != FR_OK || got != (UINT)want) {
        f_close(&f);
        return -1;
    }
    f_close(&f);
    return (int)want;
}

/* ======================================================================
 *  the interface
 * ====================================================================== */
int img_src_open(img_src_t *s)
{
    memset(s, 0, sizeof *s);
    s->kind = IMG_SRC_DEFAULT;
    s->path = IMG_SRC_FILE_PATH;
    s->mem  = (const void *)(uintptr_t)IMG_SRC_MEM_ADDR;
    s->mem_fmt = IMG_SRC_MEM_FMT;

    switch (s->kind) {
    case IMG_SRC_UART:
        /*  Fall back to the SD card rather than failing: a demo with no PC
         *  attached should still classify the image on the card. */
        if (uart_open() != 0) {
            s->kind = IMG_SRC_FILE;
            s->once = 1;
        }
        return 0;

    case IMG_SRC_FILE:
    case IMG_SRC_MEM:
        s->once = 1;
        return 0;

    default:
        return -1;
    }
}

int img_src_next(img_src_t *s, void *buf, size_t len, img_fmt_t *fmt)
{
    int got;

    if (buf == NULL || fmt == NULL || len < IMG_SRC_BUF_BYTES)
        return -1;

    /*  A one-shot source has nothing more to give. Returning -1 rather than the
     *  same image again is what lets main.c's loop terminate. */
    if (s->once && s->served > 0)
        return -1;

    switch (s->kind) {
    case IMG_SRC_UART:
        got = uart_next((uint8_t *)buf, len, fmt);
        break;

    case IMG_SRC_FILE:
        got = file_next(s->path, (uint8_t *)buf, len, fmt);
        break;

    case IMG_SRC_MEM:
        /*  Memory carries no length, so the format cannot be inferred from one
         *  and comes from the build-time knob instead. */
        *fmt = s->mem_fmt;
        got  = (int)IMG_FMT_BYTES(*fmt);
        memcpy(buf, s->mem, (size_t)got);
        break;

    default:
        return -1;
    }

    if (got > 0)
        s->served++;
    return got;
}

void img_src_close(img_src_t *s)
{
    (void)s;
}

const char *img_src_name(const img_src_t *s)
{
    switch (s->kind) {
    case IMG_SRC_UART: return "UART from the PC (scripts/send_image.py)";
    case IMG_SRC_FILE: return "a .bin on the SD card";
    case IMG_SRC_MEM:  return "already in DDR (JTAG preload)";
    default:           return "?";
    }
}
