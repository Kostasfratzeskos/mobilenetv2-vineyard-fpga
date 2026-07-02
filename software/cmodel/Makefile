CC       = gcc
CFLAGS   = -std=c11 -Wall -Wextra -O2 -MMD -MP

# ---- layout ----
SRC       = src
TESTDIR   = test
BUILD     = build
TESTBUILD = $(BUILD)/test
LOG       = $(BUILD)/test.log
INCLUDES  = -I$(SRC)

# ---- .exe suffix on Windows, empty elsewhere ----
ifeq ($(OS),Windows_NT)
  EXE := .exe
else
  EXE :=
endif

# ---- app: every .c in model/src; split main off so tests can reuse the rest ----
SRCS      = $(wildcard $(SRC)/*.c)
LIB_SRCS  = $(filter-out $(SRC)/main.c,$(SRCS))
LIB_OBJS  = $(patsubst $(SRC)/%.c,$(BUILD)/%.o,$(LIB_SRCS))
APP_OBJS  = $(BUILD)/main.o $(LIB_OBJS)
TARGET    = $(BUILD)/mobilenet$(EXE)

# ---- tests: every .c in test/ is its own program ----
TEST_SRCS = $(wildcard $(TESTDIR)/*.c)
TEST_OBJS = $(patsubst $(TESTDIR)/%.c,$(TESTBUILD)/%.o,$(TEST_SRCS))
TEST_BINS = $(patsubst $(TESTDIR)/%.c,$(TESTBUILD)/%$(EXE),$(TEST_SRCS))

DEPS      = $(APP_OBJS:.o=.d) $(TEST_OBJS:.o=.d)

all: $(TARGET)

$(TARGET): $(APP_OBJS)
	$(CC) $(CFLAGS) -o $@ $^

$(BUILD)/%.o: $(SRC)/%.c | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

$(TESTBUILD)/%.o: $(TESTDIR)/%.c | $(TESTBUILD)
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# each test links against the engine objects, never against main.o
$(TESTBUILD)/%$(EXE): $(TESTBUILD)/%.o $(LIB_OBJS) | $(TESTBUILD)
	$(CC) $(CFLAGS) -o $@ $^

# build + run every test, fresh log each run
test: $(TEST_BINS)
	@: > $(LOG)
	@for t in $(TEST_BINS); do \
	    echo "===== $$t =====" | tee -a $(LOG); \
	    "$$t" 2>&1            | tee -a $(LOG); \
	    echo ""               | tee -a $(LOG); \
	done
	@echo "Tests finished -> $(LOG)"

$(BUILD):
	mkdir -p $(BUILD)

$(TESTBUILD):
	mkdir -p $(TESTBUILD)

clean:
	rm -f $(APP_OBJS) $(TEST_OBJS) $(TEST_BINS) $(TARGET) $(DEPS) $(LOG)

-include $(DEPS)

.PHONY: all test clean