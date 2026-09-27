/*============================================================================
 *  accel_drv.h  -  driving the accelerator from the PS
 *
 *  The whole interface, in the order it is used:
 *
 *      accel_init          check the ID, clear any previous state
 *      accel_load_program  512 words through the aperture, once per boot
 *      accel_set_blobs     where the four static blobs are in DDR
 *      accel_load_image    where the image is, then start the DMA and wait
 *      accel_run           START, then wait for done
 *      accel_result        the four logits and the predicted class
 *
 *  That is the sequence hardware/tb/accel_axi_tb.sv executes against the RTL and
 *  gets 6,895,780 elements bit-exact, so it is a transcription of something
 *  already verified rather than a fresh guess at the protocol.
 *
 *  ---- THE THING MOST LIKELY TO GO WRONG ON REAL HARDWARE -----------------
 *
 *  S_AXI_HP0_FPD IS NOT CACHE-COHERENT.
 *
 *  The accelerator reads the blobs and the image out of DDR over that port,
 *  which does not snoop the APU's caches. So when the PS has just written a
 *  buffer, the bytes are sitting dirty in L1/L2 and DDR still holds whatever was
 *  there before. The DMA then reads DDR, gets the stale data, and the run
 *  completes - with a plausible wrong answer and no error anywhere. Nothing in
 *  simulation can catch this, because the AXI slave model in
 *  hardware/tb/axi_ddr_model.svh has no caches to be incoherent with.
 *
 *  So every buffer handed to this driver MUST be flushed after it is written and
 *  before the accelerator is told about it. accel_set_blobs and
 *  accel_load_image do the flush themselves through the platform hook below, so
 *  a caller cannot forget - that is why they take lengths as well as addresses.
 *
 *  For the same reason every buffer must be ACCEL_ALIGN-aligned: a cache flush
 *  works on whole lines, and a buffer sharing its first or last line with
 *  something else means flushing that too, or not flushing part of the buffer.
 *  accel_set_blobs refuses a misaligned address rather than papering over it.
 *
 *  ---- the platform hooks -------------------------------------------------
 *
 *  Four functions the platform provides, so this driver is portable C with no
 *  Xilinx headers and can therefore be TESTED ON A PC. firmware/test supplies a
 *  mock CSR and a no-op flush; firmware/src/plat_zynq.c supplies the real ones.
 *==========================================================================*/
#ifndef ACCEL_DRV_H
#define ACCEL_DRV_H

#include <stddef.h>
#include <stdint.h>
#include "accel_csr.h"

/*  One A53 cache line. Buffers are aligned and padded to this; see the
 *  coherency note above for why it is not merely a performance choice. */
#define ACCEL_ALIGN 64u

typedef enum {
    ACCEL_OK = 0,
    ACCEL_ERR_ID,          /* the ID register did not read back "VINE"        */
    ACCEL_ERR_ALIGN,       /* a buffer was not ACCEL_ALIGN-aligned            */
    ACCEL_ERR_SIZE,        /* a buffer was the wrong length for its blob      */
    ACCEL_ERR_BUSY,        /* asked to start while running or loading         */
    ACCEL_ERR_TIMEOUT,     /* the poll gave up                                */
    ACCEL_ERR_FAULT,       /* STATUS reported fault / dma_error / tag_error   */
    ACCEL_ERR_NO_RESULT    /* done, but the result was never captured         */
} accel_status_t;

typedef struct {
    uintptr_t csr;         /* the AXI-Lite base, 0xA000_0000 in the BD        */
    uint32_t  last_status; /* whatever STATUS said when something went wrong  */
    uint32_t  poll_limit;  /* polls before ACCEL_ERR_TIMEOUT; 0 = the default */
} accel_t;

typedef struct {
    int16_t logit[ACCEL_N_CLASSES];
    uint8_t argmax;
} accel_result_t;

/* ---- the platform provides these ---------------------------------------- */
void     accel_plat_wr32(uintptr_t addr, uint32_t val);
uint32_t accel_plat_rd32(uintptr_t addr);

/*  Push a buffer out of the caches so the DMA can see it. MUST be a real
 *  flush-to-DDR on the ZU+ (Xil_DCacheFlushRange); the host test's no-op is
 *  only correct because a PC test has no accelerator reading DDR behind it. */
void     accel_plat_flush(const void *addr, size_t len);

/*  Somewhere to yield or spin while polling. May be empty. */
void     accel_plat_relax(void);

/* ---- the driver --------------------------------------------------------- */
accel_status_t accel_init(accel_t *a, uintptr_t csr_base);

/*  words must be ACCEL_PROG_WORDS long. Refused while running - the RTL would
 *  answer SLVERR and top_seq would drop the write anyway (finding T-10). */
accel_status_t accel_load_program(accel_t *a, const uint32_t *words,
                                  size_t n_words, uint8_t n_instr);

/*  The four static blobs. Addresses are PHYSICAL, which on baremetal is the
 *  same as the pointer. Lengths are taken so the flush can be done here, and
 *  checked against what the compiled program actually needs. */
accel_status_t accel_set_blobs(accel_t *a,
                               const void *wgt, size_t wgt_len,
                               const void *pb,  size_t pb_len,
                               const void *pm,  size_t pm_len,
                               const void *ps,  size_t ps_len);

/*  The image, HWC interleaved: byte (y*W + x)*3 + c holds channel c (DD-032).
 *  Flushes, points IMG_BASE at it, pulses LOAD_IMAGE and waits for the DMA. */
accel_status_t accel_load_image(accel_t *a, const void *img, size_t img_len);

/*  START, then poll until done. Refused if a run or an image load is in
 *  flight - starting on a half-written image is a complete feature map built
 *  partly from the previous picture, which nothing downstream would notice. */
accel_status_t accel_run(accel_t *a);

accel_status_t accel_result(accel_t *a, accel_result_t *out);

/*  For a report or an LED. Never needed on the happy path. */
uint32_t       accel_status_raw(accel_t *a);
const char    *accel_strerror(accel_status_t s);

#endif /* ACCEL_DRV_H */
