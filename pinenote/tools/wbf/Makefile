# Host-side .wbf waveform parser tests (offline testing ladder, rung 1).
# Compiles the verbatim drm_epd_helper.[ch] from the forward-port patch.
#
#   guix shell gcc-toolchain python -- make check WBF=/path/to/ebc.wbf
#
# The waveform file is per-device and never committed (see the repo
# firmware/waveform policy); point WBF at the device's own copy (backup
# ledger in doc/device-runbook.md, or pull /lib/firmware/rockchip/ebc.wbf
# from the running device).

PATCH := ../../patches/linux-pinenote-7.0-forward-port.patch
BUILD := build
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -g
CPPFLAGS := -Ishim -I$(BUILD) -I$(BUILD)/include/drm

EXTRACTED := $(BUILD)/drivers/gpu/drm/drm_epd_helper.c \
             $(BUILD)/include/drm/drm_epd_helper.h

all: $(BUILD)/wbf-info

$(EXTRACTED) &: $(PATCH) extract-from-patch.py
	python3 extract-from-patch.py $(PATCH) $(BUILD) \
	  drivers/gpu/drm/drm_epd_helper.c include/drm/drm_epd_helper.h
	mkdir -p $(BUILD)/drm
	cp $(BUILD)/include/drm/drm_epd_helper.h $(BUILD)/drm/

$(BUILD)/wbf-info: wbf-info.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -I$(BUILD)/drivers/gpu/drm \
	  -o $@ wbf-info.c

check: $(BUILD)/wbf-info
	@test -n "$(WBF)" || { echo "usage: make check WBF=/path/to/ebc.wbf" >&2; exit 2; }
	./run-tests.sh $(BUILD)/wbf-info "$(WBF)"

clean:
	rm -rf $(BUILD)

.PHONY: all check clean
