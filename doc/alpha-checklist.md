# Alpha checklist

Scope decided 2026-08-07. Alpha is the **reader flavor on os2** doing one
job well: read books already on `/data/books`, with finger and pen, four
orientations, frontlight, single-pass page turns, Wi-Fi for `scp`,
key-only SSH, and press-to-suspend / power-button resume. Plus **every
landed large power lever on and correct in code**, and **the ultra
question answered on hardware** — answered, not necessarily landed.

**Audience: two people with PineNotes** — the author and one friend, both
able to build from source and drive a UART. The repo goes public at the
same time, but for *reading and stealing*, not for installing: no
general-audience install path, no update mechanism, no support promise.
The disclaimer carries that.

**Missing a target is acceptable** and gets the pre-1.0 optimization
pass. Publishing a number we never measured is not. Alpha ships measured
numbers or no numbers.

**Alpha is cut by a person, not by a green test run.**
`doc/alpha-signoff.md` carries the human QC cycle, the quality bar
("a cold, not covid"), the list of things the machine already proves so
they are not re-checked by hand, the known colds we ship deliberately,
and the sign-off record to fill in.

---

## Blockers

### 1. ~~DMC default~~ — DONE 2026-08-07 (`28fda00`)

The selector defaulted to `normal` (324 MHz) on every non-opt-in path
despite a commit claiming otherwise; a fresh install would have corrupted
its display on every boot, silently. Fixed, with a preflight gate that
negative-tests against the broken version. *Kept here because it is the
model failure for this project: no runtime signal exists, so only a human
looking at the glass would ever have caught it.*

### 2. ~~Hardware session A~~ — DONE 2026-08-07

Ship candidate `7eaab343…` deployed (dd + readback SHA) and accepted on
glass, **5/5**, judged by the operator's eye on the exact artifact
intended to ship: clean panel out of boot; press-to-suspend with banner
and clean second-press resume; no residue over 10 page turns both ways;
all four autorotations; no double draws or flashing. Machine account
agreed — `mode=off` read from p7, `clk_scmi_ddr` 1056000000,
`wilkbook_dmc` unloaded, `suspend_stats` 2/0, and the secure build
verified *on the device* (no ACM console service, zero `NOPASSWD`).

Two of those had never been recorded on any image: the clean boot, and
**the awake power-tap test**, which had sat at "fix deployed, unproven"
since the corruption it caused.

Found in the same session and fixed: the suspend banner sizes against
`FB_W` (1872, the long axis) while the device is read in either
orientation, so scale 6 overflowed the 1404 px short axis by ~3
characters. The operator had normalised it as cosmetic for weeks.

**The boot-slot question is also settled, and it was the #1 blocker in
two of the four alpha assessments.** The tree looked contradictory: two
records of os2 coming up "with no console intervention" (2026-07-05,
2026-07-26) against one of os1 (2026-08-06). All four records reconcile
once you separate *attended* from *unattended*: the U-Boot menu is
interactable **on the device**, so a human present can always pick os2
without a serial console; with nobody present the countdown elapses and
the default ("search all partitions") finds p5 first, because os1 carries
`/boot/extlinux/extlinux.conf`. Tonight's ultra recovery boot captured
the countdown running 15→0 untouched, then landing on os1.

So: **not an alpha blocker** — an installer is a human at their device.
It *is* the blocker for anything that must come back up on os2 by itself,
which is why hibernation is gated on it (`doc/power-management.md`).
`doc/install.md` and `doc/device-access.md` both claimed booting os2
without a UART was impossible; corrected 2026-08-07.

### 3. ~~Hardware session B — the ultra handshake~~ — DONE 2026-08-07

