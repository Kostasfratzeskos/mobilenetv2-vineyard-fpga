#=============================================================================
#  firmware/linux/Makefile  -  the camera application for Linux on the ZCU104
#
#      make test     the host tests, with the PC's own gcc: no board, no Linux
#      make          vinecam for the board - aarch64 Linux, linked STATIC
#      make check    both: the tests, and proof the board build compiles
#      make tools    render_ui: the demo screen from a photograph, on the PC
#      make clean
#
#  ---- two compilers, on purpose ----------------------------------------
#
#  Same split as firmware/Makefile. Everything that decides WHICH bytes reach
#  the accelerator - the resampler, the address translation, the region
#  allocator, the sysfs and iomem parsing, the screen layout - is portable C
#  and is tested here, on the PC. The parts that are only system calls (mmap
#  of /dev/uioN, V4L2, the framebuffer, sockets) cannot run on a PC, so the
#  cross build is their check: `make check` compiles all of it for the board
#  with -Werror.
#
#  ---- the cross compiler ------------------------------------------------
#
#  Vitis ships one: <Vitis>/gnu/aarch64/{nt,lin}/aarch64-linux/bin/
#  aarch64-linux-gnu-gcc, with its own glibc. It is found automatically from
#  the usual install paths; otherwise
#
#      make CROSS_CC=/path/to/aarch64-linux-gnu-gcc
#      make CROSS_CC="$CC"      # inside a PetaLinux SDK environment
#
#  STATIC, so the binary needs nothing from the board's root filesystem: it
#  runs on the PetaLinux image this directory builds, and on any other aarch64
#  Linux the board boots. Copy it to the SD card next to the blobs and run it.
#=============================================================================
FW       := ..
HOSTCC   ?= gcc
B        := build
HB       := $(B)/host
TB       := $(B)/aarch64

ifeq ($(OS),Windows_NT)
  EXE := .exe
endif

CROSS_CC ?= $(firstword \
  $(wildcard C:/Xilinx/Vitis/*/gnu/aarch64/nt/aarch64-linux/bin/aarch64-linux-gnu-gcc.exe) \
  $(wildcard /tools/Xilinx/Vitis/*/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc) \
  $(wildcard /opt/Xilinx/Vitis/*/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc) \
  $(shell command -v aarch64-linux-gnu-gcc 2>/dev/null))

INC      := -Iinclude -I$(FW)/include

#  -ffp-contract=off: camfront.c's coefficients must round the way Pillow's
#  do, which an FMA would not (camfront.c explains why it cannot matter for
#  these expressions, and why the flag stays anyway).
FP       := -ffp-contract=off

#  On a 32-bit x86 host gcc computes doubles on the x87, in 80 bits, which is
#  neither the target's arithmetic nor Pillow's. SSE2 makes the host compute
#  what the A53 computes, so a host pass means something about the board.
HOSTARCH := $(shell $(HOSTCC) -dumpmachine)
ifneq ($(findstring 86,$(HOSTARCH))$(findstring mingw32,$(HOSTARCH)),)
  HOSTFP := -msse2 -mfpmath=sse
endif

HOSTCFLAGS := -std=c11 -Wall -Wextra -O2 $(FP) $(HOSTFP) $(INC)
CFLAGS     := -std=c11 -Wall -Wextra -Werror -O2 $(FP) $(INC)
LDFLAGS    := -static
LDLIBS     := -lm -lpthread

HDRS     := $(wildcard include/*.h) $(wildcard $(FW)/include/*.h)

APP_SRCS := src/vinecam.c src/vine_uio.c src/plat_linux.c src/dmaregion.c \
            src/uio_sysfs.c src/camfront.c src/v4l2cam.c src/fbdev.c \
            src/canvas.c src/ui.c src/httpview.c src/ppm.c src/dump.c \
            $(FW)/src/accel_drv.c $(FW)/src/preproc.c

TESTS    := $(HB)/test_camfront$(EXE) $(HB)/test_platform$(EXE) $(HB)/test_ui$(EXE)

.PHONY: all vinecam test check tools clean
all: vinecam

$(HB) $(TB):
	@mkdir -p $@

# ---- the board -----------------------------------------------------------
vinecam: $(TB)/vinecam

$(TB)/vinecam: $(APP_SRCS) $(HDRS) | $(TB)
	@if [ -z "$(CROSS_CC)" ]; then \
	    echo "No aarch64 Linux cross compiler found. Install Vitis, or run"; \
	    echo "    make CROSS_CC=/path/to/aarch64-linux-gnu-gcc"; exit 1; fi
	"$(CROSS_CC)" $(CFLAGS) $(APP_SRCS) -o $@ $(LDFLAGS) $(LDLIBS)
	@echo "built $@ - static aarch64 Linux; copy it to the SD card with the blobs"

# ---- the PC --------------------------------------------------------------
$(HB)/test_camfront$(EXE): test/test_camfront.c src/camfront.c $(HDRS) | $(HB)
	$(HOSTCC) $(HOSTCFLAGS) $(filter %.c,$^) -o $@ -lm

$(HB)/test_platform$(EXE): test/test_platform.c src/dmaregion.c src/uio_sysfs.c \
                           src/plat_linux.c $(FW)/src/accel_drv.c $(HDRS) | $(HB)
	$(HOSTCC) $(HOSTCFLAGS) $(filter %.c,$^) -o $@

$(HB)/test_ui$(EXE): test/test_ui.c src/ui.c src/canvas.c $(HDRS) | $(HB)
	$(HOSTCC) $(HOSTCFLAGS) $(filter %.c,$^) -o $@ -lm

$(HB)/render_ui$(EXE): tools/render_ui.c src/camfront.c src/canvas.c src/ui.c \
                       src/ppm.c src/dump.c $(FW)/src/preproc.c $(HDRS) | $(HB)
	$(HOSTCC) $(HOSTCFLAGS) $(filter %.c,$^) -o $@ -lm

tools: $(HB)/render_ui$(EXE)

test: $(TESTS)
	@fail=0; \
	for t in $(TESTS); do \
	    echo "=============== $$t ==============="; \
	    ./$$t || fail=1; \
	    echo ""; \
	done; \
	if [ $$fail -ne 0 ]; then echo ">> LINUX-SIDE TESTS FAILED"; exit 1; fi; \
	echo ">> all Linux-side host tests pass"

check: test vinecam

clean:
	rm -rf $(B)
