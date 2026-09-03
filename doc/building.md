# Building PineNote images

All commands run from the repository root on the x86_64 build host. Everything
here writes only to the Guix store and `/tmp/wilkbook`; deploying artifacts to
the device is covered separately in `doc/hardware-deploy.md`.

The `Makefile` wraps the common invocations; the raw commands are recorded
below for when a wrapper is not enough.

## From zero

If you have never used Guix, three steps stand between a clean machine
and an image. Guix is the only host dependency — it brings its own
toolchain, so there is nothing else to install and nothing to install
system-wide.

1. **Install Guix** on any x86_64 GNU/Linux distribution, following the
   upstream instructions (the binary installation script on a "foreign
   distro" is the usual path). Nothing here needs Guix System; a Guix
   *package manager* on Debian/Fedora/Arch is fine.

2. **Pull the channel set this repo builds against.** `channels.scm` in
   the repo root is a working channel list carrying nonguix and its
   channel introduction — the signing key that makes `guix pull` trust
   it. Without nonguix, every build here fails at module resolution,
   because `linux-pinenote` builds from nonguix's vanilla kernel.org
   `linux` (linux-libre cannot carry the PineNote display stack).

   ```sh
   guix pull -C channels.scm
   hash guix                     # pick up the newly pulled guix
   guix describe                 # record this; images are only as
                                 # reproducible as the channels that built them
   ```

   Expect this to take a while the first time.

3. **Authorize nonguix substitutes before the first kernel build** (see
   the prerequisites below). This is not optional in any practical
   sense: with substitutes most of the toolchain arrives prebuilt;
   without them the cross-built kernel alone is an hours-long build.

Then `make rootfs-reader` produces the artifact, and
`doc/hardware-deploy.md` covers writing it to a device — a manual,
os2-only, user-present procedure, deliberately.

**Reality check before you start:** a full image pulls tens of GB into
`/gnu/store`, and this repo has only ever been built by its author on one
machine. If something fails at module resolution, the nonguix channel is
the first thing to check.

## Host prerequisites

- An x86_64 GNU/Linux host with Guix installed and current-ish
  (`guix pull`). Everything cross-builds to `aarch64-linux-gnu` from
  x86_64; no aarch64 hardware or binfmt emulation is needed.
- **The channel depends on nonguix** (see `.guix-channel` /
  `channels.scm`): `linux-pinenote` builds from nonguix's vanilla
  kernel.org `linux` package (linux-libre cannot carry the PineNote
  stack), and the firmware/font packaging uses nonguix's license
  helpers. Your `guix pull` channel set must include nonguix or every
  build here fails at module resolution.
- **Set up substitutes for nonguix before the first kernel build.**
  Subscribe to `https://substitutes.nonguix.org` and authorize its
  signing key (see nonguix's README for the current key; the usual
  moves are adding the server to `--substitute-urls`/your
  `guix-daemon` configuration and `guix archive --authorize` with the
  published key). Be warned honestly: without substitutes, the
  cross-built PineNote kernel alone is an hours-long build, and a full
  image pulls tens of GB into `/gnu/store`. With substitutes, most of
  the toolchain arrives prebuilt and only the PineNote-specific
  packages compile locally.
- **`TIME_MACHINE=1` builds against the pin; without it you build
  against your last `guix pull`.** Every build target routes through
  `guix time-machine -C channels.scm --` when the flag is set:

  ```sh
  make rootfs-reader TIME_MACHINE=1     # pinned
  make rootfs-reader                    # ambient guix, whatever you pulled
  ```

  It is opt-in rather than the default because a cold cache has to
  materialize the pinned Guix first, which would turn the cheap rung-2
  gates (`make kernel-drv`, ~0.6 s) into a long build.

  **The 2026-08-26 pin bump made `TIME_MACHINE=1` work again on
  current `main`.** From 2026-08-25 until then it was broken: the
  kernel had moved to the `nongnu:linux-7.1` series pin while
  `channels.scm` still pinned a nonguix commit (`3ed7c20`) predating
  `linux-7.1`, so every time-machine build died at module evaluation
  with `Unbound variable: nongnu:linux-7.1`. The bump pinned the exact
  channel generation the working ambient builds were using, and its
  acceptance gate was equality: `make kernel-drv TIME_MACHINE=1`
  resolves the *identical derivation* as the ambient build, and
  `make kernel-version-check TIME_MACHINE=1` passes. The
  byte-identical-rebuild claim therefore holds for `v0.1.0-prealpha`
  with its pin and for `main` from the bump onward — not for the
  2026-08-25→26 window between. The lesson is now procedure: **a
  kernel-series bump and the channel-pin bump travel in the same
  change** (`make channels-pin`, then both TIME_MACHINE=1 gates). See
  issue #13 for the history (the base used to be the floating
  `nongnu:linux` alias, which is how 7.1 arrived uninvited in the
  first place). Note the pinned nonguix generation has since deleted
  `linux-7.0` upstream — the 7.0.11 track builds only through the
  *old* pin at the `v0.1.0-prealpha` tag, another reason the tag's
  pin is never rewritten.

  Three `guix` call sites stay ambient **by design**, and are not
  oversights: the `guix-shell` toolchain helper in the `Makefile`
  (bypassed wholesale by `HOST_TOOLCHAIN=1`), `make channels-pin` (which
  must describe the *ambient* guix or it could not regenerate the pin),
  and `pinenote/tools/koreader-input/run-tests.sh`'s `guix build
  koreader-bin` fallback (override with `KOREADER_BUNDLE=`).

  The known-good channel set — every hardware-validated image since
  2026-06-05 built against it — is:

  ```
  guix    2cd0118  https://git.guix.gnu.org/guix.git        (master)
  nonguix 3ed7c20  https://gitlab.com/nonguix/nonguix       (master)
  saayix  f0e272e  https://codeberg.org/look/saayix         (main)
  ```

  That set built the 7.0.11-era images and remains true of them; it
  cannot build the current 7.1-series tree (the paragraph above).

  Record your own `guix describe` output alongside any image you
  deploy, so a misbehaving build can be bisected to a channel bump.
- **Fonts (optional).** The hardware-validated reader images bundle
  personally-licensed fonts staged from the gitignored
  `pinenote/fonts/local/` (see `pinenote/fonts/README.md`). A fresh
  clone builds fine without them — KOReader falls back to its bundled
  Noto fonts — but the result is typographically different from the
  images `doc/status.md` validated.

## System flavors

See `doc/pinenote-flavors.md` for the flavor matrix. **The `reader`
flavor is the product and the current deploy target** — start there
(`make rootfs-reader` is the one-command path to a deployable artifact).
Build a system closure:

```sh
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-reader.scm
```

Build the deployable disk image (an MBR image with a single ext4 partition;
the rootfs gets extracted from it before deployment, see below):

```sh
guix system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-reader.scm
```

Substitute any other flavor entrypoint from `pinenote/systems/`. Every
flavor carries the primary kernel — since the embrace sweep (2026-09-03)
that is the direct-mode EBC driver, `doc/embrace-sweep-plan.md` — except
`usb-console-linux-6-6`, which exists to vary it (regression isolation
only; see `doc/status.md`). `reader-debug` and `reader-direct` are gone:
the driver carries `EXTRACT_FBS` natively and the reader carries the
direct-mode wiring itself (`doc/pinenote-flavors.md`).
`usb-console` is the bring-up/debug image — the gadget console without
KOReader.

### Per-checkout build flags

Two environment variables change what gets built. The Makefile
`-include`s a gitignored `local.mk` at the repo root, so a choice can be
made once instead of retyped:

```make
# local.mk -- gitignored, never committed
export WILKBOOK_TIMEZONE = Europe/Dublin
export WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE = 1
```

Either also works as a one-off prefix (`WILKBOOK_TIMEZONE=Europe/Dublin
make image-reader`). `WILKBOOK_TIMEZONE` sets the timezone for **every**
flavor and defaults to `Etc/UTC`; an unusable name aborts the evaluation
with an explanation rather than shipping a dangling `/etc/localtime`
(`pinenote/timezone.scm`, gated by `make timezone-check`).
`WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE` is the reader flavor's
development-conveniences switch (`pinenote/insecure.scm`). The rationale
for both is in `README.md` § Build flags.

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

Three things to know about the artifact root before relying on it:

- **It is volatile.** `/tmp` does not survive a host reboot; rebuild (or
  copy out) any rootfs a later deploy session will reference.
- **The name is load-bearing**, not just a default: the preflight/QEMU
  scripts hard-contain their writes under `/tmp/wilkbook` and fail
  loudly on anything outside it. `ARTIFACTS=` overrides where the
  Makefile puts artifacts, but for the `qemu-virt*` targets the override
  must still resolve under `/tmp/wilkbook`.
- **It was renamed on 2026-08-24** from `/tmp/opencode` (a previous
  coding tool's name), scripts and containment checks moving in the same
  change. The cutover is hard: nothing accepts the old root any more.
  Session records dated before then — `doc/status.md`, `doc/artifacts/`,
  `doc/archive/`, `doc/reviews/` — still name `/tmp/opencode`, because
  that is where those runs actually wrote. Read it as this same root
  under its old name; do not "fix" those entries.


The raw image is a build intermediate, never written to the device whole.
Extract the single ext4 partition into a direct rootfs artifact labelled
`PNGuixRoot`, validate it, and stage a matched boot bundle from it:

```sh
mkdir -p /tmp/wilkbook/pinenote-rootfs-artifacts
rootfs=/tmp/wilkbook/pinenote-rootfs-artifacts/pinenote-$(date +%Y%m%d).ext4

