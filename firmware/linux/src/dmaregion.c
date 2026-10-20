/*============================================================================
 *  dmaregion.c  -  allocate, translate and write the accelerator's DDR region
 *
 *  See dmaregion.h. Portable C on purpose: everything here is tested on a PC by
 *  test/test_platform.c, against ordinary memory standing in for the region.
 *==========================================================================*/
#include "dmaregion.h"

#include <string.h>

int dmaregion_init(dmaregion_t *r, volatile void *virt, uint64_t phys,
                   size_t size)
{
    if (r == NULL)
        return -1;
    memset(r, 0, sizeof *r);
    if (virt == NULL || size == 0u ||
        ((uintptr_t)virt % DMAREGION_ALIGN) != 0u ||
        (phys % DMAREGION_ALIGN) != 0u)
        return -1;
    r->virt = (volatile uint8_t *)virt;
    r->phys = phys;
    r->size = size;
    return 0;
}

void *dmaregion_alloc(dmaregion_t *r, size_t len)
{
    size_t start;

    if (r == NULL || r->virt == NULL || len == 0u)
        return NULL;
    start = (r->used + DMAREGION_ALIGN - 1u) & ~(size_t)(DMAREGION_ALIGN - 1u);
    if (start > r->size || len > r->size - start)
        return NULL;
    r->used = start + len;
    /*  The cast drops `volatile` deliberately: the driver takes const void *,
     *  and only ever passes the pointer back to accel_plat_phys and the
     *  barrier. Every access to the bytes goes through dmaregion_write and
     *  dmaregion_verify, which put the qualifier back. */
    return (void *)(uintptr_t)(r->virt + start);
}

uint64_t dmaregion_phys(const dmaregion_t *r, const void *p, size_t len)
{
    uintptr_t base, a;
    size_t    off;

    if (r == NULL || r->virt == NULL || p == NULL)
        return DMAREGION_NO_PHYS;
    base = (uintptr_t)r->virt;
    a    = (uintptr_t)p;
    if (a < base)
        return DMAREGION_NO_PHYS;
    off = (size_t)(a - base);
    /*  Written so that neither comparison can overflow: off may be anything. */
    if (off > r->size || len > r->size - off)
        return DMAREGION_NO_PHYS;
    return r->phys + (uint64_t)off;
}

int dmaregion_write(volatile void *dst, const void *src, size_t len)
{
    volatile uint64_t *d = (volatile uint64_t *)dst;
    const uint8_t     *s = (const uint8_t *)src;
    size_t             i;

    if (((uintptr_t)dst & 7u) != 0u)
        return -1;

    for (i = 0; i + 8u <= len; i += 8u) {
        uint64_t v;
        memcpy(&v, s + i, 8u);         /* the SOURCE may be unaligned */
        *d++ = v;
    }
    if (i < len) {
        volatile uint8_t *db = (volatile uint8_t *)d;
        for (; i < len; i++)
            *db++ = s[i];
    }
    return 0;
}

size_t dmaregion_verify(const volatile void *dst, const void *src, size_t len)
{
    const volatile uint8_t *d = (const volatile uint8_t *)dst;
    const uint8_t          *s = (const uint8_t *)src;
    size_t                  i = 0;

    /*  Whole words where both are aligned, then bytes - the same access sizes
     *  the write used, so the check reads the region the way it was written. */
    if (((uintptr_t)dst & 7u) == 0u) {
        const volatile uint64_t *dw = (const volatile uint64_t *)dst;
        for (; i + 8u <= len; i += 8u) {
            uint64_t want, got = dw[i / 8u];
            memcpy(&want, s + i, 8u);
            if (got != want)
                break;               /* fall through to find the byte */
        }
    }
    for (; i < len; i++)
        if (d[i] != s[i])
            return i;
    return len;
}
