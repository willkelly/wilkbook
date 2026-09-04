# Changelog

Maintained as work lands rather than only at release time, and written
for someone holding the device rather than for someone reading the diff.

Numbers here follow the same rule as the rest of the repo: **measured**
means an instrument or a log said so, and anything that is division from
a measurement is labelled as such. Depth lives in `doc/`; these entries
are pointers, not summaries.

`v0.3.0-prealpha` (date to be set at tagging) is the current tag: the
update path (deploy without a cable) and the embrace sweep (one reader
flavor, on the direct-mode kernel — no more direct-vs-shipping split)
land together, on top of `v0.2.0-prealpha` (2026-08-27), which cut the
`reader-direct` image as the direct-mode lineage in the first place. The
`v0.1.0-prealpha` image `9a08803e…` on Linux 7.0.11 remains the last
build of the old shipping-only driver as a separate flavor; from this
tag on there is one kernel and it is the direct-mode one. Everything
under **v0.3.0-prealpha** below was proven on wkelly's device across the
sessions it cites, moved onto the device generation-by-generation by
`make deploy` rather than by a single `dd`'d image; **Unreleased** above
it is empty until the next round of work lands.

## Unreleased

## v0.3.0-prealpha — (date to be set at tagging)

**Cable-free updates, one reader flavor, and a device that puts itself
back together when an update goes wrong.** The direct-vs-shipping split
is gone — `linux-pinenote` **is** the direct-mode kernel now, on every
build — and from this tag on the device stays current without a serial
cable: `make deploy` sends only what changed, boots it as a trial, and
only keeps it if the trial passes a health check. Suspend and wake
(button, cover, KOReader's own idle timer) go through the same broker
as v0.2.0, now proven on the direct-mode kernel too, and Wi-Fi should
reconnect on its own after every sleep instead of needing a manual
toggle. Hardware evidence below is generation-by-generation on wkelly's
device (`doc/status.md`, 2026-09-02 through 2026-09-04); the
second-operator validation from v0.2.0's cycle (rpedde, 2026-08-31) has
not yet been repeated on this lineage.

### Wi-Fi comes back after sleep, on its own

- **The reader's own memory of "Wi-Fi was on" is now reasserted from its
  own record on every wake**, instead of trusting KOReader's copy of
  it — that copy was the real reason an idle sleep, or a sleep the
  device rejected outright (e.g. while paused), could leave the radio
  off until you opened the menu and flipped the toggle yourself.
- **If the Wi-Fi driver itself gives up during a resume**, the device
  now rebinds it and retries the association on its own, logging the
  attempt either way; earlier this showed up about once in ten sleeps
  and needed a full reboot to clear.
- **The kernel gives the Wi-Fi module 100 ms to settle** after its power
  rail comes up, closing a race that could otherwise show up as the
  same symptom.
- **Run overnight, unattended, 2026-09-03/04**: 65 sleep/wake cycles
  through the device's own broker-driven path, zero Wi-Fi restore
  failures, zero driver rebinds needed. The path where KOReader's own
  idle timer — rather than the power button, the cover, or the RTC
  backstop — triggers the sleep is the same fix, but only fired four
  times in that run: thinner evidence, not a different code path.

### One reader, on the direct-mode driver

- **There is one reader image now, not two.** The direct-mode display
  driver — previously shipped only in a separate "study" image while
  the original driver stayed the default — is now `linux-pinenote`
  itself, on every build.
- **What you'll notice reading on it**: page turns have no flashing;
  rotating the device still flashes and feels a little sluggish, same
  as it did in the study image; pen and touch work as before.
- **Sleep and wake go through the same broker you had in v0.2.0**,
  proven for the first time on the direct-mode kernel: power button and
  cover both suspend and wake the device cleanly (three cycles, zero
  failures, on glass 2026-09-03).
- **Glass-proven as generation 7** on wkelly's device, deployed over the
  update path (below) rather than a cable, with a follow-up cold boot
  proving the same image comes up clean without a kexec involved.
  `doc/status.md`, 2026-09-03 late afternoon.
- **Not yet re-run since the switch**: the fuller shipping-reader
  read-quality checklist and a fresh optics (camera) check — day-to-day
  reading should feel the same as v0.2.0, but it hasn't been
  re-verified item by item on this exact build.

### A failed cable-free update now recovers by itself

- **If a wireless update boots a kernel that hangs instead of coming
  up, the device brings itself back.** The SoC's own watchdog resets
  it, and the last version that was actually working boots on its
  own — no cable, no power button. Proven end to end on glass
  2026-09-03 evening: an intentionally broken trial kernel hung, and a
  few minutes later, untouched, the device was back on the last good
  version and reading again.
- **One narrower class of failure is prevented rather than recovered
  from**: a specific hard hang tied to a USB clock the outgoing kernel
  leaves off, which the update tool already avoids by default — you
  should not see it, but if a future kernel change reintroduces it,
  that one class still needs the power button.
- The very first update ever applied to a device that doesn't already
  have this self-recovery fix isn't covered by it — the safety net only
  exists once it has already been installed once.

### Suspend and wake: the platform-controls broker

Sleep is a conversation with the reader instead of a rug-pull: the
power button, closing the cover, the menu's Sleep item, and KOReader's
own AutoSuspend timer all reach one acknowledged path. KOReader
checkpoints your place, paints a real sleep screen (including custom
images), and quarantines input before the device actually suspends; if
the reader doesn't answer in ten seconds, it sleeps anyway behind a
fallback screen. Frontlight level and warmth come back exactly after a
wake and survive a restart; a device on the charger no longer
auto-sleeps by default; Wi-Fi has an on/off toggle in KOReader that
honors "restore Wi-Fi after resume"; Power Off in the menu actually
powers off. First hardware-accepted on a second operator's own device
2026-08-31, and — new this release — proven on the direct-mode kernel
too, above.

### The update path: updates without a cable

- **Your workstation can now push a new build to the device over the
  network**, without a reflash: it sends only the store paths the
  device is missing, boots the result as a trial, and only keeps it
  once a health check passes — otherwise the device stays on whatever
  was already working. Rolling back is the identical move in reverse.
- **Proven end to end**, both in an automated QEMU rig and on glass:
  the first cable-free deploy landed 2026-09-02, and every generation
  cited elsewhere in this release (7 through 12) moved onto the device
  the same way afterward.
- One dd-from-os1 reflash is still needed to put this capability on a
  device that doesn't already have it; after that, it's `make deploy
  DEVICE=…` from then on.

### Also fixed since v0.2.0

- **A malformed rectangle hint could corrupt kernel memory** in the
  direct driver's `RECT_HINTS` ioctl (the pen/UI hint path). Nothing in
  the shipped reader sends malformed rectangles today, but this closes
  the door before more hint-driven work opens it.
- **Pinch-to-font-size could crash the reader** (KOReader exited and
  respawned in about a second, losing nothing but your gesture). Fixed
  at the source: the reader no longer hands the gesture detector a
  touch it lost track of.

### Known broken — read before you file a report

- **If the direct display driver's first startup attempt is
  interrupted** (its first probe is *expected* to fail and retry a
  moment later — that part is normal), it can leak memory it acquired
  before the failure instead of freeing it. Found by an outside code
  review 2026-09-03, not yet fixed.
- **The fuller shipping-reader validation checklist and an optics
  (camera) check have not been re-run since the driver switch above** —
  reading should look and feel the same as v0.2.0; say something if it
  doesn't.
- **The os1-based rescue procedure for a badly broken update has never
  actually been run.**
- **A stuck wireless update can look hung for a while before anything
  tries to help**: the update tool's own recovery watcher doesn't start
  looking for a stuck trial until about five minutes have passed, and
  if the watchdog self-reset above doesn't fire either, the device can
  end up back on the stock rescue system (os1) rather than on your
  reader.
- **Old versions can be cleaned up automatically even if one of them is
  the last one known to work well** — there's no "never delete this
  one" pin yet.
- **The debug serial port still logs in as root with no password**, if
  someone has physical access and the right cable — same as before, now
  written down plainly rather than left implicit.
- **The self-recovery reset above is slower than its own timeout
  suggests**: it took roughly 3.5 minutes in the session that proved it,
  not the ~44 seconds the configured watchdog timeout would predict.
  Harmless, but unexplained — don't assume it failed just because a
  minute has passed.
- **Wi-Fi-after-sleep is well-tested for the normal case** (button,
  cover, the automatic backstop) but thin for the case where KOReader's
  own idle timer is what puts the device to sleep — see above.
- If you're handed a device running a "convenience" build (a build flag
  that turns the USB console into a no-login root shell for debugging),
  that's deliberate and isn't what ships by default — don't mistake it
  for a security bug, and don't leave it as your everyday device.

