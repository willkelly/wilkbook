# wilkbook

A reading-first operating system for the Pine64 PineNote e-ink tablet,
built as a Guix channel. It boots straight into KOReader on the
framebuffer — pen, finger, four orientations, single-pass page turns —
and runs nothing else. No desktop, no compositor, no display server, no
apps waiting to be closed. The entire OS exists so that a book is on the
screen and the battery is spent on nothing that is not the book. Under
it: a forward-ported vanilla-7.0.x kernel (PREEMPT_RT) carrying the
PineNote display stack as explicit patches, and a one-command path from
checkout to a deployable rootfs.

The pitch is minimal and measured. Current numbers, from one device,
honestly labelled:

| What | Number | Provenance |
|---|---|---|
| RAM in use at boot | ~164 MB | the whole OS, KOReader included (operator-measured; committing a session record is [issue #1](../../issues)) |
| Awake, reading | ~157 mA | measured floor 156.9 mA; stock Debian idles ~230 mA on the same glass (`doc/alpha-expectations.md`, `doc/power-management.md`) |
| Suspended | **4.64 mA** | **measured on hardware 2026-08-08** (`doc/artifacts/pinenote-ultra-r12-20260808/`) |
| Standby | ~36 days | *arithmetic* from that draw; ~28 effective days with backstop wakes; the multi-day soak is running right now |

"Measured" means a battery gauge, a wall clock, and the ABBA discipline
in `doc/power-management.md`. "Arithmetic" means division. This repo
keeps the distinction everywhere, on purpose.

Three words you will meet immediately: **os1/os2** — the two OS slots
(p5 = stock Debian, the untouched rescue slot; p6 = ours, the only
partition ever written); **on glass** — on the physical e-ink panel;
**rung** — a step on the offline validation ladder (`doc/testing.md`).

Built by one human and a lot of AI, validated on exactly one device, and
public so other PineNote people can take the useful parts. Which brings
us to:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### *** W A R N I N G *** W A R N I N G *** W A R N I N G ***

### !!! TURN BACK NOW !!! WE ARE NOT KIDDING !!! THIS MEANS *YOU* !!!

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

*~*~*~ a scrolling marquee is unavailable in markdown. please move your
eyes from left to right at a steady pace for the full effect ~*~*~*

**YOU ARE VISITOR NUMBER: `[0][0][0][0][0][2]`**
*(visitor number 000001 owns the ONLY PineNote this has ever run on.
there has never been a visitor number 000003.)*

**THIS IS AI SLOP HARDLY TESTED NONSENSE. ONLY FLASH THIS IF YOU ARE
INSANE OR HATE YOUR PINENOTE.** That sentence has survived every rewrite
of this README because it is *true*. The specifics, so you can judge for
yourself exactly which kind of insane you are:

- **IT IS LARGELY WRITTEN BY AI.** Most of the code and nearly all of
  the prose came from AI agents working under the rules in `CLAUDE.md`,
  with one (1) human reviewing everything and running every hardware
  session. If the phrase "AI-generated kernel patches on my eMMC" just
  set off a small alarm in your head: GOOD. That alarm is CORRECT.
  Consult it often.
- **HARDLY TESTED means HARDLY TESTED.** Every measured number, every
  "proven on glass" claim, comes from ONE PineNote v1.2. One. There is
  no fleet. There is no QA lab. **NO SECOND PERSON HAS EVER INSTALLED
  THIS.** `doc/install.md` admits it in its first paragraph, because
  honesty is cheaper than support.
- **YOU WILL BE RUNNING `dd` AGAINST YOUR TABLET'S eMMC.** Deployment
  writes a rootfs onto a device that is *notoriously awkward* to
  reflash. The protocol is paranoid — hash before, hash after,
  refuse-rather-than-guess — but at the bottom of it all it is still
  you, root, and a block device. **YOU FLASH AT YOUR OWN RISK.**
- **SOMETIMES THE ONLY WAY OUT IS THE 10-SECOND POWER HOLD.** Real
  sessions have ended with the device wedged before U-Boot, waiting on a
  human thumb to perform the ancient rite of forced power-off.
  Supervised procedures literally *budget one per sitting*. It is a
  documented line item.
- **GET THE SBU DEBUG CABLE ANYWAY.** You can pick the boot slot right
  on the glass with your finger — no serial console needed for that —
  but when a boot goes sideways the UART is your root shell and your
  only window into WHAT IT IS DOING. (It is also a passwordless root
  shell for anyone who physically holds it. That is the recovery
  channel, on purpose. Know this before it surprises you.)
- **THERE IS NO SUPPORT. NONE.** No update path — a new build means the
  whole write protocol AGAIN. No package manager on the device. No
  issue-triage promise. NO WARRANTY OF ANY KIND (`LICENSE`, and it
  means it). If it breaks, you get to keep all the pieces, which is
  generous, because e-ink breaks into SO MANY pieces.

~~~ AND YET ~~~ the safety model is paranoid *in your favor* ~~~

- **os1 IS SACRED.** Stock Debian on the rescue slot is never written,
  never reconfigured, never even breathed on. Every procedure in this
  repo is built around keeping that escape hatch open. Builds NEVER
  touch the device at all; deployment is a separate, manual, os2-only
  act of will. An untouched reboot lands you back in os1.
- **NEVER SEND US YOUR WAVEFORM. WE WILL NEVER SEND YOU OURS.** The EPD
  waveform and VCOM are per-device FACTORY CALIBRATION, extracted from
  your own device's waveform partition at boot. The build FAILS LOUDLY
  rather than bundle a generic one. Do not post yours. Do not ask for
  the author's. This is not etiquette — it is how your panel stays a
  panel.

And if you only came for the *good stuff* — host tools that test the
display driver on your desk, driver bugs with reproducers, waveform
decoders — relax and keep scrolling: **none of it touches your device
at all.**

`<blink>` imagine, if you will, that this line is blinking `</blink>`

~~~~~~ THIS PAGE IS UNDER CONSTRUCTION ~~ IT ALWAYS WILL BE ~~~~~~

## Quick start

The short version. `doc/install.md` is the long version — read it before
step 3, because step 3 is where the `dd` lives.

**0. What you need.** A PineNote v1.2 with a working stock Debian on
os1; backups of your waveform partition, VCOM, and partition table
(`doc/device-runbook.md`); a USB-C SBU debug cable run at 1500000 baud
(`doc/device-access.md`); a GNU/Linux host with Guix and the nonguix
channel (`doc/building.md` starts from zero). Charge to ~100% *before*
the cable goes on — the cable and the charger share the PineNote's one
port.

**1. Build.** Everything is pinned by commit; a tagged tree rebuilds
byte-identically anywhere:

```sh
guix time-machine -C channels.scm -- \
  system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-reader.scm
```

Or `make rootfs-reader`, which builds the image *and* extracts the
rootfs you will actually write (an ext4 labelled `PNGuixRoot`) into
`$(ARTIFACTS)`. Fair warning: a cold kernel cross-build is hours, not
minutes. Add `TIME_MACHINE=1` and the wrapper *is* the pinned,
byte-identical path shown above — without it you build against whatever
your last `guix pull` produced, which is currently a kernel that does not
compile (`doc/building.md`, issue #13). Day-to-day:
`make help`, `make kernel-drv` (seconds, before any real build),
`make qemu-smoke`. The gitignored licensed fonts are optional — a fresh
clone builds and runs with KOReader's bundled fallbacks
(`doc/building.md`).

**2. Stage your life on the data partition.** The image is generic on
purpose — no credentials, keys, or books ever enter it. Everything yours
lives on p7 (label `data`), which survives reflashes and which stock os1
mounts at `/home`, so you can stage all of it from os1 before os2 ever
boots. Paths relative to the partition root:

- `wifi/wlan0.conf`, mode 0600 — plain wpa_supplicant(5) format, with a
  `country=` line and the PSK *hash* from `wpa_passphrase`, never the
  passphrase:

  ```
  country=US
  ctrl_interface=/run/wpa_supplicant
  update_config=1
  network={
      ssid="YourNetwork"
      psk=<64-hex-from-wpa_passphrase>
  }
  ```

  (the two extra lines are inert today; they feed the planned on-device
  Wi-Fi picker — `doc/networking.md` §4.1.)

  No file means no Wi-Fi and no drama: the reader boots fine without it
  (`doc/networking.md`).
- `ssh/authorized_keys` — your public key. A boot service installs it
  for root on every boot, so it survives reflashes. SSH is key-only: no
  staged key, no SSH, and your way in is the console. (p7 also comes to
  hold the device's *private* SSH host identity under `ssh/host/`, so
  back p7 up like it contains key material — it does.)
- `books/` — your library. KOReader's home is `/data/books`; a
  first-boot service creates the directory if it is missing
  (`pinenote/services/library.scm` — proven in QEMU fixtures, not yet on
  a second device), but only you can put books in it.
- `wilkbook/autosuspend.conf` — **optional, and a foot-gun.** Writing
  `enabled=0` here pauses auto-suspend, which is genuinely handy while
  you are poking at a new device over SSH (otherwise it naps five
  minutes in and each nap costs a physical button press). **If you write
  it, you must undo it** — a device with this file at `enabled=0` never
  sleeps, shows no suspend banner, and burns ~157 mA forever. Undo with
  `enabled=1`, or just delete the file; the daemon re-reads it before
  every idle wait, so no reboot is needed. Skip this bullet entirely and
  suspend works out of the box — the recommended path.

**3. Write os2.** Copy the extracted rootfs, its SHA-256, and
`pinenote/scripts/preflight/write-os2-verified.sh` to os1 over SSH.
Then, from a root shell on os1, with backups verified and
`doc/install.md` read:

```sh
./write-os2-verified.sh pinenote-reader-PNGuixRoot-YYYYMMDD.ext4 <sha256>
```

The script refuses to run from os2, refuses a mounted target, derives
every block count instead of trusting you to type one, and SHA-verifies
the readback. It writes p6 and nothing else. os1 — your rescue slot —
is never touched.

**4. Boot it.** Power on and pick **"Boot OS2 (part 6)"** at the U-Boot
menu, on the device itself — the menu works on the glass, no serial
console needed, with a ~15 s countdown. A boot where nobody touches the
menu lands in os1, which is exactly the behaviour you want from a rescue
default.

**5. Check it sleeps.** Leave it untouched for six minutes. You should
see your page with a `SUSPENDED` banner and the frontlight off; SSH and
ping go dead. If it never sleeps, check
`cat /data/wilkbook/autosuspend.conf` first — see the previous step.

**6. Read.** Page turns are single-pass, the device suspends itself when
you drift off, and it sips 4.64 mA while you sleep (one measured 40-minute bracket;
the multi-day soak is running). What it should feel like, and what is
known-broken: `doc/alpha-expectations.md`. That is the whole product.

## What to steal

Written for other PineNote people. Nothing in this section requires
Guix, a deployment, or this repo's packaging unless it says so; the real
coupling is to the kernel patch and to the driver source, both of which
you probably already carry.

**Test the display driver on your workstation.** These compile the
*verbatim* `rockchip_ebc` / `drm_epd_helper` source straight out of
`pinenote/patches/linux-pinenote-7.0-forward-port.patch` — extracted at
build time, never hand-copied — so they cannot drift from the driver.
`gcc` + `python3`; no device.

- `pinenote/tools/wbf` — decodes your panel's own PVI `.wbf` exactly as
  the driver loads it (modes, temperature bins, LUTs), and dumps LUTs for
  the simulator. The cheapest way to find out what your waveform file
  actually contains.
- `pinenote/tools/ebc-logic` — the driver's pure logic (XRGB8888/R4→Y4
  blitters, damage split/collision scheduling) against independent
  references, plus a behavioral device model that *executes* the refresh
  state machine (probe, LUT upload, DMA windowing, IRQ/completion) under
  ASan, plus `ebc-replay`, which replays KOReader refresh traces through
  it under candidate policies.
- `pinenote/tools/rastersim` — a dependency-free C Gray8→Y4 raster
  library and waveform simulator; the independent reference that pinned
  the LUT `(from, to)` axis order three separate ways.
- `pinenote/scripts/preflight/validate-*-hunk.sh` — POSIX-shell
  structural gates over the patch itself, with mutation tests. They exist
  because a host harness compiles the `#else` stub of any `#ifdef` it
  does not define, so a green suite can prove nothing about code inside a
  config guard. If you carry the same patch, these port unchanged.

**Measure what the panel actually does.**

- `pinenote/tools/optics` — a camera-in-a-box optical-defect instrument:
  a self-calibrating EPUB test card, video ingest, and deterministic
  black-flash / ghosting / slow-settle / double-flash classifiers.
  Explicitly designed to be portable to other people's PineNotes — a
  phone camera and a dark box are enough to produce a comparable dataset.
  Analysis is pure Python and needs no device.
  `pinenote/tools/optics/belief-vs-glass.sh` is the cheap version of the
  same idea: put `/dev/fb0` (what the driver believes it painted) next to
  the photo (what the glass shows), so "looks bad" becomes a measurement.
  (Edit the host/known-hosts at the top; it is written for the author's
  device.)
- `pinenote/tools/ebc-damage-probe` — device-side LuaJIT probes that
  write chosen patterns into the mmapped framebuffer and count EBC
  interrupts, isolating deferred-io and damage scheduling from KOReader
  entirely. This is the instrument that found fbcon starvation and drove
  the `defio_delay_ms` choice. Needs `/dev/fb0`, `/proc/interrupts` and
  LuaJIT; its build snippets hardcode Guix store paths you would replace.
- `pinenote/tools/power/fb-damage-gates.sh` — a read-only dump of the
  four silent gates between a userspace framebuffer write and an EBC
  frame. It deliberately opens no device node (the first opener of
  `/dev/dri/card0` becomes DRM master).

**Kernel work.**

- `pinenote/patches/linux-pinenote-7.0-forward-port.patch` — the EBC
  display stack, `drm_epd_helper`, WS8100 pen, PineNote DTS and
  `pinenote_defconfig`, forward-ported onto vanilla 7.0.x and
  hardware-validated. Six smaller patches ride alongside it (BSP SIP
  suspend, cpuidle, vdd_cpu PFM, DDR static-low, st_accel PM, and the
  ultra rails-off suspend — 4.64 mA measured 2026-08-08).
  `doc/kernel-forward-port.md` carries the inventory, the refresh
  procedure, the config lessons, and the community cherry-pick record.
- `pinenote/tools/ddr-sip-probe/src` — a ~zero-risk out-of-tree module
  that asks whether your bl31 implements the Rockchip DRAM-frequency SIP
  and then returns `-ENODEV` so it can never stay loaded. Plain Kbuild;
  only its `guix.scm` is Guix-specific. (Its sibling `ddr-dvfs-test`
  *changes* the DDR rate and is the highest-risk artifact in the repo —
  read its `protocol.md` before you consider it.)
- `pinenote/tools/orientation/orientation-bridge.lua` — SC7A20
  accelerometer → uinput orientation bridge in plain LuaJIT, independent
  of the display driver; you would swap the Shepherd handshake for your
  own supervisor.
- `pinenote/tools/koreader-input` — runs KOReader's *own*
  `input.lua`/`gesturedetector.lua` against synthetic evdev streams;
  reproduces the pen-hover tap-capture bug (finger tap read as a swipe)
  and pins cyttsp5 touch-axis normalization to measured targets.

**Findings and method.**

- `doc/driver-findings-report.md` — a community-facing writeup of
  `rockchip_ebc` defects found from the desk (heap overrun on odd clips,
  a scheduler hole, teardown UAF, …), each with a deterministic
  reproducer and its fix status. Written to be posted upstream.
- `doc/refresh-policy.md` + `doc/pageturn-program.md` — waveform decodes,
  the publish-on-call fix for the portrait double refresh, the GL16
  partial policy and idle washer, and the replay workbench behind them.
- `doc/eink-research.md` + `doc/eink-sota.md` — curated e-ink domain
  background, and an adversarially-verified state-of-the-art survey with
  a ranked steal list and a corrections register.
- `doc/device-access.md` — the UART/SSH/console conventions that cost
  sessions to learn: 1500000 baud, the device-side 9600 termios trap, a
  flipped USB-C plug swapping SBU1/SBU2, proving the link with the SoC's
  own `tx`/`rx` counters, and post-mortem log harvest from the other slot.
- `doc/power-management.md` and `doc/artifacts/` — the measured power
  ledger and the raw session evidence (scripts included) behind it,
  including the ABBA measurement discipline used to cancel drift.
- `doc/testing.md` — the method itself, which is the most portable thing
  here: verbatim source extraction, independent references rather than
  re-pasted code, "absence of an error is not a passing test", and why a
  single-stack harness models ordering but not races.

## Status (2026-08-08)

- **Product**: the reader image on os2 — KOReader natively on fbdev with
  pen/finger input, four orientations, publish-on-call single-pass page
  turns, the GL16 partial policy + idle washer, Wi-Fi with out-of-band
  credentials, key-only SSH. `v0.1.0-prealpha` is tagged; the alpha
  sign-off (`doc/alpha-signoff.md`) has not happened.
- **Ultra suspend is in production** (2026-08-08): hrdl's rails-off
  configuration on the primary kernel, **4.64 mA measured on glass**
  (`doc/artifacts/pinenote-ultra-r12-20260808/`) against the superseded
  deep's ~20 mA — ~36 days of pure suspend on paper, labelled
  arithmetic. The device sleeps after 5 idle minutes; only the power
  button, the RTC backstop, and the charger can wake it — the rails-off
  tradeoff unpowers GPIO0 during suspend, so the pen cannot — though
  the cover demonstrably does wake it (2026-08-09), which the model does
  not yet explain.
  A ≥3-day unplugged soak is RUNNING; until it concludes, multi-day
  standby is arithmetic on one good measurement. SSH to a deployed
  reader is intermittent while auto-suspend is enabled
  (`doc/device-access.md`).
- **Kernel**: the vanilla-7.0.x forward port is the hardware-proven
  primary (display, PREEMPT_RT, Wi-Fi/BT, gadget). Seven patches total —
  `doc/kernel-forward-port.md`.
- Exact image hashes, session records, and the full history:
  `doc/status.md`.

## Alpha

Alpha targets operators who build from source and are comfortable with a
serial console for recovery. No one outside the author has installed it
yet; if you are provisioning your own device, `doc/install.md` is your
starting page, `doc/alpha-expectations.md` says what it should feel
like, and `doc/alpha-signoff.md` is the bar an actual alpha release has
to clear. `doc/alpha-checklist.md` tracks what stands between the
prealpha tag and that bar.

## Reading order (humans)

1. This file, then `doc/status.md` (current-state header) — where we are.
2. `doc/building.md` — host setup and your first build.
3. `doc/install.md` — the path from a stock PineNote to a booting os2, if
   the device is yours rather than the author's. Then
   `doc/hardware-deploy.md` (the write protocol) + `doc/device-runbook.md`
   (the backup ledger).
4. `doc/testing.md` — the offline validation ladder; read before changing
   code. `doc/worked-examples.md` shows the philosophy applied.
5. `ROADMAP.md` — direction. `CLAUDE.md` — required reading for AI agents,
   useful for humans too (safety model, conventions).

## Layout

- `pinenote/packages/` — three kernel packages (`linux-pinenote` forward
  port, `linux-pinenote-debug` with diagnostics + `EXTRACT_FBS`,
  `linux-pinenote-6.6.30` regression baseline), Broadcom Wi-Fi/BT
  firmware packages, firmware helper scripts, the KOReader device target.
- `pinenote/patches/` — the kernel forward-port patch (EBC driver, WS8100
  pen, PineNote DTS, `pinenote_defconfig`) plus the smaller
  power-management patches (BSP SIP suspend, cpuidle, vdd_cpu PFM, DDR
  DVFS, st_accel PM). `doc/kernel-forward-port.md` has the inventory.
- `pinenote/services/` — Shepherd services: waveform install, EBC
  parameters, reader session, orientation bridge, auto-suspend, DDR
  DVFS (dmc + input-driven boost), networking, USB CDC-ACM gadget
  console, diagnostics.
- `pinenote/images/` — initrd wrappers, extlinux bootloader config, kernel
  arguments, partition labels.
- `pinenote/systems/` — flavor entrypoints (see `doc/pinenote-flavors.md`).
- `pinenote/scripts/preflight/` — non-destructive inspection and extraction
  helpers.
- `pinenote/tools/` — test and diagnostic tools. Host-side (no device):
  `wbf`, `ebc-logic`, `rastersim`, `orientation`, `koreader-input`,
  `optics`, `power`, `rockchip-pm`, `ebc-barrier`. Device-side and
  supervised: `ebc-damage-probe`, `ddr-sip-probe`, `ddr-dvfs-test`. The
  table in `doc/testing.md` gives each one's rung and coverage.
- `pinenote/fonts/` — optional, gitignored personally-licensed fonts
  (`pinenote/fonts/README.md`).
- `doc/` — the doc map in `CLAUDE.md` describes every document. Highlights:
  `status.md` (hardware truth), `testing.md`, `building.md`,
  `hardware-deploy.md`, `device-runbook.md`, `device-access.md`,
  `networking.md`, `refresh-policy.md`, `power-management.md`,
  `kernel-forward-port.md`, `eink-research.md` + `eink-sota.md` (domain
  background), `driver-findings-report.md` + `upstream-register.md`
  (community-facing), `pinenote-flavors.md`. `doc/archive/` holds
  historical documents, `doc/artifacts/` committed hardware-session
  evidence, `doc/datasets/` the committed optics dataset.

## Firmware and waveform policy

- The per-device EBC **waveform is never bundled**. The initrd and a
  first-boot service extract it from the device's own `waveform` partition
  (fallback: `/state/firmware/ebc.wbf`) into
  `/lib/firmware/rockchip/ebc.wbf`, failing visibly if absent.
- Broadcom Wi-Fi/BT firmware is packaged from public sources
  (linux-firmware, RPi-Distro bluez-firmware). The kernel builds from
  vanilla sources via nonguix because linux-libre refuses to load these
  blobs (see `doc/kernel-forward-port.md`).
- VCOM calibration, waveform, U-Boot, and partition-table backups are
  recorded per-device in `doc/device-runbook.md` before any hardware work.

## Licensing

The channel's own code (Scheme, tools, docs) is AGPL-3.0 (`LICENSE`).
Kernel patches carry the kernel's licenses (GPL-2.0, per the SPDX headers
inside the patch files) — a patch to GPL-2.0 code is GPL-2.0. The KOReader
device target follows upstream KOReader (AGPL-3.0). Nothing in this repo
relicenses upstream work.

## Safety model

Builds never touch the device. Deployment writes only the `os2` slot after
the backup checklist passes, never the bootloader, partition table,
`waveform`, or `os1` rescue system, and never persists U-Boot environment or
boot-order changes. Reboots and other destructive steps are user-present.

## Build flags

One knob, off by default: `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE`.

Bring-up on a one-port device sometimes genuinely needs an
unauthenticated shell — the debug cable and the charger are mutually
exclusive, and serial cannot wake a suspended device. The design rule is
that this must be a deliberate, visible choice: opt-in, gated together,
and every reader build names which one it is in `/etc/wilkbook-build`.

So it is opt-in:

```make
# local.mk at the repo root -- gitignored, per-checkout
export WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE = 1
```

or `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE=1 make image-reader` for a
one-off. A plain clone cannot build the conveniences by accident.

What it gates, listed explicitly in `pinenote/insecure.scm` so that
adding to the list is a deliberate edit that shows up in review:

- the **USB ACM gadget console**, which execs a shell on `/dev/ttyGS0`
  with no login prompt at all;
- **passwordless sudo** for the `reader` account, which is what makes
  that shell root-equivalent.

The two move together on purpose: a build with the shell but no sudo is
just latent, and one with sudo but no shell is the worst of both.

**Every reader build says which one it is.** `/etc/wilkbook-build` is
present either way and names the build, so a mounted image or a running
system answers the question without inferring from behaviour:

```
WILKBOOK_BUILD=default                     # or: very-insecure-for-convenience
```

Verified by inspecting built systems, not by reading the code: the
secure closure contains zero `shepherd-pinenote-usb-acm-console` items
and no `NOPASSWD` line; the insecure one contains both.

**Scope: the flag and the marker are on the `reader` flavor.** The
bring-up flavors carry the conveniences unconditionally and write no
marker — `pinenote/systems/pinenote-usb-console.scm` ships the
unauthenticated ACM console, `reader ALL=(ALL) NOPASSWD: ALL`, and an
auto-login getty by definition. They are debug images.

Neither build sets an account password, and `%base-services` runs a getty
on the kernel console, so **the SBU debug cable is a passwordless root
shell on any build** while the device is awake (`doc/device-access.md`).
That is the recovery channel, deliberately. "Default" means not reachable
over a USB data cable, not locked down.

## Hosting

The canonical public home is <https://github.com/willkelly/wilkbook>
(tagged `v0.1.0-prealpha`). Issues and contributions go through GitHub.
