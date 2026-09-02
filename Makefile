# Convenience wrapper around the build commands in doc/building.md.
# Everything cross-builds for aarch64 and writes only to the Guix store
# and $(ARTIFACTS).

GUIX_BASE = guix
# channels.scm IS the reproducibility claim (doc/release.md).  TIME_MACHINE=1
# routes every guix invocation through the pinned channels.
#
# REPAIRED 2026-08-26: the pin bump landed (channels.scm now carries the
# generation that builds linux-pinenote-7.1.x), and the gate was that
# `make kernel-drv TIME_MACHINE=1' resolves the IDENTICAL derivation as
# the ambient build.  From 2026-08-25 until then it was broken -- the
# committed pin predated nongnu:linux-7.1 and died at module evaluation
# with "Unbound variable" -- so the byte-identical-rebuild claim skips
# that window of main.  When bumping the kernel series again, bump the
# pin in the same change and re-run both gates (kernel-drv and
# kernel-version-check, each with TIME_MACHINE=1).
GUIX = $(if $(TIME_MACHINE),$(GUIX_BASE) time-machine -C channels.scm --,$(GUIX_BASE))
TARGET = aarch64-linux-gnu
GUIX_FLAGS = -L . --target=$(TARGET)

# Per-checkout build flags, gitignored.  Two supported knobs, one
# mechanism -- an environment variable the system definition reads, with
# this file as the way to make the choice stick:
#
#   WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE  (pinenote/insecure.scm) -- OFF
#     unless this file turns it on, so a plain checkout cannot build the
#     development conveniences by accident.
#   WILKBOOK_TIMEZONE                       (pinenote/timezone.scm)  -- the
#     build-time timezone for every flavor; Etc/UTC unless set, and an
#     unusable name is refused at evaluation time rather than shipped as a
#     dangling /etc/localtime.
#
# Both want the `export' form here (export WILKBOOK_TIMEZONE = Europe/Dublin),
# because what reads them is guix, not make.
-include local.mk

# CI / preprovisioned toolchains.  Every host suite below runs fine under an
# ordinary distro toolchain: they compile verbatim sources extracted from the
# patches and read committed fixtures, and none evaluates a Guix module,
# computes a derivation, or inspects the store.  The `guix shell' prefixes are
# toolchain convenience, not a correctness requirement.  Set HOST_TOOLCHAIN=1
# to use whatever is already on PATH:
#
#   make check-host HOST_TOOLCHAIN=1
#
# Opt-in: a plain `make check-host' behaves exactly as it always has, so a
# developer's reproducible toolchain is never silently bypassed.
ifeq ($(HOST_TOOLCHAIN),1)
guix-shell =
else
guix-shell = guix shell $(1) --
endif
# Volatile by design: /tmp does not survive a host reboot, so rebuild
# (or copy out) anything a later deploy will reference.  /tmp/wilkbook
# is load-bearing beyond being this default: it is the write-containment
# boundary hard-coded in the preflight/qemu scripts, so an ARTIFACTS
# override must still resolve under /tmp/wilkbook for the qemu-virt*
# targets (the scripts fail loudly on anything outside it).
ARTIFACTS ?= /tmp/wilkbook/pinenote-rootfs-artifacts
# Which synthetic p7 qemu-data-check boots against:
#   os1-used     a lived-in Debian home, no library yet (the migrating friend)
#   with-library an existing /books that must be left alone (author's device)
#   empty        no Debian home at all (reprovisioned p7)
FIXTURE ?= os1-used

# reader-debug = reader with the EXTRACT_FBS diagnostic kernel
# (linux-pinenote-debug); remove with the debug patch when done.
# reader-direct = reader with hrdl's direct-mode EBC driver
# (linux-pinenote-hrdl-direct).  A STUDY flavor: it builds, it has never
# run, and it is expected NOT to reach a working reader on a first boot
# (doc/pinenote-flavors.md says why).  Never a deploy candidate; remove
# with the direct-mode patch if the adoption bails out.
FLAVORS = minimal slim networked dev usb-console usb-console-linux-6-6 reader reader-debug reader-direct

.PHONY: help packages kernel kernel-drv reader-system-drv qemu-smoke qemu-virt qemu-virt-check qemu-update-check qemu-pageturn-campaign refresh-episodes-check refresh-trigger-check \
         check-host wbf-check wbf-notice clut-check ebc-logic-check ebc-barrier-check rastersim-check koreader-input-check orientation-check platform-controls-check optics-check optics-audit-dataset power-check rockchip-pm-check activation-positive-check suspend-check \
        battery-dtb-check time-machine-check gexp-modules-check \
        timezone-check kernel-version-check library-check \
        manuals-check ultra-coupling-check timesync-check \
        settings-check koreader-profile-check ebc-modprobe-options-check \
        ebc-clut-check ebc-card-resolution-check ebc-ioctl-roster-check update-path-check deploy reader-stop-check pen-check ebc-lab-check \
        $(FLAVORS) $(addprefix image-,$(FLAVORS)) $(addprefix rootfs-,$(FLAVORS))

