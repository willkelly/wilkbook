# PineNote Gate 6 Serial and U-Boot Worksheet

This worksheet prepares the first serial-console interaction with U-Boot. It is
not authorization to write `os2`, change U-Boot environment variables, flash,
repartition, or alter persistent boot selection.

## Current matched artifacts

Use the rootfs-matched boot bundle, not the older `guix system build` bundle,
for any boot attempt paired with the extracted rootfs image. The matched bundle
was extracted from the validated `PNGuixRoot` rootfs, so its `gnu.system`,
`gnu.load`, kernel, and initrd paths match the root filesystem contents.

| Artifact | Path | Size | SHA-256 |
| --- | --- | ---: | --- |
| rootfs | `/tmp/opencode/pinenote-rootfs-artifacts/pinenote-slim-PNGuixRoot-20260510.ext4` | 1,137,762,304 bytes | `26c1645ce3ccb3f87bc3a09db137c30217c026bbecf45bb70d874f6e4b6e11b1` |
| boot bundle | `/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510` | directory | inspected by `inspect-boot-bundle.sh` |
| `Image` | `/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510/extlinux/Image` | 19,491,328 bytes | `6991061f6c5b387df6aa4ed9f46e3fc626e50b4b8cffb07784b21d24797e33ad` |
| `rk3566-pinenote-v1.2.dtb` | `/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510/extlinux/rk3566-pinenote-v1.2.dtb` | 61,094 bytes | `4f99379db3be1a4d6dc1b328bead01c1c5a0774d3625640f9260dd73df32d8c0` |
| `initrd.cpio.gz` | `/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510/extlinux/initrd.cpio.gz` | 12,256,926 bytes | `2be3a56cc41456cdc87b0c8a46073119804fdbf96ca39392cf4f4b1d10c51d67` |
| `extlinux.conf` | `/tmp/opencode/pinenote-gate6-rootfs-boot-bundle-slim-20260510/extlinux/extlinux.conf` | 546 bytes | `bb53b497f405387b65f284e2df69dee7c7ae1e29e10ec069b133d1f8b90b22e4` |

The matched `extlinux.conf` uses:

```text
APPEND root=LABEL=PNGuixRoot gnu.system=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system gnu.load=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system/boot ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off
```

## Stop before opening the serial session

All items must be true before interacting with U-Boot:

- Local and NFS backups from 2026-05-08 and 2026-05-10 still verify.
- The operator has a known power-cycle path back to stock Debian `os1`.
- The serial adapter and capture command are ready, and output will be logged.
- No command block below will be pasted until it has been edited for the
  discovered U-Boot device/partition names.
- No command containing `saveenv`, `env save`, `mmc write`, `ext4write`,
  `fatwrite`, `gpt write`, `part write`, `sf write`, `ums`, `rockusb`, or
  `fastboot` will be typed.

## Serial capture

### USB CDC-ACM status

Current host/PineNote USB-C checks do not show a U-Boot console path:

- The host currently has no `/dev/ttyACM*` or `/dev/ttyUSB*` node for the
  PineNote.
- The host kernel has `cdc_acm` available, but it is not loaded because no
  matching USB CDC-ACM interface is enumerating.
- Stock Debian on the PineNote exposes USB device controller
  `/sys/class/udc/fcc00000.usb`, but no configfs USB gadget is configured.
- The backed-up U-Boot image contains `stdout=serial,vidconsole` and
  `stdin=serial,pwr_key_stdin,touch_keys`; its USB gadget strings are for
  `fastboot`, `rockusb`, and `UMS`, not a `usbtty`/CDC-ACM console.

Do not use `fastboot`, `rockusb`, or `UMS` for Gate 6 discovery. They are
download/storage modes and are not a read-only U-Boot console path.

Conclusion: the USB-C cable to the host is not currently a U-Boot console. The
`usb0` boot target in U-Boot expects USB storage or network devices visible to
the PineNote as a USB host; a normal host-to-device USB-C cable to a laptop does
not make the laptop a readable U-Boot disk.

With USB-C as the only physical connection, the confirmed control plane is stock
Debian while it is booted. A first Guix attempt must therefore be staged from
stock Debian and kept limited to the inactive OS slot unless a verified U-Boot
USB-console or `fastboot boot` flow is proven separately.

The validated rootfs artifact now also normalizes the embedded
`/boot/extlinux/extlinux.conf` to `root=LABEL=PNGuixRoot`, so it is suitable for
an explicitly approved OS2 placement as well as for the external matched boot
bundle.

The initial slim rootfs was written to `os2` and verified, but was not rebooted
because it had no confirmed USB-C console, Wi-Fi credentials, SSH path, or
keyboard path. It has since been replaced on `os2` by
`pinenote/systems/pinenote-usb-console.scm`, which exposes a CDC-ACM gadget and
auto-login `reader` console on `ttyGS0` after Shepherd starts. The next stop
point is reboot approval.

## USB-C-only first-boot path

This is the preferred no-UART path. The OS2 write boundary has been crossed only
after explicit operator approval; the reboot boundary has not:

1. Keep stock Debian `os1` as the rescue system and control plane.
2. Verify backups and confirm `/dev/mmcblk0p6` (`os2`) is unmounted and
   expendable.
3. Stop for explicit approval to write only the inactive `os2` partition.
4. Write the validated USB-console `PNGuixRoot` rootfs artifact to `os2` from
   stock Debian.
5. Re-read `os2` metadata and embedded `/boot/extlinux/extlinux.conf`; confirm
   label `PNGuixRoot`, `root=LABEL=PNGuixRoot`, and no `root=/dev/mmcblk`.
