# os1 oracle: deep suspend/resume on stock 6.12 — 2026-08-01

One bounded deep cycle on stock Debian (6.12.11-pinenote), RTC-armed,
user watching the glass. Answers the resume-defect provenance question
from the same day's os2 ladder session.

- rc=0; `suspend entry (deep)` @110.61 -> `suspend exit` @112.58.
  The cycle was ~2 s, not the armed 25 — an early wake of unidentified
  source (plausibly the user touching the device to check it; benign
  for this purpose: deep was entered and exited).
- **Panel works after resume — user-confirmed on glass.**
- **PG 0x00 -> 0xfa across the cycle: the rails genuinely dropped and
  came back** — this was a real power transition, not a shallow no-op.
- **VCOM1 reads 0x8f AFTER a real deep cycle**: the NVM-stored
  per-device calibration survived an actual SLEEP reset. The NVM
  thesis is closed with hardware proof at the strongest level.
- ENABLE 0x20 -> 0x1f: the 6.12 driver's resume restoration ran and
  rewrote it; every other register identical pre/post.
- **The smoking gun for our tree**: os1's dmesg shows the IDENTICAL
  resume teardown our kernel logs (`rockchip_ebc_suspend` ->
  `plane_reset`/`ctx_release`/`ctx_free`) — and its panel works.
  The teardown is not the defect. The divergence is the display
  client: os1 runs a DRM compositor that issues a fresh modeset/
  commit after resume, rebuilding the driver context; our image's
  fbdev emulation never re-commits, so the context stays torn down
  and damage is never serviced. The regulator leak is the same gap
  (resume-time enables never balanced by a commit-driven lifecycle).
  Fix direction, our-tree: restore the fbdev client after resume
  (drm_mode_config_helper_suspend/resume or an explicit fb-helper
  restore) — the lineage never ran this driver fbdev-only, so this
  is a forward-port integration gap, not a community defect.

## Captures

