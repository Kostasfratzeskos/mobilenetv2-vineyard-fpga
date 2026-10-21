/*============================================================================
 *  test_platform.c  -  the Linux platform layer, on a PC
 *
 *  Everything between the driver and the kernel that can be checked without
 *  a board:
 *
 *    1  dmaregion: the allocator hands out page-aligned pieces and refuses
 *       when full; the translation is exact inside the region and REFUSES
 *       anything not wholly inside it - before, after, straddling the end
 *    2  dmaregion_write/verify: every length, the tail, a misaligned
 *       destination refused, and verify pointing at the first bad byte
 *    3  the driver with plat_linux.c's REAL hooks, against a register file in
 *       ordinary memory: the base registers must receive the region's
 *       PHYSICAL addresses - not the pointers, which under Linux are virtual -
 *       and a buffer outside the region must be refused before it is written
 *    4  sysfs: a fake /sys/class/uio tree, found by name, maps read; a
 *       missing name and a duplicated one are both refused
 *    5  /proc/iomem: a reserved region passes, one the kernel calls System RAM
 *       is caught, and an all-zero file (what a non-root reader sees) is
 *       reported as unreadable rather than as "fine"
 *    6  the hex parser the two above rely on
 *
 *  Run: cd firmware/linux && make test
 *==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <direct.h>
#  define MKDIR(p) _mkdir(p)
#else
#  include <sys/stat.h>
#  define MKDIR(p) mkdir((p), 0755)
#endif

#include "accel_drv.h"
#include "dmaregion.h"
#include "plat_linux.h"
#include "uio_sysfs.h"

#define FIX "build/host/fixtures"

static int fails = 0;

static void ck(int cond, const char *what)
{
    if (!cond) {
        printf("  [ERR] %s\n", what);
        fails++;
    }
}

static void section(int before, const char *what)
{
    if (fails == before)
        printf("  [ok ] %s\n", what);
}

/*  A stand-in for the mmap'd region: page-aligned, ordinary memory. Aligned
 *  by hand rather than with _Alignas(4096), which a Windows toolchain need not
 *  honour for static data. */
#define REGION_SIZE  (8u * 4096u)
#define REGION_PHYS  0x38000000u

static uint8_t *page_aligned(size_t n)
{
    uint8_t *raw = malloc(n + 4096u);

    if (raw == NULL) {
        printf("  [ERR] out of memory\n");
        exit(1);
    }
    return raw + (4096u - ((uintptr_t)raw & 4095u)) % 4096u;   /* leaked: a test */
}

/* ---- 1 ------------------------------------------------------------------ */
static void t_region(void)
{
    uint8_t    *region_mem = page_aligned(REGION_SIZE);
    dmaregion_t r;
    uint8_t    *a, *b2, *c;
    int before = fails;

    ck(dmaregion_init(&r, region_mem + 8, REGION_PHYS, REGION_SIZE) != 0,
       "a region whose mapping is not page-aligned was accepted");
    ck(dmaregion_init(&r, region_mem, REGION_PHYS + 64u, REGION_SIZE) != 0,
       "a region whose physical address is not page-aligned was accepted");
    ck(dmaregion_init(&r, region_mem, REGION_PHYS, REGION_SIZE) == 0,
       "a good region was refused");

    a  = dmaregion_alloc(&r, 100);
    b2 = dmaregion_alloc(&r, 5000);
    c  = dmaregion_alloc(&r, 1);
    ck(a == region_mem, "the first allocation is not at the start");
    ck(b2 == region_mem + 4096 && c == region_mem + 3 * 4096,
       "allocations are not page-aligned and sequential");
    ck(dmaregion_alloc(&r, REGION_SIZE) == NULL, "an allocation past the end succeeded");
    ck(dmaregion_alloc(&r, 0) == NULL, "a zero-length allocation succeeded");
    ck(dmaregion_alloc(&r, 4 * 4096u) != NULL, "the space that IS left was refused");
    ck(dmaregion_alloc(&r, 1) == NULL, "a full region still handed out memory");

    ck(dmaregion_phys(&r, a, 100) == REGION_PHYS, "the start does not translate");
    ck(dmaregion_phys(&r, b2 + 10, 20) == REGION_PHYS + 4096u + 10u,
       "an interior pointer translates wrongly");
    ck(dmaregion_phys(&r, region_mem + REGION_SIZE - 64, 64) ==
       REGION_PHYS + REGION_SIZE - 64u, "the last 64 bytes do not translate");
    ck(dmaregion_phys(&r, region_mem + REGION_SIZE - 64, 65) == DMAREGION_NO_PHYS,
       "a buffer straddling the END of the region was translated");
    ck(dmaregion_phys(&r, region_mem - 4096, 64) == DMAREGION_NO_PHYS,
       "a buffer BEFORE the region was translated");
    ck(dmaregion_phys(&r, region_mem + REGION_SIZE, 1) == DMAREGION_NO_PHYS,
       "a buffer just past the region was translated");
    {
        static uint8_t heap_like[256];
        ck(dmaregion_phys(&r, heap_like, sizeof heap_like) == DMAREGION_NO_PHYS,
           "an unrelated buffer was translated - a malloc'd image would reach the DMA");
    }
    section(before, "1  region: page-aligned allocation, exact translation, "
                    "everything outside refused");
}

