#ifndef HEXIO_H
#define HEXIO_H

#include <stdint.h>

/* =====================================================================
 *  $readmemh-style hex files: one two's-complement value per line.
 *  The exported weights and the golden vectors both use this format.
 *
 *  LAYOUT NOTE (the thing most likely to bite):
 *    the hex files store activations as (N,C,H,W) row-major, but the
 *    cmodel works internally in NHWC. So loading an activation permutes
 *    NCHW->NHWC, and dumping permutes NHWC->NCHW. Weight/bias/m0/shift
 *    files are 1-D lists and are read verbatim (no permute).
 * ===================================================================== */

/* count non-empty lines (== number of values) in a hex file, or -1 */
long hex_count(const char *path);

/* read exactly n values; returns n on success, -1 on error/short file */
int hex_read_i8 (const char *path, int8_t  *dst, int n);
int hex_read_i32(const char *path, int32_t *dst, int n);

/* write n values, one per line, lowercase hex two's complement */
int hex_write_i8 (const char *path, const int8_t  *src, int n);
int hex_write_i32(const char *path, const int32_t *src, int n);

/* layout permutes (H*W*C elements) */
void nchw_to_nhwc_i8(const int8_t *nchw, int8_t *nhwc, int C, int H, int W);
void nhwc_to_nchw_i8(const int8_t *nhwc, int8_t *nchw, int C, int H, int W);

/* activation helpers: read an NCHW hex file into an NHWC buffer, and the
 * reverse for dumping. Both allocate no memory; caller owns dst.        */
int hex_read_activation_nhwc (const char *path, int8_t *nhwc, int C, int H, int W);
int hex_write_activation_nchw(const char *path, const int8_t *nhwc, int C, int H, int W);

#endif /* HEXIO_H */
