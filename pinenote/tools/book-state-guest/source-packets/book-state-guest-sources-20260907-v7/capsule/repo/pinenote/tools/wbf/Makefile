# Host-side .wbf waveform parser tests (offline testing ladder, rung 1).
# Compiles the verbatim drm_epd_helper.[ch] from the forward-port patch.
#
#   guix shell gcc-toolchain python -- make check WBF=/path/to/ebc.wbf
#
# The waveform file is per-device and never committed (see the repo
# firmware/waveform policy); point WBF at the device's own copy (backup
# ledger in doc/device-runbook.md, or pull /lib/firmware/rockchip/ebc.wbf
# from the running device).

# PATCH/EXTRACT/PYTHON are overridable so the pinenote-wbf-clut Guix
# package can cross-build wbf-clut out of this same Makefile with the
# patch and extractor copied flat beside the sources (the shape
# pinenote-ebc-barrier-test already uses).
PATCH ?= ../../patches/linux-pinenote-7.0-forward-port.patch
EXTRACT ?= extract-from-patch.py
PYTHON ?= python3
BUILD ?= build
PREFIX ?= /usr/local
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -g
CPPFLAGS := -Ishim -I$(BUILD) -I$(BUILD)/include/drm

EXTRACTED := $(BUILD)/drivers/gpu/drm/drm_epd_helper.c \
             $(BUILD)/include/drm/drm_epd_helper.h

all: $(BUILD)/wbf-info $(BUILD)/wbf-clut $(BUILD)/wbf-clut-selftest \
     $(BUILD)/wbf-clut-diff

$(EXTRACTED) &: $(PATCH) $(EXTRACT)
	$(PYTHON) $(EXTRACT) $(PATCH) $(BUILD) \
	  drivers/gpu/drm/drm_epd_helper.c include/drm/drm_epd_helper.h
	mkdir -p $(BUILD)/drm
	cp $(BUILD)/include/drm/drm_epd_helper.h $(BUILD)/drm/

$(BUILD)/wbf-info: wbf-info.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -I$(BUILD)/drivers/gpu/drm \
	  -o $@ wbf-info.c

# The SHIPPING CLUT compiler: exactly what pinenote-wbf-clut cross-builds
# for the device, with no mutation knobs compiled in at all.
$(BUILD)/wbf-clut: wbf-clut.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -I$(BUILD)/drivers/gpu/drm \
	  -o $@ wbf-clut.c

# The decode-fidelity differ (doc/status.md 2026-08-27): the verbatim
# helper's 4BIT_PACKED view vs an independent walk of a compiled
# CLUT0002, per (bin, slot, from, to).  Needs the per-device WBF and a
# CLUT compiled from it:  make clut-diff WBF=... CLUT=...
$(BUILD)/wbf-clut-diff: wbf-clut-diff.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -I$(BUILD)/drivers/gpu/drm \
	  -o $@ wbf-clut-diff.c

.PHONY: clut-diff
clut-diff: $(BUILD)/wbf-clut-diff
	@test -n "$(WBF)" -a -n "$(CLUT)" || \
	  { echo "usage: make clut-diff WBF=/path/ebc.wbf CLUT=/path/custom_wf.bin"; exit 2; }
	$(BUILD)/wbf-clut-diff $(WBF) $(CLUT)

# The same source with -DWBF_CLUT_MUTATIONS, which unlocks --mutate=...
# knobs that each break ONE of the two reproduced upstream quirks (or the
# from/to axis mapping).  run-clut-tests.sh requires every mutated output
# to DIFFER from the reference: without that, "byte-identical" would pass
# for an implementation whose fidelity was accidental.
$(BUILD)/wbf-clut-selftest: wbf-clut.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -DWBF_CLUT_MUTATIONS \
	  -I$(BUILD)/drivers/gpu/drm -o $@ wbf-clut.c

check: $(BUILD)/wbf-info
	@test -n "$(WBF)" || { echo "usage: make check WBF=/path/to/ebc.wbf" >&2; exit 2; }
	./run-tests.sh $(BUILD)/wbf-info "$(WBF)"

# Byte-identical differential against hrdl's wbf_to_custom.py.  Needs both
# the per-device waveform (WBF=) and the reference tree (CLUT_REF=), and
# says out loud what it skipped when either is missing.
clut-check: $(BUILD)/wbf-clut $(BUILD)/wbf-clut-selftest $(BUILD)/wbf-info \
            $(BUILD)/wbf-clut-diff
	WBF="$(WBF)" \
	  $(if $(CLUT_REF),CLUT_REF="$(CLUT_REF)",) \
	  $(if $(CLUT_REF_BIN),CLUT_REF_BIN="$(CLUT_REF_BIN)",) \
	  $(if $(CLUT_PYTHON),CLUT_PYTHON="$(CLUT_PYTHON)",) \
	  ./run-clut-tests.sh $(BUILD)/wbf-clut $(BUILD)/wbf-clut-selftest \
	  $(BUILD)/wbf-info

# Device install: the CLUT compiler only.  wbf-info and the selftest build
# are host diagnostics and have no business in an image.
install: $(BUILD)/wbf-clut
	install -Dm755 $(BUILD)/wbf-clut $(DESTDIR)$(PREFIX)/bin/wbf-clut

clean:
	rm -rf $(BUILD)

.PHONY: all check clut-check install clean