### oracle-deep.log
```
+ [ -e /sys/kernel/debug/regmap/0-001c/name ]
+ cat /sys/kernel/debug/regmap/0-001c/name
+ [ fan53555-regulator = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/0-0020/name ]
+ cat /sys/kernel/debug/regmap/0-0020/name
+ [ rk8xx-i2c = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0036/name ]
+ cat /sys/kernel/debug/regmap/3-0036/name
+ [ lm3630a_bl = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0060/name ]
+ cat /sys/kernel/debug/regmap/3-0060/name
+ [ wusb3801 = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0068/name ]
+ cat /sys/kernel/debug/regmap/3-0068/name
+ [ tps65185 = tps65185 ]
+ cat /sys/kernel/debug/regmap/3-0068/registers
+ [ -e /sys/kernel/debug/regmap/5-0018/name ]
+ cat /sys/kernel/debug/regmap/5-0018/name
+ [ st-accel-i2c = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/5-0024/name ]
+ cat /sys/kernel/debug/regmap/5-0024/name
+ [ cyttsp5 = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-power-management@0x00000000fdd90000/name ]
+ cat /sys/kernel/debug/regmap/dummy-power-management@0x00000000fdd90000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe128000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe128000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138180/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138180/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe150000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe150000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158180/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158180/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158200/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158200/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158280/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158280/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158300/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158300/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190280/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190280/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190300/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190300/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190380/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190380/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190400/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190400/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe198000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe198000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc20000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc20000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc50000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc50000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc60000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc60000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdca0000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdca0000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fdec0000.ebc/name ]
+ cat /sys/kernel/debug/regmap/fdec0000.ebc/name
+ [ rockchip-ebc = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe410000.i2s/name ]
+ cat /sys/kernel/debug/regmap/fe410000.i2s/name
+ [ rockchip-i2s-tdm = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe420000.i2s/name ]
+ cat /sys/kernel/debug/regmap/fe420000.i2s/name
+ [ rockchip-i2s-tdm = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe440000.pdm/name ]
+ cat /sys/kernel/debug/regmap/fe440000.pdm/name
+ [ rockchip-pdm = tps65185 ]
+ sync
+ cat /sys/class/rtc/rtc0/since_epoch
+ now=1785607893
+ echo 0
+ echo 1785607918
+ cat /sys/class/rtc/rtc0/wakealarm
+ echo alarm=1785607918 now=1785607893
alarm=1785607918 now=1785607893
+ echo mem
+ rc=0
+ dmesg
+ tail -60
+ [ -e /sys/kernel/debug/regmap/0-001c/name ]
+ cat /sys/kernel/debug/regmap/0-001c/name
+ [ fan53555-regulator = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/0-0020/name ]
+ cat /sys/kernel/debug/regmap/0-0020/name
+ [ rk8xx-i2c = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0036/name ]
+ cat /sys/kernel/debug/regmap/3-0036/name
+ [ lm3630a_bl = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0060/name ]
+ cat /sys/kernel/debug/regmap/3-0060/name
+ [ wusb3801 = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/3-0068/name ]
+ cat /sys/kernel/debug/regmap/3-0068/name
+ [ tps65185 = tps65185 ]
+ cat /sys/kernel/debug/regmap/3-0068/registers
+ [ -e /sys/kernel/debug/regmap/5-0018/name ]
+ cat /sys/kernel/debug/regmap/5-0018/name
+ [ st-accel-i2c = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/5-0024/name ]
+ cat /sys/kernel/debug/regmap/5-0024/name
+ [ cyttsp5 = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-power-management@0x00000000fdd90000/name ]
+ cat /sys/kernel/debug/regmap/dummy-power-management@0x00000000fdd90000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe128000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe128000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138180/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe138180/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe148100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe150000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe150000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158180/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158180/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158200/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158200/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158280/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158280/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158300/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe158300/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190280/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190280/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190300/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190300/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190380/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190380/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190400/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe190400/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe198000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe198000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8000/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8080/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8080/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8100/name ]
+ cat /sys/kernel/debug/regmap/dummy-qos@0x00000000fe1a8100/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc20000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc20000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc50000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc50000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc60000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdc60000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdca0000/name ]
+ cat /sys/kernel/debug/regmap/dummy-syscon@0x00000000fdca0000/name
+ [ nodev = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fdec0000.ebc/name ]
+ cat /sys/kernel/debug/regmap/fdec0000.ebc/name
+ [ rockchip-ebc = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe410000.i2s/name ]
+ cat /sys/kernel/debug/regmap/fe410000.i2s/name
+ [ rockchip-i2s-tdm = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe420000.i2s/name ]
+ cat /sys/kernel/debug/regmap/fe420000.i2s/name
+ [ rockchip-i2s-tdm = tps65185 ]
+ [ -e /sys/kernel/debug/regmap/fe440000.pdm/name ]
+ cat /sys/kernel/debug/regmap/fe440000.pdm/name
+ [ rockchip-pdm = tps65185 ]
+ echo rc=0
```
### TPS65185 pre
```
00: 19
01: 20
02: 03
03: 8f
04: 00
05: ff
06: ff
07: 00
08: 00
09: e1
0a: 00
0b: 1e
0c: 83
0d: 20
0e: 78
0f: 00
10: 66
```
### TPS65185 post
```
00: 19
01: 1f
02: 03
03: 8f
04: 00
05: ff
06: ff
07: 00
08: 00
09: e1
0a: 00
0b: 1e
0c: 83
0d: 20
0e: 78
0f: fa
10: 66
```
### dmesg tail post
```
[    8.855445] Bluetooth: BNEP (Ethernet Emulation) ver 1.3
[    8.855973] Bluetooth: BNEP filters: protocol multicast
[    8.856452] Bluetooth: BNEP socket layer initialized
[    9.265285] Bluetooth: hci0: BCM: features 0x2f
[    9.267010] Bluetooth: hci0: BCM43455 37.4MHz Raspberry Pi 3+-0190
[    9.267033] Bluetooth: hci0: BCM4345C0 (003.001.025) build 0382
[    9.292052] Bluetooth: MGMT ver 1.23
[    9.308429] NET: Registered PF_ALG protocol family
[   11.003624] systemd-journald[215]: File /var/log/journal/c67879d64fb749eb824ccd1ba7cfea0c/user-1000.journal corrupted or uncleanly shut down, renaming and replacing.
[   20.691191] rfkill: input handler disabled
[   26.878396] ebc: rockchip_ebc_ctx_release
[   26.878436] EBC: rockchip_ebc_ctx_free
[   30.705990] vdda_0v9_ldo: disabling
[   30.708332] vccio_sd: disabling
[   30.711860] vbat_4g: disabling
[  110.613092] PM: suspend entry (deep)
[  110.615548] Filesystems sync: 0.002 seconds
[  110.616091] Freezing user space processes
[  110.620428] Freezing user space processes completed (elapsed 0.003 seconds)
[  110.621107] OOM killer disabled.
[  110.621397] Freezing remaining freezable tasks
[  110.623263] Freezing remaining freezable tasks completed (elapsed 0.001 seconds)
[  110.623918] printk: Suspending console(s) (use no_console_suspend to debug)
[  110.628404] st_accel_suspend
[  110.628598] rockchip_ebc_suspend
[  111.643433] ieee80211 phy0: brcmf_fil_cmd_data: bus is down. we have nothing to do.
[  111.643460] ieee80211 phy0: brcmf_cfg80211_get_tx_power: error (-5)
[  112.217742] PM: suspend devices took 1.593 seconds
[  112.220347] Disabling non-boot CPUs ...
[  112.221516] psci: CPU3 killed (polled 0 ms)
[  112.224200] psci: CPU2 killed (polled 0 ms)
[  112.226850] psci: CPU1 killed (polled 0 ms)
[  112.227826] Enabling non-boot CPUs ...
[  112.228781] Detected VIPT I-cache on CPU1
[  112.228842] GICv3: CPU1: found redistributor 100 region 0:0x00000000fd480000
[  112.228902] CPU1: Booted secondary processor 0x0000000100 [0x412fd050]
[  112.229737] CPU1 is up
[  112.230606] Detected VIPT I-cache on CPU2
[  112.230660] GICv3: CPU2: found redistributor 200 region 0:0x00000000fd4a0000
[  112.230710] CPU2: Booted secondary processor 0x0000000200 [0x412fd050]
[  112.231477] CPU2 is up
[  112.232342] Detected VIPT I-cache on CPU3
[  112.232393] GICv3: CPU3: found redistributor 300 region 0:0x00000000fd4c0000
[  112.232441] CPU3: Booted secondary processor 0x0000000300 [0x412fd050]
[  112.233838] CPU3 is up
[  112.237541] st_accel_resume
[  112.265394] mmc_host mmc1: Bus speed (slot 0) = 375000Hz (slot req 400000Hz, actual 375000HZ div = 0)
[  112.289665] ebc: rockchip_ebc_plane_reset
[  112.290040] ebc: rockchip_ebc_ctx_release
[  112.290050] EBC: rockchip_ebc_ctx_free
[  112.383175] mmc_host mmc1: Bus speed (slot 0) = 150000000Hz (slot req 150000000Hz, actual 150000000HZ div = 0)
[  112.519250] dwmmc_rockchip fe2c0000.mmc: Successfully tuned phase to 219
[  112.527991] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43455-sdio for chip BCM4345/6
[  112.528223] brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43455-sdio.pine64,pinenote-v1.2.bin failed with error -2
[  112.529581] PM: resume devices took 0.294 seconds
[  112.544957] OOM killer enabled.
[  112.545260] Restarting tasks ... done.
[  112.579284] PM: suspend exit
[  112.641811] brcmfmac: brcmf_c_process_txcap_blob: no txcap_blob available (err=-2)
[  112.644136] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/6 wl0: Apr 15 2021 03:03:20 version 7.45.234 (4ca95bb CY) FWID 01-996384e2
```
