# Hardware status

Last updated: 2026-06-10. This is the single place to record what has actually
been proven on the device. Update it after every hardware session; the
detailed evidence lives in session logs, not in git.

## Summary

| Area | 6.6.30 (m-weigand) | 7.0 forward-port (vanilla via nonguix) |
| --- | --- | --- |
| Boots to Guix userspace on os2 | yes | yes (needs `CONFIG_GPIO_ROCKCHIP=y`) |
| Waveform install (initrd, from partition) | yes | yes |
| EBC display output | yes | unproven — nothing on panel yet |
| UART console (ttyS2, 1500000) | yes | yes |
| USB ACM gadget console (ttyGS0) | yes | gadget binds; `dwc3: failed to enable ep0out`, host never sees ttyACM |
| Bluetooth firmware (BCM4345C0.hcd) | yes | loads |
| Wi-Fi firmware (brcmfmac43455) | yes | untested since vanilla-source rebase (was blocked by linux-libre deblob) |

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
  sources via nonguix instead (host-side: derivation computes, patch
  applies cleanly). Wi-Fi firmware loading on the vanilla base has not yet
  been confirmed on hardware.
- Bluetooth firmware (`BCM4345C0.pine64,pinenote-v1.2.hcd`) loads despite the
  deblob, after the device-specific alias was added.
- The USB gadget reaches configfs binding but fails at
  `dwc3: failed to enable ep0out`; only the UART console is usable on 7.0.
  A role-switch-gated gadget service ("v3") was deployed but its boot result
  was not captured (session ended with the device needing a manual
  power-cycle).
- 2026-06-10 bracketing experiment: the identical configfs ACM recipe run
  on stock os1 (6.12) binds, enumerates on the host as 0525:a4a7, and
  passes data both ways with zero dwc3 errors. The dwc3, usb2phy, and
  wusb3801/type-C DT nodes are identical (modulo phandle renumbering)
  between the working 6.12 DTB and our 7.0 DTB. The regression is
  therefore in kernel driver code between 6.12 and 7.0 (dwc3 core,
  inno-usb2 phy, or role-switch timing), not in DT and not in our
  userspace sequence.
- No EBC/display success has been recorded on any 7.0 boot, even though the
  initrd installs the waveform from p2 and the `rockchip_ebc` parameters are
  on the command line. Not yet root-caused; comparing rockchip_ebc
  probe/bind between 6.6 and 7.0 UART logs is the obvious next diagnostic.

## Current os2 contents

Written and readback-verified 2026-06-10 from os1 (device on USB-C power,
no reboot performed):

- Artifact: `pinenote-usb-console-PNGuixRoot-20260610.ext4` (usb-console
  flavor, vanilla-source `linux-pinenote` 7.0.11, v3 role-gated gadget
  service), 1,501,614,080 bytes.
- SHA-256 (artifact and p6 readback):
  `1b6b8ed250494897bbb2152e9922fd3bb07eb20288b994f168eae937cb625ff8`.
- Note: this replaced the never-boot-tested v3 gadget rootfs, so the next
  os2 boot tests two changes at once relative to the last observed boot:
  the v3 gadget service and the vanilla kernel.

## Immediate next session (once charged enough for the UART adapter)

1. Connect UART (1500000 8N1), start capture, power-cycle, confirm `os1`
   still boots.
2. Select OS2 and watch for: boot to Shepherd, v3 gadget binding without
   `dwc3 ep0out` failure, host enumeration of `/dev/ttyACM0` (0525:a4a7).
3. Check whether brcmfmac loads
   `brcmfmac43455-sdio.pine64,pinenote-v1.2.bin` now that the kernel is
   vanilla-based (dmesg over UART or ACM shell).
4. Look for any rockchip_ebc probe/bind activity vs the 6.6 UART logs
   (display is still unproven on 7.0).

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
