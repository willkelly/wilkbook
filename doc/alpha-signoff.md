# Alpha sign-off — the human QC cycle

Alpha is not cut by a green test run. It is cut by a person putting their
name on this page after using the thing.

**The bar, as set by the project's maintainer when alpha was scoped
(2026-08-07):** *we want to let people use this, but
we want it to be of reasonable quality with appropriate steps taken to
ensure we are not unleashing a horrible plague upon the world and at most
are introducing minor annoyances — like the cold, but not covid.*

That phrasing is the actual specification, so it is worth making precise:

- **Covid** = anything that costs someone their device, their books, or
  their rescue path. Bricking, an unwakeable suspend, a corrupted p7, an
  os1 that no longer boots, a silent display defect nobody can diagnose.
  **Zero tolerance.** If one is found, alpha does not ship.
- **A cold** = it looks wrong, it needs a second tap, it wants a doc, it
  loses a setting on reflash. **Acceptable, if written down** in "Known
  colds" below. An annoyance the user was warned about is a cold; the
  same annoyance undocumented is how a cold gets reported as covid.

---

## 0. What must be true before QC starts

- [ ] A **fresh image built from the tag being signed off**, not from a
      working tree. The deployed 2026-08-07 image predates the library
      service, the quickstart fix, the conditional fonts, and the banner
      geometry fix, so it cannot be the alpha artifact. Since 2026-09-02
      the artifact may be a generation deployed from the tag instead of
      a dd'd image (`doc/release.md`).
- [ ] `make check-host` green, `make qemu-virt-check` green, and
      `make qemu-data-check` green on **all three** fixtures
      (`os1-used`, `with-library`, `empty` — `doc/testing.md` rung 4d).
- [ ] Both slots backed up and SHA-verified per `doc/device-runbook.md`.
- [ ] os1 boots and is reachable. It is the rescue path; if it is sick,
      stop.
- [x] The one end-to-end standby measurement exists (alpha checklist
      blocker 4). Alpha may ship a disappointing number. It may not ship
      an unmeasured one. **Done 2026-08-15**: 6.17 days unplugged,
      5.47 mA idle standby and 10.07 mA as actually read, 170 suspend
      cycles / 0 failures (`doc/artifacts/pinenote-ultra-soak-20260815/`).
      The number alpha states is **both** of those, never just the first.

## 1. Do not re-check these by hand

The machine already proves them, and hand-checking them wastes the scarce
resource. Listed so the human knows what is *not* their job:

| Already proven | Where |
|---|---|
| Boots, PREEMPT_RT, initrd waveform install, EBC modules, root mount, shepherd, udev | rung 4, `make qemu-virt-check` |
| ~~`refresh_waveform` is genuinely GL16 at runtime~~ — retired with the direct driver, which has no such parameter (2026-09-03) | was rung 4 |
| Library created on a lived-in os1 disk; pointer relative and resolving; os1's home untouched | rung 4d, `FIXTURE=os1-used` |
| An existing library is left strictly alone across a redeploy | rung 4d, `FIXTURE=with-library` |
| No dangling pointer on a p7 with no Debian home | rung 4d, `FIXTURE=empty` |
| Seeded profile points at the library and suppresses the quickstart | rung 4d, all fixtures |
| Fonts-absent build boots and runs the reader | rung 4 on a fresh clone |
| DMC default is `off` on every non-opt-in path | `make library-check`, `validate-dmc-default-off.sh` |
| Secure build carries no ACM console and no `NOPASSWD` | verified on-device 2026-08-07 |

## 2. The human QC cycle

Run in order on the alpha image, on a device whose p7 already has a stock
Debian home. Record the verdict for each. **Stop at the first covid.**

### 2.1 First contact — the thing a second person sees
- [ ] Power on. The reader comes up **without a boot menu keypress** if
      os2 was selected, or after one deliberate selection. Note which.
- [ ] The file browser opens on **the library**, not the quickstart guide
      and not a store path.
- [ ] A folder named **`Debian home`** is present. Open it. Their actual
      Debian files are there.
- [ ] Nothing on this screen requires a doc to understand.

### 2.2 Reading — the product
- [ ] Open a **real book** (not the quickstart), 100+ pages.
- [ ] 20 page turns forward, 20 back. **No residue, no double draws, no
      flashing.** Single-pass turns.
- [ ] All four orientations, with a page turn in each.
- [ ] Frontlight: on, adjustable, off.
- [ ] Close and reopen the book: **it resumes where you were.**

