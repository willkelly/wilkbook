# Kernel packaging and the forward-port workflow

Keeping the kernel current is a core goal of this project. The PineNote needs
a downstream display/pen stack that has never been mainlined, so every kernel
update means carrying those changes forward.

## The two kernel packages

Both live in `pinenote/packages/kernel.scm`:

- `linux-pinenote-6.6.30` — the m-weigand PineNote tree, pinned by commit.
  Hardware-validated end to end (display, Wi-Fi, BT, USB gadget). Kept as the
  known-good baseline and for isolating regressions in newer kernels.
- `linux-pinenote` — Guix's current `linux-libre` source plus
  `pinenote/patches/linux-pinenote-7.0-forward-port.patch`, configured with
  `pinenote_defconfig`. This is the kernel-currency track.

## What the forward-port patch carries

- the `rockchip_ebc` DRM driver (EBC e-ink controller),
- the WS8100 pen driver,
- PineNote DTS/DTSI (`rk3566-pinenote-v1.2.dts`, `rk3566-pinenote.dtsi`),
- `arch/arm64/configs/pinenote_defconfig`,
- supporting bits (TPS65185 PMIC integration, etc.).

## Refreshing the patch for a new kernel

1. Check the current Guix `linux-libre` version the package inherits:
   `guix build --source -L . -e '(@ (pinenote packages kernel) linux-pinenote)'`
2. In a disposable tree, unpack that source and apply the existing patch.
   Resolve rejects against the m-weigand/hrdl trees as reference
   (https://github.com/m-weigand/linux, branches like
   `branch_pinenote_6-12-11`).
3. Sanity-check the tree without building:
   `pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/tree`
4. Regenerate `pinenote/patches/linux-pinenote-7.0-forward-port.patch` as a
   single diff against the pristine source.
5. Gate with derivation computation, then build:

   ```sh
   guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
     --target=aarch64-linux-gnu
   ```

6. Verify the output contains uncompressed `Image`, modules, and
   `lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb`.

## Hard-won configuration lessons

Record anything that took a hardware session to discover:

- `CONFIG_GPIO_ROCKCHIP=y` (built-in, not module). As a module, boot dies in
  a mass deferred-probe storm (regulators, sdhci, dwc3 extcon, EBC
  temperature channel all waiting on GPIO) and root never appears.
- The TPS65185 module is named `tps65185-regulator` in newer kernels but
  `tps65185` in 6.6; the initrd module lists in
  `pinenote/images/pinenote-initramfs.scm` differ for exactly this reason.
- Use the uncompressed `Image`; older PineNote U-Boot may not load
  `Image.gz`.
- Kernel arguments that matter are centralized in
  `pinenote/images/pinenote-initramfs.scm`
  (`earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off` plus the
  `rockchip_ebc` parameters).

## The linux-libre firmware problem

linux-libre's deblob pass does not just omit firmware files — it disables
non-free firmware *loading* by rewriting request paths to
`/*(DEBLOBBED)*/`. Consequences observed on hardware:

- brcmfmac Wi-Fi firmware is rejected at runtime even when the files are
  present under the exact requested names. Packaging firmware
  (`pinenote-broadcom-wifi-firmware`) cannot fix this, and partially
  restoring the driver in the forward-port patch (firmware name strings plus
  the `request_firmware`/`firmware_request_nowarn` call sites) was tried and
  still hits "Missing Free firmware (non-Free firmware loading is
  disabled)" — the loading machinery itself is gated, not just the names.
- The Bluetooth `BCM4345C0.hcd` path survived (loads on 7.0) once the
  PineNote v1.2 device alias was provided.

For full hardware support the forward-port needs to move from `linux-libre`
to vanilla kernel.org sources (a custom origin in `kernel.scm`, conceptually
what the nonguix channel does for its `linux` package). That keeps the same
inherit-and-patch structure; only the source origin changes. This is tracked
in `ROADMAP.md`.
