# Building PineNote images

All commands run from the repository root on the x86_64 build host. Everything
here writes only to the Guix store and `/tmp/opencode`; deploying artifacts to
the device is covered separately in `doc/hardware-deploy.md`.

The `Makefile` wraps the common invocations; the raw commands are recorded
below for when a wrapper is not enough.

## System flavors

See `doc/pinenote-flavors.md` for the flavor matrix. Build a system closure:

```sh
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-usb-console.scm
```

Build the deployable disk image (an MBR image with a single ext4 partition;
the rootfs gets extracted from it before deployment, see below):

```sh
guix system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-usb-console.scm
```

Substitute any other flavor entrypoint from `pinenote/systems/`. The
`usb-console` flavor carries the hardware-validated primary 7.0 kernel; use
`usb-console-linux-6-6` only for regression isolation (see `doc/status.md`).

## Packages

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
guix build -L . pinenote-ebc-barrier-test --target=aarch64-linux-gnu
guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu
guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu
guix build -L . pinenote-broadcom-wifi-firmware --target=aarch64-linux-gnu
guix build -L . pinenote-broadcom-bt-firmware --target=aarch64-linux-gnu
```

Compute the kernel derivation before committing to a full kernel build:

```sh
guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
  --target=aarch64-linux-gnu
```

Kernel packaging and the forward-port workflow are described in
`doc/kernel-forward-port.md`.

## Rootfs extraction and boot bundles

The raw image is a build intermediate, never written to the device whole.
Extract the single ext4 partition into a direct rootfs artifact labelled
`PNGuixRoot`, validate it, and stage a matched boot bundle from it:

```sh
mkdir -p /tmp/opencode/pinenote-rootfs-artifacts
rootfs=/tmp/opencode/pinenote-rootfs-artifacts/pinenote-$(date +%Y%m%d).ext4

pinenote/scripts/preflight/extract-rootfs-from-raw.sh \
  /gnu/store/...-disk-image "$rootfs"
pinenote/scripts/preflight/inspect-rootfs-image.sh "$rootfs"

bundle=/tmp/opencode/pinenote-boot-bundle-$(date +%Y%m%d)
pinenote/scripts/preflight/stage-boot-bundle-from-rootfs.sh "$rootfs" "$bundle"
pinenote/scripts/preflight/inspect-boot-bundle.sh "$bundle"
```

The extraction helper normalizes the embedded `/boot/extlinux/extlinux.conf`
to `root=PNGuixRoot` (Guix initrd label shorthand, not the Linux `LABEL=`
form). The validated rootfs must have no partition table and the `PNGuixRoot`
label. The boot-bundle inspector checks for an uncompressed `Image` (older
PineNote U-Boot may not load `Image.gz`), `rk3566-pinenote-v1.2.dtb`, the
initrd, and a label-based root argument.

## QEMU smoke test

A generic ARM64 QEMU `virt` check that avoids all PineNote kernel, DTB,
waveform, and EBC assumptions. It proves Guix userspace construction only,
not PineNote hardware behavior:

```sh
guix system vm -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
guix shell qemu -- /gnu/store/...-run-vm.sh -M virt -cpu max -nographic -no-reboot
```

The VM launcher has reached the `pinenote-qemu-smoke login:` prompt; treat
that as the validated QEMU gate. The `qcow2-gpt` image path fails while
copying Syslinux `.c32` modules and is not used.

## QEMU with the real PineNote artifacts

The PineNote kernels build with QEMU `virt` support (virtio disk/net and a
PL011 console are built in; see `%pinenote-qemu-virt-config-lines` in
`pinenote/packages/kernel.scm`), so the exact kernel, initrd, and rootfs
that would be written to the device can be booted off-device:

```sh
make qemu-virt ROOTFS=/tmp/opencode/pinenote-rootfs-artifacts/<artifact>.ext4 \
     [WAVEFORM=/path/to/local/waveform.bin]
