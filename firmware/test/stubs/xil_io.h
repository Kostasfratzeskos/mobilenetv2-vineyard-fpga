/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_XIL_IO_H
#define STUB_XIL_IO_H

#include "xil_types.h"

void Xil_Out32(UINTPTR addr, u32 value);
u32  Xil_In32(UINTPTR addr);

#endif