Run, and answered. The firmware **does** honour `LINUX_PM_STATE=5`
(`ultra:` incremented 0→1, the first time ever) — and nothing wakes the
device from it: not the RTC at +60 s, not a short power-button press.
Only a forced power-off exits. Both pmic words were identical to the
control, so this was a pure handshake with the proven `mem` rails and no
DT change. **Ultra is closed for this bl31**; `deep` at ~20 mA is the
shipping suspend, and the deferred rail payload below is now moot rather
than merely deferred. Record:
`doc/artifacts/pinenote-ultra-handshake-20260807/RESULT.md`.

### 4. One end-to-end standby measurement

- [ ] Overnight, unattended, unplugged, no reboot: `charge_now` bracket
      over ≥6 h. **No standby figure in this repo has ever been
      measured** — every multi-day number is arithmetic on ≤900 s
      windows. The precedent is exact: the 2026-08-03 soak *measured* the
      duty-cycle bug, was written up as an argument for the setting that
      made it worse, and the model said 8.6 days while reality was 3.0.

### 5. ~~Fresh-clone first boot~~ — DONE 2026-08-07

Investigated properly (8-agent design + 3 adversarial lenses). What was
written here as "one mkdir in activation" is four defects, three of them
invisible to every gate we have:

- [x] **`/data/books` is created by nothing.** DONE — `pinenote/services/library.scm`, a shepherd one-shot requiring `file-system-/data`. It exists on the one
      device because a human made it. **It must be created by a shepherd
      one-shot requiring `file-system-/data`, not by activation** —
      verified 2026-08-07: the boot script mentions `/data` zero times
      and only runs `activate`; the mount is a shepherd service that
      starts *after* activation. A `mkdir -p` in activation lands on the
      os2 root filesystem, underneath the mount, invisible forever. Same
      class as the DMC regression (`dmc.scm:69-77` has the pattern).
- [x] **A `home_dir` that does not resolve does not fall back.** DONE — the directory now always exists, and a shadowed activation fallback on the os2 rootfs covers the never-mounted case with a readable explanation instead of a store path.
      `realpath` returns nil, `root_path` drops through to
      `lfs.currentdir()` — the read-only Guix store. A fresh device's
      first view of "your library" is `/gnu/store/…/lib/koreader`
      listing `luajit` and `reader.lua`. This closes the open question
      at `doc/install.md`.
- [x] **On a true first session the seeded `home_dir` is bypassed
      entirely.** DONE — `quickstart_shown_version` seeded at the verified 2021070000 threshold. KOReader forces the quickstart guide, and every route
      out of it passes the open document's path, so the browser opens in
      the quickstart's directory. Proven by grepping all 14
      `showFileManager` call sites; PineNote maps no Back key, so there
      is no fourth route. Fixing this needs `quickstart_shown_version`
      seeded, not a `home_dir` change.
- [x] **Any shell one-shot must `export PATH` as its first line.** DONE, and gated.
      Shepherd start-lambdas inherit PID 1's environment, which on this
      device is `PATH=/gnu/store/…-e2fsck-static/sbin` — one binary. A
      script using `stat`/`mkdir`/`ln` silently takes its failure branch
      and exits 0, while every gate stays green because the developer's
      workstation has a full PATH. `wifi.scm:26` records this lesson
      already; `ssh-keys.scm:75` has the incantation.
- [x] **The build works without the gitignored licensed fonts.** DONE —
      and it was two defects, not one. The seed is now built host-side so
      the font block can be conditional on `pinenote-local-fonts`; and
      because *this* seed wins over `reader-session`'s, it now carries the
      FULL block (`monospace_font` and `cre_font_family_fonts` were being
      silently dropped from every fonts-present image we ever built).
