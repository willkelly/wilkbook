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
written as a full-device image. Gate 6 host-side prep extracts the single Linux
root partition from that disk image into a direct ext4 rootfs artifact labelled
`PNGuixRoot` before considering any manual placement into a confirmed OS slot.

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
- Networking is only a userspace baseline here. Real PineNote Wi-Fi still needs
  firmware and credential handling decisions.
