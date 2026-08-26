# Hardware status

Last updated: 2026-08-26. Update protocol: add a dated entry at the top
after every hardware session; entries are per-device/per-operator.

## 2026-08-26 (part 9) — the ghost is grayscale: A2 routing fixes page turns, live

First full run of the ebc-lab iteration loop — a CLUT variant compiled
on the workstation, swapped onto the running device, and judged through
five live hint changes under an unmodified KOReader, no image write.
The result is a validated product recipe for direct-mode page turns.

**Setup**: fresh boot (identity CLUT via the boot one-shot, hands-off
probe at 12.3 s), then `clut-swap.sh` installed a `--class-source=DU:A2`
table (`556388ec…`) — A2 (10 phases, 6 rows, run length 1) in the DU
slot, every other slot byte-identity. First hardware use of
`clut-swap.sh`, `page-flip.lua`, and the lab's GLOBAL_REFRESH one-liner;
`rect-hints.lua --default` drove the whole sweep live under the reader.

**Synthetic flips** (page-flip.lua, 12 flips at 2 s, mono blocks):
hint 0 → A2: crisp swaps, "not really" any ghosting, 20–28 IRQs/flip
(~two defio waves × A2's 10 phases). Hint 160 → GL16: 42–60 IRQs,
minor artifacting and lingering ghost — but **still far better than
KOReader's turns**, which killed the "it's the waveform table" theory
on the spot: same driver, same routing, same table, mono content is
fine.

**Live KOReader hint sweep** (operator turning real pages):

| default hint | route | verdict |
|---|---|---|
| 160 (Y4+REDRAW) | GL16 | horrible ghosting (baseline) |
| 32 (Y4) | GL16 | identical — **REDRAW exonerated** |
| 0 (Y1 threshold) | A2 | **ghosting gone**, text readable, no antialias |
| 64 (Y1 dither) | A2 | text nice; dither visible on images; heavy images ghost (A2's drive is too weak to scrub dense content) |
| 80 (Y2 dither) | DU4 | worse: lots of ghost AND slow settle — DU4 is out |

So the horrible page-turn ghosting is **GL16 × antialiased grayscale
text**, specifically — not the table bytes (mono blocks through GL16
are near-clean), not the REDRAW flag, not the damage path. Why this
driver's Y4 transitions ghost where the shipping driver ran the same
GL16 lineage cleanly is now a research question, not a product blocker.

**The wash lever closes the loop**: one GLOBAL_REFRESH (fired from the
lab via ebclib) scrubbed the full-page-image ghost completely.
Operator: "the wash cleared it. Idle washer is fine for the current
situation. Text page turns are much nicer. Whatever the config is now
is good."

**The validated recipe** (the commercial fast-mode pattern): default
hint 64 (dithered mono via A2) for turns + wash-on-debt for ghost
management (idle washer suffices today) + per-region Y4 routing for
images later, via the RECT_HINTS plumbing this session proved live.

**Device state at close**: SESSION-SCOPED config live on os2 — A2-in-DU
table + driver default hint 64. A reboot reverts both (identity CLUT,
hint 160) and brings the ghosting back; persistence needs the one-shot
and the hint default wired into the image. Reader running, autosuspend
still pinned off. Trap for future lab work: no system `luajit` on the
image — use KOReader's bundled one
(`…-koreader-bin-…/lib/koreader/luajit`).

## 2026-08-26 (part 8) — D8 CLOSED: 20 ms to ink in FAST, 40–60 ms in NORMAL, both pen-class

The formal half of D8, from two 240 fps phone clips analyzed
frame-by-frame (`doc/artifacts/pinenote-d8-pen-latency-20260826/`):

| | FAST | NORMAL |
|---|---|---|
| software (event→fsync) | 0.3 ms | 0.3 ms |
| nib → first ink | **~20 ms** (17–25) | **~40–60 ms** |
| ink → fully dark | ~100 ms | ~250–290 ms |

**The embrace threshold is met with margin** — and the surprise is
NORMAL: the CLUT engine alone is inside pen-class, which is why the
operator reported NORMAL "feels pretty much the same to write on."
Both modes sit at/under the ~50–70 ms threshold hands can feel; FAST
is 2× to first ink and ~3× to solid, and earns its keep at the
margins (one NORMAL strike showed ink-free glass 90 ms after the nib
left; one light tap left no ink at all). Physics cross-checks land:
FAST first-visibility at 1–2 phases of its ~36 ms table-free drive;
NORMAL's ~250–290 ms development matches GL16's ~260 ms sequence.

**Product reframe this enables**: NORMAL — the same waveform lineage
the shipping driver renders with, full grayscale — can carry both
reading and writing; FAST becomes an opt-in sketch mode instead of a
required posture. No mode management in the default experience. What
direct mode still owes the reader is page-turn TRANSITION quality
(the standing optics + PHASE_SEQUENCE workstreams), not rendering
fidelity or pen latency. With part 7's felt verdicts and tonight's
numbers, every D-rung of the embrace gate that can pass has passed.

Analyst traps recorded in the artifact README: Samsung edit lists
decode as DIFFERENT timelines through ffmpeg's `-i` vs lavfi `movie=`
paths (frame indices silently disagree — cost three misaligned
analyses); the dts-warning splice points bound where 4.17 ms/frame is
true; and an ROI must match the mark's size (a 36×36 box hides an
8 px dot).

## 2026-08-26 (part 7) — first pen session: "holy crap, amazing"

The D8 instruments went on glass the same hour they were built, ahead
of the formal experiment, because the operator wanted a feel. Results:

- **`ebc-mode.lua` drove the direct driver's MODE and RECT_HINTS
  ioctls on hardware for the first time** — FAST mode confirmed live
  (`mode=1`), default hint set to 0 (Y1+THRESHOLD, REDRAW off).
- **The scribbler's software path is essentially free: 0.2–1.5 ms**
  from pen event to fsync-returned, logged per batch across ~14k
  batches. Whatever the hand feels is driver+glass.
- **Operator verdicts**: "the responsiveness is extremely good" — and
  after the rendering fix below, **"holy crap, amazing"**, then:
  "This is absolutely insane on the pen mode! It goes WAY faster than
  I expected to be able to hit. **This does make pursuing this path
  worthwhile.**" D8's felt half is in and the strategic conclusion is
  stated in the operator's own words; the formal 240 fps nib-to-ink
  number is still owed for the record. Combined with part 6's reading
  verdict, the campaign is now: keep the direct driver, fix reading
  quality on it (better optics + the PHASE_SEQUENCE user-mode path
  are the standing directives).
- **The direct driver's fbdev is RGB565** — 16 bpp, stride 3744 — not
  the shipping driver's XR24/7488. The scribbler initially assumed
  32 bpp: ink at twice the vertical position, the lower half of every
  stroke written past the end of the buffer, calibration squares drawn
  sheared or entirely off-buffer. Diagnosed live from
  `/sys/class/graphics/fb0`; the tool now reads geometry from sysfs at
  startup (harness-pinned for both formats).
- **Touch mapping needs NO transform**: the operator traced the glass
  perimeter and the mapped coordinates walked the framebuffer
  perimeter exactly — digitizer and panel share landscape-native axes
  (physical-portrait top-left = fb bottom-left, corners to corners).
- **Latent bug found by the same mistake**: `autosuspend.lua`'s sleep
  banner hardcodes the 32 bpp geometry, so on the direct image the
  banner draws sheared half-tone garbage into the top half of the
  panel (unnoticed until now because nobody looked at a sleeping study
  device). Needs the same sysfs-geometry fix; filed.

## 2026-08-26 (rig session, part 6) — the landmine image: both operational traps fixed, deployed, and proven on glass

Follow-up to part 5's two landmines, same night. The `3405a1c9…` image
carries the sysrq mask fix (`MAGIC_SYSRQ_DEFAULT_ENABLE=0x0`) and the
autosuspend fbcon gate (the shepherd requirement on reader-session is
gone — `pinenote/services/autosuspend.scm`, `autosuspend.lua`,
offline-pinned in `test-autosuspend-policy.lua`). Deployed by the full
write protocol; boots hands-off (first probe -22 by design at 2.7 s,
clean probe + fb0 at 9.0 s, CLUT 229,584 B).

**Proven on glass, in order:**

- **sysrq ships masked**: `/proc/sys/kernel/sysrq` = 0 at boot — the
  noise-safe posture is now the default, no hand-parking.
- **The daemon outlives the reader**: it starts six seconds BEFORE
  reader-session now (no requirement), and `herd stop reader-session`
  (0.417 s — INT-first again) left it running where the old image's
  daemon died. With `enabled=1` and no reader it logged
  `reader-session is down (fbcon bound) -- holding off auto-suspend`
  and refused to sleep the readerless device; on `herd start` it
  logged `auto-suspend active again` — no manual `herd start
  pinenote-autosuspend`, ever.
- **The daemon's gadget quiesce beats the dwc3 abort**: with the ACM
  gadget BOUND and unattached — the exact state that hard-aborts a
  manual `echo mem` on 7.1.8 (register item 18) — the daemon completed
  two full rails-off cycles at test timers (idle=30/backstop=90):
  suspend, RTC wake at 86/88 s, ~17 s settle, re-suspend, coulomb
  telemetry in its log, and the UDC read `fcc00000.usb` again after
  resume (restore worked). The manual-path register item stands; the
  shipping path never hits it.

**Two observations for the record:**

1. Starting earlier, the daemon enumerated 7 input devices, not 8: the
   missing one is `wilkbook-orientation` — the bridge's *synthetic*
   uinput node, created after the daemon now starts (it only ever
   rescans on eviction). Every hardware input is watched. Judged
   benign-to-correct: rotation without touch should not hold the
   device awake. Noted here so the count change doesn't read as a
   regression later.
2. **A staging race nearly flashed the wrong image, and the protocol
   caught it structurally.** The first deploy run was launched while
   the artifact/script rsync was still in flight; the on-device script
   was still the previous one, so the protocol verified and re-flashed
   the PREVIOUS image — correctly, against its own EXPECT. The tell
   was the `DEPLOY OK` line naming the old SHA. Because the script and
   its EXPECT travel together, a stale script can only ever re-deploy
   the artifact it describes — it cannot flash a half-staged one. The
   rerun with staging confirmed deployed `3405a1c9…` clean. Lesson for
   the operator side: gate the launch on the staging task's completion
   *notification*, not on a glance at its output file; and always
   check the SHA in `DEPLOY OK` against the intended image.

**Parked state**: os2 = `3405a1c9…`, reader up, washer retune
re-applied (idle_s=12, debt_min=8), frontlight 153/153, autosuspend
ENABLED at stock timers (300/3600) — the device is a working reader
that sleeps on its own; SSH is intermittent by design again. os1
untouched.

**OPERATOR VERDICT (same night, reading on the parked device): page
turning remains MUCH WORSE than before the driver change.** That is
the direct-mode bail-out axis stated plainly ("a reader that regresses
reading to gain writing is the wrong trade" —
`doc/direct-mode-adoption.md`). Standing on the other side of the
scale: nothing yet — D8 has never produced a number. The decision
logic this verdict forces: run D8 next (the pen instruments landed as
`pinenote/tools/pen/`, `make pen-check` green); if FAST mode does not
reach pen-class latency, the trade has no other side and the campaign
resolves to REJECT (restore the shipping driver image on os2); if it
does, weigh iterate-vs-reject with both numbers on the table. The
remaining iterate levers on reading quality are known and bounded:
hand-crafted waveform rows inside the measured DC envelope, and
per-turn hint tuning (diff-only turns trade transition dirt against
REDRAW's flash — the operator has now rejected each end separately).

## 2026-08-26 (rig session, part 5) — the INT-first + sysrq image deploys clean; the stop is 0.484 s on glass; the serial rescue is proven and then re-modeled

After the part-4 power-button recovery: os1 came up (the UART watcher
picked the slot), p6's post-mortem was harvested (see part 4's
POST-MORTEM), and the deploy ran the full write protocol
hands-off — staged-SHA, dd, readback-SHA all
`0c9fabcf…` (the rebuilt artifact: INT-first stop + serial-sysrq
kernel, 445498×4096 B). The fixed boot-slot script (one reboot attempt,
exit status ignored, no reconnect until U-Boot) caught the menu at poll
18 and booted os2.

**Hands-off boot regression: PASS.** First EBC probe fails by
construction at t=3.3 s (`custom_wf.bin` -2, probe -22); the CLUT
one-shot compiled 229,584 B from the device's own waveform; rebind at
**t=11.0 s** — "Loaded 4-bit PVI waveform version 0x19", initialized on
minor 1 (panfrost holds card0; the card resolution held — zero GPU
fault lines all session); fb0 bound; reader-session up. No crash-loop.

**The INT-first stop on glass: `herd stop reader-session` = 0.484 s**
(old image: 8 s; lab: 0.654 s). Clean stop, clean restart. The
crengine-cache half (SIGINT → clean close) still wants a check with a
book open; nothing was open on the fresh boot.

**The serial-sysrq rescue: proven end-to-end, and the model was wrong
in an important way.** First test (sysrq mask at its shipped 0x1)
fired **Emergency Sync from the `s` of the sequence itself** — with
sysrq *enabled*, BREAK + any char fires immediately and
`MAGIC_SYSRQ_SERIAL_SEQUENCE` is never consulted; it is an arming
toggle for the *disabled* state, not a per-use guard. That shipped
state was noise-dangerous (BREAK + line noise `b` = reboot). Verified
the intended posture live: with `kernel.sysrq=0`, BREAK+`sysrq` armed
("SysRq is enabled by magic sequence 'sysrq' on serial") and a second
BREAK+`h` printed the full key table. The deployed image's runtime is
parked at `kernel.sysrq=0` (re-park after any reboot until the next
image); the tree now adds `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0` so
later builds boot that way.

**Restored device state:** washer retune re-applied to the seeded
settings (`idlewasher_idle_s=12`, `idlewasher_debt_min=8` — wiped by
the reflash, as expected), frontlight 153/153, autosuspend still
pinned `enabled=0` on `/data` (survived, as designed). os2 carries
`0c9fabcf…`; os1 untouched.

## 2026-08-26 (rig session, part 4) — the INT-first deploy stalls on the bug it fixes: the study image hangs in shutdown

Deploy attempt for the INT-first-stop image (`cc339412…`, built and
SHA'd, deploy script staged). The `reboot` reached the running study
image over SSH — and the shutdown **hung partway and stayed hung**. The
device is parked in that state awaiting a power-button cycle (operator
unavailable); a UART watcher is armed to catch U-Boot and select os1
whenever the cycle happens. (While parked, the artifact was superseded:
the image on deck was rebuilt to include the serial-sysrq kernel below
— `0c9fabcf…`, 445498×4096 B, all inspection gates green, sysrq
symbols verified in the embedded `/boot/config`. `cc339412…` was never
flashed.)

**The evidence chain, all over UART/network, no panel:**

- The boot-slot capture's last line is fbcon restoring (`Console:
  switching to colour frame buffer device`) — the reader stopped, then
  400 s of silence; U-Boot never ran.
- Ping answers and the ttyS2 line echoes keystrokes (kernel alive, IP
  configured), but sshd **refuses** connections (listener closed, not
  filtered) and no getty ever re-prompts — userspace torn down to the
  halfway point and stuck.
- Console logins can't rescue it: `root` at a live prompt got a getty
  echo but no `login`/shell response in 30 s+, with correct LF
  terminators, twice. Nothing on the tty has a reader.

Prime suspect: the shutdown-path incarnation of the known stop-handler
stall — the deployed (old) image's reader-session `stop` blocks PID 1
in `usleep`, starving shepherd's fibers; at shutdown every service stop
runs on that starved scheduler. This is precisely what the INT-first
stack on deck replaces (lab-measured 0.654 s vs 8 s per stop). The
shutdown hang is consistent with, and strengthens, that fix's rationale
— but the root cause on-device is unproven (post-mortem: nothing will
survive in /tmp; `/var/log/messages` on p6 may hold the shutdown tail —
harvest from os1 before booting os2, per `doc/device-access.md`).

**Two instrument findings, one fixed in-tree tonight:**

1. **No serial rescue exists for a hung device.** The inherited
   defconfig sets `CONFIG_MAGIC_SYSRQ=y` but explicitly unsets
   `CONFIG_MAGIC_SYSRQ_SERIAL` — a BREAK on the plumbed UART does
   nothing, so a wedged userspace costs a user-present power-cycle even
   with the cable in. Fixed in the forward-port patch. (The guard model
   this entry originally described was wrong — the sequence is an
   arming toggle, not a per-use guard; the live test that corrected it
   and the final three-symbol config are in part 5 below and
   `doc/kernel-forward-port.md`.)
2. **A hung shutdown wears the live system's face.** The first read of
   the evidence was "U-Boot fell through and rebooted os2": a
   `pinenote-reader-direct login:` prompt answered the UART probe. It
   was the *dying* session's getty — shutdown had stalled before
   reaching it. The login attempt that followed consumed that last
   getty (login(1) exec'd into the starved system and never came back;
   wedged shepherd, no respawn), closing the only interactive door.
   Diagnostic for next time: prompt-then-echo-without-response after a
   reboot command means the OLD system mid-hang, not a fresh boot —
   check uptime/dmesg BEFORE typing a login name at it, because the
   attempt itself is destructive to the recovery path.

Also confirmed the hard way: the only ttyACM on this host is the MOTU
M4 (the documented trap) — no gadget fallback while os2 is down.

**POST-MORTEM (same night, after the power-button recovery) — the
suspect above is refuted; the log names the real killer.** p6's own
`/var/log/messages`, harvested via the os1 ro-mount before the
redeploy, records the whole thing
(`doc/artifacts/pinenote-shutdown-wedge-20260826/`): the halt began at
05:02:01 and the service teardown was FAST — reader-session stopped
within a second, orientation-bridge in ~1 s (the SIGTERM fix proven
working on device), ddr-boost in 3 s. No PID 1 crawl. What wedged it:
the halt killed the very ssh session that had issued `reboot`, the
deploy script misread that client's nonzero exit as failure and fired
its `||` fallback ssh, shepherd's inetd listener — still armed
mid-halt — accepted the connection, and serving it **restarted the
networking service the halt had just stopped** (dhcpcd relaunched;
which is why ping kept answering all night). `Service networking has
been started.` is the final line the system ever logged. Two fixes:
the deploy tooling now makes ONE reboot attempt, ignores its exit
status, and never reconnects until U-Boot shows on the UART; and the
shepherd halt/inetd race is registered as upstream item 20. The
usleep/INT-first stop fix remains lab-proven and worth shipping — it
just wasn't tonight's culprit.

The operator's directive: reading first, pen later; direct mode is the
floor either way. The night's instrumentation dismantled most of the
pre-registered P4 model:

**"Two-pass by construction" is REFUTED.** ftrace on the fb blit
(`rockchip_ebc_blit_fb_rgb565_y4_hints_neon`) shows exactly one flush
per input-triggered repaint — our KOReader shim's fsync publishes
through his stock `fb_deferred_io_fsync` path, so publish-on-call works
on ANY fbdefio driver and the planned defio/publish-on-call port is
unnecessary. (P4 said "or prove an equivalent exists"; proven.)

**REDRAW is stripped at drive time at the shipping default.** The
`vbslq` force-mask in `schedule_advance_neon` clears the REDRAW bit
from every pixel when `redraw_delay==0` — turns were always diff-only;
the "full-page shimmer" theory was wrong. The dirt = the intrinsic
GL16 transition (~22 active phases ≈ 260 ms at the cold bin) plus
bounded ghost accumulation.

**`redraw_delay` cannot defer ghost-cleans from idle** — its countdown
ticks per hardware frame, an idle panel generates none, so ANY nonzero
value parks all damage indefinitely (proven twice: rd=10000 and rd=1
both wedged the queue; a wash recovers). It is a FAST-mode batching
knob, not a reading-mode one. Register item 19.

**The CLUT classes decoded** (wbf-clut -v against the device's own
waveform): active run lengths at the cold bin DU 3 / DU4 6 / GC16 9 /
GL16 22 phases, padded sequence lengths ~10x that (which is what IRQ
counting measures — 44/37/37 frames per turn for GL16/DU4/DU, ~zero
optical difference: settle medians 200/200/133 ms on the rig camera).

**The GL16←GC16 slot experiment: BUILT, RUN, REJECTED.** New
`wbf-clut --class-source=TARGET:SOURCE` (merged; identity is pinned
byte-identical, the remap pinned to take) compiled a table with page
turns on GC16's short punchy rows; deployed by live unbind/swap/bind.
Operator verdict on side-by-side video: **stock GL16 is better** — the
GC16-slot turns ghost MORE (full prior-page words readable), plausibly
because wash-pattern rows under-drive arbitrary partial transitions —
the exact thing GL16 exists for. Stock restored (and a reboot would
have restored it anyway — the stamp mechanism makes remapped tables
session-scoped). The crafting direction shifts to hand-built rows,
which needs DC-balance analysis tooling in wbf-clut first.

**Ghosts are bounded, not compounding**: mean-normalized camera diff
0.0695 after 12 washless turns, 0.0625 after 24, floor 0.0487.

**The manual-launch font bug**: every `env -i` manual KOReader launch
this whole session dropped `EXT_FONT_DIR` (and PATH, LC_ALL) — all
manual-session renders used KOReader's bundled fallback fonts, not the
seeded ones. Caught by the operator on video; proven by pagination
(guile.epub: 3716 pages under fallbacks, 3804 under the real fonts).
The full service environment is now in `doc/device-access.md`; earlier
quality impressions carry this confound (A/B comparisons were
same-fonts both sides, so relative judgments stand).

**The practical lever landed: idlewasher retune.** The knobs were
already G-settings; the device now runs `idlewasher_idle_s=12,
debt_min=8` (was 45/15) so the ghost-clean lands in natural reading
pauses. Demonstrated: 10 turns → wash fired 13 s into the pause at
debt=12. DEVICE-ONLY for now — the repo seed changes only after the
operator's felt verdict over real reading.

**R-list opportunistic closes (same userspace as shipping):** R1 —
`/etc/localtime` resolves to the configured zone (UTC default). R2 —
the manuals shelf staged (538-doc `Manual pages.epub` present); opens
measured **30.3 s uncached / 1.7 s cached**, with the catch that
crengine caches are written only on clean close: SIGTERM (shepherd's
stop, crashes) leaves zero-byte truncated caches and the next open
pays the 30 s again, while SIGINT closes cleanly (8 MB cache written,
proven). Work items: INT-before-kill in reader-session's stop;
staging-time cache pre-warm (`doc/manuals.md`). R4 largely proven in
passing: refresh seed honored (`full_refresh_count=0` respected on
glass), fonts staged and rendering (via `EXT_FONT_DIR`), idlewasher
G-settings read.

State left: stock CLUT restored and verified, service reader running
(washer retune persists via G-settings), autosuspend still pinned off,
battery ~60%.

## 2026-08-26 (same rig session, continued) — D5: all four orientations on glass; D6: ultra suspend survives the swap; the turn-key inversion; corrected power

**D5 RESOLVED AND PROVEN — rotation works on the direct driver.** The
offline rung-4v investigation (qemu, instrumented chain, now merged as
`test-rotation-decision.lua`) named the boot decider: the
`closed_rotation_mode` G-setting, which our own profile seeds to 1
(portrait) and Generic `Device:init` applies unconditionally — none of
the four glass mechanisms from 08-25 was ever consulted (two are
dead-gated by our `lock_rotation=true` seed, one is menu-only, and the
injected-gyro attempt died because `herd stop orientation-bridge` takes
reader-session down with it — a shepherd dependency stop). On glass
tonight: flipping the setting across a reader-session restart rendered
**all four orientations** — 0/2 both landscapes, 1/3 both portraits —
each camera-verified after a wash, crisp, no trace of the shipping
driver's portrait-wedge class. "Nobody has ever rotated via fbdev on
his stack" is retired.

**D6 PASSES — with one real 7.1 finding.** First attempt never
suspended: **dwc3 aborts the whole entry when the ACM gadget is bound
with no cable attached** (ep0 SETUP timeout → `failed to set STALL` →
`plat_suspend returns -11`; "Some devices failed to suspend"). The
7.0.11 soak did 170 cycles in the same gadget arrangement, so this is
new on 7.1.8 — registered (item 17 follow-on pending; workaround:
unbind the UDC first). With the UDC unbound, the ultra pair engaged
fully: `PM-STATE: ultra (cfg 0x5ec)`, rails off, LPDDR4X retrained
324→1056 on wake, `rockchip_ebc_resume` clean, post-resume wash 42
IRQs, before/after frames identical, **0 cyttsp5 wakeup-response
failures** (R6: 0/1). Gadget rebound after.

**The page-turn key is inverted, and it invalidated a bracket and a
video round.** KEY 158 — which KOReader labels `RPgBack` — executes
`goto relative screen: +1` (advances); 159/`RPgFwd` goes backward. The
first "turn" bracket and first video set therefore measured 48 clamped
same-page repaints at page 1: full-rect REDRAW passes whose cost decays
43→~12 IRQs as the ghost-clean converges (NOT diff-shrink across pages,
as first recorded), with the framebuffer byte-identical throughout.
Diagnosed end-to-end: injector emits clean press/release (od on the
evdev node), KOReader receives and maps them (`-d` trace), the page
clamps. The optics-inject header's 158/159 = RPgBack/RPgFwd comment now
carries the correction.

**Corrected active power (real turns, fb-verified advancing):**

| condition | mean |
|---|---|
| reader idle, frontlight 0 (unchanged) | 155.3 mA |
| REAL page turns every 3 s, 48/48 landed | **214.6 mA** |
| per-turn drive | **41.5 frames/turn** (1993 IRQs / 48) |

Turning at 20/min costs **+59.3 mA**, not the +37 first recorded (that
figure was the same-page artifact). Under the default Y4|REDRAW hint a
real turn drives nearly full-page waveform depth every time — a power
argument for P4's intent mapping, on top of the visual one. Idle parity
with shipping stands.

**P4 on-glass verdict (operator, watching real turns live):** turns
settle to a clean page **without any flash** — the profile's
`full_refresh_count=0` is landed and honored, and across four hint
variants (baseline 160; diff-only 32 + `redraw_delay=255`; Y2 144;
`no_off_screen=1`) zero washes and zero flashes fired in 8-turn runs —
but the **transition is dirty**: intermediary ghosting, prior-page text
briefly overlapping. P4's target is therefore transition cleanliness at
constant flash count, not flash removal. (First video round also
surfaced: a strong luminance dip at each clip's frame 0 is the Brio's
auto-exposure settling — never a panel event.)

**Operational notes:** KOReader owns frontlight state across
reader-session restarts (each restart needs the rig's 153/153 re-set
before captures — two black frames cost the lesson); one `herd start`
during the orientation sweep hung its SSH block though the service
itself came up (transient, unreproduced); fbcon briefly bound the fb
(landscape 234x87, native var 1872x1404) between reader stops around
the D6 window. Battery 85%→~65% over the whole session. Autosuspend
still pinned off; frontlight restored; portrait default restored.

## 2026-08-26 — the wired direct image boots hands-off; direct-mode active power ≈ shipping (agent session, Will's device, optics rig + UART)

Operator granted the dd and the UART slot-pick for this session ("fully
permitted to do the dd step yourself while the box is in the optics
rig"); every destructive step below ran over UART/SSH with no hands on
the device.

**Deployed**: `pinenote-reader-direct` built from main at the post-glass
fix stack (flavor wiring + rebind + card resolution + bridge SIGTERM
fix), sha256 `28eebed0ba1b17cfd25e0b298f61271fcf40ffaacb61dad25add4b923af45dec`,
staged→dd→readback all three SHAs equal. One live confirmation on the
way out: the OLD image's shutdown wedged on orientation-bridge's
`--cleanup` ignoring SIGTERM — the exact registered bug — and needed one
last SIGKILL; the reboot resumed the instant the hook died.

**The tag-blocker validation passes, fully hands-off:**

- **Boot → working reader with no hands**: initrd probe fails
  `-EINVAL` at 2.7 s (by construction, every boot), root hands off,
  `pinenote-ebc-clut` compiles `custom_wf.bin` from the device's own
  waveform (229,584 B — byte-identical size to the 08-25 hand compile),
  rebind probes clean at **10.1 s**, fb0 registers, and shepherd starts
  reader-session **once** — no crash-loop, no respawn, no wedge. The
  KNOWN GAP's expected few-failed-starts never materialized: the
  dependency chain delays KOReader past the rebind.
- **Card resolution is glass-proven**: the EBC is **card1** on this
  image (panfrost holds card0 — the exact arrangement that broke
  washes). `pinenote-ebc-refresh` through the by-driver-name path drove
  a global refresh (45 EBC IRQs), **zero** panfrost faults in dmesg,
  and KOReader logged no "full refresh disabled" (its designed failure
  signature; silence + washes landing = resolved).
- **The bridge dies on SIGTERM**: `herd stop orientation-bridge`
  completed in **1 s**, "terminated with signal 15" — where the
  previous night's image wedged until SIGKILL. Restart clean.
- **U-Boot slot-pick trap**: this U-Boot draws the boot menu without a
  contiguous "Hit any key to stop autoboot" in the byte stream —
  boot-slot.sh's old trigger missed it and the countdown fell through
  to os1 once. Trigger widened to the menu strings themselves
  ("U-Boot Boot Menu"/"Boot OS2 (part 6)"); second attempt picked os2.

**Active power under direct mode** (rk817-battery `current_avg`,
cross-checked against `charge_now` deltas; on battery, charger offline;
each bracket n=60–75 over ~150 s, sampler detached on-device — see
instrument lessons):

| condition | mean |
|---|---|
| reader idle, frontlight 0 (ledger conditions) | **155.3 mA** |
| shipping reference, same conditions (ledger) | 156.9 mA |
| reader idle, frontlight 153/153 (rig illuminant) | 194.3 mA |
| page turns every 3 s (48 turns injected, guile.epub) | **192.1 mA** |
| idle repeat, immediately after the turn run (ABA) | 169.8 mA |
| system floor, reader stopped (old image, same kernel) | 161.4 mA |

- **Direct-mode reader idle is at parity with shipping** (155.3 vs
  156.9 — inside the bracket noise). The direct driver idles properly:
  EBC and GPU runtime-suspended, 0 EBC IRQs, ±15 V/VCOM off (v3p3 held),
  cpu ~99% at 408 MHz.
- **Turning costs +36.8 mA at 20 turns/min** (aggressive pace); a
  normal 6–10/min pace interpolates to roughly +11–18 mA. Per-turn IRQ
  meta: first full-page paint 43 frames, steady state **11.7
  frames/turn average** (561 IRQs / 48 turns) — the diff/THRESHOLD hint
  shrinks steady-state turns.
- The elevated ABA repeat (169.8) is unattributed but consistent with
  the idlewasher retiring wash debt in the minute after activity;
  worth one dedicated bracket someday.
- **Frontlight term measured twice, disagreeing**: 39.0 mA (this image,
  B1−B1b) vs 24.1 mA (old image, reader stopped, SSH attached both
  sides). The ledger's "open term" now has a 24–39 mA range — over its
  15.4 mA 25-hour budget either way. ABBA owed before a single number
  enters the ledger.

**Instrument lessons (cost a first wrong reading of 235 mA):**

- An **attached SSH session inflates awake brackets ~50 mA** (Wi-Fi held
  out of powersave + per-sample wakes): 211 mA attached vs 161 mA
  detached, same state. Detached on-device sampler, fetched after, is
  the only honest method — matching the ledger's no-SSH condition.
- `scaling_cur_freq` read over SSH shows the probe's own 1.8 GHz burst;
  `time_in_state` shows the truth (~99% at 408 MHz).
- The frontlight had been left at the rig's 153/153 from the previous
  session (+24–39 mA) — check it before any power bracket.

**State left**: os2 = wired image `28eebed0…`, service KOReader at the
FileManager, frontlight 153/153 (rig standard), autosuspend still
pinned `enabled=0` on p7 (direct sessions ongoing — re-enable when they
end), injector torn down (reader stopped first; no panic — the
destroy-under-reader ordering held). os1 untouched.

## Current state (2026-08-15)

**Proven on glass**: KOReader on fbdev with pen, finger, frontlight, and
SC7A20 autorotation on all four edges; temperature-compensated waveforms;
Wi-Fi association + key-only SSH; PREEMPT_RT; **ultra suspend** — hrdl's
rails-off configuration on the primary kernel, three consecutive resumes
(RTC backstop + power button), **4.64 mA measured**
(`doc/artifacts/pinenote-ultra-r12-20260808/`); deep (~20 mA) is
superseded as the shipping suspend.

**On os2 now (since 2026-08-26)**: the `reader-direct` study image
`28eebed0…` (wired: boot-time CLUT + rebind + card resolution + bridge
fix; readback-verified), auto-suspend OFF (p7 pin, direct sessions
ongoing). The promoted shipping image `9a08803e…` last held os2 up to
2026-08-25; the shipping-image facts below describe that deployment. The **≥3-day
unplugged ultra soak has CONCLUDED** — it ran 6.17 days and met its exit
criteria: **170 suspend cycles, zero failures**, no forced power-off,
and a measured standby figure at last — **5.47 mA idle (~30 days) and
10.07 mA as actually read (~16 days)**
(`doc/artifacts/pinenote-ultra-soak-20260815/`). Exit criteria in
`doc/alpha-checklist.md` §3c. A failed wake gets the U-Boot `INT_STS`
forensics *before* any forced power-off. Wake sources are rk817-internal
(RTC alarm, power button, charger) **plus the cover, confirmed working
2026-08-09** — which our rails model says should be impossible, since
`gpio0 RK_PC7`'s pad supply is off-in-suspend. The pen cannot wake it.
The cover mechanism is an open question, not a settled tradeoff.

**Still true / still open**: DDR static-low ships `mode=off` (324 MHz
corrupts the display silently); SSH to the deployed reader is
intermittent while auto-suspend is enabled (`doc/device-access.md`); the
TPS `ENABLE` 2f→20 delta is unexplained. **Standby is now measured**, so
the long-standing "arithmetic only" caveat is retired.

**Next actions**: (1) the human QC cycle (`doc/alpha-signoff.md`) on a
post-soak image; (2) the alpha tag.

**2026-08-25 FIRST DIRECT-MODE GLASS: D1–D4 pass, D9 measured, one panic captured, D5 unresolved.** [wilkbook / wkelly + agent]
The deployed study image booted and ran KOReader through hrdl's
direct-mode driver, in the optics rig, driven entirely over SSH/UART.
Videos and frames in the session scratchpad; key artifacts to be
committed with the writeup.

LADDER RESULTS
  D1  CLUT compiled ON THE DEVICE by wbf-clut from its own ebc.wbf:
      229,584 B, 14 bins — but BY HAND: the clut service is not in the
      image (the flavor never instantiates it; found independently by
      the release review). Persists on p6, so later boots need no
      recompile — but see D2.
  D2  PROBE PASSES only after a per-boot REBIND: the initrd raw-loads
      rockchip_ebc before the rootfs (and its custom_wf.bin) exists, so
      first probe fails -EINVAL and `echo fdec0000.ebc > .../bind` must
      follow. The DT third clock works (no clock error); temp bin 24–27
      selected via IIO.
  D3  Panel lights and paints. fb0 is RGB565 1872x1404 and KOReader
      ADAPTS — the feared XR24 wall does not exist (his rgb565→Y4 blit).
  D4  Page turns work through GLOBAL_REFRESH (ABI-identical 0xC0016440)
      — after fixing THE GHOSTING ROOT CAUSE: KOReader's device.lua
      hardcodes /dev/dri/card0 for the wash ioctl, and on this image
      card0 is PANFROST (the GPU) — every wash was a malformed GPU job
      (the dmesg "JOB_CONFIG_FAULT" lines) and the panel had never been
      washed. Post-fix (bind-mounted card1), ghost-vs-wash SSIM sits at
      the camera noise floor. OPERATOR VALIDATION on video: quality
      good; MORE FLASHING/REDRAWING PER TURN than a smooth read wants —
      the pre-registered two-pass + waveform-class expectation, now the
      P4 driver (see doc/direct-mode-adoption.md).
  D9  advance() cost from his own instrumentation: 37 µs idle,
      ~1.9 ms band, **23.1 ms full-panel peak** vs the 11.7 ms frame
      budget — over budget IN THE KERNEL, single-threaded on 4 cores
      (matches the boot RT-throttle event). Residence is not the
      constraint; parallelism is the lever. This is the §7
      userspace-TCON feasibility number.
  D5  ROTATION UNRESOLVED, not failed: four remote mechanisms (injected
      gyro events, doc sidecar, copt_rotation_mode, the
      /run/wilkbook-orientation.state file) all produced portrait
      boots; the rotated render path never executed. Four cold full
      paints were clean. Next: instrument the rotation chain at rung 4v
      offline, then one targeted glass pass (or physically rotate the
      device out-of-box).

THE PANIC, CAPTURED ON CONSOLE (uart-d5.log):
      Unable to handle kernel NULL pointer dereference at virtual
      address 0000000000000008 / Oops: 0000000096000044 [#1] SMP /
      Kernel panic - not syncing. Pattern across both occurrences:
      a uinput device destroyed WHILE KOReader holds it open, then the
      reader restart panics; restarts without a preceding device
      destruction never crashed, and the stop-reader-first ordering
      survived where the other died. Reproducible; trace partially
      garbled by console interleaving. To upstream-register.

OPERATIONAL FINDINGS
  * UART slot selection works end-to-end: scripted DOWN,DOWN,ENTER at
    the U-Boot menu booted os2 twice, no hands. My earlier "RX dead"
    was two broken captures of my own (a backgrounding race, then a
    pkill that matched its own command line). /dev/ttyACM0 is the
    operator's MOTU M4, not the PineNote.
  * orientation-bridge ignores SIGTERM — its --cleanup stop hook hangs
    `herd stop` (shepherd wedged "being stopped" until SIGKILL).
  * After crash-loop failures, shepherd marks reader-session failing
    and later constructor starts fail silently; a manual env-matched
    launch works. Not yet diagnosed.
  * Two auto-suspends interrupted work before autosuspend was pinned
    off (p7 enabled=1 + the daemon restarting with the reader). The
    standing disable-first rule exists for this reason; it now also
    survives on p7 as enabled=0 — RE-ENABLE AFTER THE DIRECT SESSIONS.

Session-local state (bind-mounts, injectors, manual reader) dies at
reboot. p6 keeps custom_wf.bin; p7 keeps enabled=0. os1 rescue path
verified twice tonight, involuntarily.

**2026-08-25 FIRST DIRECT-MODE DEPLOY — written and verified, not yet booted.** [wilkbook / wkelly + agent]
The `reader-direct` STUDY image (hrdl's direct-mode EBC driver; see
`doc/direct-mode-adoption.md` and the agenda in
`doc/glass-plan-2026-08.md`) was written to os2 per the
`doc/hardware-deploy.md` protocol. os1 booted and confirmed as running
root (`/dev/mmcblk0p5`), p6 unmounted, preconditions re-checked
immediately before the write.

  artifact  pinenote-reader-direct-PNGuixRoot-20260825.ext4 (1,824,632,832 B)
  sha256    f0e9b4ad2d4fa39efe465895c7ba4f90ad67b5bb092d9bad0a1f0cba276ad0c4
            (host == staged-on-p7 == readback-from-p6, all three identical;
             readback with iflag=direct over exactly the written 445,467
             4 KiB blocks)
  kernel    linux-pinenote-hrdl-direct-7.1.8 (three EBC modules; DTB
            carries the third clock, CPLL_333M, verified in the compiled
            blob before deploy)
  contains  wbf-clut (on-device CLUT compiler; verified present and USED
            in the session below). CORRECTION, same day: this entry
            originally also claimed the checksummed ebc-clut-install
            one-shot and the zero-parameter modprobe options. The image
            contains NEITHER — the flavor on main never instantiates
            them (found independently by the release review and by the
            live session, where `herd` showed no clut service and D1
            needed a hand-compile). The wiring gap is the top
            tag-blocking item in the release-review fix-list.

This replaces the promoted reader image `9a08803e…` on os2 FOR THE STUDY
SESSION; the shipping reader remains the deploy candidate for the next
tag and its rootfs is unchanged in the store. os1 untouched throughout.
Boot and D1–D9 results get their own entry when they happen. Expectations
going in are pre-registered in the glass plan: A2 absent from the CLUT,
`refresh_waveform` writes inert, two-pass page turns by construction,
RGB565-vs-XR24 the likely first wall after probe.

**2026-08-15 THE SOAK CONCLUDED — standby measured.** [wilkbook / wkelly]
Harvested read-only over SSH from os2 while the device was still running;
nothing written, nothing restarted. Window 2026-08-08 23:57:41 →
2026-08-15 04:01:04 UTC (148.1 h, 6.17 d) on `/dev/mmcblk0p6`, Linux
7.0.11 PREEMPT_RT, image `9a08803e…`. `charge_now` 3,848,844 →
2,358,464 µAh = 1490.4 mAh consumed with **zero** gauge increases across
170 samples, so the device was never on a charger and the series is
monotonic. `/sys/power/suspend_stats`: **success=170, fail=0.**

Idle standby, taken from the 119 hour-long backstop-to-backstop
segments: **5.47 mA median** (mean 5.50, range 4.46–13.09) → **~30.5
days** from 4000 mAh. Overall across the whole window, i.e. the device as
actually lived in: **10.07 mA** → **~16.6 days**. The ~4.6 mA difference
is awake time; against the 156.9 mA awake floor that implies roughly a
3 % duty cycle, order of 40 min of reading per day.

This corrects the standing projection in both directions. R12's 4.64 mA
(a 40-min bracket containing no backstop wake) had been extrapolated to
"~36 days pure, ~28 effective". Measured idle standby is 5.47 mA, so the
hourly RTC backstop costs **~0.83 mA**, not the ~1.3 mA that estimate
implied — the post-`626cb02` re-suspend-after-20s-settle is working, and
the >30-day desired outcome is met on measurement rather than on paper.
The reading term, which no prior figure carried, roughly halves it.

Also from the log: 4 power taps correctly ignored inside the 2 s
post-resume grace (that guard fires in the field); **2 cover-close
suspends against 27 power-button presses**, quantifying the "fussy
magnets" note in `doc/alpha-expectations.md`; and 3 ×
`EBC still active after ~10s wait -- proceeding anyway` — cost nothing
here since no suspend failed, but it is the one line in six days of logs
that wants follow-up.

Not proven: charging behaviour, gauge absolute accuracy, cold storage,
or the single 13.09 mA idle-segment outlier. The window opened at ~96 %,
not 100 %, so the day figures are projections from the measured rate
rather than an observed run to empty.

**2026-08-08 (night) THE ULTRA SOAK IS RUNNING.** [wilkbook / wkelly]
Promoted image `9a08803e…` deployed to os2 (readback-verified), p7
`enabled=1`, and the first PRODUCTION ultra cycle observed end to end:
the daemon idled 300 s, drew the banner, gated the EBC, quiesced the
gadget, saved the frontlight, and entered ultra — banner
`PM-STATE: ultra (…, cfg: 0x5ec), pmic: 0x14, 0x00` — then woke on a
single power press after 677 s with the new self-telemetry line:
`resumed after 677s (charge_now=3848844)`. Battery 97 % at soak start,
~23:58 UTC. Exit criteria (pre-committed in `doc/alpha-checklist.md`
§3c): ≥3 days, zero non-wakes, no peripheral degradation, and the
standby figure computed from the daemon's own charge_now series. If a
wake ever fails: note the time, do NOT force off until the U-Boot
INT_STS forensics are taken.

**2026-08-08 R12: THE ULTRA WAKE PROBLEM IS SOLVED — rails-off resumes,
4.64 mA measured.** [wilkbook / wkelly] hrdl's configuration (three
`*_pmu` rails off-in-suspend + `sdmmc1 cap-power-off-card` + the cyttsp5
resume workaround), adopted whole into a quarantined bench flavor,
resumed from ultra suspend on our bl31 v2.3-210 + 7.0.11 stack — on BOTH
wake legs: the RTC alarm (slept=60s, exactly on the backstop) and the
power button (slept=28s). Third suspend slept 2400 s on the dot and gave
the cleanest current bracket ever taken here: **4.64 mA** (3,096 µAh over
40.0 min, both reads in-process seconds around the sleep), against deep's
~20 mA. ~36 days of pure suspend on a full charge; the 18-day target now
has 2× slack.

The pre-registered go/no-go held: bl31's banner printed `pmic: 0x14,
0x00` — the payload cleared exactly the three `POWER_SLP_EN` bits R11's
rails-on runs read as `0x25`. Wake is PMIC-mediated and it is a genuine
RESUME with kernel continuity, which fully explains R10: rails-on ultra
is the one configuration with no wake path at all. Wi-Fi re-initialised
from a powered-off SDIO card; the cyttsp5 [HACK] validated on glass
(one cold-controller timeout, reset-and-continue, operator confirms
panel clean / touch works / pages turn). `suspend_stats 3/0`.

Record: `doc/artifacts/pinenote-ultra-r12-20260808/`. Not yet done: the
multi-day soak, and the adoption decision (the payload is quarantined
out of production by `make ultra-quarantine-check`; promoting it is a
safety-model change).

**2026-08-07 auto-suspend duty-cycle fix — in tree, NOT in any deployed
image.** Every deployed image from 2026-08-03 onward re-armed a full
300 s idle period after an RTC-backstop wake, so a device left alone ran
900 s asleep at 20.6 mA then 300 s awake at 156.9 mA forever: 25 % awake,
54.7 mA, flat in ~3 days rather than the ~8 the deep floor implies.
`626cb02` re-suspends after a 20 s settle when the sleep lasted
essentially the whole backstop (a button wake still gets the full idle
period), and the default backstop moved 900 s → 3600 s now that each
backstop wake is pure cost. **No hardware evidence yet** — the numbers
are arithmetic on the measured 156.9/20.6 mA, the 1 h dwell is 4x [correction 2026-08-08: 1.5x — the 4x was against the retired 900 s default; R12 slept 2400 s] the
longest this device has slept, and the acceptance procedure (a log read)
is in `doc/power-management.md`, "The idle duty cycle". Offline evidence:
`pinenote/tools/power/test-autosuspend-policy.lua` under `make
power-check`, which runs the daemon's own extracted source and fails on
the pre-fix file. The finding was already in the 2026-08-03 soak record
four days earlier and was read as an argument for a *longer* idle default.
(`626cb02`'s message says "eleven weeks"; the record says 2026-08-03 →
2026-08-07.)

**2026-08-06 (after the v3 write) persistent SSH host keys — in tree,
NOT in any deployed image.** The same `pinenote-ssh-authorized-keys`
one-shot now synchronizes `/etc/ssh/ssh_host_*_key` with
`/data/ssh/host/` (union, `/data` wins per key type; keys failing an
`ssh-keygen -y` validity check are never installed; nothing ever
deleted from `/etc/ssh`, so no keyless window; seeds are `sync`ed so a
power cut cannot persist a truncated identity), closing the
reflash-changes-the-fingerprint annoyance.  sshd is inetd-style, so
keys are read per connection and no service ordering is needed.
Offline evidence: closure builds; the one-shot in the closure's
shepherd graph is the exact script that passed sandboxed
seed/restore/union/garbage-rejection/failure runs plus a 3-agent
adversarial review.  **Scope: v3 on os2 predates this change** — v3's
first boot regenerates the fingerprint one more time WITHOUT
persisting it.  The first boot of an image built from this tree seeds
the identity and it is stable across reflashes after that; pin the
fingerprint in the ledger THEN, not at the v3 boot.
`doc/networking.md` §4.1.

**2026-08-07 (night) ULTRA ANSWERED: firmware honours state 5, nothing
wakes from it.** [wilkbook / wkelly] Session B run on the ship candidate
`7eaab343…`, UART proven both directions first (`tx` 1701→1730 with a
host-read marker, `rx` 0→34). One variable, 65 s apart, same boot:

    R9 control  PM-STATE: mem   (ultra: 0, mem: 3, cfg: 0x5ec), pmic: 0x14, 0x25  -> rc=0, slept 60s
    R10 armed   PM-STATE: ultra (ultra: 1, mem: 3, cfg: 0x5ec), pmic: 0x14, 0x25  -> NO RESUME

`ultra:` incremented for the first time ever; `mem:` held at 3. **Both
pmic words are identical**, confirming on hardware what the offline
disassembly claimed: the ultra branch touches no PMIC, so this was a pure
firmware handshake with the proven `mem` rail configuration and zero DT
changes. Ultra ran strictly more stages (`1234567abcdeghij789sram2wfi`
against the control's `abcdeghij701M`) and ended in WFI from SRAM.

Then nothing. RTC alarm at +60 s never fired; UART silent for a further
110 s; SSH timed out; **ICMP went dead too**, which is itself evidence —
under ordinary deep this device answers pings via brcmfmac offload.
**A short power-button press also did nothing**, tried deliberately
before any long-press: had it woken, ultra would still have been a usable
reader state. It is not. Only a forced power-off exits.

**Ultra is closed for alpha, and not because of the rail payload — we
never adopted one.** `deep` at ~20 mA stands as the shipping suspend.
Recovery: long-press, cold boot, U-Boot autoboot landed on os1. Full
record and raw UART:
`doc/artifacts/pinenote-ultra-handshake-20260807/RESULT.md`.

Two procedure bugs this run found, both now fixed: PROCEDURE.md named the
wrong sysfs path (`rockchip_suspend_activate` vs the real
`rockchip_suspend_mode_drv`), which would have produced a silent false
"firmware ignored state 5"; and "gadget quiesced" was unspecified — the
first control attempt died at 5 s on `dwc3 … returns -11` because the ACM
gadget stays bound to the UDC even in the secure build.

**2026-08-07 (evening) ALPHA SHIP CANDIDATE ACCEPTED ON GLASS — image
`7eaab343…`.** [wilkbook / wkelly] First full reader acceptance since
2026-08-01, run on the exact artifact intended to ship, judged by the
operator's own eyes rather than a camera. **All five checks passed**, two
of which had never been recorded at all:

1. **Clean panel out of boot** — no striping, no dark bar. The first boot
   of an image whose DMC default is genuinely `off` in code rather than
   in prose (`28fda00`; the previous commit claiming it changed only
   comments).
2. **Press-to-suspend, the test that had sat at "fix deployed,
   unproven"** — page plus banner, sleeps, wakes clean on a second press,
   frontlight off while asleep. Machine account agrees: `power tap --
   suspending on request` → `resumed`, suspend_stats **2/0**.
3. **No residue across 10 page turns** in both directions.
4. All four autorotations.
5. No double draws, no flashing, in menus or the file browser.

Machine-side confirmation on the same boot: `mode=off` read from
`/data/wilkbook/dmc.conf`, `clk_scmi_ddr` at **1056000000**, `wilkbook_dmc`
not loaded, `/etc/wilkbook-build` = `default`, the ACM console service
absent from shepherd entirely, and zero `NOPASSWD` lines in sudoers — the
secure build verified on the device, not merely in the closure.

**One real defect found, previously normalised.** The suspend banner is
truncated, and the operator had never mentioned it because it looked
cosmetic. It is not: `draw_banner` sizes text against `FB_W` (1872, the
panel's LONG axis) while the device is read in either orientation, so at
scale 6 the 33-character string is 1584 px and overflows the 1404 px
short axis by 180 px — about three characters. Fixed by choosing the
largest scale that fits `min(FB_W, FB_H)` with a margin, which selects
scale 5 (1320 px into 1356 px usable). Not yet re-verified on glass.

Alpha status after this session: blockers 1-4 of
`doc/alpha-checklist.md` are discharged. Remaining: the ultra handshake
(session B), one end-to-end standby measurement, fresh-clone first boot,
and the public-repo posture.

**2026-08-07 DDR at 324 MHz corrupts the display; static-low is off by
default.** [wilkbook / wkelly] Root-caused on glass after a long chase.
324 MHz starves the EBC's real-time phase-data fetch; the controller has
no underrun interrupt, so it fails **silently** — clean dmesg, clean
checkpoints, wrecked panel. One-variable A/B on one image: `mode=normal`
(324) comes up striped with a dark band every time, `mode=noswitch`
(module never loaded, clk left at 1056) comes up clean. **The switch
event is innocent** — instrumented boots show it landing with the refresh
kthread `thr=P` (parked) and the EBC interrupt count frozen — it is the
RATE. **Console traffic is innocent too**: dropping `console=tty0` cut
boot EBC interrupts from ~580 to 79 and changed nothing on the glass
(kept anyway: 7x less panel work, and the U-Boot logo persists as a free
splash). Four latent bugs fixed on the way: the udev coldplug that the
modprobe blacklist never stopped (the switch had been firing 865 ms
BEFORE the guarded window); `use-modules` not importing in a COMPILED
shepherd gexp, which meant `wait-ebc-idle` had never waited and the mode
selector had never selected (every `read-line` call threw into a
`catch #t`); the selector reading `/data` before it was mounted; and
auto-suspend's pause living only on `/var/lib`, which every reflash
wiped. New standing instrument:
`pinenote/tools/optics/belief-vs-glass.sh` renders `/dev/fb0` beside the
camera view — the framebuffer was immaculate in every corrupted frame,
which is what proved the divergence is glass-side. Judge the panel with
it, never by eye off a webcam frame. Power context: the lever was
~24.8 mA quiesced, never confirmed with the reader running, worth 4-10%
of runtime and nothing in suspend. Open: 528 and 780 MHz untested
(`doc/power-management.md`, "the path to pursue").

**2026-08-06 (night, unattended bench session) UART dead, camera good;
v5 built and deployed to os2; the boot-corruption diagnosis moves off
DDR-exoneration.** [wilkbook / wkelly] Operator AFK with a camera box and
a UART cable; half the rig worked. **Camera works** and can watch a boot
(`doc/artifacts/pinenote-bench-rig-20260806/`), but only while the panel
is lit — the frontlight is off through the whole boot window, hence the
new `pinenote-frontlight` service. **UART is dead in both directions**,
localised to the cable from the SoC's own counters (`tx` climbing,
`rx:0`) — the flipped-USB-C-plug signature. Consequence, confirmed by a
test reboot: with no serial there is no slot selection, and the device
returns to os1 in 47 s every time, so **os2 could not be booted at all
this session**. Before overwriting p6 the v3 boot logs were harvested off
it; their service ordering shows `pinenote-usb-acm-gadget` (which mounts
debugfs) starting *after* `pinenote-dmc`, while `ddr-boost` found the
devfreq node in the same second the DMC service reported failure — so
that "FAILED: DDR did not reach 324000000" was about the INSTRUMENT, not
the switch. An 11-agent adversarial analysis then overturned two earlier
conclusions: (1) **"no EBC timeouts" does not exonerate a DDR stall** —
the 25 ms `EBC_FRAME_TIMEOUT` is armed only in the PARTIAL path, a global
arms one 3000 ms wait for ~596 ms of drive, and `INT_STATUS` has no
underrun bit at all, so data starvation is structurally silent (this
retracts the argument used in awake-levers Addendum 5); (2) the fb
**blank is a no-op** on this driver — every EBC hook is gated on
`mode_changed`, which an fbdev DPMS blank never sets — so the DMC
"quiesce" was only ever the fbcon unbind, and no blank-driven wash or
cache desync exists. Also established: `wilkbook_dmc` **cannot defer**
(no clocks/regulators/OPP phandles, synchronous probe, and a failed
switch would unregister the devfreq device), so the late-unguarded-switch
theory is dead. What remains is that the old idle gate was a single
500 ms pair where `ddr-dvfs-test/protocol.md` requires zero IRQ delta
"over several seconds" — a gap exactly the width of a mid-flight global,
whose only IRQ arrives at completion. v5 (`6d64fa34…`, on os2, unbooted)
carries the 2.5 s sustained-quiet gate, devfreq-first verification,
per-step checkpoints (EBC IRQ + both rate sources), the early frontlight,
and a boot-window experiment selector at `/data/wilkbook/dmc.conf`
(`normal` / `noswitch` / `off`) — p7, which os1 mounts at `/home`, so the
next os2 boot is configurable from the rescue slot without a rebuild.

**2026-08-06 (late night) v3 fix image written to os2 — not yet
booted.** [wilkbook / wkelly] The Addendum 5 fix stack (commit
`55c43b0`, each diff adversarially reviewed; the review caught the
EBC-idle gate's global-refresh blind spot — a global's only IRQ is its
completion tick, so "one unchanged sample pair" reads exactly like
idle — and the waveform save/restore self-poisoning) built, closure-
verified (pwrkey-free `koreader-bin l3g2wn5h…`, both hardened daemons,
`panel-wash` in the shepherd conf), extracted with all inspection gates
green, staged, and dd'd to p6 with matching readback SHA `f41cf91f…`.
System `cjqyiy02…`. The `/data/ssh/authorized_keys` migration trap was
live (key not staged, UART disconnected — the image would have booted
dark); staged from os1 (`/home/ssh/` on p7) before the write. Staging
copy kept at os1 `/home/pn-stage-v3.ext4` until the boot proves out.
**v3 boot acceptance**: clean first wash (no console residue; any
`panel-wash:` stderr lines in the reader-session log are diagnostic
gold), awake power tap → banner + suspend with no corruption and no
KOReader reaction (the definitive test — DDR is static so the demoted
collision theory cannot confound), idle-path sleep screen still clean,
`suspend boundary noticed` never fires in ddr-boost's log (it ships
disabled), and the autosuspend log's EBC-gate timeout line never fires
in normal use.

