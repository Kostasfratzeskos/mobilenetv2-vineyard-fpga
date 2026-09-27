/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_XPARAMETERS_H
#define STUB_XPARAMETERS_H

#define XPAR_XUARTPS_0_DEVICE_ID   0
/*  Deliberately NOT defining XPAR_ACCEL_AXI_0_BASEADDR: main.c has a fallback
 *  for the case where the BSP does not define it, and that fallback is the path
 *  worth compiling, since the other one is trivial. */

#endif