6. Stop again before reboot. This is the current state.
7. Reboot only after explicit approval, with the expectation that unchanged U-Boot
   can still return to stock Debian `os1` if the `os2` boot fails.

`fastboot boot` remains a possible USB-C-only experiment, but not the first
choice: it requires proving that stock Debian can enter fastboot and that this
U-Boot accepts the host-built boot image/kernel+ramdisk+DTB form. It still needs
a root filesystem, so it does not eliminate the `os2` placement decision.

Use the actual host serial device in place of `<serial-device>`. The PineNote
kernel command line uses `console=ttyS2,1500000n8`; keep the serial session at
1,500,000 baud unless the U-Boot banner proves a different setting.

```sh
mkdir -p /tmp/opencode/pinenote-gate6-serial
guix shell picocom -- \
  picocom -b 1500000 \
    --logfile /tmp/opencode/pinenote-gate6-serial/uboot-$(date +%Y%m%d-%H%M%S).log \
    <serial-device>
```

If the prompt is not visible, stop and recover stock Debian before trying a boot
sequence.

## Read-only U-Boot discovery commands

These commands inspect the running U-Boot session and do not persist state.
Record the output, then stop and update this worksheet if device numbering or
available commands differ.

```text
version
bdinfo
printenv bootcmd boot_targets kernel_addr_r fdt_addr_r ramdisk_addr_r scriptaddr pxefile_addr_r
mmc list
part list mmc 0
usb start
usb tree
part list usb 0
```

Stop after discovery if any of these are true:

- `kernel_addr_r`, `fdt_addr_r`, or `ramdisk_addr_r` is unset.
- The intended boot source is not visible to U-Boot.
- The only visible rootfs target would require writing PineNote eMMC without
  explicit approval.
- Any read-only command behaves unexpectedly.

## Preferred no-eMMC-write boot shape

The safest first hardware boot remains a removable or otherwise non-eMMC source
that U-Boot can read without persistent environment changes:

- a boot partition containing the matched bundle's `/extlinux` directory;
- a root filesystem labelled `PNGuixRoot` from the validated rootfs artifact.

This still needs hardware confirmation that U-Boot can read the boot source and
that the kernel/initrd can discover the labelled root filesystem.

## Temporary boot via `sysboot`

Use this only after read-only discovery confirms the boot device and partition.
Edit `pn_bootdev` and `pn_bootpart` before typing. Do not run `saveenv`.

```text
setenv pn_bootdev usb
setenv pn_bootpart 0:1
usb start
sysboot ${pn_bootdev} ${pn_bootpart} any ${scriptaddr} /extlinux/extlinux.conf
```

Do not use `sysboot` against `/boot/extlinux/extlinux.conf` inside `os2` for the
Gate 6 label-root test: the Guix-generated source file inside the rootfs uses
the filesystem UUID from image construction. For an explicitly approved `os2`
experiment, use the manual `booti` block below so the boot arguments still use
`root=LABEL=PNGuixRoot`.

## Manual `booti` fallback

Use this only if `sysboot` is unavailable or cannot parse the generated
`extlinux.conf`. Load the initrd last so `${filesize}` still contains the initrd
size when `booti` runs.

For a removable boot partition with `/extlinux` copied from the matched bundle:

```text
setenv pn_bootdev usb
setenv pn_bootpart 0:1
usb start
load ${pn_bootdev} ${pn_bootpart} ${kernel_addr_r} /extlinux/Image
load ${pn_bootdev} ${pn_bootpart} ${fdt_addr_r} /extlinux/rk3566-pinenote-v1.2.dtb
load ${pn_bootdev} ${pn_bootpart} ${ramdisk_addr_r} /extlinux/initrd.cpio.gz
setenv bootargs 'root=LABEL=PNGuixRoot gnu.system=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system gnu.load=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system/boot ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off'
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

For an explicitly approved `os2` experiment where the rootfs is already on
`/dev/mmcblk0p6`, the rootfs contains the source paths used to create the matched
bundle:

```text
setenv pn_bootdev mmc
setenv pn_bootpart 0:6
ext4load ${pn_bootdev} ${pn_bootpart} ${kernel_addr_r} /gnu/store/43g0m3k4gi9fcfnlbgi041z0fb3vic78-linux-pinenote-6.6.30-pinenote/Image
ext4load ${pn_bootdev} ${pn_bootpart} ${fdt_addr_r} /gnu/store/43g0m3k4gi9fcfnlbgi041z0fb3vic78-linux-pinenote-6.6.30-pinenote/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb
ext4load ${pn_bootdev} ${pn_bootpart} ${ramdisk_addr_r} /gnu/store/pbik33rj0zlan135fk5bpbf63r3hhgqr-raw-initrd/initrd.cpio.gz
setenv bootargs 'root=LABEL=PNGuixRoot gnu.system=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system gnu.load=/gnu/store/vfpialj7b776qnfc401sqn5lb723f9pb-system/boot ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off'
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

Do not use the `mmc 0:6` block until the write to `os2` has been separately
approved and completed.

## Success and recovery notes

During boot, capture serial output through at least one of these outcomes:

- Guix reaches a login prompt or Shepherd service output.
- The kernel panics or cannot find `PNGuixRoot`.
- The display/EBC path fails but serial continues far enough to identify the
  failure.

If the boot fails, power-cycle without saving U-Boot environment changes. The
expected rescue target remains stock Debian `os1` at `user@192.168.86.141`.
