# Roadmap

Three tracks, in priority order. Current hardware truth lives in
`doc/status.md`; this file is direction, not status.

## 1. Kernel currency

Goal: stay close to current mainline kernels while carrying the PineNote
display/pen stack as explicit patches, with working firmware.

- [x] Move `linux-pinenote` from the `linux-libre` base to vanilla
      kernel.org sources (2026-06-10: rebased onto nonguix's `linux`,
      deblob-restoration hunks dropped from the patch; see
      `doc/kernel-forward-port.md`). Wi-Fi firmware loading on the vanilla
      base still needs hardware confirmation.
- [ ] Get EBC display output working on the forward-ported kernel. 6.6
      works entirely; 7.0 boots but has shown nothing on the panel yet.
      Compare rockchip_ebc probe/bind between 6.6 and 7.0 UART logs.
- [ ] Fix the USB gadget on 7.0 (`dwc3: failed to enable ep0out`); confirm
      the role-switch-gated v3 gadget service on hardware.
- [ ] Write down each patch-refresh in `doc/kernel-forward-port.md` (new
      base version, conflicts hit, config deltas) so the next refresh is
      cheaper.
- [ ] Once 7.0 reaches parity with 6.6, retire the 6.6 package or keep it
      only as a regression-isolation tool.

## 2. Easy image building

Goal: one command from checkout to deployable artifact.

- [ ] `make <flavor>` builds the image and extracts the validated
      `PNGuixRoot` rootfs (Makefile wraps the commands in
      `doc/building.md`).
- [ ] Re-measure flavor closure sizes after the firmware packages landed
      (`doc/pinenote-flavors.md` table is stale).
- [ ] Decide the Broadcom firmware delivery story now that firmware
      packages exist: wire `pinenote-brcm-firmware-service-type` into a
      flavor or delete it, and retire the `/state/firmware/brcm` runtime
      helper if the packages make it redundant.
- [ ] Eventually: A/B slot awareness (os1/os2) in the image tooling rather
      than manual dd.

## 3. E-ink userland

Goal: a reading-first device. Not started; blocked on display output on the
kernel-currency track (or can begin against the working 6.6 flavor).

- [ ] Grow `pinenote-ebc-test` into the staged render harness from the
      original plan (`doc/archive/phase1a-bringup-plan.md`): grayscale
      ramps, partial updates, waveform comparison (A2/DU4/GC16), then a
      small Gray8→Y4 raster library.
- [ ] Decide the reader direction: a KOReader spin (it already has
      framebuffer e-ink rendering and would mostly need packaging plus
      EBC-aware refresh hints) versus a custom MuPDF-based renderer (full
      control over waveform-aware rendering, much more work). Packaging
      KOReader on Guix is nontrivial (LuaJIT + vendored deps); prototype
      against the 6.6 flavor first.
- [ ] Wi-Fi credentials/networking story for the device (the networked
      flavor has no credential handling yet).
- [ ] Later: Wayland/wlroots shell informed by WinkShell; system D-Bus only
      when a concrete service needs it.
