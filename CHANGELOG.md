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
- The image runs UTC unless you say otherwise: `WILKBOOK_TIMEZONE`
  chooses the zone at build time for every flavor, and the default stays
  `Etc/UTC` because a guess at where you live would be wrong for most of
  the world (issue #6, `README.md`).
- **New, and off unless you turn it on: the device can set its own
  clock.** Getting the zone right does not help if the underlying time is
  wrong, and nothing here ever set it — the reader kept whatever the RTC
  held. `pinenote-timesync` steps the clock from an NTP server whenever a
  network happens to be there, and writes the correction back to the RTC
  so it survives a flat battery. It ships with **no server configured**,
  so out of the box the image still talks to nothing; naming one is a
  line in your system configuration (`doc/networking.md` §7):

  ```scheme
  (service pinenote-timesync-service-type
           (pinenote-timesync-configuration
            (servers '("192.168.1.1"))))
  ```

  Your router is usually the right answer. With no Wi-Fi it does nothing,
  quietly and forever — it cannot wake the device, it will not open a
  socket without a route, and it gives up more slowly each time a server
  does not answer, because the battery budget for all of this is 5.47 mA.
  **Nothing here has been booted: no clock has been set on a PineNote**
  (issue #27).
- Why you would care: everything this project reconstructs about a device
  — when a suspend happened, how long a page turn took, which day a log
  line belongs to — is a timestamp. A clock that is quietly wrong makes
  all of it read plausibly wrong, which is worse than reading obviously
  wrong.

### Reading material

- **The device's own manuals are now books.** Every man page and Texinfo
  manual carried by the software on the reader — 532 pages and 24 GNU
  manuals as it stands — is converted to EPUB when the image is built and
  staged into `/data/books/Manuals`, where KOReader opens them like any
  other document. `Manual pages.epub` has a section index with every
  page's one-line description and working `grep(1) -> sed(1)` cross
  references; each GNU manual is its own book with its node tree as the
  table of contents. About 4.9 MB on the data partition.
- Why it matters beyond novelty: this stuff has always shipped —
  `man-db` and `info-reader` come with the base system — and there has
  never been a way to read a word of it, because the device has no
  terminal. It also means a device with an empty library has something
  in it on first boot.
- **Nothing here has been rendered by KOReader yet.** The conversion is
  tested offline and every book is structurally sound with every
  internal link resolving, but no engine has laid one out: typography,
  table-of-contents behaviour and how long the big man book takes to
  open the first time are all unknown. Read `doc/manuals.md` before
  quoting anything about how it looks.
- If you delete the `Manuals` folder it stays deleted, including across
  a reflash. Books you put in it yourself are never touched.

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
- **Pinch-to-resize costs one page pass, not one per size step** — and
  we know that because we measured it before building anything (#26).
  The worry was that a pinch spanning several font sizes would redraw
  the page for each one, seconds of panel activity for one gesture. It
  does not: KOReader classifies pinch and spread only when the fingers
  *lift*, so the interaction is a single redraw however long it takes or
  however fast the panel samples. The proposed "small indicator while
  you pinch, full render on lift" plugin was therefore **not built** —
  the deferral already exists a layer lower, and drawing an indicator
  would have *added* panel activity to an interaction that currently
  costs one pass (`doc/refresh-policy.md`).
- **What the measurement found instead: pinch briskly.** Upstream only
  accepts the gesture if the whole pinch finishes in under about a
  second; slower than that and nothing happens at all, with no message
  saying why. On a display that teaches you to slow down, that is
  backwards. Reproduced offline as a one-variable A/B and recorded for
  upstream rather than patched locally (`doc/upstream-register.md`
  item 12); `doc/alpha-expectations.md` now tells testers.
- New offline coverage for both, plus which two-finger gestures are
  actually reachable here (pinch, spread, rotate, two-finger tap,
  two-finger swipe):
  `pinenote/tools/koreader-input/test-continuous-gesture-cost.lua`, in
  `make koreader-input-check`. **Nothing in this item has been seen on a
  panel.**
- **Four of the five candidate causes are now ruled out**, from the
  committed traces plus KOReader's own source: a footer or progress-bar
  repaint growing to full page, the page-turn animation path, a document
  re-render, and our own idle washer. The survivor is a duplicated touch
  — and it is precisely the one a refresh log cannot see, because no
  trace records an input. Closing it means logging page turns on the
  input side, which changes the shipped reader, then reading for another
  few days (`doc/pageturn-program.md` §6).
- Two claims from the earlier analysis are **corrected by the same
  files**. The "hard floor at 131 ms" is not a floor: those six days
  contain identical full-screen repaints **68 ms** apart. And the
  behaviour is not specific to page turns — counting full-screen
  repaints of every kind there are **11** rapid runs, not five, and the
  largest is ten in 3.7 seconds.
- **A second, far more regular two-step surfaced.** Dismissing a menu
  produces a full-screen wash and then *another* full-screen repaint
  about 0.85 s later — two full-screen updates for one dismissal, at a
  near-constant delay. It is not universal: about one dismissal in five
  (6 of 27 washes), four of them at about 0.85 s. Nobody has watched the panel during one, and it
  is unexplained, but it is much easier to chase than the page-turn case.
- `make refresh-trigger-check` re-derives every number above from the
  committed logs. It is the first gate in the offline roster whose input
  is field evidence rather than a fixture: if those logs move, it fails
  loudly instead of quietly measuring something else.
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

- **New rung-1 gate: `make koreader-profile-check`** — KOReader's
  reading defaults now have exactly one writer, and the gate fails if a
  second appears. There were two, and only one of them could ever run:
  that is how a build once shipped with none of the e-ink refresh
  settings in it (2026-08-05), which a tester would have felt as a
  slower device rather than seen as an error. The surviving seed is
  generated from a record whose fields *are* the settings, so the three
  font settings can no longer go missing one at a time. What the device
  writes is unchanged — same keys, same values, three new comment lines
  at the top of the file.
- **First CI for the channel**: three jobs on every push — no Guix, no
  device, no waveform — whose job is protecting the kernel patch stack
  (`.github/workflows/host-gates.yml`). A safety job asserts that no
  waveform or VCOM blob is tracked, that every tracked shell script
  parses, and — by parsing the YAML rather than grepping it — that no
  workflow uses a secret or the fork-privileged pull-request trigger.
  Every run also prints what green does **not** mean: nothing was built,
  nothing was booted, and the waveform parser cannot be covered at all.
- **New rung-1 gate: `make manuals-check`** — the man/info -> EPUB
  converter behind the manuals shelf, run as the file the image is
  actually built from. Python standard library, no Guix module, no
  store, no device; `mandoc` is now on the CI toolchain so the
  end-to-end pass runs there rather than only on a workstation.
- The host gates now run without Guix installed (`HOST_TOOLCHAIN=1`),
  and `guix time-machine -C channels.scm` is finally wired into the
  build targets (`TIME_MACHINE=1`), so the reproducibility claim in
  `doc/release.md` is true of the commands it names (issue #2).
  `make help` gained a Flags section; these were undiscoverable without
  reading the Makefile.
- **`make timesync-check`**, the gate behind the new clock service. It
  pulls the SNTP client's protocol and policy functions verbatim out of
  the shipped daemon and drives them with synthetic packets, then binds a
  UDP socket on loopback, launches the real daemon at it, answers one
  request with a time it chose, and requires that time back out. That
  second half is what proves the FFI struct layouts a unit test cannot
  reach — including glibc's `struct addrinfo` field order, where a wrong
  guess gives a wrong address rather than a crash. No root, no network,
  no device, and no clock is ever set.
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
