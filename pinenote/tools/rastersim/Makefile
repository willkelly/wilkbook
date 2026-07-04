# Gray8->Y4 raster library + waveform simulator (offline ladder rung 3).
#
#   guix shell gcc-toolchain python -- make check [WBF=/path/to/ebc.wbf]
#
# Without WBF the waveform-dependent tests are skipped with a message;
# with it, ../wbf's wbf-info (which extracts the kernel's own LUT decoder
# from the forward-port patch — hence the python in the shell) dumps the
# GC16/GL16/A2/DU LUTs at 25 C for sim-wbf-test.  The .wbf is per-device
# and never committed.

BUILD := build
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -g

BINS := $(BUILD)/test-rastersim $(BUILD)/sim-wbf-test $(BUILD)/gen-testimage

all: $(BINS)

$(BUILD)/rastersim.o: rastersim.c rastersim.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ rastersim.c

$(BUILD)/test-rastersim: test-rastersim.c rastersim.h $(BUILD)/rastersim.o
	$(CC) $(CFLAGS) -o $@ test-rastersim.c $(BUILD)/rastersim.o

$(BUILD)/sim-wbf-test: sim-wbf-test.c rastersim.h $(BUILD)/rastersim.o
	$(CC) $(CFLAGS) -o $@ sim-wbf-test.c $(BUILD)/rastersim.o

$(BUILD)/gen-testimage: gen-testimage.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ gen-testimage.c

check: all
	./run-tests.sh $(BUILD) "$(WBF)"

# Regenerate the committed test image and quantization goldens (only
# needed when the image or a quantization mode changes intentionally;
# see README.md).
regen-goldens: $(BUILD)/gen-testimage $(BUILD)/test-rastersim
	$(BUILD)/gen-testimage testdata/gradient-checker.pgm
	$(BUILD)/test-rastersim dump-quant testdata/gradient-checker.pgm $(BUILD)
	cd $(BUILD) && sha256sum quant-shift.y4 quant-bw.y4 quant-ordered.y4 \
	  quant-fourtone.y4 quant-fs.y4 > ../testdata/quant-goldens.sha256
	od -A x -t x1 -v $(BUILD)/quant-shift.y4 > testdata/quant-shift.hex

clean:
	rm -rf $(BUILD)

.PHONY: all check regen-goldens clean
