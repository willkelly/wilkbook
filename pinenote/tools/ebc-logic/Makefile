# Host-side tests for the EBC driver (offline testing ladder).
#
# Binaries over the same verbatim driver sources (extracted from the
# forward-port patch at build time):
#   ebc-logic-test    rung 2: unit tests for the pure logic (blitters,
#                     damage scheduling, threshold/dither paths)
#   ebc-refresh-test  rung 7a: executes the refresh state machine against
#                     a behavioral device model (shim/fake-ebc.h), built
#                     with ASan; see doc/ebc-harness-spike.md
#   ebc-refresh-test-dbg  the same TU compiled against the DEBUG driver:
#                     the extraction with pinenote/patches/
#                     linux-pinenote-debug-*.patch applied (the exact
#                     stack the linux-pinenote-debug kernel carries) and
#                     -DEBC_HARNESS_DBG.  Runs the whole rung-7a suite
#                     (proving the debug patches change no refresh
#                     behavior: same goldens) plus the EXTRACT_FBS ioctl
#                     tests.  No debug hunk ships un-executed.
#   ebc-fbdev-order-test  the only binary that defines
#                     CONFIG_DRM_FBDEV_EMULATION, so it is the only one
#                     that compiles the driver's four fbdev-guarded
#                     blocks (defio_delay_ms, the fbdev_probe wrapper and
#                     its .fbdev_probe slot, the publish-on-call
#                     deferred-io drain, the resume barrier, remove()'s
#                     clearing of the helper static).  Everywhere else
#                     those compile as the #else stub.  Its shim
#                     workqueue is SYNCHRONOUS: it proves ORDERING, never
#                     the absence of a race -- read the file header.
#   ebc-fbdev-order-test-prefix  the SAME source against the pre-fix
#                     ordering (mutate-prefix-order.py moves the arm back
#                     after the drain, exactly what commit 8665ed8
#                     changed).  run-tests.sh requires this one to FAIL:
#                     a test that passes on both orderings proves nothing.
#   ebc-drain-gate-test  issue #22: under a sustained damage supply a
#                     queued global refresh (or a kthread_park) must
#                     still launch, within one area lifetime.
#   ebc-drain-gate-test-nogate  the SAME source against the driver with
#                     the drain gate removed (mutate-drain-gate.py).
#                     EXPECTED TO FAIL; run-tests.sh asserts that it does.
#   ebc-refresh-starvation-test  the pinned `quirk:` reproduction of the
#                     inherited starvation, ALSO built against the
#                     ungated driver -- the shipping one no longer
#                     starves, which is what the drain-gate test proves.
#   ebc-replay        the rung-7a phase-B workbench: replays KOReader
#                     [pn-refresh] traces through the same machine under
#                     candidate refresh policies (doc/refresh-policy.md).
#                     Built without ASan — it is a measurement tool that
#                     scans full-panel buffers per frame; the same driver
#                     paths run under ASan in ebc-refresh-test.
#   ebc-dump          host decoder for EXTRACT_FBS dump containers
#                     (ebc-dump-format.h): PGMs, diffs, --json for
#                     optics/analyze.py.  Pinned to the driver's Y4
#                     conventions by the dbg suite's decode differential.
#   ebc-dump-grab     the on-device grabber (PineNote/debug kernel);
#                     compiled here only as a build-proof — the real
#                     cross-build is the pinenote-ebc-dump package
#                     (pinenote/packages/firmware.scm).
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
CXX := g++
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

# The debug-driver variant: the same extraction with the exact active
# linux-pinenote-debug patch stack.  Keep this explicit: a wildcard plus a
# tolerated failure can compile a partially patched driver.
DBGDIR := $(BUILD)/dbg
DBG_PATCHES := ../../patches/linux-pinenote-debug-extract-fbs.patch
DBG_DRIVER := $(DBGDIR)/drivers/gpu/drm/rockchip/rockchip_ebc.c

# The pre-fix-ordering variant, for negative-testing the ordering test.
PREFIXDIR := $(BUILD)/prefix
PREFIX_DRIVER := $(PREFIXDIR)/drivers/gpu/drm/rockchip/rockchip_ebc.c

# The pre-issue-#22 variant: the same extraction with the work-item drain
# gate removed, i.e. the driver as the m-weigand lineage still ships it.
# It carries the pinned starvation `quirk:` and negative-tests the gate.
NOGATEDIR := $(BUILD)/nogate
NOGATE_DRIVER := $(NOGATEDIR)/drivers/gpu/drm/rockchip/rockchip_ebc.c

