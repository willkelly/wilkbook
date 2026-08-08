# Convenience wrapper around the build commands in doc/building.md.
# Everything cross-builds for aarch64 and writes only to the Guix store
# and $(ARTIFACTS).

GUIX = guix
TARGET = aarch64-linux-gnu
GUIX_FLAGS = -L . --target=$(TARGET)

# Per-checkout build flags, gitignored.  The only supported knob today is
# WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE (pinenote/insecure.scm), which is
# OFF unless this file turns it on -- so a plain checkout cannot build the
# development conveniences by accident.
-include local.mk
# Volatile by design: /tmp does not survive a host reboot, so rebuild
# (or copy out) anything a later deploy will reference.  The
# /tmp/opencode root is a historical name (a previous coding tool) that
# is load-bearing as the write-containment boundary hard-coded in the
# preflight/qemu scripts, so an ARTIFACTS override must still resolve
# under /tmp/opencode for the qemu-virt* targets (the scripts fail
# loudly on anything outside it).  Renaming the root is an open task
# that must move those scripts in the same change.
ARTIFACTS ?= /tmp/opencode/pinenote-rootfs-artifacts
# Which synthetic p7 qemu-data-check boots against:
#   os1-used     a lived-in Debian home, no library yet (the migrating friend)
#   with-library an existing /books that must be left alone (author's device)
#   empty        no Debian home at all (reprovisioned p7)
FIXTURE ?= os1-used

# reader-debug = reader with the EXTRACT_FBS diagnostic kernel
# (linux-pinenote-debug); remove with the debug patch when done.
FLAVORS = minimal slim networked dev usb-console usb-console-linux-6-6 reader reader-debug

.PHONY: help packages kernel kernel-drv qemu-smoke qemu-virt qemu-virt-check \
         check-host wbf-check ebc-logic-check ebc-barrier-check rastersim-check koreader-input-check orientation-check optics-check power-check rockchip-pm-check activation-positive-check suspend-check \
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
	@echo "  check-host        every host suite needing no hardware ([WBF=..] adds wbf-check + waveform-gated tests)"
	@echo "  wbf-check         waveform parser checks (WBF=..; never committed)"
	@echo "  ebc-logic-check   extracted EBC driver logic checks ([WBF=..])"
	@echo "  ebc-barrier-check supervised EBC sleep-frame command host tests"
	@echo "  rastersim-check   raster/waveform simulation checks ([WBF=..])"
	@echo "  koreader-input-check  KOReader input, touch, and virtual-node lifecycle tests"
	@echo "  orientation-check SC7A20 classifier and uinput bridge tests"
	@echo "  optics-check      deterministic recorder/bundle/analysis tests"
	@echo "  power-check       fake-root tests for the read-only Guile power recorder; auto-suspend post-wake policy"
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
#   make qemu-virt ROOTFS=$(ARTIFACTS)/...ext4 \
#        [WAVEFORM=/path/to/waveform.bin]
qemu-virt:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-virt ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-virt-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-virt-disk-$$stamp.img; \
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
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-virtchk-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-virtchk-disk-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-assertions.sh \"$$bundle\" \"$$disk\""

# QEMU-virt WITH a data partition (offline ladder rung 4d): the same boot,
# on a synthetic p7 that looks like a PineNote whose stock Debian os1 has
# been lived in.  Answers the questions no other rung can: does the library
# get created on a disk that already has a Debian home, does the pointer to
# that home resolve, is os1's home left byte-for-byte alone, and does
# KOReader come up pointed at the right place and stay up.  Usage:
#   make qemu-data-check ROOTFS=<rootfs.ext4> [WAVEFORM=<file>] [FIXTURE=...]
qemu-data-check:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-data-check ROOTFS=<rootfs.ext4> [WAVEFORM=<file>] [FIXTURE=os1-used|with-library|empty]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-datachk-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-datachk-disk-$$stamp.img; \
	data=$(ARTIFACTS)/pinenote-datachk-data-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/qemu/make-data-fixture.sh $(FIXTURE) \"$$data\" && \
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" '$(WAVEFORM)' \"$$data\" && \
	  VIRTCHK_EXPECT_DATA=$(FIXTURE) pinenote/scripts/qemu/run-virt-assertions.sh \"$$bundle\" \"$$disk\""

