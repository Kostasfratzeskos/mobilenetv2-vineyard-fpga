/*============================================================================
 *  plat_linux.h  -  the driver's platform hooks, for a Linux process
 *
 *  accel_drv.c calls five functions it does not define (accel_drv.h). For
 *  baremetal they are firmware/src/plat_zynq.c; for Linux they are
 *  plat_linux.c, and the only state they need is which region the DMA may be
 *  pointed at - everything else is a volatile access or a barrier.
 *==========================================================================*/
#ifndef PLAT_LINUX_H
#define PLAT_LINUX_H

#include "dmaregion.h"

/*  The region accel_plat_phys translates through. Until it is set, every
 *  buffer is refused - which is the right answer for a process that has not
 *  mapped the region yet. */
void plat_linux_set_region(const dmaregion_t *r);

#endif /* PLAT_LINUX_H */
