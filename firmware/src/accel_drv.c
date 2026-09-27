/*============================================================================
 *  accel_drv.c  -  the driver. See accel_drv.h for the contract and for the
 *                  cache-coherency requirement, which is the important part.
 *==========================================================================*/
#include "accel_drv.h"

/*  Generous: the longest legitimate run is ~1.15 million cycles (measured by
 *  accel_axi_tb), and top_seq's own watchdog abandons a hung load after 2^20
 *  cycles per load and raises `fault`, which this driver reports. So this limit
 *  exists to stop a dead PL from hanging the PS forever, not to second-guess the
 *  hardware's own timeout. */
#define ACCEL_POLL_DEFAULT 200000u

static void wr(accel_t *a, uint32_t off, uint32_t v)
{
    accel_plat_wr32(a->csr + off, v);
}

static uint32_t rd(accel_t *a, uint32_t off)
{
    return accel_plat_rd32(a->csr + off);
}

static uint32_t poll_limit(const accel_t *a)
{
    return a->poll_limit ? a->poll_limit : ACCEL_POLL_DEFAULT;
}

static int misaligned(const void *p)
{
    return (uintptr_t)p & (ACCEL_ALIGN - 1u);
}

uint32_t accel_status_raw(accel_t *a)
{
    return rd(a, ACCEL_STATUS);
}

const char *accel_strerror(accel_status_t s)
{
    switch (s) {
    case ACCEL_OK:             return "ok";
    case ACCEL_ERR_ID:         return "the ID register did not read VINE - is the PL programmed and clocked?";
    case ACCEL_ERR_ALIGN:      return "a buffer is not 64-byte aligned, so it cannot be cache-flushed safely";
    case ACCEL_ERR_SIZE:       return "a buffer is the wrong length for its blob";
    case ACCEL_ERR_BUSY:       return "the accelerator is running or loading an image";
    case ACCEL_ERR_TIMEOUT:    return "timed out polling STATUS";
    case ACCEL_ERR_FAULT:      return "the accelerator reported fault / dma_error / tag_error";
    case ACCEL_ERR_NO_RESULT:  return "the run finished but no result was captured";
    default:                   return "unknown";
    }
}

/*  Wait for `want` to appear in STATUS, giving up on an error bit or the poll
 *  limit. One place, so every wait in this driver reports failures the same way.
 *
 *  Checking the error bits here and not only `want` is the difference between a
 *  clear message and a timeout: a run that faults would otherwise sit here until
 *  the limit and report ACCEL_ERR_TIMEOUT, which says nothing about why. */
static accel_status_t wait_for(accel_t *a, uint32_t want)
{
    uint32_t n = poll_limit(a);

    for (;;) {
        uint32_t st = rd(a, ACCEL_STATUS);
        a->last_status = st;

        if (st & ACCEL_ST_ERRORS)
            return ACCEL_ERR_FAULT;
        if (st & want)
            return ACCEL_OK;
        if (n-- == 0u)
            return ACCEL_ERR_TIMEOUT;

        accel_plat_relax();
    }
}

accel_status_t accel_init(accel_t *a, uintptr_t csr_base)
{
    a->csr         = csr_base;
    a->last_status = 0u;
    a->poll_limit  = 0u;

    /*  The cheapest possible proof that the aperture is mapped and the PL is
     *  programmed and clocked. Everything else fails confusingly if this is
     *  wrong: reads return zeros or hang the bus, and it looks like a broken
     *  accelerator rather than a missing bitstream. */
    if (rd(a, ACCEL_ID) != ACCEL_ID_MAGIC)
        return ACCEL_ERR_ID;

    /*  Clear anything sticky from a previous run so the first STATUS read of
     *  this one means what it says. */
    wr(a, ACCEL_STATUS_CLR, 0xFFu);
    wr(a, ACCEL_IRQ_EN, 0u);       /* this driver polls; see the README */
    return ACCEL_OK;
}

accel_status_t accel_load_program(accel_t *a, const uint32_t *words,
                                  size_t n_words, uint8_t n_instr)
{
    if (n_words != ACCEL_PROG_WORDS)
        return ACCEL_ERR_SIZE;
    if (rd(a, ACCEL_STATUS) & (ACCEL_ST_RUNNING | ACCEL_ST_IMG_BUSY))
        return ACCEL_ERR_BUSY;

    /*  A plain loop over the aperture. No pointer register to get out of step,
     *  which DD-031 chose deliberately: a pointer one word behind produces a
     *  program that EXECUTES. */
    for (size_t i = 0; i < n_words; i++)
        wr(a, (uint32_t)(ACCEL_PROG_BASE + 4u * i), words[i]);

    /*  n_instr is written AFTER the program, so a half-written program can never
     *  be launched by a stale count. It resets to zero in the RTL precisely so
     *  that a PS which forgets this gets top_seq's T-1 refusal rather than an
     *  assumed 64. */
    wr(a, ACCEL_N_INSTR, n_instr);
    return ACCEL_OK;
}

