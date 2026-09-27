/*============================================================================
 *  accel_csr.h  -  the accelerator's AXI-Lite register map, as the PS sees it
 *
 *  This is the ONE place the firmware states where the registers are. It is a
 *  second copy of what hardware/rtl/axi/axi_lite_csr.v declares, which is
 *  exactly the kind of duplication DD-030 warns about - so it is not left to
 *  inspection: firmware/test/test_csr_map.c PARSES axi_lite_csr.v and fails if a
 *  single offset, bit position or size here disagrees with the RTL.
 *
 *  That test matters more than it sounds. A wrong offset here does not fail to
 *  build and does not crash; it writes a base address into the wrong register
 *  and the accelerator runs on whatever was there before. On hardware that is a
 *  plausible wrong classification with no error anywhere, and it is the single
 *  most likely mistake in this whole file. `make test` on a PC catches it.
 *
 *  ---- the map (DD-031, extended by DD-032) ------------------------------
 *
 *  Everything is 32-bit. Offsets are from the CSR base, which the block design
 *  places at 0xA000_0000 (scripts/make_bd.tcl) - but the base is a parameter to
 *  accel_init, not a constant here, because the address map belongs to the block
 *  design and not to the driver.
 *==========================================================================*/
#ifndef ACCEL_CSR_H
#define ACCEL_CSR_H

#include <stdint.h>

/* ---- register offsets --------------------------------------------------- */
#define ACCEL_CTRL          0x00u   /* W1P: bit0 START, bit1 LOAD_IMAGE       */
#define ACCEL_N_INSTR       0x04u   /* RW : [7:0] instruction count           */
#define ACCEL_IRQ_EN        0x08u   /* RW : bit0 done, bit1 any error         */
#define ACCEL_STATUS_CLR    0x0Cu   /* W1C: clears the sticky STATUS bits     */
#define ACCEL_STATUS        0x10u   /* RO : see the bits below                */
#define ACCEL_WGT_BASE      0x14u   /* RW : weights.bin      in DDR           */
#define ACCEL_PB_BASE       0x18u   /* RW : params_b.bin                      */
#define ACCEL_PM_BASE       0x1Cu   /* RW : params_m0.bin                     */
#define ACCEL_PS_BASE       0x20u   /* RW : params_shift.bin                  */
#define ACCEL_RESULT_LO     0x24u   /* RO : [15:0] logit0, [31:16] logit1     */
#define ACCEL_RESULT_HI     0x28u   /* RO : [15:0] logit2, [31:16] logit3     */
#define ACCEL_ARGMAX        0x2Cu   /* RO : [1:0] class, [2] result captured  */
#define ACCEL_ID            0x30u   /* RO : a fixed magic word                */
#define ACCEL_IMG_BASE      0x34u   /* RW : the image, HWC in DDR (DD-032)    */

/*  The program aperture: 512 words at this offset, write-only. An aperture
 *  rather than an address/data pair so the PS side is a plain loop with no
 *  pointer state to get out of step - DD-031 explains why that mattered. */
#define ACCEL_PROG_BASE     0x1000u
#define ACCEL_PROG_WORDS    512u
#define ACCEL_APERTURE_SIZE 0x2000u  /* 8 KB, i.e. the RTL's ADDR_W = 13      */

/* ---- CTRL ---------------------------------------------------------------
 *  Write-1-to-pulse. Both read back as zero: they are actions, not state.    */
#define ACCEL_CTRL_START       (1u << 0)
#define ACCEL_CTRL_LOAD_IMAGE  (1u << 1)

/* ---- STATUS -------------------------------------------------------------
 *  RUNNING and IMG_BUSY are LIVE. The rest are sticky and are cleared by
 *  writing START or by writing the matching bit to STATUS_CLR.
 *
 *  DONE is sticky for a reason worth knowing: top_seq's `done` is a ONE-CYCLE
 *  pulse, and a processor polling a register will essentially never be looking
 *  during that cycle. The same applies to the result - logit_out does not hold
 *  its output, so the CSR latches it. DD-031 has the detail. */
#define ACCEL_ST_RUNNING    (1u << 0)
#define ACCEL_ST_DONE       (1u << 1)
#define ACCEL_ST_FAULT      (1u << 2)
#define ACCEL_ST_DMA_ERROR  (1u << 3)
#define ACCEL_ST_TAG_ERROR  (1u << 4)
#define ACCEL_ST_RESULT     (1u << 5)
#define ACCEL_ST_IMG_BUSY   (1u << 6)
#define ACCEL_ST_IMG_DONE   (1u << 7)
#define ACCEL_ST_PC_SHIFT   8
#define ACCEL_ST_PC_MASK    0xFFu

/*  Every way the hardware can report that a run went wrong. `fault` alone means
 *  the accelerator gave up (watchdog, undecodable opcode, n_instr out of
 *  range); with dma_error it means the bus is why; tag_error is pw_out's own
 *  self-check (finding T-3). */
#define ACCEL_ST_ERRORS  (ACCEL_ST_FAULT | ACCEL_ST_DMA_ERROR | ACCEL_ST_TAG_ERROR)

/* ---- ARGMAX ------------------------------------------------------------- */
#define ACCEL_ARGMAX_MASK   0x3u
#define ACCEL_ARGMAX_VALID  (1u << 2)

/* ---- ID ----------------------------------------------------------------
 *  "VINE". Read it first: it is the cheapest possible proof that the aperture
 *  is mapped and the PL is programmed and clocked, before anything else is
 *  blamed. accel_axi_tb reads it first too, for the same reason. */
#define ACCEL_ID_MAGIC      0x56494E45u

/* ---- the shapes the hardware is built with -----------------------------
 *  Not configurable from here. The image size in particular is STRUCTURAL in
 *  the DMA (DD-032): there is no register for it, deliberately, because a PS
 *  that wrote the wrong pixel count would half-fill the image buffer and the
 *  run would COMPLETE, on a tensor built partly from the previous picture. */
#define ACCEL_IMG_W         224u
#define ACCEL_IMG_H         224u
#define ACCEL_IMG_C         3u
#define ACCEL_IMG_PIXELS    (ACCEL_IMG_W * ACCEL_IMG_H)          /* 50,176   */
#define ACCEL_IMG_BYTES     (ACCEL_IMG_PIXELS * ACCEL_IMG_C)     /* 150,528  */
#define ACCEL_N_CLASSES     4u

#endif /* ACCEL_CSR_H */