**2026-08-06 (night) v2 DMC image deployed and soaking; two display bugs
found on glass, one diagnosis corrected.** [wilkbook / wkelly] The v2
image (`8c5ae451…`: `wilkbook_dmc` @324, ddr-boost, eviction fixes)
passed boot acceptance: DMC one-shot switched to 324 with the EBC
quiesced, boost proven on real input, bridge-respawn eviction at
0 jiffies (v1 measured 494). Found on glass: (1) **GL16 cold-start
ghosting** — heavy residue that partials and GL16 globals could not
clear; a GC16 wash cleared it on the spot (fix queued: first wash after
boot is GC16). (2) **Post-tap-suspend panel corruption**, initially
attributed to a ddr-boost/suspend collision (the operator challenged
this, correctly): the root cause is **power-key double ownership** —
KOReader maps the pwrkey and upstream `onPowerEvent` ignores
`canSuspend`, so every awake tap fires a KOReader global refresh while
the new press-to-suspend parks the EBC mid-drive ~1.2 s later; the
desynced glass/cache survives GL16 restore washes (they are neutral) and
heals on the next tap's full refresh. The absence of EBC frame timeouts
had already ruled out the DDR-stall mechanism. Full chain + predictions:
`doc/artifacts/pinenote-awake-levers-20260806/README.md` Addendum 5.
Soak proceeds static-324 (boost `enabled=0`). Queued fixes: KOReader
stops opening the pwrkey; autosuspend waits for EBC-idle instead of
`sleep 1`; post-resume wash forced GC16.

