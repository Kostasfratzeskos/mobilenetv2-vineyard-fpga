#=============================================================================
#  firmware/Makefile  -  the HOST build, which exists to run the tests
#
#  Same shape as software/cmodel/Makefile: src/ and test/, one program per test
#  file, .exe on Windows.
#
#  ---- what this Makefile does and does not build ----------------------
#
#  It builds the driver and the tests for a PC, with gcc. It does NOT build the
#  baremetal application - that needs a Vitis workspace with a standalone BSP
#  generated from build/bd_*/accel_bd_wrapper.xsa, an aarch64 cross compiler and
#  xilffs for the SD card. See README.md.
#
#  That split is the point rather than a limitation. accel_drv.c is portable C
#  with no Xilinx headers, talking to the hardware through four platform hooks,
#  precisely so that the part most likely to be wrong - the register map and the
#  order of operations - can be tested on a machine with no board attached.
#
#      make test      both tests
#      make           the same
#
#  Neither test needs hardware, a bitstream, or Vivado.
#=============================================================================
CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -O2 -MMD -MP -Iinclude
LDFLAGS =

SRC       = src
TESTDIR   = test
BUILD     = build
TESTBUILD = $(BUILD)/test

ifeq ($(OS),Windows_NT)
  EXE := .exe
else
  EXE :=
endif

#  main.c is the baremetal application and does not build on the host (it needs
#  xilffs and the BSP), so it is excluded here. Everything else is portable.
LIB_SRCS  = $(SRC)/accel_drv.c
LIB_OBJS  = $(patsubst $(SRC)/%.c,$(BUILD)/%.o,$(LIB_SRCS))

TEST_SRCS = $(wildcard $(TESTDIR)/*.c)
TEST_BINS = $(patsubst $(TESTDIR)/%.c,$(TESTBUILD)/%$(EXE),$(TEST_SRCS))

.PHONY: all test clean
all: test

$(BUILD) $(TESTBUILD):
	@mkdir -p $@

$(BUILD)/%.o: $(SRC)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

#  Two explicit rules rather than one pattern, because the two tests need
#  different things and saying so is clearer than a generic rule plus stubs.
#
#  test_csr_map compares the header against the RTL and touches no hardware at
#  all, so it must NOT link the driver - the driver's platform hooks are
#  undefined without a mock, and stubbing them just to satisfy the linker would
#  put dead code in a test whose whole job is to read a file.
$(TESTBUILD)/test_csr_map$(EXE): $(TESTDIR)/test_csr_map.c | $(TESTBUILD)
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

#  test_drv_seq IS the driver's test, and supplies the four platform hooks
#  itself as a mock of the CSR.
$(TESTBUILD)/test_drv_seq$(EXE): $(TESTDIR)/test_drv_seq.c $(LIB_OBJS) | $(TESTBUILD)
	$(CC) $(CFLAGS) $< $(LIB_OBJS) -o $@ $(LDFLAGS)

test: $(TEST_BINS)
	@fail=0; \
	for t in $(TEST_BINS); do \
	    echo "=============== $$t ==============="; \
	    ./$$t || fail=1; \
	    echo ""; \
	done; \
	if [ $$fail -ne 0 ]; then echo ">> FIRMWARE TESTS FAILED"; exit 1; fi; \
	echo ">> all firmware tests pass"

clean:
	rm -rf $(BUILD)

-include $(wildcard $(BUILD)/*.d) $(wildcard $(TESTBUILD)/*.d)