all: header-check $(BUILD)/ebc-logic-test $(BUILD)/ebc-refresh-test \
     $(BUILD)/ebc-refresh-test-dbg $(BUILD)/ebc-refresh-starvation-test \
     $(BUILD)/ebc-drain-gate-test $(BUILD)/ebc-drain-gate-test-nogate \
     $(BUILD)/ebc-suspend-bracket-test \
     $(BUILD)/ebc-fbdev-order-test $(BUILD)/ebc-fbdev-order-test-prefix \
     $(BUILD)/ebc-replay \
     $(BUILD)/ebc-dump $(BUILD)/ebc-dump-grab

header-check: $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h
	$(CC) $(CFLAGS) -Ishim/uapi -x c -fsyntax-only \
	  -include $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h /dev/null
	$(CXX) $(CFLAGS) -Ishim/uapi -x c++ -fsyntax-only \
	  -include $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h /dev/null

$(EXTRACTED) &: $(PATCH) $(EXTRACT)
	python3 $(EXTRACT) $(PATCH) $(BUILD) \
	  drivers/gpu/drm/rockchip/rockchip_ebc.c \
	  drivers/gpu/drm/drm_epd_helper.c \
	  include/drm/drm_epd_helper.h \
	  include/uapi/drm/rockchip_ebc_drm.h
	cp $(BUILD)/include/uapi/drm/rockchip_ebc_drm.h $(BUILD)/include/drm/

$(DBG_DRIVER): $(PATCH) $(EXTRACT) $(DBG_PATCHES)
	rm -rf $(DBGDIR)
	python3 $(EXTRACT) $(PATCH) $(DBGDIR) \
	  drivers/gpu/drm/rockchip/rockchip_ebc.c
	set -e; for p in $(DBG_PATCHES); do \
	  echo "applying $$p"; \
	  patch --dry-run -p1 -d $(DBGDIR) < $$p; \
	  patch -p1 -d $(DBGDIR) < $$p; \
	done

$(BUILD)/ebc-logic-test: ebc-logic-test.c $(EXTRACTED) shim/kernel-shim.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ ebc-logic-test.c

$(BUILD)/rastersim-asan.o: ../rastersim/rastersim.c ../rastersim/rastersim.h
	$(CC) $(CFLAGS) $(ASAN) -c -o $@ ../rastersim/rastersim.c

$(BUILD)/ebc-refresh-test: ebc-refresh-test.c $(EXTRACTED) shim/kernel-shim.h \
                           shim/fake-ebc.h $(BUILD)/rastersim-asan.o
	$(CC) $(CFLAGS) $(ASAN) $(CPPFLAGS) -o $@ ebc-refresh-test.c \
	  $(BUILD)/rastersim-asan.o

# -I$(DBGDIR)/... first so `#include "rockchip_ebc.c"` resolves to the
# debug-patched driver.
$(BUILD)/ebc-refresh-test-dbg: ebc-refresh-test.c $(EXTRACTED) \
                               shim/kernel-shim.h shim/fake-ebc.h \
                               ebc-dump-format.h $(DBG_DRIVER) \
                               $(BUILD)/rastersim-asan.o
	$(CC) $(CFLAGS) $(ASAN) -DEBC_HARNESS_DBG=1 \
	  -I$(DBGDIR)/drivers/gpu/drm/rockchip $(CPPFLAGS) \
	  -o $@ ebc-refresh-test.c $(BUILD)/rastersim-asan.o

# Liveness, not correctness: pins that a sustained damage supply starves the
# global-refresh / REFRESH_BARRIER path (the 2026-07-29 hardware failure).
# Waveform-gated, because the starvation boundary IS the waveform's phase
# count -- it skips cleanly without a WBF.
#
# Built against build/nogate (the extraction with the issue-#22 work-item
# drain gate REMOVED): this file is the pinned `quirk:` record of the
# inherited m-weigand-lineage defect, and the shipping driver no longer
# reproduces it.  ebc-drain-gate-test is the shipping driver's side.
$(BUILD)/ebc-refresh-starvation-test: ebc-refresh-starvation-test.c \
                                      $(EXTRACTED) shim/kernel-shim.h \
                                      shim/fake-ebc.h $(NOGATE_DRIVER)
	$(CC) $(CFLAGS) $(ASAN) \
	  -I$(NOGATEDIR)/drivers/gpu/drm/rockchip $(CPPFLAGS) \
	  -o $@ ebc-refresh-starvation-test.c

