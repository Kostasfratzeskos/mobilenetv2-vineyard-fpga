/*  A STUB, not a BSP. See test/stubs/README.md.
 *
 *  Declarations only, copied from the real Xilinx header's signatures, so that
 *  `make lint` can compile-check the baremetal sources on a PC. Never linked.
 */
#ifndef STUB_FF_H
#define STUB_FF_H

#include <stddef.h>

#include "xil_types.h"

typedef unsigned int  UINT;
typedef unsigned long FSIZE_t;

typedef enum { FR_OK = 0, FR_DISK_ERR } FRESULT;

typedef struct { int dummy; } FATFS;
typedef struct { FSIZE_t fsize; } FIL;

#define FA_READ  0x01
#define FA_WRITE 0x02

FRESULT f_mount(FATFS *fs, const char *path, unsigned char opt);
FRESULT f_open(FIL *fp, const char *path, unsigned char mode);
FRESULT f_read(FIL *fp, void *buff, UINT btr, UINT *br);
FRESULT f_close(FIL *fp);

/*  In xilffs this is a macro over fp->obj.objsize. A function here is enough for
 *  a type check and avoids inventing the object layout. */
FSIZE_t f_size(FIL *fp);

#endif
