/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_XIL_TYPES_H
#define STUB_XIL_TYPES_H

#include <stdint.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uintptr_t UINTPTR;
typedef intptr_t  INTPTR;

#define XST_SUCCESS 0L
#define XST_FAILURE 1L

#endif
