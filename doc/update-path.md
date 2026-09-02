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
guix copy --to=root@reader S                  → store import (signed; ACL)
ssh reader wilkbook-generation add S          → system-(N+1)-link, /boot/gen-(N+1)/{Image,initrd,dtb,append}
                                                extlinux.conf regenerated: one LABEL per kept generation,
                                                DEFAULT unchanged (still gen N)
ssh reader wilkbook-generation trial N+1      → EBC quiesce, gadget off, Wi-Fi off, kexec -l, kexec -e
wait for ssh; health check                    → /run/current-system == S, broker ready, reader up
ssh reader wilkbook-generation promote N+1    → DEFAULT = gen N+1
(prune)                                       → keep K generations; guix gc reclaims the rest
```

Rollback: `wilkbook-generation trial N` then `promote N`. A generation
that never answers is abandoned by a power-cycle (U-Boot → os2 →
extlinux DEFAULT, which still names the last promoted one).

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

Builds never touch the device. `guix copy` and the helper write only
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
  copy` generation B into the VM over SSH, `add`, `trial` (kexec inside
  the VM), verify B answers as `/run/current-system`, `promote`, then
  roll back to A. The mechanism end-to-end, no glass.
- **Glass** (UART-attended): the SoC-specific unknowns — kexec on
  RK3566 with the BSP firmware, the EBC and TPS65185 through a warm
  restart, brcmfmac over SDIO, the waveform install running again in
  the new initrd.

## Open questions

- Does the stock U-Boot read anything but ext4/FAT? (`version`, and
  whether `help` lists `btrls`.) First item at the next cable session;
  it decides the deferred filesystem question, not phase 1.
- kexec on this SoC: does the panel need to be powered down (not just
  quiesced) before the kernel is replaced? What does the TPS65185 do
  through a warm restart?
- Store growth policy: how many generations to keep on a 15.7 GB slot
  (default K=3), and when `guix gc` runs (only from the deployer, never
  on a timer).
- Whether `guix copy` over Wi-Fi is fast enough for a kernel-sized
  delta (~100 MB) to feel routine.

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
