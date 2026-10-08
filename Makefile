ARCHS   = -arch arm64 -arch x86_64
CFLAGS  = -O2 -Wall -Wextra -Wno-deprecated-declarations $(ARCHS)
PREFIX  = /usr/local
DRIVER  = /Library/Printers/RP425
PPDDIR  = /Library/Printers/PPDs/Contents/Resources

all: build/rastertorp425 build/rp425

build/rastertorp425: src/rastertorp425.c
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< -lcups

build/rp425: src/rp425.swift
	@mkdir -p build
	swiftc -O -target arm64-apple-macos12 -o build/rp425-arm64 $<
	swiftc -O -target x86_64-apple-macos12 -o build/rp425-x86_64 $<
	lipo -create -output $@ build/rp425-arm64 build/rp425-x86_64

# Encodes a test label without touching the printer; `make test-print` sends it.
build/test.zpl: build/rastertorp425 test/mkpdf.swift ppd/RP425.ppd
	swiftc -O -o build/mkpdf test/mkpdf.swift
	build/mkpdf build/test.pdf
	/usr/sbin/cupsfilter -p ppd/RP425.ppd -m application/vnd.cups-raster build/test.pdf > build/test.ras 2>/dev/null
	build/rastertorp425 1 $(USER) test 1 "" build/test.ras > $@

test: build/test.zpl
	python3 test/roundtrip.py build/rastertorp425 build/test.ras

test-print: build/test.zpl build/rp425
	build/rp425 send build/test.zpl

install: all
	@test "$$(id -u)" = 0 || { echo "run: sudo make install"; exit 1; }
	install -d -o root -g wheel -m 755 $(DRIVER)/Filter $(PREFIX)/bin
	install -o root -g wheel -m 755 build/rastertorp425 $(DRIVER)/Filter/rastertorp425
	gzip -9c ppd/RP425.ppd > $(PPDDIR)/RP425.ppd.gz
	chown root:wheel $(PPDDIR)/RP425.ppd.gz && chmod 644 $(PPDDIR)/RP425.ppd.gz
	install -o root -g wheel -m 755 build/rp425 $(PREFIX)/bin/rp425

uninstall:
	@test "$$(id -u)" = 0 || { echo "run: sudo make uninstall"; exit 1; }
	-lpadmin -x RP425 2>/dev/null
	rm -rf $(DRIVER) $(PPDDIR)/RP425.ppd.gz $(PREFIX)/bin/rp425

# Adds a CUPS queue named RP425 for the USB-attached printer.
queue:
	@uri=$$(lpinfo -v 2>/dev/null | awk '/usb:.*RP425/ {print $$2; exit}'); \
	test -n "$$uri" || { echo "RP425 not found by lpinfo -v (is it plugged in and on?)"; exit 1; }; \
	lpadmin -p RP425 -E -D "Rongta RP425" -v "$$uri" -P $(PPDDIR)/RP425.ppd.gz -o PageSize=w288h432 && \
	echo "Added queue RP425 -> $$uri"

ui:
	python3 ui/rp425-ui.py

clean:
	rm -rf build

.PHONY: all test test-print install uninstall queue ui clean
