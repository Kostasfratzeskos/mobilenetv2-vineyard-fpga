/*============================================================================
 *  vine_uio.c  -  map the CSR and the DMA region through /dev/uioN
 *
 *  Linux only. See vine_uio.h for what is checked and why.
 *==========================================================================*/
#define _GNU_SOURCE
#include "vine_uio.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "accel_csr.h"
#include "uio_sysfs.h"

/*  The top of what S_AXI_HP0_FPD can reach as memory: SEG_zynq_ps_HP0_DDR_LOW,
 *  0x0000_0000 + 0x8000_0000, in build/bd_<cfg>/address_map.rpt. */
#define HP0_DDR_LOW_END  0x80000000ull

static int write_str(const char *path, const char *s)
{
    int     fd = open(path, O_WRONLY);
    ssize_t w;

    if (fd < 0)
        return -1;
    w = write(fd, s, strlen(s));
    close(fd);
    return w == (ssize_t)strlen(s) ? 0 : -1;
}

/*  The device is in the device tree but nothing bound it - the usual cause is
 *  bootargs without uio_pdrv_genirq.of_id=generic-uio. The platform device
 *  exists anyway (DT nodes become platform devices whether or not a driver
 *  matches), named <unit-address>.<node-name>, so point uio_pdrv_genirq at it
 *  by hand. Its probe takes any DT node, so a forced match is enough. */
static int try_bind(const char *name)
{
    const char    *devs = "/sys/bus/platform/devices";
    DIR           *d = opendir(devs);
    struct dirent *e;
    char           suffix[96], path[512];
    int            bound = -1;

    if (d == NULL)
        return -1;
    snprintf(suffix, sizeof suffix, ".%s", name);
    while ((e = readdir(d)) != NULL) {
        size_t ln = strlen(e->d_name), ls = strlen(suffix);
        if (ln <= ls || strcmp(e->d_name + ln - ls, suffix) != 0)
            continue;
        snprintf(path, sizeof path, "%s/%s/driver_override", devs, e->d_name);
        if (write_str(path, "uio_pdrv_genirq"))
            continue;
        if (write_str("/sys/bus/platform/drivers/uio_pdrv_genirq/bind",
                      e->d_name) == 0) {
            fprintf(stderr, "  note: bound uio_pdrv_genirq to %s by hand - "
                    "add uio_pdrv_genirq.of_id=generic-uio to the bootargs "
                    "(vinecam.dtsi) to make this unnecessary\n", e->d_name);
            bound = 0;
        }
    }
    closedir(d);
    return bound;
}

int vine_uio_open(vine_uio_t *u, const char *name, char *err, size_t errlen)
{
    char     dev[32];
    uint64_t a0, s0, a1, s1;
    long     page = sysconf(_SC_PAGESIZE);
    int      r, readable;
    void    *m;

    memset(u, 0, sizeof *u);
    u->fd = -1;

    r = uio_find_by_name("/sys", name, &u->index);
    if (r == -1 && try_bind(name) == 0)
        r = uio_find_by_name("/sys", name, &u->index);
    if (r == -2) {
        snprintf(err, errlen, "more than one UIO device is called %s - "
                 "refusing to guess which is the accelerator", name);
        return -1;
    }
    if (r != 0) {
        snprintf(err, errlen, "no UIO device called %s. Is the board running the "
                 "vinecam device tree (firmware/linux/petalinux/vinecam.dtsi)? "
                 "`ls /sys/class/uio` lists what exists", name);
        return -1;
    }

    if (uio_map_info("/sys", u->index, 0, &a0, &s0) ||
        uio_map_info("/sys", u->index, 1, &a1, &s1)) {
        snprintf(err, errlen, "%s must have two maps - the CSR and the DMA "
                 "region - and does not", name);
        return -1;
    }

    if (s0 < ACCEL_APERTURE_SIZE) {
        snprintf(err, errlen, "map0 of %s is smaller than the 8 KB CSR aperture "
                 "- is map0 really the CSR?", name);
        return -1;
    }

    /*  The DMA region's three conditions. Each is a way for the accelerator
     *  to read bytes other than the ones this process wrote. */
    if ((a1 % (uint64_t)page) != 0u || (s1 % (uint64_t)page) != 0u) {
        snprintf(err, errlen, "the DMA region (map1) is not page-aligned");
        return -1;
    }
    if (a1 + s1 > HP0_DDR_LOW_END) {
        snprintf(err, errlen, "the DMA region (map1) is not below 2 GB, and "
                 "S_AXI_HP0_FPD only reaches DDR_LOW - move the carve-out");
        return -1;
    }
    r = iomem_overlaps_ram("/proc/iomem", a1, a1 + s1, &readable);
    if (r == 1) {
        snprintf(err, errlen, "the DMA region (map1) is listed as System RAM in "
                 "/proc/iomem: the kernel is using it. The reserved-memory node "
                 "is missing, or lacks no-map");
        return -1;
    }
    if (r < 0 || !readable)
        fprintf(stderr, "  warning: /proc/iomem is not readable (not root?) - "
                "cannot confirm the DMA region is reserved\n");

    snprintf(dev, sizeof dev, "/dev/uio%d", u->index);
    u->fd = open(dev, O_RDWR | O_SYNC);
    if (u->fd < 0) {
        snprintf(err, errlen, "%s: %s (run as root)", dev, strerror(errno));
        return -1;
    }

    /*  UIO selects map N by an mmap offset of N pages. Each length is recorded
     *  the moment its mapping exists, so a failure after it unmaps exactly what
     *  was mapped. */
    m = mmap(NULL, (size_t)s0, PROT_READ | PROT_WRITE, MAP_SHARED, u->fd, 0);
    if (m == MAP_FAILED) {
        snprintf(err, errlen, "mmap of the CSR failed: %s", strerror(errno));
        vine_uio_close(u);
        return -1;
    }
    u->csr      = (volatile uint8_t *)m;
    u->csr_len  = (size_t)s0;
    u->csr_phys = a0;

    m = mmap(NULL, (size_t)s1, PROT_READ | PROT_WRITE, MAP_SHARED, u->fd,
             (off_t)page);
    if (m == MAP_FAILED) {
        snprintf(err, errlen, "mmap of the DMA region failed: %s", strerror(errno));
        vine_uio_close(u);
        return -1;
    }
    u->dma      = (volatile uint8_t *)m;
    u->dma_len  = (size_t)s1;
    u->dma_phys = a1;
    return 0;
}

void vine_uio_close(vine_uio_t *u)
{
    if (u->csr != NULL)
        munmap((void *)(uintptr_t)u->csr, u->csr_len);
    if (u->dma != NULL)
        munmap((void *)(uintptr_t)u->dma, u->dma_len);
    if (u->fd >= 0)
        close(u->fd);
    memset(u, 0, sizeof *u);
    u->fd = -1;
}
