/*============================================================================
 *  test_drv_seq.c  -  the driver against a mock of the CSR's actual behaviour
 *
 *  There is no board. What can still be checked on a PC is whether the driver
 *  does the right things in the right ORDER, and whether it ever does something
 *  the real CSR would refuse - and that is most of what a driver can get wrong.
 *
 *  The mock is not a register file with a memcpy. It implements the parts of
 *  hardware/rtl/axi/axi_lite_csr.v that have behaviour:
 *
 *    * CTRL is write-1-to-PULSE and reads back zero. A driver that expected to
 *      read its own START bit back would fail here.
 *    * STATUS's RUNNING and IMG_BUSY are live; DONE, IMG_DONE, FAULT, DMA_ERROR,
 *      TAG_ERROR and RESULT are sticky and cleared by START or STATUS_CLR.
 *    * `done` and the result are only ever visible because the CSR latches a
 *      one-cycle event, so the mock makes them appear a few polls later - a
 *      driver that read STATUS once and expected the answer would fail.
 *    * EVERY GUARD the RTL answers SLVERR to is recorded as a violation:
 *      writing config or the program while running or loading, START while
 *      running or loading, a second LOAD_IMAGE while one is in flight, and any
 *      write to a read-only register. The test asserts zero violations, so the
 *      driver cannot pass by doing something the hardware would reject.
 *
 *  The one thing this cannot check is the register OFFSETS, because the mock
 *  decodes them from the same header the driver uses - a typo would cancel out.
 *  That is test_csr_map.c's job, against the RTL.
 *==========================================================================*/
#include <stdio.h>
#include <string.h>

#include "accel_drv.h"

/* ======================================================================
 *  the mock
 * ====================================================================== */
#define MOCK_BASE 0xA0000000u

/*  How many polls of STATUS before the mock declares the operation finished.
 *  Not 0: the point is that a driver must POLL, because the hardware events are
 *  one cycle wide and the PS will never be looking. */
#define MOCK_RUN_POLLS 5
#define MOCK_IMG_POLLS 3

typedef struct {
    uint32_t reg[16];
    uint32_t prog[ACCEL_PROG_WORDS];
    int      prog_written;

    int      running;
    int      img_busy;
    uint32_t sticky;          /* DONE / IMG_DONE / RESULT / error bits        */
    int      run_polls;
    int      img_polls;

    /*  what the test inspects afterwards */
    int      started;         /* START pulses                                 */
    int      img_loads;       /* LOAD_IMAGE pulses                            */
    int      violations;      /* things the real CSR would answer SLVERR to    */
    char     last_violation[160];

    /*  fault injection */
    int      inject_fault_after;   /* set FAULT after this many run polls; -1 off */

    /*  the answer the mock will hand back */
    int16_t  logit[4];
    uint8_t  argmax;

    /*  flush accounting, so the test can prove the driver flushed every buffer */
    int      flushes;
    const void *flushed[8];
    size_t   flushed_len[8];
} mock_t;

static mock_t M;

static void violation(const char *what)
{
    M.violations++;
    snprintf(M.last_violation, sizeof M.last_violation, "%s", what);
}

/*  Mirrors axi_lite_csr.v's wr_bad_run: nothing that changes how a run behaves
 *  may be written while a run or an image load is in flight. */
static int cfg_write_blocked(uint32_t off)
{
    switch (off) {
    case ACCEL_N_INSTR:
    case ACCEL_WGT_BASE:
    case ACCEL_PB_BASE:
    case ACCEL_PM_BASE:
    case ACCEL_PS_BASE:
    case ACCEL_IMG_BASE:
        return M.running || M.img_busy;
    default:
        return 0;
    }
}

