# Convenience wrapper around the build commands in doc/building.md.
# Everything cross-builds for aarch64 and writes only to the Guix store
# and $(ARTIFACTS).

GUIX = guix
TARGET = aarch64-linux-gnu
GUIX_FLAGS = -L . --target=$(TARGET)
ARTIFACTS ?= /tmp/opencode/pinenote-rootfs-artifacts

# reader-debug = reader with the EXTRACT_FBS diagnostic kernel
# (linux-pinenote-debug); remove with the debug patch when done.
FLAVORS = minimal slim networked dev usb-console usb-console-linux-6-6 reader reader-debug

.PHONY: help packages kernel kernel-drv qemu-smoke qemu-virt qemu-virt-check \
         wbf-check ebc-logic-check ebc-barrier-check rastersim-check koreader-input-check orientation-check optics-check power-check rockchip-pm-check activation-positive-check suspend-check \
        $(FLAVORS) $(addprefix image-,$(FLAVORS)) $(addprefix rootfs-,$(FLAVORS))

help:
	@echo "Targets:"
	@echo "  <flavor>          build the system closure ($(FLAVORS))"
	@echo "  image-<flavor>    build the raw-with-offset disk image"
	@echo "  rootfs-<flavor>   image + extract + inspect PNGuixRoot rootfs into $(ARTIFACTS)"
	@echo "  kernel-drv        compute the linux-pinenote derivation (cheap gate)"
	@echo "  kernel            build the forward-ported linux-pinenote"
	@echo "  packages          build the helper/firmware packages"
	@echo "  qemu-smoke        build the generic ARM64 QEMU smoke VM launcher"
	@echo "  qemu-virt-check   mechanized virt boot assertions (ROOTFS=.. [WAVEFORM=..])"
	@echo "  wbf-check         waveform parser checks (WBF=..; never committed)"
	@echo "  ebc-logic-check   extracted EBC driver logic checks ([WBF=..])"
	@echo "  ebc-barrier-check supervised EBC sleep-frame command host tests"
	@echo "  rastersim-check   raster/waveform simulation checks ([WBF=..])"
	@echo "  koreader-input-check  KOReader input, touch, and virtual-node lifecycle tests"
	@echo "  orientation-check SC7A20 classifier and uinput bridge tests"
	@echo "  optics-check      deterministic recorder/bundle/analysis tests"
	@echo "  power-check       fake-root tests for the read-only Guile power recorder"
	@echo "  rockchip-pm-check dormant BSP SIP/PM model, DTB, and zero-call checks"
	@echo "  activation-positive-check  fake capabilities/coordinator + active PM scenario; production hard-off"
	@echo "  suspend-check     offline fail-closed e-reader suspend qualification gates"
	@echo
	@echo "Deployment is manual by design: see doc/hardware-deploy.md."

$(FLAVORS): %:
	$(GUIX) system build $(GUIX_FLAGS) pinenote/systems/pinenote-$*.scm

$(addprefix image-,$(FLAVORS)): image-%:
	$(GUIX) system image -t raw-with-offset $(GUIX_FLAGS) pinenote/systems/pinenote-$*.scm

$(addprefix rootfs-,$(FLAVORS)): rootfs-%:
	@set -e; \
	image=$$($(GUIX) system image -t raw-with-offset $(GUIX_FLAGS) pinenote/systems/pinenote-$*.scm); \
	mkdir -p $(ARTIFACTS); \
	rootfs=$(ARTIFACTS)/pinenote-$*-PNGuixRoot-$$(date +%Y%m%d).ext4; \
	pinenote/scripts/preflight/extract-rootfs-from-raw.sh "$$image" "$$rootfs"; \
	pinenote/scripts/preflight/inspect-rootfs-image.sh "$$rootfs"; \
	echo "rootfs ready: $$rootfs"

kernel-drv:
	$(GUIX) build -d -L . --target=$(TARGET) \
	  -e '(@ (pinenote packages kernel) linux-pinenote)'

kernel:
	$(GUIX) build -L . --target=$(TARGET) \
	  -e '(@ (pinenote packages kernel) linux-pinenote)'

packages:
	$(GUIX) build $(GUIX_FLAGS) pinenote-ebc-test pinenote-ebc-barrier-test pinenote-diagnostics \
	  pinenote-firmware-support pinenote-broadcom-wifi-firmware \
	  pinenote-broadcom-bt-firmware

qemu-smoke:
	$(GUIX) system vm $(GUIX_FLAGS) pinenote/systems/qemu-aarch64-smoke.scm
	@echo "Run the printed launcher with:"
	@echo "  guix shell qemu -- <launcher> -M virt -cpu max -nographic -no-reboot"

# Boot the real PineNote kernel/initrd/rootfs in QEMU virt with a synthetic
# PineNote-layout disk (waveform partition + PNGuixRoot). Usage:
#   make qemu-virt ROOTFS=/tmp/opencode/pinenote-rootfs-artifacts/...ext4 \
#        [WAVEFORM=/path/to/waveform.bin]
qemu-virt:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-virt ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	bundle=/tmp/opencode/pinenote-virt-bundle-$$stamp; \
	disk=/tmp/opencode/pinenote-virt-disk-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-pinenote-virt.sh \"$$bundle\" \"$$disk\""

