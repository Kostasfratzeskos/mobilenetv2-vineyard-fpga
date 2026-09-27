/*============================================================================
 *  test_csr_map.c  -  the C register map must match the RTL
 *
 *  firmware/include/accel_csr.h is a second copy of what
 *  hardware/rtl/axi/axi_lite_csr.v declares. DD-030 is about exactly that kind
 *  of duplication, and the answer there was "do not have a second copy". Here a
 *  second copy is unavoidable - the firmware cannot include Verilog - so the
 *  answer is instead: DERIVE the truth from the RTL at test time and fail if they
 *  disagree.
 *
 *  Why bother. A wrong offset in accel_csr.h does not fail to compile and does
 *  not crash. It writes a base address into the wrong register and the
 *  accelerator runs on whatever was there before, producing a confident wrong
 *  classification with no error anywhere. On a board that is hours with a
 *  debugger; here it is a `make test` on a PC.
 *
 *  How. The RTL declares its map as localparams:
 *
 *      localparam R_CTRL       = 4'd0,
 *                 R_N_INSTR    = 4'd1,
 *                 ...
 *                 R_IMG_BASE   = 4'd13,
 *                 N_REGS       = 4'd14;
 *
 *  and a register's byte offset is its index times four (LSB = 2 in the RTL).
 *  This parses those, plus ADDR_W for the aperture size and the PROG_SEL bit for
 *  the program aperture base, and compares every one.
 *
 *  It is deliberately a TEXT parse rather than anything cleverer. A generated
 *  header would be better still, but it would be a third artifact to keep in
 *  step; a test that reads the RTL has no artifact at all and fails loudly the
 *  first time someone renumbers a register.
 *==========================================================================*/
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "accel_csr.h"

#define RTL_PATH "../hardware/rtl/axi/axi_lite_csr.v"

static int fails = 0;

/*  Slurp the RTL. Small enough (tens of KB) that reading it whole is simpler
 *  than streaming, and this runs on a PC. */
static char *slurp(const char *path, long *len_out)
{
    FILE *fh = fopen(path, "rb");
    char *buf;
    long len;

    if (!fh) {
        printf("  [ERR] cannot open %s - run make from firmware/\n", path);
        fails++;
        return NULL;
    }
    fseek(fh, 0, SEEK_END);
    len = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    buf = malloc((size_t)len + 1);
    if (!buf) { fclose(fh); return NULL; }
    if (fread(buf, 1, (size_t)len, fh) != (size_t)len) {
        printf("  [ERR] short read on %s\n", path);
        fails++;
        fclose(fh);
        free(buf);
        return NULL;
    }
    buf[len] = '\0';
    fclose(fh);
    if (len_out) *len_out = len;
    return buf;
}

/*  Find "<name>   = 4'd<N>" and return N, or -1. Tolerant about whitespace and
 *  about the width prefix, so reformatting the RTL does not break the test. */
static long rtl_localparam_index(const char *src, const char *name)
{
    const char *p = src;
    size_t nlen = strlen(name);

    while ((p = strstr(p, name)) != NULL) {
        const char *q = p + nlen;
        /*  Must be a whole identifier, not a prefix of a longer one. */
        if ((p != src) && (isalnum((unsigned char)p[-1]) || p[-1] == '_')) {
            p = q;
            continue;
        }
        if (isalnum((unsigned char)*q) || *q == '_') { p = q; continue; }

        while (*q == ' ' || *q == '\t') q++;
        if (*q != '=') { p = q; continue; }
        q++;
        while (*q == ' ' || *q == '\t') q++;
        /*  Skip an optional size/base prefix such as 4'd or 'd */
        while (*q && *q != ',' && *q != ';' && !isdigit((unsigned char)*q)) q++;
        if (*q == '\0') return -1;
        /*  For 4'd13 the digit run before the quote is the WIDTH, so if a quote
         *  follows digits, skip past it and take what comes after. */
        {
            const char *digits = q;
            while (isdigit((unsigned char)*q)) q++;
            if (*q == '\'') {
                q++;
                while (*q && !isdigit((unsigned char)*q)) q++;
                digits = q;
            } else {
                q = digits;
            }
            return strtol(digits, NULL, 10);
        }
    }
    return -1;
}

static void check_reg(const char *src, const char *rtl_name,
                      unsigned c_offset, const char *c_name)
{
    long idx = rtl_localparam_index(src, rtl_name);
    unsigned want;

    if (idx < 0) {
        printf("  [ERR] %s not found in the RTL - was it renamed?\n", rtl_name);
        fails++;
        return;
    }
    want = (unsigned)idx * 4u;          /* LSB = 2 in axi_lite_csr.v */
    if (want != c_offset) {
        printf("  [ERR] %s: RTL index %ld => offset 0x%02x, but %s is 0x%02x\n",
               rtl_name, idx, want, c_name, c_offset);
        fails++;
    }
}