```

This stages a boot bundle from the rootfs, builds a synthetic GPT disk that
mimics the PineNote layout (a 2 MiB partition GPT-named `waveform`, the
rootfs in a partition named `os2`), and boots QEMU with the bundle's exact
Guix boot arguments, only steering the console from `ttyS2` to `ttyAMA0`.

What it tests for real: the hardware kernel image boots with `PREEMPT_RT`,
the initrd finds the waveform partition by PARTNAME and installs `ebc.wbf`,
loads the EBC display modules, sees `PNGuixRoot` before the root switch,
root mounts by that label, and Shepherd brings up its base services. That
is the config/initrd/root-mount regression class — exactly how the
`VIRTIO_MENU` olddefconfig drop (which made virtio-blk vanish so root never
appeared) is caught.

The full service stack comes up on virt: udev, the `pinenote-waveform`
and `pinenote-ebc-params` one-shots, and reader-session (KOReader's
luajit — which then spins a vCPU for want of a framebuffer; expected).
Note that the *console* stops showing shepherd messages ~5 s into boot —
that's shepherd diverting its output from /dev/kmsg to /var/log/messages
once its system-log service is up, not a hang (this masqueraded as a
"udev deadlock" on 2026-07-04; see `doc/status.md` 2026-07-05). Log in
as root on the console and read /var/log/messages for the rest. What
virt can *not* test is anything RK3566-specific — EBC rendering, the
dwc3 gadget (the ACM gadget one-shot fails here, correctly), Wi-Fi/BT
firmware. `WAVEFORM` may point at a local waveform backup; it is never
bundled or committed.

`make qemu-virt-check` (offline ladder rung 4) wraps this boot into a
non-interactive gate. It captures the console via a socket chardev, waits
for the login prompt, asserts the early milestones from the console log,
then logs in as root over the socket and asserts the post-udev service
stack from the guest's own /var/log/messages (udev completion, both
one-shots, reader-session start), and finally powers the guest off and
requires a clean `reboot: Power down`. Regression signatures
(waveform-not-found, PNGuixRoot-not-visible, kernel panic, RT
sleeping-in-atomic) must be absent. It exits non-zero on any failed
assertion; a green run takes a few minutes (TCG, and udev's settle takes
~a minute):

```sh
make qemu-virt-check ROOTFS=/tmp/opencode/pinenote-rootfs-artifacts/<artifact>.ext4 \
     [WAVEFORM=/path/to/local/waveform.bin]
