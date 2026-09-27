/*============================================================================
 *  plat_zynq.c  -  the four platform hooks, for a baremetal ZU+ APU
 *
 *  Not built by firmware/Makefile: it needs a standalone BSP generated from
 *  build/bd_<cfg>/accel_bd_wrapper.xsa. See README.md for the Vitis side. The
 *  tests supply their own versions of these four functions, which is what lets
 *  accel_drv.c be tested on a PC.
 *
 *  ---- the flush is the only one with anything to get wrong ---------------
 *
 *  S_AXI_HP0_FPD does not snoop the APU caches. After the PS writes a blob the
 *  bytes are dirty in L1/L2 and DDR still holds whatever was there before; the
 *  DMA reads DDR. So the flush is not an optimisation, it is the difference
 *  between the accelerator seeing this image and seeing the last one - with no
 *  error anywhere, because a stale read is a perfectly valid AXI transaction.
 *
 *  Xil_DCacheFlushRange cleans AND invalidates the range, which is what is
 *  wanted here: clean so the DMA sees the data, invalidate because nothing else
 *  should be holding these lines afterwards.
 *
 *  Note what is NOT needed: the accelerator writes nothing to DDR. Its only
 *  outputs are the logits and argmax, which come back through the CSR as
 *  register reads, and those are Device-nGnRnE memory - not cached. So there is
 *  no invalidate-before-read half of this problem, which is the usual other half
 *  of a DMA driver and is absent here by design.
 *==========================================================================*/
#include "accel_drv.h"

#include "xil_cache.h"
#include "xil_io.h"

void accel_plat_wr32(uintptr_t addr, uint32_t val)
{
    Xil_Out32((UINTPTR)addr, val);
}

uint32_t accel_plat_rd32(uintptr_t addr)
{
    return Xil_In32((UINTPTR)addr);
}

void accel_plat_flush(const void *addr, size_t len)
{
    Xil_DCacheFlushRange((INTPTR)addr, (unsigned)len);
}

void accel_plat_relax(void)
{
    /*  Nothing to yield to on a single-threaded baremetal app. Left as a
     *  function rather than removed so a future version can put the core in
     *  WFI on the interrupt (DD-031 wired irq to pl_ps_irq0 for exactly that)
     *  without touching the driver. */
}