help:
	@echo "Targets:"
	@echo "  <flavor>          build the system closure ($(FLAVORS))"
	@echo "  image-<flavor>    build the raw-with-offset disk image"
	@echo "  rootfs-<flavor>   image + extract + inspect PNGuixRoot rootfs into $(ARTIFACTS)"
	@echo "  kernel-drv        compute the linux-pinenote derivation (cheap gate)"
	@echo "  kernel-version-check  assert the resolved kernel is still 7.0.x (rung 2; needs guix)"
	@echo "  kernel            build the forward-ported linux-pinenote"
	@echo "  packages          build the helper/firmware packages"
	@echo "  qemu-smoke        build the generic ARM64 QEMU smoke VM launcher"
	@echo "  qemu-virt-check   mechanized virt boot assertions (ROOTFS=.. [WAVEFORM=..])"
	@echo "  qemu-pageturn-campaign  scripted page-turn/menu campaign + [pn-refresh] episode analysis (ROOTFS=..)"
	@echo "  refresh-episodes-check  self-test of the episode analyser against the issue-#14 fixture"
	@echo "  refresh-trigger-check   self-test of the trigger analyser against the COMMITTED issue-#14 traces"
	@echo "  check-host        every host suite needing no hardware ([WBF=..] adds wbf-check + waveform-gated tests)"
	@echo "  wbf-check         waveform parser checks (WBF=..; never committed)"
	@echo "  clut-check        C CLUT compiler vs hrdl's wbf_to_custom.py, byte-identical ([WBF=..] [CLUT_REF=..])"
	@echo "  ebc-clut-check    the direct-mode CLUT installer one-shot, driven through every branch"
	@echo "  ebc-ioctl-roster-check  every on-device EBC ioctl against the driver(s) it runs on (both UAPI headers from the patches)"
	@echo "  update-path-check the update path: generation ledger, extlinux rendering, trial/promote pins"
	@echo "  deploy            DEVICE=<ssh host>: build, guix copy, add generation, kexec trial, health, promote"
	@echo "  qemu-update-check ROOTFS=<ext4> [SYSTEM_B=..]: the update flow end to end in QEMU (rung 4u)"
	@echo "  ebc-logic-check   extracted EBC driver logic checks ([WBF=..])"
	@echo "  ebc-barrier-check supervised EBC sleep-frame command host tests"
	@echo "  rastersim-check   raster/waveform simulation checks ([WBF=..])"
	@echo "  koreader-input-check  KOReader input, touch, and virtual-node lifecycle tests"
	@echo "  orientation-check SC7A20 classifier and uinput bridge tests"
	@echo "  platform-controls-check acknowledged suspend broker and production service integration"
	@echo "  optics-check      deterministic recorder/bundle/analysis tests (incl. the evidence-audit passes)"
	@echo "  optics-audit-dataset  re-check the 2026-07-12 evidence audit against doc/datasets (stdlib only)"
	@echo "  power-check       fake-root tests for the read-only Guile power recorder; auto-suspend post-wake policy"
	@echo "  manuals-check     man/info -> EPUB converter for the reader's manuals shelf"
	@echo "  rockchip-pm-check dormant BSP SIP/PM model, DTB, and zero-call checks"
	@echo "  activation-positive-check  fake capabilities/coordinator + active PM scenario; production hard-off"
	@echo "  suspend-check     offline fail-closed e-reader suspend qualification gates"
	@echo "  gexp-modules-check  no use-modules in a shepherd start/stop without a (modules ..) field"
	@echo "  timezone-check    the build-time timezone knob resolves, and refuses an unusable name"
	@echo "  timesync-check    SNTP client protocol/policy tests plus a loopback round trip"
	@echo "  settings-check    every knob declared twice still agrees; today's drift is pinned (issue #12)"
	@echo "  ebc-modprobe-options-check  each rockchip_ebc options set names only parameters its own driver registers"
	@echo "  ebc-card-resolution-check  no on-device EBC path hardcodes a /dev/dri/cardN index (2026-08-25 wash-to-GPU bug)"
	@echo "  reader-stop-check  reader-session's stop is SIGINT-first (TERM truncates crengine caches)"
	@echo
	@echo "Flags:"
	@echo "  TIME_MACHINE=1    build through channels.scm (required for releases; pin bumped"
	@echo "                    2026-08-26 to the 7.1-resolving generation, see doc/building.md)"
	@echo "  HOST_TOOLCHAIN=1  use the toolchain already on PATH instead of 'guix shell' (what CI does)"
	@echo "  SKIP_CHECKS=..    omit named check-host members (must be in CHECK_HOST_TARGETS)"
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
	@# --no-grafts is what makes this the cheap gate doc/testing.md advertises.
	@# `guix build -d' WITH grafting has to realize the ungrafted output in
	@# order to compute references, i.e. it performs a REAL cross kernel build
	@# -- the exact opposite of a derivation-only check.  Measured on this
	@# tree: 0.64s with --no-grafts, versus a full (currently failing) compile
	@# without it.  Grafts are irrelevant when all you want is the drv hash.
	$(GUIX) build -d --no-grafts $(GUIX_FLAGS) \
	  -e '(@ (pinenote packages kernel) linux-pinenote)'

