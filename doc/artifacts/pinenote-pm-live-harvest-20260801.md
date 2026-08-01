# PM live ground truth — os2, 2026-08-01

Captured over SSH from the running publish-on-call image (kernel 7.0.11,
reader active, EBC idle). Read-only. Companion to the 2026-08-01 evidence
pass in doc/power-management.md.

## TPS65185 register file (i2c 3-0068, regmap debugfs)

```
tps65185
00: 17
01: 2f
02: 03
03: 8f
04: 00
05: 7f
06: ff
07: 00
08: 00
09: e1
0a: 00
0b: 1e
0c: 00
0d: 20
0e: 78
0f: fa
10: 66
```

VCOM1=0x8f (143 -> -1.43 V): the per-device calibrated value, live in
the chip, matching vendor-storage record 17; factory default is 0x7D.
UPSEQ0=0xe1 differs from the datasheet default 0xE4 (driver-programmed
at probe from DT); DWNSEQ0 matches its default.

## Regulators, DT suspend states, wakeup sources, battery

```
=== regulators (name:state:users:suspend-mem) ===
regulator-dummy :  : users=4 : mem=disabled
vbat_4g :  : users=0 : mem=disabled
vdd_gpu_npu : disabled : users=0 : mem=enabled
vcc_ddr : enabled : users=1 : mem=enabled
vcc_3v3 : enabled : users=4 : mem=enabled
vcca_1v8_pmu : enabled : users=3 : mem=enabled
vdda_0v9_ldo : disabled : users=0 : mem=enabled
vdda_0v9_pmu : enabled : users=1 : mem=enabled
vccio_acodec : enabled : users=1 : mem=enabled
vccio_sd : disabled : users=0 : mem=enabled
vcc_3v3_pmu : enabled : users=3 : mem=enabled
vcc_1v8_en : enabled : users=1 : mem=enabled
vcc_1v8 :  : users=2 : mem=disabled
vbat_4g_en : disabled : users=0 : mem=enabled
sleep_sta_ctl : disabled : users=0 : mem=enabled
boost : disabled : users=0 : mem=enabled
otg_switch : disabled : users=0 : mem=enabled
v3p3 : enabled : users=1 : mem=disabled
vposneg : enabled : users=0 : mem=disabled
vcom : disabled : users=0 : mem=disabled
vcc_bat :  : users=4 : mem=disabled
vcc_hall_3v3 :  : users=1 : mem=disabled
vcc_sys :  : users=11 : mem=disabled
vcc_wl : enabled : users=2 : mem=disabled
vdda_0v9 :  : users=0 : mem=disabled
vdd_cpu : enabled : users=2 : mem=enabled
vdd_logic : enabled : users=1 : mem=enabled
=== DT regulator-state-mem nodes ===
=== sdmmc1 power props ===

=== rockchip-suspend node / pm driver ===
/proc/device-tree/rockchip-suspend
rockchip-pm-domain
rockchip-suspend-mode
=== wakeup-capable devices ===
/sys/class/wakeup/wakeup10/name:ws8100_pen
/sys/class/wakeup/wakeup11/name:serial0-0
/sys/class/wakeup/wakeup1/name:0-0020
/sys/class/wakeup/wakeup2/name:rk805-pwrkey.2.auto
/sys/class/wakeup/wakeup3/name:rk808-rtc.3.auto
/sys/class/wakeup/wakeup4/name:alarmtimer.4.auto
/sys/class/wakeup/wakeup5/name:rk817-battery
/sys/class/wakeup/wakeup6/name:rk817-charger
/sys/class/wakeup/wakeup7/name:mmc0
/sys/class/wakeup/wakeup8/name:mmc1
/sys/class/wakeup/wakeup9/name:gpio-keys
=== battery telemetry ===
charge_now=3985412 charge_full=4000000 voltage_now= current_now= capacity=100 status=Discharging 
=== iio (sc7a20 + tps65185 temp) ===
/sys/bus/iio/devices/iio:device0: tps65185
/sys/bus/iio/devices/iio:device1: sc7a20
/sys/bus/iio/devices/iio:device2: fe720000.saradc
=== mem_sleep / wakeup_sources count ===
s2idle [deep]
14
```
