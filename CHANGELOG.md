# Changelog

Maintained as work lands rather than only at release time, and written
for someone holding the device rather than for someone reading the diff.

Numbers here follow the same rule as the rest of the repo: **measured**
means an instrument or a log said so, and anything that is division from
a measurement is labelled as such. Depth lives in `doc/`; these entries
are pointers, not summaries.

Nothing after `v0.1.0-prealpha` has been tagged or cut as an image. If
you are running wilkbook today you are running the pre-alpha image
`9a08803e…` on Linux 7.0.11, and everything under **Unreleased** that
was proven was proven on that image.

## Unreleased

### Battery and suspend

- **Standby has a measured number for the first time.** Six days and
  four hours unplugged, never on a charger: **5.47 mA sitting idle** and
  **10.07 mA as the device was actually read**. Against a 4000 mAh
  battery that projects to ~30 days idle and ~16.6 days in use — the day
  figures are arithmetic from the measured draw, not an observed run to
  empty (`doc/artifacts/pinenote-ultra-soak-20260815/`).
- The framing the docs now use, because the gap between those two
  numbers is what a reader actually feels: **a month in a bag, a couple
  of weeks in your hands.** Quoting only the 30 quotes the number for a
  device nobody is using.
- **170 suspend/resume cycles over those six days, zero failures**,
  unattended. That is the figure to weigh against the standing warnings
  about a device that will not wake.
- The old "~36 days of standby on paper" arithmetic is retired from
  every current-state document, along with the "the soak is running"
  labels. It still appears in dated entries under `doc/status.md`,
  `doc/artifacts/` and `doc/archive/`, which are an append-only record
  of what was believed on the day and are deliberately not rewritten.
  The hourly RTC backstop wake turns out to cost ~0.83 mA, cheaper than
  that estimate assumed (`doc/power-management.md`).
- **Closing the cover suspends the device — confirmed on glass, on two
  devices.** Expect fussy magnets: six days of ordinary use logged
  2 cover-close suspends against 27 power-button presses. An earlier
  claim that the author's cover could not actuate the sensor at all came
  from a single close in one position and is corrected in place.