# Rung 2, and the only gate that reads services/*.scm and systems/*.scm AS
# SCHEME.  Nothing in rung 1 evaluates them, so a broken gexp -- a typo'd
# field, an unbound variable inside a service definition -- is invisible until
# something lowers the system.  Cheap for the same --no-grafts reason.
reader-system-drv:
	$(GUIX) system build -d --no-grafts $(GUIX_FLAGS) \
	  pinenote/systems/pinenote-reader.scm

# Is the kernel we would build still in the series this repo pins?
#
# %linux-pinenote-base is bound to nongnu:linux-7.1 -- a SERIES pin, no longer
# the floating nongnu:linux alias -- so ambient point releases (7.1.5 -> 7.1.8)
# pass, and the check catches the series moving under us or the pin changing
# without this expectation following.  The resolved derivation NAME carries
# the version, so asking is ~0.6s and needs no build.
#
# Since the 2026-08-26 pin bump BOTH forms pass, and time-machine
# resolves the identical derivation as ambient guix (that equality was
# the bump's acceptance gate; see the GUIX comment at the top).  If the
# TIME_MACHINE=1 form ever fails with an "Unbound variable" while the
# ambient form passes, the kernel series moved without the pin -- bump
# channels.scm in the same change.
#
# Deliberately NOT in CHECK_HOST_TARGETS: the CI runner installs no Guix.
KERNEL_EXPECT ?= linux-pinenote-7.1.
kernel-version-check:
	@set -e; \
	drv=$$($(GUIX) build -d --no-grafts $(GUIX_FLAGS) \
	         -e '(@ (pinenote packages kernel) linux-pinenote)' | tail -n 1); \
	echo "resolved: $$drv"; \
	case "$$drv" in \
	  *$(KERNEL_EXPECT)*) echo "PASS: kernel base is $(KERNEL_EXPECT)x as expected"; ;; \
	  *) echo "FAIL: expected $(KERNEL_EXPECT)x, resolved $$drv"; \
	     echo "      Either your channels no longer provide the pinned series (re-run"; \
	     echo "      'guix pull', or the pin in pinenote/packages/kernel.scm moved without"; \
	     echo "      KERNEL_EXPECT following), or this ran with TIME_MACHINE=1 against a"; \
	     echo "      channels.scm that predates the series (issue #13, doc/building.md)."; \
	     exit 1 ;; \
	esac

kernel:
	$(GUIX) build -L . --target=$(TARGET) \
	  -e '(@ (pinenote packages kernel) linux-pinenote)'

packages:
	$(GUIX) build $(GUIX_FLAGS) pinenote-ebc-test pinenote-ebc-barrier-test pinenote-diagnostics \
	  pinenote-firmware-support pinenote-broadcom-wifi-firmware \
	  pinenote-broadcom-bt-firmware pinenote-wbf-clut

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
	$(call guix-shell,e2fsprogs gptfdisk qemu) sh -c "\
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
	$(call guix-shell,e2fsprogs gptfdisk qemu) sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-assertions.sh \"$$bundle\" \"$$disk\""

