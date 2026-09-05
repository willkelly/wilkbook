# The update path: generations, `guix copy`, and kexec

How a running reader gets a new OS without a cable, a boot menu, or a
1.8 GB reflash — and how it gets the old one back. Written 2026-09-02
after the broker+direct arc showed what "flash → boot menu → verify"
costs per iteration. Status: **on glass since 2026-09-02** — fifteen
generations on one device by 2026-09-04, the QEMU rig alongside ("Proof
ladder" and "Glass notes" below). `doc/status.md` is the truth; this
page is the design and what the glass taught.

## Goal

Update os2 remotely, hands-off, in minutes, with rollback — while os1
stays the untouched rescue slot, the partition table is never written,
and the device never builds anything.

## Decisions, and the facts behind them

1. **Keep cross-building; the device never builds.** `guix deploy`
   proper builds *natively* for the target (emulated or offloaded
   aarch64); our closures are cross-built and not interchangeable, so an
   on-device `reconfigure` would try to rebuild the kernel. We keep the
   pipeline and write a deployer that does what `guix deploy` does
   *minus the build*.
2. **The daemon comes back — as a store importer, not a builder.** Cost
   measured 2026-09-02: ~5 MB idle RSS, no timers (blocks in `accept`),
   ~890 MiB of closure. Configured with `--max-jobs=0` (local builds
   impossible), substitutes off, no substitute key generated, no
   channels installed. What it buys: `guix copy` (signed nar imports), a
   real store database, and `guix gc` with generation links as roots —
   Guix's own rollback machinery instead of a bespoke ledger.
3. **Generations are the rollback tree.** A generation is a symlink plus
   the unique store paths it needs, content-deduplicated; hundreds cost
   only their deltas. The initrd already activates whatever
   `gnu.system=` names, so switching generations is a boot-parameter
   change, not a reinstall. No copy-on-write filesystem is needed for
   any of this.
4. **kexec is load-bearing, not a nicety.** The stock U-Boot defaults to
   os1 on its ~15 s countdown and `saveenv` is forbidden, so no
   unattended reboot ever lands in os2 today. A kexec into the new
   generation's kernel never runs U-Boot at all. `CONFIG_KEXEC` was
   off; it is enabled through the kernel package's config-line append
   (never by editing the forward-port patch).
5. **Trial boot, then promote.** The new generation is kexec'd *without*
   changing the bootloader default. It is promoted (made the extlinux
   `DEFAULT`) only after it answers SSH and passes a health check. Until
   then a power-cycle boots the previous default: a bad generation rolls
   itself back. Explicit rollback is a kexec into the previous
   generation plus a demote.
6. **Root stays ext4 on p6.** U-Boot must read `/boot` (kernel, initrd,
   DTB, `extlinux.conf`) from p6's filesystem, there is no boot
   partition, and the table is off-limits. Copy-on-write filesystems
   (for compression and per-book snapshot histories) are a later,
   separate decision — see "Deferred".
7. **p6 has room.** The partition is 15.7 GB; the shipped filesystem is
   1.76 GB. A first-boot `resize2fs` claims the rest. A generation's
   boot payload is ~33 MB (Image 20 MB, initrd 13 MB, DTB 64 KB).

## The flow

```
workstation                                   device (os2, running gen N)
-----------                                   ---------------------------
guix system build --target=aarch64-linux-gnu  → S (system store path)
guix gc --references -R S | ssh reader \
  guix archive --missing                      → the paths the device lacks
guix archive --export <missing> | ssh reader \
  guix archive --import                       → store import (signed; ACL)
ssh reader wilkbook-generation add S          → system-(N+1)-link, /boot/gen-(N+1)/{Image,initrd,dtb,append}
                                                extlinux.conf regenerated: one LABEL per kept generation,
                                                DEFAULT unchanged (still gen N)
ssh reader wilkbook-generation trial N+1      → EBC quiesce, gadget off, Wi-Fi off, kexec -l, kexec -e
wait for ssh; health check                    → /run/current-system == S, broker ready, reader up
ssh reader wilkbook-generation promote N+1    → DEFAULT = gen N+1
(prune)                                       → keep K generations (+ DEFAULT, the booted one, and
                                                every PINNED one); guix gc reclaims the rest
(after a cold boot: wilkbook-generation pin N) → /boot/gen-N/pinned; prune never deletes N
```

The transfer is guix's own signed nar stream — `guix archive --export`
piped through plain OpenSSH into `guix archive --import` on the reader,
which is what `guix copy` does internally — rather than `guix copy`
itself, because `guix copy` talks ssh through Guile-SSH/libssh, which
resolves `~/.ssh/known_hosts` and `~/.ssh/config` from the passwd home
directory rather than `$HOME` or any option it exposes, so it cannot
honor the per-slot `UserKnownHostsFile` convention (`doc/device-access.md`)
or a harness's pinned host key; plain OpenSSH honors both.

Rollback: `wilkbook-generation trial N` then `promote N`. A generation
that never answers is abandoned by a power-cycle (U-Boot → os2 →
extlinux DEFAULT, which still names the last promoted one).

**What actually moves.** The deployer asks the device which of the
closure's paths it lacks (`guix archive --missing` on the far side) and
exports only those — the `guix copy` algorithm. A KOReader or service
change is megabytes; a kernel change ~100 MB; never the 2 GB closure.

## Pieces

**On the device** (`pinenote/packages/update-path/`, shipped like
platform-controls): `wilkbook-generation` — `add`, `list`, `trial`,
`promote`, `demote`, `pin`, `unpin`, `prune`. The generation ledger is
`/var/guix/profiles/system-*-link` (Guix's own) plus
`/boot/gen-*/`; `extlinux.conf` is rendered from the ledger. The trial
reuses the broker's quiesce (the EBC must be idle before the kernel is
replaced under it). Pure parts — ledger arithmetic, extlinux rendering,
promote/prune decisions, the pinned set — are tested offline.

**The pin (2026-09-04).** `prune --keep K` keeps the K *newest*
generations, which are the least proven; without a pin the only
cold-booted generation was kept inside the window by hand, until the
deploy of generation 16 (`KEEP=8`) pruned generation 10 — the previous
cold-booted one — exactly that way. `wilkbook-generation pin N` marks
N known-good and `prune` then never deletes it, on top of never
deleting `DEFAULT` or the booted generation; pinned generations do not
count against K. `list` shows `[pinned]`; `unpin N` clears it. The
marker is an empty file in the generation's own payload directory,
`/boot/gen-N/pinned`, chosen over a separate list file because it dies
with the generation (prune removes `/boot/gen-N` whole, so a pin cannot
dangle), needs no parsing, and adds nothing to the helper's write set —
`/boot`, the profiles and the store, pinned by `test-static.sh`. Pin a
generation once a cold boot has proven it (the trial does not run its
device tree — "Device-tree changes do not ride a trial" below); unpin
the previous one when a newer generation has been cold-booted and
pinned in its place. The deployer needs no change: its
`prune --keep $KEEP` honours the pins. Not yet run on a device: the
glass proof is a `pin` of the cold-booted generation followed by a
prune with a `KEEP` small enough to have taken it, and `list` still
showing it.

**On the workstation** (`make deploy DEVICE=…`): build, copy, add,
trial, health-check, promote, with every step refusing rather than
guessing (wrong slot, unsigned import, generation already present,
health check failed → no promotion). The signing key is per-operator:
the device authorizes public keys found under
`/data/wilkbook/guix/authorized-keys/` at boot (the same out-of-band
pattern as Wi-Fi credentials), so a reflash never loses the trust and
the repo never carries a key.

**Enablement (one more reflash, then none):** daemon (importer mode),
`kexec-tools`, `CONFIG_KEXEC`/`CONFIG_KEXEC_FILE`, the first-boot
`resize2fs`, the ACL one-shot, the helper. The closure-level image
inspection requires every one of them.

## Safety model, unchanged

Builds never touch the device. The nar export/import (what `guix copy`
does internally, sent over plain OpenSSH) and the helper write only
p6's store, profiles and `/boot`; never p7, never the table, never os1.
The dd protocol remains the recovery path. kexec replaces the kernel
under a running system — the trial step therefore runs the same
teardown as a suspend (EBC quiesce, gadget unbind, Wi-Fi off) before
`kexec -e`, and the first kexec on glass is UART-attended.

## Proof ladder

- **Rung 1**: the helper's pure logic (ledger, extlinux render, promote/
  demote/prune with the pinned set, health predicate) under host luajit;
  the kernel-config and package pins in the image inspection.