- [x] **`make qemu-virt-check` against a genuinely fresh clone.** DONE,
      and used as a release gate for the first time in the project's
      history. A clone of `ultra-handshake-arm` with no
      `pinenote/fonts/local` cross-built to
      `3b35f8df730476070722dfe3fbd00b6b7718fa9a29d8d79f24ebeff52c9ee5e7`
      — the fonts-absent build that "has never been booted anywhere" —
      and every assertion passed in 68 s: all 10 boot milestones, all 9
      service milestones including **`reader-session started`**, all 6
      forbidden regressions absent, clean poweroff.

      That `reader-session started` line is the one that mattered: it now
      *requires* `pinenote-library`, so an unsatisfiable
      `file-system-/data` on a machine with no data partition would have
      deadlocked the reader. It did not.

      Verified in the built system rather than assumed: `pinenote-library`
      is in the booted `shepherd.conf`, and the shadowed fallback is in
      the activation snippets. (Both looked absent at first — an artifact
      of grepping a closure whose entries are symlinks, and then of
      grepping `activate.scm`, which is a 2 KB stub containing none of the
      snippets it references. The known-good koreader seed was the control
      that caught it.)

`make library-check` is structural and negative-tested against nine ways
it must be able to fail. Both font branches evaluate under
`guix system build --dry-run --target=aarch64-linux-gnu`: fonts-present in
the working tree, fonts-absent in the clone.

**What this still does not prove.** QEMU-virt has no e-ink panel, so
nothing here says what the first boot LOOKS like; and the case that
motivated the whole change — a p7 carrying a real stock-Debian home, where
the "Debian home" pointer should appear and resolve — is untested, because
the QEMU disk has no such partition. Those need a device.

**Premise correction worth keeping:** `/data/books` is not a wilkbook
invention. p7's root *is* os1's `/home`, so `/data/books` already **is**
`/home/books`, and os1's own KOReader has been reading from it — its
profile carries `["lastfile"] = "/home/books/The Chronicles of Prydain…"`.
Progress does not flow symmetrically, though: os2 writes root-owned
`.sdr` sidecars that os1's uid-1000 user cannot rewrite, so os1 silently
forks into its private `docsettings` tree.

### 6. Release mechanics — SCAFFOLDED 2026-08-07

The machinery now exists; the acts themselves wait for sign-off.

- [x] **`channels.scm` committed** — Guix plus every extra channel pinned
      by commit with introductions. This is the reproducibility claim:
      `guix time-machine -C channels.scm` rebuilds the identical closure.
      Regenerate with `make channels-pin` *before* building the shipping
      artifact.
- [x] **`make release-manifest ROOTFS=…`** writes `SHA256SUMS` carrying
      the hash, the git description and the channel pointer, so the hash
      lands inside signed history rather than beside a download.
- [x] **`doc/release.md`** — the procedure, and what we deliberately do
      not do (no hosted binary, no update path, no detached signatures
      until there is a binary to sign).
- [ ] The annotated tag itself, naming the image hash. **After** QC.
- [ ] Merge the shippable half of `ultra-handshake-arm` to main.

Calibration, from surveying hrdl's `pinenote-dist` on 2026-08-07: they
have zero tags across 66 commits and 14 months, a mutable artifact URL,
no published SHA-256, and no `gpg --verify` anywhere. The bar is low; one
tag, one channel pin and one hash clears it.

### 7. Public-repo posture

- [ ] The disclaimer, stated plainly and early: hardly tested, largely
      AI-written, will probably break your device, no support.
- [ ] **Root posture stated, not discovered.** With the convenience flag
      on, any USB-C cable is an unauthenticated root shell
      (`usb-gadget.scm` execs a shell with no login prompt; `reader` has
      `NOPASSWD: ALL`). That is fine for two people who know — and only
      if they are told, in the README, not in a commit message.
      `/etc/wilkbook-build` names the build either way.
- [ ] Merge the shippable half of `ultra-handshake-arm` to main.
- [ ] A "what to steal" entry point: this repo's genuine value to other
      PineNote people is the host tools and the findings, not the image.
      Point at them from the README.

---

### 8. Numbers the repo repeats that are not derived

Cheap, offline, and they are the numbers a public repo gets judged on.

