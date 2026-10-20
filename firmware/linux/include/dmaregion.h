/*============================================================================
 *  dmaregion.h  -  the one piece of DDR the accelerator is allowed to read
 *
 *  Under Linux, the four blobs and the image cannot live in ordinary process
 *  memory. A malloc'd buffer is virtual, scattered over physical pages the
 *  kernel chose, and cached by the APU - and S_AXI_HP0_FPD neither translates
 *  virtual addresses nor snoops caches. So the device tree carves a region out
 *  of DDR before Linux ever sees it (firmware/linux/petalinux/vinecam.dtsi):
 *
 *      reserved-memory { vine-dma@38000000 { no-map; reg = <... 16 MB>; } }
 *
 *  and exposes it, with the CSR, through one UIO device. This file is what the
 *  application does with that region: hand out pieces of it, translate their
 *  addresses for accel_plat_phys, and write into it safely.
 *
 *  ---- why no cache flush is needed, and why that is not an assumption -----
 *
 *  `no-map` removes the region from the kernel's linear map, so the ONLY
 *  mapping of it anywhere is this process's, through UIO - and UIO maps
 *  physical memory with pgprot_noncached, which on arm64 is Device-nGnRnE. No
 *  cache ever holds a line of it, so there is nothing for the DMA to miss: the
 *  baremetal Xil_DCacheFlushRange becomes a barrier (plat_linux.c), which waits
 *  for the writes to reach DDR before the CSR write that starts the DMA.
 *
 *  Without `no-map` that argument fails silently: the kernel's linear map would
 *  still cover the region as cacheable, a speculative fill could put a line of
 *  it in L2, and two mappings with different attributes is exactly the case the
 *  architecture does not promise anything about. vine_uio.c checks /proc/iomem
 *  so a device tree that forgot `no-map` is refused, not discovered later.
 *
 *  ---- why the writes are 8 bytes at a time ------------------------------
 *
 *  Device memory faults on an unaligned access, and glibc's memcpy relies on
 *  unaligned and overlapping stores for its head and tail - and memset uses
 *  DC ZVA, which faults on Device memory outright. dmaregion_write therefore
 *  stores aligned 64-bit words through a volatile pointer, which the compiler
 *  may neither merge, split nor turn back into a memcpy call.
 *==========================================================================*/
#ifndef DMAREGION_H
#define DMAREGION_H

#include <stddef.h>
#include <stdint.h>

/*  Same value as the driver's ACCEL_PHYS_NONE; plat_linux.c asserts it. */
#define DMAREGION_NO_PHYS  UINT64_MAX

/*  Each allocation starts on a page. 4 KB is more than the 64 bytes the driver
 *  needs, and it means no AXI burst from one buffer can cross into the next
 *  buffer's 4 KB page - a burst may not cross a 4 KB boundary anyway. */
#define DMAREGION_ALIGN    4096u

typedef struct {
    volatile uint8_t *virt;     /* this process's mapping                     */
    uint64_t          phys;     /* where it starts in DDR                     */
    size_t            size;
    size_t            used;     /* bump allocator: nothing is ever freed      */
} dmaregion_t;

/*  0, or -1 if the region is unusable: not page-aligned, or empty. */
int      dmaregion_init(dmaregion_t *r, volatile void *virt, uint64_t phys,
                        size_t size);

/*  len bytes, DMAREGION_ALIGN-aligned, or NULL when the region is full. */
void    *dmaregion_alloc(dmaregion_t *r, size_t len);

/*  The physical address of [p, p + len), or DMAREGION_NO_PHYS unless ALL of it
 *  is inside the region. accel_plat_phys is this. */
uint64_t dmaregion_phys(const dmaregion_t *r, const void *p, size_t len);

/*  Copy into the region with aligned 64-bit stores (and byte stores for a
 *  tail). dst must be 8-byte aligned: -1 if not, 0 on success. */
int      dmaregion_write(volatile void *dst, const void *src, size_t len);

/*  Read the region back and compare: the offset of the first differing byte,
 *  or len if it all matches. A mapping that does not reach real memory - the
 *  wrong `reg`, a missing carve-out - shows up here, at start-up, instead of as
 *  a wrong class. */
size_t   dmaregion_verify(const volatile void *dst, const void *src, size_t len);

#endif /* DMAREGION_H */