### How to report

Same rules as `doc/alpha-expectations.md`: a device that won't wake is
forensic evidence — note the time, don't force a power-off until asked.
Display artifacts (flashing on an ordinary turn, a two-part draw,
residue that builds up) are worth a description or a photo. And if
anything on the known-broken list above works better for you than
described, that's useful too — say so.

## v0.2.0-prealpha — 2026-08-27

**The pre-alpha moves to the direct-mode driver.** This tag cuts the
`reader-direct` image as the new pre-alpha lineage: hrdl's direct-mode
EBC driver with wilkbook's banded parallel screen updates, atomic page
turns, a decode-fidelity CLUT compiler, validated display defaults
applied at boot, a white splash instead of a console, and the same
reader stack (KOReader, pen, Wi-Fi, key-only SSH, ultra suspend
machinery) as v0.1.0. Operator-validated over a full evening and a
night of instrumented measurement (`doc/status.md` 2026-08-26/27
parts 9-24; the optics evidence in
`doc/artifacts/pinenote-optics-turnroutes-20260826/`): page turns are
snappy, the mid-turn "wave" of prior-page text is gone, accumulating
ghosting is resolved to acceptable, menus no longer flash, writing
latency is unchanged ("looks great"). Release image
`pinenote-reader-direct-PNGuixRoot-20260826.ext4` (built 2026-08-27),
SHA256 `7afd3f8a…` — full hash and deploy record in `doc/status.md`
part 24.

