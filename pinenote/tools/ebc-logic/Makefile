# Host-side tests for the EBC driver (offline testing ladder).
#
# Three binaries over the same verbatim driver sources (extracted from
# the forward-port patch at build time):
#   ebc-logic-test    rung 2: unit tests for the pure logic (blitters,
#                     damage scheduling, threshold/dither paths)
#   ebc-refresh-test  rung 7a: executes the refresh state machine against
#                     a behavioral device model (shim/fake-ebc.h), built
#                     with ASan; see doc/ebc-harness-spike.md
#   ebc-replay        the rung-7a phase-B workbench: replays KOReader
#                     [pn-refresh] traces through the same machine under
#                     candidate refresh policies (doc/refresh-policy.md).
#                     Built without ASan — it is a measurement tool that
#                     scans full-panel buffers per frame; the same driver
#                     paths run under ASan in ebc-refresh-test.
#
#   guix shell gcc-toolchain python -- make check [WBF=/path/to/ebc.wbf]
#
# WBF is optional: without it the waveform-dependent tests are skipped
# with a clear message.  The waveform file is per-device and never
# committed (see the repo firmware/waveform policy).

PATCH := ../../patches/linux-pinenote-7.0-forward-port.patch
EXTRACT := ../wbf/extract-from-patch.py
BUILD := build
# := (not ?=): make's builtin CC=cc would silently pick the system
# compiler even inside `guix shell gcc-toolchain`, and the ASan runtime
# must come from the same toolchain as the instrumented code.
CC := gcc
# -Wno-maybe-uninitialized: rockchip_ebc.c's blit_pixels assigns
# first_odd/last_odd under the same conditions it reads them; the kernel
# build does not enable this warning either.
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -Wno-maybe-uninitialized -g
ASAN := -fsanitize=address -fno-omit-frame-pointer
CPPFLAGS := -Ishim -I$(BUILD)/include \
            -I$(BUILD)/drivers/gpu/drm -I$(BUILD)/drivers/gpu/drm/rockchip

EXTRACTED := $(BUILD)/drivers/gpu/drm/rockchip/rockchip_ebc.c \
             $(BUILD)/drivers/gpu/drm/drm_epd_helper.c \
             $(BUILD)/include/drm/drm_epd_helper.h \
             $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h

all: $(BUILD)/ebc-logic-test $(BUILD)/ebc-refresh-test $(BUILD)/ebc-replay

$(EXTRACTED) &: $(PATCH) $(EXTRACT)
	python3 $(EXTRACT) $(PATCH) $(BUILD) \
	  drivers/gpu/drm/rockchip/rockchip_ebc.c \
	  drivers/gpu/drm/drm_epd_helper.c \
	  include/drm/drm_epd_helper.h \
	  include/uapi/drm/rockchip_ebc_drm.h
	cp $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h $(BUILD)/include/drm/

$(BUILD)/ebc-logic-test: ebc-logic-test.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ ebc-logic-test.c

$(BUILD)/rastersim-asan.o: ../rastersim/rastersim.c ../rastersim/rastersim.h
	$(CC) $(CFLAGS) $(ASAN) -c -o $@ ../rastersim/rastersim.c

$(BUILD)/ebc-refresh-test: ebc-refresh-test.c $(EXTRACTED) shim/kernel-shim.h \
                           shim/fake-ebc.h $(BUILD)/rastersim-asan.o
	$(CC) $(CFLAGS) $(ASAN) $(CPPFLAGS) -o $@ ebc-refresh-test.c \
	  $(BUILD)/rastersim-asan.o

$(BUILD)/ebc-replay: ebc-replay.c $(EXTRACTED) shim/kernel-shim.h \
                     shim/fake-ebc.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ ebc-replay.c -lm

check: all
	./run-tests.sh $(BUILD) "$(WBF)"

# Regenerate the committed refresh-harness golden hashes (only when a
# scenario or the synthetic LUT changes intentionally).
regen-goldens: $(BUILD)/ebc-refresh-test
	$(BUILD)/ebc-refresh-test "" "" $(BUILD)
	cd $(BUILD) && sha256sum refresh-drive-count.pgm refresh-final.pgm \
	  > ../testdata/refresh-goldens.sha256

clean:
	rm -rf $(BUILD)

.PHONY: all check regen-goldens clean