**2026-08-06 SSH authorized key moved out of the image — in tree, NOT
deployed.** The reader flavor no longer bakes an authorized key;
`pinenote-ssh-authorized-keys` (new `pinenote/services/ssh-keys.scm`)
installs `/data/ssh/authorized_keys` over `/root/.ssh/authorized_keys`
at every boot (survives reflashes; image stays generic —
`doc/networking.md` §4.1). Offline evidence: reader closure builds, the
built sshd_config honors `.ssh/authorized_keys`, `/etc` in the image
carries no key, the one-shot is in the shepherd graph. **MIGRATION TRAP
for the next os2 deploy**: an image built from this tree has no
reachable root SSH until the key is staged — run
`mkdir -p /data/ssh && cp /etc/ssh/authorized_keys.d/root
/data/ssh/authorized_keys` on the *currently deployed* image (or write
the key over the ACM console) **before** deploying, or SSH goes dark
and the consoles are the way back in.

**2026-08-06 vanished-input-device eviction (backfilled 2026-08-06 from
commit records).** Destroying a uinput device (as an orientation-bridge
respawn does) left its fd permanently select-readable with `ENODEV`, and
both input-watching daemons (autosuspend, ddr-boost) could spin at 100%
CPU — measured live by the ddr-boost acceptance test. Both now evict the
fd and rebuild the select set; a vanish event no longer resets the idle
timer. Commit `db71109`.

**2026-08-06 DDR DVFS lands in tree (backfilled 2026-08-06 from commit
records).** `wilkbook_dmc` (minimal devfreq driver over the proven DRAM
SIP, powersave governor floors at 324 MHz, never above the boot rate) plus
the `pinenote-dmc` one-shot (EBC quiesced before the probe-time switch)
and the input-driven `ddr-boost` min_freq daemon. In tree, **not yet in
the deployed image**. Commit `7b0251b`.

**2026-08-06 deep-suspend rail-floor audit: 20.6 mA, peripherals
exonerated (backfilled 2026-08-06 from commit records).** Normal-path deep
20.6 mA vs 22.7 mA with touch/pen/BT unbound and wlan0 down — same boot,
900 s windows. Bypassing driver suspend hooks makes things *worse*; the
20.6 mA is PMIC quiescent + always-on rails + DDR self-refresh + bl31
(ultra-suspend territory). Bonus: bl31 preserves a non-boot DDR rate
across suspend/resume (324 survived both cycles). Commit `981afae`,
`doc/artifacts/pinenote-awake-levers-20260806/`.

**2026-08-06 first-ever DDR rate change on this board; 324 MHz saves
~24.8 mA (backfilled 2026-08-06 from commit records).** Supervised
`ddr-dvfs-test` SET_RATE 324: MCU path, 106.8 ms, memory intact, EBC
quiesced for every switch. Firmware table 324/528/780/1056 (v0x101).
Measured quiesced@324 174.4 mA vs quiesced@1056 199.2 mA, same-boot
battery-drain windows. Rules that held: never switch with the EBC active;
never target above the boot rate. Commits `5197aab`/`1bd1855`,
`doc/artifacts/pinenote-awake-levers-20260806/`.

**2026-08-06 vdd_cpu auto-PFM: ~30 mA off the clamped idle floor;
174 → 156.9 mA realized (backfilled 2026-08-06 from commit records).** The
TCS4525 CPU buck powers on with force-PWM set and nothing in the ecosystem
ever clears it. Runtime i2c ABA with dead-man revert measured ~30 ± 8 mA;
baked into `linux-pinenote-7.0-vdd-cpu-auto-pfm.patch` with the
`fan53555_set_mode` NORMAL-branch fix it requires. Boot acceptance PASSED
on image `1a582179…`: opmode "normal" from DT, survives deep
suspend/resume; settled reader idle 156.9 mA. Commits `881224f`/`689a632`,
`doc/artifacts/pinenote-awake-levers-20260806/`.

**2026-08-05 DDR SIP probe: firmware says GO; TCS4525 landmine recorded
(backfilled 2026-08-06 from commit records).** The read-only
`ddr-sip-probe` module got `DRAM_GET_VERSION → SUCCESS, v0x101` from bl31,
turning the DDR DVFS port from speculation into justified work. Research
for the vdd_cpu A/B found `fan53555_set_mode()`'s NORMAL branch writes the
ACTIVE voltage selector on TCS4525 — −400 mV on the CPU rail in one write
(upstream-register item 10; never "test" the broken path on hardware).
Commit `9a5432a`.

**2026-08-05 cpuidle works and does not help; 92% of awake draw is a
static floor (backfilled 2026-08-06 from commit records).** First cpuidle
driver ever to register on this SoC (DT `idle-states` node, PSCI): cores
idle 31–72% of wall time — and the same-boot A/B says **2.1 mA**. A domain
teardown attributes only 14 mA of 177.5 to anything switchable (Wi-Fi
10.3, KOReader 4.1, gadget 2.0, panel 0.0): 163.1 mA is an irreducible
static floor. Deep suspend verified safe with idle-states present, 4/4
cycles. Commits `036dae0`/`b93fd90`,
`doc/artifacts/pinenote-cpuidle-psci-20260806/`.

**2026-08-04 power-button short-press suspend (backfilled 2026-08-06 from
commit records).** A tap now suspends immediately; a long hold is left to
the PMIC hard power-off. Post-resume the daemon drains the input queue and
ignores the button for a grace period so the wake press cannot re-suspend.
Devices are found by name, never by event number (numbering moved across a
power cycle this session). Also fixed a cdata-vs-`math.floor` crash that
had killed the daemon on the first real press. Commit `ff2904a`.

**2026-08-03 SC7A20 autorotation survives deep suspend — FIXED, 6/6
cycles.** The last open blocker from the deep-suspend program is closed.
Image `a3ea6a2d2249447f8ece69889758e3ece5495fbb3940b0d3e7c4d157a8a599aa`
(475,028 x 4096, kernel `vhb7v5fr…`, system `cqvbxca4…`) deployed to os2,
readback verified. Six consecutive `deep` cycles each measured 10
data-ready interrupts per 10 s window on **both** sides of the suspend —
exactly the configured 1 Hz ODR — with no storm, `ddepth=0`, and the
polarity register holding `0x2` throughout. Session total:
`success=7 fail=0`.

Both defects were in our own PM patch, and the first hid the second:

1. **Read-after-clobber.** `st_sensors_resume()` tested `->hw_irq_trigger`
   *after* `st_sensors_reinit_hw()`, which clears it via its inherited
   "disable DRDY" step. The re-arm never ran, so the storm happened
   anyway — `irq 73: nobody cared`, count 116 → **100,117**, then
   `Disabling IRQ #73`.
2. **Interrupt polarity never restored.** Fixing (1) removed the storm and
   produced a *silent* failure that looks healthier: no dmesg error,
   `ddepth=0`, every control register correct — and **zero** interrupts,
   with the chip sampling into an overrun. The active-low bit is written
   only in `st_sensors_allocate_trigger()` at probe, so the chip returns
   at its active-high reset default against a `LEVEL_LOW` GPIO. Proven
   live before writing code: with `0x25=0x00` the IRQ counted 0/5 s;
   writing `0x02` by hand restored exactly 1 Hz.

   The same inversion explains the burst-then-silence seen in the
   (1)-only run (count 65 → 7488, then flat): at reset the line idles low
   = *asserted* to a `LEVEL_LOW` GPIO (burst); once data arrives it goes
   high = *de-asserted* (silence).

**Rotation confirmed on glass** (Will, 2026-08-03): rotated after a deep
cycle, the screen follows. That was the one claim the harness could not
make — it proves delivery of the interrupt, not that the bridge consumes
it and the reader reorients. The full path is now proven end to end:
chip → DRDY → GPIO → threaded handler → iio buffer → orientation bridge →
uinput → KOReader. Detail and reusable instrument notes:
`doc/artifacts/pinenote-sc7a20-resume-fixed-20260803/`.

**2026-08-03 unplugged soak, working daemon: clean — no spurious wakes
(backfilled 2026-08-06 from commit records).** On image `7bb55c2f…`,
unplugged, `idle=60 backstop=240`: `success=2 fail=0`, both sleeps ran
their full armed duration (240 s and 241 s) — **nothing wakes the device
spuriously on battery** at this dwell length, the open question the
8.6-day standby figure rested on. Duty-cycle average 64.4 mA at ~20 %
awake (naive model 49.8 mA; the ~30 % gap is per-cycle resume cost —
Wi-Fi re-association, banner, full refresh — which argues for the long
300 s default). Not concluded: one pre-suspend `nobody cared` + call
trace at 108.9 s uptime on this st_accel-PM image. The week-scale soak
remains open. Commit `9c4795f`,
`doc/artifacts/pinenote-autosuspend-soak-unplugged-20260803/`.

**2026-08-03 auto-suspend actually works now.** Image
`7bb55c2f940d89f716cf87de163dedb46a9cf693fd73a68e71a9eb6b0991a717`
(475,027 x 4096) deployed to os2, readback verified. Carries the three
fixes that turn the daemon from never-suspending into functional:

1. **`write_file(udc, "\n")`** — Lua's `io.write("")` issues no write
   syscall, so the gadget unbind never reached configfs and dwc3 vetoed
   every attempt. This is why `suspend_stats` read `success=0 fail=10`
   while every hand-written *shell* test slept correctly: `echo "" >`
   emits a newline. Verified: success went 0 → 19.
2. **Sleep-banner save/restore** — drawing it destroyed the pixels under
   it and the post-resume refresh repainted the banner. Now the band is
   stashed and written back before the refresh. Confirmed on glass.
3. **`/var/lib/pinenote` created by service activation** — it did not
   exist on a fresh image, so the documented runtime tunables were
   unusable without a manual mkdir.

*All three verified inside the built artifact before staging*, and the
activation was confirmed in the system's activation fragments (the
top-level `activate.scm` is only a loader — grep the fragments it
references, not the loader).

**Still no evidence about spurious wakes on battery.** *[superseded
2026-08-03, same evening: the unplugged soak ran clean — see the entry
above (`9c4795f`); only the week-scale soak remains open.]* Every soak so far
measured a daemon that never suspended, so the 8.6-day standby figure is
still an extrapolation from hand-run dwells. The unplugged soak is now
worth running and is the next thing to do; read
`suspend_stats/{success,fail,last_failed_dev}` first, not durations.

**2026-08-03 charging inhibit deployed to os2.** Image
`fe48dfd72220d55a010447b8f7f4896a8fbc0edca8dbc7e6850de26ed36e3985`
(475,027 x 4096). Full protocol from os1, readback verified. Auto-suspend
no longer runs while plugged in — which the soak showed is **required**,
not cosmetic: every sleep aborted after 5-6 s while charging (8/8), so the
device would otherwise thrash a suspend/resume cycle every 65 s forever.

*Staged-image cleanup*: 38 superseded images removed (~70 GB), keeping only
the current and previous in each location, both hash-verified. Device
`/home` went from 8.7 G to 50 G free. Rebuildable from Guix, so nothing of
value was archived. **Keep it to two from here on** — the previous image is
the rollback, everything older is noise.

**2026-08-03 AUTO-SUSPEND IS LIVE ON os2.** Image
`8c1a24f49b6d476032751214c0bdc29dae5a34a767f23c827f1ccfb601dd1dd7`
(475,026 x 4096), system `wl9prfi6wwj98d4l5i4bi4bdd6gp4bbw-system`.

```
* Status of pinenote-autosuspend: running
[autosuspend] watching 8 input devices, idle=300s backstop=900s overlay=true
```

The device now sleeps to `deep` after 5 minutes without input and wakes on
the power button, showing your page with a
`SUSPENDED - PRESS POWER TO RESUME` banner instead of a white void. On
measured numbers this is worth ~7x (172 mA awake vs 19.3 mA deep).
**[Figures superseded 2026-08-06: awake reader idle is now 156.9 mA
after vdd_cpu auto-PFM, and the deep rail-floor audit reads 20.6 mA —
see "Current state" at the top.]**

*Tunable two ways*, as designed: build-time fields in
`pinenote/services/autosuspend.scm`, and `/var/lib/pinenote/autosuspend.conf`
re-read before every idle wait (`idle=`, `backstop=`, `enabled=0`) with no
restart.

*Practical consequence for future sessions*: **ssh is now intermittent.**
The device is only reachable for `idle` seconds after the last input, and
Wi-Fi re-association eats several of those after each wake. To work on it,
write `enabled=0` to the runtime config first. UART remains reachable
whenever the device is awake and gives **passwordless root**, which is the
recovery channel if auto-suspend ever misbehaves.

*Not yet proven*: a long unattended soak. The daemon has survived several
cycles including RTC-backstop wakes, but "sleeps correctly on a shelf for a
week" — the test that would validate the 8.6-day standby end to end — is a
day of wall clock and has not been run.

**2026-08-02 DEEP SUSPEND WORKS. Rung 3 PASS.** Artifact:
`doc/artifacts/pinenote-deep-suspend-WORKS-20260802/`.

```
RESUMED rc=0 asleep=60s
VERDICT control=46 A(blanked)=46 B(unblanked)=46 C(ioctl)=1 D(after-ioctl)=46
TPS VCOM pre=8f post=8f
```

Entered `deep`, slept 60 s, woke on the armed RTC alarm, and came back with
a fully working display at both CRTC states. The firmware boundary tells
the story — same device, same bl31, hours apart:

| | `PM-STATE` |
| --- | --- |
| before activation (hung forever) | `mem (ultra: 0, mem: 1, cfg: 0x0)` |
| after activation (woke) | `mem (ultra: 0, mem: 1, cfg: 0x5ec)` |

Two independent proofs it was a real power-down: the **kernel monotonic
clock froze** (1.08 s kernel across 60 s wall — s2idle runs matched exactly,
so a short kernel delta is the signature of success, not an early wake),
and **OP-TEE re-initialised secondary CPUs** on resume. VCOM survived at
`8f`. Reader restored clean.

*Not claimed*: battery life is unmeasured (60 s proves mechanism, not the
multi-day target); only the RTC wake source is proven; TPS `ENABLE` moved
`2f → 20` and was not restored by our PM pair (display works via runtime
PM, but it differs from os1 and is worth understanding before long
dwells); ultra-suspend remains unadopted; and this is one cycle — repeat
before trusting it.

**2026-08-02 BSP SIP activation is LIVE and BOUND on os2 — deep's missing
configuration is now actually being sent.** Image
`d604ff98d454a5cd89c230363cace1eaf785b71ccfbbae0be03db7de477f78af`
(475,000 x 4096), system `p4mpqkidq9g8ppdx0mfb9iadf44wpzz2-system`.

```
[0.267551] rockchip-suspend-mode rockchip-suspend: BSP suspend policy activated
driver rockchip-suspend-mode -> device rockchip-suspend   (BOUND)
"DORMANT policy core bound": 0 occurrences
```

That log line only exists on the activation path, and probe returns
`-ENODATA` if sleep-mode/wakeup are absent — so a clean bind proves the
policy reached the driver and the four probe-time SIP calls were emitted
(`0x01 0x5ec`, `0x02 0x10`, `0x04 0 0xffff`, `0x05 0 0`). Linux reads the
node exactly as intended:

| property | value | expected |
| --- | --- | --- |
| `rockchip,sleep-mode-config` | `0x000005ec` | ✔ |
| `rockchip,wakeup-config` | `0x00000010` | ✔ |
| `rockchip,sleep-debug-en` | `0x00000000` | ✔ |
| `compatible` | `rockchip,pm-rk3568` | ✔ |

**No regression on the normal path**, which was the gating concern since
activation adds a `.prepare` callback and regulator suspend programming to
every boot: reader healthy, `defio_delay_ms=250` persisted, and the panel
paints a full 46-frame pass for both checker and white fills with
`fb-rows-changed=120/120`. The only dmesg warning is the known benign
`dwc3 … failed to enable ep0out`.

*Booted to os2 by driving the U-Boot menu over UART* (two DOWN + ENTER),
no hands on the device.

**Still unproven: firmware acceptance.** bl31 has now been handed the
configuration, but nothing has attempted `deep` yet. That is the next
step, and its realistic failure mode is still a hang — with UART live and
`no_console_suspend` deployed we would this time capture the trace through
`dpm_suspend` and read bl31's `cfg:` word, which was `0x0` on 2026-08-02
and should now be non-zero.

**2026-08-02 RUNG 2 PASSES. Post-resume damage paints; the "dead-write
window" was substantially our own probe.** Artifact:
`doc/artifacts/pinenote-suspend-ladder-20260802-discriminator/`.

```
VERDICT control=46 | blanked black=0 checker=46 | unblanked black=0 checker=46
ACCEPTANCE: post-resume fb writes DO paint
```

A full 46-frame pass at **both** CRTC states after resume. Gates all open
(G1 `state=0`, G2 plane holds `fb=38 [fbcon]`, G3 no master), **zero
regulator drift, zero TPS drift**, VCOM intact, no poison/timeout/BUG.
Operator confirmed on glass: three checker bands at rows 100/560/860 of
1404 — 7 %, 40 %, 61 % down the panel, exactly the predicted geometry —
while the two black bands were invisible.

*Why black read zero, proven the same session* with the reader restarted
so the region held non-black content: the **same black probe at the same
row** drove 46 frames and changed the framebuffer. Black is not dropped
intrinsically — only when the underlying content is already black, which
is `rockchip_ebc_plane_atomic_update()`'s drop-on-match working as
designed. Post-resume the panel showed the black console background, so
writing black was a genuine no-op.

*Not established*: whether the damage-baseline fix was **necessary**. This
run cannot separate "the fix cured a real stale baseline" from
"black-on-black was always the artifact" — both predict it, and a
distinctive fill was never run on the old image. The fix stays regardless:
`final_atomic_update` was genuinely `kmalloc`'d and left uninitialised on
the resume path while every other branch seeds it, and it is the diff
baseline.

*Instrument fixed so this cannot recur*: `mmap-band-probe.lua` now reports
`fb-rows-changed=N/120` and flags `[NO-OP WRITE]`. Demonstrated live — the
same checker twice gives 46 then 0 frames with 0/120 rows changed, which
under the old probe was indistinguishable from a dead pipeline. **Every
probe in this program before today wrote `0x00`.**

*Ladder state*: rungs 1 and 2 PASS on s2idle. Rung 3 (`deep`) remains
blocked at bl31 with `cfg: 0x0` — an activation design decision, not a
boot.

**2026-08-02 deploy to os2: `pinenote-reader-PNGuixRoot-20260802.ext4`,
SHA-256
`190321cda1324b8c78e241658f36db0d6a36df348ef22d03af5a00ee9e34020d`,
1,945,591,808 bytes = 474,998 × 4096.** Full protocol from os1: staged
SHA verified against the host artifact; preconditions re-checked
fail-closed immediately before `dd` (root=p5, p6 unmounted, staged SHA,
size a 4096 multiple, image fits the partition); readback of exactly the
written range matches. Note the block count is **474,998** here, not the
474,999 of the previous image — compute it from the artifact, never reuse
the constant.

Carries two changes, both byte-verified inside the artifact before
staging: (1) the **damage-baseline fix** — `rockchip_ebc.ko` in the
initrd is byte-identical to the cross-build (`9035901b…`) and **differs
from the deployed module** (`a6fe799e…`), confirming new code rather than
a stale rebuild; (2) **`no_console_suspend`**, confirmed present in the
embedded `extlinux.conf` cmdline, so the next deep attempt can capture
the `dpm_suspend` phase the runtime knob could not hold open.

Superseded image preserved as `…-20260801-deployed-5493d994.ext4`.

**Next session, one boot, two questions.** Re-run the rung-2 ladder, and
fold in the discriminator that costs nothing: post-resume, write a band of
a **distinctive** value rather than `0x00`. Every probe so far wrote
black, so a white/patterned band separates "drop-on-match, now fixed"
from a further cause. Keep the pre-suspend CONTROL gate — it is what makes
a FAIL trustworthy.