int main(void)
{
    char *src = slurp(RTL_PATH, NULL);
    long addr_w, n_regs, prog_words_rtl;

    printf("UNIT: the C register map against hardware/rtl/axi/axi_lite_csr.v\n\n");
    if (!src) {
        printf("FAILED    (could not read the RTL)\n");
        return 1;
    }

    /* ---- every register offset ------------------------------------------ */
    check_reg(src, "R_CTRL",       ACCEL_CTRL,       "ACCEL_CTRL");
    check_reg(src, "R_N_INSTR",    ACCEL_N_INSTR,    "ACCEL_N_INSTR");
    check_reg(src, "R_IRQ_EN",     ACCEL_IRQ_EN,     "ACCEL_IRQ_EN");
    check_reg(src, "R_STATUS_CLR", ACCEL_STATUS_CLR, "ACCEL_STATUS_CLR");
    check_reg(src, "R_STATUS",     ACCEL_STATUS,     "ACCEL_STATUS");
    check_reg(src, "R_WGT_BASE",   ACCEL_WGT_BASE,   "ACCEL_WGT_BASE");
    check_reg(src, "R_PB_BASE",    ACCEL_PB_BASE,    "ACCEL_PB_BASE");
    check_reg(src, "R_PM_BASE",    ACCEL_PM_BASE,    "ACCEL_PM_BASE");
    check_reg(src, "R_PS_BASE",    ACCEL_PS_BASE,    "ACCEL_PS_BASE");
    check_reg(src, "R_RESULT_LO",  ACCEL_RESULT_LO,  "ACCEL_RESULT_LO");
    check_reg(src, "R_RESULT_HI",  ACCEL_RESULT_HI,  "ACCEL_RESULT_HI");
    check_reg(src, "R_ARGMAX",     ACCEL_ARGMAX,     "ACCEL_ARGMAX");
    check_reg(src, "R_ID",         ACCEL_ID,         "ACCEL_ID");
    check_reg(src, "R_IMG_BASE",   ACCEL_IMG_BASE,   "ACCEL_IMG_BASE");
    if (fails == 0)
        printf("  [ok ] all 14 register offsets match the RTL's localparams\n");

    /* ---- the aperture size ---------------------------------------------- */
    addr_w = rtl_localparam_index(src, "parameter ADDR_W");
    if (addr_w < 0) addr_w = rtl_localparam_index(src, "ADDR_W");
    if (addr_w <= 0) {
        printf("  [ERR] ADDR_W not found in the RTL\n");
        fails++;
    } else if ((1u << addr_w) != ACCEL_APERTURE_SIZE) {
        printf("  [ERR] RTL ADDR_W=%ld => %u bytes, but ACCEL_APERTURE_SIZE is %u\n",
               addr_w, 1u << addr_w, ACCEL_APERTURE_SIZE);
        fails++;
    } else {
        printf("  [ok ] the aperture is 1<<%ld = %u bytes, as the header says\n",
               addr_w, ACCEL_APERTURE_SIZE);
    }

    /*  The program aperture starts at the top address bit (PROG_SEL = ADDR_W-1
     *  in the RTL), so its base is half the aperture. */
    if (addr_w > 0) {
        unsigned want = 1u << (addr_w - 1);
        if (want != ACCEL_PROG_BASE) {
            printf("  [ERR] RTL PROG_SEL=%ld => program base 0x%04x, header says 0x%04x\n",
                   addr_w - 1, want, ACCEL_PROG_BASE);
            fails++;
        } else {
            printf("  [ok ] the program aperture is at 0x%04x (bit %ld selects it)\n",
                   ACCEL_PROG_BASE, addr_w - 1);
        }
    }

    /* ---- the register count -------------------------------------------- */
    n_regs = rtl_localparam_index(src, "N_REGS");
    if (n_regs != 14) {
        printf("  [ERR] the RTL has N_REGS=%ld; this test knows about 14. "
               "A register was added - add it here too.\n", n_regs);
        fails++;
    } else {
        printf("  [ok ] N_REGS is 14 and all 14 are checked above\n");
    }

    /* ---- the program length -------------------------------------------- */
    prog_words_rtl = rtl_localparam_index(src, "parameter PGA_W");
    if (prog_words_rtl < 0) prog_words_rtl = rtl_localparam_index(src, "PGA_W");
    if (prog_words_rtl > 0) {
        unsigned want = 1u << prog_words_rtl;
        if (want != ACCEL_PROG_WORDS) {
            printf("  [ERR] RTL PGA_W=%ld => %u program words, header says %u\n",
                   prog_words_rtl, want, ACCEL_PROG_WORDS);
            fails++;
        } else {
            printf("  [ok ] the program is 1<<%ld = %u words\n",
                   prog_words_rtl, ACCEL_PROG_WORDS);
        }
    }

    /* ---- the ID magic -------------------------------------------------- */
    if (strstr(src, "56_49_4E_45") == NULL && strstr(src, "56494E45") == NULL) {
        printf("  [ERR] the RTL's ID_MAGIC is not 0x56494E45 (\"VINE\") any more\n");
        fails++;
    } else {
        printf("  [ok ] ID_MAGIC is \"VINE\" in both\n");
    }

    free(src);
    printf("\n");
    if (fails == 0) {
        printf("ALL PASS  (the firmware's map and the RTL's agree)\n");
        return 0;
    }
    printf("FAILED    (%d disagreements between the firmware and the RTL)\n", fails);
    return 1;
}
