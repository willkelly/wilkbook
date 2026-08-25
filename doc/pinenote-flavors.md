# PineNote System Flavors

The bring-up channel keeps target images separate from host-side build, QEMU,
and development tooling. The working budget is a maximum 4 GiB per boot slot,
with two slots expected for A/B testing on 128 GB storage.

## Flavors

| Flavor | Entrypoint | Purpose |
| --- | --- | --- |
| slim | `pinenote/systems/pinenote-slim.scm` | Smallest current PineNote boot target: PineNote kernel, waveform/EBC/diagnostics services, and local helper packages only. |
| usb-console | `pinenote/systems/pinenote-usb-console.scm` | Slim target plus a USB CDC-ACM gadget, auto-login `reader` getty on `ttyGS0` and UART `ttyS2`, and passwordless `sudo` for `reader`. Carries the forward-ported `linux-pinenote` kernel; this is the kernel-currency track (see `doc/status.md` for open issues). |
| usb-console-linux-6-6 | `pinenote/systems/pinenote-usb-console-linux-6-6.scm` | Same as usb-console but with the m-weigand 6.6.30 kernel and matching initrd. Regression-isolation tool only since 2026-07-04, when the 7.0 usb-console flavor reached display/gadget/RT parity on hardware. |
| reader | `pinenote/systems/pinenote-reader.scm` | The reading-first target and current deploy artifact. Slim base plus: KOReader natively on the framebuffer (`reader-session`; `doc/refresh-policy.md` for the shipped refresh architecture), the SC7A20→uinput orientation bridge, the ACM **gadget** (always) whose unauthenticated auto-login `reader` shell is built ONLY when `WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE` is set — default builds have the gadget bound but nothing listening, and `/etc/wilkbook-build` names which one you have (`pinenote/insecure.scm`), Wi-Fi from out-of-band credentials + `dhcpcd` + key-only root SSH (hardware-proven; `doc/networking.md`), DDR dmc/boost services, and idle auto-suspend to ultra (rails-off, 4.64 mA measured 2026-08-08;
wake = power button/RTC/charger only — `doc/power-management.md`), and the manuals shelf: the man pages and Texinfo manuals of this flavor's own packages, converted to EPUB at build time and staged into `/data/books/Manuals` (issue #17, `doc/manuals.md`; nothing in it has been rendered by KOReader yet). **No** ttyS2 auto-login getty — UART login is the base kernel-console getty; a second agetty on that tty caused the 2026-07-12 os2 wedge (see the entrypoint comment). First light 2026-07-05; autorotation/touch normalization hardware-accepted 2026-07-19. |
| reader-debug | `pinenote/systems/pinenote-reader-debug.scm` | Temporary: the reader flavor with the diagnostic kernel (`linux-pinenote-debug`, EXTRACT_FBS belief-dump ioctl), hostname `pinenote-reader-dbg` so the flashed slot is identifiable at the login prompt, and the inert `ebc-dump-grab` CLI. Delete together with the debug patch when the investigations close (see the entrypoint comment). |
| reader-direct | `pinenote/systems/pinenote-reader-direct.scm` | **A study artifact, not a product, and never a deploy candidate.** The reader flavor on hrdl's direct-mode EBC driver (`linux-pinenote-hrdl-direct`, `doc/direct-mode-adoption.md` P2), hostname `pinenote-reader-direct`, plus the `wbf-clut` CLUT compiler as an on-device CLI. It **builds and evaluates; nothing in it has ever run** — no module loaded, no device bound, no panel driven — and it is expected **not** to reach a working reader on a first boot. Three known reasons, all established offline: (a) the driver `request_firmware`s `rockchip/custom_wf.bin` and its probe returns `-EINVAL` without it, nothing produces that file at boot yet, and the initrd raw-loads `rockchip_ebc` before the root filesystem is mounted — so a root-filesystem service that writes it later cannot fix the probe without also reloading the module; (b) the shipped `/etc/modprobe.d/rockchip_ebc.conf` names nine parameters of which exactly **one** (`dclk_select`) exists in this driver, which is inert while the initrd raw-loads the module and fatal to the first `modprobe` after any reload; (c) the refresh policy still speaks A2, which hrdl's CLUT drops, and three self-heal paths write a `refresh_waveform` parameter this driver does not have (they log and fall back to a plain full wash rather than crash). The realistic first goal is *"the module probes, binds, and lights the panel at all"*, not a working page turn. Page turns themselves should survive the swap: `GLOBAL_REFRESH` is ABI-identical, so KOReader's ioctl is unchanged. Delete together with the direct-mode patch if the adoption hits a bail-out criterion. |
| networked | `pinenote/systems/pinenote-networked.scm` | Slim target plus `dhcpcd` and `wpa_supplicant` for an initial Wi-Fi/DHCP size baseline. The `wpa_supplicant` D-Bus control interface is disabled, and no network credentials are embedded. |
| minimal | `pinenote/systems/pinenote-minimal.scm` | Bring-up target with PineNote services plus Guix `%base-packages`, but without the Guix daemon service. |
| dev | `pinenote/systems/pinenote-dev.scm` | Development comparison target that restores `%base-services`, including the Guix service. Keep this out of release boot slots unless explicitly needed. |

## Current Measurements

Measured with `guix system build -L . --target=aarch64-linux-gnu ...` and
`guix size --sort=self` after the PineNote kernel build succeeded. These
numbers predate the Broadcom firmware packages and the usb-console flavors;
re-measure before relying on them (tracked in `ROADMAP.md`).

| Flavor | System closure | Compressed tarball rootfs proxy |
| --- | ---: | ---: |
| slim | 858.8 MiB | 228,662,337 bytes |
| networked | 919.7 MiB | 243,633,694 bytes |
| minimal | 1104.6 MiB | 291,310,712 bytes |
| dev | 1799.5 MiB | 469,258,730 bytes |

The tarball image is a safe rootfs-size proxy. The `raw-with-offset` image path
is only a build intermediate; it is not hardware-boot validated and must not be
written as a full-device image. Host-side prep (`doc/building.md`, "Rootfs
extraction") extracts the single Linux root partition from that disk image into
a direct ext4 rootfs artifact labelled `PNGuixRoot` before considering any
manual placement into a confirmed OS slot.

## Measurement Commands

```sh
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-usb-console.scm
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-networked.scm
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-minimal.scm
guix system build -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-dev.scm
```

For a compressed rootfs proxy:

```sh
guix system image -t tarball -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-slim.scm
```

## Notes

- The `cross-aarch64` runtime library names in `guix size` are target AArch64
  runtime outputs from the cross build, not host compilers intentionally placed
  in the release slot.
- Host QEMU, Mesa, GTK, Python, and build environments are outside these target
  system closures unless a flavor explicitly references them.
- Slim, networked, and minimal are service-level D-Bus-free bring-up targets.
  Current `networked` closure measurements can still include D-Bus libraries
  through `wpa_supplicant` package references; that does not mean a system
  D-Bus service or D-Bus network control path is enabled.
- A later desktop, mobile, or reader-shell flavor should add system D-Bus
  deliberately when a concrete service needs it. PineNote control daemons,
  NetworkManager, BlueZ, and sensor proxy stacks commonly use D-Bus, but they
  are outside the current release-slot baseline.
- The reader flavor's Wi-Fi firmware, out-of-band credential handling,
  association, DHCP, key-only root SSH, and `scp` are hardware-proven. The
  `networked` flavor remains a closure-size/service baseline rather than the
  deployed reader path; see `doc/networking.md`.