# The update path end to end in QEMU virt (rung 4u, doc/update-path.md):
# boot generation A from ROOTFS with a data partition carrying a harness ssh
# key, a fixed host key and this workstation's guix signing key; guix copy
# generation B (SYSTEM_B, a system store path -- default: the hostname
# variant in pinenote/scripts/qemu/update-flow-generation-b.scm, built here)
# into the guest; add, kexec trial, health, promote; then roll back to A.
# Needs /etc/guix/signing-key.pub on this host (sudo guix archive --generate-key).
# Usage: make qemu-update-check ROOTFS=<rootfs.ext4> [SYSTEM_B=<store path>] [WAVEFORM=<file>]
qemu-update-check:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-update-check ROOTFS=<rootfs.ext4> [SYSTEM_B=<system store path>] [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-updchk-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-updchk-disk-$$stamp.img; \
	data=$(ARTIFACTS)/pinenote-updchk-data-$$stamp.img; \
	home=$(ARTIFACTS)/pinenote-updchk-home-$$stamp; \
	sysb="$(SYSTEM_B)"; \
	if [ -z "$$sysb" ]; then sysb=$$($(GUIX) system build --no-grafts $(GUIX_FLAGS) pinenote/scripts/qemu/update-flow-generation-b.scm | tail -n 1); fi; \
	$(call guix-shell,e2fsprogs gptfdisk qemu openssh) sh -c "\
	  set -e; \
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  sysa=\$$(sed -n 's/.*gnu.system=\([^ ]*\).*/\1/p' \"$$bundle/extlinux/extlinux.conf\" | head -n 1) && \
	  mkdir -p \"$$home/.ssh\" && chmod 700 \"$$home/.ssh\" && \
	  ssh-keygen -q -t ed25519 -N '' -f \"$$home/.ssh/id_ed25519\" && \
	  ssh-keygen -q -t ed25519 -N '' -f \"$$home/.ssh/vm_host_ed25519\" && \
	  printf 'Host vm\n  HostName 127.0.0.1\n  Port %s\n  User root\n  IdentityFile %s\n  UserKnownHostsFile %s\n  StrictHostKeyChecking yes\n  ConnectTimeout 5\n  ServerAliveInterval 5\n  ServerAliveCountMax 2\n  BatchMode yes\n' \"$${VIRT_UPDATE_PORT:-2277}\" \"$$home/.ssh/id_ed25519\" \"$$home/.ssh/known_hosts\" > \"$$home/.ssh/config\" && \
	  printf '[127.0.0.1]:%s %s\n' \"$${VIRT_UPDATE_PORT:-2277}\" \"\$$(cut -d' ' -f1,2 \"$$home/.ssh/vm_host_ed25519.pub\")\" > \"$$home/.ssh/known_hosts\" && \
	  UPDATE_FLOW_SSH_PUBKEY=\"$$home/.ssh/id_ed25519.pub\" UPDATE_FLOW_HOST_KEY=\"$$home/.ssh/vm_host_ed25519\" \
	    pinenote/scripts/qemu/make-data-fixture.sh update-flow \"$$data\" && \
	  VIRT_ROOT_SLACK_MIB=2048 pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(or $(WAVEFORM),'') \"$$data\" && \
	  VIRT_ROOT_SLACK_MIB=2048 pinenote/scripts/qemu/run-virt-update-flow.sh \"$$bundle\" \"$$disk\" \"$$home\" \"\$$sysa\" \"$$sysb\""

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
	$(call guix-shell,e2fsprogs gptfdisk qemu) sh -c "\
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
	$(call guix-shell,e2fsprogs gptfdisk qemu) sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  pinenote/scripts/qemu/run-virt-visual.sh \"$$bundle\" \"$$disk\""

# Scripted page-turn / menu campaign on the rung-4v boot (offline
# reproduction attempt for issue #14, "occasional two-step page turns").
# Drives many page turns with interleaved menu open/dismiss cycles --
# the antecedent 4 of the 5 field episodes share -- harvests the guest's
# own [pn-refresh] traces over the console, and scores them with the
# same signature logic the issue analysis used (threshold sweep, episode
# runs, menu-antecedent rate vs base).  Usage:
#   make qemu-pageturn-campaign ROOTFS=<rootfs.ext4> [WAVEFORM=<file>] \
#        [CAMPAIGN_TURNS=160] [CAMPAIGN_MENU_EVERY=8] [CAMPAIGN_PROBE=1]
qemu-pageturn-campaign:
	@test -n "$(ROOTFS)" || { echo "usage: make qemu-pageturn-campaign ROOTFS=<rootfs.ext4> [WAVEFORM=<file>]"; exit 2; }
	@set -e; \
	stamp=$$(date +%Y%m%d-%H%M%S); \
	mkdir -p $(ARTIFACTS); \
	bundle=$(ARTIFACTS)/pinenote-pageturn-bundle-$$stamp; \
	disk=$(ARTIFACTS)/pinenote-pageturn-disk-$$stamp.img; \
	$(call guix-shell,e2fsprogs gptfdisk qemu) sh -c "\
	  pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh '$(ROOTFS)' \"$$bundle\" && \
	  pinenote/scripts/qemu/make-virt-disk.sh '$(ROOTFS)' \"$$disk\" $(WAVEFORM) && \
	  CAMPAIGN_TURNS='$(CAMPAIGN_TURNS)' CAMPAIGN_MENU_EVERY='$(CAMPAIGN_MENU_EVERY)' \
	  CAMPAIGN_PROBE='$(CAMPAIGN_PROBE)' CAMPAIGN_PLAN='$(CAMPAIGN_PLAN)' \
	  CAMPAIGN_STEADY_WAIT='$(CAMPAIGN_STEADY_WAIT)' \
	  CAMPAIGN_MODE_WAIT='$(CAMPAIGN_MODE_WAIT)' \
	  CAMPAIGN_BURST_WAIT='$(CAMPAIGN_BURST_WAIT)' \
	  pinenote/scripts/qemu/run-virt-pageturn-campaign.sh \"$$bundle\" \"$$disk\""

# Self-test of the episode analyser (rung 1: no device, no VM, no guix).
# It replays the issue-#14 field fixture and requires the published
# numbers back out, so an offline campaign result and the field result
# are known to be the same measurement.
refresh-episodes-check:
	python3 pinenote/tools/refresh-episodes/test-refresh-episodes.py

# Self-test of the TRIGGER analyser, and the only suite in the roster
# whose input is committed field evidence rather than a fixture: it runs
# over doc/artifacts/pinenote-refresh-traces-20260815/ and requires the
# published issue-#14 numbers back.  In CHECK_HOST_TARGETS deliberately
# -- issue #4 is the record of an audit whose numbers stopped being
# re-derivable because its scripts were reachable by nobody.
refresh-trigger-check:
	python3 pinenote/tools/refresh-episodes/test-refresh-triggers.py

# Aggregate host gate (doc/testing.md, validation-ladder rung 1): every
# suite that needs no hardware and no per-device waveform, in one
# command.  wbf-check hard-requires WBF=, so it joins only when WBF is
# set; ebc-logic-check and rastersim-check accept the same optional WBF
# and skip their waveform-gated tests without it.
# The rung-1 roster.  Single source of truth: CI shards it with SKIP_CHECKS=
# rather than restating it, so a suite added here is picked up automatically
# instead of quietly missing from CI.
CHECK_HOST_TARGETS = clut-check ebc-logic-check ebc-barrier-check rastersim-check \
        koreader-input-check orientation-check platform-controls-check optics-check power-check \
        rockchip-pm-check activation-positive-check suspend-check \
        library-check koreader-profile-check manuals-check ultra-coupling-check \
        battery-dtb-check time-machine-check gexp-modules-check \
        timezone-check refresh-trigger-check timesync-check settings-check \
        ebc-modprobe-options-check ebc-clut-check ebc-card-resolution-check ebc-ioctl-roster-check \
        update-path-check reader-stop-check pen-check ebc-lab-check

# Parse time, not recipe time: a recipe-level guard would run only AFTER every
# prerequisite had already completed, so it could not prevent the mistake it
# exists to catch.
ifneq ($(filter-out $(CHECK_HOST_TARGETS),$(SKIP_CHECKS)),)
$(error SKIP_CHECKS names a target not in CHECK_HOST_TARGETS: $(filter-out $(CHECK_HOST_TARGETS),$(SKIP_CHECKS)))
endif

check-host: wbf-notice $(if $(WBF),wbf-check) \
        $(filter-out $(SKIP_CHECKS),$(CHECK_HOST_TARGETS))

# Announce the waveform coverage gap on EVERY run, so a local green is as
# honest as a CI green.  doc/testing.md: "absence of an error is not a passing
# test."  The waveform is per-device calibration and is never committed, so CI
# can NEVER cover the parser -- that has to be said out loud rather than
# inferred from a badge.
wbf-notice:
	@if [ -n "$(WBF)" ]; then echo "wbf-check: enabled (WBF=$(WBF))"; else \
	  echo 'SKIP: wbf-check and every waveform-gated test -- WBF= is unset.'; \
	  echo '      The waveform is per-device calibration and is NEVER committed,'; \
	  echo '      so CI cannot cover it. Run locally: make check-host WBF=/path/to/ebc.wbf'; fi
	@test -z "$(SKIP_CHECKS)" || printf 'SKIP: %s -- excluded by SKIP_CHECKS\n' '$(SKIP_CHECKS)'

# The generated-battery-DTB inspector's own self-test.  It has been in the tree
# and executed by no make target, which is the coverage-rot failure mode.
battery-dtb-check:
	$(call guix-shell,dtc) sh pinenote/scripts/preflight/test-inspect-pinenote-battery-dtb.sh

# Every recipe that invokes guix must go through $(GUIX), so TIME_MACHINE=1 can
# pin it to channels.scm.  Pure text analysis of this file; needs no guix.
time-machine-check:
	sh pinenote/scripts/preflight/validate-time-machine-wiring.sh

# A shepherd service file is COMPILED, so a `use-modules' inside a start/stop
# lambda imports nothing and every call it was meant to satisfy throws Unbound
# variable -- inside a catch #t, silently.  Shipped twice (dmc.scm, live
# 2026-08-07; frontlight.scm).  Pure text analysis of the service sources;
# needs no guix.
gexp-modules-check:
	sh pinenote/scripts/preflight/validate-gexp-modules.sh

# Guix never opens the timezone string -- /etc/localtime is `file-append
# tzdata "/share/zoneinfo/" timezone', pure concatenation -- so a typo'd
# WILKBOOK_TIMEZONE builds, images and deploys cleanly and then dangles,
# and glibc falls back to UTC without a word.  This gate pins the refusal
# that pinenote/timezone.scm does at evaluation time, plus the local.mk
# wiring the docs promise.  Guile is a toolchain convenience here: the
# script text-gates either way and says SKIP for what it could not run.
timezone-check:
	$(call guix-shell,guile) sh pinenote/scripts/preflight/validate-timezone-selection.sh

# Host-side waveform parser tests (offline ladder rung 1); needs the
# per-device .wbf (never committed): make wbf-check WBF=/path/to/ebc.wbf
wbf-check:
	$(call guix-shell,gcc-toolchain python) $(MAKE) -C pinenote/tools/wbf check WBF=$(WBF)

# The C CLUT compiler (doc/direct-mode-adoption.md P1) differentialled
# against hrdl's wbf_to_custom.py.  Unlike wbf-check this is a check-host
# member, because without WBF= it still compiles both binaries out of the
# forward-port patch -- coverage of the patch that CI can actually run --
# and then says out loud that the differential did not run.  The gate is
# byte-identical output, so CLUT_REF must point at a pinenote-dist clone
# (doc/reference-register.md) and python needs numpy:
#   make clut-check WBF=/path/to/ebc.wbf CLUT_REF=~/src/reference/pinenote-dist/bin
clut-check:
	$(call guix-shell,gcc-toolchain python python-numpy) $(MAKE) -C pinenote/tools/wbf clut-check \
	  WBF=$(WBF) CLUT_REF=$(CLUT_REF) CLUT_REF_BIN=$(CLUT_REF_BIN) CLUT_PYTHON=$(CLUT_PYTHON)

# The other half of D1: the compiler exists, and this is the one-shot that
# would put its output where hrdl's driver looks (doc/direct-mode-adoption.md
# D1/D7).  EXECUTES pinenote/services/ebc-clut-install.sh -- the exact file
# the service hands to shepherd -- through every branch against a fake
# firmware tree and a stub compiler, plus a mutation control that replaces
# the checksum with upstream's compile-once-if-absent ExecCondition and
# requires the freshness branches to go red for it.  stdlib python3 only; no
# waveform, no store, no device.  `guix repl' compiles the service module
# when guix is on PATH and says SKIP when it is not.
ebc-clut-check:
	python3 pinenote/scripts/preflight/test-ebc-clut-install.py

# EBC driver logic unit tests against the verbatim rockchip_ebc.c from
# the forward-port patch (offline ladder rung 2). WBF optional; without
# it the waveform-dependent tests are skipped:
#   make ebc-logic-check [WBF=/path/to/ebc.wbf]
ebc-logic-check:
	$(call guix-shell,gcc-toolchain python) $(MAKE) -C pinenote/tools/ebc-logic check WBF=$(WBF)
	@# The harness does not define CONFIG_DRM_FBDEV_EMULATION, so the suite
	@# above is blind to the deferred-io drain and to its ordering against
	@# the wash. That ordering is worth one whole visible refresh pass.
	sh pinenote/scripts/preflight/validate-ebc-global-arm-order-hunk.sh

# Host-only fake-operation coverage for the separately invoked sleep-frame
# diagnostic.  It extracts the barrier UAPI from the permanent kernel patch;
# this target never invokes --run or opens device nodes.
ebc-barrier-check:
	$(call guix-shell,gcc-toolchain python) $(MAKE) -C pinenote/tools/ebc-barrier check

# Gray8->Y4 raster library + waveform simulator tests (offline ladder
# rung 3). WBF optional; without it the waveform-dependent tests are
# skipped: make rastersim-check [WBF=/path/to/ebc.wbf]
rastersim-check:
	$(call guix-shell,gcc-toolchain python) $(MAKE) -C pinenote/tools/rastersim check WBF=$(WBF)

# KOReader input-routing tests against the verbatim bundle sources
# (native koreader-bin, resolved via `guix build` -- cached; override
# with KOREADER_BUNDLE=/gnu/store/...): proves the pen-hover tap-capture
# bug and validates the mixedrouter fix.
koreader-input-check:
	$(MAKE) -C pinenote/tools/koreader-input check KOREADER_BUNDLE=$(KOREADER_BUNDLE)

orientation-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/orientation check

platform-controls-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/platform-controls check

# E-ink optical-defect detectors (optics harness analysis core). Deterministic
# validation of the flash/ghost/settle/double-flash classifiers against
# synthetic clips with known injected defects; no camera, no device. Also
# re-runs the committed-data half of the 2026-07-12 evidence audit against
# doc/datasets/2026-07-optics (audit.py dataset).
#   make optics-check
optics-check:
	$(call guix-shell,python python-numpy python-scipy python-pillow ffmpeg) $(MAKE) -C pinenote/tools/optics check

# The evidence audit's committed-data re-check on its own: stdlib python only,
# no numpy/ffmpeg/guix shell, ~instant. The frame passes it cannot run need a
# bundle's gitignored capture.mkv -- see pinenote/tools/optics/audit.py.
#   make optics-audit-dataset
optics-audit-dataset:
	$(MAKE) -C pinenote/tools/optics audit-dataset

# Read-only power snapshot/delta recorder tests.  Guile is present in the
# final4 system profile and the tool uses only base Guile modules.  luajit
# joins for the auto-suspend post-wake policy gate, which executes the
# daemon's own extracted source.
power-check:
	$(call guix-shell,guile python luajit) $(MAKE) -C pinenote/tools/power check

# The D8 pen tools: the scribbler's geometry/parsing/publish path and
# ebc-mode's MODE/RECT_HINTS ABI, extracted verbatim and pinned against
# the hardware-proven GLOBAL_REFRESH ioctl constant.
pen-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/pen check

# The EBC live-iteration lab: struct packers for RECT_HINTS and the
# PHASE_SEQUENCE userspace-drive program, discovery, and page-flip's
# synthetic-turn renderer -- the no-image-write experiment workbench.
ebc-lab-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/ebc-lab check

# The SNTP client behind pinenote-timesync (issue #27).  Its protocol and
# policy functions are extracted VERBATIM from the shipped daemon, and the
# suite then runs the real daemon against a fake NTP server it hosts on
# 127.0.0.1 -- which is what proves the ffi.cdef struct layouts (including
# glibc's addrinfo field order) that no unit test can reach.  Nothing here
# needs root or a network: the daemon runs --dry-run and sets no clock.
timesync-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/timesync check

# The configuration coupling gate (issue #12 step 1).  The same knob is
# declared in a Guix record, a Lua `opt' table, a .conf key, an argv flag,
# a modprobe options string and a host model that claims to mirror the
# device -- with nothing connecting the copies.  This asserts they still
# agree.  Pure text analysis over the sources; python3 stdlib only, no
# guix, no store, no device.
#
# EXPECTED OUTPUT -- do not "fix" the DEBT lines: the tree HAS drifted, and
# #12 step 1 asks for that drift to be pinned rather than repaired here.
# Each DEBT row is inventory that a later #12 step removes; a divergence
# NOT in the register fails the build, and so does a register row whose
# divergence has been paid off.  The second command is the positive
# control: it breaks one coupling at a time in a scratch copy of the tree
# and requires the gate to reject it.
settings-check:
	python3 pinenote/tools/settings/check-settings.py
	python3 pinenote/tools/settings/test-check-settings.py

# We now carry TWO rockchip_ebc drivers with almost disjoint module
# parameters, and the kernel does not protect you from mixing them up:
# unknown_module_param_cb() warns and IGNORES, so an options line aimed at
# the wrong driver loads fine with its intents silently discarded.  This
# gate derives each driver's real parameter set from the module_param()
# registrations in its own patch -- resolving #ifdef guards, and refusing
# rather than guessing when it meets a guard it does not know -- and checks
# each options string against the driver it is for.  It also pins the
# shipping options text, because the direct-mode set is deliberately empty
# and a check over an empty set proves nothing on its own; the positive
# control is that the SHIPPING string must be rejected against hrdl's
# driver.  python3 stdlib, no device.  One step is not text analysis: it
# runs `guix repl' to LOAD (pinenote services ebc-direct): when the check
# was written nothing imported that module, and even now only the
# reader-direct study flavor does, so an ordinary reader build would
# never compile it.  That step SKIPs, loudly, where guix is absent --
# CI included.
ebc-modprobe-options-check:
	python3 pinenote/scripts/preflight/validate-ebc-modprobe-options.py

# The EBC's DRM card index is not stable across images (panfrost takes
# card0 on the direct-mode image), so every on-device EBC-ioctl path
# must resolve the card by DRIVER=rockchip-ebc rather than hardcode an
# index -- the 2026-08-25 wash-to-GPU ghosting root cause.
ebc-card-resolution-check:
	sh pinenote/scripts/preflight/validate-ebc-card-resolution.sh

# The two drivers do not share an ioctl table (shipping adds REFRESH_BARRIER
# at DRM command 0x03; hrdl's direct driver puts RECT_HINTS there), and DRM
# dispatches on the command number -- so a tool built for one driver lands
# in a DIFFERENT handler on the other (issue #42: every suspend on the direct
# image aborted with EFAULT).  Reconstructs both UAPI headers from the
# patches, computes every ioctl number the way _IOC() does, proves the
# calculator against glass-proven constants, and checks each on-device
# ioctl user against the driver(s) it is declared for; positive-controlled.
ebc-ioctl-roster-check:
	python3 pinenote/scripts/preflight/validate-ebc-ioctl-roster.py

# The update path's pure decisions (generation ledger, extlinux rendering,
# promote/prune/health) and the structural pins on its imperative halves
# (the trial boot's teardown order, the deployer's promote-only-after-health).
update-path-check:
	$(call guix-shell,luajit) $(MAKE) -C pinenote/tools/update-path check

# Deploy a flavor to a running reader over ssh: build, guix copy, add a
# generation, kexec trial boot, health check, promote, prune
# (doc/update-path.md).  DEVICE is an ssh destination for root.  Never
# touches os1, p7 or the partition table; a failed health check leaves the
# previous generation as DEFAULT.
deploy:
	@test -n "$(DEVICE)" || { echo "usage: make deploy DEVICE=<ssh host> [FLAVOR=reader-direct] [KEEP=3]"; exit 2; }
	sh pinenote/tools/deploy/deploy.sh "$(DEVICE)" "$(or $(FLAVOR),reader-direct)" "$(or $(KEEP),3)"

# reader-session's stop must be INT-first: TERM truncates the crengine
# cache to zero bytes and re-arms a 30 s re-parse of the manuals book
# (measured on glass 2026-08-26 -- doc/manuals.md).
reader-stop-check:
	sh pinenote/scripts/preflight/validate-reader-stop.sh

rockchip-pm-check:
	$(call guix-shell,dtc gcc-toolchain git python) $(MAKE) -C pinenote/tools/rockchip-pm check

# Deliberately composite: the positive fake scenarios may pass only alongside
# the production suspend gate. Nothing here can write power state.
activation-positive-check:
	$(call guix-shell,dtc gcc-toolchain git python luajit) sh -c 'set -e; \
	  $(MAKE) -C pinenote/tools/power power-capabilities-check; \
	  $(MAKE) -C pinenote/tools/power ebc-sleep-frame-check; \
	  luajit pinenote/tools/power/test-power-coordinator.lua; \
	  $(MAKE) -C pinenote/tools/rockchip-pm activation-positive-check; \
	  sh pinenote/scripts/preflight/test-inspect-pinenote-suspend-gates.sh'

# Fail-closed suspend qualification checks. These prove only static config,
# approved DT wake capability, and restricted KOReader device evaluation.
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
#
# The git description is captured BEFORE the redirect: `>` truncates
# SHA256SUMS first, which dirties the tree, so an inline
# $(git describe --dirty) inside the block always reported -dirty no matter
# how clean the checkout was.
release-manifest:
	@test -n "$(ROOTFS)" || { echo "usage: make release-manifest ROOTFS=<rootfs.ext4>"; exit 2; }
	@test -f channels.scm || { echo "no channels.scm -- run: make channels-pin"; exit 2; }
	@set -e; \
	  desc=$$(git describe --always --dirty --tags); \
	  { printf '# wilkbook release manifest\n'; \
	    printf '# git:      %s\n' "$$desc"; \
	    printf '# built:    %s\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	    printf '# channels: channels.scm at this commit (guix time-machine -C)\n'; \
	    printf '# verify:   sha256sum -c SHA256SUMS\n'; \
	    sha256sum "$(ROOTFS)" | sed 's|  .*/|  |'; } > SHA256SUMS
	@cat SHA256SUMS

# The reader's library directory and first-boot landing.  Structural, and
# negative-tested against six ways it has to be able to fail.
library-check:
	sh pinenote/scripts/preflight/validate-koreader-library.sh

# One writer for KOReader's settings profile, and it is the record.  The
# tree carried two seeds of that file until 2026-08-24; only the
# activation one could ever run, so the six e-ink refresh keys added to
# the other on 2026-08-05 shipped in nothing.  Checks 1-5 are text
# analysis and need nothing installed; check 6 generates the seed from the
# record and reads it, which needs `guix' because the record is a Guix
# service configuration -- it SKIPS loudly without one (CI has guile but
# no guix), so a green here is weaker in CI than it is locally.
koreader-profile-check:
	sh pinenote/scripts/preflight/validate-koreader-profile.sh

# The man/info -> EPUB converter the manuals shelf is built from (issue #17).
# Python 3 standard library over generated fixtures plus one committed
# mandoc fragment; no Guix module is evaluated and the store is never read.
# mandoc is a toolchain convenience: without it the roff stage reports SKIP
# and the post-processor still runs against fixtures/wilkdemo.1.mandoc-html.
manuals-check:
	$(call guix-shell,mandoc python) sh pinenote/tools/manuals/run-tests.sh

# The ultra payload is a matched pair (standing override + rails) that must
# ship whole in one patch on the primary kernel; either half alone is a
# proven-broken configuration.
ultra-coupling-check:
	sh pinenote/scripts/preflight/validate-ultra-coupling.sh

suspend-check:
	$(call guix-shell,dtc python luajit) sh pinenote/scripts/preflight/test-inspect-pinenote-suspend-gates.sh
	sh pinenote/scripts/preflight/validate-tps65185-pm-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-fbdev-resume-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-resume-baseline-hunk.sh
	sh pinenote/scripts/preflight/validate-ebc-timeout-asymmetry.sh
	sh pinenote/scripts/preflight/validate-dmc-default-off.sh
	$(call guix-shell,python) sh pinenote/scripts/preflight/test-validate-ebc-fbdev-resume-hunk.sh
