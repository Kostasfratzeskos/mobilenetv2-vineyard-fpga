/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_XIL_PRINTF_H
#define STUB_XIL_PRINTF_H

void xil_printf(const char *fmt, ...);

#endif