pinenote/scripts/preflight/extract-rootfs-from-raw.sh \
  /gnu/store/...-disk-image "$rootfs"
pinenote/scripts/preflight/inspect-rootfs-image.sh "$rootfs"

bundle=/tmp/wilkbook/pinenote-boot-bundle-$(date +%Y%m%d)
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
make qemu-virt ROOTFS=/tmp/wilkbook/pinenote-rootfs-artifacts/<artifact>.ext4 \
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
make qemu-virt-check ROOTFS=/tmp/wilkbook/pinenote-rootfs-artifacts/<artifact>.ext4 \
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
   `make check-host` runs every suite that needs no hardware and no
   waveform in one command; `make check-host WBF=/path/to/ebc.wbf
   KOREADER_BUNDLE=/path/to/koreader-bundle` folds in `wbf-check` and the
   waveform-gated tests, which a reader candidate requires.
   These compile the verbatim EBC driver/waveform sources and catch
   driver-logic and waveform regressions. The Rockchip PM gate separately
   compiles the verbatim typed model/executor, builds and parses donor/maximal
    Run `make check-host` (add `WBF=` for a reader candidate); each
    gate's exact guarantees are catalogued in `doc/testing.md`. Run the
    relevant gates whenever you touch either kernel patch.
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
   only under `/tmp/wilkbook`).
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