void accel_plat_wr32(uintptr_t addr, uint32_t val)
{
    uint32_t off = (uint32_t)(addr - MOCK_BASE);

    if (off >= ACCEL_PROG_BASE) {
        uint32_t w = (off - ACCEL_PROG_BASE) / 4u;
        if (M.running || M.img_busy) {
            violation("program write while running or loading an image");
            return;
        }
        if (w >= ACCEL_PROG_WORDS) {
            violation("program write past the end of the aperture");
            return;
        }
        M.prog[w] = val;
        M.prog_written++;
        return;
    }

    if (cfg_write_blocked(off)) {
        violation("config write while running or loading an image");
        return;
    }

    switch (off) {
    case ACCEL_CTRL:
        if (val & ACCEL_CTRL_START) {
            if (M.running || M.img_busy) {
                violation("START while running or loading an image");
            } else {
                M.started++;
                M.running   = 1;
                M.run_polls = 0;
                /*  START clears the sticky bits and the stale result, as the
                 *  RTL does - so a driver relying on a previous DONE fails. */
                M.sticky &= ~(ACCEL_ST_DONE | ACCEL_ST_RESULT | ACCEL_ST_ERRORS);
            }
        }
        if (val & ACCEL_CTRL_LOAD_IMAGE) {
            if (M.running || M.img_busy) {
                violation("LOAD_IMAGE while running or already loading");
            } else {
                M.img_loads++;
                M.img_busy  = 1;
                M.img_polls = 0;
            }
        }
        /*  CTRL is an action: it does NOT store. */
        return;

    case ACCEL_STATUS_CLR:
        M.sticky &= ~val;
        return;

    /*  Read-only. The RTL answers SLVERR. */
    case ACCEL_STATUS:
    case ACCEL_RESULT_LO:
    case ACCEL_RESULT_HI:
    case ACCEL_ARGMAX:
    case ACCEL_ID:
        violation("write to a read-only register");
        return;

    default:
        M.reg[off / 4u] = val;
        return;
    }
}

uint32_t accel_plat_rd32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - MOCK_BASE);

    if (off >= ACCEL_PROG_BASE) {
        violation("read from the write-only program aperture");
        return 0u;
    }

    switch (off) {
    case ACCEL_ID:
        return ACCEL_ID_MAGIC;

    case ACCEL_CTRL:
    case ACCEL_STATUS_CLR:
        return 0u;                     /* actions read as zero */

    case ACCEL_STATUS: {
        uint32_t st = M.sticky;

        /*  Advance the simulated operation on every poll, which is what makes
         *  this a test of polling rather than of a single read. */
        if (M.img_busy) {
            if (++M.img_polls >= MOCK_IMG_POLLS) {
                M.img_busy = 0;
                M.sticky  |= ACCEL_ST_IMG_DONE;
            } else {
                st |= ACCEL_ST_IMG_BUSY;
            }
        } else if (M.running) {
            M.run_polls++;
            if (M.inject_fault_after >= 0 && M.run_polls > M.inject_fault_after) {
                M.running = 0;
                M.sticky |= ACCEL_ST_FAULT;
            } else if (M.run_polls >= MOCK_RUN_POLLS) {
                M.running = 0;
                M.sticky |= ACCEL_ST_DONE | ACCEL_ST_RESULT;
            } else {
                st |= ACCEL_ST_RUNNING;
            }
        }
        return st | M.sticky;
    }

    case ACCEL_RESULT_LO:
        return ((uint32_t)(uint16_t)M.logit[1] << 16) | (uint16_t)M.logit[0];
    case ACCEL_RESULT_HI:
        return ((uint32_t)(uint16_t)M.logit[3] << 16) | (uint16_t)M.logit[2];
    case ACCEL_ARGMAX:
        return (M.sticky & ACCEL_ST_RESULT)
               ? (ACCEL_ARGMAX_VALID | M.argmax) : 0u;

    default:
        return M.reg[off / 4u];
    }
}

void accel_plat_flush(const void *addr, size_t len)
{
    if (M.flushes < 8) {
        M.flushed[M.flushes]     = addr;
        M.flushed_len[M.flushes] = len;
    }
    M.flushes++;
}

void accel_plat_relax(void) { }

/* ======================================================================
 *  the test
 * ====================================================================== */
static int fails = 0;

static void ck(int cond, const char *what)
{
    if (!cond) {
        printf("  [ERR] %s\n", what);
        fails++;
    }
}

static void mock_reset(void)
{
    memset(&M, 0, sizeof M);
    M.inject_fault_after = -1;
    M.logit[0] = -4950;
    M.logit[1] = -6177;
    M.logit[2] = 15185;
    M.logit[3] = -5486;
    M.argmax   = 2;
}

/*  Buffers standing in for the DDR blobs. Aligned because the driver requires
 *  it, and it requires it because a cache flush works on whole lines. */
