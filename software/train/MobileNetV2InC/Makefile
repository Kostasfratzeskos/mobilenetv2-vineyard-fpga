CC      := gcc
CFLAGS  := -Wall -Wextra -g -std=c11
TARGET  := main.exe
SRCS    := $(wildcard *.c)
OBJS    := $(SRCS:.c=.o)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: clean