Known character and open work: a transient per-turn settling effect
(bold prior elements briefly shining through; wavy text coming into
focus — gone once settled); a faint full-width band summonable by
display-timing experiments (do not use long frame pacing); the
phase-sequence tool can crash the kernel (UART-attended only); the
suspend/power legs have not been re-validated on this driver.

### Display (the fidelity CLUT)

- **The waveform tables the panel plays are now byte-exact to what the
  original driver's hardware engine reads.** The boot-time compiler had
  faithfully reproduced its reference's bugs: on ~13 % of grayscale
  transitions — concentrated at the near-black/near-white levels
  antialiased text edges use — the panel played the WRONG waveform, and
  ~80 % of transitions ran time-shifted. Found by a new offline differ
  (`wbf-clut-diff`, now a standing test gate), fixed as the compiler's
  default, A/B'd live on glass the same night: operator +1.

### Direct-mode driver (was: study image)

- **Page turns compute in time now.** The direct driver's screen
  updates were arriving ~50 % slower than the panel scans whenever most
  of the screen changed — every page turn ran its waveform out of spec
  while pen strokes ran on time. The update computation now spreads
  across CPU cores and full-screen refreshes hit the panel's native
  rate (measured: 18.4 → 11.9 ms per frame, no visual difference at
  the seams, same pen feel). `doc/status.md` 2026-08-26 part 12.
- **The display defaults you'd otherwise set by hand now ship.** The
  next study image boots straight into the measured reading route
  (grayscale page turns through GL16) and the corrected temperature
  bin (the built-in sensor reads warm at the bin boundary; the wrong
  bin costs visibly more ghosting). Previously both had to be applied
  over SSH after every boot. `doc/status.md` parts 10–16.
- **No more terminal on the e-ink panel.** The boot console text used
  to burn into the ghost ledger during boot and whenever the reader
  stopped. The panel now shows a plain white page from driver bring-up
  until KOReader takes over; the terminal remains available on serial.
- **Known issue: a faint full-width band** (~1/6 of screen height,
  ~3/4 down the page) can appear after display-timing experiments and
  deepen with rapid page turns; repeated full refreshes fade it. Under
  investigation — do not run `phase-seq.lua` (its reset mode crashed
  and rebooted the device once; it is marked dangerous until a
  UART-attended session).

### Battery and suspend

- **Stopping the reader no longer silently kills auto-suspend.** The
  daemon used to be a shepherd dependent of reader-session, so a stop
  test (or any reader stop) took it down — and nothing restarted it,
  leaving the device draining at awake current while looking configured
  to sleep (found dead 18 minutes after a stop test, 2026-08-26). The
  requirement is gone; the daemon instead gates each suspend on fbcon
  ownership (`vtcon1/bind` reads `0` exactly while the reader owns the
  panel), which keeps the old protections — a boot that never reaches
  the reader stays awake and reachable, an operator's stop holds
  suspend off — and re-arms itself the moment the reader is back.
  Offline-proven in `test-autosuspend-policy.lua` (three-way policy,
  both suspend paths, the requirement stays dropped), then
  **glass-proven the same night**: the daemon outlived a reader stop,
  logged the hold-off and the re-arm, and completed two full rails-off
  suspend cycles through its own gadget quiesce — with the gadget in
  the exact bound-unattached state that aborts a manual suspend on
  7.1.8 (`doc/status.md` 2026-08-26 part 6).

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
- **Auto-suspend no longer believes an impossible clock.** It measures
  idleness as a difference of wall-clock readings, and a clock *step* —
  `date` on the console today, the new time-sync service routinely
  tomorrow — used to destroy that measurement in both directions: a
  backwards step held the device awake at full draw exactly when it had
  just been put down, and a forwards step could suspend it under your
  fingers. The daemon now re-bases instead of believing either. Tested
  on the host by extracting the guard verbatim; **no device has stepped
  its clock with this in place** — host-proven, not hardware truth.

