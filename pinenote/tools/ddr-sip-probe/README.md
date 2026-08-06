# ddr-sip-probe — read-only Rockchip DRAM SIP go/no-go

A tiny out-of-tree kernel module that answers one question at zero risk:
**does this device's bl31 implement the Rockchip DRAM-frequency SIP
interface** (`SIP_DRAM_CONFIG`, 0x82000008) that the BSP DMC driver
drives?  It issues only version *queries* on init, printks the raw
SMC results, and returns `-ENODEV` so it never stays loaded.  Per SMCCC,
an unimplemented function ID returns `SMC_UNK` (-1) harmlessly — which is
why the queries are safe and any `SET_*` call would not be.

## Answer on the PineNote (2026-08-06, bl31 from the stock BSP boot chain)

```
ATF_VERSION      fid=0x82000001 -> a0=0xffffffffffffffff        (UNK — variant difference, fine)
SIP_VERSION      fid=0x8200000a -> a0=0x0  a1=0x2               (SIP v2)
DRAM_GET_VERSION fid=0x82000008 -> a0=0x0  a1=0x101             (IMPLEMENTED, DDR ATF v0x101)
```

**GO.**  a0=0 is `SIP_RET_SUCCESS`; the BSP `rockchip_dmc.c` requires the
version in a1 to be ≥ 0x100.  DDR DVFS is genuinely available from this
firmware; what is missing is only the Linux side (mainline has no rk356x
DMC driver, and even Rockchip's 6.12 BSP DTB for the PineNote does not
wire one up — no board has ever run DDR DVFS on this device).

Constants and calling convention were extracted from the BSP tree
(`include/soc/rockchip/rockchip_sip.h`, `drivers/firmware/rockchip_sip.c`,
`drivers/devfreq/rockchip_dmc.c`): the subfunction rides in x3;
`GET_VERSION` = 0x08.

## Build (cross, against the exact running kernel)

```
guix build -L <repo> --target=aarch64-linux-gnu -f guix.scm
```

`guix.scm` uses `linux-module-build-system` with `#:linux linux-pinenote`,
so the resulting .ko carries the same vermagic **and** MODVERSIONS CRCs as
the deployed kernel — verified by comparing against the store kernel's own
`Module.symvers` before first load.

## Run

```
insmod ddr-sip-probe.ko    # prints "could not insert ... No such device"
dmesg | grep ddr_sip_probe # -- that error IS the success path
```

Loading an out-of-tree module taints the kernel (flag `O`); the taint is
cosmetic and clears on reboot.

## Scope guard

This module must never grow `SET_RATE`, `SET_AT_SR`, share-mem setup, or
any other write toward the firmware.  A wrong DRAM write hangs the memory
the kernel is executing from; the entire value of this probe is that it
cannot do that.
