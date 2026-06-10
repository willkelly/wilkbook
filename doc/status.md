# Hardware status

Last updated: 2026-06-10. This is the single place to record what has actually
been proven on the device. Update it after every hardware session; the
detailed evidence lives in session logs, not in git.

## Summary

| Area | 6.6.30 (m-weigand) | 7.0 forward-port (linux-libre) |
| --- | --- | --- |
| Boots to Guix userspace on os2 | yes | yes (needs `CONFIG_GPIO_ROCKCHIP=y`) |
| Waveform install (initrd, from partition) | yes | yes |
| EBC display output | yes | unproven — nothing on panel yet |
| UART console (ttyS2, 1500000) | yes | yes |
| USB ACM gadget console (ttyGS0) | yes | gadget binds; `dwc3: failed to enable ep0out`, host never sees ttyACM |
| Bluetooth firmware (BCM4345C0.hcd) | yes | loads |
| Wi-Fi firmware (brcmfmac43455) | yes | blocked: linux-libre deblob rejects non-free firmware loading |

The `pinenote-usb-console-linux-6-6` flavor is the fully working baseline.
The `pinenote-usb-console` flavor (7.0 forward-port) is the kernel-currency
track with the open issues below.

## 7.0 forward-port: findings so far

- The original pre-root stall was a mass deferred-probe failure ("GPIO not
  available": regulators, sdhci vmmc, dwc3 extcon, EBC temperature channel).
  Building the GPIO driver in (`CONFIG_GPIO_ROCKCHIP=y`) fixed it; 7.0.x now
  reaches Shepherd with root mounted from `PNGuixRoot`.
- Wi-Fi cannot work on a linux-libre base: the deblob pass disables non-free
  firmware loading (`/*(DEBLOBBED)*/` request paths in brcmfmac). The
  forward-port patch already tried restoring the `brcmfmac43455-sdio` names
  and the `request_firmware`/`firmware_request_nowarn` call paths, and the
  kernel still rejects the load ("Missing Free firmware (non-Free firmware
  loading is disabled)") with the files present in the rootfs. Moving the
  forward-port onto vanilla kernel sources is the planned fix (see
  `ROADMAP.md`).
- Bluetooth firmware (`BCM4345C0.pine64,pinenote-v1.2.hcd`) loads despite the
  deblob, after the device-specific alias was added.
- The USB gadget reaches configfs binding but fails at
  `dwc3: failed to enable ep0out`; only the UART console is usable on 7.0.
  A role-switch-gated gadget service ("v3") was deployed but its boot result
  was not captured (session ended with the device needing a manual
  power-cycle).
- No EBC/display success has been recorded on any 7.0 boot, even though the
  initrd installs the waveform from p2 and the `rockchip_ebc` parameters are
  on the command line. Not yet root-caused; comparing rockchip_ebc
  probe/bind between 6.6 and 7.0 UART logs is the obvious next diagnostic.

## Immediate next session

1. Manually power-cycle (device was left stuck before the U-Boot menu),
   confirm `os1` rescue still boots.
2. Select OS2 and capture UART logs for the deployed-but-untested v3 gadget
   service: look for the `ep0out` failure and whether the host enumerates
   `/dev/ttyACM0` (0525:a4a7).
3. Capture the post-reboot p6 readback evidence per the write protocol.

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
