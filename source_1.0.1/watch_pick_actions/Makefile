CC = gcc
CFLAGS = -Wall -O2 -D_GNU_SOURCE
LDFLAGS = -static
TARGET = nss_watch

all: $(TARGET)

$(TARGET): nss_watch.c nss_watch.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TARGET) nss_watch.c

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) ./

.PHONY: all clean install
