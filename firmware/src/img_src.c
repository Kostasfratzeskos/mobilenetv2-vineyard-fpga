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

#include "ff.h"
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

#ifndef IMG_UART_BAUD
#define IMG_UART_BAUD 921600u
#endif

static int uart_open(void)
{
    XUartPs_Config *cfg = XUartPs_LookupConfig(IMG_UART_DEVICE_ID);

    if (!cfg)
        return -1;
    if (XUartPs_CfgInitialize(&uart, cfg, cfg->BaseAddress) != XST_SUCCESS)
        return -1;

    XUartPs_SetBaudRate(&uart, IMG_UART_BAUD);
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

/*  Resynchronise on the 4-byte magic. Without this, one spurious byte at
 *  power-up offsets every frame that follows for the rest of the session. */
static void uart_wait_magic(void)
{
    static const uint8_t want[4] = { 'I', 'M', 'G', '1' };
    uint8_t win[4] = { 0, 0, 0, 0 };

    for (;;) {
        uint8_t b;
        uart_read_exact(&b, 1);
        win[0] = win[1]; win[1] = win[2]; win[2] = win[3]; win[3] = b;
        if (memcmp(win, want, 4) == 0)
            return;
    }
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int uart_next(uint8_t *buf, size_t len)
{
    uint8_t  hdr[4];
    uint32_t n, sum = 0, want_sum;
    size_t   i;

    for (;;) {
        uart_wait_magic();

        uart_read_exact(hdr, 4);
        n = le32(hdr);
        if (n != (uint32_t)len) {
            /*  Not a short read - a frame for a different image size. Say so
             *  and resynchronise rather than truncating it into the buffer. */
            xil_printf("  image frame says %u bytes, expected %u - dropped\r\n",
                       (unsigned)n, (unsigned)len);
            continue;
        }

        uart_read_exact(buf, len);
        uart_read_exact(hdr, 4);
        want_sum = le32(hdr);

        for (i = 0; i < len; i++)
            sum += buf[i];

        if (sum != want_sum) {
            /*  A dropped byte shifts every channel after it, which yields a
             *  plausible image. Refusing the frame is the whole reason the
             *  checksum is in the protocol. */
            xil_printf("  image checksum 0x%08x, expected 0x%08x - dropped\r\n",
                       (unsigned)sum, (unsigned)want_sum);
            continue;
        }
        return (int)len;
    }
}

/* ======================================================================
 *  SD file
 * ====================================================================== */
static int file_next(const char *path, uint8_t *buf, size_t len)
{
    FIL  f;
    UINT got = 0;

    if (f_open(&f, path, FA_READ) != FR_OK)
        return -1;
    if (f_read(&f, buf, (UINT)len, &got) != FR_OK || got != (UINT)len) {
        f_close(&f);
        return -1;
    }
    f_close(&f);
    return (int)len;
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

int img_src_next(img_src_t *s, void *buf, size_t len)
{
    int got;

    if (len != ACCEL_IMG_BYTES)
        return -1;

    /*  A one-shot source has nothing more to give. Returning -1 rather than the
     *  same image again is what lets main.c's loop terminate. */
    if (s->once && s->served > 0)
        return -1;

    switch (s->kind) {
    case IMG_SRC_UART:
        got = uart_next((uint8_t *)buf, len);
        break;

    case IMG_SRC_FILE:
        got = file_next(s->path, (uint8_t *)buf, len);
        break;

    case IMG_SRC_MEM:
        memcpy(buf, s->mem, len);
        got = (int)len;
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
