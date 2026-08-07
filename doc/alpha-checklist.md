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

---

## Blockers

### 1. ~~DMC default~~ — DONE 2026-08-07 (`28fda00`)

The selector defaulted to `normal` (324 MHz) on every non-opt-in path
despite a commit claiming otherwise; a fresh install would have corrupted
its display on every boot, silently. Fixed, with a preflight gate that
negative-tests against the broken version. *Kept here because it is the
model failure for this project: no runtime signal exists, so only a human
looking at the glass would ever have caught it.*

### 2. Hardware session A — deploy a ship candidate and accept it

One supervised sitting, in this order. Discharges five open items at once
and uses the scarce resource (charged device + cable + human) at maximum
yield.

- [ ] **Settle what is actually on os2 first.** The repo says image
      `50e7fe1d`, written by a commit that *precedes* the RTC-rewake fix;
      the working assumption is that the ultra-arm image (which carries
      it) was written later. One log read decides it: `awake 20s` versus
      `awake 300s` in `/var/log/pinenote-autosuspend.log`. This is a
      3-day-battery difference — do not overwrite it before reading it.
- [ ] **Deploy the ship candidate** (dd + readback SHA, os1-side,
      `doc/hardware-deploy.md`). Not free: cable connected and logging
      before boot, one USB-C port so no charger for the run.
- [ ] **Confirm the boot-slot claim.** The repo says an unattended reboot
      "always" lands on os1; the evidence is *one* observation. One
      deliberate power cycle with the UART capturing the menu.
- [ ] **Reader acceptance on the exact artifact being shipped.** No
      reader validation exists on any image since 2026-08-01. Real book,
      not the quickstart; finger taps, not uinput; all four edges; file
      browser on a real `/data/books`. Judge with
      `pinenote/tools/optics/belief-vs-glass.sh`, never by eye — that
      rule exists because eye-judging produced two wrong calls in one
      session.
- [ ] **The awake power-tap test**, which has never been recorded and is
      still listed as "fix deployed, unproven". Press-to-suspend is the
      alpha user's primary power gesture and its failure mode was silent
      panel corruption that GL16 washes cannot heal.
- [ ] **A clean suspend/resume on the shipping stack** — an alpha user
      exercises this every five idle minutes.

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

### 5. Fresh-clone first boot must survive

- [ ] `/data/books` is created by activation, not by hand. It exists on
      the one device because someone made it; the seeded profile
      hardcodes it as `home_dir`.
- [ ] The build works without the gitignored licensed fonts.
- [ ] `make qemu-virt-check` against a genuinely fresh clone.

### 6. Public-repo posture

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