/* ---- 2 ------------------------------------------------------------------ */
static void t_write(void)
{
    static uint8_t src[320];
    uint8_t *dst = page_aligned(512);
    size_t   n;
    int      before = fails;

    for (n = 0; n < sizeof src; n++)
        src[n] = (uint8_t)(n * 37u + 11u);

    /*  Every length from 0 to 299, from a source one byte off alignment - the
     *  whole words, the tail, and the source-side unaligned loads. */
    for (n = 0; n < 300u; n++) {
        memset(dst, 0xEE, 512);
        if (dmaregion_write(dst, src + 1, n) != 0) {
            ck(0, "an aligned write was refused");
            break;
        }
        if (memcmp(dst, src + 1, n) != 0) {
            ck(0, "a write of some length did not land intact");
            break;
        }
        if (dst[n] != 0xEE) {
            ck(0, "a write ran past its length");
            break;
        }
    }
    ck(dmaregion_write(dst + 1, src, 16) != 0,
       "a misaligned destination was accepted - on Device memory that faults");

    dmaregion_write(dst, src, 200);
    ck(dmaregion_verify(dst, src, 200) == 200, "verify reported a difference in equal data");
    dst[123] ^= 1u;
    ck(dmaregion_verify(dst, src, 200) == 123, "verify did not point at the bad byte");
    dst[123] ^= 1u;
    dst[199] ^= 0x80u;
    ck(dmaregion_verify(dst, src, 200) == 199, "verify missed a difference in the tail");
    section(before, "2  writes: every length 0..299 from an unaligned source, "
                    "misaligned destination refused, verify finds the byte");
}

/* ---- 3: the real hooks, a register file in memory ------------------------ */
static uint32_t csr[ACCEL_APERTURE_SIZE / 4u];