**2026-08-02 (offline code-read) the post-resume dead-write window has a
named defect: the resume path never restores the damage-comparison
baseline.** `ctx->final_atomic_update` is the buffer the blitters write
into and diff against, and
`rockchip_ebc_plane_atomic_update()` **drops any area whose blit reports
no change** — `list_del` + `kfree`, silently: no error, no frame, nothing
logged. It is `kmalloc`'d, **not** `kzalloc`'d. A system resume is the one
path that reaches the thread's outer-loop init with a *brand-new* ctx
(`crtc_atomic_check` reallocates whenever `mode_changed`, which
`drm_atomic_helper_resume`'s duplicated-state commit always sets). Both
non-suspend init branches seed the buffer — `0xff` on first run,
`suspend_next` on re-init — and **only the `suspend_was_requested` branch
did not**. So after every resume, damage was diffed against uninitialised
memory.

*Fix*: restore it from `suspend_next`, the same source as `ctx->final` —
the panel shows `suspend_next` after the restoring global refresh, so that
is the correct baseline. Gated by a new mutation-tested structural check,
`validate-ebc-resume-baseline-hunk.sh`, wired into `make suspend-check`.

*Ruled out by the same read, each with a reason*: ctx **is** correctly
reallocated and propagated (thread's cached ctx and the plane's commit ctx
are the same object — `drm_atomic_get_plane_state()` pulls the plane's
CRTC into the state, so `drm_atomic_get_new_crtc_state()` is never NULL);
the thread parks at the **bottom** of its outer loop so unpark re-reads
ctx as designed; `limit_fb_blits` defaults to `-1` (unlimited) and is
never set; `worker_available` gates only the barrier ioctl, not refresh.

*Honesty note*: this defect is certain and independently worth fixing, but
it is **not proven** to be the whole explanation — a total zero requires
every damage rect to match the stale buffer, and `ctx_alloc` runs *before*
the old ctx is freed, so the new buffer does not simply inherit the old
contents. The cheap discriminator on hardware is to write a band of a
**distinctive** value post-resume instead of black (every probe run so far
wrote `0x00`), which distinguishes drop-on-match from a further cause.
The rung-7a harness cannot settle it: its `commit_damage()` appends areas
directly and never calls the blitter, so drop-on-match is not executed
offline (recorded in `doc/testing.md`).

**2026-08-02 (offline) the "fbdev re-commit fix" was NOT written — its
premise is contradicted, and the IRQ unit was being misread.** Three
independent facts kill the os1-oracle diagnosis ("our fbdev never
re-commits, so the ctx stays torn down"): (1) the ctx **is** reallocated
at resume — `rockchip_ebc_crtc_atomic_check` allocates whenever
`mode_changed`, which the duplicated-state commit sets, and the
`ctx_release`/`ctx_free` in dmesg is the *old* ctx being dropped by that
very allocation; (2) the refresh thread parks at the **bottom** of its
outer loop, so unpark → loop top → fresh ctx read, exactly as designed;
(3) the 2026-08-02 run **forced** a re-commit (unblank drove
`crtc_active` 0→1, `atomic_enable` ran) and still painted nothing.

**Instrument correction, verified from the register programming**
(`doc/testing.md`, "EBC IRQ counts"): a **global** refresh writes one
`EBC_DSP_START` with `DSP_FRM_TOTAL(num_phases-1)` and takes a single
completion — **1 IRQ total**. A **partial** refresh drives frame-by-frame
with its own `reinit_completion`/`wait` per frame — **1 IRQ per frame**.
So the suspend/resume cycle's "exactly 2 frames", read on 2026-08-01 and
again on 2026-08-02 as near-total inactivity, is in fact **two successful
global refreshes**: the pre-park off-screen wash and the post-resume
restore. The global path *works* after resume. This also explains the
`suspend_was_requested` → `do_one_full_refresh` → global → flag-cleared
sequence running exactly as intended.

**Residual, re-narrowed**: after resume the **partial/damage** path
produces nothing while the **global** path works. Not commits, not ctx
allocation, not the thread's park bracket. Next step is *not* another
boot: it is either code-reading the queue→thread handoff
(`plane_atomic_update` splices into `ctx->queue` then
`wake_up_process`), or extending the harness to actually run the thread
body — see the new harness limitation recorded in `doc/testing.md`.

**2026-08-02 rung 3 `deep` on os2: HARD HANG, no wake, recovered by
power-cycle to os1.** Artifact:
`doc/artifacts/pinenote-deep-suspend-hang-20260802/`. Operator-authorised
override of the rung-2-first rule, on the correct premise that deep is
already hardware-proven on this device (os1 oracle, 2026-08-01). The
evidence ends at the suspend write:

```
[01:38:15] CONTROL PASS: 38 frames before any suspend
[01:38:22] alarm armed=1785634761 now=1785634701 (+60s absolute epoch)
[01:38:22] --- RUNG 3: echo mem > /sys/power/state  (mode=deep)
```

`rung3.err` 0 bytes, no post files, no `COMPLETE`. The +60 s RTC alarm
did not wake it. **Deep is not a display problem** — it never reached
resume. Hardware and firmware are exonerated by the os1 precedent on the
same bl31 and DDR; the divergence is our 7.0.11 + DT/defconfig +
PREEMPT_RT stack versus os1's 6.12 BSP kernel.

*Leading hypothesis, consistent with the design and now measured rather
than assumed*: os1's BSP kernel configures the Rockchip suspend mode via
the BSP SIP call before entering deep, and **our tree deliberately
compiles that out** (activation hard-off, no `rockchip-suspend` DT node
at all). bl31 therefore gets no suspend-mode configuration and no
wake-source arming. This is the strongest evidence yet for why the
dormant BSP SIP stack exists — and it is **not** activation permission:
the reviewed active DT policy, real coordinator providers, and the
rail-kill wake collision all remain open. Not excluded by one run: RTC
alarm not armed in firmware across deep, wake routing through the
`vcc_3v3_pmu`-fed GPIO0 bank, or a hang on entry that never slept.

**Attempt 2 the same night, with UART: hung identically — and the trace
answers it.** `console_suspend=N`, live capture at 1500000:

```
[  439.643831] PM: suspend entry (deep)
[  439.651652] Freezing remaining freezable tasks completed (elapsed 0.001 seconds)
v2.3():v2.3-210-g4af361e4c:zwx
PM-STATE: mem (ultra: 0, mem: 1, cfg: 0x0), pmic: 0x14, 0x25
abcdeghij7
```

The last three lines are **bl31, not Linux**. So Linux hands off cleanly,
the BSP ATF is reached and runs its full sequence — a hang on the *entry*
path is excluded. **`cfg: 0x0` is the finding**: bl31's suspend
configuration word is zero, i.e. Linux sent it no suspend-mode
configuration and no wake-source arming — exactly what our tree does on
purpose. The hypothesis above is now **firmware-sourced measurement, not
inference**. Still not activation permission.

***The UART works — that long-standing "receives nothing from ttyS2" claim
is RETRACTED.*** It was a test artifact that cost two sessions of blind
protocol. Validated both directions at 1500000. Two causes: the
device-side `/dev/ttyS2` termios defaults to **9600** and on an 8250 the
console shares the port divisor (so output left at 9600 while we listened
at 1500000); and every earlier test was a **passive listen after boot**,
when the console is idle — which cannot distinguish a dead cable from a
quiet one. **Working method: transmit a marker from the device while
sweeping the host baud.** Passive captures yield runs of `0x00`, which
reads as "broken cable" and is not. Console-free is now an option, not a
necessity — but **deep must never run without UART**.

*Code change from this*: `no_console_suspend` added to
`pinenote-kernel-arguments`. Runtime `console_suspend=N` suppresses
console suspension but does **not** hold the 8250 port up through its own
`dev_pm_ops` — that run still lost every `dpm_suspend` message, so the
trace jumps from freezing straight to bl31. Gated: `make kernel-drv` and
a full `guix system build` green, arg verified present in the built
closure. Not yet deployed.

*Evidence survived the hard power-cut*: Guix's `%base-file-systems`
declares no `/tmp`, so os2's `/tmp` is on the ext4 root. It was recovered
from os1 by mounting `/dev/mmcblk0p6` read-only (`ro,noload`) and
unmounted cleanly. **An os2 hang is not an evidence loss** — worth
remembering for every future session.

**2026-08-02 suspend ladder on the resume-barrier image: rung 1 PASS,
rung 2 mechanics PASS, G1 fixed on hardware, acceptance still FAIL — and
the four-gate model is wrong.** Full artifact:
`doc/artifacts/pinenote-suspend-ladder-20260802/`.

*What improved, and is now hardware-proven.* `fb0.state=0` after resume —
the fbdev client's deferred un-suspend now completes, which is exactly
what the barrier was added for. Suspend/wake mechanics clean again (45 s,
rc=0, on-schedule RTC alarm, gadget quiesced). **Regulators show zero
drift pre→post, and so does the TPS65185** (VCOM `03: 8f` intact,
`ENABLE 2f` = rails properly down). The 2026-08-01 "+1 enable" and the
stuck `3f` are both gone.

*What did not.* Post-resume damage still paints 0 frames, and **every
gate reads open at every stage**: G1 `state=0`, G2 plane holds `fb=38`
`[fbcon]`, G3 no master, `crtc active=1` after unblank, thread idle. The
post-unblank state is *identical* to the pre-suspend state that painted
38 frames. G1 was real and is fixed; it was not the cause. Reader restart
recovers fully (+192 frames, no reboot) as before.

*Methodology failure, caught mid-session.* The first ladder run used
`dd`/`write()` to `/dev/fb0` and reported ACCEPTANCE FAIL. **That verdict
was void**: on a fully healthy device with no suspend involved, the same
probe changed the framebuffer (md5 `f3eb15e1`→`06b5a22c`) and produced
**zero frames**. The fbdev `write()` path generates no damage that
reaches this panel; only `mmap` does (38 frames = one pass). The
2026-08-01 "all four damage probes are dead" result was `write()`-based
too and **should be assumed to have measured the same dead instrument**;
the surviving result from that night is the GLOBAL_REFRESH ioctl's +47
frames, which used a different path. The ladder script now **gates on a
pre-suspend CONTROL probe and aborts if it paints 0** — the second run
passed that gate 60 s before the post-resume probes read 0, which is what
makes its FAIL trustworthy. New instrument:
`pinenote/tools/ebc-damage-probe/mmap-band-probe.lua`.

*Surviving lead for the offline pass.* `rockchip_ebc_plane_reset` →
`ctx_release` → `ctx_free` at resume: `drm_atomic_helper_resume()` calls
`drm_mode_config_reset()` before committing the duplicated state, so the
DRM-visible plane fb is restored by that commit **while the driver's own
refresh context is torn down and rebuilt.** Read that ctx lifecycle next.
Rung 3 (`deep`) NOT run — forbidden by rule until rung 2 passes.

**2026-07-30 EBC barrier campaign: PASSED. The generation barrier is
hardware-proven, and the starvation cause is now measured rather than
inferred.** Same unchanged 2026-07-28 image on os2 (system generation
`jswc6b1vhx07z7c7llgrns86wnqkkdgb-system`, root on `/dev/mmcblk0p6`); no
rebuild and no write. Run under the corrected procedure in
`doc/hardware-deploy.md`:

```
pinenote-ebc-sleep-frame-test: sleep frame is visible; press Enter on /dev/tty to restore (generation 1)
pinenote-ebc-sleep-frame-test: exact snapshot restored (generation 2)
EXIT=0
```

*Acceptance, all five criteria.* (1) The card rendered — the X was plainly
visible on the glass, and its 1-px border is occluded by the bezel, not
missing (see the bezel measurement below); framebuffer content was
independently proven byte-exact. (2) Two nonzero generations, 1 and 2.
(3) `exact snapshot restored` with the second barrier completing; note this
was confirmed by the tool's own report and the subsequent normal repaint —
a separate naked-eye confirmation of the restored pre-run image was not
taken. (4) Exit 0. (5) The reader restarted and repainted normally, settling
to a quiescent EBC (thread `I`, 0 IRQ across consecutive 5 s windows).
Across the whole session `dmesg` gained four lines, all benign fbcon
bind/unbind transitions, and every failure grep was zero.

*The damage producer is now measured, not hypothesised.* A clean A/B taken
before the run, with the reader stopped:

| | fbcon bound | fbcon unbound |
| --- | --- | --- |
| `/sys/class/graphics/fbcon/cursor_blink` | **1** | n/a (`-1`) |
| EBC IRQ | **63 Hz** | **0 Hz** |
| `ebc-refresh` thread | **`D`** | **`I`** |

`herd stop reader-session` alone reproduces the wedged state — 63 Hz and a
`D` thread, matching 2026-07-29 exactly — and unbinding fbcon collapses it to
*exactly zero*. The blinking console cursor was the entire damage source.
This supersedes the 2026-07-29 entry's hedge that the producer was only a
leading hypothesis.

*The 2026-07-29 panel anomaly is closed.* While the diagnostic was parked at
its acknowledgement prompt, `/dev/fb0` hashed
`7d94be719f99c6684485f9f073d46c1a68fbdbe8b3461f62b7ad389bcf6acd97` — byte-for-byte
the offline reference emitted by `pinenote/tools/ebc-barrier/ebc-card-reference`
from the same `ebc_barrier_paint_card()` the device runs. The paint reaches the
framebuffer correctly; last session's blank panel was the starved refresh never
driving it, not a paint or damage defect.

*Measured: the bezel occludes the outermost 4–10 px (~0.5–1.1 mm) on all
sides.* A probe card of concentric 4-px rings at insets 0, 10, 25, 50, 100 and
200 px showed five rings with bare glass outside the outermost visible one:
the inset-0 ring (pixels 0–3) is hidden, the inset-10 ring is not. So the
campaign card's 1-px border at pixel 0 renders and is simply not visible.
Useful beyond this campaign — it is the reader UI's usable-area inset.

Suspend remains disabled; none of this is suspend permission.

**2026-08-01 (offline source pass, no device) the dead-write window has
four candidate gates, all silent; G1 is unconditionally wrong and is
fixed in the driver.** Reading the 7.0.11 submission path end to end
(`drm_fb_helper.c`, `drm_damage_helper.c`, `drm_client_event.c`,
`drm_client_modeset.c`, `drm_auth.c`, `fbcon.c`) turned the previous
entry's single suspected gate into four that each produce the identical
external signature — write accepted, `fsync` 0, no frame, empty dmesg.
See `doc/power-management.md` ("Post-resume dead-write window") for the
table; in short: **G1** `drm_fb_helper_damage_work`'s FBINFO_STATE gate
(the previously suspected one, confirmed as real and reachable);
**G2** `drm_atomic_helper_dirtyfb` committing an *empty* state when no
plane holds the fbdev fb; **G3** any DRM-master holder making
`drm_fb_helper_blank`/`set_par` silently no-op (they discard the
`-EBUSY`); **G4** fbcon unbound, so nothing repaints after
`fb_set_suspend(0)`.

Two results matter beyond the fix. First, **the probe ladder we ran
could not have named the gate** — all four return success. Second,
**our own diagnostics can close G3 on themselves**: the first opener of
`/dev/dri/card0` becomes master, so a tool that opens the card to issue
an ioctl invalidates every unblank and `set_par` it subsequently tries.
The previous entry's `probeC-setpar` result is therefore retired as
evidence about G2. New standing rule, and a new read-only instrument:
`pinenote/tools/power/fb-damage-gates.sh` reads all four gates in one
shot and deliberately opens no DRM node.

The G1 fix is in the forward-port patch: `rockchip_ebc_resume()` now
calls `drm_fb_helper_set_suspend_unlocked(helper, false)` a second time
after a successful `drm_mode_config_helper_resume()`, whose opening
`flush_work(&fb_helper->resume_work)` is the barrier the vanilla resume
path never had — the deferred un-suspend completes before resume
returns, and costs nothing when the first call already took the console
lock. Ordered after `rockchip_ebc_wake_worker()` so released damage has
a live consumer. G2/G4 are deliberately *not* fixed in the driver:
re-committing a modeset in resume would override a user's pre-suspend
blank, and fbcon-unbound is a design property of the reader image. Gates green: `make kernel-drv`,
`make kernel` (cross-build clean — the compile gate for the
`CONFIG_DRM_FBDEV_EMULATION` branch the host harness cannot reach), and
the full `ebc-logic` suite. **Not hardware-verified.** Next session: run
`fb-damage-gates.sh` once after resume, before anything else touches the
display.

**Deployed to os2 (2026-08-01, late).**
`pinenote-reader-PNGuixRoot-20260801.ext4`, SHA-256
`5493d9941147652d054c3ab63715dc667b143b57eeaba98ee9e725e16970ca7b`,
1,945,595,904 bytes = 474,999 × 4096. Full protocol from os1: staged SHA
verified against the host artifact, preconditions re-checked fail-closed
immediately before `dd` (root=p5, p6 unmounted, staged size and SHA),
readback of exactly the written range matches. `fb-damage-gates.sh` and
`pm-ground-truth.sh` are staged in `/home/user` on os1, SHA-verified. The
fix was byte-verified inside the artifact before staging: the
`rockchip_ebc.ko` inside its initrd is byte-identical to the freshly
cross-built module (`a6fe799e…`), and references
`drm_fb_helper_set_suspend_unlocked`, which the previous build's module
does not reference at all. The image it supersedes on os2 is preserved
as `…-20260801-deployed-8e302e48.ext4`. Device address note: the PineNote
took a **new DHCP lease, 192.168.86.145** (not the `.141` in
`doc/device-runbook.md`); resolve it via `pinenote.local` rather than
assuming the old address. The host-key warning that produced was benign
and was resolved by comparison, not bypass — the key offered at `.145` is
byte-identical to the one recorded for `.141`, and the stale `.145` entry
belonged to a different device that previously held the lease. `fb-damage-gates.sh` needs no
image — it is a read-only shell script, copied at session time like
`pm-ground-truth.sh`, and runs on whatever is already on the device.

**os1 gate reading taken during the deploy (read-only, os1 healthy), and
it corrected the write-up.** The probe runs correctly on real hardware.
os1 reads: G1 `state=0`; G3 **`systemd-logind` holds master** on the EBC
card; G2 plane[32] → **`fb=39`, allocated by gnome-shell** (fbcon's
framebuffer is `fb=37` and is *not* on the plane); G4 `vtcon1 bind=1`
— fbcon is **bound**. So the claim that "fbcon-unbound is why os1 never
shows this" is wrong: os1 has fbcon bound and still never exercises the
path, because a KMS compositor owns the plane. Both G2 and G3 are
permanently closed on os1 *for fbdev*, and the panel is fine anyway.
**Standing limit, now recorded in `CLAUDE.md`: os1 is not an oracle for
the fbdev damage path.** It answers hardware questions; it cannot answer
"should this fbdev write have painted", because it never makes one. The
probe was improved in place to correlate the plane's fb with its
allocator, so this reads as one line instead of being inferred.

**2026-08-01 (late evening) discriminator pass: the residual is
localized to silent damage-drop at the fb-helper's suspended-state
gate; the driver, thread, and hardware are fully exonerated.**
Checkpointed cycle (per-step full-line IRQ sums; the single-column
counter concern was checked and refuted — all interrupts land on CPU0):
the blank step drives 0 frames; the whole suspend/resume cycle drives
exactly 2 single frames (one in entry/resume, one at unblank — there
is no wash and never was; the "white" seen on glass is those minimal
off-screen drives, the machinery behind os1's fancy suspend image with
our white fallback, cf. the boot-time `rockchip_ebc_default_screen.bin
-2` line). Post-resume, ALL FOUR damage probes are dead — plain write,
write+fsync (the production publish path!), bare FBIOPUT_VSCREENINFO
set_par, and write-after-set_par — refuting the set_par-revival
hypothesis. Then the decisive pair on the live wedged state: the raw
GLOBAL_REFRESH ioctl returns 0 and drives a full pass (+47 frames —
thread, ctx, rails, hardware all healthy; this is what reader-start
"recovery" really is), while writes remain dead even AFTER the ioctl's
drain force-flushed the deferred-io and damage workers. Damage is not
queued anywhere: it is being dropped at submission. Signature match:
`drm_fb_helper_fb_dirty`'s FBINFO_STATE gate discards dirty rects
while the fbdev client is marked suspended — the client's resume
(deferred through the console-lock dance during the device-resume
phase) apparently never completes in our configuration. DRM topology
is intact (plane attached, fb bound, connector live). No stuck
kworker, no error lines. Open question for the offline pass: why the
fb client's deferred resume never lands (7.0.11
`drm_fb_helper_set_suspend_unlocked`/resume_work vs our console
config), and the fix shape (likely: ensure fb-client resume completion
from our resume path, or re-arm it post-resume). The queued
partials-after-recovery question was answered the same night by use:
the user loaded a book and turns pages normally — a fresh fb client
clears the clog completely, so reader-start recovery is full recovery,
partials included. Device restored (reader running, 186-frame boot, /tmp
clean, no reboot — third wedge-free session in a row).

**2026-08-01 (evening) rung-2 retry on the bracket-fix image: MAJOR
PARTIAL — the thread un-wedges and the panel recovers WITHOUT a reboot
for the first time, but plain fb writes between resume and the next
real client commit still do not flow.** Protocol as documented, with
the blanked-CRTC precondition made deterministic (explicit blank;
drm-state captured active=1 → 0 pre-suspend). Mechanics clean again:
24.6 s asleep, alarm wake, gadget quiesced, `rockchip_ebc_resume`
printed (the fix ran), ctx swap at resume as designed. New facts:

- The whole cycle produced only **2 EBC IRQs** — the expected park-tail
  wash did not run either (open sub-question).
- Post-resume band writes: 0 frames (beacon never appeared) — BUT
  **`herd start reader-session` recovered everything: 186 IRQs, panel
  alive, reader healthy**. Every previous failure was reboot-only; the
  bracket fix converted a hard wedge into a
  recoverable-by-next-modeset state. The reader's start issues
  `FBIOPUT_VSCREENINFO` (set_par → full mode-restore commit), which is
  what plain write()-path damage lacks.
- **The regulator "+1 leak" is retired as a non-leak**: after recovery
  the counts returned to baseline (v3p3:1, vposneg:0, vcom:0) — it was
  the enable-count of the stuck refresh state, not an unbalanced path.
  The earlier analysis's "sampling artifact" branch was correct.
- Residual defect, now narrow: after a blanked-CRTC resume, damage
  submitted through the fb-helper dirty path does not reach the panel
  until a modeset-bearing commit occurs. Production impact: a reader
  surviving suspend in place would resume into the dead-write window
  (its refresh calls are commits but not modesets). Next offline
  analysis question: why the resume-committed enable=1/active=0 state
  (unblanked to active=1 afterwards) services commit-damage only after
  a set_par, and where the park-tail wash went.
- Evidence harvested with verification before cleanup (the multi-file
  scp trap recurred; caught this time by the gated cleanup — the
  standing rule works). Device left healthy: reader running, EBC
  active, regulators balanced, /tmp clean, no reboot performed.
- **Observed re-run, same evening (user watching the glass; identical
  counters: 25.0 s, 2 IRQs in the gt window, fresh band 0 frames,
  reader-start recovery 186 IRQs)**. The glass sequence, verbatim:
  "koreader → console (stays a while) → what looks like a blank screen
  → wait → console again → wait → koreader". Decoded: the post-wake
  unblank REPAINTED THE CONSOLE — a modeset-class commit the panel
  serviced, proving the thread alive and servicing immediately after
  resume; the beacon band was invisible on glass exactly as the
  0-frame counter said. New puzzle the counters cannot explain: the
  "blank screen" around suspend entry suggests the park-tail wash
  painted white in a window where the IRQ counter moved by only 2 —
  something drove the glass without counted DSP_END interrupts.
  Next-cycle discriminators queued: per-step IRQ checkpoints, a
  write+fsync (publish-path) band vs plain write, and dirtyfb-vs-write
  discrimination.

**2026-08-01 os2 write #3: the worker-bracket-fix image is deployed and
readback-verified; reboot pending.** Artifact
`pinenote-reader-PNGuixRoot-20260801.ext4` (staged as `…-fix.ext4`),
SHA-256
`8e302e488243bbdbc4a6ac9f2ade9145eca9120b35325c4ed01c5a026301622d`,
1,945,595,904 bytes (474,999 × 4096 exactly). Carries the previous
image plus the system-sleep worker bracket fix (the `l47fsm…` kernel,
byte-verified inside the artifact before staging). Full write protocol
from os1: archived-fingerprint identity, staged SHA match, root=p5 and
p6-unmounted re-checked in the write shell, exact-count dd, readback
over the identical range matches. First session on this image: the
rung-2 ladder retry per `doc/power-management.md` — expected new
behaviors: park-tail white wash on suspend entry (blanked path),
`rockchip_ebc_resume` in dmesg, and the beacon band actually appearing
after wake.

**2026-08-01 (afternoon, offline, follows the midday ladder): the resume defect is root-caused to a
single gating asymmetry and fixed in-tree; hardware proof pending the
next boot.** A three-analyst source reconstruction plus two adversarial
verifiers (all verified against the real 7.0.11 DRM core, our driver,
and the fetched m-weigand 6.12) pinned it: across a system sleep the
enable flip makes `mode_changed` true in *both* commits, so the ctx swap
in `atomic_check` always runs — but the DRM helper *invokes* the
park/unpark hooks only for an ACTIVE CRTC, and our fbdev CRTC was
blanked at suspend. The never-parked refresh thread kept the freed
pre-suspend ctx (its kref-less per-unpark re-read never re-ran) and
every post-resume refresh hit the empty-list break before the only
`DSP_FRM_START` write: silent zero-frame success that still
power-cycled rails via runtime PM — matching all five hardware
observations, including the abort reproduction and os1's survival
(compositors keep the CRTC active and re-modeset). The structure is
**inherited** (6.12 identical; reported in
`doc/driver-findings-report.md` with the latent-UAF note and three
suggested upstream fixes); our tree carries the integration fix: the
hook bodies factored into idempotent quiesce/wake helpers
(`worker_parked` bracket, `kthread_park` return consumed, no unpark
into a NULL ctx, PM-side ctx read under the CRTC lock) called
unconditionally from the system PM callbacks, plus two
observability-only lines (first-poison warn, runtime-suspend supply
warn). Offline ladder all green: patch applies, verbatim-source host
suites pass with the new `ebc-suspend-bracket-test` pinning the bracket
(13 assertions), full aarch64 cross-build. Deliberate visible change:
blanked-CRTC suspend now runs the park-tail wash (glass to white).
Not deployed; the next boot's ladder retry is the proof.

**2026-08-01 (midday) FIRST SUPERVISED SUSPEND LADDER SESSION: rung 1
PASS, rung 2 suspend/wake mechanics PASS, rung 2 acceptance FAIL — the
`rockchip_ebc` system-resume path is broken in our tree, reproduced on
both an aborted and a clean cycle. Ladder stopped; deep untested by
rule.** User present throughout; three reboots total; device restored
healthy after each. Full record:
`doc/artifacts/pinenote-suspend-ladder-20260801.md`.

- **Rung 1 (pm_test freezer): PASS** — 5.15 s cycle, clean entry/exit.
- **Rung 2 attempt 1: FAIL-ABORT, root-caused.** The USB ACM gadget
  with an active host session vetoes suspend: dwc3 `wait for SETUP
  phase timed out` → `dwc3_plat_suspend` returns -11 → PM core aborts.
  New hard precondition: quiesce the gadget (blank
  `/sys/kernel/config/usb_gadget/pinenote-acm/UDC`) before any attempt.
  Also: rk808-rtc rejects the `+N` wakealarm form (EAGAIN) — arm with
  absolute epoch.
- **Rung 2 attempt 2: mechanics PASS** — gadget unbound, alarm armed
  +25 s absolute, `suspend entry (s2idle)` → 24.7 s asleep → RTC woke it
  on schedule, Wi-Fi rejoined, dwc3 clean. The TPS65185 snapshot/restore
  pair ran on hardware both cycles without errors (registers identical
  pre/post except ENABLE, explained below).
- **Acceptance FAIL, the session's headline**: after `rockchip_ebc`'s
  system-resume (`plane_reset`/`ctx_release`/`ctx_free`), damage is
  never serviced again — beacon and probe band writes cost 0 frames,
  the reader's own boot repaint cost 0 frames, and the user confirms
  nothing ever appeared on glass. Additionally the resume path leaks
  regulator enables every cycle (vcom 0→1 users, v3p3 1→2, vposneg
  0→2; TPS `ENABLE` 0x2f→0x3f with VCOM live) while runtime-PM still
  reports `suspended`. Recovery is reboot-only. **This is the suspend
  program's display-side blocker**, now precisely characterized with
  two reproductions.
- **UART finding** **[superseded 2026-08-02: the UART works at 1500000;
  this was a test artifact — see `doc/device-access.md` and the
  2026-08-02 rung-3 entry]**: the USB-C serial cable receives nothing from
  `ttyS2` at 1.5 Mbaud even when plugged from boot (verified by writing
  to `/dev/kmsg` and `/dev/ttyS2` directly while capturing) — the
  console-free protocol (absolute-epoch RTC bound, panel beacon,
  on-disk evidence, PMIC long-press as recovery) is the validated
  procedure for this hardware, and the ACM console cannot observe
  suspend by construction (it is a USB gadget and dies with it).
- **Operator error, recorded**: the raw rung-2 evidence files were
  deleted from the device after a silently failed multi-file scp; the
  full abort-session dmesg survives and every load-bearing value was
  captured live in-session before the loss (excerpted in the artifact).
- **The oracle question was answered the same evening** (artifact
  `pinenote-os1-suspend-oracle-20260801.md`): one bounded **deep**
  cycle on stock os1 (its own shipping mode — it auto-deep-suspends on
  idle per its journal, explaining the battery longevity) came back
  with a **working panel, user-confirmed on glass**. PG 0x00→0xfa
  proves the rails genuinely cycled, and **VCOM read 0x8f after a real
  SLEEP reset — the NVM calibration thesis is hardware-proven at the
  strongest level**. Decisive detail: os1's dmesg logs the *identical*
  resume teardown ours does (`plane_reset`/`ctx_release`/`ctx_free`) —
  the teardown is not the defect. The divergence is the display
  client: os1's DRM compositor re-commits after resume and rebuilds
  the context; our fbdev emulation never does, leaving damage
  unserviced and the resume-time regulator enables unbalanced. **The
  fix is ours to write** (restore the fbdev client after resume —
  `drm_mode_config_helper_suspend/resume` or an explicit fb-helper
  restore): a forward-port integration gap, since the lineage never
  ran this driver fbdev-only. Offline-writable; provable at the next
  boot with the same console-free ladder protocol.

**2026-08-01 os2 write #2: the consolidated image is deployed and
readback-verified; reboot pending.** Artifact
`pinenote-reader-PNGuixRoot-20260801.ext4`, SHA-256
`be29e1f72d7abcf3aabdf1fb4276d6b03ed7464c9859cb75bf58246a7febfe41`,
1,945,587,712 bytes (474,997 × 4096 exactly). Carries everything since
the last write, verified byte-present inside the artifact before
staging: `defio_delay_ms=250` pinned in `pinenote-apply-ebc-params` and
both modprobe lines (the portrait fix persists across reboots from this
image on), the TPS65185 suspend/resume restoration in the embedded
kernel (dormant; policy still `false`), the updated dormant ultra model
(production parser still rejects the override property), and the
publish-on-call stack from the previous image. Same full protocol: os1
identity by archived fingerprint, staged SHA match, root=p5 and
p6-unmounted re-checked in the same shell as the write, exact-count dd,
readback over the identical byte range matches. **Booted and verified
same day**: `defio_delay_ms` reads 250 at boot with no sysfs step, 4/4
alternating uinput portrait page turns cost exactly 38 frames = one
pass each (38-phase bin), zero error signatures, reader healthy, EBC
quiescent, `/tmp` clean. The portrait single-pass fix is persistent
across reboots from this image on. Nothing suspends; the PM code is
dead until the ladder says otherwise.

**2026-08-01 (later): the TPS65185 resume-restoration hunk is written,
gated, and dormant.** The forward-port patch now carries
suspend/resume PM ops for the mainline tps65185 driver: snapshot the
nine programmable non-VCOM registers at suspend, wait out the 50 ms
post-wake EEPROM reload window, rewrite bit-exact via cache-through
`regmap_write`. VCOM is never written (NVM-backed per-device
calibration — never-bundle class), TMST1 excluded (write-trigger),
ENABLE last (no rails under stale sequencing), snapshot-not-defaults
because U-Boot programs sequencing (UPSEQ0 0xe1 measured vs 0xe4
default). The tps65185 diff section was regenerated with `diff -u`
(96→212 lines) and the patched source verified byte-identical to the
edited file. A structural gate
(`validate-tps65185-pm-hunk.sh`, wired into `make suspend-check`) pins
the VCOM exclusion, the reload wait ordering, the no-`regcache_sync`
rule, and ENABLE-last — negative-tested four ways. Dormant on the
running image: nothing suspends (policy `false`), so the callbacks
never execute until the ladder reaches `deep`. All host suites green;
full aarch64 cross-build green. The remaining resume blockers
(cyttsp5, rail policy) stay open — SC7A20 was fixed 2026-08-03 — they are gated on hardware
truth (the rail-kill wake question), not on writable code.

**2026-08-01 suspend-program groundwork, same os2 session + offline: the
ultra-suspend firmware handshake is modeled and hard-off, VCOM is proven
NVM-safe, TPS65185 resume is settled as required-with-known-shape, and
hrdl's rail payload is found to collide with our entire wake path.**
Live, read-only: the TPS65185 register file was dumped over regmap
debugfs (VCOM1=0x8f = the per-device −1.43 V calibration, live in
chip; the dump is the proven acceptance instrument for the first `deep`
case) and the regulator/DT/wakeup ground truth harvested
(`doc/artifacts/pinenote-pm-live-harvest-20260801.md`) — the dormant
`rockchip-suspend-mode` driver is bound on this image too, and the three
rails hrdl's ultra policy kills are all `mem=enabled` here. Offline: the
donor diff settled (his whole kernel delta is 8 lines; SIP transport
byte-identical), `rockchip,suspend-state-override` is modeled in the
bsp-sip-probe patch under a strict exactly-5 contract with the firmware
word decoupled from regulator-list selection, pinned by mutations, and
still production-rejected (all three gates green — the C tests
originally absorbed the semantic change silently, the exact assertion
gap the groundwork brief predicted, closed with negative-tested
coverage). Evidence pass highlights: VCOM survives SLEEP because the
TPS65185's NVM value *is* its power-up default (datasheet §8.3.7.2; the
installed U-Boot is a self-healing NVM programmer that has been taking
its no-op branch; later community u-boot disables even that to protect
the factory value); stock os1's kernel already does full non-VCOM
register restoration on resume (the template for our future
REGCACHE-caveated hunk); and the rail audit found `vcc_3v3_pmu` feeds
`pmuio1/2` — the GPIO0 bank carrying **every external wake interrupt on
this board** — making the rail-kill wake collision the new gating
question for the ~11 mW prize. New blocker recorded: SC7A20 resume (FIXED 2026-08-03).
Full detail: `doc/power-management.md`, "Evidence pass (2026-08-01)".
No suspend was attempted; activation stays compiled out.

**2026-08-01 first boot of the publish-on-call image: the portrait
double-refresh is FIXED ON GLASS — eight of eight portrait page turns cost
exactly one pass, and `defio_delay_ms=250` is the chosen, now-pinned
value.** Clean first boot (waveform 0x19 loaded, zero real error
signatures, `vt.global_cursor_default=0` live on the cmdline, fb0 reports
`rockchip-ebcdrm` so KOReader's `eink_fb` invert quirk provably cannot
fire). All over SSH with the standard preconditions; device left healthy
(reader running, fbcon unbound, EBC quiescent, `/tmp` clean).

- **Sweep** (`repaint-duration.lua`, live sysfs writes): at 50, spans
  ≥66 ms cost two passes (defect reproduced on the new kernel, ≤41 ms one
  pass); at **250**, spans of 72/155 ms cost ONE pass and 261 ms (just over
  the window) correctly costs two — the window tracks the parameter
  exactly; at 1000, every span through 390 ms costs one pass. Probe
  limitation found and worked around: `settle()`'s 400 ms patience
  under-waits any window > 400 ms and aliases rows (the raw 1000 run showed
  0-frame rows); re-run with patience 1300 ms was clean.
- **Publish latency is timer-independent** (`fsync-band.lua` at 250):
  timer path 380–394 ms (window + ~135 ms pipeline floor), fsync path
  unchanged at 133–140 ms. Raising the window costs publishers nothing.
- **The proof**: with the reader's fsync wiring live and the window at
  250, eight alternating uinput portrait page turns (KEY 158/159, content
  verified changing via fb0 hashes — a forward-only run pages past the
  2-page quickstart's end and reads 0 frames, the same-content trap at
  document level) cost **exactly 46 frames = one pass each**, against
  23/23 turns at exactly two passes before the fix. The startup wash and
  session traces confirm the new `device.lua` publishes at every intent.
- **Value pinned**: 250 in `pinenote-apply-ebc-params` and both modprobe
  option lines (reaches the device on the next image; this boot has it
  applied live via sysfs and reverts to 50 on reboot until then). 1000
  also works but penalizes non-publishing writers for no reader benefit.
- Temperature bins moved mid-session (38-frame cold, 46 warm) [correction 2026-08-08: backwards — 46 frames is the cooler bin, 38 the >=24 C bin; doc/refresh-policy.md] —
  per-turn pass counting used same-session baselines throughout.
- Expected lifecycle note: `QUIT`ing the optics injector destroys an
  input device the reader holds, which correctly restarts reader-session
  (required-device-loss path); the post-restart wash accounts for the IRQ
  burst during cleanup.

**2026-08-01 os2 write: the publish-on-call image is deployed and
readback-verified; reboot pending.** Artifact
`pinenote-reader-PNGuixRoot-20260731.ext4`, SHA-256
`7d5d7b493dce95f7b9c55b112401340a9abd1756dbee05b8f31e237906a32487`,
1,945,591,808 bytes (474,998 × 4096 exactly). Every delta verified in the
artifact before staging: `parm=defio_delay_ms` in the embedded
`rockchip_ebc.ko` (with the ioctl wash-ordering drain and the remove-path
UAF fix), 8 `publish()` sites in the image's KOReader pinenote device
target, `vt.global_cursor_default=0` in the extlinux `APPEND` (closing the
fbcon cursor-blink hazard at its source), and the panfrost softdep in the
system `/etc/modprobe.d`. Full write protocol: os1 identity confirmed by
the archived ED25519 fingerprint, root=p5 and p6-unmounted re-verified
immediately before the write, staged to
`/home/user/wilkbook-artifacts/` with matching SHA, `dd bs=4096
count=474998 conv=fsync`, readback of the exact byte range matches the
artifact hash. Reboot (U-Boot menu, "Boot OS2") is user-present as always;
the first session on this image is the `defio_delay_ms` sweep
(`doc/hardware-deploy.md`, "defio_delay_ms sweep session").

**2026-08-01 SSH-only probe session on the deployed (2026-07-28) os2 image:
publish-on-call's kernel half is hardware-validated ahead of deployment, and
the deferred-io threshold is bracketed.** No reboot, no writes outside
`/tmp`, reader stopped/restarted over SSH with fbcon unbound and EBC-idle
preconditions; device fully restored (reader running, fbcon unbound, EBC
quiescent, `/tmp` emptied). Findings, all on the *current* kernel (which has
no `defio_delay_ms` — confirmed absent from
`/sys/module/rockchip_ebc/parameters/`, so the {50,250,1000} sweep still
needs the new image):

- **`fb_deferred_io_fsync` behaves exactly as publish-on-call assumes**
  (`fsync-publish.lua`): no-op fsync 0.01–0.08 ms; publish call with a full
  screen dirty 4.6–9.8 ms; fsync during an active 596 ms pass returns in
  4.5 ms (non-blocking confirmed); write+fsync costs exactly one pass.
