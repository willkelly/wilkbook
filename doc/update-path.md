# The update path: generations, `guix copy`, and kexec

How a running reader gets a new OS without a cable, a boot menu, or a
1.8 GB reflash — and how it gets the old one back. Written 2026-09-02
after the broker+direct arc showed what "flash → boot menu → verify"
costs per iteration. Status: **designed, phase 1 in progress; nothing
below has run on glass.** `doc/status.md` is the truth; this page is the
intent.

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
(prune)                                       → keep K generations; guix gc reclaims the rest
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
`promote`, `demote`, `prune`. The generation ledger is
`/var/guix/profiles/system-*-link` (Guix's own) plus
`/boot/gen-*/`; `extlinux.conf` is rendered from the ledger. The trial
reuses the broker's quiesce (the EBC must be idle before the kernel is
replaced under it). Pure parts — ledger arithmetic, extlinux rendering,
promote/prune decisions — are tested offline.

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
  demote/prune, health predicate) under host luajit; the kernel-config
  and package pins in the image inspection.
- **Rung 4 — the whole flow in QEMU virt** (`make qemu-update-check ROOTFS=…`): boot generation A, `guix
  archive --export | ssh | guix archive --import` generation B into the
  VM (the guix copy nar pipe over plain OpenSSH), `add`, `trial` (kexec
  inside the VM), verify B answers as `/run/current-system`, `promote`,
  then roll back to A. The mechanism end-to-end, no glass.
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
  (default K=3), and when `guix gc` runs (only from the deployer, never
  on a timer). First data point: four generations of the reader used
  2.0 GB of the 15 GB slot; prune to two took it to the same 2.0 GB
  (the generations share nearly everything).
- Whether the nar transfer over Wi-Fi is fast enough for a kernel-sized
  delta (~100 MB) to feel routine.

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
- **Hardening, designed offline the same night — glass proof pending.**
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
  `/sys/class/watchdog/watchdog0/timeout`). U-Boot's own default
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
  configuration. Ranked candidate mechanisms (leading one: the
  watchdog's counting clock freezes somewhere in the transition, not
  yet located in source) are in `doc/upstream-register.md` item 25. The
  arm stays in the helper as harmless — it is what will deliver the
  self-reset once the kexec-path mechanism is found — but today it does
  not recover a trial that dies before its drivers probe; that still
  needs the power button.
- **Recovery is what the design said.** A trial that hangs leaves
  `DEFAULT` on the last good generation; the power button plus the
  UART slot pick (`pinenote/scripts/uart/uboot-pick-slot.sh`) brought
  it back three times. A generation is proven only by *both* boots: the
  kexec trial and, for anything that changes early boot, a cold one.

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
- The `trial` ssh session dies with the old kernel, and kexec never
  closes its TCP connection: a client without keepalives waits forever
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