- [ ] **The "9 mA pessimistic end"** in the targets table has no
      derivation anywhere in the tree, and `68dfbba` attributes it to
      hrdl, who never wrote it. Derive it or drop it.
- [ ] **"4x the longest dwell"** for the 3600 s backstop, in
      `doc/status.md` and `doc/power-management.md`: it is **1.33x**. The
      4x is against the retired 900 s default.
- [ ] **`doc/status.md`'s "38-frame cold, 46 warm"** is backwards per
      `doc/refresh-policy.md`.
- [ ] The felt-latency model **double-counts `delay_b`**, which is
      already inside the measured 132-140 ms pipeline floor.

### 9. Reader-quality fixes found 2026-08-07 (mining hrdl's dist)

Both were verified in our own tree before being believed, and both are
fixed in `pinenote/tools/power/autosuspend.lua` — but **neither has been
seen on glass**, so both belong in the QC cycle.

- [x] **The cover no longer delays suspend.** It was counted as activity
      (the daemon's header said "buttons and the cover all count"), so the
      gesture meaning "I am putting this away" re-armed the idle timer and
      held the device awake a further period at ~157 mA. Now a suspend
      request; cover-open remains activity.
- [x] **The frontlight is saved, zeroed and restored across suspend.** It
      was never touched: designed, modelled, never shipped. Mainline
      `lm3630a_bl.c` has no `dev_pm_ops`, so after the rail drops the panel
      can return dark while sysfs reports the old value —
      `doc/hardware-deploy.md:184` already told the operator to re-set it
      by hand "or the box is pitch black", which *is* this bug.
- [ ] **Verify both on glass** — QC §2.2 (cycle with the light ON and
      check `actual_brightness` after) and §2.3 (close the cover, confirm
      it sleeps promptly; open it, confirm it wakes).
- [ ] **The cover as a WAKE source has never been exercised.** Our own
      suspend gate declares exactly two armed DT wake paths and the cover
      switch is one of them; every test we have ever run used the other
      (the PMIC leg). Free to try, and it matters to the ultra question.

## Explicitly deferred to the pre-1.0 optimization pass

On the record as decisions, not oversights.

- **The ultra rail payload** — now **moot, not deferred**. The 2026-08-07
  handshake showed the device cannot wake from ultra even with the proven
  `mem` rails untouched, so the payload could only make the unwakeable
  state cheaper. Reopening it needs a firmware/wake fix first.
- **DDR at 528/780 MHz.** Never measured. Worth 4–10% of awake runtime,
  zero standby benefit.
- **Wi-Fi off by default** (10.3 mA, and that was `wlan0 down`, not radio
  off). Target 1 is met without it.
- **USB gadget off by default** (2.0 mA — at the instrument's own
  resolution, worth 0.35 h of reading) and it costs the ACM console.
- **Suspend between page turns.** Modelled at 44.7 or 32.0 mA against
  156.9 mA awake — by a wide margin the largest modelled awake lever in
  the repo, and entirely assumption-based today.
- **Conditional resume wash.** A device in a bag currently washes its
  glass once per backstop cycle for nobody.
- **The ~120 mA of unattributed awake floor** (CPLL/NPLL/VI/VO domain
  candidates). The largest genuine unknown, and the only place a
  step-change in reading runtime is still hiding.
- **The `herd restart reader-session` panel wreck.** A real,
  uninvestigated, DDR-independent defect — but only on a maintenance
  path an alpha user has no reason to take.
- **The frontlight power measurement.** It saves nothing, so it cannot
  block shipping — but it is an absolute blocker on *publishing any
  hours figure*, since 156.9 mA was measured at frontlight zero.

---

## The numbers alpha may state

Measured, and labelled as such:

- awake reader idle **156.9 mA**, at frontlight zero
- deep suspend **~20 mA**
- whatever the one standby observation says

Everything else — 25.5 h, 7.4 days, 18 days, the ultra bracket — is
arithmetic or a third party's unreplicated figure. Goals, not claims.