- **The pen-latency win is measured** (`fsync-band.lua`): for a 100-row
  (~1 ms) write, timer path 174–189 ms vs write+fsync 132–140 ms to first
  EBC IRQ — **fsync saves ~45 ms**, the mean timer wait. Full-screen A/Bs
  cannot see this: a governor-paced ~40–100 ms fill spans the timer window
  and both paths flush mid-write, which is itself the portrait defect in
  miniature.
- **Idle-start pipeline floor ~132–140 ms** from damage to first frame
  (commit blit + EPD power-up + LUT + temperature read). Highly consistent
  (±5 ms). This bounds any "instant" page-turn expectation from EBC-idle;
  warm-path latency is unmeasured.
- **The corrected `repaint-duration.lua` works on glass and the threshold
  is bracketed**: measured spans ≤44.4 ms cost one pass, ≥68.0 ms cost two,
  across ten rows over two runs — every point consistent with span-vs-50 ms
  and no anomalous slack. One pass = **46 frames** in the current
  temperature bin (the probe's pass divisor is now self-calibrating off its
  baseline row; 38 and 46 are both real bins).
- **The RGA is alive on our image**: mainline V4L2 `rockchip-rga` (HW
  3.02, `/dev/video0`) processed 1404×1872→1872×1404 XR24 during the
  2026-07-31 feasibility benchmarks — hardware confirmed working even
  though the accelerator is dominated by publish-on-call for latency.
- One probe authoring mistake preserved for the record: same-value fills
  are masked by `diff_mode` and read as "no refresh" — every A/B write must
  flip against current content.

**2026-07-30 refresh accounting, same os2 session: portrait page turns cost
exactly two refresh passes, landscape exactly one.** Measured by sampling the
EBC interrupt counter at ~11 Hz while turning pages and correlating each burst
against the device target's `[pn-refresh]` intent lines on shared epoch
timestamps — one DSP_END per hardware frame, so a burst's interrupt count is
its frame count. Eight full-screen portrait `partial` turns cost **76 IRQs**
each (2 × the 38-phase GC16 partial); eight landscape turns cost **38**. Zero
exceptions. Single-pass bursts ran 0.67–0.76 s against the recalibrated
38 × 15.688 ms = 596 ms, incidentally cross-checking the same day's
frame-clock work.

KOReader issues exactly one intent per turn in both orientations, so the
doubling is generated below it. The doubled bursts are **continuous** — across
all 13 multi-pass bursts the longest internal idle is 0 ms in eleven and one
sample period in two — so both damage areas were already queued and the driver
is correctly *serialising* them: `rockchip_ebc_schedule_area` defers an
overlapping area past the active window, and two full-screen damages overlap
totally, giving 76 continuous frames. Portrait yields two full-screen damages
because KOReader draws through a rotated view of the row-major framebuffer, so
each logical row touches every framebuffer row and dirties all pages at once;
the repaint then spans two deferred-io flush periods. (An earlier reading of
this capture — that a slow blit delivered the second damage ~600 ms late — is
refuted by the absence of any such gap.)

A second capture the same day settled the follow-up: fifteen portrait turns
over mixed dense and sparse pages cost **exactly 92 interrupts each**, so page
content does not change the pass count. 92 is 2 × 46, not 2 × 38 — the panel
had drifted to 23.0 °C into the cooler waveform bin, so the per-pass phase
count moved 38 → 46 exactly as the `.wbf` decode predicts while the pass count
held at two. The method thus detected a temperature-bin crossing on its own.
With 23 of 23 portrait turns at exactly 2.0 passes across two sessions and two
temperature bins, the doubling is **deterministic, not a timing race**; the
defect is repaint duration versus the deferred-io window, and **rotation is
only a way of being slow**. Established by controlled on-device probes
(`pinenote/tools/ebc-damage-probe/`) that write chosen patterns straight to the
framebuffer with no KOReader involved: each deferred-io flush costs one whole
refresh pass and passes do not pipeline, with **disjoint** damages costing
exactly what overlapping ones do (76 frames either way) — which refuted the
overlap explanation. With no transpose at all and duration as the only
variable, one contiguous full-screen write costs 38 frames at 0 ms spread and
76 at 40 ms and beyond, saturating there. The window is 50 ms, set by DRM core
(`drm_fbdev_shmem.c:184`, `fbdefio.delay = HZ / 20`), and a contiguous
full-screen fill alone costs ~29 ms of it. Landscape lands inside; portrait
does not. That accounts for the exact 2.0×, its independence from content and
temperature, the saturation at two, and the reported `[old] → [new | old] →
[new]`. Three earlier explanations recorded here — late damage, a timing race,
and overlap serialisation — were each killed by measurement. The same capture also shows damage rects
inflated 28 px per side and escaping the screen bounds (1460 wide on a
1404-wide screen, 1928 on 1872, one line with `x=-28`). Both findings, the
method, and the replayable trace are in `doc/refresh-policy.md` and
`pinenote/tools/ebc-logic/traces/2026-07-30-portrait-vs-landscape.trace`.
No device state was changed to obtain either.

*Fix implemented offline 2026-07-31 (publish-on-call), not yet
hardware-proven.* Three pieces: the driver gained a `defio_delay_ms` module
parameter (a `.fbdev_probe` wrapper over the exported vanilla probe; default
50 keeps the timer period bit-identical; the sysfs setter retargets the live
helper because the initrd raw-loads the module, and `remove()` clears the
helper static under the param lock); the KOReader device target fsyncs the fb
fd at every `refresh*Imp`; and the global-refresh ioctl drains the deferred-io
flush *and* the damage worker into `ctx->final` before arming the wash —
fsync alone cannot order the commit blit against the refresh thread's
snapshot, so the wash-paints-new-page guarantee lives in the drain, not the
fsync (adversarial-review finding, same day). Full aarch64 cross-build,
`parm=` metadata in the `.ko`, all host suites, a fail-loud `substitute*`
assertion in `koreader.scm`, and `test-refresh-seam.lua` (bundle-verbatim Imp
seam + per-Imp publish coverage with trace/publish/wash adjacency,
negative-tested) are green. Rollout: only the timer period is inert until the
parameter is set; the publishes and the drain are live immediately (at
delay=50 extra flushes cannot add passes — saturation at 2.0 was measured).
Hardware-gated remainder: sweep `defio_delay_ms` {50, 250, 1000} with the
corrected `repaint-duration.lua`, pin the winner in
`pinenote-apply-ebc-params`, and prove the single-pass portrait turn on
glass. Details: `doc/refresh-policy.md`, "publish-on-call".

**2026-07-29 EBC barrier campaign: the image booted, the barrier returned
`-110`, and the cause is a starved refresh thread — root-caused the same
session, offline, with no second boot.** The 2026-07-28 candidate booted from
os2 and passed full identity confirmation. The one permitted supervised run of
`pinenote-ebc-sleep-frame-test --run` then failed:

```
pinenote-ebc-sleep-frame-test: initial operation failed (-110; cleanup error 0); no restore or further EBC start was attempted
```

exit 1, **zero generation lines**, so acceptance failed on every criterion and
the campaign ended without retry per `doc/hardware-deploy.md`.

*Identity (all confirmed before the run):* system generation
`jswc6b1vhx07z7c7llgrns86wnqkkdgb-system`; diagnostic
`iacbgbk8dl5gj4dl0cwmcqwawbx2f4i3-pinenote-ebc-barrier-test-0.1.0`; KOReader
`p3x3wfkl6pd82i1cn6szhkzrab2y6w3z-koreader-bin-2026.03`; `/boot/Image`
`1302cd62…f611f3` and `/boot/config` `31095857…d609c` matching the matched
bundle; ext4 UUID `70c4c247-0bbd-3a2e-f332-95ba70c4c247`, label `PNGuixRoot`,
PARTLABEL `os2`; all six PineNote Lua targets matching the artifact manifest;
`suspend_policy.lua` exactly `return false`; no dormant imports in
`device.lua`; `CONFIG_ROCKCHIP_SUSPEND_MODE=y` with
`CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE` absent. All four backup manifests
verified immediately beforehand.

*Recorded deviations from the written protocol.* No UART: the CH340 was not
attached, so the session ran over Wi-Fi SSH as `root@os2` with operator
approval; the kernel ring buffer supplied the whole boot log and the failure
mode kept SSH alive, so nothing was lost. The binary was invoked directly
rather than through `sudo` (already euid 0; this removed any chance of a sudo
prompt consuming the acknowledgement byte). Read-only identity checks were run
before `herd stop reader-session`. The frontlight had to be re-enabled after
stopping the reader — KOReader owns both channels and zeroes them on exit.

*What the kernel said.* Nothing. Across the entire run `dmesg` gained exactly
one line, `Console: switching to colour frame buffer device 234x87` — fbcon
rebinding when the reader stopped. No `Refresh timed out!`, no `Frame N timed
out!`, no `*ERROR*`, no poison or uncertain-ownership line. `barrier_poison`
was **provably 0**: `ioctl_refresh_barrier`'s WAIT path can only report
`-EINPROGRESS` when `waited == 0` and no poison is set, because the wait
condition is `(poison || completed_generation >= request_id)`. The `-110` is
userspace's mapping of that expiry (`ebc-barrier.c:45-46`), not a kernel
`-ETIMEDOUT`.

*What the hardware was doing.* The `ebc-refresh/fdec0000.ebc` kthread sat in
**`D`** (uninterruptible), not `I`, and was the only such task;
`voluntary_ctxt_switches` climbed ~68/s; EBC IRQ 66 ran at a sustained
**63.4 Hz** (634 interrupts / 10 s) for minutes *after* the tool exited. The
panel washed to uniform white — the pre-run console text vanished — and the
painted card never appeared. That is optically confirmed, not assumed: a 3×
crop with contrast boost shows a featureless field, while the same crop of the
pre-run frame resolves individual console glyphs, so the camera can resolve
detail far finer than a full-screen diagonal.

*Root cause.* `rockchip_ebc_partial_refresh` runs an unbounded
`for (frame = 0;; frame++)` loop (patch:4101) whose only exit is the area list
draining (patch:4244-4247) — and it re-splices `ctx->queue` into that list on
**every frame** (patch:4269-4286). Under a sustained damage source the loop
never returns, so `rockchip_ebc_refresh_thread` never gets back to the top
where `do_one_full_refresh` is read (patch:4619). The barrier's SUBMIT had
correctly allocated a generation and set the flag (patch:3216-3221); nothing
was ever there to consume it, so the credit at patch:4653 never ran and WAIT
correctly reported `-EINPROGRESS` (patch:3250). The in-loop wait is
`EBC_FRAME_TIMEOUT` = **25 ms** (patch:2981, used at patch:4288), not the 3 s
`EBC_REFRESH_TIMEOUT` (patch:2982) — every frame landed in ~15.7 ms, so no
timeout fired and nothing was logged. That the 3 s global bound never fired
either is precisely how we know the thread was never inside
`rockchip_ebc_global_refresh` at all. Note the partial path refreshes with
`default_waveform` (patch:4660), so `refresh_waveform` is not even on this
code path.

*The frame rate is a cross-check, not a coincidence.* `dclk_select=0` gives a
200 MHz dclk; with `CLKDIV2` → 8 pixels/sdck, `sdck.htotal = 2208/8 = 276` and
vtotal 1421, so 276 × 1421 / 25 MHz = 15.688 ms = **63.744 Hz** predicted
against 63.4 Hz measured (0.5 %).

*The os1 differential.* Stock Debian 6.12 on os1 keeps its refresh thread in
`I` at ~3 Hz idle. Its kernel cmdline carries **`vt.global_cursor_default=0`**
(`doc/device-runbook.md:29`) and `/sys/class/graphics/fbcon/cursor_blink` is
`0`; the reader image's cmdline has no cursor setting. An area retires at
`frame_delta > last_phase` (patch:4199), i.e. ~47 frames ≈ **737 ms**, so any
damage source faster than ~1.36 Hz starves the loop; fbcon's cursor blinks
every 200 ms (`fbcon.c:781`, `cur_blink_jiffies = HZ / 5`, verified against the
7.0.11 source).

**[Superseded 2026-07-30: the producer was measured — `cursor_blink=1`, and
unbinding fbcon took the EBC from 63 Hz to exactly 0 Hz with the thread going
`D`→`I`. The paragraph below records what was known at the time.]**

**The producer is the leading hypothesis, not a measurement.** `herd stop
reader-session` does re-bind fbcon — the service unbinds it while the reader
owns the panel and re-binds on stop
(`pinenote/services/reader-session.scm:20`), re-creating the "fbcon stomping"
hazard it exists to prevent (`doc/koreader-spike.md:59-67`) — and the cursor
fits every constraint. But nobody read `/sys/class/graphics/fbcon/cursor_blink`
on os2 or captured a damage trace, and *any* source above ~1.36 Hz produces an
identical signature. Reading that file is a next-boot item.

*Open, and not to be written down as explained:* the painted card is 99.64 %
white (9,377 black pixels of 2,628,288), so a washed panel is consistent with
its background having been driven — but the offline probe against the verbatim
driver drives the black features too under exactly this starvation, and the
contrast-boosted crop shows no border, diagonals, or centre block. Either the
hairlines were driven and lost photographically, or the card's damage never
reached `ctx->final`. Unresolved; it does not affect the verdict.
**[Closed 2026-07-30: neither. The paint reaches the framebuffer byte-exactly
(fb0 matched the offline golden), and once the refresh thread was not starved
the card rendered on the glass. The 2026-07-29 panel was blank because the
starved loop never drove it.]**

*Ruled out on measurement, not argument.* The `refresh_waveform` difference
(os2 = 6/GL16, os1 = 4/GC16) does **not** explain it: `wbf-info` against the
device's own waveform at the measured 23 °C gives GC16 = 46 phases and
GL16 = 46 phases — identical area lifetimes.

The EBC was never poisoned and no reboot was required for recovery; the device
was returned to os1 normally. os2's `/var/log/messages` was harvested
post-mortem through a `ro,noload` mount of p6 from os1, and p6 was confirmed
unmounted afterwards. **The barrier's hardware semantics remain unproven** —
this run never reached a global refresh. Suspend remains disabled and this was
not suspend permission.

**2026-07-28 signal-safe dormant EBC adapter candidate: written to os2 with
exact readback verification; not booted.** A fresh reader artifact packages
the root-only C diagnostic plus dormant LuaJIT barrier and injected sleep-frame
modules. The production reader imports none of them, `suspend_policy.lua`
remains exactly false, Rockchip activation remains compiled out, and the
diagnostic has no suspend or power-state operation. Goal review found that a
flag check followed by blocking `read()` left a signal race at acknowledgement.
The corrected command blocks INT/TERM/HUP throughout setup and restoration and
uses `pselect` to unmask them atomically only while waiting; bounded host tests
cover both an already-pending signal and delivery while blocked. Security
follow-up made `/proc` inspection fail closed, moved DRM acquisition before
mutation, and added a second reader-ownership gate immediately before the
snapshot; its tests prove a late reader or inspection error causes no
framebuffer copy, fsync, or barrier call. EUID root is an operational gate, not
an authorization boundary under the image's existing maintenance sudo policy.
Final review then caught a startup interval before signal blocking and valid
kernel SUBMIT/WAIT failures being collapsed into protocol errors. The shared
signal guard now blocks before installing handlers, detects pending cancellation
immediately before snapshot, and has a raised-SIGTERM zero-mutation regression;
both C and Lua clients preserve valid negative kernel results.
A second code review caught cancellation during the read-only snapshot window
and teardown unblocking before original dispositions were restored. The core
now rechecks after snapshot and directly before paint, with an injected-during-
copy zero-mutation regression; teardown drains already-pending campaign signals
while blocked, restores dispositions, then restores the original mask.
Final review then closed two evidence gaps: `/proc` enumeration now
distinguishes EOF from `readdir()` failure through an injected-test helper, so
scan errors remain fail-closed, and a successful restore prints its second
nonzero generation as required by the hardware acceptance contract.

Host, ASan/UBSan, LuaJIT coordinator, activation-hard-off, suspend-spoof,
AArch64 package, reader, rootfs, matched-bundle, QEMU rung 4, and visual rung 4v
gates pass. Rootfs inspection now verifies `debugfs` emitted an inode, follows
the persistent system-profile link, embeds the profile-matched `/boot/config`,
and proves activation compiled out within the same ext4 identity; an image with
`/boot/Image` removed is rejected. The exact offline rootfs is
`/tmp/opencode/pinenote-rootfs-artifacts-ebc-adapter-release-reviewed-20260727/pinenote-reader-PNGuixRoot-20260727.ext4`,
SHA-256 `1777dde4c5febd7eaaf9d763b422b48ab7d24ca5c75a615bc966406cf973ae64`,
1,945,583,616 bytes (3,799,968 sectors), with matched bundle
`/tmp/opencode/pinenote-reader-boot-bundle-ebc-adapter-release-reviewed-20260727`.

All four local/NFS backup manifests passed immediately before deployment. The
archived stock-os1 ED25519 fingerprint
`SHA256:vT0BeMam25qi9bWdKQEFPUR/xEoEeAHCiSM6vMfxRtY` matched at
`192.168.86.145`; Debian 6.12 was confirmed running from `/dev/mmcblk0p5`, p6
was unmounted with 15,728,640,000-byte capacity, and the staged file matched the
host size and SHA-256. `dd` wrote exactly 3,799,968 records to
`/dev/mmcblk0p6` with `bs=512 count=3799968 iflag=fullblock conv=fsync`, then
`blockdev --flushbufs` flushed p6. The exact same `bs=512 count=3799968
iflag=fullblock` range read back with matching `1777dde4…ae64` SHA-256. The
final check found root still on p5, p6 unmounted, and p6 labeled `PNGuixRoot`.
No reboot, os2 boot, diagnostic, suspend, persistent boot-selection change, or
write to another partition occurred. The replayable record is
`doc/artifacts/pinenote-reader-ebc-adapter-20260727.md`.

**2026-07-27 EBC generation-barrier candidate: exact image booted from os2 and
passed read-only reader/containment acceptance.** The fresh reader rootfs is
`/tmp/opencode/pinenote-rootfs-artifacts-ebc-barrier-20260727/pinenote-reader-PNGuixRoot-20260727.ext4`,
SHA-256 `c15d023159e130633db87a0df742248ef5be2ac6e9aece9d4fc83f73c59cfd4d`,
1,945,313,280 bytes, exactly 3,799,440 512-byte sectors. Rootfs and matched
boot-bundle inspection passed; exact-artifact QEMU rung 4 and visual rung 4v
also passed.

All four local/NFS backup manifests were rerun successfully. Stock Debian os1
was confirmed as `/dev/mmcblk0p5` at its new DHCP address `192.168.86.145`, p6
was unmounted, and the staged artifact matched the host hash. Exactly 3,799,440
sectors were written to `/dev/mmcblk0p6` with `iflag=fullblock conv=fsync`; an
exact-range p6 readback produced the same SHA-256. The device remained on os1.
No reboot, os2 boot, suspend, persistent boot-selection change, or write to any
other partition occurred during deployment. The subsequent manual os2 boot
selected `/gnu/store/27sd3c4537cqpfmqa2ik7gjghqqcp9n8-system` on
`/dev/mmcblk0p6`; Linux 7.0.11 PREEMPT_RT reported taint zero, and the live
Image, DTB, and initrd hashes matched the rootfs-bound bundle. The regenerated
ED25519 SSH host-key fingerprint is
`SHA256:vOfxe+6eauQjlK6gRjCj9zusG0R2rhkfVmCC5xqcPY0`.

EBC loaded the device waveform version `0x19`, registered fb0 at 1872x1404,
and had no timeout, poison, or uncertain-ownership signature. KOReader and the
orientation bridge remained running; finger, pen, and orientation inputs,
Wi-Fi/DHCP at `192.168.86.145`, gateway, and key-only SSH were present. The
policy-free live `/rockchip-suspend` node contained only `compatible`, Linux
OF's synthesized `name`, and `status`; the driver bound with `DORMANT policy
core bound; activation compiled out`. Live packaged hashes prove
`suspend_policy.lua` remains exactly `return false` and `device.lua` imports
neither dormant PM module. No fatal kernel/reader signature appeared.

This boot proves image compatibility and preserved fail-closed boundaries, not
the generation barrier's hardware semantics: production still has no caller for
the barrier UAPI. No suspend, firmware/SMC/PSCI, regulator, CPU, resume, or EBC
repair action was requested. The artifact-bound record is
`doc/artifacts/pinenote-reader-ebc-barrier-20260727.md`.

**2026-07-26 OF-name fix bind verdict: the exact corrected image booted from os2
and the activation-hard-off Rockchip PM driver bound successfully.** The live
root is `/dev/mmcblk0p6`; cmdline selects
`/gnu/store/arh9k85n6h7i8mr2w1f29s5v8pz6qpzv-system`; Linux reports 7.0.11
`#1 SMP PREEMPT_RT` with taint zero. The regenerated ED25519 SSH host-key
fingerprint is `SHA256:xsDSQhSAxtAK0b/A3SyavTqpo3Y5xjLrXm7P5hWxbJs`.

The live `/rockchip-suspend` node contains exactly `compatible`, Linux OF's
synthesized `name`, and `status`. Sysfs links the device to
`rockchip-suspend-mode`, and dmesg reports `DORMANT policy core bound; activation
compiled out` with no former `-EINVAL` rejection. The live config enables only
the core, `System.map` contains the executor but no activation prepare/complete
edge, and the packaged Lua policy remains exactly `return false`. No PM backend,
firmware/SMC/PSCI, regulator, CPU, suspend, or resume action was requested by
this stack.

The rest of the reader boot is healthy: waveform `0x19`, EBC fb0 at 1872x1404,
KOReader, orientation bridge, finger/pen/orientation inputs, Wi-Fi/DHCP, gateway,
and key-only SSH are present. Suspend was not attempted. `/sys/power/state`
advertising `mem` and `mem_sleep` advertising `deep` are capability strings, not
firmware compatibility, suspend, wake, resume, display-repair, or energy proof.

After that boot, the next **offline-only** slice completed without device access.
The production-carried EBC patch now has a fixed-width generation barrier;
the verbatim EBC/WBF harness proves batching and publication order, disable-tail
caller/off-screen snapshots, exact completion accounting, and terminal poison
after setup or hardware timeout. Active DMA mappings are retained, all waiters
receive the same failure, and late DSP_END cannot start or complete later work.
A closed provider constructor and pure injected-capability Lua coordinator prove transaction ordering,
durable prepared/failure records, reverse restore, and permanent poison with no
filesystem or sysfs authority. A distinct synthetic active DT policy executes
probe and MEM events through fake Rockchip operations; its composite gate also
reruns the unchanged production activation-hard-off preflight. None of these
Lua changes is production-wired, enables activation, calls firmware, or requests
suspend. The EBC UAPI has no production userspace caller yet.

**2026-07-26 activation-hard-off candidate boot correction: the reader boot was
healthy, but the Rockchip PM driver did not bind.** The live root was
`/dev/mmcblk0p6`; the cmdline selected
`/gnu/store/pdqr7rf00bzd4sb1d7mxqmk25qdbn83k-system`; Linux reported 7.0.11
`#1 SMP PREEMPT_RT` with taint zero. The live `/proc/device-tree/rockchip-suspend`
node contained only `compatible = "rockchip,pm-rk3568"`, Linux OF's synthesized
`name = "rockchip-suspend"`, and `status = "okay"`. The parser incorrectly
treated that standard `name` metadata as policy, logged `policy property name
requires activation` (`-EINVAL`), and probe failed `-22`; the platform driver
was unbound.

The rest of the reader acceptance evidence was healthy: EBC loaded waveform
`0x19` and registered fb0, KOReader, orientation, pen/finger input, Wi-Fi, and
SSH were healthy. The omitted activation object meant no PM prepare/executor
edge existed: no backend, firmware/SMC/PSCI, regulator, CPU, or suspend action
occurred. This is a Linux live-OF normalization finding, not a firmware
compatibility result. The corrected metadata handling and successful dormant
bind are recorded above; the 2026-07-26 review-fix artifact is superseded as
binding evidence, while its offline artifact facts remain historical.

The corrected offline candidate is
`/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-namefix-20260726/pinenote-reader-PNGuixRoot-20260726.ext4`,
SHA-256 `0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f`,
1,945,280,512 bytes, exactly 3,799,376 512-byte sectors. Its kernel is
`/gnu/store/pk42mcgg1cvxnmjpa028n6x6ddniz1ba-linux-pinenote-7.0.11-pinenote`
and embedded system is `/gnu/store/arh9k85n6h7i8mr2w1f29s5v8pz6qpzv-system`.
The complete host rung, derivation, fresh kernel/packages/reader/rootfs builds,
source/config/DT/package/helper gates, rootfs-matched bundle checks, QEMU rung 4,
and visual rung 4v pass. The artifact-bound record is
`doc/artifacts/pinenote-reader-bsp-pm-namefix-20260726.md`.

The device then returned to stock os1: its archived ED25519 host key matched,
the running root was `/dev/mmcblk0p5`, and `/dev/mmcblk0p6` was unmounted. The
candidate was staged at
`/home/user/pinenote-reader-PNGuixRoot-20260726-bsp-pm-namefix.ext4`; its remote
size and SHA-256 matched the host. The p6 capacity was 15,728,640,000 bytes.
Exactly 3,799,376 512-byte records (1,945,280,512 bytes) were written to p6
with `bs=512 count=3799376 iflag=fullblock conv=fsync`. SHA-256 of an exact
`bs=512 count=3799376 iflag=fullblock` p6 readback matched
`0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f`.
The device remained on os1, p6 remained unmounted, and no reboot or suspend was
attempted during the write sequence; at that point the corrected image was
written and readback-verified but unbooted. Its subsequent boot is recorded
above.
The two backup-root checksum verifications were not rerun in this session, so
this is evidence of the guarded write and exact-range readback sequence, not a
claim that every `doc/hardware-deploy.md` precondition was repeated.

**2026-07-25 BSP SIP probe-only hardware verdict: the exact reader image boots
cleanly, but the legacy version-query gate returns `-EOPNOTSUPP` and the
platform driver remains unbound.** The live root is `/dev/mmcblk0p6`; cmdline
selects the staged `/gnu/store/adf13n0abirx4y6lmmi0kblaf3ang6ah-system`; and
the live `Image` resolves to the expected
`/gnu/store/wwyn7zwl5x36xa0ay92rjl2g9fnnfwx6-linux-pinenote-7.0.11-pinenote`
output. Its SHA-256 is byte-identical to the build, as are the live DTB and
initrd against the staged boot bundle. The kernel reports 7.0.11
`#1 SMP PREEMPT_RT`, taint zero, and boot-time policy0 governor
`conservative`.

The packaged config had `ROCKCHIP_LEGACY_SIP`, `ROCKCHIP_SUSPEND_MODE`, and the
forced `ROCKCHIP_SUSPEND_MODE_PROBE_ONLY` all built in. The live DT node was
exactly policy-free (`compatible`, `name`, and `status` only), and PSCI used the
SMC conduit. At 0.252 seconds the kernel logged
`legacy SIP version probe failed` with `-EOPNOTSUPP`, followed by platform probe
error `-95`; the driver directory contains no bound-device symlink. Current
logging cannot distinguish whether private legacy ID `0x82000001` failed, or
whether it succeeded and `0x8200000a` failed. It proves only that one returned a
raw signed `-1` or `-2`, which the transport deliberately maps to
`-EOPNOTSUPP`. No suspend control ID was called and no suspend state was
requested.

The rest of the boot stayed healthy during the read-only acceptance window.
EBC loaded the device waveform version `0x19`, registered fb0, and runtime
suspended; KOReader and the orientation bridge stayed running with stable PIDs;
the mirrored cyttsp5 axes and `wilkbook-orientation` MSC_RAW device were present;
Wi-Fi associated and leased `192.168.86.145`; root SSH, gateway, and Internet
reachability passed; and the fatal-kernel scan was clean. This is evidence of a
healthy boot and a rejected probe gate, not of private SIP compatibility,
suspend, DDR retention, wake, resume, EBC repair, or energy savings.

The separate 7.0 probe patch then had a forced probe-only legacy SIP transport,
policy-free DT node, and the two now-rejected version calls. That discovery
premise is retired. The replacement execution-capable stack is fully
offline-validated; its first activation-hard-off boot instead exposed the live
OF `name` metadata parser rejection recorded above, and makes no
firmware-compatibility claim. Its fresh kernel output is
`/gnu/store/43aa16pq7hd5p5ahka01yczhrb1fcp8d-linux-pinenote-7.0.11-pinenote`;
the matching image system is
`/gnu/store/pdqr7rf00bzd4sb1d7mxqmk25qdbn83k-system`.

The 2026-07-26 review-fix artifact that was subsequently deployed is
`/tmp/opencode/pinenote-rootfs-artifacts-bsp-pm-reviewfix-20260726/pinenote-reader-PNGuixRoot-20260726.ext4`,
SHA-256 `0d5c432d5db8291d023c8061d364745f820f8391d8264444a19882dc6330fef6`,
1,945,288,704 bytes, exactly 3,799,392 512-byte sectors. Its rootfs-matched boot
bundle is `/tmp/opencode/pinenote-reader-boot-bundle-bsp-pm-reviewfix-20260726`.
The extracted `Image` and DTB byte-match the new kernel output; their SHA-256
values are `a8b8cb89e0e71bab7aacbcca08c449a70890bbabfc4f251db18b85e4553290dc`
and `9d981579a2bafd56b2c56c215c88b01a6ec2670dafc5d97a7dd949b66e229bf2`.
The bundle's initrd SHA-256 is
`db7d08cb6e304fdc87618b523d6848d7ddb4aef2268b200072e184de775065b7`.

