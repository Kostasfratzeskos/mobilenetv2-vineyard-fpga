/*============================================================================
 *  vine_uio.h  -  the accelerator, as a Linux process sees it
 *
 *  One UIO device, two maps, both declared in firmware/linux/petalinux/
 *  vinecam.dtsi:
 *
 *      map0   the AXI-Lite CSR, 8 KB at 0xA000_0000 (scripts/make_bd.tcl)
 *      map1   the DMA region, the `no-map` reserved-memory carve-out
 *
 *  vine_uio_open finds the device by name, maps both, and refuses a region the
 *  accelerator could not actually use - each refusal names its cause, because
 *  the alternative is a run that completes on the wrong bytes:
 *
 *    * not below 2 GB: S_AXI_HP0_FPD reaches DDR_LOW, 0 to 0x7FFF_FFFF, and
 *      nothing else that is memory (build/bd_<cfg>/address_map.rpt)
 *    * not page-aligned: the mapping, and the allocator, assume it
 *    * listed as "System RAM" in /proc/iomem: the kernel is using it, so the
 *      carve-out is missing or lacks `no-map`, and dmaregion.h's argument that
 *      no cache can hold a line of it no longer holds
 *
 *  If the device exists in the device tree but no driver took it - the
 *  bootargs lack uio_pdrv_genirq.of_id=generic-uio - it binds uio_pdrv_genirq
 *  to it through driver_override, says so, and carries on.
 *==========================================================================*/
#ifndef VINE_UIO_H
#define VINE_UIO_H

#include <stddef.h>
#include <stdint.h>

/*  The node's name in vinecam.dtsi, which is what the UIO name defaults to. */
#define VINE_UIO_NAME  "vine-accel"

typedef struct {
    int                fd;
    int                index;          /* the N of /dev/uioN                 */
    volatile uint8_t  *csr;            /* map0                               */
    size_t             csr_len;
    uint64_t           csr_phys;
    volatile uint8_t  *dma;            /* map1                               */
    size_t             dma_len;
    uint64_t           dma_phys;
} vine_uio_t;

/*  0, or -1 with the reason in err. */
int  vine_uio_open(vine_uio_t *u, const char *name, char *err, size_t errlen);
void vine_uio_close(vine_uio_t *u);

#endif /* VINE_UIO_H */
