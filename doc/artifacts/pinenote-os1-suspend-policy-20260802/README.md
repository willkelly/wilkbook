# os1's live suspend policy — the donor values, measured (2026-08-02)

Extracted from the **DTB os1 actually boots**, read without a reboot by
mounting `/dev/mmcblk0p5` read-only from os2 (`ro,noload`, unmounted
cleanly afterwards). Source path inside os1:

```
/usr/lib/linux-image-6.12.11-pinenote-202501281646-00249-g211ba27556cc/rockchip/rk3566-pinenote-v1.2.dtb
sha256 7032b76da3f8bcfecdc15e42b226f0a812146cf779f3c6c2d75a984b08ef064c
```

That is the kernel on which **deep suspend demonstrably works on this
device** (os1 oracle, 2026-08-01: rc=0, panel alive on resume, PG
`0x00→0xfa`, VCOM `0x8f` surviving a real SLEEP reset).

```dts
rockchip-suspend {
	compatible = "rockchip,pm-rk3568";
	status = "okay";
	rockchip,sleep-debug-en = <0x00>;
	rockchip,sleep-mode-config = <0x5ec>;
	rockchip,wakeup-config = <0x10>;
};
```

**This matches `pinenote/tools/rockchip-pm/fixtures/donor-pinenote-policy.dts`
exactly** — same compatible, same three values. The `0x5ec` constant our
model has carried was previously undocumented as to provenance, which made
it look like a guess. It is not: it is byte-identical to the policy the
known-working BSP kernel applies on this exact hardware.

Two further facts from the same DTB:

- **No `rockchip,suspend-state-override`.** os1 reaches working deep with
  the plain BSP state; the override is an hrdl ultra-suspend extension and
  is not required for the baseline we want.
- The 2026-08-02 UART trace showed bl31 reporting `PM-STATE: mem (ultra: 0,
  mem: 1, cfg: 0x0)`. `cfg: 0x0` is precisely the absence of the values
  above. os1 sends them; we send nothing.

## Why this matters for the activation decision

It removes the largest unknown. The risk in enabling activation was always
"we are about to hand firmware a config word we invented." We are not —
the word is the one the working kernel uses, now verified from the device's
own filesystem rather than from a community tree or a model.