All reader-candidate host suites passed against the verified device waveform,
as did the derivation, full AArch64 kernel, helper packages, reader closure,
rootfs and boot-bundle inspectors, source/config/DT inspection, complete mock
helper gate, generic ARM64 login smoke, real-artifact QEMU rung 4, and visual
rung 4v. Files dumped back out of this exact ext4 image prove the packaged
config leaves `ROCKCHIP_SUSPEND_MODE_ACTIVATE` disabled, the packaged Lua policy
is exactly disabled, and `System.map` contains the executor but no activation
symbol. At that pre-deployment point the candidate was ready for the separate
user-present os2 write protocol; no device access, os2 write, reboot, suspend, or
hardware action occurred while producing the offline evidence. Its later write
and boot are recorded below and its binding claim is superseded. The
artifact-bound command, input, hash, and log record is
`doc/artifacts/pinenote-reader-bsp-pm-reviewfix-20260726.md`.

On 2026-07-26 the exact candidate was copied to stock os1 at
`/home/user/pinenote-reader-PNGuixRoot-20260726-bsp-pm-reviewfix.ext4`.
The SSH host key matched the archived stock-os1 ED25519 fingerprint, the running
root was `/dev/mmcblk0p5`, and the remote file matched the host at 1,945,288,704
bytes and SHA-256
`0d5c432d5db8291d023c8061d364745f820f8391d8264444a19882dc6330fef6`.
The os2 write and exact-range readback sequence then completed from that same
stock-os1 session.
`/dev/mmcblk0p6` was confirmed unmounted and large enough before `dd`; exactly
3,799,392 512-byte records (1,945,288,704 bytes) were written to p6 with
`conv=fsync`. SHA-256 of an exact 3,799,392-sector readback from p6 matched
`0d5c432d5db8291d023c8061d364745f820f8391d8264444a19882dc6330fef6`.
The write session did not change boot selection or reboot the device. The user
subsequently unplugged it and reported that it rebooted into os2. Read-only SSH
acceptance then confirmed the exact root/system/kernel and healthy reader stack,
and exposed the metadata-only unbound-driver finding recorded above.

The maximal **offline-only** Linux-side contract is now production-linked and
activation-hard-off. A
host-compiled typed model captures donor `72127ca` probe ordering, GPIO records
and terminator, three regulator-state lists, PM-prepare events, and the
descriptive virtual-poweroff sequence. Donor and maximal DTS fixtures are
compiled to DTBs, parsed with the exact `rockchip,power-ctrl` and
`rockchip,regulator-*-in-*` property schema, and consumed by the same C tests.
Production Kbuild links the strict parser, typed model, generic executor,
exact-node regulator consumer API with locked wrappers, and narrow
SIP/regulator/CPU/modern-PSCI backend. A separate activation object owns the
active driver and its device-PM `.prepare`/executor edge; hidden exact-default-n
config omits it, so the policy-free probe still performs zero actions.
Production rejects mem-lite, mem-ultra, and virtual-poweroff policy; CPU/PSCI
remain linked but dormant. Regulator identities are provider-deduplicated and
exact prior settings are restored after failure, completion, and teardown;
failed restores remain queued for retry, and any failed prepare poisons the
activation instance until reboot. Kconfig requires `SUSPEND` for ARM64
`CPU_PM`. Host tests use fakes only. The affected default-linked
objects and the separately requested activation object compile under AArch64
LLVM; host, mutation, suspend, actual source-tree, full-kernel, image, and QEMU
gates pass. The superseded review-fix source booted with activation hard-off but
rejected Linux OF's synthesized `name` metadata before binding; the corrected
namefix dormant bind is recorded at the top of this document. Neither boot is
evidence of firmware compatibility or permission to attempt suspend.

Stock Debian os1 was confirmed as `/dev/mmcblk0p5`, os2 remained unmounted,
and the remotely staged file at
`/home/user/pinenote-reader-PNGuixRoot-20260725-bsp-sip-probe.ext4` matched the
host size and SHA-256. Exactly 3,799,368 512-byte sectors were written to
`/dev/mmcblk0p6` with `conv=fsync`; SHA-256 of an exact-range eMMC readback
matched. No persistent boot-selection change or firmware write occurred.

**2026-07-19 hardware verdict: final4 autorotation and touch normalization are
deployed and fully accepted on glass.** The final image booted from os2 with the
bridge and reader ordered correctly, the consumer handshake complete, and
event7 advertising `capabilities/ev=11` plus
`capabilities/msc=8`. Its production self-test passed the exact virtual identity
and an MSC_RAW mode 2 + SYN_REPORT delivery. This closed the first image's root
cause: it had used `0x4004556a` (`UI_SET_SNDBIT`) instead of `0x40045568`
(`UI_SET_MSCBIT`), so uinput accepted writes but discarded every undeclared
MSC_RAW frame.

Supervised pose capture established the sensor truth (TOP raw -X, RIGHT raw -Y,
BOTTOM raw +X, LEFT raw +Y). A reversible on-device `+2 mod 4` A/B then corrected
all on-glass orientations, proving that the final KOReader contract is **TOP ->
mode 1, RIGHT -> 0, BOTTOM -> 3, LEFT -> 2**; the earlier TOP3/RIGHT2/BOTTOM1/
LEFT0 conclusion was wrong and is superseded. The source table and host tests
now carry the proven values, so the temporary orientation patch is not part of
the final image.

Finger inaccuracy was separate and equally measurable. With the 1404x1872
target EPUB frozen and KOReader stopped, raw cyttsp5 taps at T02/T03/T04/T05/T01
were `(1757,102)`, `(1763,1332)`, `(113,1297)`, `(102,72)`, and `(926,693)`.
The live MT ranges are X `0..1871`, Y `0..1403`; mirroring both axes before
KOReader rotation maps all five targets within 25 px (center residual 8x9 px).
A combined reversible patch first passed the user verdict: finger and pen both
selected small controls accurately across the screen and rotation remained
correct. Production now discovers the touch node and mirrors each axis from its
queried min/max; pen scaling is unchanged. The baked implementation then passed
the same verdict without any userpatch: all four poses followed the physical
edge, and finger and pen selected small controls accurately across the screen.

The final baked rootfs is
`/tmp/opencode/pinenote-rootfs-artifacts-final4/pinenote-reader-PNGuixRoot-20260719.ext4`,
SHA-256 `d64b1e820d37071108a361f97fd1383630bd36a97b536e4c157407fd4db8fbdc`,
1,945,276,416 bytes. Orientation/input suites, deterministic target generation,
reader/system/rootfs builds, preflight inspection, rung 4, and rung 4v are all
green. It was written from stock Debian os1 with p5 confirmed as root and p6
unmounted; the staged file SHA-matched, exactly 1,945,276,416 bytes were flushed
with `dd conv=fsync`, and readback of that exact range from eMMC SHA-matched.

First-boot acceptance is complete: root is `/dev/mmcblk0p6`; the temporary A/B
patch is absent; the reader logs `touch MT axes X=0..1871 Y=0..1403 (mirrored)`;
and bridge/reader logs contain no scan, uinput, orientation, or range-query
error. Toggle/replay passed (ignore events suppresses rotation; re-enable while
still immediately synchronizes). Finger and pen contact defer rotation until
lift, while pen hover alone does not block it. Restarting `orientation-bridge`
replaced both processes (bridge PID 383 -> 656, reader -> 669), recreated the
consumer handshake and event7 capabilities, and a fresh physical-TOP hold
committed mode 1 and displayed correctly.

**2026-07-20 power evidence baseline (same final4 boot): read-only collection
plus a reversible governor A/B completed; no energy or battery-life verdict.**
The new streamed Guile recorder captured wakeup sources, IRQs, runtime PM,
cpufreq transitions, and workload context without installing code or writing
kernel interfaces. EBC stayed runtime-suspended during a no-refresh interval.
The live DT exposes wake-source properties only for the cover switch and RK817
PMIC, and has no CPU idle-state nodes. The only power supply is the unusable
`ws8100_pen`; no RK817 battery/charger telemetry exists on final4 because its
DT lacks the battery profile and charger linkage.

A short SSH-instrumented A/B temporarily selected `powersave`, `conservative`,
and `ondemand`; a shell trap restored `schedutil`, and the stock min/max limits
and reader/orientation services were rechecked healthy. `schedutil` produced
about 57.22 transitions/s and 1027.13 IRQ29 events/s; `powersave` produced zero
of both; `conservative` produced about 2.13 and 30.94; `ondemand` about 8.32
and 60.97. This causally attributes the high-rate I2C0 interrupts to DVFS/
TCS4525 traffic, but counters are not energy measurements and no governor
change is persisted. Exact evidence and the supervised RK817 telemetry plan
are in `doc/power-management.md`. No suspend state was requested; KOReader's
exact disabled policy remains bound to `canSuspend`, and the offline suspend
gate is a fail-closed qualification check rather than a hardware verdict.

**2026-07-24 RK817 telemetry mechanism accepted for awake charge/discharge
observations; no suspend attempted.** The reader rootfs is
`/tmp/opencode/pinenote-rootfs-artifacts-telemetry-current/pinenote-reader-PNGuixRoot-20260720.ext4`,
SHA-256 `92837467ba2c0714bdef595d0a2f247536a82aa4dbcb80774902f4d0c1dac189`,
1,945,272,320 bytes. Its full waveform/EBC/raster/input/orientation/optics/power/
suspend host suites passed their then-current gates; the rootfs-extracted DTB
passed the exact RK817 battery profile/phandle gate and then-current suspend
gate; and QEMU rung 4 plus 4v passed.
All local and NFS backup manifests verified. Stock os1 was verified as
`/dev/mmcblk0p5`, os2 remained unmounted, and the file was staged at
`/home/user/pinenote-reader-PNGuixRoot-20260720-telemetry.ext4`; its remote
size and SHA-256 match the host artifact. Exactly 3,799,360 512-byte sectors
(1,945,272,320 bytes) were written to `/dev/mmcblk0p6` with `conv=fsync`;
SHA-256 of an exact-range readback is
`92837467ba2c0714bdef595d0a2f247536a82aa4dbcb80774902f4d0c1dac189`.
The 2026-07-24 UART/ACM-observed boot reached `/dev/mmcblk0p6` on kernel
7.0.11 with the exact embedded Guix system store path. Waveform/EBC one-shots,
orientation, reader, and Wi-Fi were healthy; live `refresh_waveform=6`; KOReader
painted the document; and the reader/orientation PIDs stayed stable throughout
the session.

Both new supplies appeared. `rk817-battery` reports present with the exact DTS
profile (4,000,000-uAh design/full charge, 3.5--4.2 V design range, 2-A charge
limit, 4.2-V charge-voltage limit, and 300-mA termination); these are DTS inputs,
not a measured usable capacity. Four unplugged polls
showed charger `online=0`, charger voltage zero, then stable `Discharging` at
-198 to -203 mA with declining voltage and `charge_now`; replugging produced
`online=1`, `Charging/Standard`, +108 to +116 mA, and increasing `charge_now`.
No relevant RK817/charger/regulator error or abnormal temperature appeared
during this boot window; final CPU/GPU temperatures were 35.6/31.9 C.

A recorder-bracketed, cable-free 61-second observation (frontlights zero, Wi-Fi up,
USB not attached) consumed 3,440 uAh, equivalent to about 203 mA over that
interval. EBC remained runtime-suspended throughout and no wakeup-source counter
changed. `schedutil` made 2,828 transitions while IRQ29 fired 50,922 times
(18.0 I2C0 IRQs/transition), independently confirming the DVFS/TCS4525 result.
The full reports are under `/tmp/opencode/pinenote-power-20260724/`; this short,
near-full observation is neither a representative low-power baseline nor a
battery-life estimate.

**2026-07-24 late-session governor energy A/B (device UTC 2026-07-25):
`powersave` reduced static awake draw by about 11%, but is not persisted.** A
cable-free, untouched ABBA run used four three-minute intervals with both
frontlights zero and Wi-Fi associated; a trap restored `schedutil`. The two
`schedutil` runs measured 201.84 and 205.26 mA from `charge_now`; the two
`powersave` runs measured 178.36 and 184.09 mA. Means are 203.55 versus 181.23
mA, a 22.32-mA (10.97%) reduction. IRQ29 fell from 843--875/s to 4.5/s and
cpufreq transitions from 46.8--48.6/s to zero; arch-timer IRQs also fell from
539--560/s to 187--193/s. EBC remained runtime-suspended for every interval,
wake counters stayed flat, reader/orientation PIDs remained stable, and the
original governor was restored. Reports are under
`/tmp/opencode/pinenote-power-governor-abba-20260725/`. This is a static-idle
result, not yet a responsiveness, reading-workload, or persistent-governor
verdict; `conservative` remains the next adaptive candidate.

**The follow-up powersave/conservative ABBA found no resolvable static-energy
penalty for adaptive scaling.** The two `powersave` runs measured 181.72 and
178.36 mA; the two `conservative` runs measured 180.32 and 181.31 mA. Their
means, 180.04 and 180.82 mA, differ by only 0.78 mA (0.43%) in these short
intervals. `conservative` made 3.2--3.7 transitions/s versus zero for
`powersave`, far below `schedutil`'s 46.8--48.6/s. EBC remained suspended,
wake counters stayed flat, services stayed stable, and `schedutil` was restored.
Reports are under `/tmp/opencode/pinenote-power-conservative-abba-20260725/`.
`conservative` then passed the deterministic page-turn/render gate. The
unplugged SSH ABBA ran `conservative,powersave,powersave,conservative` over the
exact 45-turn optics workload at 26 C with both frontlights zero and Wi-Fi
associated. Conservative used 12.900 and 13.244 mAh in 176/177 s; powersave
used 15.652 and 16.168 mAh in 209/209 s. The means are 13.072 versus 15.910 mAh
per completed workload (17.8% less for conservative) and 176.5 versus 209.0 s
(15.6% faster). Every leg carried exactly 45 fresh timestamp-correlated
`[pn-refresh]` events (maximum residual 0.2604 s). The harness restored and
read back the running image's original `schedutil`; its watchdog and optics
reader were absent afterward and the normal reader service was running.

The first attempt produced one valid conservative leg, then failed closed when
the powersave trace exposed two KOReader processes writing the same truncated
log. `KOReaderBackend.prepare()` had ignored a bounded prior-reader stop
failure. It now refuses to relaunch unless the PID/cmdline-verified reader exits,
with a bounded identity-checked `KILL` fallback; offline optics and power suites
pass, and the repeated hardware ABBA completed all four legs. The forward-port
defconfig now selects `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y`; the
2026-07-25 probe-only reader boot read it back as `conservative`. No suspend was
attempted and suspend remains disabled. Owner-only raw reports are
under `/tmp/opencode/pinenote-reader-energy-ABBA-20260725-retry1/` and must not
be committed or shared unsanitized.

Suspend firmware inventory is now pinned far enough to choose the contract:
live firmware reports PSCI v1.1, DT advertises `arm,psci-1.0` with `method=smc`,
and Linux reports cpuidle driver `none`. The 2026-07-25 offline comparison found
that the verified device backup is byte-for-byte identical to PNDeb/Pine64's
`stable_1056mhz` idblock and U-Boot FIT (SHA-256 `7a935efc…` and `078f81dc…`).
This excludes the partially flashed post-October-2024 factory payload; rerunning
the installer would write identical bytes. The FIT contains Rockchip
`U-Boot 2017.09-ge0ec1df #runner` (2024-10-25), a primary ATF segment built
2022-06-09 with `rockchip_sip_svc`/`suspend_mode_config`/ultra-suspend strings,
and OP-TEE 3.13 built 2023-06-07. It is the downstream BSP-ATF contract, not
upstream TF-A 2.12+.

Source review resolved one misleading earlier kernel artifact: the 7.0 patch carried
`CONFIG_ROCKCHIP_SUSPEND_MODE=y` but neither the downstream Rockchip SIP suspend
driver nor its `rockchip-suspend` DT policy; upstream 7.0.11 does not define the
symbol, so the ignored stale line was removed before the explicit compatibility
patch was added. The current patch is not an active BSP suspend path: its
production candidate contains the real backend, but exact-default-n Kconfig
omits the only activation object, and the core accepts only the policy-free DT.
At the 2026-07-25 decision point, the installed stable BSP ATF still required an
execution-capable Linux-side SIP driver plus DT policy. The accepted direction
was to retain the byte-verified stable boot firmware and port the required
`rockchip_sip`/`rockchip_pm_config` contract into the recoverable os2 kernel/DT.
The production-linked MEM-policy parser/model/executor/backend slice is now
offline-proven behind exact-default-n activation; it is deliberately not the
full PineNote ultra-suspend policy. Activation, an active reviewed DT policy,
suspend-state selection, and PineNote resume dependencies remain leading
deep-suspend blockers. Suspend remains disabled, and any first activated boot is
a separate non-suspending bind/probe check under UART. No additional hardware
boot is allocated merely to repeat the corrected zero-call dormant binding.
An upstream-TF-A
migration is a separate later project because os1 cannot recover a damaged boot
chain. Public
Kindle/Kobo/reMarkable/PocketBook integrations support the
intended policy shape--save, paint and wait, disable light/radio, batch wakes,
and use one platform owner--but provide no evidence that this PineNote's
firmware, wake routing, or EBC resume contract works.

**2026-07-15 (night): the "insane finger calibration" was nobody owning
rotation — the touch chain itself is verified correct on glass.** After
the first clean-reboot reading session, Will reported swipes "backwards",
taps registering "on a completely different part of the page", and page
turns drawing in two chunks (top ~2/3, then the bottom, independently).
New instrument, built in-session: a passive raw-evdev observer (luajit
dumper on the device's touchscreen node — evdev allows a second reader,
so it watches real use without disturbing KOReader) correlated against
the `[pn-refresh]` trace. Verdicts from Will's own natural touches:
raw touch frame == fb native frame; the mode-3 translation chain
(`translateCoordinates` → `ges_coordinate_translation_270`) is
self-consistent; footer taps hit the footer, the top-center tap opened
the menu, and four right-edge taps each produced a page-turn repaint
within 150 ms. Stock gestures are already Kindle-style (west = next;
`inverse_reading_order` false). The real bug: **rotation has no owner.**
The file manager snaps to rotation 0 — LANDSCAPE on this panel
(`filemanager.lua:66` fallback) — and each book re-imposes its sidecar
rotation, so entering the FM (first hit 16 s after boot: the input-
inhibit pair at 22:45:26, ~48 s of sideways UI before reopening the
book) or switching books flips the UI relative to the user's hands.
Touch stays internally consistent, which is exactly why it reads as
miscalibration rather than rotation. Compounding it: the PineNote was then
believed to be a symmetric slab with no accelerometer, so picking it up 180° from last
time is routine (the sidecars ended the night disagreeing: Prydain 1,
Mastering Emacs 3 — Will rotated via menu at 00:16:53 mid-diagnosis).
Interim FIX: `lock_rotation=true` (+ `closed_rotation_mode=1` for first start)
— upstream's own mechanism: docs and the FM stop imposing, rotation is
one sticky user-owned value restored across restarts. Deployed live as
a KOReader userpatch (`patches/2-lock-rotation.lua`, applies at the
next KOReader start) and seeded for fresh profiles in the reader
flavor. The two-chunk page draw is NOT new breakage: it is the
pageturn-program's defio-band mechanism made visible by portrait — the
software-rotated blit scatters writes so the paint spans multiple
deferred-io flushes and outlives `delay_b`'s 100 ms coalescing window;
landscape paints fit in one window, which is why it was never seen
before (field note added to `doc/pageturn-program.md` §0).

**2026-07-13 (night): the "portrait artifacting" was a two-instance
framebuffer fight — and portrait WORKS on A.2.8.** First real reading
session (Prydain, portrait) showed overstruck text and stale bands; the
belief-vs-glass instrument proved fb0 == driver-final byte-exact (kernel
exonerated in one measurement), and the trail led through rotation
state, crengine caches, and damage rects before the actual cause
surfaced: the veritas optics session's KOReader (testcard viewer) was
STILL RUNNING, and the dogfooding reader fought it for the fb all
evening — two shadow buffers flushing to one panel, plus fbcon churn
from diagnostic restarts. With one instance owning the fb, portrait
renders clean edge to edge (first functional portrait ever on this
device — the historical A.2.6 portrait WEDGE did not reproduce on the
A.2.8 fixed kernel. Two-band deferred-io quality remains a separate
limitation; the historical finding is not a portrait-functional blocker).
Fixes landed: optics driver.close() kills its reader+injector and
restores reader-session; reader-session start pkills stray readers
(one-owner rule at both ends). Wrong theories chased and discarded en
route, preserved here for honesty: margin-triggered odd-x blit
regression, un-rotated damage rects (trace-only), crengine cache
staleness, KOReader default-rotation mismatch. Dogfood comfort work the
same night: image-page flash promotion off, promotion retired
(washer owns cadence), Equity A typography seeded + live, Prydain
loaded with position preserved on /data. This is the single place to record what has actually
been proven on the device. Update it after every hardware session; the
detailed evidence lives in session logs, not in git.

**2026-07-12 (later): THE IDLE-WASHER IS HARDWARE-VALIDATED.** Three
acceptance captures on the boxed rig (plugin pushed per run over SSH — no
reflash; `build/bundles/idlewasher-accept*`). Run r0 proved the debt
machinery on glass (two debt-max bundled washes, log lines matching the
patch-strip detector to the second) and CAUGHT A REAL BUG the offline suite
had missed: after an idle span ending below debt_min, the timer stays armed
on the deep-clean horizon and `on_input` never pulls it back, so the idle
wash could never fire in normal reading. Fixed in the pure core
(armed-deadline mirroring, b82bab1) with the acceptance timeline as a
table-driven regression that only fires on_timer at the armed deadline. Run
v2 (idle-path-only protocol, bundling excluded via debt_max=50) passed all
three phases: idle wash 20s into a pause at debt 9, silence through a
below-min pause (debt 2), and the fix's exact shape — resumed reading then
idle wash at debt 6, 20s in. Glass agreed with the log to ~0.5s (detector
events t≈64.1/176.2 vs predicted 64.6/176.6, nothing in the silent window).
Also noted: the device rebooted ~19:13 on 07-11 (boot-time kernel log only),
so the armC-era dmesg is gone — quirk F's timeout-correlation check is
UNAVAILABLE, not negative; the instrumented auto=1 repro remains the
confirmation path.