# QEMU-virt visual loop (offline ladder rung 4v): same boot plus a
# virtio-gpu framebuffer at panel resolution and scripted virtio input;
# QMP screendumps assert KOReader paints and reacts to a tap. Usage:
#   make qemu-virt-visual ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]
qemu-virt-visual:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-virt-visual ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-virtvis-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-virtvis-disk-$$stamp.img; \
	guix shell e2fsprogs gptfdisk qemu -- sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-visual.sh \"$$bundle\" \"$$disk\""

# Aggregate host gate (doc/testing.md, validation-ladder rung 1): every
# suite that needs no hardware and no per-device waveform, in one
# command.  wbf-check hard-requires WBF=, so it joins only when WBF is
# set; ebc-logic-check and rastersim-check accept the same optional WBF
# and skip their waveform-gated tests without it.
check-host: $(if $(WBF),wbf-check) ebc-logic-check ebc-barrier-check \
        rastersim-check koreader-input-check orientation-check optics-check \
        power-check rockchip-pm-check activation-positive-check suspend-check

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
	@# The harness does not define CONFIG_DRM_FBDEV_EMULATION, so the suite
	@# above is blind to the deferred-io drain and to its ordering against
	@# the wash. That ordering is worth one whole visible refresh pass.
	sh pinenote/scripts/preflight/validate-ebc-global-arm-order-hunk.sh

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
# final4 system profile and the tool uses only base Guile modules.  luajit
# joins for the auto-suspend post-wake policy gate, which executes the
# daemon's own extracted source.
power-check:
	guix shell guile python luajit -- $(MAKE) -C pinenote/tools/power check

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
# Pin the exact channel set this tree builds against.  channels.scm IS the
# reproducibility claim: `guix time-machine -C channels.scm -- ...` rebuilds
# the identical closure on any machine, which is the one thing a rolling
# binary distribution structurally cannot offer.  Regenerate and COMMIT it
# with each release.
channels-pin:
	guix describe -f channels > channels.scm
	@echo "channels.scm updated -- commit it with the release"

# What was built, from what, and its hash.  Committed at the tag, so the
# hash lives inside signed history rather than beside a download.
release-manifest:
	@test -n "$(ROOTFS)" || { echo "usage: make release-manifest ROOTFS=<rootfs.ext4>"; exit 2; }
	@test -f channels.scm || { echo "no channels.scm -- run: make channels-pin"; exit 2; }
	@set -e; \
	  { printf '# wilkbook release manifest\n'; \
	    printf '# git:      %s\n' "$$(git describe --always --dirty --tags)"; \
	    printf '# built:    %s\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	    printf '# channels: channels.scm at this commit (guix time-machine -C)\n'; \
	    printf '# verify:   sha256sum -c SHA256SUMS\n'; \
	    sha256sum "$(ROOTFS)" | sed 's|  .*/|  |'; } > SHA256SUMS
	@cat SHA256SUMS

# The reader's library directory and first-boot landing.  Structural, and
# negative-tested against six ways it has to be able to fail.
library-check:
	sh pinenote/scripts/preflight/validate-koreader-library.sh

suspend-check:
	guix shell dtc python luajit -- sh pinenote/scripts/preflight/test-inspect-pinenote-suspend-gates.sh
	sh pinenote/scripts/preflight/validate-tps65185-pm-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-fbdev-resume-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-resume-baseline-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-timeout-asymmetry.sh
	sh pinenote/scripts/preflight/validate-dmc-default-off.sh
	guix shell python -- sh pinenote/scripts/preflight/test-validate-ebc-fbdev-resume-hunk.sh