### 2.3 Sleep — the primary gesture
- [ ] Short power press: page plus **suspend banner**. Read the banner —
      it must be **complete, not truncated** (fixed 2026-08-07; since
      2026-08-31 the broker has KOReader paint its own sleep screen
      instead of the daemon's banner).
- [ ] Second press: wakes, panel intact, no corruption.
- [ ] Leave it idle past the auto-suspend threshold, then wake. Same.
- [ ] **Leave it asleep overnight** — several RTC backstop cycles — then
      wake it with one short press. Panel intact, no corruption, and it
      must **not** need a long-press. The 2026-08-15 soak ran 170 such
      cycles with zero failures, but unattended and judged by a log; this
      is the same event judged by a human eye the next morning, which is
      the case a second person actually meets.
- [ ] Frontlight is off while asleep.

### 2.4 Getting books on
- [ ] Wi-Fi associates from the out-of-band credentials.
- [ ] `scp` a book into the library from another machine.
- [ ] It appears in the browser and opens.

### 2.5 The rescue path — the covid check
- [ ] Reboot and select **os1**. It boots normally.
- [ ] os1's home is intact: their files, their KOReader, unchanged.
- [ ] Reboot back to os2. Library and reading position survive.

### 2.6 Redeploy idempotence
- [ ] Write the same image again per `doc/hardware-deploy.md`.
- [ ] Boot. **The library still holds their books, with no new pointer or
      stray files**, and reading positions survive (`.sdr` sidecars live
      beside the books on p7).
- [ ] Accept that seeded settings reset — `/root` does not survive a
      reflash. This is a cold, and it is listed below.

## 3. Known colds (ship with these, documented)

If the friend meets one of these, it is expected. If they meet something
not on this list that costs them anything, it is a defect.

- **Settings reset on reflash.** KOReader's profile lives in `/root`,
  which no reflash survives. Books and per-book reading positions are on
  p7 and do survive. Fix deferred (moving `KO_HOME` to p7 has a
  hard-failure mode when p7 is absent).
- **Reading history does not cross the two OS slots.** Positions do,
  because `.sdr` sidecars sit beside the book. History and statistics do
  not. Worse, os2 writes root-owned sidecars that os1's user cannot
  rewrite, so os1 quietly keeps its own copy.
- **Unattended reboots land on os1.** The menu is interactable on the
  device, so this costs one deliberate selection, not a cable.
- **Suspend is ultra (rails-off), and only the power button, the RTC,
  the charger, and the cover can wake it.** The pen cannot. (Cover wake
  was confirmed 2026-08-09; its sensor turns out to be battery-powered,
  2026-08-24, and only the PMU's edge latch is still unexplained — see
  `doc/power-management.md`; the tradeoff below is otherwise
  5.47 mA idle standby vs deep's ~20 mA, measured over six unplugged
  days with 170 wakes and no failures,
  `doc/artifacts/pinenote-ultra-soak-20260815/`). One cold
  touch-controller timeout on resume is absorbed by a carried
  workaround; the panel must come back clean.
- **No on-device Wi-Fi picker.** Credentials are staged out of band.
- **The first install is a reflash; updates are not.** Since 2026-09-02
  a new version reaches an installed device by `make deploy`
  (`doc/update-path.md`); a failed update with no debug cable attached
  ends on os1 until a human picks os2 at the menu.
- **`herd restart reader-session` lands in the library, not the book**
  (2026-09-04; on the old driver it wrecked the panel). A maintenance
  path an alpha user has no reason to take; a reboot is clean.
- **The typography differs** from the validated images unless you stage
  the licensed fonts yourself; the build falls back to Noto.

## 4. Sign-off record

Copy this block, fill it in, commit it, and note it in `doc/status.md`.

```
Alpha sign-off
  tag/commit      :
  image SHA-256   :
  device / operator:
  date            :
  p7 had a stock Debian home before QC?  yes / no
  section 2.1 first contact   : pass / fail / n-a   notes:
  section 2.2 reading         : pass / fail / n-a   notes:
  section 2.3 sleep           : pass / fail / n-a   notes:
  section 2.4 getting books on: pass / fail / n-a   notes:
  section 2.5 rescue path     : pass / fail / n-a   notes:
  section 2.6 redeploy        : pass / fail / n-a   notes:
  new colds found (add to section 3):
  covid found (blocks alpha)  :
  VERDICT: alpha cut / not cut
  signed:
```

**One person may sign this.** The repo's two-person convention governs
changes to the kernel patches and the safety model, not this cycle — but
if QC turns up anything in section 2.5, that is a safety-model matter and
the other operator sees it before alpha is cut.
