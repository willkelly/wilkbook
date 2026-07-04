# Host-side unit tests for the EBC driver's pure logic (offline testing
# ladder, rung 2).  Compiles the verbatim rockchip_ebc.c (and its LUT
# dependency drm_epd_helper.c) from the forward-port patch against a
# kernel-API shim, then unit-tests the blitters, the damage-area
# scheduler, and the threshold/dither paths.
#
#   guix shell gcc-toolchain python -- make check [WBF=/path/to/ebc.wbf]
#
# WBF is optional: without it the (few) waveform-dependent tests are
# skipped with a clear message.  The waveform file is per-device and never
# committed (see the repo firmware/waveform policy).

PATCH := ../../patches/linux-pinenote-7.0-forward-port.patch
EXTRACT := ../wbf/extract-from-patch.py
BUILD := build
CC ?= gcc
# -Wno-maybe-uninitialized: rockchip_ebc.c's blit_pixels assigns
# first_odd/last_odd under the same conditions it reads them; the kernel
# build does not enable this warning either.
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -Wno-maybe-uninitialized -g
CPPFLAGS := -Ishim -I$(BUILD)/include \
            -I$(BUILD)/drivers/gpu/drm -I$(BUILD)/drivers/gpu/drm/rockchip

EXTRACTED := $(BUILD)/drivers/gpu/drm/rockchip/rockchip_ebc.c \
             $(BUILD)/drivers/gpu/drm/drm_epd_helper.c \
             $(BUILD)/include/drm/drm_epd_helper.h \
             $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h

all: $(BUILD)/ebc-logic-test

$(EXTRACTED) &: $(PATCH) $(EXTRACT)
	python3 $(EXTRACT) $(PATCH) $(BUILD) \
	  drivers/gpu/drm/rockchip/rockchip_ebc.c \
	  drivers/gpu/drm/drm_epd_helper.c \
	  include/drm/drm_epd_helper.h \
	  include/uapi/drm/rockchip_ebc_drm.h
	cp $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h $(BUILD)/include/drm/

$(BUILD)/ebc-logic-test: ebc-logic-test.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ ebc-logic-test.c

check: $(BUILD)/ebc-logic-test
	./run-tests.sh $(BUILD)/ebc-logic-test "$(WBF)"

clean:
	rm -rf $(BUILD)

.PHONY: all check clean