- **Opening the cover wakes it too**, so the cover is a complete
  sleep/wake gesture alongside the power button, the RTC and the
  charger. Confirmed on glass, then hardware-attributed to GPIO0 IRQ 63
  — the cover pin — by a paired A/B against a power-button control. Our
  own rails model says that pad should be unpowered in suspend, so the
  mechanism is an open question rather than a settled tradeoff
  (issue #8, `doc/power-management.md`).
- The pen still cannot wake the device, but the reason changed: it is
  not an armed wake source in the device tree at all. The "GPIO0 is
  unpowered in suspend" premise that used to explain it is now known
  false for at least the cover pin, which reopens pen wake as a question
  worth testing (issue #9).

### Setup and first boot

- **The reader now suspends out of the box.** The first install by
  someone other than the author produced a device that never slept: our
  own install page recommended creating an `autosuspend.conf` with
  `enabled=0` for first-boot debugging, and no page anywhere said to
  undo it. Skipping that file is now the recommended path; where it is
  still offered it is labelled a foot-gun with its undo in the same
  breath, and both config locations and their precedence are written
  down where someone diagnosing this will look (`doc/install.md`).
- The README quickstart gained a "check that it sleeps" step, and
  `doc/alpha-expectations.md` names a never-sleeping device as the most
  likely first-boot symptom rather than an exotic one.
- **New: `doc/alpha-expectations.md`** — the tester-facing brief. What
  the reader should feel like, what is known-broken stated up front
  rather than discovered, and the one load-bearing reporting rule: a
  device that fails to wake is forensic evidence, and a ten-second power
  hold destroys it.
- The README no longer claims you need a serial cable to boot os2. The
  U-Boot menu works on the glass and the untouched default is os1; the
  cable is for the AI agent, which has no fingers or eyes.
- Still true and still annoying: the image runs UTC, because the
  timezone is not set at build time (issue #6).

### Display and page turns

One real change to the display driver this cycle, and it has not run on
a panel yet. Otherwise: a long-suspected defect acquired evidence, a name
and a bound.

- **The display can no longer be jammed by something that keeps drawing**
  (#22). Until now, anything producing continuous screen damage — a
  blinking console cursor, and in future continuous pen strokes — could
  hold off a full-screen wash indefinitely, with nothing logged and
  nothing timing out. The same stall could hold off a suspend, because
  the sleep path waits for that same loop to finish. The driver now stops
  absorbing new damage once a wash or a suspend is waiting, so the work
  in flight finishes and the wash goes ahead. This is hrdl's own fix,
  backported.
- **What that is worth in practice, honestly:** the workarounds it
  replaces (a disabled console cursor, and a procedure for supervised
  test sessions) are still in place, so most readers will notice
  nothing. It matters for what comes next — handwriting at ~6 fps is
  exactly the kind of continuous producer that caused the original
  failure.
- **Not proven on hardware.** It is validated by an offline harness that
  runs the real driver code against a simulated controller; no panel has
  displayed a single frame of it. What a busy producer's extra wash looks
  like on glass is an open question for the next device session
  (`doc/driver-findings-report.md`).

- **Occasional two-step page turns are now a documented issue** (#14):
  KOReader itself issues two or more identical full-page refreshes
  ~130–390 ms apart, above the driver rather than in it. 764 traces from
  6.2 days of ordinary reading are committed as the evidence, because a
  reboot rotates the log and the behaviour is not reproducible on demand
  (`doc/artifacts/pinenote-refresh-traces-20260815/`).
- The full series corrected the first analysis. The rate held (3.3 %
  over 764 traces), but these are **episodes** of up to eight
  refreshes in 2.26 s rather than pairs, and the gap distribution is a
  continuum with no natural cutoff. Four of the five episodes begin
  within 15 s of a menu being opened and dismissed.
- An offline qemu-virt page-turn campaign was built to hunt it and **did
  not reproduce it**: 428 taps, 0 of 274 adjacent full-panel pairs under
  500 ms, against 2.51 % in the field. That is a bound, not a
  refutation — virtio-gpu blits in microseconds where the panel takes
  ~300 ms, so the harness lacks the very mechanism the issue blames.
- New host tool `pinenote/tools/refresh-episodes/` scores a device log
  and a harness log the same way, with a threshold sweep instead of one
  convenient cutoff.
- A re-read of hrdl's driver found a **potential 1.25× on every refresh
  mode** — a clock reclock to 79.68 Hz, worth about two device-tree
  lines and ten driver lines. It is not shipped and not measured: it
  raises the display's memory traffic on exactly the path that a
  one-variable A/B proved starves silently when DDR is slowed
  (issue #23, `doc/hrdl-evaluation.md`).

### Kernel

- **The kernel this repo built used to be chosen by when you last ran
  `guix pull`.** The base was a floating nonguix alias; it moved to 7.1
  on its own and `make kernel` stopped working. The base is now an
  explicit series pin, and `make kernel-version-check` detects drift in
  ~0.6 s with no build (issue #13).
- **The tree now targets the 7.1 series and the reader image builds
  again.** Two device-tree hunks were deleted because mainline absorbed
  them verbatim, shrinking the forward-port patch from 31 hunks to 29 —
  the good direction for a forward port. **Nothing on 7.1 has run on
  glass.** The hardware-proven kernel remains 7.0.11, which is what the
  deployed image runs (`doc/kernel-forward-port.md`).
- Two upstream Guix cross-compilation defects are repaired in
  `pinenote/packages/cross-fixes.scm` — alsa-lib declaring its build
  tools as `inputs`, and groff-minimal typesetting PDFs through a
  cross-built binary. They bite only local `--target=aarch64` builds,
  which is why they survive upstream: Guix's farm builds natively per
  architecture and never builds these derivations.
- Audio userland stays in the image. It was dropped under build pressure
  and put back: mainline's PineNote device tree describes stereo
  speakers, an amplifier and a headphone path, and audiobooks on an
  e-reader are an obvious fit (issue #18). The measured cost of keeping
  it is 37 derivations.
- Deleted the abandoned cage/wlroots kiosk package. That approach was
  dropped in July 2026 when KOReader proved it runs natively on fbdev,
  and the module had since rotted to the point of not loading.

### Build, CI and gates

- **First CI for the channel**: three jobs on every push — no Guix, no
  device, no waveform — whose job is protecting the kernel patch stack
  (`.github/workflows/host-gates.yml`). A safety job asserts that no
  waveform or VCOM blob is tracked, that every tracked shell script
  parses, and — by parsing the YAML rather than grepping it — that no
  workflow uses a secret or the fork-privileged pull-request trigger.
  Every run also prints what green does **not** mean: nothing was built,
  nothing was booted, and the waveform parser cannot be covered at all.
- The host gates now run without Guix installed (`HOST_TOOLCHAIN=1`),
  and `guix time-machine -C channels.scm` is finally wired into the
  build targets (`TIME_MACHINE=1`), so the reproducibility claim in
  `doc/release.md` is true of the commands it names (issue #2).
  `make help` gained a Flags section; these were undiscoverable without
  reading the Makefile.
- **A gate for a bug that shipped twice.** A `use-modules` inside a
  Shepherd service's start lambda silently resolves nothing, and here
  the resulting exception was swallowed by a `catch #t`. It shipped live
  on the 2026-08-07 boot, where the DDR service's EBC-idle wait never
  waited and its mode selector always fell back to "normal".
  `validate-gexp-modules.sh` now catches it per service, including
  through helper indirection.
- CI stages the pinned KOReader bundle and replicates the device graft
  rather than skipping the input suite — the suite that covers touch
  normalization and the refresh seam, which is the area under active
  work.
- The reader-energy tests run under bash with a real sleep, so they pass
  on any host whose `/bin/sh` is dash (every CI runner, and no
  workstation here, which is why it stayed hidden).
- **The display harness can now fail a driver for hanging, not just for
  being wrong.** It was correctness-complete and still missed a
  multi-minute stall, because nothing asserted that a refresh ever
  *returns*. The new `ebc-drain-gate-test` asserts exactly that, and — as
  with the page-turn ordering gate before it — the same test is also
  compiled against a copy of the driver with the fix removed and required
  to **fail**. A liveness test that passes either way proves nothing
  (issue #22).

### Docs and evidence

- The README was rebuilt front to back for readers who were not present
  in the development conversations, and 25 further docs were corrected —
  with dated notes in place rather than rewritten history.
- **The README's last unsourced number is closed.** RAM in use at boot
  is **~162 MiB measured** on glass, two minutes after boot with
  KOReader painted and Wi-Fi up — or ~148 MiB for a device running
  unattended, since the SSH session used to take the reading costs
  ~14 MiB (issue #1, `doc/artifacts/pinenote-boot-ram-20260815/`).
- `doc/kernel-forward-port.md` gained an "Upgrading the kernel" section
  separating the two cases that used to be one undifferentiated risk: a
  point release is a cheap offline check, while a series bump is a
  project whose deliverable is *deleted* patch.
- Four new committed artifact sets: the soak, the boot-RAM capture, the
  refresh traces, and the cover-wake attribution.
- Two retractions worth reading as method rather than as news: a
  proposed pen-wake experiment was void because the pen was never an
  armed wake source, and a "measurement artifact" explanation for the
  cover wake was struck by its own author 88 minutes after it was
  written (`5aae5a3` 21:13, `ca59ea0` 22:41, same day).
- `CLAUDE.md` records the two-remote workflow (GitHub is PR-only
  upstream; Forgejo is the working remote) and the `git add -A` incident
  that is why contributors stage explicit paths.

## v0.1.0-prealpha — 2026-08-08

The first public tag, and the first build that could be handed to
someone else. A reader image for the os2 slot: KOReader running natively
on fbdev with pen and touch, all four orientations, single-pass page
turns, the GL16 partial policy with its idle washer, Wi-Fi from
out-of-band credentials, and key-only SSH — hardware-proven on one
device. Ultra suspend (hrdl's rails-off configuration) was promoted the
same day after three measured resumes at 4.64 mA; the multi-day soak
validating it was still running at tag time, so standby was arithmetic
and the tag said so.

Image `pinenote-reader-PNGuixRoot-20260808.ext4`, sha256 `9a08803e…`,
rebuildable byte-identically from `channels.scm`.

The banner on that tag is not decoration — hardly tested, largely
AI-written, will probably break your device. `doc/install.md` states the
prerequisites and the risks, and the signed-off alpha
(`doc/alpha-signoff.md`) has not happened.
