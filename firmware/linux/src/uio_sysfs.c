/*============================================================================
 *  uio_sysfs.c  -  read the kernel's description of the UIO device
 *
 *  See uio_sysfs.h. Hex is parsed by hand rather than with strtoull or %llx,
 *  which is not a matter of taste: the Windows host the tests also run on has a
 *  C runtime whose 64-bit conversions are not reliable, and a parser this small
 *  is easier to trust than to work around.
 *==========================================================================*/
#include "uio_sysfs.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>

int uio_parse_hex(const char *s, uint64_t *out)
{
    uint64_t v = 0;
    int      digits = 0;

    if (s == NULL || out == NULL)
        return -1;
    while (*s == ' ' || *s == '\t')
        s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        s += 2;
    for (;; s++) {
        int d;
        if (*s >= '0' && *s <= '9')      d = *s - '0';
        else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else break;
        if (digits == 16)
            return -1;                   /* more than 64 bits */
        v = (v << 4) | (uint64_t)d;
        digits++;
    }
    if (digits == 0 || (*s != '\0' && *s != '\n' && *s != '\r' &&
                        *s != ' ' && *s != '\t'))
        return -1;
    *out = v;
    return 0;
}

/*  The first line of a small text file, without its newline. */
static int read_line(const char *path, char *buf, size_t n)
{
    FILE  *fh = fopen(path, "r");
    size_t len;

    if (fh == NULL)
        return -1;
    if (fgets(buf, (int)n, fh) == NULL) {
        fclose(fh);
        return -1;
    }
    fclose(fh);
    len = strlen(buf);
    while (len > 0u && (buf[len - 1u] == '\n' || buf[len - 1u] == '\r'))
        buf[--len] = '\0';
    return 0;
}

int uio_find_by_name(const char *sysroot, const char *name, int *index)
{
    char           path[512], nm[128];
    DIR           *d;
    struct dirent *e;
    int            found = 0, n;

    snprintf(path, sizeof path, "%s/class/uio", sysroot);
    d = opendir(path);
    if (d == NULL)
        return -1;
    while ((e = readdir(d)) != NULL) {
        char tail;
        /*  "uio12" and nothing else: the trailing %c must NOT match. */
        if (sscanf(e->d_name, "uio%d%c", &n, &tail) != 1)
            continue;
        snprintf(path, sizeof path, "%s/class/uio/%s/name", sysroot, e->d_name);
        if (read_line(path, nm, sizeof nm) == 0 && strcmp(nm, name) == 0) {
            *index = n;
            found++;
        }
    }
    closedir(d);
    if (found == 0)
        return -1;
    return found == 1 ? 0 : -2;
}

int uio_map_info(const char *sysroot, int index, int map,
                 uint64_t *addr, uint64_t *size)
{
    char path[512], buf[64];

    snprintf(path, sizeof path, "%s/class/uio/uio%d/maps/map%d/addr",
             sysroot, index, map);
    if (read_line(path, buf, sizeof buf) || uio_parse_hex(buf, addr))
        return -1;
    snprintf(path, sizeof path, "%s/class/uio/uio%d/maps/map%d/size",
             sysroot, index, map);
    if (read_line(path, buf, sizeof buf) || uio_parse_hex(buf, size))
        return -1;
    return 0;
}

/*  "  38000000-38ffffff : reserved" - leading spaces are nesting, the ranges
 *  are inclusive, and the name is everything after " : ". */
static int parse_iomem_line(const char *ln, uint64_t *lo, uint64_t *hi,
                            const char **name)
{
    char        a[24], b[24];
    const char *dash, *colon, *p = ln;
    size_t      la, lb;

    while (*p == ' ')
        p++;
    dash  = strchr(p, '-');
    colon = strstr(p, " : ");
    if (dash == NULL || colon == NULL || dash > colon)
        return -1;
    la = (size_t)(dash - p);
    lb = (size_t)(colon - dash - 1);
    if (la == 0u || la >= sizeof a || lb == 0u || lb >= sizeof b)
        return -1;
    memcpy(a, p, la);
    a[la] = '\0';
    memcpy(b, dash + 1, lb);
    b[lb] = '\0';
    if (uio_parse_hex(a, lo) || uio_parse_hex(b, hi))
        return -1;
    *name = colon + 3;
    return 0;
}

int iomem_overlaps_ram(const char *path, uint64_t lo, uint64_t hi,
                       int *readable)
{
    FILE *fh = fopen(path, "r");
    char  ln[256];
    int   overlap = 0, nonzero = 0;

    if (readable)
        *readable = 0;
    if (fh == NULL)
        return -1;
    while (fgets(ln, sizeof ln, fh)) {
        uint64_t    a, b;
        const char *name;
        size_t      len = strlen(ln);

        while (len > 0u && (ln[len - 1u] == '\n' || ln[len - 1u] == '\r'))
            ln[--len] = '\0';
        if (parse_iomem_line(ln, &a, &b, &name))
            continue;
        if (a != 0u || b != 0u)
            nonzero = 1;
        /*  [a, b] inclusive against [lo, hi) half-open. */
        if (strcmp(name, "System RAM") == 0 && a < hi && b >= lo)
            overlap = 1;
    }
    fclose(fh);
    if (readable)
        *readable = nonzero;
    return overlap;
}