# Mechanized qemu-virt boot assertions (offline ladder rung 4): boot the real
# kernel/initrd/rootfs on virt, capture the console, and assert the boot
# milestones through Shepherd start (kernel+PREEMPT_RT, initrd waveform
# install, EBC module load, PNGuixRoot pre-root visibility, root mount).
# Non-interactive; exits non-zero on any failed assertion. Usage:
#   make qemu-virt-check ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]
qemu-virt-check:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-virt-check ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	bundle=/tmp/opencode/pinenote-virtchk-bundle-$$stamp; \
	disk=/tmp/opencode/pinenote-virtchk-disk-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-assertions.sh \"$$bundle\" \"$$disk\""

# QEMU-virt visual loop (offline ladder rung 4v): same boot plus a
# virtio-gpu framebuffer at panel resolution and scripted virtio input;
# QMP screendumps assert KOReader paints and reacts to a tap. Usage:
#   make qemu-virt-visual ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]
qemu-virt-visual:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-virt-visual ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	bundle=/tmp/opencode/pinenote-virtvis-bundle-$$stamp; \
	disk=/tmp/opencode/pinenote-virtvis-disk-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-visual.sh \"$$bundle\" \"$$disk\""

# Host-side waveform parser tests (offline ladder rung 1); needs the
# per-device .wbf (never committed): make wbf-check WBF=/path/to/ebc.wbf
wbf-check:
	guix shell gcc-toolchain python -- $(MAKE) -C pinenote/tools/wbf check WBF=$(WBF)

# EBC driver logic unit tests against the verbatim rockchip_ebc.c from
# the forward-port patch (offline ladder rung 2). WBF optional; without
# it the waveform-dependent tests are skipped:
#   make ebc-logic-check [WBF=/path/to/ebc.wbf]
ebc-logic-check:
	guix shell gcc-toolchain python -- $(MAKE) -C pinenote/tools/ebc-logic check WBF=$(WBF)

# Host-only fake-operation coverage for the separately invoked sleep-frame
# diagnostic.  It extracts the barrier UAPI from the permanent kernel patch;
# this target never invokes --run or opens device nodes.
ebc-barrier-check:
	guix shell gcc-toolchain python -- $(MAKE) -C pinenote/tools/ebc-barrier check

# Gray8->Y4 raster library + waveform simulator tests (offline ladder
# rung 3). WBF optional; without it the waveform-dependent tests are
# skipped: make rastersim-check [WBF=/path/to/ebc.wbf]
rastersim-check:
	guix shell gcc-toolchain python -- $(MAKE) -C pinenote/tools/rastersim check WBF=$(WBF)

# KOReader input-routing tests against the verbatim bundle sources
# (native koreader-bin, resolved via `guix build` -- cached; override
# with KOREADER_BUNDLE=/gnu/store/...): proves the pen-hover tap-capture
# bug and validates the mixedrouter fix.
koreader-input-check:
	$(MAKE) -C pinenote/tools/koreader-input check KOREADER_BUNDLE=$(KOREADER_BUNDLE)

orientation-check:
	guix shell luajit -- $(MAKE) -C pinenote/tools/orientation check

# E-ink optical-defect detectors (optics harness analysis core). Deterministic
# validation of the flash/ghost/settle/double-flash classifiers against
# synthetic clips with known injected defects; no camera, no device.
#   make optics-check
optics-check:
	guix shell python python-numpy python-scipy python-pillow ffmpeg -- $(MAKE) -C pinenote/tools/optics check

# Read-only power snapshot/delta recorder tests.  Guile is present in the
# final4 system profile and the tool uses only base Guile modules.
power-check:
	guix shell guile python -- $(MAKE) -C pinenote/tools/power check

rockchip-pm-check:
	guix shell dtc gcc-toolchain git python -- $(MAKE) -C pinenote/tools/rockchip-pm check

# Deliberately composite: the positive fake scenarios may pass only alongside
# the unchanged production hard-off gate. Nothing here can write power state.
activation-positive-check:
	guix shell dtc gcc-toolchain git python luajit -- sh -c 'set -e; \
	  $(MAKE) -C pinenote/tools/power power-capabilities-check; \
	  $(MAKE) -C pinenote/tools/power ebc-sleep-frame-check; \
	  luajit pinenote/tools/power/test-power-coordinator.lua; \
	  $(MAKE) -C pinenote/tools/rockchip-pm activation-positive-check; \
	  sh pinenote/scripts/preflight/test-inspect-pinenote-suspend-gates.sh'

# Fail-closed suspend qualification checks. These prove only static config,
# approved DT wake capability, and restricted KOReader policy evaluation.
suspend-check:
	guix shell dtc python luajit -- sh pinenote/scripts/preflight/test-inspect-pinenote-suspend-gates.sh
	sh pinenote/scripts/preflight/validate-tps65185-pm-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-fbdev-resume-hunk.sh
	guix shell python -- sh pinenote/scripts/preflight/test-validate-ebc-fbdev-resume-hunk.sh
