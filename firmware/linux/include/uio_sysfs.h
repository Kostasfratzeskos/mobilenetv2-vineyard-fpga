/*============================================================================
 *  uio_sysfs.h  -  finding the accelerator's UIO device, and checking its region
 *
 *  The kernel says where everything is in text files, and these read them:
 *
 *      /sys/class/uio/uioN/name              "vine-accel" - the DT node's name
 *      /sys/class/uio/uioN/maps/mapM/addr    0x00000000a0000000
 *      /sys/class/uio/uioN/maps/mapM/size    0x0000000000002000
 *      /proc/iomem                           what the kernel thinks is RAM
 *
 *  Nothing is hard-coded that the device tree already states: the CSR address,
 *  the DMA region and its size all come from these files, so a carve-out moved
 *  in vinecam.dtsi reaches the application without an edit here. What IS checked
 *  here is that they make sense - see vine_uio.c.
 *
 *  Portable C with a configurable root, so test/test_platform.c can run every
 *  function against a fake /sys and a fake /proc/iomem on a PC.
 *==========================================================================*/
#ifndef UIO_SYSFS_H
#define UIO_SYSFS_H

#include <stddef.h>
#include <stdint.h>

/*  "0x..." or bare hex, as sysfs writes it. -1 if it is not hex. */
int uio_parse_hex(const char *s, uint64_t *out);

/*  The N of the uioN whose name file is exactly `name`, under sysroot (which
 *  is "/sys" on a board). 0 when exactly one matches; -1 when none does; -2
 *  when more than one does, which is refused rather than resolved by guessing. */
int uio_find_by_name(const char *sysroot, const char *name, int *index);

/*  One map's physical address and size. 0 on success. */
int uio_map_info(const char *sysroot, int index, int map,
                 uint64_t *addr, uint64_t *size);

/*  Does [lo, hi) overlap anything /proc/iomem calls "System RAM"? 1 if it does,
 *  0 if not, -1 if the file cannot be read. *readable is 0 when every range
 *  reads as zero - which is what a non-root reader is shown - so a "no" from an
 *  unreadable file is never mistaken for a real one. */
int iomem_overlaps_ram(const char *path, uint64_t lo, uint64_t hi,
                       int *readable);

#endif /* UIO_SYSFS_H */
