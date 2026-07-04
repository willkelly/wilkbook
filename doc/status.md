# Hardware status

Last updated: 2026-07-03. This is the single place to record what has actually
been proven on the device. Update it after every hardware session; the
detailed evidence lives in session logs, not in git.

2026-07-03 note: the 2026-06-11 os2 boot *was* captured after all — the boot
ran unobserved but syslog persisted to os2's `/var/log/messages`, harvested
read-only from os1 over SSH. The 7.0 findings below reflect that log.

## Summary

| Area | 6.6.30 (m-weigand) | 7.0 forward-port (vanilla via nonguix) |
| --- | --- | --- |
| Boots to Guix userspace on os2 | yes | yes (needs `CONFIG_GPIO_ROCKCHIP=y`) |
| Waveform install (initrd, from partition) | yes | yes (initrd); post-boot service raced udev, fixed 2026-07-03 |
| EBC display output | yes | probe fails: no TPS65185 IIO temp channel on vanilla base; fix staged 2026-07-03, unproven on panel |
| UART console (ttyS2, 1500000) | yes | yes |
| USB ACM gadget console (ttyGS0) | yes | never bound on 6-11 boot: modprobe path bug + `CONFIG_DEBUG_FS` off gated the role check; both fixed 2026-07-03, plus `snps,dis_u3_susphy_quirk` targeting the `ep0out` root cause (6.15 susphy reordering); unproven on hardware |
| Bluetooth firmware (BCM4345C0.hcd) | yes | yes (2026-06-11: `BCM4345C0.pine64,pinenote-v1.2.hcd` patch applied, build 0382) |
| Wi-Fi firmware (brcmfmac43455) | yes | yes (2026-06-11: brcmfmac 7.45.234 loaded on vanilla base — deblob problem confirmed solved) |

The `pinenote-usb-console-linux-6-6` flavor is the fully working baseline.
The `pinenote-usb-console` flavor (7.0 forward-port) is the kernel-currency
track with the open issues below.

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

Still the 2026-06-10 artifact (`pinenote-usb-console-PNGuixRoot-20260610.ext4`,
SHA-256 `1b6b8ed2…`), whose boot produced the 2026-06-11 log above.

## Staged and ready to write (2026-07-03)

The full fix-stack artifact is built, QEMU-virt boot-tested (reaches
Shepherd on the `PREEMPT_RT` kernel; initrd installs waveform and loads
display modules), and staged on the device with a verified SHA:

- Artifact: `pinenote-usb-console-PNGuixRoot-20260703.ext4`,
  1,503,334,400 bytes (= 2,936,200 × 512 sectors), at
  `/home/user/wilkbook-artifacts/` on os1.
- SHA-256 (host artifact and staged copy both):
  `4cab03b25c2c80ae6a3c22147f30c1022fcfe3e9f787ab302d8dbc9e034ea43e`.
- Contains: TPS65185 IIO + `#io-channel-cells`, `eink,ed103tc2`
  panel-simple entry, `snps,dis_u3_susphy_quirk`, `CONFIG_PREEMPT_RT=y`,
  `CONFIG_DEBUG_FS=y`, waveform-service udev ordering + sysfs fallback,
  gadget `modprobe -d` fix.

To write (from os1, os2 unmounted — deliberately left as a manual step):

```sh
A=/home/user/wilkbook-artifacts/pinenote-usb-console-PNGuixRoot-20260703.ext4
sudo dd if=$A of=/dev/mmcblk0p6 bs=1M conv=fsync status=progress && sync
sudo dd if=/dev/mmcblk0p6 bs=512 count=2936200 status=none | sha256sum
# expect 4cab03b25c2c80ae6a3c22147f30c1022fcfe3e9f787ab302d8dbc9e034ea43e
```

## Immediate next session (once charged enough for the UART adapter)

Precondition: build and stage the 2026-07-03 fix stack (TPS65185 IIO +
`#io-channel-cells`, `CONFIG_DEBUG_FS=y`, `CONFIG_PREEMPT_RT=y`, waveform
service ordering, gadget `modprobe -d`) to os2 first.

1. Connect UART (1500000 8N1), start capture, power-cycle, confirm `os1`
   still boots.
2. Select OS2 and watch for, in order:
   - `rockchip_ebc` probe passing the temperature channel (expect deferral
     until `tps65185` registers IIO, then `Loaded 4-bit PVI waveform`
     and `Initialized rockchip-ebc`, per the os1 6.12 signature);
   - anything drawn on the panel (fbcon on `tty0` is on the cmdline);
   - v3 gadget binding with working modprobes and debugfs mode writes,
     then whether `dwc3 ep0out` still fails; host enumeration of
     `/dev/ttyACM0` (0525:a4a7).
3. Confirm `uname -v` shows `PREEMPT_RT` and check dmesg for RT-related
   warnings (e.g. `BUG: sleeping function called from invalid context`).
4. Even without a panel result, harvest `/var/log/messages` from os2
   before ending the session — the 6-11 boot proved post-mortem logs work.

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