### Setup and first boot

- **Stopping the rotation service no longer hangs the service manager.**
  The orientation bridge inherited a SIGTERM-proof signal state from
  its parent, so `herd stop` waited forever on a process that could not
  hear it — the 2026-08-25 session hit this live and had to SIGKILL.
  The bridge now restores default signal handling at startup and bounds
  its cleanup with a 15-second watchdog, so a wedged teardown ends
  instead of wedging the stop. Host-proven with a positive control
  (an unrestored copy provably survives SIGTERM) — and the real test
  passed on glass 2026-08-26: `herd stop orientation-bridge` completed
  in one second, terminated by signal 15, where the previous night's
  image wedged until SIGKILL. This changes the
  shipping reader image — the bridge script rides in it — and is the
  cycle's one deliberate change to shipping behavior outside the
  display work.
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
a panel yet; one real change to how userspace finds the display, proven
offline only. Otherwise: a long-suspected defect acquired evidence, a
name and a bound.

- **Full-screen washes now find the e-ink display instead of assuming
  it is the first graphics device.** On the direct-mode study image the
  GPU claims that first slot, so every deghosting wash was silently
  handed to the GPU as a garbage command and the panel accumulated
  ghosting unwashed — the 2026-08-25 session's root cause, fixed live
  with a bind-mount and now fixed properly: every wash path (KOReader,
  the reader-stop deep clean, the post-resume wash tool, the
  diagnostics) resolves the EBC's DRM node by driver name via sysfs.
  On the shipping image the answer is the same node as before, so
  nothing changes there. A new repo gate
  (`make ebc-card-resolution-check`) keeps index hardcodes out of every
  on-device path. Glass-proven 2026-08-26: on the wired image the EBC
  is card1 behind the GPU's card0, a wash through the resolved path
  drove the panel (45 EBC interrupts), and dmesg carried zero GPU
  faults.

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
  mode** — a clock reclock to 79.68 Hz — and then the measurement made
  it cheaper than the re-read priced it. The estimate was two
  device-tree lines and ten driver lines; **measured on glass
  2026-08-24, it is one existing module parameter** (`dclk_select=1`),
  because the CRU divider already runs the parent clock at 250 MHz.
  The clock change is measured — both directions, three transitions —
  and the per-mode payoff is arithmetic from it: GL16/GC16 596 →
  477 ms, A2 157 → 126 ms
  (`doc/artifacts/pinenote-dclk-reclock-20260824/`, issue #23).
- **Not cleared to ship, and the artifact says exactly why:** the
  failure mode is silent display corruption on the memory path a
  one-variable A/B proved starves without an error, and the only visual
  check so far is a webcam with a drift-controlled noise floor — no
  clock-attributable difference was found *above that floor*, which is
  real evidence and much weaker than the optics rig would give. Faster
  page turns arrive when that check happens, not before.
- **The replay workbench had quietly stopped modelling the device you
  hold** (issue #30). Its "shipped stack" baseline was written on
  2026-07-05, was correct that day, and was never touched again through
  two shipped policy changes — for seven weeks it modelled auto-refresh
  behaviour and a deferred-io window this image stopped shipping in
  July. Corrected; its usage banner's argued-from-a-stale-number advice
  is withdrawn rather than restated; and the first study's tables in
  `doc/refresh-policy.md` carry a correction block instead of a silent
  re-run. No number a policy decision rests on changed — those were
  ratios and A/Bs, re-checked.
- **KOReader's pen-slot collision stopped being hypothetical.** The
  router that keeps pen and finger apart assumed the touchscreen hands
  out contact slots densely; a device capture showed it does not (a
  120 s capture peaking at three simultaneous contacts used slots
  {0, 1, 2, 5}), so a lone finger can be
  assigned the very slot KOReader reserves for the pen — its swipe then
  gets the pen's coordinates written onto it. Reproduced offline as a
  one-variable A/B and **pinned as a `quirk:` test, not fixed** — the
  fix belongs upstream (issue #21). Alongside it, the device's input
  axes (slot count, pen pressure/tilt/hover ranges) are now recorded by
  the standing ground-truth capture, so issues #20 and #21 stop costing
  hardware sessions (issue #20, #21).

### The direct-mode display experiment

The week's defining thread: handwriting became a stated product
direction, and the display path that could support it (hrdl's
direct-mode driver) went from "rejected, re-evaluate later" to a sized
plan, a study image, and — on 2026-08-25 — a first session on glass.
None of this changes the image a tester flashes; the decision it feeds
is **embrace-or-reject, after which one image ships either way**
(`doc/direct-mode-adoption.md`).

- **The plan and its agenda are written before the sessions, not
  after**: `doc/direct-mode-adoption.md` (blockers, bail-out criteria,
  and the operator's one-image decision) and
  `doc/glass-plan-2026-08.md` (the D1–D9 direct-mode ladder plus the
  R1–R7 shipping-reader list, each item naming the decision it feeds,
  with reject criteria pre-registered). ROADMAP §5 now carries the
  direction itself — note-taking, drawn UIs in books, handwritten code
  — which until 2026-08-25 lived only in conversation records.
- **His driver compiles and links against our stack** — first grafted
  into a clean 7.1.8 tree (all three objects build), then the real
  integration: our `pinenote_defconfig`, our seven patches, his driver
  as a kernel package variant, full build, modules linking their
  symbols across. Along the way his 3WIN fallback config turned out to
  have **never been compilable** (a missing parenthesis wholly inside
  its `#ifdef`) — reported to the upstream register rather than
  patched, and a reminder that our own shipping driver is the real
  retreat, not a configuration of his we would first have to repair.
- **The rebase surface is measured, not feared**: 182 commits over
  mainline, but seven of twelve touched files are new and four are
  build glue; the nine kernel APIs his driver uses that ours does not
  all exist in 7.1.8, checked against the source rather than assumed.
- **First glass session, 2026-08-25** (`doc/status.md` has the full
  entry): the study image booted, KOReader ran through the direct-mode
  driver, and **D1–D4 of the ladder pass** — CLUT compiled on the
  device from its own waveform by the C compiler (by hand; see the gap
  below), the driver probed (after a rebind; see below), the panel
  lights, and page turns reach glass through the identical
  `GLOBAL_REFRESH` ioctl. The feared framebuffer-format wall does not
  exist: KOReader adapts to the driver's RGB565 fbdev on its own.
- **The ghosting root cause of the session was ours to find — and ours
  to fix**: our KOReader device shim hardcodes `/dev/dri/card0` for
  the full-refresh wash, and on the direct image card0 is the **GPU** —
  so every wash was a malformed GPU job (a dmesg fault line each time)
  and the panel was never washed at all. Redirecting it to the real
  display node live on the device fixed it; ghost-vs-wash then sat at
  the camera noise floor (measured, optics rig). The proper fix —
  resolve the display by driver name in every wash path — has since
  landed; see "Display and page turns".
- **The operator's verdict on video: quality good, but more
  flashing and redrawing per page turn than a smooth read wants.** That
  is the pre-registered two-pass expectation confirmed on glass, and it
  is now the driving item for the polish phase of the plan.
- **Stopping the reader no longer destroys your book's cache.** The
  538-document man-pages book opens in 1.7 s with its cache and 30.3 s
  without — and every service stop used to silently truncate that cache
  to zero bytes (SIGTERM skips KOReader's clean close; measured on
  glass 2026-08-26). The stop now asks nicely first: SIGINT, a
  cooperative wait for the clean close, then the old kill for a wedged
  reader. Pinned by a new gate (`make reader-stop-check`) whose review
  found the first version was dead code under real shepherd — the fixed
  form was validated in a scratch shepherd (0.65 s clean stop); the
  on-device proof rides the next deployed image.
- **The waveform toolbox learned charge balance** (`wbf-clut
  --balance-report`): per-mode net-impulse and worst round-trip
  analysis of the decoded sequences, arithmetic positive-controlled on
  constructed rows. First result: the vendor's own envelope — DU/DU4
  round-trips perfectly balanced, GL16/GC16 bounded at 48 (cold) to 4
  (warm), INIT exactly zero. That envelope is the constraint any
  hand-crafted page-turn sequence must respect, which is the point.
- **The page-turn program got its instruments, and the instruments
  killed two planned fixes** (2026-08-26): turns were already
  single-flush (the fsync publish works through the stock driver — the
  planned defio port is unnecessary) and already diff-only (the REDRAW
  ghost-clean is stripped at the shipping default). What remains of
  "dirty transitions" is the waveform transition itself plus bounded
  ghost residue. A new compiler knob (`wbf-clut --class-source`) let a
  whole waveform-class swap be tried on glass in one evening — turns on
  GC16's shorter rows — and the operator's eyes rejected it (more
  residue: wash-pattern rows under-drive partial transitions; GL16
  stays). The practical fix that DID land: the idle washer's cadence
  knobs (already settings) retuned so the ghost-clean fires in natural
  reading pauses (12 s) instead of only long ones (45 s) — device-side
  for now, seeded into the profile after the operator's felt verdict.
  Also caught: hand-launched KOReader sessions were rendering fallback
  fonts (a dropped `EXT_FONT_DIR`); the faithful launch recipe is now
  in `doc/device-access.md`.
- **Direct mode costs nothing at idle** (2026-08-26, wired image):
  reader idle measured **155.3 mA** against the shipping ledger's
  156.9 mA under identical conditions — parity. Real page turns at an
  aggressive 20/min add ~59 mA (each turn drives ~41.5 waveform frames
  under the untuned default hint — a power argument for the P4 intent
  mapping); a normal pace interpolates to +18–30 mA
  (`doc/power-management.md`).
- **Rotation works — all four orientations, on glass** (2026-08-26).
  The offline investigation found boot orientation is decided by one
  setting our own profile seeds (`closed_rotation_mode`), and flipping
  it rendered all four orientations on the direct driver,
  camera-verified, with no portrait-wedge. The decision chain is pinned
  (`make koreader-input-check`) so a KOReader upgrade that moves it
  fails loudly.
- **Ultra suspend survives the direct driver** (2026-08-26): rails-off
  entry, DDR retrain on wake, clean EBC resume, panel intact, zero
  touch-controller handshake failures. One new 7.1 finding: a bound
  but unattached USB gadget **aborts suspend entirely** (dwc3 ep0
  timeout) — workaround is unbinding first; the bug is registered, not
  papered over.
- **The one feasibility number for the userspace-TCON question is
  banked**: the driver's own instrumentation puts the per-frame
  `advance()` at 37 µs idle, ~1.9 ms banded, and **23.1 ms peak for a
  full panel** against an 11.7 ms frame budget — over budget *inside
  the kernel*, single-threaded on four cores. Measured on glass;
  residence is not the constraint, parallelism is
  (`doc/direct-mode-adoption.md` §7).
- **Rotation is unresolved, not failed** (D5): four remote mechanisms
  for rotating the reader all produced portrait boots — the
  rotation-decision chain is unmapped. The investigation is queued
  offline at rung 4v before any more glass is spent on it
  (`doc/glass-plan-2026-08.md` §3).
- **A reproducible kernel panic was captured on console**: destroy a
  uinput device while KOReader holds it open, then restart the reader —
  NULL dereference, the same pattern both times it was provoked, while
  restarts without the destruction never crashed. To the upstream
  register. Also found live: the orientation bridge ignores SIGTERM,
  which wedges service stop — that one is our own bug, and its fix is
  under "Setup and first boot".
- **Two wiring gaps stand between the session and a hands-off boot,
  and both are known tag-blockers**: the flavor never instantiates the
  CLUT one-shot or the direct-mode modprobe options (D1 was compiled by
  hand), and the initrd raw-loads the display module before the root
  filesystem — and thus the CLUT — exists, so the first probe fails on
  every boot and a rebind must follow. Found independently by the
  release review and by the session. Both fixes have since landed in
  the tree — the flavor wiring under "Build, CI and gates", the
  wash-path resolution under "Display and page turns" — and the image
  carrying both **booted hands-off on 2026-08-26**: CLUT compiled at
  boot, rebind at 10.1 s, KOReader up via shepherd with no crash-loop,
  washes on the resolved card, reader-idle power at parity with
  shipping (155.3 vs 156.9 mA, `doc/status.md`).

### Kernel

- **A hung device can now be rescued over the debug cable** (kernels
  built after 2026-08-26). The inherited defconfig shipped serial sysrq
  off, which was discovered the expensive way: a wedged shutdown left
  the kernel echoing keystrokes with userspace dead, and the only way
  out was a finger on the power button — with the UART cable plugged in
  the whole time. Serial BREAK sysrq is now enabled but ships
  **masked off**, with a break-then-`sysrq` arming sequence, so a
  floating RX line's noise cannot fake a reboot (the presumed reason it
  was off; a live test proved the sequence is an arming toggle, not a
  per-use guard, which is why the mask matters). The whole chain is
  glass-proven: arm with BREAK+`sysrq`, fire with BREAK+key. Recipe and
  the semantics trap in `doc/kernel-forward-port.md`; the hang itself
  in `doc/status.md` (2026-08-26 part 4).
- **The kernel this repo built used to be chosen by when you last ran
  `guix pull`.** The base was a floating nonguix alias; it moved to 7.1
  on its own and `make kernel` stopped working. The base is now an
  explicit series pin, and `make kernel-version-check` detects drift in
  ~0.6 s with no build (issue #13).
- **The tree now targets the 7.1 series and the reader image builds
  again.** Two device-tree hunks were deleted because mainline absorbed
  them verbatim, shrinking the forward-port patch from 31 hunks to 29 —
  the good direction for a forward port. When this entry landed nothing
  on 7.1 had run on glass; since 2026-08-25 a 7.1.8 build **has** — but
  only the direct-mode *study* configuration (hrdl's display driver
  swapped in), never the shipping driver. The hardware-proven kernel
  for the image you flash remains 7.0.11, which is what the deployed
  reader runs (`doc/kernel-forward-port.md`).
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

- **Reproducible builds work again on `main`** (2026-08-26). The
  channel pin now carries the generation that resolves the 7.1 kernel,
  ending the window opened 2026-08-25 when the kernel series moved
  without it. The acceptance gate was equality, not just success:
  `TIME_MACHINE=1` resolves the byte-identical kernel derivation the
  ambient build does. Procedure now recorded in `doc/building.md`: a
  kernel-series bump and the pin bump travel in the same change.
  (Urgency footnote: upstream nonguix has since *deleted* `linux-7.0`
  — the 7.0.11 track now builds only through the old pin at the
  `v0.1.0-prealpha` tag.)

- **The study flavor below now actually contains its boot-time table
  step — and rebinds the display driver to use it.** The first on-glass
  run of the direct-mode image (2026-08-25, `doc/status.md`) found the
  flavor had never been wired to the table-compiling one-shot two
  entries down: the operator had to compile the table and re-trigger the
  driver by hand. Both halves are wired now: `reader-direct` runs the
  one-shot at boot, and the one-shot ends by re-probing the driver
  through sysfs — because on this boot path the driver always loads,
  and fails, before the table can exist, *every* boot. A re-probe that
  fails now fails the service loudly instead of leaving a blank panel
  with a green boot log. Proven offline (`make ebc-clut-check`, against
  a fake sysfs) and pinned so the wiring cannot silently vanish again;
  when this entry landed the image built from this wiring had not yet
  booted — the 08-25 session proved the sequence by hand; on 2026-08-26
  the wired image ran it hands-off, rebind at 10.1 s, reader up with no
  crash-loop. The shipping reader's
  system derivation is unchanged, re-checked at the same store path.
- **There is a second reader flavor now, and it is not for you to
  flash.** `make reader-direct` builds the reader image on the faster
  display driver we are evaluating for handwriting
  (`doc/direct-mode-adoption.md`). It is a study artifact, and when this
  entry first landed nothing in it had ever run. **That changed on
  2026-08-25**: it was deployed to the author's os2 and drove the panel
  through a full session — see "The direct-mode display experiment"
  above. It still does *not* reach a working reader hands-off: the
  session's two wiring gaps are fixed in the tree (the entry above,
  and the wash-path resolution under "Display and page turns"), but no
  image containing those fixes has booted. The image you are actually
  running was unaffected by the flavor itself — checked rather than
  asserted: adding the flavor left the shipping reader's system
  derivation at the same store path, and its build closure contains
  none of the new driver. `doc/pinenote-flavors.md` has the row.
- **New rung-1 gate: `make clut-check`, and the tool behind it.** The
  faster display path we are evaluating for handwriting
  (`doc/direct-mode-adoption.md`) will not even *start* without a table
  compiled from your device's own waveform, and the only existing
  compiler is a Python script needing numpy and pandas — neither of
  which the reader image has, or should. `wbf-clut` is a C replacement
  that produces a **byte-identical** file. That comparison needs both a
  device waveform and hrdl's Python to hand, so it runs on a developer's
  machine and **not in CI** — where the gate checks structure only and
  says so rather than printing an unqualified pass. Finding it took
  reproducing two bugs in the
  original on purpose (`doc/driver-findings-report.md`) — a "cleaner"
  compiler would have quietly changed the waveform your screen is
  driven with. Since 2026-08-25 the compiler has run **on the device**,
  in the study image, and the panel has been driven from its output —
  invoked by hand on that session's image, which predated the wiring;
  the study flavor now runs it at boot (two entries up), and on
  2026-08-26 the wired image did exactly that hands-off — compile,
  rebind, reader — with no hands on the device.
- **A follow-up fixed the compiler's safety gate, which had shipped
  inoperative** — and the fixes had been *described as merged* while
  sitting uncommitted in a working tree (a `git commit --amend` with
  nothing staged succeeds silently; the record is corrected rather than
  quietly re-landed). The gate that keeps per-device waveform data out
  of the repo asked `file(1)` to recognize the format, but libmagic
  does not know it and reports plain "data" — so a genuine compiled
  table under an innocuous name was committable the whole time. It now
  reads the bytes itself, and the test summary now says which of its
  two honesty levels actually ran instead of printing one unqualified
  "ALL TESTS PASSED".
- **New rung-1 gate: `make ebc-clut-check`**, and the boot-time step it
  covers. The table above has to reach the driver, and on this device
  that means compiling it **from your own device's waveform, on the
  device, at boot** — it is calibration data and is never shipped with
  the image. The one-shot that does it now exists and is driven through
  every branch offline, including the one that matters most: it
  **rebuilds the table whenever your waveform changes**, rather than the
  upstream shape of "build it once and never look again", which would
  have left a wrong table in place silently. If it cannot build the
  table it says so loudly and fails, because the alternative on this
  driver is a device that boots to a blank screen with no explanation.
  When this entry first landed the one-shot was wired into no image —
  the study image shipped without it, which is why the 2026-08-25
  session compiled the table by hand. **The study flavor now runs it at
  boot** (the top entry of this section), together with the rebind
  below. Along the way the plan's claim that our boot needed no
  initramfs work turned out to be **wrong** — the display module is
  loaded from the initrd, before any of this can run, so the first
  probe fails on *every* boot — which was written down as its own
  blocker (`doc/direct-mode-adoption.md` D7) and is now resolved by
  the one-shot's closing re-probe.
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
- **New rung-1 gate: `make settings-check`** — this project declares the
  same knob in up to five places (a Guix record, a daemon's own
  defaults, a `.conf` key, an argv flag, a modprobe string) and nothing
  connected the copies; issue #12 counted 63 operator-reachable knobs.
  The gate compares every declared coupling, and what it found on day
  one was not the drift everyone expected: the record/daemon default
  pairs agreed in 14 of 15 cases, while the real divergences included
  two `.conf` parsers in the same directory reading the same key name
  `enabled` with **opposite grammars and opposite defaults**, and a
  host tool modelling a device we stopped shipping in July. Today's
  divergences are recorded in a **debt register that can only shrink**:
  new drift fails the gate, and so does a register row whose divergence
  has been paid off — both properties positive-controlled by mutation,
  since a text gate without positive controls is how this repo grew
  vacuous checks before. A review fix made the register pin the exact
  divergence rather than merely the site, so new drift at a
  known-divergent site cannot hide as old inventory (issue #12 step 1).
  Nothing here changes the device; the gate proves declarations agree,
  not that the device behaves — and the same evening three of its debt rows
  retired themselves when the issue-#30 fix landed, which is the
  can-only-shrink property working in anger.
- **The artifact root is `/tmp/wilkbook` now, not `/tmp/opencode`** —
  the old name came from a previous coding tool, and it was not
  decorative: it is the write-containment boundary eight preflight and
  qemu scripts refuse to write outside of. The checks and the writes
  moved in one commit, because a docs-only rename would have left the
  containment checks guarding a directory nothing writes to any more
  (issue #3).
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
  build targets (`TIME_MACHINE=1`), which made the reproducibility
  claim in `doc/release.md` true of the commands it names when it
  landed (issue #2). **It is not true today**: the kernel then moved to
  the 7.1 series pin while `channels.scm` still pins a nonguix commit
  that predates it, so `TIME_MACHINE=1` currently fails outright
  (verified 2026-08-25 — the ambient build is the working one, exactly
  inverted from mid-August). The byte-identical-rebuild claim holds for
  the `v0.1.0-prealpha` tag with its pin, not for current `main`; the
  repair is a pin bump, which is its own reviewed change, and
  `doc/building.md`, `doc/release.md` and the Makefile all now say so
  rather than telling the pre-inversion story.
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
- **New: `doc/configuration.md`** — the settled direction for every knob
  on the device, written down so it stops living in one conversation
  thread. The parts a future tester will feel: the idle timeout belongs
  to the person holding the device, not to us; an override stores only
  what you explicitly set (absent means "give me the new default",
  present means "I chose this" and survives); when a valid value stops
  being valid we migrate it rather than dropping it, and a question
  that needs a human is queued rather than asked at boot, because at
  boot nobody is there; and **settings survive a reflash, KOReader's
  included** — losing "show clock in footer" while font size survives
  is a bug, because that boundary is invisible from the reading chair.
  Direction, not implementation: almost none of it is built.

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