```

Two software stand-ins are built into the image as modules for a future
rung that can exercise the gadget and render plumbing off-device:

```sh
modprobe dummy_hcd   # fake UDC: exercise the configfs/ACM gadget stack
modprobe vkms        # virtual DRM device: exercise render plumbing
```

`dummy_hcd` is a fake UDC for the configfs/ACM plumbing (libcomposite,
u_serial, usb_f_acm, ttyGS0); `vkms` gives DRM userspace a real connector.
Both are reachable today: the virt boot completes and Guix's console getty
answers on `ttyAMA0` (log in as root there, or over the harness's console
socket), so a future rung can modprobe and exercise them interactively.
Neither module models EBC semantics; rendering policy (Y4 quantization,
waveform selection) lives in the host-side tools under `pinenote/tools/`,
and a QEMU device model for the EBC register block is a possible future rung
(see `ROADMAP.md`). (The dwc3 `ep0out` regression itself was never
reproducible here — dummy_hcd bypasses dwc3 — and was fixed on hardware
2026-07-04 via `snps,dis_u3_susphy_quirk`.)

## Validation ladder

Run before any hardware deployment, stopping at the first failure. The
reasoning behind this ordering — and the host tools in rung 0 — is in
`doc/testing.md`.

0. Host tool suites (offline, no VM), all required for a reader candidate:
   `make wbf-check ebc-logic-check ebc-barrier-check rastersim-check koreader-input-check
   orientation-check optics-check power-check rockchip-pm-check activation-positive-check suspend-check
   WBF=/path/to/ebc.wbf KOREADER_BUNDLE=/path/to/koreader-bundle`.
   These compile the verbatim EBC driver/waveform sources and catch
   driver-logic and waveform regressions. The Rockchip PM gate separately
   compiles the verbatim typed model/executor, builds and parses donor/maximal
    DTB fixtures (including standard OF `compatible`, `name`, and `status`
    metadata), and proves the default production image links the executor but
   omits its separate activation/PM-callback caller. Production parsing is
    MEM-only and rejects virtual poweroff. The composite activation-positive
    gate runs only the closed fake capability boundary, coordinator, and backend, then reruns the
    production hard-off preflight so positive synthetic coverage cannot weaken
    the shipped boundary. Run
   the relevant gates whenever you touch either kernel patch.
1. Static Guix build of the scaffold packages (commands above).
2. QEMU `virt` smoke run for generic ARM64 userspace; `make qemu-virt` for
   an interactive boot of the real kernel/initrd/rootfs on a synthetic disk;
   `make qemu-virt-check` for the non-interactive assertion gate over
   the same boot (kernel+RT, initrd waveform install, EBC module load,
   PNGuixRoot pre-root visibility, root mount — through Shepherd start); then
   `make qemu-virt-visual ROOTFS=... [WAVEFORM=...]` for rung 4v KOReader
   framebuffer paint and scripted-tap verification.
3. Kernel source inspection:
   `guix shell git python -- pinenote/scripts/preflight/inspect-kernel-source.sh
   /path/to/linux /path/to/build/.config`
   (run from the full checkout because this also validates the canonical BSP
   SIP compatibility patch and its reviewed applied files),
   (read-only; checks `pinenote_defconfig`, PineNote DTS/DTSI, `rockchip_ebc`,
   the EBC/PMIC/Wi-Fi/pen defconfig markers, and battery prerequisites without
   executing the inspected source tree's Makefile). Then run
   `inspect-pinenote-battery-dtb.sh` on the generated PineNote v1.2 DTB and
   `inspect-pinenote-suspend-gates.sh RESOLVED_CONFIG DTB SUSPEND_POLICY_LUA
   KOREADER_DEVICE_LUA`. The suspend gate must pass while restricted false/true
   policy injection proves the returned KOReader class follows the exact
   disabled policy module; it is a qualification guard, not evidence that the
    device can resume. The compiled-DTB fixture's explicit `name` coverage is a
    parser gate; Linux synthesizes that standard property in live OF even when
    the source DT does not spell it out.
4. Boot-bundle inspection (commands above).
5. Mock helper tests: `pinenote/scripts/preflight/mock-pinenote-services.sh`
   (inspects hardware-targeted helpers without executing them; fixtures live
   only under `/tmp/opencode`).
6. Hardware deployment per `doc/hardware-deploy.md`, with the backup
   checklist in `doc/device-runbook.md` satisfied first.

## First-boot service logic

The Shepherd services in the bring-up flavors are one-shot hooks:

- `pinenote-waveform` copies a waveform from
  `/dev/disk/by-partlabel/waveform` or `/state/firmware/ebc.wbf` to
  `/lib/firmware/rockchip/ebc.wbf`, failing visibly if neither exists. The
  initrd performs the same extraction pre-root so `rockchip_ebc` can bind
  early. The waveform is never bundled in this repository: it is per-device
  calibration data.
- `pinenote-ebc-modprobe` installs `/etc/modprobe.d/rockchip_ebc.conf` with
  the PNDeb-derived module options.
- `pinenote-ebc-params` applies the `rockchip_ebc` parameter values once
  sysfs exposes them, failing if the parameter directory is absent.
- `pinenote-diagnostics` records read-only boot diagnostics.
- `pinenote-ebc-test` runs a read-only EBC report; its explicit
  `--draw-smoke` mode performs a reversible framebuffer smoke test manually.
- `pinenote-ebc-barrier-test` is installed but never started by Shepherd.  Its
  `pinenote-ebc-sleep-frame-test --help` is inert; supervised root-only
  `--run` requires `herd stop reader-session` and an interactive tty, paints
  then strictly waits for the EBC barrier, and restores the exact framebuffer
  snapshot only after explicit Enter.  It is a test artifact, not a QEMU
  action or production suspend wiring.
- The usb-console flavors additionally start a CDC-ACM gadget (gated on the
  USB role switch) with an auto-login `reader` shell on `ttyGS0`, plus an
  auto-login getty on UART `ttyS2` at 1500000 baud.