accel_status_t accel_set_blobs(accel_t *a,
                               const void *wgt, size_t wgt_len,
                               const void *pb,  size_t pb_len,
                               const void *pm,  size_t pm_len,
                               const void *ps,  size_t ps_len)
{
    if (misaligned(wgt) || misaligned(pb) || misaligned(pm) || misaligned(ps))
        return ACCEL_ERR_ALIGN;
    if (wgt_len == 0u || pb_len == 0u || pm_len == 0u || ps_len == 0u)
        return ACCEL_ERR_SIZE;

    /*  params_b and params_m0 are one int32 per channel and params_shift one
     *  byte, so the two must agree and the third must be a quarter of them. A
     *  mismatch here means the wrong file was loaded into the wrong buffer,
     *  which otherwise shows up as a wrong bias somewhere in the middle of the
     *  network. */
    if (pb_len != pm_len || pb_len != 4u * ps_len)
        return ACCEL_ERR_SIZE;

    if (rd(a, ACCEL_STATUS) & (ACCEL_ST_RUNNING | ACCEL_ST_IMG_BUSY))
        return ACCEL_ERR_BUSY;

    /*  THE FLUSH. See accel_drv.h: without this the DMA reads stale DDR while
     *  the real bytes sit dirty in L1/L2, and the run completes with a wrong
     *  answer and no error. Done here rather than left to the caller because a
     *  caller who forgets gets no warning of any kind. */
    accel_plat_flush(wgt, wgt_len);
    accel_plat_flush(pb,  pb_len);
    accel_plat_flush(pm,  pm_len);
    accel_plat_flush(ps,  ps_len);

    wr(a, ACCEL_WGT_BASE, (uint32_t)(uintptr_t)wgt);
    wr(a, ACCEL_PB_BASE,  (uint32_t)(uintptr_t)pb);
    wr(a, ACCEL_PM_BASE,  (uint32_t)(uintptr_t)pm);
    wr(a, ACCEL_PS_BASE,  (uint32_t)(uintptr_t)ps);
    return ACCEL_OK;
}

accel_status_t accel_load_image(accel_t *a, const void *img, size_t img_len)
{
    accel_status_t s;

    if (misaligned(img))
        return ACCEL_ERR_ALIGN;

    /*  The DMA reads exactly ACCEL_IMG_BYTES and the count is structural in the
     *  hardware - there is no register for it (DD-032). So a buffer of the wrong
     *  size is a caller bug that the hardware cannot detect: it would read past
     *  the end, or leave the tail of img_buffer holding the previous picture. */
    if (img_len != ACCEL_IMG_BYTES)
        return ACCEL_ERR_SIZE;

    if (rd(a, ACCEL_STATUS) & (ACCEL_ST_RUNNING | ACCEL_ST_IMG_BUSY))
        return ACCEL_ERR_BUSY;

    accel_plat_flush(img, img_len);
    wr(a, ACCEL_IMG_BASE, (uint32_t)(uintptr_t)img);

    /*  Clear the previous load's sticky bit BEFORE starting, or the wait below
     *  returns immediately on a stale IMG_DONE and the run begins on a
     *  half-written image. */
    wr(a, ACCEL_STATUS_CLR, ACCEL_ST_IMG_DONE);
    wr(a, ACCEL_CTRL, ACCEL_CTRL_LOAD_IMAGE);

    s = wait_for(a, ACCEL_ST_IMG_DONE);
    if (s != ACCEL_OK)
        return s;

    /*  IMG_DONE is a sticky bit set by a pulse that fires only on success, so
     *  seeing it means the whole image landed - but check the live busy bit too,
     *  because a driver that trusts one bit and not the pair is one RTL change
     *  from being wrong. */
    if (rd(a, ACCEL_STATUS) & ACCEL_ST_IMG_BUSY)
        return ACCEL_ERR_BUSY;

    return ACCEL_OK;
}

accel_status_t accel_run(accel_t *a)
{
    uint32_t st = rd(a, ACCEL_STATUS);

    /*  The RTL refuses both of these with SLVERR, so this check is not the
     *  safety net - it is so the failure arrives as a return value instead of a
     *  data abort several frames up the stack. */
    if (st & (ACCEL_ST_RUNNING | ACCEL_ST_IMG_BUSY))
        return ACCEL_ERR_BUSY;

    /*  START also clears the sticky bits and zeroes the stale result in the
     *  hardware, so there is nothing to clear here first. */
    wr(a, ACCEL_CTRL, ACCEL_CTRL_START);
    return wait_for(a, ACCEL_ST_DONE);
}

accel_status_t accel_result(accel_t *a, accel_result_t *out)
{
    uint32_t lo, hi, am;

    am = rd(a, ACCEL_ARGMAX);
    if (!(am & ACCEL_ARGMAX_VALID))
        return ACCEL_ERR_NO_RESULT;

    lo = rd(a, ACCEL_RESULT_LO);
    hi = rd(a, ACCEL_RESULT_HI);

    /*  The casts matter: the logits are SIGNED int16 packed two to a word, and
     *  reading them as unsigned turns -4950 into 60586. That is exactly the
     *  mistake accel_axi_tb's report line made once. */
    out->logit[0] = (int16_t)(lo & 0xFFFFu);
    out->logit[1] = (int16_t)(lo >> 16);
    out->logit[2] = (int16_t)(hi & 0xFFFFu);
    out->logit[3] = (int16_t)(hi >> 16);
    out->argmax   = (uint8_t)(am & ACCEL_ARGMAX_MASK);
    return ACCEL_OK;
}
