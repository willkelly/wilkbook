# Hardware status

Last updated: 2026-07-25.

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
suspend host suites pass; the rootfs-extracted DTB passes the exact RK817
battery profile/phandle gate and suspend gate; and QEMU rung 4 plus 4v pass.
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
defconfig now selects `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y` for the next
reader image. Boot-time governor readback remains a deployment check; no
suspend was attempted and suspend remains disabled. Owner-only raw reports are
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

Source review resolved one misleading kernel artifact: the 7.0 patch carried
`CONFIG_ROCKCHIP_SUSPEND_MODE=y` but neither the downstream Rockchip SIP suspend
driver nor its `rockchip-suspend` DT policy; upstream 7.0.11 does not define the
symbol, so the ignored stale line has been removed. This is not an active BSP
suspend path. The installed stable BSP ATF requires that complete Linux-side
SIP driver plus DT policy, so the present firmware/kernel contract mismatch is
the leading deep-suspend blocker. **Architecture decision (2026-07-25):** retain
the byte-verified stable boot firmware for the first qualification and port
Samuel Holland's complete `rockchip_sip` + `rockchip_pm_config` +
`rockchip-suspend` compatibility stack into the recoverable os2 kernel/DT.
Suspend remains disabled; the first hardware boot of that stack is a
non-suspending bind/probe check under UART. An upstream-TF-A migration is a
separate later project because os1 cannot recover a damaged boot chain. Public
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

## Summary

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

os2 currently holds the **2026-07-20 RK817 telemetry candidate**, SHA
`92837467ba2c0714bdef595d0a2f247536a82aa4dbcb80774902f4d0c1dac189` —
written from os1 with the full protocol and exact-range readback verification.
The staged copy is
`/home/user/pinenote-reader-PNGuixRoot-20260720-telemetry.ext4`.
**First boot and RK817 telemetry acceptance confirmed 2026-07-24; no suspend
attempted.** The previously installed and hardware-accepted final4
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
up on its own — `feature_disable` applied, `wlan0` associated to `largeprofanity`,
DHCP `192.168.86.144`, ping + DNS OK) = the **Phase 1 Wi-Fi userland**
(`pinenote-wifi` service +
`wpa_supplicant` + `dhcpcd`, out-of-band conf on the `data` partition;
`doc/networking.md §4.1`) **plus the confirmed brcmfmac Wi-Fi fix**
(`feature_disable=0x82000` via modprobe.d + kernel cmdline, `d911e57`; the
`82f111c` PATH fix). Wi-Fi credentials for SSID `largeprofanity` are pre-staged
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
Replayed on the phase B workbench: settle med 38 frames / 447 ms —
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
answer); settle = 38 frames/447 ms per GC16 partial page turn, scheduler
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

Autorotation and touch acceptance are complete; no corrective device session is
queued. Continue ordinary reading dogfood and harvest one organic `[pn-refresh]`
trace for the phase-B workbench. If a future input failure appears, preserve the
smallest failing evdev interval plus `/var/log/{wilkbook-orientation,
reader-session}.log`; do not reopen calibration from an anecdotal miss alone.

Still queued behind the display program:

- The community-standard ECM ethernet gadget alongside ACM.
- RT characterization under load (refresh + pen input; watch the EBC
  refresh kthread).
- Finger-touch DTS validation happened 2026-07-05 (cyttsp5 works); the
  cherry-picked driver (fsleep + shrunken dma_sync) has now survived
  three hardware boots with artifact-free partials.

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