static void t_driver(void)
{
    const size_t   bigsz = 4u * 4096u + ACCEL_IMG_BYTES;
    uint8_t       *big = page_aligned(bigsz);
    dmaregion_t    r;
    accel_t        a;
    accel_status_t s;
    void          *wgt, *pb, *pm, *ps, *img;
    static uint8_t not_in_region[ACCEL_IMG_BYTES + 64];
    uint8_t       *outside = not_in_region + (64u - ((uintptr_t)not_in_region & 63u)) % 64u;
    int before = fails;

    memset(csr, 0, sizeof csr);
    csr[ACCEL_ID / 4u] = ACCEL_ID_MAGIC;
    /*  STATUS as a finished image load would leave it, so accel_load_image's
     *  wait returns at once - this test is about addresses, not about polling,
     *  which test_drv_seq covers against a mock with real behaviour. */
    csr[ACCEL_STATUS / 4u] = ACCEL_ST_IMG_DONE;

    dmaregion_init(&r, big, REGION_PHYS, bigsz);
    wgt = dmaregion_alloc(&r, 64);
    pb  = dmaregion_alloc(&r, 256);
    pm  = dmaregion_alloc(&r, 256);
    ps  = dmaregion_alloc(&r, 64);
    img = dmaregion_alloc(&r, ACCEL_IMG_BYTES);

    /*  Before the region is registered, nothing may translate. */
    plat_linux_set_region(NULL);
    ck(accel_init(&a, (uintptr_t)csr) == ACCEL_OK, "accel_init failed on the fake CSR");
    s = accel_set_blobs(&a, wgt, 64, pb, 256, pm, 256, ps, 64);
    ck(s == ACCEL_ERR_ADDR, "blobs were accepted with no region registered");

    plat_linux_set_region(&r);
    s = accel_set_blobs(&a, wgt, 64, pb, 256, pm, 256, ps, 64);
    ck(s == ACCEL_OK, "accel_set_blobs failed with the real hooks");
    ck(csr[ACCEL_WGT_BASE / 4u] == REGION_PHYS,
       "WGT_BASE is not the region's physical address");
    ck(csr[ACCEL_PB_BASE / 4u] == REGION_PHYS + 4096u, "PB_BASE is not physical");
    ck(csr[ACCEL_PM_BASE / 4u] == REGION_PHYS + 2u * 4096u, "PM_BASE is not physical");
    ck(csr[ACCEL_PS_BASE / 4u] == REGION_PHYS + 3u * 4096u, "PS_BASE is not physical");
    ck(csr[ACCEL_WGT_BASE / 4u] != (uint32_t)(uintptr_t)wgt,
       "WGT_BASE holds the virtual pointer");

    s = accel_load_image(&a, img, ACCEL_IMG_BYTES);
    ck(s == ACCEL_OK, "accel_load_image failed with the real hooks");
    ck(csr[ACCEL_IMG_BASE / 4u] == REGION_PHYS + 4u * 4096u, "IMG_BASE is not physical");

    /*  The case the hook exists for: an image buffer the process allocated
     *  itself - correctly aligned, so the only thing wrong with it is WHERE it
     *  is. Refused, and IMG_BASE keeps the good address. */
    s = accel_load_image(&a, outside, ACCEL_IMG_BYTES);
    ck(s == ACCEL_ERR_ADDR, "an image outside the DMA region was handed to the DMA");
    ck(csr[ACCEL_IMG_BASE / 4u] == REGION_PHYS + 4u * 4096u,
       "a refused image still overwrote IMG_BASE");

    plat_linux_set_region(NULL);
    section(before, "3  the driver through plat_linux.c: PHYSICAL bases, and a "
                    "buffer outside the region refused");
}

/* ---- 4: a fake /sys ------------------------------------------------------ */
static void put(const char *path, const char *text)
{
    FILE *fh = fopen(path, "w");
    if (fh) {
        fputs(text, fh);
        fclose(fh);
    }
}

static void mkuio(const char *root, int n, const char *name, const char *a0,
                  const char *s0, const char *a1, const char *s1)
{
    char p[256];

    snprintf(p, sizeof p, "%s/class/uio/uio%d", root, n);                MKDIR(p);
    snprintf(p, sizeof p, "%s/class/uio/uio%d/name", root, n);           put(p, name);
    snprintf(p, sizeof p, "%s/class/uio/uio%d/maps", root, n);           MKDIR(p);
    snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map0", root, n);      MKDIR(p);
    snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map0/addr", root, n); put(p, a0);
    snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map0/size", root, n); put(p, s0);
    if (a1) {
        snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map1", root, n);      MKDIR(p);
        snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map1/addr", root, n); put(p, a1);
        snprintf(p, sizeof p, "%s/class/uio/uio%d/maps/map1/size", root, n); put(p, s1);
    }
}

static void mkroot(const char *root)
{
    char p[256];
    MKDIR("build"); MKDIR("build/host"); MKDIR(FIX);
    MKDIR(root);
    snprintf(p, sizeof p, "%s/class", root);     MKDIR(p);
    snprintf(p, sizeof p, "%s/class/uio", root); MKDIR(p);
}