- **Rung 4 — the whole flow in QEMU virt** (`make qemu-update-check ROOTFS=…`): boot generation A, `guix
  archive --export | ssh | guix archive --import` generation B into the
  VM (the guix copy nar pipe over plain OpenSSH), `add`, `trial` (kexec
  inside the VM), verify B answers as `/run/current-system`, `promote`,
  `pin` A and `prune --keep 1` (A survives; `unpin`), then roll back to
  A and `prune --keep 0` (B goes). The mechanism end-to-end, no glass.
- **Glass** (UART-attended) — **done 2026-09-02**: the enabling image
  was written to os2 by the dd protocol, generation 3 (a cross-built
  system) was promoted and cold-booted from the helper's own extlinux
  menu, and generation 4 went through the whole `make deploy` path
  hands-off — 13-path delta, add, trial kexec, health, promote, prune —
  with the panel re-probing on its own waveform, the reader, the ACM
  gadget and brcmfmac all back. The SoC unknowns are answered below.

## Open questions

- Does the stock U-Boot read anything but ext4/FAT? (`version`, and
  whether `help` lists `btrls`.) First item at the next cable session;
  it decides the deferred filesystem question, not phase 1.
- ~~kexec on this SoC: does the panel need to be powered down?~~
  Answered 2026-09-02: quiesced is enough. The EBC re-probes in the new
  kernel, loads the device's waveform and the reader paints; the
  TPS65185 came through four warm restarts. What kexec *does* need on
  the RK3566 is in the glass notes below.