**2026-07-12 (night): os2 PID-1 wedge — root-caused post-mortem from os1;
NOT the eMMC, NOT the display stack.** After ~9 h of uptime the running
A.2.6 os2 became unreachable: ping fine, SSH accepted TCP but no banner;
one patient connection authenticated ("Accepted publickey" in the os2 log)
then hung at shell spawn; finally even TCP timed out; the on-screen reader
wedged. Post-mortem via the os1 oracle (p6 mounted ro): the disk was HEALTHY
the whole time (syslog MARK lines flushed to eMMC until the power-cycle;
e2fsck: p6 clean). Root cause chain: **`term-ttyS2` (the flavor's UART
auto-login getty) exits 1 ten seconds after every spawn — 3,201 respawn
cycles since boot** — and this image's sshd is inetd-style THROUGH shepherd
(PID 1 accepts every connection and spawns a transient sshd service), so a
degrading PID 1 starves SSH accepts until the backlog fills. The 10 s cycle
is slow enough that shepherd's rapid-respawn breaker never trips. ttyS2
exists and works on os1's 6.12 (console + getty), so the exit-1 is specific
to the 7.0.11 reader image — offline-diagnosable. FIX QUEUED for A.2.7:
repair or remove the ttyS2 getty (and consider a respawn backoff). Also
noted in the log: `setfont` popen of the store's own gzip failed with "Exec
format error" (once, early) — unexplained, filed. Host-side amplifiers the
same night, now in memory notes: a wedged gpg-agent (pinentry) made every
host ssh hang/fail during diagnosis. The interrupted /data write left p7's
fs dirty; its journal replayed clean on the next mount (full offline fsck
deferred — p7 is os1's live /home). Books: `/data/books/` created,
`mastering-emacs-v5.epub` copied via os1, SHA-verified; the reader-flavor
commit `4a3761e` mounts /data and seeds KOReader's home_dir from A.2.7 on.

**2026-07-12 (late): five instrumented corrupter repros — timeout variant
dead, corruption not reproducible on demand, optics limits mapped.** Five
`auto_refresh=1` runs with a live kernel-log watch (same-pair x3 across
firing regimes incl. rapid-into-stream; diverse walks x2 at threshold=8):
the kernel logged ZERO frame/refresh timeouts across ~45 verified threshold
firings plus two diverse walks — the 25 ms-timeout straggler variant is
ruled out; the timeout-free extra-credit variant is the prime suspect. No
run corrupted (v4's apparent graying was a measurement artifact — blank
pages carry no fiducials and the frame snaps fell back to unrelated frames;
v5 with strict validated frames measured zero residue). Methods note in
the findings report: GL16 threshold-globals are optically undetectable
inside diverse content; same-pair regimes remain the only place the strip
detector is trustworthy. The campaign's corruption (armC/neverx3) stands
as real but its trigger is unisolated (cumulative state / environment
candidates); per-event ground truth needs the straggler-detector debug
kernel (built offline in a worktree; flashing it is the next user-present
step). All runs ended with 3x GC16 recovery + `auto_refresh=0` readback;
bundles `corrupter-repro-v1/-v2/-v3/-v4-void/` + `corrupter-repro` (v5).

**2026-07-12: MECHANISM FOUND — the driver's auto-globals corrupt state;
`auto_refresh=0` shipped.** A full experimental campaign (9 sweep runs + soaks
+ a 2x2 isolation, all on the boxed rig) found that threshold-triggered
auto-globals progressively corrupt displayed fine structure, while
ioctl-triggered globals are clean across ~20 sessions: diverse-page never-runs
corrupt 3/4 under auto=1 but run CLEAN 2/2 under auto=0; a patch-strip wash
detector caught the auto firings on camera in exactly the corrupting runs;
quirk 3's cross-run damage accumulator explains the stochastic phase. Driver
finding written for upstream (doc/driver-findings-report.md). Shipped:
`auto_refresh=0` in the params one-shot + modprobe.d (b9bbc0e) and applied to
the live device; userspace owns all full refreshes (KOReader promotion now;
the idle-washer next). Full third-party dataset + review guide committed
(doc/optics-dataset-2026-07.md, doc/datasets/2026-07-optics/ — 20 bundles,
checksummed videos, per-claim evidence audit).

**2026-07-11 (close): THE CALIBRATED BASELINE — coherent physics.** Fresh
full-card capture at calibrated settings (`build/bundles/cal-baseline`,
report alongside): 47/49 transitions, sync auto-detected. The GL16 reading
regime measured: **partial page turns are essentially flash-free (0.00-0.06)**
with settle 0.1-0.6 s; **the every-6th promoted fulls flash at 0.16-0.23** —
about a third of GC16's 0.6, so GL16's no-flash property holds for partials
but NOT for fulls. Ghost: none across the board (the correlation gate
correctly rejects the render-mismatch bias). New behavioral discovery:
**ux->novel double-flashes (x2) on every repetition** — exiting the menu-style
page costs two refreshes, a real KOReader pattern worth a policy look.
Remaining calibration debt (queued): NaN guard for tiny stays-white masks,
gray-corrupt thresholds, settle-incomplete tail. Next experiment: GL16 vs
GC16 x full_refresh_count sweep — one --param-sets file away.

**2026-07-11 (calibration): the instrument is now precise.** Exposure sweep on
the rig: v4l2 exposure units are 100 us, so 60 fps caps exposure at ~156 =
unavoidably dark — captures now run 30 fps with calibrated locked values
(exposure 312, gain 32, frontlight 255/255 → panel whites 214/255, zero
clipping; camera_lock applies the values, not just freezing AE). The 10-repeat
noise pilot (novel<->blank x10, full_refresh_count=never so every flip is the
identical partial) exposed two analyzer defects, both fixed: the flash
reference now uses STAYS-WHITE pixels (former text transiting dark while
clearing had fabricated ~0.10 flash on clean partials), and _warp_all now fits
ONE session homography (median of 5) — per-frame fit jitter at content edges
had kept the settle ROI "never quiet" (22/26 clean dwells read incomplete;
now 15 none / 5 slow / 1). Post-fix repeatability: **ghost rms sigma
0.003-0.006** between identical repeats — ~0.01-rms config differences are
now 3-sigma detectable off a webcam. One real optical finding already: whites
adjacent to text dip ~0.15 transiently while text CLEARS under GL16 partials
(0.148 +/- 0.032, absent in the appearing direction) — the visible
text-clear shimmer, quantified. Mask-erosion knob to separate edge shimmer
from background flash is queued.

**2026-07-11 (later): FIRST REAL DEFECT REPORT — the instrument works.** After
three real-footage fixes (sync preamble 5s->240s for automated captures;
panel-presence gate 15%->4% of frame; memory-bounded decode --max-fps/
--analysis-scale), the analyzer segmented **all 49 transitions** from the first
bundle, decoded page IDs off the dark 10%-of-frame panel, and attributed every
metric to the baseline-gl16 run. Real signal: the full_refresh_count=6
promotion cadence is VISIBLE in the optics (~8 transitions flash severe at
depth 0.15-0.28 = the promoted fulls; partials mostly none/mild) — and even
GL16 fulls flash to ~0.2 after partial-accumulated drift (vs GC16's ~0.6).
Known calibration artifacts pending the noise pilot + a brighter locked
exposure: settle:incomplete everywhere (SETTLE_EPS below this rig's noise
floor), flash NaN/overcounting on frame noise, gray-corrupt false flags.
Next: exposure bump + camera nudge (panel top edge sits at the frame boundary)
+ the 10-repeat noise pilot to set thresholds from measured sigma.

**2026-07-11 (night): FIRST REAL OPTICS CAPTURE.** The production CLI
(`recorder.py record` — SSH transport, KOReader backend, injector page turns,
`--camera-lock`) produced the first real bundle from the boxed rig: 186 s of
true MJPG 1080p60 off the Brio (stream-copied, no VFR — `exposure_dynamic_
framerate=0` locked and recorded), schema-v2 session with split illuminant
(153/153, dark-box), panel temps 23→24 °C, and the harvested [pn-refresh]
trace showing 39 partial + 8 full — the full_refresh_count=6 cadence in a
real capture. En route, four more live-found render bugs were fixed (portrait
EBC wedge → landscape-native card; footer/margins splitting views; hardcoded
rendition:orientation; absolute-px img CSS silently dropping the image — found
by dumping /dev/fb0 and looking). Analysis of the first bundle runs offline.

**2026-07-11 (evening): the optics capture stack is live-proven end to end.**
On A.2.6 over SSH, the production path (SSHTransport + KOReaderBackend +
run_scenario) drove a full 49-page card scenario: injector daemon -> uinput
`wilkbook-optics` -> KOReader (opened it as event7) -> 48 injected page turns
-> 48 harvested `[pn-refresh]` events — **39 partial + 8 full, exactly the
seeded full_refresh_count=6 promotion cadence**, i.e. the diff-masked partial
regime real reading uses, measured for the first time. Panel temps recorded
26->27 °C across the run. Three live-found bugs fixed en route (SSH clients
lingering on detached launches -> fire-and-forget transport; fbcon rebound by
reader-session's stop -> unbind in prepare; landscape default splitting
portrait pages into two views -> seed copt_rotation_mode=0 + drop stale .sdr
sidecars). The only thing between here and the first real optics bundle is
pointing the camera at the panel.

**2026-07-10: Wi-Fi working end-to-end — root-caused and fixed live.**
A.2.3 (reader + the Phase 1 Wi-Fi userland) was built, written to os2 (rootfs
SHA `196d601c…`, drop_caches readback-verified) and booted. The userland is
proven over the CDC-ACM console: `wlan0` autoloads, is unblocked, scans; the
`pinenote-wifi` service mounts the `data` partition, reads the credential conf,
and (after a PATH fix — `wpa_supplicant` is in the profile's `sbin` not `bin`,
`82f111c`) launches the supplicant. First boot did **not** connect: the radio
associated but the 4-way handshake timed out (`auth_failures`,
`reason=CONN_FAILED`, `wlan0 DORMANT`) on **both** WPA2-PSK and WPA3-SAE,
regardless of PMF. **Root cause:** the shipped BCM4345/6 firmware (7.45.234,
Apr 2021) mis-negotiates its WPA offloads (FWSUP + SAE) with **wpa_supplicant
2.11** — the reader ships 2.11; Debian os1 ships **2.10**, which is why os1
connects with byte-identical firmware/NVRAM/creds (all `cmp`-verified). A known
brcmfmac bug on this chip family (Red Hat #2302577, raspberrypi/linux #4976),
**not** a driver defect and **not** PineNote-specific. **Fix, confirmed live:**
`brcmfmac feature_disable=0x82000` (disables FWSUP `0x2000` + SAE `0x80000`
offloads → software handshake). Reloading brcmfmac with it on the A.2.3 boot
made the same AP + creds **complete the handshake** (CTRL-EVENT-CONNECTED,
`PTK/GTK=CCMP`), lease `192.168.86.143`, and ping `1.1.1.1` (~12 ms) + `gnu.org`
(DNS OK). Baked into the image two ways (`d911e57`): `/etc/modprobe.d/
brcmfmac.conf` (via the `pinenote-wifi` etc extension) and the kernel cmdline
`brcmfmac.feature_disable=0x82000`. **A.2.4** (with the fix) is the next os2
write. The stuck-WORLD-regdomain and `set_channel … reason -52` observations
were benign red herrings (self-managed-regulatory noise), not the cause.

**2026-07-05: reader first light, then the appliance path.** KOReader
renders and is pen- and finger-navigable on the panel, running
**natively on the framebuffer** (no compositor, no SDL — the cage/SDL
plan died on hardware; see the session section below and
`doc/koreader-spike.md`). Same day, the final image passed the
**unattended-boot test**: power-on → KOReader, no console intervention.

**2026-07-04: the 7.0 forward-port reached hardware parity on the
kernel-currency goals.** The 2026-07-03 fix-stack boot succeeded on every
axis: fbcon text on the panel, USB ACM gadget console working end-to-end
(this session's diagnostics were gathered *over that console*), full
`PREEMPT_RT`, untainted kernel, zero dwc3 errors, zero RT splats.

## 6.6-vs-7.0 parity (historical, mid-July)

| Area | 6.6.30 (m-weigand) | 7.0 forward-port (vanilla via nonguix) |
| --- | --- | --- |
| Boots to Guix userspace on os2 | yes | yes (needs `CONFIG_GPIO_ROCKCHIP=y`) |
| Waveform install (initrd + post-boot service) | yes | yes (2026-07-04: `ebc.wbf` installed; service `running #t` after the udev-ordering fix) |
| EBC display output | yes | **yes** (2026-07-04: healthy probe signature — waveform 0x19, `rockchip-ebc 0.3.0`, `fb0` — and fbcon text visible on the panel) |
| EBC temperature channel (TPS65185 IIO) | yes | **yes** (2026-07-04: `iio:device0` = tps65185, `in_temp_input` = 28000 m°C, via the forward-ported IIO provider) |
| UART console (ttyS2, 1500000) | yes | yes |
| USB ACM gadget console (ttyGS0) | yes | **yes** (2026-07-04: enumerates as `PineNote Guix Gate6 ACM Console`, reader shell works, zero dwc3 errors — `snps,dis_u3_susphy_quirk` fixed `ep0out`) |
| PREEMPT_RT | n/a (not supported on 6.6) | **yes** (2026-07-04: `#1 SMP PREEMPT_RT`, tainted=0, no sleeping-function/atomic splats) |
| Bluetooth firmware (BCM4345C0.hcd) | yes | yes (2026-06-11: `BCM4345C0.pine64,pinenote-v1.2.hcd` patch applied, build 0382) |
| Wi-Fi firmware (brcmfmac43455) | yes | yes (2026-06-11: brcmfmac 7.45.234 loaded on vanilla base — deblob problem confirmed solved) |
| Wi-Fi radio (wlan0 up, scan) | works | **yes** (2026-07-10: wlan0 autoloads, unblocked, stable MAC, scans 6 APs) |
| Wi-Fi WPA association | yes | **yes — needs `brcmfmac.feature_disable=0x82000`** (2026-07-10: firmware WPA offload vs wpa_supplicant 2.11 broke the 4-way on 7.0; fix proven live — handshake completes, DHCP `192.168.86.143`, ping OK. In A.2.4 (`d911e57`) via modprobe.d + cmdline; A.2.3 on os2 lacks it. PATH fix `82f111c` lets the service launch the supplicant) |
| KOReader on the panel (reader flavor) | n/a | **yes** (2026-07-05: native fbdev + evdev, pen- and finger-navigable, frontlight, MB Type fonts; unattended boot validated) |
| SC7A20 autorotation | n/a | **yes** (2026-07-19 final4: all four physical edges, toggle/state replay, contact deferral, and bridge/reader restart recovery hardware-accepted; production mapping TOP1/RIGHT0/BOTTOM3/LEFT2) |
| Finger/pen coordinates under rotation | n/a | **yes** (2026-07-19 final4: cyttsp5 MT axes mirrored from queried ranges; five target residuals <=25 px and small controls hardware-accepted with finger and pen) |

The `pinenote-usb-console` flavor (7.0 forward-port) is the validated primary.
The `pinenote-usb-console-linux-6-6` flavor remains only for regression
isolation; the dated findings below preserve the path by which 7.0 reached
parity and then became primary.

## 7.0 forward-port: findings so far

- The original pre-root stall was a mass deferred-probe failure ("GPIO not
  available": regulators, sdhci vmmc, dwc3 extcon, EBC temperature channel).
  Building the GPIO driver in (`CONFIG_GPIO_ROCKCHIP=y`) fixed it; 7.0.x now
  reaches Shepherd with root mounted from `PNGuixRoot`.
- Wi-Fi could not work on the original linux-libre base: the deblob pass
  disables non-free firmware loading (`/*(DEBLOBBED)*/` request paths in
  brcmfmac), and restoring the names/call paths in the patch was not
  enough. As of 2026-06-10 `linux-pinenote` builds from vanilla kernel.org
  sources via nonguix instead. **Confirmed fixed on hardware** (2026-06-11
  boot): brcmfmac loads firmware `BCM4345/6 wl0 ... version 7.45.234` on the
  vanilla base.
- Bluetooth firmware (`BCM4345C0.pine64,pinenote-v1.2.hcd`) loads despite the
  deblob, after the device-specific alias was added. Reconfirmed on the
  2026-06-11 vanilla-base boot (chip build 0382 after patch).
- 2026-06-10 bracketing experiment: the identical configfs ACM recipe run
  on stock os1 (6.12) binds, enumerates on the host as 0525:a4a7, and
  passes data both ways with zero dwc3 errors. The dwc3, usb2phy, and
  wusb3801/type-C DT nodes are identical (modulo phandle renumbering)
  between the working 6.12 DTB and our 7.0 DTB. The regression is
  therefore in kernel driver code between 6.12 and 7.0 (dwc3 core,
  inno-usb2 phy, or role-switch timing), not in DT and not in our
  userspace sequence.

## 2026-06-11 os2 boot (7.0.11 vanilla, v3 gadget) — log recovered 2026-07-03

The boot reached Shepherd with root on `PNGuixRoot`; UART/tty services,
Wi-Fi, Bluetooth, stylus (w9013 + ws8100_pen) all came up. Four distinct
failures, all root-caused on 2026-07-03 with fixes staged in this repo:

1. **EBC display (the panel blocker)**: `rockchip_ebc` probe failed hard:
   `OF: /ebc@fdec0000: could not get #io-channel-cells for
   /i2c@fe5c0000/pmic@68` → `error -EINVAL: Failed to get temperature I/O
   channel` (terminal, no deferral). Cause: the EBC driver reads panel
   temperature through an IIO channel on the TPS65185 EPD PMIC. The stock
   6.12 downstream kernel patches the TPS65185 driver to register an IIO
   temperature channel and its DTB carries `#io-channel-cells` (verified
   live on os1: `iio:device0` = `3-0068` with `in_temp_input`). Mainline's
   `drivers/regulator/tps65185.c` (new in ~2025) exposes the temperature
   as **hwmon only** — visible in the log as `hwmon hwmon2: temp1_input not
   attached to any thermal zone`. Fix: the forward-port patch now adds a
   minimal IIO temperature provider to mainline `tps65185.c` and
   `#io-channel-cells = <1>` to the `ebc_pmic` DT node.
2. **Waveform post-boot service**: `no waveform source found` — the
   shepherd service only required `root-file-system` and ran before udev
   created `/dev/disk/by-partlabel/waveform`. Fix: require `udev` and add a
   sysfs `PARTNAME=waveform` scan fallback (same discovery as the initrd).
   The initrd-side install (which feeds the in-initrd EBC probe) was fine.
3. **Gadget modprobes all failed**: `modprobe: FATAL: Module ... not found
   in directory /lib/modules/7.0.11`. Two-part cause, verified by chroot
   into the os2 rootfs from os1: Guix's kmod ignores
   `LINUX_MODULE_DIRECTORY` (the setenv in the service did nothing), and
   the raw kernel package has no depmod database — only the kernel
   *profile* (`/run/booted-system/kernel`) carries `modules.dep`. Fix:
   `modprobe -d /run/booted-system/kernel` (chroot-verified to resolve
   libcomposite).
4. **debugfs**: the defconfig had `# CONFIG_DEBUG_FS is not set`, so the
   Guix `/sys/kernel/debug` file-system service looped on EPERM and the
   gadget service could not reach the dwc3 debugfs mode path — the v3
   role-gate then (correctly) refused to bind, so `ep0out` was never
   retested this boot. Fix: `CONFIG_DEBUG_FS=y` in the defconfig.

Also staged 2026-07-03:

- `CONFIG_PREEMPT_RT=y` (full RT preemption is a project goal for
  pen/refresh latency; arm64 supports mainline RT since 6.12). Confirmed to
  survive olddefconfig; built kernel banner reads `#1 SMP PREEMPT_RT`.
- The `eink,ed103tc2` panel-simple entry (see
  `doc/kernel-forward-port.md`) — without it the EBC probe would clear the
  temperature channel and then park forever in `-EPROBE_DEFER` waiting for
  a panel driver that vanilla 7.0 does not have. Caught by adversarial
  review of the fix stack, not by a hardware session.
- `snps,dis_u3_susphy_quirk` on the dwc3 node — targets the `ep0out`
  root cause identified by research: mainline `cc5bfc4e16fc` (6.15,
  stable-backported) sets `GUSB3PIPECTL.SUSPHY` at core init while the
  RK3566 OTG's USB3 PIPE phy is unwired, timing out the first ep0out
  endpoint command. Explains cleanly why vanilla 6.12 worked and 7.0
  failed with identical DT. Note the 6-11 boot also revealed
  `/sys/class/usb_role` is empty on this DT (wusb3801 registers no role
  switch), so the v3 gate passes vacuously and proceeds to the debugfs
  mode write once debugfs exists.

## Current os2 contents

**The newest deploy entry at the top of this file is the authority for
what os2 holds** — this section is a pointer plus a historical deployment
ledger, so it cannot rot silently again. As of 2026-08-06 os2 holds the
**vdd_cpu auto-PFM reader image `1a582179…`** (deployed from the p7
staged copy; boot acceptance passed 2026-08-06 — see
`doc/artifacts/pinenote-awake-levers-20260806/`). It carries the full
2026-08-03 stack — auto-suspend live with charging inhibit and the
power-button tap, the SC7A20 resume fix — plus cpuidle and the refresh
seed. The intermediate 2026-08-02/03 deployments are recorded in their
dated entries above. Note the 2026-08-03 staged-image cleanup: only the
current and previous images remain staged; older staged copies named
below were removed.

Ledger (oldest deployments last): the previously installed **2026-07-28
signal-safe dormant EBC adapter candidate** had SHA
`1777dde4c5febd7eaaf9d763b422b48ab7d24ca5c75a615bc966406cf973ae64` —
written from stock os1 with exact-range readback verification, staged copy
`/home/user/pinenote-reader-ebc-adapter-release-reviewed-20260727.ext4`.
(Its record here once said "this image has not booted"; it booted
2026-07-29 and its diagnostic passed on 2026-07-30 — see the dated
entries above.) The previously installed 2026-07-27 EBC generation-barrier reader
candidate had SHA
`c15d023159e130633db87a0df742248ef5be2ac6e9aece9d4fc83f73c59cfd4d`
and staged copy
`/home/user/pinenote-reader-PNGuixRoot-20260727-ebc-barrier.ext4`. That exact
image booted from os2 and passed the read-only reader/containment acceptance
recorded above; production had no barrier UAPI caller. The previously installed
2026-07-26 BSP PM OF-name
fix reader candidate had SHA
`0c67785ff434bac66e3652e940c1d088e2c242cf6dfd132fc66fd8e2b8f97f4f` and staged
copy `/home/user/pinenote-reader-PNGuixRoot-20260726-bsp-pm-namefix.ext4`.
That exact image booted from os2 and passed the activation-hard-off bind and
reader-health acceptance recorded at the top of this document; no suspend was
attempted. The previously installed 2026-07-26 BSP PM
review-fix reader candidate had SHA
`0d5c432d5db8291d023c8061d364745f820f8391d8264444a19882dc6330fef6` and staged
copy `/home/user/pinenote-reader-PNGuixRoot-20260726-bsp-pm-reviewfix.ext4`. Its
unplugged boot and read-only SSH acceptance confirmed the exact os2
root/system/kernel and a healthy reader stack. The PM driver remained unbound
only because the old parser rejected Linux OF's standard `name` metadata; no
backend or suspend action occurred and no suspend was attempted. The previously
installed 2026-07-25 BSP SIP probe-only reader
candidate had SHA
`e64bc5e495aa5b865354b2fe5afa30adc05e8182084887f3c42970daf7d13289` and staged
copy `/home/user/pinenote-reader-PNGuixRoot-20260725-bsp-sip-probe.ext4`. It
booted from os2 with the exact matched boot bundle and `conservative` governor;
the reader stack was healthy, but the probe-only driver returned `-EOPNOTSUPP`
from its ambiguous two-call legacy version gate and did not bind. No suspend was
attempted. The previously installed 2026-07-20 RK817
telemetry candidate had SHA
`92837467ba2c0714bdef595d0a2f247536a82aa4dbcb80774902f4d0c1dac189`; its
staged copy is `/home/user/pinenote-reader-PNGuixRoot-20260720-telemetry.ext4`.
Its first boot and RK817 telemetry acceptance were confirmed 2026-07-24, with
no suspend attempted. The previously installed and hardware-accepted final4
2026-07-19 autorotation reader build had SHA
`d64b1e820d37071108a361f97fd1383630bd36a97b536e4c157407fd4db8fbdc`; its
staged copy is
`/home/user/pinenote-reader-PNGuixRoot-20260719-final4.ext4`.
**First boot and full acceptance confirmed 2026-07-19:** bridge/reader startup,
MSC_RAW delivery, four-pose rotation, toggle/state replay, contact deferral,
finger/pen accuracy, and bridge/reader restart recovery all passed. No temporary
userpatch is present. The superseded corrected-ioctl final3 image had SHA
`5df3aceed5cf565cd2ceffc05684e028b9479aa35c0c88a8b51298fc02f64512`;
it proved uinput delivery but required the temporary combined A/B patch because
its mode table was opposite the final verdict and it lacked touch-axis mirroring.
The superseded 2026-07-18 autorotation reader record follows: SHA
`e27da1abc87ff4b564112a3cf5ea8a7910699d20f2800577c9007778779f7562` —
**written 2026-07-18** with the full protocol (stock Debian os1 root confirmed
at `/dev/mmcblk0p5`, p6 unmounted, staged artifact SHA-matched, exactly
1,945,268,224 bytes written with `dd conv=fsync`, and readback of that exact
range SHA-matched from eMMC). The staged copy is
`/home/user/pinenote-reader-PNGuixRoot-20260718-autorotation.ext4`.
**First boot confirmed 2026-07-18.** Both orientation and reader services came
up cleanly; the first committed state was mode 1 and KOReader painted a rotated
1404x1872 full refresh. The live state then traversed modes 0 and 1. Restarting
`orientation-bridge` deliberately proved the dependency/recovery path: Shepherd
stopped and relaunched KOReader around the replacement bridge and named evdev,
with fresh consumer and state files and no logged error. This is the production
reader flavor with the SC7A20
buffered-IIO orientation bridge, KOReader source-gated gyro adapter, contact
deferral, autorotation toggle/state replay, and bridge/reader restart recovery.
The final offline ladder passed the orientation and KOReader input suites,
system/rootfs builds, rung 4 service assertions, and rung 4v paint/tap loop.
**Hardware verdict: superseded.** Its virtual node declared EV_MSC but no MSC_RAW
code, so no orientation frame reached KOReader. The corrected-ioctl final3 image
replaced it; the fully corrected final4 artifact and accepted hardware verdict
are recorded at the top of this file.

The superseded A.2.8-dbg record follows: SHA
`34bde60c77c407336afe344f6829beaf70d540c29430352709e1315368165312` —
**written 2026-07-13** with the full protocol (os1 root confirmed at
`/dev/mmcblk0p5`, p6 unmounted, `dd conv=fsync`, readback of the exact
1 945 407 488-byte range SHA-matched from eMMC). Staged copy on os1 at
`/home/user/wilkbook-artifacts/pinenote-reader-debug-PNGuixRoot-20260712-a28.ext4`.
**First boot confirmed 2026-07-13, all green:** the wifi one-shot came
up UNASSISTED via the mounted /data (the A.2.7 mount-conflict fix
works); the ttyS2 getty service is gone (exactly one base agetty);
boot ebc-dbg globals clean on the FIXED kernel; the reading-position
sidecar (.sdr) survived the reflash beside the book on /data.
**EXTRACT_FBS smoke ride PASSED**: `ebc-dump-grab --verify` produced a
9,199,048-byte double-read-stable dump under the live DRM master, and
the host `ebc-dump` decoder rendered the driver's belief planes — the
decoded `final` buffer is a pixel-faithful image of what KOReader had
on screen. The belief-vs-glass instrument is live end to end. (Note:
os1 now leases the same MAC-pinned address as os2; host keys differ
between the OSes.)
A.2.8-dbg = A.2.7-dbg + **hrdl's fixes for findings 1/2/7 in the primary
kernel** (the finding-2 scheduler fix doubles as the quirk-2 corruption
A/B — if overlap is the mechanism, corruption dies on this kernel) +
**EXTRACT_FBS** in the debug kernel (belief-vs-glass instrument;
`pinenote-ebc-dump` grabber in the image; idle live-DRM smoke passed) + the
ttyS2-getty removal and the wifi-one-shot /data-mount fix (both
live-mitigated on the current A.2.7-dbg boot, baked in here). All 385
offline checks green at build.

The superseded A.2.7-dbg record follows: SHA
`7620b453f7dec9ad49c2693b20fae2edb4df2659cb6928aa0bc6e1861251becb` —
**written 2026-07-12** with the full protocol (os1 root confirmed at
`/dev/mmcblk0p5`, p6 unmounted, `dd conv=fsync`, readback of the exact
1 945 235 456-byte range SHA-matched from eMMC). Staged copy on os1 at
`/home/user/wilkbook-artifacts/pinenote-reader-debug-PNGuixRoot-20260712.ext4`.
**First boot pending.** A.2.7-dbg = the production reader flavor + the quirk F
diagnostic kernel `linux-pinenote-debug` (primary kernel byte-identical + one
printk-only DSP_END straggler-instrumentation patch; host name
`pinenote-reader-dbg`). Userspace additions over A.2.6: the hardware-validated
idle-washer plugin grafted into koreader-bin, `auto_refresh=0` in the params
one-shot + modprobe.d (finding 10), the `/data` mount (by partlabel) + KOReader
`home_dir=/data/books` first-boot seed, and **the `wait-cr` UART getty fix**
(the PID-1-killing respawn loop from the 2026-07-12 wedge post-mortem). The
superseded A.2.6 record follows.

A.2.6 — **boot confirmed 2026-07-11; carried the entire optics campaign**
(calibration, sweeps, the 2x2 isolation, idle-washer acceptance, five
instrumented corrupter repros) until the 2026-07-12 PID-1 wedge (post-mortem
above; not an image-data fault — p6 e2fsck clean). SHA `1a1e1366…`; staged
copy remains on os1 for rollback. A.2.6 = A.2.5 + the integrated optics
blocker work (the `wilkbook-optics` injector whitelist + configurable flash
fraction in the koreader graft) + the `/var/empty` sshd activation fix (first
image where SSH needs no manual step). The superseded A.2.5 (`e0e7735c…`)
staged copy remains on os1 for rollback; its record follows.

A.2.5 — **first boot confirmed 2026-07-11**: Wi-Fi auto-joined again (note: dhcpcd
mints a fresh DUID per reflash, so absent a router-side reservation the DHCP
lease drifts across flashes). One bug found + fixed live: the image ships `/var/empty` owned by a
build-container uid (998:981), so sshd fatal'd on every connection
("/var/empty must be owned by root..."); `chown root:root; chmod 555` fixed it
on-device (persists on this image), and an activation snippet in the reader
flavor re-asserts it for future images. **SSH verified end to end**: key-only
`root@` login + scp round-trip; the test card epub is staged at
`/root/optics-testcard.epub` over scp. The device is fully operable over Wi-Fi
with no USB cable. A.2.5 = A.2.4 + **key-only SSH** (`openssh-service-type`,
`PermitRootLogin prohibit-password`, `PasswordAuthentication no`, operator's
ed25519 key authorized for root) so the device is reachable over Wi-Fi with the
USB cable removed (also the recorder's SSHTransport). Host keys regenerate on
reflash (persistent `/data` host keys are a follow-up). The superseded A.2.4
(`54579bab…`) staged copy remains on os1 for rollback.

**Superseded pre-deployment A.2.6 record:** the built local rootfs was
`pinenote-reader-PNGuixRoot-20260711-a26.ext4`, SHA
`1a1e13669a17e258487d6f78d862517c9765b9f172e962e52e63ce4cc2bb9b68`; payload
checks PASS; verified to carry the optics device.lua changes — the
`wilkbook-optics` injector whitelist + G_reader_settings flash fraction — plus
the `/var/empty` sshd activation fix, so SSH works with no manual step). It was
A.2.5 + the integrated optics blocker work and subsequently booted and used for
the optics campaign recorded above.

A.2.4 (Wi-Fi, first-boot-confirmed 2026-07-11: cold boot brought the full chain
up on its own — `feature_disable` applied, `wlan0` associated to `<home-ssid>`,
DHCP `192.168.86.144`, ping + DNS OK) = the **Phase 1 Wi-Fi userland**
(`pinenote-wifi` service +
`wpa_supplicant` + `dhcpcd`, out-of-band conf on the `data` partition;
`doc/networking.md §4.1`) **plus the confirmed brcmfmac Wi-Fi fix**
(`feature_disable=0x82000` via modprobe.d + kernel cmdline, `d911e57`; the
`82f111c` PATH fix). Wi-Fi credentials for SSID `<home-ssid>` are pre-staged
on the `data` partition (`0600`, persists across reflashes). The superseded
A.2.3 (`196d601c…`) and A.2.2 (`b166d869…`) staged copies remain on os1 for
rollback.

**Historical A.2.4 build record (written and first-boot-confirmed 2026-07-11;
now superseded):** local rootfs SHA
`54579babf4462d05b4c572f6e09849f9f1f21e2bcd4a7054bfd50a8f6f49a4a7`,
cmdline-verified to carry `brcmfmac.feature_disable=0x82000`. It was A.2.3 plus
the confirmed Wi-Fi fix (the two `feature_disable` mechanisms + the `82f111c`
PATH fix). A.2.3 associated but could not complete WPA without that option;
A.2.4 was the first build to bring Wi-Fi up automatically on boot.

Over A.2 it carries three fixes, each found on (or predicted by) the
A.2 first boot the same night and proven offline before this write:
the refresh_waveform config bug (the ebc-params one-shot now sets
GL16; inert cmdline tokens removed; rung 4 asserts the live value,
`VIRTCHK-WF-6`), the boot blank upgraded to a GC16 deep clean, and the
TOC-tap fix (`mixedrouter.lua` src-aware slot routing, proven on the
`koreader-input` harness). Rungs 4 (all-green, incl. the new
live-parameter assertion) and the host suites ran on this exact
rootfs. It supersedes the intermediate A.2.1 (`4b97c382…`, config
fixes only, rung-4 green, never written — its os1 staged copy can be
deleted) and the first-booted **A.2** (`52cf8e8a…`, session record
below; its staged copy remains on os1 at
`pinenote-reader-PNGuixRoot-20260705-a2.ext4` for rollback).

Phase A.2 adds over the phase A build it replaced: GL16 global refreshes
(`rockchip_ebc.refresh_waveform=6` — the full wash no longer drives the
white background through a negative; doc/refresh-policy.md has the
waveform decode and the replay-study numbers), the input-architecture
rework (handleMixedTouchEv + per-source event conditioning: two-finger
gestures structurally fixed, palm-while-pen ghost taps fixed, ws8100
pen-button page turns), and the rung-4v tap-path fix. Rungs 4 and 4v
green on this exact rootfs (the 4v tap now provably works: the scripted
tap word-selects in the quickstart and opens the dictionary dialog in
the screendump).

Superseded same-day predecessors, each booted and validated: the
evening phase A build (`f4e0cd5d…` — booted and judged: wash + quiet
menus good, no ghosting; full-refresh black flash and input feel
raised), the midday build (`0a8a55c2…` — unattended boot, touch, pen,
frontlight, MB Type fonts all validated; see the session records) and
the morning build (`40393404…` — touchscreen probed, but KOReader
white-screened on the missing KO_HOME; hotfixed live).

Phase A adds over the validated midday build (offline gates green,
optics judgment pending): the >=60%-area flash policy (menus stop
washing the whole panel), the pre-KOReader panel blank+wash (boot text
no longer lingers), `[pn-refresh]` intent tracing to
/var/log/reader-session.log, and the virt-only virtio-gpu/input
modules + probe token for the rung-4v visual loop.

Contents carried over from the earlier 2026-07-05 builds:

- KOReader **native fbdev** device target grafted into `koreader-bin`
  (pen input via pure-Lua evdev backend, frontlight/battery powerd,
  full refresh = EBC `GLOBAL_REFRESH` ioctl); reader-session service
  runs `luajit reader.lua` directly and unbinds fbcon for the session.
  cage/seatd are gone from the image.
- Boot fixes for everything recovered by hand on 2026-07-04: gadget
  service requires `file-systems` (debugfs EBUSY race); waveform +
  ebc-params scripts export a PATH (shepherd runs them env-empty);
  koreader.sh shebang no longer x86_64-mangled (shebang phases deleted).
- **cyttsp5 touchscreen DTS node** (`cypress,tt21000` on i2c5 +
  pinctrl) added to the forward-port patch — driver was already `=m`
  but mainline's DTS has no node (neither does hrdl's tree; taken from
  m-weigand's). **Validated on hardware 2026-07-05**: native screen
  coordinates, finger navigation works.

First-boot checklist for the phase A (`f4e0cd5d…`) artifact: boot text
washes to clean white before KOReader appears; menu open/close updates
without a whole-panel flash; ghosting from un-flashed overlays stays
tolerable (note where it does not — that calibrates the phase B
workbench); everything from the midday build still works (unattended
boot, touch, pen, frontlight, fonts). Harvest
`/var/log/reader-session.log` afterwards — it now carries the
`[pn-refresh]` intent trace.

The previously deployed `pinenote-reader-PNGuixRoot-20260704.ext4` (SHA
`23e597fd…`) was **booted and live-debugged 2026-07-04/05** — session
record below; its staged copy remains on os1 for rollback.

## 2026-07-05 (night) phase A.2 first boot — pinch validated, two bugs found live, one fixed in-session

The A.2 build (`52cf8e8a…`) booted unattended to KOReader. Debugging ran
over the ACM gadget console with the user present; the device was
rebooted to os1 before the visual GL16/GC16 A/B was judged, and the
post-mortem harvest below completed the session offline.

**Validated on hardware:**

- **Two-finger pinch-zoom works** — the input-architecture rework's
  structural fix (handleMixedTouchEv + per-source conditioning)
  confirmed on the panel.
- **GC16 deep-clean scrubs believed-white residue** — see below; this
  was demonstrated live and is now the boot-blank behavior.

**Bug 1 (config, root-caused and fixed same session):** the live
`refresh_waveform` read **4 (GC16), not 6** — the A.2 GL16 policy never
applied. Root cause: the Guix initrd raw-loads `rockchip_ebc` with
`load-linux-modules-from-directory`, which passes no module parameters;
`module.param=` kernel-cmdline tokens only reach loadable modules via
modprobe (which reads /proc/cmdline), so every `rockchip_ebc.*` cmdline
token we ever shipped was inert — the other parameters only ever worked
because the `pinenote-ebc-params` one-shot re-applies them post-boot,
and that script did not set `refresh_waveform`. Worked around live
(sysfs write), then fixed in the repo: the one-shot now sets
`refresh_waveform 6`, the modprobe options line is synced, the dead
cmdline tokens are removed, and **rung 4 now asserts the live sysfs
value from inside the guest** (`VIRTCHK-WF-6`) — the gate that would
have caught this before the device did.

**Residue diagnosis (user's question answered):** the black background
texture was fbcon boot-text residue in believed-white pixels. The boot
sequence (panel blank partial + global) ran under GC16 this boot so it
*should* have scrubbed — but the boot wash raced KOReader's own first
washes; a deliberate GC16 global fired live via the ioctl visibly
scrubbed the residue. Under the intended GL16 policy such residue would
*never* scrub (GL16's white→white sequence is neutral), so the
reader-session boot blank now runs its wash as an explicit GC16 deep
clean and restores the shipped waveform after (validated live).

**Bug 2 (root-caused and fixed offline, same night): the TOC-tap
bug.** Tapping a link in the quickstart guide's table of contents
always navigated to the same wrong destination ("the user interface
page"), regardless of the link tapped; pinch and menu navigation
worked. Diagnosis ran entirely offline (os1 oracle + a 19-agent
adversarially-verified read of the KOReader input stack and the
mainline cyttsp5 driver source): KOReader's single global `cur_slot`
gets parked on the dedicated pen slot by BTN_TOOL_PEN:1 — pen *hover*,
no contact needed — and the kernel's ABS_MT_SLOT dedup means a
single-finger session never re-routes it. So while the pen hovered,
every finger tap was written into the pen slot, where live pen-hover
coordinates rewrote the contact mid-gesture into a swipe along the
finger→pen bearing; swipe = one page forward, and from the quickstart
TOC one page forward IS the "User interface" page (also the first
link's target). It explains all three facts at once: constant wrong
destination (fixed hand posture), working pinch (explicit slot events
+ two-handed so the pen is away), working menus (pen stowed). The os1
oracle had already exonerated the DT axis config (identical
touchscreen node on the working stock system). Fixed in our device
layer (`mixedrouter.lua`: src-aware slot routing, commit cf670ed) and
proven on the new `koreader-input` host harness (rung-2-style: the
verbatim bundle input stack, synthetic event streams — bug reproduced
without the router, tap lands correctly with it, pen/pinch/baseline
guarded; commit 776da5b). Hardware confirmation pending the A.2.2
boot: tap TOC links with the pen held near the glass. The underlying
src-blind cur_slot design should be reported upstream to KOReader (it
bites every wacom_protocol + multitouch device).

**Post-mortem harvest (via the os1 oracle, p6 mounted read-only):**
`/var/log/reader-session.log` recovered — the first **real device
`[pn-refresh]` trace** (59 events / 153 s), committed as
`pinenote/tools/ebc-logic/traces/2026-07-05-a2-first-boot.trace`.
Replayed on the phase B workbench: settle med 38 frames / 447 ms —  *(Frame-clock recalibration 2026-07-30: the frame counts are correct and
invariant; the millisecond figure was on the wrong 85 Hz basis and is ~596 ms
at the driver's real 63.744 Hz. Left as recorded — see doc/refresh-policy.md.)*
matching the synthetic study exactly; and the GC16-as-run vs GL16
comparison on real usage reproduces the synthetic 2.3× ratio (385M vs
165M wash px-phases; 9.19M believed-white px driven dark per wash cycle
vs zero). The real session fired 22 global washes in 153 s — under
GC16 that is a black flash every ~7 s, matching the felt experience.

**Still pending from the A.2 checklist:** the GL16 wash optics verdict
(the "letters shimmer, not negative flash" judgment) — the session
never ran long under true GL16. The **A.2.1** build with the config
fixes is staged (ledger below).

## 2026-07-04/05 reader first light (os2 boot of the 20260704 artifact)

The boot validated the base system again (kernel 7.0.11 PREEMPT_RT
tainted=0, cherry-picked driver healthy, gadget console up after manual
recovery) and produced a chain of findings that ended with KOReader
working. Everything below was diagnosed and worked around **live over
the ACM console**, then turned into the staged fixes above.

Boot-time service failures (all now fixed in-repo):

- The gadget service raced the fstab mounts to `EBUSY` on debugfs,
  cascading into every dependent service; recovered live with
  `umount`/`herd start`. Fix: require `file-systems`.
- `pinenote-ebc-params` died with exit 127: shepherd one-shots run with
  an empty environment and the script needs `cat`. The waveform script
  only survived by luck (its early-exit path is all shell builtins).
  Fix: both scripts export PATH.
- KOReader couldn't launch via `bin/koreader`: cross `patch-shebangs`
  had rewritten `koreader.sh`'s `#!/bin/sh` to a build-machine x86_64
  bash ("Exec format error"). Fix: delete the shebang phases.

The display mystery (why the panel showed console text while the kiosk
"ran"), root-caused in three layers — full narrative in
`doc/koreader-spike.md` §3:

1. **fbcon stomps the compositor.** `console=tty0 ignore_loglevel`
   means every kernel message redraws fbcon, and the DRM fbdev
   emulation's flushes commit over the compositor's frames (observed
   as 1872×1392 full-frame blits at ~8 Hz with `drm.debug=0x2`, which
   itself feeds the loop). cage's own frames *were* reaching the
   panel — and being immediately overwritten. Unbinding fbcon
   (`vtcon1/bind=0`) gave cage the panel: uniform gray + software
   cursor, confirmed visually.
2. **SDL3 first-frame deadlock under wlroots** (frame callback
   requested on a surface that's then unmapped; wlroots never fires
   it; SDL parks in `ppoll` forever, 0 CPU).
3. **SDL3 cannot present on Wayland without GL/Vulkan** — SDL3 has no
   software present path (SDL2 did). The device has neither; the
   renderer cascade fails and KOReader ignores the failure and runs
   blind. This killed the kiosk architecture, not just a configuration.

The pivot, built and validated the same session: KOReader's own e-ink
architecture (fbdev + evdev, as on Kobo). Verified `/dev/fb0` mmap
writes reach the panel via deferred-io (luajit one-liner, black band
visible) before writing the port. Then the native device target
(`pinenote/packages/koreader-device/`) brought first light:

- `initializing for device PineNote`; quickstart guide rendered on the
  panel after a `GLOBAL_REFRESH` wash; **pen taps navigate the UI**
  (w9013 axes 20966×15725 auto-scaled to 1872×1404, no axis swap
  needed); user exited KOReader from its own menu.
- Frontlight confirmed working this session via the sysfs backlights
  (cool=60/warm=140 were set live; powerd now drives the same knobs).
- **No finger touch**: `/proc/bus/input/devices` shows no touchscreen —
  `CONFIG_TOUCHSCREEN_CYTTSP5=m` was set but no DTS node exists in
  mainline (or hrdl); node now staged from m-weigand's tree.
- Driver observability gaps found while debugging, for the config
  wishlist: `EXTRACT_FBS` ioctl is stubbed `-EOPNOTSUPP` in the 7.0
  port (the buffer-dump oracle is unavailable on-device) and
  `CONFIG_DYNAMIC_DEBUG` is off (`drm.debug` sufficed).
  *(Update 2026-07-13: EXTRACT_FBS is now implemented in the
  `linux-pinenote-debug` kernel — `linux-pinenote-debug-extract-fbs.patch`,
  offline-proven by the ebc-logic dbg suite; grabber `ebc-dump-grab`
  ships in the reader-debug image, host decoder `ebc-dump` in
  pinenote/tools/ebc-logic. The idle `--verify` on-device smoke passed under
  the live DRM master and decoded a pixel-faithful KOReader screen; a
  mid-scribble sample remains. The primary kernel keeps the stub.)*
- The pen pressure warning `w9013 … Ignoring pressure offset greater
  than 50%` appears whenever libinput handles the pen (cage runs);
  KOReader's evdev path doesn't involve libinput. Park for the pen
  polish pass.

Previous os2 contents (2026-07-03, hardware-validated 2026-07-04):
`pinenote-usb-console-PNGuixRoot-20260703.ext4`, SHA
`4cab03b25c2c80ae6a3c22147f30c1022fcfe3e9f787ab302d8dbc9e034ea43e` —
staged copy still on os1 if a rollback write is wanted.
- Contains the full 2026-07-03 fix stack: TPS65185 IIO +
  `#io-channel-cells`, `eink,ed103tc2` panel-simple entry,
  `snps,dis_u3_susphy_quirk`, `CONFIG_PREEMPT_RT=y`,
  `CONFIG_DEBUG_FS=y`, waveform-service udev ordering + sysfs fallback,
  gadget `modprobe -d` fix.
- This replaces the 2026-06-10 artifact whose boot produced the
  2026-06-11 log above. Next os2 boot is the first observation of the
  whole stack.

## 2026-07-04 boot session (fix-stack validation — all green)

The os2 boot of `pinenote-usb-console-PNGuixRoot-20260703.ext4` validated
the entire 2026-07-03 fix stack. Diagnostics gathered live over the ACM
gadget console itself (the strongest possible evidence for the gadget
fix):

- `uname -a`: `Linux pinenote-usb-console 7.0.11 #1 SMP PREEMPT_RT 1
  aarch64`. `tainted = 0`. No RT splats in dmesg.
- EBC: `rockchip_ebc_probe start` → `Loaded 4-bit PVI waveform version
  0x19` → `Initialized rockchip-ebc 0.3.0` → `fb0: rockchip-ebcdrm` —
  identical to the healthy 6.12 signature; fbcon text visible on the
  panel. Benign residue: `panel-simple: Expected bpc in {6,8} but got: 4`
  (warning only) and a missing optional
  `rockchip_ebc_default_screen.bin` (could ship one later).
- Temperature: `iio:device0` = `tps65185`, `in_temp_input` = 28000
  (28 °C) — the forward-ported IIO provider feeding per-refresh LUT
  selection.
- Gadget: host enumerates `PineNote Guix Gate6 ACM Console`
  (1d6b:0104 composite); `dmesg | grep -iE "dwc3|ep0"` is **empty** —
  the `snps,dis_u3_susphy_quirk` DT fix eliminated the `ep0out` failure.
- Services: `pinenote-waveform`, `pinenote-usb-acm-gadget`,
  `pinenote-usb-acm-console`, `pinenote-ebc-params` all
  `running`/`#t`; `/lib/firmware/rockchip/ebc.wbf` installed this boot.
- Remaining dmesg errors, both known/benign: `No available vop found`
  (PineNote has no VOP — EBC is the display) and the pre-existing
  `ws8100_pen` status-property `-74` quirk (also present on 6.6).

## 2026-07-04 display exercise (same boot, over the ACM console)

- `pinenote-ebc-test --draw-smoke`: white square drawn and restored.
- 16-step grayscale ramp written to `/dev/fb0` (XRGB8888, 1872×1404,
  stride 7488) with plain `dd`/`tr` — all 16 levels rendered.
- `GLOBAL_REFRESH` ioctl (`0xC0016440` on `/dev/dri/card0`) triggered
  successfully **from stock Guile via the FFI** — no compiled tools
  needed on the device. Packaged as `pinenote-ebc-refresh` in
  `pinenote-ebc-test` for future images.
- The device's own waveform was pulled over the ACM console (base64,
  ~1.5 s for 2 MiB) and SHA-verified against the device copy
  (`ba3d4883…`); preserved at
  `~/pinenote-backup/2026-07-04-wbf-pull/` and used as the input for the
  new host-side parser tests (`pinenote/tools/wbf/`, ladder rung 1 —
  all tests pass; see `pinenote/tools/wbf/README.md` for what the
  waveform contains).

## 2026-07-05 (late, offline) phase B trace-replay workbench built and its first study run

The display-quality program can now iterate without the device.
`ebc-replay` (third binary in `pinenote/tools/ebc-logic/`, in `make
ebc-logic-check`, all suites green with and without `WBF=`) replays
KOReader `[pn-refresh]` traces through the **verbatim driver's refresh
thread** on the rung-7a fake device with an 85 Hz frame-clock model,
re-deciding every intent under a candidate policy. It models the two
layers the trace does not record — fbdev deferred-io page-band damage
and the driver's auto-refresh accumulator — and reports washes by cause,
a per-wash black-flash census (believed-white pixels driven dark),
pixel-phases, per-event settle latency, and end-of-session scrub
staleness. Deterministic; seconds per run at `scale=2`; synthetic
sessions via `ebc-replay synth` until real traces are harvested.

First study (120 synthetic pages, results + table in
`doc/refresh-policy.md`): the A.2 GL16 decision quantified (12.0 M
believed-white pixels driven dark per session under GC16 fulls, zero
under GL16, at 2.3× fewer wash pixel-phases); **full_refresh_count's
scrub value collapses under GL16** (staleness identical at full-every
6/12/never — a GC16 "deep clean" action is now the load-bearing residue
answer); settle = 38 frames/447 ms [see 2026-07-30 frame-clock recalibration:
~596 ms at the real 63.744 Hz] per GC16 partial page turn, scheduler
overhead zero; modeling the device's real ~50 ms deferred-io lag
(`defio-delay-ms=50`) reproduces the "draws black then redraws" verdict
mechanically — the wash ioctl beats the flush, inverts the *old* page,
and a follow-up partial draws the new one (+22 % partial work); and a
new driver finding, reported not patched (ebc-logic README finding 7,
executed as a discriminating `quirk:` test): **manual global washes
never reset the auto-refresh accumulator**, so auto washes fire on
partial-damage volume regardless of interleaved user washes.

The tool went through a 19-agent adversarial review before landing;
the two highest-severity catches (content painted across the whole
deferred-io band would have defeated diff-masking and faked the
staleness metric; globals due mid-wash could mint a phantom wash
misattributed to "auto") were fixed and the study re-run — headline
conclusions unchanged, numbers corrected.  One harness fix rode along:
the shim's DMA handle allocator wrapped to the error-sentinel handle 0
after 192 mappings (only long replay sessions allocate that many).

## 2026-07-05 (evening, offline) refresh-policy phase A built — NOT yet on hardware

Built and offline-validated the first refresh-policy pass plus its
tooling; **no hardware validation yet** (the deployed os2 image predates
these changes). New artifact `pinenote-reader-PNGuixRoot-20260705.ext4`
SHA `f4e0cd5d745a5e963aadc69f4a0e40a9c8b914c054e93755d9334d6fce0e9c98`
carries: (1) device-target refresh policy v1 — flashui/flashpartial no
longer always fire the whole-panel GLOBAL_REFRESH; they wash only when
damage covers >=60% of the panel, so menu open/close stops blinking the
screen (ghosting is cleared by KOReader's every-N-pages full refresh);
(2) every refresh intent traced as a `[pn-refresh]` line in
/var/log/reader-session.log (the capture side of the replay workbench);
(3) reader-session blanks the panel white + one global wash before
KOReader spawns, so retained boot text disappears immediately; (4)
kernel gains virtio-gpu/virtio-input modules (virt-only, invisible on
hardware) and the KOReader probe honors the harness-only
`wilkbook.force_device=pinenote` token. Offline gates: rung 4 all green
on the new image, and the new **rung 4v visual loop** (`make
qemu-virt-visual`) passed first try — QMP screendumps show the KOReader
quickstart rendered in Equity at 1872x1404 on the virt framebuffer, and
a scripted tap dismissed a toast (input path proven; shots in the run
directory). **os2 write done same evening** (full protocol, readback-SHA verified
byte-exact) and **booted + judged the same evening**: boot-text wash
works ("boot worked right"), menus are "a bit better", **no real
ghosting observed** from the un-flashed overlays, overall verdict
"pretty awesome". Remaining optics complaint: the periodic full refresh
(every 6th page turn, KOReader's default) is "very flashy... a lot of
black" — that is GC16's inversion drive, the next policy target (can
the global use a gentler waveform? how few fulls can we get away with,
given ghosting stayed invisible?). Separate finding: stylus+touch UX
"feels wrong" — input-architecture rework queued (prefab survey).

## 2026-07-05 os2 write: final reader image deployed (unattended boot pending)

Wrote `pinenote-reader-PNGuixRoot-20260705.ext4` (SHA
`0a8a55c253119249da44ef8421f538deb82b2d1899beb3164cc318ad68a1894c`,
1 903 083 520 bytes) to `/dev/mmcblk0p6` from os1 over SSH with the full
protocol (os1-root confirmed, p6 unmounted, dd with fsync, readback-SHA
verified byte-exact). This supersedes the first-light build that was on
os2, which predates the KO_HOME fix and white-screens on unattended
boot. What's new in this image vs. what os2 held: KO_HOME set by
reader-session (fixes the cache-init crash loop), MB Type fonts staged
with Equity A / Concourse 4 / Triplicate A Code defaults (Noto
fallbacks), cyttsp5 finger-touch DTS node, and the three boot-service
fixes. All offline gates green at deploy time, including the completed
rung 4 (full service stack + clean poweroff asserted in-guest, 2×
consecutive).

**Unattended boot: VALIDATED same day.** Will booted os2 with no console
intervention and KOReader appeared on the panel. Read-only ACM check
confirmed the reader process (`luajit reader.lua`, PID 318 — a low PID,
i.e. one clean start, no respawn churn). The ACM console on this image
lands in the unprivileged reader shell (`pinenote-acm$`), so root-side
herd/syslog checks need the UART or os1 post-mortem instead. This
closes the appliance-path milestone: power-on → reader, hands off.

**Validated in the same session:** frontlight brightness, finger touch
(cyttsp5), pen, and the **MB Type reading fonts** — Will confirmed
Equity A active in the book view (the UI chrome stays Noto Sans by
design; only the reading fonts are seeded). Known rough edge, expected:
**page turns flash** — the driver global-refreshes past
`refresh_threshold=60` and a page turn damages ~100% of the panel, so
every turn is a full refresh. That is the refresh-policy tuning work
(ROADMAP §4), not a regression.

## 2026-07-05 the qemu-virt "udev deadlock" was never a deadlock — rung 4 now asserts the full service stack

The 2026-07-04 "virt deadlocks entering udev" finding (below) is
**retracted**. The guest boots to completion every time; what stops is
the *console log*, deterministically, by design:

- Shepherd (PID 1) routes its messages through `call-with-syslog-port`
  (`comm.scm`): it first tries to connect to **/dev/log** and only falls
  back to `/dev/kmsg` (which is what reaches the serial console) when
  that fails. Shepherd 1.0's built-in **system-log service starts
  listening on /dev/log ~5 s into boot**, and from that moment every
  shepherd message — including `Service udev has been started` and the
  one-shot completions — goes to **/var/log/messages** and the console
  goes dark. All nine captured boot logs stop at the exact same place
  (the loopback/udev-logger lines at guest t≈5.2 s). 100% deterministic;
  there was never a per-boot race.
- What looked like "login unsticks the wedge" was observability, not
  causation: logging into a "wedged" guest and running `herd status
  udev` showed *"It is running since … (3 minutes ago)"* — it had
  completed long before, on its own. `ps` in the same guest showed the
  whole stack up: udevd, nscd, six gettys, and the reader-session
  **luajit process running** (KOReader). /var/log/messages holds all
  the "missing" lines.
- The theory-killing experiment: the interim harness poked a quiet
  guest with four *clean* root-login/`herd`/`exit` cycles — every one
  executed perfectly (login, prompt, herd reply, logout, getty respawn),
  proving shepherd's SIGCHLD handling, process monitor, and control
  socket were all healthy — yet the console still never showed udev
  completing. That ruled out the shepherd lost-wakeup theory the pokes
  were built on and pointed the investigation at the logging path.
- The earlier exonerations stand (kernel, eudev `settle`'s hard 120 s
  deadline, entropy, signalfd) — but the conclusion is stronger: nothing
  was ever stuck. There is **no upstream shepherd bug to file** (the
  kmsg→/dev/log switchover is intended behavior, if a spooky-quiet one).
- New virt-only finding while validating: with no EBC framebuffer on
  virt, KOReader's luajit **spins a vCPU**, which under TCG starves the
  guest enough to produce soft-lockup/RCU-stall splats and a sluggish
  console. Harmless on virt, absent on hardware (fb exists); the
  harness stops reader-session once its start is confirmed to keep the
  guest responsive.

The assertion harness (`run-virt-assertions.sh`) was redesigned around
this: the console lives on a socket chardev (qemu `logfile=` tees the
capture; anything can connect for post-mortem debugging), and once the
login prompt appears the harness **logs in as root over the socket and
asserts the post-switchover milestones from inside the guest** — it
greps /var/log/messages for udev completion, the pinenote-waveform and
pinenote-ebc-params one-shots, and reader-session start, echoing
VIRTCHK-\* sentinel lines that land in the console log; then it powers
the guest off cleanly and requires `reboot: Power down`. Since
reader-session's shepherd requirements are `(udev user-processes
pinenote-waveform pinenote-ebc-params)`, its start line transitively
proves the whole service-ordering chain that cost the first two
hardware sessions. Rung 4 now covers power-on → full service stack →
clean shutdown, unattended.

## 2026-07-04 qemu-virt rung 4 (offline) — mechanized boot assertions + a udev-hang finding

*(Superseded 2026-07-05, above: the "deadlock" was a console-logging
artifact — shepherd's messages divert from /dev/kmsg to /var/log/messages
once the system-log service is up. The boot completes; the one-shots DO
run on virt.)*

Built the mechanized qemu-virt gate (`make qemu-virt-check`, offline ladder
rung 4). Booting the real 2026-07-03 artifact on QEMU `virt` with the pulled
waveform, it asserts and passes all boot milestones **through Shepherd
start**: kernel 7.0.11 `PREEMPT_RT`, `root=PNGuixRoot`, initrd waveform
install from `/dev/vda1`, EBC display module load, `PNGuixRoot` visible
pre-root at `/dev/vda2`, root fsck-clean mount, `Service root-file-system
running #t`, and reaching `Starting service udev`; and no panic / RT
sleeping-in-atomic / root-not-found / `PNGuixRoot`-not-visible. The whole
run is ~45 s (quiescence-terminated).

**Finding:** the virt boot then *deadlocks entering the `udev` service.*
After `Starting service udev` → udevd starts → shepherd `waiting for
udevd...` → loopback up, the console goes silent at guest t≈12.3 s and never
advances. CPU sampling of the QEMU process shows **0.5 % of one core** (13 s
of CPU over 6+ min elapsed) — the guest is idle-blocked, a genuine deadlock,
not TCG slowness. So the post-udev one-shot services (`pinenote-waveform`,
the ACM gadget, `pinenote-ebc-params`) **never run on virt** — correcting the
earlier doc claim that "the one-shot services run." Consequently the
service-ordering regressions (waveform/udev race, gadget `modprobe -d`) are
*not* covered by qemu-virt and stay on the host tools + hardware. Diagnosing
the hang is blocked on visibility: the defconfig ships
`CONFIG_MAGIC_SYSRQ_SERIAL` and `CONFIG_DETECT_HUNG_TASK` **off**, so no
serial-SysRq or automatic blocked-task backtrace is available — a debug
kernel enabling both (or a gdbstub attach) is the next step (ROADMAP §3
rung 4). This does not affect hardware, where all of these services are
confirmed working (2026-07-04 above).

## 2026-07-04 refresh harness rung 7a (offline) — the refresh machine executes on the host

Built spike option (a) from `doc/ebc-harness-spike.md` the same day it was
scoped: `pinenote/tools/ebc-logic/ebc-refresh-test` runs the **verbatim**
driver's probe, global/partial refresh orchestration, LUT upload, DMA
windowing, IRQ/completion contract, mid-refresh buffer switching, and the
refresh-thread body against a behavioral EBC model (`shim/fake-ebc.h`),
under ASan, as part of `make ebc-logic-check`. All green against the
device's own waveform, including the strongest check: all 256 Y4 (from,to)
drive sequences observed at the fake device match rastersim's independent
decode of the same `.wbf` (GC16@25 °C, 38 phases). Two rung-2 findings are
now *executed*, not just read: the `ctx_free` teardown UAF (ASan-verified
reproducer, asserted by the test runner) and scheduler QUIRK E (chained
begin-together produces device-visible phase-index regressions —
conflicting waveform data on hardware). The differential also re-confirmed
from the hardware side that `blit_direct` (unused, `direct_mode=0`) reads
the LUT transposed. Hardware truth unchanged: the model encodes our
understanding of the silicon; the on-device `EXTRACT_FBS` differential
remains the ground-truth complement.

## 2026-07-04 hrdl 6.19 cherry-picks (offline) — two ported, two rejected on evidence

The ROADMAP's four cherry-pick candidates were read as actual diffs from
`git.sr.ht/~hrdl/linux` `v6.19_ebc_custom` (full record:
`doc/kernel-forward-port.md`). Ported into the forward-port patch:
`usleep_range`→`fsleep` (three sites) and the `dma_sync` size shrink,
translated to our area-list partial refresh (per-frame blitted-row spans
instead of full ~1.3–2.6 MB buffer cleans — RT latency win). Rejected:
the ≥19 °C temperature clamp and pixels-to-IDLE, both workarounds for
their 60–85 Hz rework's early-cancellation / per-pixel scheduler state,
which our m-weigand-lineage copy does not have. To make the shrink
provable and the clamp rejection evidence-backed, the refresh harness
grew a **non-coherent DMA model** (the fake device reads per-mapping
shadow buffers that only `dma_map_single`/`dma_sync_single_for_device`
publish — an under-synced CPU write is now a test failure, not a silent
pass) and a **cold-bin test** (0 °C selects and cleanly orchestrates the
131-phase GC16 waveform). All host suites green before and after the
patch edit; `make kernel-drv` computes; validated only offline — the
shrunken syncs ride along for hardware validation next session.

## 2026-07-04 KOReader packaging spike (offline) — reader track started, KOReader first

Track 4 reprioritized: KOReader leads (an external user wants to run
it). Spike result (`doc/koreader-spike.md`): `koreader-bin` packaged
from the upstream `linux-arm64`/`linux-x86_64` release tarballs
(`pinenote/packages/koreader.scm`, gnu-build-system + patchelf; the
bundle is self-contained except glibc and the Wayland client libs its
SDL3 dlopens). Proven offline: the x86_64 variant boots the complete
KOReader frontend headless (`SDL_VIDEODRIVER=offscreen` — the bundled
SDL3 has wayland/offscreen/dummy backends only, so the device needs a
Wayland compositor) and sits in its UI loop; the aarch64 variant
cross-builds with correct target interpreter/rpath (and its luajit
executes under qemu-user). The kiosk was built the same day: stock
wlroots propagates mesa, which does not cross-compile, so
`pinenote/packages/kiosk.scm` carries `wlroots-pixman`/`cage-pixman`
(no mesa/vulkan/Xwayland — the EBC has no GPU path; pixman on dumb
buffers), plus `reader-session.scm` (respawning root kiosk,
`LIBSEAT_BACKEND=builtin`) and the `reader` flavor (usb-console +
kiosk). Validated offline: full system closure cross-builds;
`make rootfs-reader` produces a preflight-clean
`pinenote-reader-PNGuixRoot-20260704.ext4`; the exact
compositor+client pairing (cage-pixman nested in a live session,
KOReader inside) runs end-to-end. One isolated offline-only failure:
under a *headless* wlroots backend SDL3 segfaults on the
zero-capability seat (no input devices) — can't occur on device
(touch+pen always present); verify at first light. Next: panel/pen
validation on hardware.

## Next sessions

See the **"Current state" header at the top of this file** for the live
queue (unplugged multi-day soak, wake attribution, TPS `ENABLE 2f → 20`).
This section held a mid-July action list, superseded 2026-08-06; the
long-parked items (ECM ethernet gadget, RT characterization under load)
remain parked and are tracked in `ROADMAP.md`.

## Device facts

See `doc/device-runbook.md` for the full inventory and backup ledger.
Highlights:

- Pine64 PineNote v1.2; stock Debian rescue on `os1` (`/dev/mmcblk0p5`),
  experiments on `os2` (`/dev/mmcblk0p6`), waveform partition on
  `/dev/mmcblk0p2`, data on `/dev/mmcblk0p7`.
- VCOM: 1430000 microvolts (recorded, backed up).
- UART: 1500000 baud, 8n1, via CH340 adapter on ttyS2.
- Backups (waveform, uboot, uboot_env, logo, GPT head) verified in two
  locations, 2026-05-08 and 2026-05-10 sets.