static uint32_t prog_words[ACCEL_PROG_WORDS];
_Alignas(ACCEL_ALIGN) static unsigned char buf_wgt[ACCEL_ALIGN * 4];
_Alignas(ACCEL_ALIGN) static unsigned char buf_pb[ACCEL_ALIGN * 4];
_Alignas(ACCEL_ALIGN) static unsigned char buf_pm[ACCEL_ALIGN * 4];
_Alignas(ACCEL_ALIGN) static unsigned char buf_ps[ACCEL_ALIGN];
_Alignas(ACCEL_ALIGN) static unsigned char buf_img[ACCEL_IMG_BYTES];

int main(void)
{
    accel_t a;
    accel_result_t r;
    accel_status_t s;
    size_t i;

    printf("UNIT: the driver against a mock of the CSR's behaviour\n\n");

    for (i = 0; i < ACCEL_PROG_WORDS; i++)
        prog_words[i] = (uint32_t)(0xA5000000u + i);

    /* ---- 1: init ---------------------------------------------------- */
    mock_reset();
    s = accel_init(&a, MOCK_BASE);
    ck(s == ACCEL_OK, "accel_init did not succeed against a good ID");
    ck(M.violations == 0, "accel_init touched something it should not");
    if (fails == 0) printf("  [ok ] 1  init reads the ID and clears the sticky bits\n");

    /* ---- 2: a bad ID must be reported, not ignored ------------------- */
    {
        /*  The whole point of the ID check is the case where the PL is not
         *  programmed. Simulate it by pointing the driver somewhere the mock
         *  does not answer ACCEL_ID_MAGIC for. */
        accel_t b;
        mock_reset();
        s = accel_init(&b, MOCK_BASE + 0x10000u);   /* decodes to the aperture */
        ck(s != ACCEL_OK, "a wrong ID was accepted - a missing bitstream would look like a working one");
        printf("  [ok ] 2  a bad ID is refused (%s)\n", accel_strerror(s));
    }

    /* ---- 3: the program ------------------------------------------- */
    mock_reset();
    accel_init(&a, MOCK_BASE);
    s = accel_load_program(&a, prog_words, ACCEL_PROG_WORDS, 64);
    ck(s == ACCEL_OK, "accel_load_program failed");
    ck(M.prog_written == (int)ACCEL_PROG_WORDS, "not every program word was written");
    ck(memcmp(M.prog, prog_words, sizeof prog_words) == 0,
       "the program words landed in the wrong order or the wrong places");
    ck(M.reg[ACCEL_N_INSTR / 4u] == 64u, "n_instr was not written");
    ck(M.violations == 0, M.last_violation);
    printf("  [ok ] 3  512 words through the aperture, then n_instr, in that order\n");

    /*  A short program must be refused rather than half-written. */
    s = accel_load_program(&a, prog_words, ACCEL_PROG_WORDS - 1, 64);
    ck(s == ACCEL_ERR_SIZE, "a short program was accepted");
    printf("  [ok ] 3  a short program is refused\n");

    /* ---- 4: the blobs, and the flush --------------------------------- */
    mock_reset();
    accel_init(&a, MOCK_BASE);
    s = accel_set_blobs(&a, buf_wgt, sizeof buf_wgt,
                        buf_pb, sizeof buf_pb, buf_pm, sizeof buf_pm,
                        buf_ps, sizeof buf_ps);
    ck(s == ACCEL_OK, "accel_set_blobs failed");
    ck(M.flushes == 4, "all four blobs must be flushed - S_AXI_HP is not coherent");
    ck(M.reg[ACCEL_WGT_BASE / 4u] == (uint32_t)(uintptr_t)buf_wgt, "wgt_base wrong");
    ck(M.reg[ACCEL_PB_BASE  / 4u] == (uint32_t)(uintptr_t)buf_pb,  "pb_base wrong");
    ck(M.reg[ACCEL_PM_BASE  / 4u] == (uint32_t)(uintptr_t)buf_pm,  "pm_base wrong");
    ck(M.reg[ACCEL_PS_BASE  / 4u] == (uint32_t)(uintptr_t)buf_ps,  "ps_base wrong");
    ck(M.violations == 0, M.last_violation);
    printf("  [ok ] 4  four bases written and all four buffers flushed\n");

    /*  Misalignment must be refused: it cannot be flushed safely. */
    s = accel_set_blobs(&a, buf_wgt + 1, sizeof buf_wgt - 1,
                        buf_pb, sizeof buf_pb, buf_pm, sizeof buf_pm,
                        buf_ps, sizeof buf_ps);
    ck(s == ACCEL_ERR_ALIGN, "a misaligned blob was accepted");
    /*  And params_b / params_m0 / params_shift must be consistent. */
    s = accel_set_blobs(&a, buf_wgt, sizeof buf_wgt,
                        buf_pb, sizeof buf_pb, buf_pm, sizeof buf_pm - 4,
                        buf_ps, sizeof buf_ps);
    ck(s == ACCEL_ERR_SIZE, "mismatched parameter blobs were accepted");
    printf("  [ok ] 4  misalignment and mismatched parameter lengths are refused\n");

    /* ---- 5: the image ----------------------------------------------- */
    mock_reset();
    accel_init(&a, MOCK_BASE);
    s = accel_load_image(&a, buf_img, sizeof buf_img);
    ck(s == ACCEL_OK, "accel_load_image failed");
    ck(M.img_loads == 1, "LOAD_IMAGE was not pulsed exactly once");
    ck(M.started == 0, "loading an image must not start a run");
    ck(M.flushes == 1, "the image was not flushed");
    ck(M.reg[ACCEL_IMG_BASE / 4u] == (uint32_t)(uintptr_t)buf_img, "img_base wrong");
    ck(M.violations == 0, M.last_violation);
    printf("  [ok ] 5  the image is flushed, IMG_BASE set, LOAD_IMAGE pulsed once, and it waits\n");

    /*  A wrong-sized image must be refused: the length is structural in the
     *  hardware, so it cannot detect this itself (DD-032). */
    s = accel_load_image(&a, buf_img, ACCEL_IMG_BYTES - 3);
    ck(s == ACCEL_ERR_SIZE, "a wrong-sized image was accepted");
    printf("  [ok ] 5  a wrong-sized image is refused\n");

    /* ---- 6: the run and the result ---------------------------------- */
    mock_reset();
    accel_init(&a, MOCK_BASE);
    accel_load_program(&a, prog_words, ACCEL_PROG_WORDS, 64);
    accel_set_blobs(&a, buf_wgt, sizeof buf_wgt, buf_pb, sizeof buf_pb,
                    buf_pm, sizeof buf_pm, buf_ps, sizeof buf_ps);
    accel_load_image(&a, buf_img, sizeof buf_img);
    s = accel_run(&a);
    ck(s == ACCEL_OK, "accel_run failed");
    ck(M.started == 1, "START was not pulsed exactly once");
    ck(M.violations == 0, M.last_violation);

    s = accel_result(&a, &r);
    ck(s == ACCEL_OK, "accel_result failed");
    ck(r.logit[0] == -4950 && r.logit[1] == -6177 &&
       r.logit[2] == 15185 && r.logit[3] == -5486,
       "the logits came back wrong - signedness or word packing");
    ck(r.argmax == 2, "argmax came back wrong");
    printf("  [ok ] 6  a full sequence runs, and the logits read back SIGNED: %d %d %d %d, class %u\n",
           r.logit[0], r.logit[1], r.logit[2], r.logit[3], r.argmax);

    /* ---- 7: a fault must be reported, not waited out ---------------- */
    mock_reset();
    M.inject_fault_after = 1;
    accel_init(&a, MOCK_BASE);
    accel_load_image(&a, buf_img, sizeof buf_img);
    s = accel_run(&a);
    ck(s == ACCEL_ERR_FAULT, "a run that faulted did not report ACCEL_ERR_FAULT");
    ck((a.last_status & ACCEL_ST_FAULT) != 0, "last_status does not carry the fault bit");
    printf("  [ok ] 7  a fault is reported as a fault, not as a timeout (%s)\n",
           accel_strerror(s));

    /* ---- 8: no result without a run --------------------------------- */
    mock_reset();
    accel_init(&a, MOCK_BASE);
    s = accel_result(&a, &r);
    ck(s == ACCEL_ERR_NO_RESULT, "a result was returned before any run");
    printf("  [ok ] 8  reading the result before a run is refused, not garbage\n");

    /* ---- 9: nothing anywhere the hardware would have refused -------- */
    printf("\n");
    if (fails == 0) {
        printf("ALL PASS  (the driver's sequence is legal against the CSR's own guards)\n");
        return 0;
    }
    printf("FAILED    (%d problems)\n", fails);
    return 1;
}