- Store growth policy: how many generations to keep on a 15.7 GB slot
  (the deployer's default `KEEP` is 5), and when `guix gc` runs (only from the deployer, never
  on a timer). First data point: four generations of the reader used
  2.0 GB of the 15 GB slot; prune to two took it to the same 2.0 GB
  (the generations share nearly everything). *Which* generations the
  window keeps is settled (2026-09-04): the K newest plus `DEFAULT`,
  the booted one and every pinned one — a pinned generation costs only
  its delta, so a pin is cheap to hold.
- Whether the nar transfer over Wi-Fi is fast enough for a kernel-sized
  delta (~100 MB) to feel routine.

## Device-tree changes do not ride a trial (2026-09-03)

A trial boots on the **running** kernel's device tree, whatever the
helper's `--dtb` says. kexec-tools (2.0.31) tries `kexec_file_load`
first, and its arm64 loader drops a user DTB on that path (it prints
"(ignored)" only under `-d`; `kexec/arch/arm64/kexec-arm64.c`); the
kernel then builds the next tree from the current one — U-Boot's
`serial-number` and memory layout included, which is also why forcing
the legacy syscall with `-c` is not the fix: our DTB files carry no
memory node and no firmware reservations, U-Boot adds those at a cold
boot. Proven 2026-09-03: generation 10's staged DTB carried a new
`sdio-pwrseq` property, the kexec'd kernel's `/sys/firmware/fdt` did
not, and it did carry U-Boot's `serial-number`.

