# Reference register — external sources for hard PineNote problems

The standing list of trees and documents worth *watching*, not just citing
once. This is the inbound counterpart to `doc/upstream-register.md` (which
records what we owe the community).

The PineNote has perhaps a handful of people working on it seriously.
When we hit something hard — firmware suspend states, waveform handling,
board-revision differences, recovery from an unbootable device — the
answer usually already exists in one of these trees. Look here before
theorising.

Each entry says what the source is **authoritative for**, so we do not
treat a display expert's off-hand power claim as evidence, or vice versa.

---

## Access notes (these cost real time on 2026-08-07)

- **`git.sr.ht`'s web UI returns HTTP 502**, and so does anything fetching
  it as a web page. **The git protocol works fine.** Use
  `git ls-remote` / `git clone`, never a browser fetch, to read hrdl's
  trees. This is why the branch names below are recorded here — a
  `ls-remote` is cheap, a blind guess is not.
- **`--filter=blob:none` is not supported by sr.ht's server** ("filtering
  not recognized by server, ignoring"), so a partial clone silently
  becomes a full one. Use `--depth N --single-branch` to bound the fetch.
- **hrdl's GitHub org is stale and says so itself.**
  `hrdl-github/linux` reads "Moved to https://git.sr.ht/~hrdl/linux/";
  `hrdl-github/pinenote-arch` reads "OUTDATED and INCOMPATIBLE with
  rockchip_ebc custom driver". Do not read hrdl's work on GitHub.

---

## hrdl — the most advanced independent PineNote stack

Canonical home is sr.ht. Authoritative for the display driver's future
direction, and the only known-working ultra-suspend configuration.

### `https://git.sr.ht/~hrdl/linux`

Kernel tree. Branch names matter; there is no single "main" to follow.
Verified reachable 2026-08-07.

| branch | what it holds |
|---|---|
| `v6.19_ultra_suspend` | the ultra config (tip `ee2c553f78`) |
| `v6.19_rk_suspend_driver` | the suspend driver the ultra branch sits on |
| `v6.19_ebc_custom` | the custom-waveform display work |
| `v6.19_iio_accel` | accelerometer; visibly unfinished |

**Authoritative for:** ultra suspend, the rockchip suspend driver, the
custom-waveform (`custom_wf.bin`) display pipeline.

**What we have taken:** the ultra configuration, read from source
2026-08-07 — `rockchip,suspend-state-override = <5>` plus three `*_pmu`
rails flipped to `regulator-off-in-suspend` and `sdmmc1` moved from
`keep-power-in-suspend` to `cap-power-off-card` (5 lines total), and the
`[HACK]` cyttsp5 resume that goes with it. Their `sleep-mode-config`
(0x5ec) and `wakeup-config` (0x10) are **identical to ours** — the rails
are the entire difference. Their commit message states mode 5 "is needed
for the system to resume", i.e. the two halves are a matched pair.
See `doc/power-management.md` and
`doc/artifacts/pinenote-ultra-handshake-20260807/`.

**Watch for:** whether ultra ever lands on a mainline-tracking branch;
anything about wake sources under ultra; the tps65185 resume work.

### `https://git.sr.ht/~hrdl/pinenote-dist`

The Arch distribution: mkosi build, custom packages, sway/e-ink
integration, published signed images. Small (66 commits at 2026-06-23).
Verified reachable 2026-08-07.

**Authoritative for:** image build and distribution mechanics, and the
**`rkdeveloptool` recovery path** — their README documents
`rkdeveloptool write-partition os2 <img>` as the recommended method *when
os1 is not bootable*. That is the recovery path this repo does not have,
and its absence is what currently blocks us from ever changing
persistent boot state (`doc/power-management.md`, hibernation).

**Watch for:** release mechanics we could copy for alpha (signing,
hosting, checksums), and board-revision handling — their extlinux names
`rk3566-pinenote-v1.2.dtb`.

### `https://git.sr.ht/~hrdl/pinenote-shared`

Verified reachable 2026-08-07. Shared helpers. Note `doc/power-management.md`
already records a decision **not** to copy its tps65185 hunk (it restores
only sequencing mainline never programs, misses INT_EN/ENABLE, and its
uncached write method is defeated by our `REGCACHE_MAPLE` cache).

---

## m-weigand — the origin of the display driver

`https://github.com/m-weigand/linux` — last pushed 2025-02-18.

**Authoritative for:** the original `rockchip_ebc` driver and the
6.12-pinenote kernel that **stock os1 actually runs on our device**, which
makes it the reference for the os1 oracle's behaviour. Our
`linux-pinenote-6.6.30` regression-isolation kernel descends from here.

**Watch for:** little — the tree is comparatively quiet. Its value is as
the baseline that os1 embodies, not as a moving target.

---

## PNDeb — what os1 *is*

`https://github.com/PNDeb/pinenote-debian-image` — last pushed
2026-07-10, actively maintained.

**Authoritative for:** the stock Debian image occupying os1 on every
PineNote, including ours. Anything about what a user's device looks like
*before* they meet wilkbook — the p7 layout, the Debian home, the
preinstalled KOReader — is answered here. Directly relevant to the
migration story (`pinenote/services/library.scm`).

Also carries `pn_record_power_usage.py`, a systemd-sleep hook that
brackets power across suspend — the closest thing to a community standby
measurement (`doc/power-management.md`).

---

## Rockchip firmware blobs

`https://github.com/rockchip-linux/rkbin` — last pushed 2026-06-11,
**actively maintained**.

**Authoritative for:** bl31 and U-Boot binaries. Our deployed bl31 is
`v2.3-210-g4af361e4c` (2022-06-09). Because our ultra failure is a
firmware-behaviour question, a newer bl31 is one of the named conditions
for reopening ultra
(`doc/artifacts/pinenote-ultra-handshake-20260807/RESULT.md`).

**Watch for:** bl31 releases newer than v2.3-210, and any changelog
mentioning suspend, ultra, or wake. Note that swapping bl31 means writing
p1 — persistent boot state, which our deploy protocol deliberately never
touches, so this is gated behind having a recovery path (see
pinenote-dist above).

---

## Reference documentation

- **Kernel PM docs** — `https://docs.kernel.org/admin-guide/pm/sleep-states.html`
  and the `power/` tree (`basic-pm-debugging`, `suspend-and-interrupts`).
  Authoritative for the Linux side of suspend, and useful mainly for
  knowing where its coverage *ends*: our ultra failure is past the SMC
  boundary, where none of these tools can see.
- **Rockchip wiki, power management** — `http://rockchip.wikidot.com/power-manage`.
  Community-transcribed BSP notes. Treat as a hint generator, not
  evidence; nothing here is vendor-authoritative.
- **Pine64 PineNote documentation** — `https://pine64.org/documentation/PineNote/`.
  Authoritative for hardware facts: schematics, board revisions, flashing.
  The schematic is the source for questions like "what net does this
  regulator actually feed", which we have needed repeatedly.

---

## How to use this list

1. **Match the question to the authority.** Display question → hrdl's
   `v6.19_ebc_custom` or m-weigand. Firmware suspend → hrdl's ultra
   branch plus rkbin. "What does a stock device look like" → PNDeb.
   Hardware net → the schematic.
2. **Read the source, not a summary of it** — including ours. The
   2026-08-07 ultra work turned on a five-line diff that no summary
   conveyed, and on a commit-message sentence ("This is needed for the
   system to resume") that reframed the whole experiment.
3. **Record what you took and what you rejected**, here or in the
   relevant doc. A rejection with a reason is worth as much as a
   cherry-pick — see the tps65185 note above.