# The positive counterpart (issue #22): under the same sustained damage
# supply, a queued global refresh / park MUST launch within a bounded
# number of frames.  Waveform-gated for the same reason -- the bound IS
# the waveform's phase count.
$(BUILD)/ebc-drain-gate-test: ebc-drain-gate-test.c \
                              $(EXTRACTED) shim/kernel-shim.h \
                              shim/fake-ebc.h
	$(CC) $(CFLAGS) $(ASAN) $(CPPFLAGS) -o $@ ebc-drain-gate-test.c

# ... and the negative test of that test: the SAME source against the
# ungated driver.  This binary is EXPECTED TO FAIL; run-tests.sh asserts
# that it does.  A liveness test that passes with and without the gate
# would prove nothing.
$(BUILD)/ebc-drain-gate-test-nogate: ebc-drain-gate-test.c $(EXTRACTED) \
                                     shim/kernel-shim.h shim/fake-ebc.h \
                                     $(NOGATE_DRIVER)
	$(CC) $(CFLAGS) $(ASAN) \
	  -I$(NOGATEDIR)/drivers/gpu/drm/rockchip $(CPPFLAGS) \
	  -o $@ ebc-drain-gate-test.c

# Not waveform-gated: drives only the system-sleep park/wake bracket.
$(BUILD)/ebc-suspend-bracket-test: ebc-suspend-bracket-test.c \
                                   $(EXTRACTED) shim/kernel-shim.h \
                                   shim/fake-ebc.h
	$(CC) $(CFLAGS) $(ASAN) $(CPPFLAGS) -o $@ ebc-suspend-bracket-test.c

# The fbdev-guarded code.  -pthread: the refresh thread runs on a second
# task so a wake_up_process() can actually preempt its waker (still a
# strict baton handoff -- ordering, not a race; see the file header).
$(BUILD)/ebc-fbdev-order-test: ebc-fbdev-order-test.c $(EXTRACTED) \
                               shim/kernel-shim.h shim/fake-ebc.h
	$(CC) $(CFLAGS) $(ASAN) $(CPPFLAGS) -pthread \
	  -o $@ ebc-fbdev-order-test.c

$(PREFIX_DRIVER): $(EXTRACTED) mutate-prefix-order.py
	rm -rf $(PREFIXDIR)
	python3 mutate-prefix-order.py \
	  $(BUILD)/drivers/gpu/drm/rockchip/rockchip_ebc.c $@

$(NOGATE_DRIVER): $(EXTRACTED) mutate-drain-gate.py
	rm -rf $(NOGATEDIR)
	python3 mutate-drain-gate.py \
	  $(BUILD)/drivers/gpu/drm/rockchip/rockchip_ebc.c $@

# -I$(PREFIXDIR)/... first so `#include "rockchip_ebc.c"` resolves to the
# pre-fix-ordered driver.  This binary is EXPECTED TO FAIL; run-tests.sh
# asserts that it does.
$(BUILD)/ebc-fbdev-order-test-prefix: ebc-fbdev-order-test.c $(EXTRACTED) \
                                      shim/kernel-shim.h shim/fake-ebc.h \
                                      $(PREFIX_DRIVER)
	$(CC) $(CFLAGS) $(ASAN) \
	  -I$(PREFIXDIR)/drivers/gpu/drm/rockchip $(CPPFLAGS) -pthread \
	  -o $@ ebc-fbdev-order-test.c

$(BUILD)/ebc-replay: ebc-replay.c $(EXTRACTED) shim/kernel-shim.h \
                     shim/fake-ebc.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ ebc-replay.c -lm

$(BUILD)/ebc-dump: ebc-dump.c ebc-dump-format.h
	$(CC) $(CFLAGS) -o $@ ebc-dump.c

$(BUILD)/ebc-dump-grab: ebc-dump-grab.c ebc-dump-format.h
	$(CC) $(CFLAGS) -o $@ ebc-dump-grab.c

check: all
	./run-tests.sh $(BUILD) "$(WBF)"
	./run-tests-dbg.sh $(BUILD) "$(WBF)"

# Regenerate the committed refresh-harness golden hashes (only when a
# scenario or the synthetic LUT changes intentionally).
regen-goldens: $(BUILD)/ebc-refresh-test
	$(BUILD)/ebc-refresh-test "" "" $(BUILD)
	cd $(BUILD) && sha256sum refresh-drive-count.pgm refresh-final.pgm \
	  > ../testdata/refresh-goldens.sha256

clean:
	rm -rf $(BUILD)

.PHONY: all check header-check regen-goldens clean