So a trial half-tests a generation whose device tree differs from the
promoted one: the kernel, the userspace and the health check all run,
the tree does not. Only a cold boot of the promoted generation runs its
own DTB. The helper says so at trial time (`NOTE: generation N's device
tree differs from the booted gen-M's …`) by comparing the target's
staged DTB with the booted generation's, and adds a second note whenever
the running kernel was itself kexec'd (its tree is the last cold boot's,
which may be older still); the deployer prints both. Both notes, and
the machine-model line, are logged **before** the trial's teardown
begins: the teardown turns the radio off right after stopping the
reader, and whoever watches a trial over ssh — the deployer, or a
hand-run helper — is on that radio, so nothing logged after it ever
arrives (2026-09-04: two trials in a row "never captured" the notes
until this was seen; `test-static.sh` now pins the order). The lines
that follow the radio-off (`kexec -e into generation N`, `watchdog
armed`, the kexec binary's own stderr) reach only a UART login that
ran the helper itself — the deployer never sees them, and the ACM
console loses the same lines one statement later when the gadget is
unbound. Until a cold boot has run, treat a
device-tree change as undeployed — the Wi-Fi power-sequence delay
(`doc/networking.md` §8) is the first one to wait for that.

## Glass notes (what the first kexecs on the PineNote taught, 2026-09-02)

Three kexecs hung identically before the fourth booted; each hang cost
a power-cycle (the kexec'd kernel stalls before its serial driver is
up, so serial-BREAK sysrq cannot reach it — the debug cable carries no
reset line). Every one stalled at the same line, `DMA: preallocated
512 KiB … pool`, 0.12 s in, then reported a workqueue lockup on
whichever CPU was running init. Two real defects were found; one was
the hang.

- **The GICv3's LPI tables are not reserved across a non-EFI kexec.**
  The running kernel allocates them in ordinary memory and only an
  EFI boot persists a reservation for the next kernel
  (`gic_reserve_range` is a silent no-op otherwise); this GIC latches
  `GICR_CTLR.EnableLPIs`, so the kexec'd kernel printed "Booted with
  LPIs enabled, memory probably corrupted" and "Failed to disable
  LPIs" on all four CPUs. LPIs serve PCIe message-signalled interrupts;
  the PineNote has no PCIe node and `/proc/interrupts` shows no ITS
  user, so every flavor now boots with `irqchip.gicv3_nolpi=1` and a
  kexec'd kernel inherits a clean controller. Real, fixed — and **not
  the hang**: a kexec from a nolpi kernel into a nolpi kernel stalled
  at the same line.
- **The hang: `rockchip_grf_init` writes the PIPE GRF with its clock
  gated.** In link order the postcore initcalls between the DMA pool
  and the thermal core are few, and the only unconditional hardware
  write among them is the rk3566 table in `drivers/soc/rockchip/grf.c`:
  three USB3-OTG bits into the PIPE GRF at `0xfdc50000`. That block
  sits on `pclk_pipe`, which nothing in the PineNote's tree uses, so
  the running kernel gates it as unused (`clk_summary`: enable count
  0); U-Boot hands a cold boot with it running. An APB write into an
  unclocked block never completes — no fault, no message. Proof: a
  kexec with `initcall_debug initcall_blacklist=rockchip_grf_init`
  booted all the way, USB gadget included (the GRF keeps the cold
  boot's values across a kexec, so the write is redundant there). The
  helper therefore appends `initcall_blacklist=rockchip_grf_init` to
  the kexec command line on a PineNote, and nowhere else: cold boots
  keep the init. The proper fix is a kernel one — a `clocks` reference
  on the `pipegrf` syscon so regmap clocks the access, or
  `CLK_IGNORE_UNUSED` on `pclk_pipe` — recorded as
  `doc/upstream-register.md` item 22.
- **The trial runs the helper the target generation ships.** The
  running generation's helper could not know the skip; the deployer now
  invokes `<target system>/profile/bin/wilkbook-generation trial N`, so
  a kexec-preparation fix applies to the first kexec that needs it. A
  generation that predates the fix cannot be *trialled into* (the
  pre-fix generations 1 and 2 were pruned for that reason); it can still
  be cold-booted from the menu.
- **U-Boot reads the helper's menu.** The rendered `extlinux.conf`
  (`MENU TITLE wilkbook generations`, one `LABEL` per kept generation,
  `DEFAULT` the promoted one, `TIMEOUT 30`) was parsed by the stock
  U-Boot on the first power-cycle and booted the promoted generation;
  after `promote 3` and a plain reboot it booted generation 3 cold with
  no key pressed at the extlinux stage.
- **Hardening, designed offline the same night — glass-proven end to
  end 2026-09-03 evening (below).**
  Two more facts drove it. (a) The clock patch alone did not stop the
  hang: a kexec into the patched generation 5 with no skip still stalled
  in `rockchip_grf_init` (named by `initcall_debug`). The trial's gadget
  unbind lets the USB controller runtime-suspend and genpd gate the PIPE
  power *domain* — the "domain was on" snapshot had been taken before
  the unbind — and a powered-off block hangs the bus whatever its clock
  does. dwc3 has no shutdown hook, so the helper now sets the controller
  runtime-PM `on` after the unbind and the domain should survive into the
  next kernel; the measurement (domain state 4 s after unbind, then
  held) and the kexec are one power-cycle away. (b) A kernel that dies
  before its drivers probe can only be recovered by the power button, so
  the helper now arms the SoC watchdog as the last thing before
  `kexec -e`. The RK3566's DesignWare watchdog cannot be stopped without
  a reset line (this node has none), a kexec'd kernel finds it running
  and pings it from the moment the driver probes
  (`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`), and a kernel that never
  gets there resets into U-Boot after the hardware timeout (44 s, per
  `/sys/class/watchdog/watchdog0/timeout`) — nominally: on the one
  proof run (2026-09-03 17:05, doc/status.md) the reset landed about
  3.5 minutes after the arm, not 44 s, and SSH to the recovered DEFAULT
  came 5 min 13 s after the launch; the stretch is unexplained (the
  driverless measurement earlier that day showed a 44 s period, so it
  is something the new kernel's dw_wdt probe did before the panic).
  Any wait on this path must budget for it. U-Boot's own default
  then lands on **os1**; the UART watcher picks os2 when attended. Both
  are best-effort (no such device on QEMU virt) and pinned.
  **Both measured the same night, both negative, both recorded in
  `doc/status.md`:** the PIPE domain stayed *on* through the unbind, the
  hold and the kexec, and the patched generation still hung in
  `rockchip_grf_init` — so neither the clock reference nor the domain is
  the mechanism, and the kexec-only skip remains the only proven fix
  (`doc/upstream-register.md` 22 is corrected accordingly). And the
  watchdog armed, kept running through the kexec, expired — and reset
  nothing, twice (2026-09-02 23:24, 2026-09-03 01:34 MDT). The obvious
  suspect — on the RK3568 the watchdog's reset reaches the chip's
  global reset only when `CRU_GLB_RST_CON` (CRU + 0xdc) bits 0–1 are
  set, the PX30 precedent in mainline U-Boot — is refuted: the register
  already read `0x103` (bits 0–1 set) and the armed hang still did not
  reset.
  **Updated 2026-09-03 morning: the watchdog does reset the SoC.** A
  runtime test with no kexec involved (arm from the running kernel,
  read `WDT_CCVR`, wait) got a real reset ~58 s after arming — DDR
  init, U-Boot menu, the watcher picking os2, a clean boot
  (`doc/status.md`). So the identical arm sequence resets the chip when
  nothing else happens and does not reset it when a kexec intervenes:
  the kexec transition itself is what defeats it, not the watchdog's
  configuration. Two candidate mechanisms remain — the transition stops or
  freezes the dog before the hang, or the reset fires into the bus the
  PIPE GRF write wedged and the BootROM stalls before TPL prints — and
  the discriminating test (arm, then a blacklisted kexec trial into the
  running generation, then read the counter in the new kernel) is in
  `doc/upstream-register.md` item 25. The
  arm stays in the helper as harmless — it is what will deliver the
  self-reset once the kexec-path mechanism is found — but today it does
  not recover a trial that dies before its drivers probe; that still
  needs the power button.
  **Updated 2026-09-03 afternoon: kernel patch 8
  (`linux-pinenote-7.1-rk8xx-kexec-sleep-pin.patch`, `%linux-pinenote-patches`)
  landed — `rk8xx_shutdown()` returns early `if (kexec_in_progress)`, so
  the outgoing kernel's kexec no longer flips the RK817 sleep pin to its
  power-down function (SYS_CFG3, the PMIC's I2C regmap register 0xf4)
  before jumping to the next kernel — and the self-reset test still
  failed with the patch *confirmed* present in the kernel that ran it.
  Confirmed offline from the exact store derivation generation 8 was
  built from (not just the source tree): the `linux-7.1.8.tar.zst`
  source derivation gen-8's kernel `.drv` references lists the patch
  file as a direct input, and the realized source's
  `drivers/mfd/rk8xx-core.c` carries the guard; `kernel/kexec_core.c`
  sets `kexec_in_progress = true` immediately before
  `kernel_restart_prepare()` in `kernel_kexec()`, so the guard is live
  by the time `device_shutdown()` reaches the PMIC; both generation 7's
  and generation 8's on-device `.config` carry `CONFIG_KEXEC_CORE=y`.
  15:19:32 MDT, from gen-8 (patched, SYS_CFG3 read `0x20` immediately
  before): armed the watchdog (timeout 44 s), then `kexec -e` into
  generation 7's kernel *without* the `rockchip_grf_init` skip — the
  designed hang, confirmed on the UART at 0.165 s kernel-relative time.
  A dedicated UART watch (grep for `DDR Version`) found **no reset in
  200 s** — more than 4x the watchdog's own timeout — and a parallel
  SSH-reconnect poll found nothing for another 200 s (script log:
  `NO RESET within 200 s of launch`, then `ssh: connect ... Connection
  timed out`). The device was still unreachable and silent on the UART
  at 15:28:16, and was not confirmed fully back (fresh boot into
  generation 7, `DDR Version`/SPL/U-Boot with no `PM-STATE:` resume
  prefix, i.e. a cold-style reset rather than a resume) until sometime
  before 16:04 — at least 9 minutes of proven dead silence, bounded
  above by roughly 45 minutes, far past anything the 44 s watchdog
  timeout explains on its own; the recovery bears every mark of the
  power button, not a watchdog fire. **So: the patch is proven present
  and correctly wired, and it does not recover a target hung on the
  GRF bus wedge specifically** — this test kexec'd deliberately
  *without* `initcall_blacklist=rockchip_grf_init` to reproduce that
  exact hang. That is a narrower result than "the self-reset doesn't
  work": the helper's blacklist already prevents this hang on every
  real trial (it is unconditional, applied to every generation the
  helper prepares), so this class of failure is designed out of the
  update path rather than left for the watchdog to catch. The wedge
  from writing the clock-gated PIPE GRF (item 22) stays the leading
  suspect for *why the watchdog itself doesn't reach the chip here* —
  either it freezes the watchdog's own reset-assertion logic before it
  can fire, or the reset fires but the BootROM stalls before it can
  print anything — and the two remain undistinguished; this reads as a
  TRM-level question about what a first-stage global reset reaches on a
  wedged interconnect, not one this patch can answer. What this test
  left open was the mechanism's positive case: does the self-reset work
  at all, against a target that halts for some *other* reason, with
  patch 8 in the kexecing kernel.

  **Updated 2026-09-03 evening: yes, proven end to end
  (`doc/status.md`, top entry; `doc/upstream-register.md` item 25).**
  From a generation whose kexecing kernel carried patch 8, armed
  (`echo 1 > /dev/watchdog0`), kexec'd (with the proven GRF blacklist)
  into a target built to boot far enough to run patch 8's guard and
  then halt cleanly (`rdinit=/nonexistent…
  init=/nonexistent… panic=0`, so no root and no panic reboot): the new
  kernel started, printed its command line, went silent — then,
  unattended, `DDR Version`, U-Boot, the slot pick, and the target
  generation up, `[promoted] [booted]`, `SYS_CFG3` back at `0x20`. Two
  more facts from the same evening round it out: (1) a target that
  *panics* instead of halting cleanly already self-recovers independent
  of the watchdog — `CONFIG_PANIC_TIMEOUT=1` (`pinenote_defconfig`)
  reboots it through firmware within a second, confirmed the same
  evening; (2) the self-reset needs the *kexecing* kernel to carry
  patch 8 — the very first kexec into a newly-patched generation is
  still done by the old, unpatched one, and a hang in that one trial
  still powers the board off (observed live, unplanned, 16:25 the same
  evening). So the update path's coverage as of patch 8: bus wedge →
  prevented outright by the blacklist; panic → the kernel reboots
  itself; any other halt or deadlock in a kernel kexec'd *from* a
  patched generation → the watchdog. The one gap is the first hop onto
  a newly-patched generation.
- **Recovery, updated.** A trial that halts now self-recovers by
  watchdog when patch 8 is in the kexecing kernel (above) — `DEFAULT`
  boots hands-off, no cable, no power button. The power button plus the
  UART slot pick (`pinenote/scripts/uart/uboot-pick-slot.sh`) remains
  the recovery for the cases the self-reset does not reach: the GRF
  bus-wedge hang (prevented by the blacklist on any real trial, but not
  self-recovering if it does happen), and the first kexec onto a
  generation that doesn't have patch 8 yet. It brought the device back
  three times this investigation. A generation is proven only by *both*
  boots: the kexec trial and, for anything that changes early boot, a
  cold one — and once it is, `pin` it, so the next prune cannot take it.

## Rig notes (what the QEMU flow taught, 2026-09-02)

- A generation's `APPEND` is the PineNote's: `console=ttyS2`, the
  PineNote DTB, an EBC to quiesce. Off a PineNote (the rig keys on
  `/proc/device-tree/model`) the helper reuses the running device tree,
  skips the quiesce, and rewrites the console to the PL011. Without the
  last one the kexec'd kernel cannot open `/dev/console`, and Guix's
  initrd `init` runs away to ~1.9 GB and is OOM-killed — a fragility of
  the upstream initrd worth remembering on the device too: a wrong
  serial console argument is a non-booting generation, which is exactly
  what trial-then-promote is for.
- `guix copy`'s Guile-SSH transport resolves known-hosts and ssh config
  from the passwd home and ignores `$HOME`; the signed nar pipe over
  OpenSSH (what `guix copy` does internally) is used instead, and sends
  only what `guix archive --missing` reports on the far side.
- The `trial` ssh session dies without a FIN — on QEMU with the old
  kernel, on a PineNote earlier still, at the helper's own Wi-Fi off —
  and nothing closes its TCP connection: a client without keepalives waits forever
  (the harness did, twice, with the guest already up as the new
  generation). `ServerAliveInterval` makes the replacement kernel answer
  the next probe with a reset within seconds; the caller's `timeout` is
  the backstop. The helper is right to let `kexec -e` end the session
  rather than detach it -- a "scheduled" return would hide a failed
  `-e` behind a clean exit.
- A generation built before a helper change tests the old helper: a
  pre-gate generation B refused the rollback trial with "EBC did not go
  idle" on a machine with no EBC, and the harness had thrown the trial's
  output away. The rig now refuses a generation whose shipped helper is
  not the tree's and echoes every trial's output.
- The synthetic os2 partition needs slack (`VIRT_ROOT_SLACK_MIB`) or the
  first-boot `resize2fs` has nothing to grow into; with 2 GiB of slack
  the rig proves the grow and has room for generation B.

## Deferred: filesystems and per-book histories

Interactive books will generate files and need a point-in-time restore
UI. That history should be **per book, decoupled from root**: one
self-contained image per book on `/data`, mounted on demand as the
container's writable layer. Candidates inside it: btrfs with `zstd:3`
and event-driven snapshots (transparent, hundreds of points per book,
count bounded per image); nilfs2 (continuous checkpoints — designed for
"restore to 3:42 pm"; niche); git (richest undo semantics; needs a
commit trigger). ZFS for books is *possible* (the boot blocker does not
apply off root) but contingent on the module cross-building against our
PREEMPT_RT kernel — a one-derivation experiment to run when the book
runtime exists, not before. Root stays ext4 under generations
regardless. Btrfs scales to thousands of snapshots per filesystem with
no quotas and batched deletion; the per-book unit keeps every
filesystem inside that range by construction.
