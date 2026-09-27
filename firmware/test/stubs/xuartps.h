/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_XUARTPS_H
#define STUB_XUARTPS_H

#include "xil_types.h"

#define XUARTPS_OPER_MODE_NORMAL 0x00U

typedef struct {
    u16      DeviceId;
    UINTPTR  BaseAddress;
    u32      InputClockHz;
} XUartPs_Config;

typedef struct {
    XUartPs_Config Config;
} XUartPs;

XUartPs_Config *XUartPs_LookupConfig(u16 DeviceId);
int   XUartPs_CfgInitialize(XUartPs *p, XUartPs_Config *cfg, UINTPTR base);
u32   XUartPs_SetBaudRate(XUartPs *p, u32 baud);
void  XUartPs_SetOperMode(XUartPs *p, u8 mode);
u32   XUartPs_Recv(XUartPs *p, u8 *buf, u32 len);
u32   XUartPs_Send(XUartPs *p, u8 *buf, u32 len);

#endif
