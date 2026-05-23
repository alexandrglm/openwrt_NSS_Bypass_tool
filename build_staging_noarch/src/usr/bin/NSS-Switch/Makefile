# Makefile para compilar nss-watch
CC = gcc
CFLAGS = -Wall -O2 -D_GNU_SOURCE
TARGET = nss-watch
SOURCES = nss_watch.c

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCES)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	cp $(TARGET) /usr/bin/
	chmod 755 /usr/bin/$(TARGET)

.PHONY: all clean install
