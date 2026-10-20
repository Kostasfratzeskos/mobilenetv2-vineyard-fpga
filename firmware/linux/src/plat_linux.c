/*============================================================================
 *  plat_linux.c  -  the five platform hooks, for a Linux process on the A53
 *
 *  The same contract as firmware/src/plat_zynq.c, met differently:
 *
 *    wr32 / rd32   volatile 32-bit accesses through the UIO mapping of the CSR.
 *                  The `addr` the driver passes is the mapping's VIRTUAL
 *                  address plus a register offset - accel_init is handed the
 *                  pointer vine_uio_open returned - so nothing is translated.
 *
 *    flush         a DSB, and not a cache operation. The DMA region is mapped
 *                  Device-nGnRnE and nowhere else (dmaregion.h), so no cache
 *                  holds any of it; what IS still needed is ordering. Writes to
 *                  the region and the CSR write that starts the DMA go to two
 *                  different endpoints, DDR and the PL, and the architecture
 *                  orders Device accesses only within one peripheral. The DSB
 *                  waits for every earlier write to COMPLETE - with no early
 *                  write acknowledgement, that is DDR accepting it - before
 *                  the driver's next access, the IMG_BASE write, is issued.
 *
 *    relax         a YIELD hint. The poll is a busy-wait, as on baremetal: the
 *                  run is ~6 ms, shorter than a scheduler tick, so sleeping
 *                  would add latency and save nothing worth having.
 *
 *    phys          through the one region this process mapped, and nothing
 *                  else. A pointer outside it - a malloc'd buffer, a stack
 *                  array - is refused, and the driver turns that into
 *                  ACCEL_ERR_ADDR before any register is written.
 *
 *  Compiles on the host too (with a portable barrier), so `make test` can at
 *  least prove it builds; it only runs on the board.
 *==========================================================================*/
#include "plat_linux.h"

#include "accel_drv.h"

_Static_assert(ACCEL_PHYS_NONE == DMAREGION_NO_PHYS,
               "the driver and the region must agree on 'no physical address'");

static const dmaregion_t *g_region;

void plat_linux_set_region(const dmaregion_t *r)
{
    g_region = r;
}

void accel_plat_wr32(uintptr_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
}

uint32_t accel_plat_rd32(uintptr_t addr)
{
    return *(volatile uint32_t *)addr;
}

void accel_plat_flush(const void *addr, size_t len)
{
    (void)addr;
    (void)len;
#if defined(__aarch64__)
    __asm__ volatile("dsb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}

void accel_plat_relax(void)
{
#if defined(__aarch64__)
    __asm__ volatile("yield" ::: "memory");
#endif
}

uint64_t accel_plat_phys(const void *addr, size_t len)
{
    if (g_region == NULL)
        return ACCEL_PHYS_NONE;
    return dmaregion_phys(g_region, addr, len);
}