static void t_sysfs(void)
{
    const char *one = FIX "/sys_one", *two = FIX "/sys_two";
    uint64_t    a, s;
    int         idx = -1, before = fails;

    mkroot(one);
    mkuio(one, 0, "axi-pmon\n", "0xff0a0000\n", "0x10000\n", NULL, NULL);
    mkuio(one, 3, "vine-accel\n", "0x00000000a0000000\n", "0x0000000000002000\n",
          "0x0000000038000000\n", "0x0000000001000000\n");

    ck(uio_find_by_name(one, "vine-accel", &idx) == 0 && idx == 3,
       "the vine-accel UIO device was not found as uio3");
    ck(uio_map_info(one, 3, 0, &a, &s) == 0 && a == 0xA0000000ull && s == 0x2000u,
       "map0 (the CSR) read wrongly");
    ck(uio_map_info(one, 3, 1, &a, &s) == 0 && a == 0x38000000ull && s == 0x1000000u,
       "map1 (the DMA region) read wrongly");
    ck(uio_map_info(one, 0, 1, &a, &s) != 0, "a map that does not exist was read");
    ck(uio_find_by_name(one, "nope", &idx) == -1, "a missing name was found");
    ck(uio_find_by_name(one, "vine-acce", &idx) == -1,
       "a PREFIX of the name matched - the comparison must be exact");

    mkroot(two);
    mkuio(two, 0, "vine-accel\n", "0xa0000000\n", "0x2000\n", "0x38000000\n", "0x1000000\n");
    mkuio(two, 1, "vine-accel\n", "0xa0010000\n", "0x2000\n", "0x39000000\n", "0x1000000\n");
    ck(uio_find_by_name(two, "vine-accel", &idx) == -2,
       "two devices with the same name were not reported as ambiguous");
    section(before, "4  sysfs: found by exact name, both maps read, missing and "
                    "duplicate names refused");
}

/* ---- 5: /proc/iomem ------------------------------------------------------ */
static void t_iomem(void)
{
    const char *good = FIX "/iomem_good", *zero = FIX "/iomem_zero";
    int r, readable, before = fails;

    put(good,
        "00000000-37ffffff : System RAM\n"
        "  00200000-0144ffff : Kernel code\n"
        "38000000-38ffffff : reserved\n"
        "39000000-7fefffff : System RAM\n"
        "a0000000-a0001fff : a0000000.vine-accel\n"
        "ff000000-ff00002f : xuartps\n");
    put(zero,
        "00000000-00000000 : System RAM\n"
        "00000000-00000000 : reserved\n"
        "00000000-00000000 : System RAM\n");

    r = iomem_overlaps_ram(good, 0x38000000ull, 0x39000000ull, &readable);
    ck(r == 0 && readable == 1, "a properly reserved region was flagged");
    r = iomem_overlaps_ram(good, 0x37fff000ull, 0x38001000ull, &readable);
    ck(r == 1, "a region overlapping System RAM below was not caught");
    r = iomem_overlaps_ram(good, 0x38ff0000ull, 0x39001000ull, &readable);
    ck(r == 1, "a region overlapping System RAM above was not caught");
    r = iomem_overlaps_ram(good, 0x38fff000ull, 0x39000000ull, &readable);
    ck(r == 0, "the last page of the reserved region was flagged - an off-by-one "
               "on the inclusive end");
    r = iomem_overlaps_ram(zero, 0x38000000ull, 0x39000000ull, &readable);
    ck(readable == 0, "an all-zero /proc/iomem (a non-root reader) looked readable");
    ck(iomem_overlaps_ram(FIX "/no_such_file", 0, 1, &readable) == -1,
       "a missing file was not reported");
    section(before, "5  /proc/iomem: reserved passes, System RAM caught at both "
                    "edges, non-root zeros not mistaken for a pass");
}

/* ---- 6 ------------------------------------------------------------------ */
static void t_hex(void)
{
    uint64_t v;
    int before = fails;

    ck(uio_parse_hex("0x00000000a0000000\n", &v) == 0 && v == 0xA0000000ull, "0x...a0000000");
    ck(uio_parse_hex("38000000", &v) == 0 && v == 0x38000000ull, "bare hex");
    ck(uio_parse_hex("0xFFFFFFFFFFFFFFFF", &v) == 0 && v == UINT64_MAX, "64 bits");
    ck(uio_parse_hex("0x1FFFFFFFFFFFFFFFF", &v) != 0, "65 bits accepted");
    ck(uio_parse_hex("0x", &v) != 0, "no digits accepted");
    ck(uio_parse_hex("0x12g4", &v) != 0, "a non-hex character accepted");
    section(before, "6  hex: sysfs's formats parsed, overflow and junk refused");
}

int main(void)
{
    printf("UNIT: the Linux platform layer - region, hooks, sysfs, iomem\n\n");
    t_region();
    t_write();
    t_driver();
    t_sysfs();
    t_iomem();
    t_hex();
    printf("\n");
    if (fails == 0) {
        printf("ALL PASS  (the DMA can only ever be given physical addresses inside "
               "the reserved region)\n");
        return 0;
    }
    printf("FAILED    (%d problems)\n", fails);
    return 1;
}
