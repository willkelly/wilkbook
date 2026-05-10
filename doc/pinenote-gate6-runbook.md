# PineNote Gate 6 Runbook

Gate 6 is the first hardware-adjacent preflight. It must remain read-only until
the backup, rescue, and operator-approval checks below pass. Do not flash,
repartition, mount images for writing, write bootloader environment variables,
or change persistent boot selection from this runbook.

## Current device inventory

Observed over SSH as `user@192.168.86.141` while stock Debian was running:

- OS: Debian GNU/Linux 13 (trixie)
- Kernel: `6.12.11-pinenote-202501281646-00249-g211ba27556cc`
- Boot root: `/dev/mmcblk0p5`, partition label `os1`
- Spare OS slot: `/dev/mmcblk0p6`, partition label `os2`, currently unmounted
- Data partition: `/dev/mmcblk0p7`, partition label `data`, mounted at `/home`
- Waveform partition: `/dev/mmcblk0p2`, partition label `waveform`
- U-Boot environment partition: `/dev/mmcblk0p3`, partition label `uboot_env`
- VCOM regulator: `vcom microvolts=1430000`
- EBC display: `/sys/class/drm/card0`, connector `card0-DPI-1`, connected at
  `1872x1404`
- Active PineNote-specific service: `pinenote-dbus-service`
- Active integration services: D-Bus, NetworkManager, `wpa_supplicant`,
  Bluetooth, GDM, SSH

Current stock-Debian kernel arguments use the raw root device:

```text
root=/dev/mmcblk0p5 ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 splash plymouth.ignore-serial-consoles vt.global_cursor_default=0
```

The Guix preflight target should continue to use label-based root selection:
`root=LABEL=PNGuixRoot`.

## Existing backup roots

Two backup copies currently exist:

- `/home/wkelly/pinenote-backup/2026-05-08`
- `/mnt/nastyboy/main/wkelly/pinenote-backup/2026-05-08`

Both copies verified with `sha256sum -c SHA256SUMS`, and matching files have the
same SHA-256 hashes and apparent sizes.

Existing backed-up artifacts:

| File | Status | Notes |
| --- | --- | --- |
| `waveform_p2.img` | present in both copies | Critical per-device waveform partition backup. |
| `ebc_orig.wbf` | present in both copies | Same SHA-256 as `waveform_p2.img`; firmware-form copy. |
| `uboot_env_p3.img` | present in both copies | U-Boot environment partition backup. |
| `mmcblk0_first16M.img` | present in both copies | GPT plus early eMMC area; includes only the beginning of `uboot`, not the full 64 MiB partition. |
| `ebc_batch2.wbf`, `ebc.wbf.backup` | present in both copies | Generic batch-2 waveform files. |
| `rockchip_ebc_default_screen.bin` | present in both copies | Stock display firmware asset. |
| `info.txt` | present in both copies | Partition map, kernel/cmdline, firmware listing, machine ID. |
| `README.md`, `SHA256SUMS` | present in both copies | Backup explanation and hashes. |

A read-only supplement also exists in both backup roots:

- `/home/wkelly/pinenote-backup/2026-05-10`
- `/mnt/nastyboy/main/wkelly/pinenote-backup/2026-05-10`

The supplement fills the pre-Gate-6 gaps that were safe to fill from stock
Debian over SSH. Both copies verify with their `SHA256SUMS`, and matching files
have the same SHA-256 hashes and apparent sizes.

Supplement artifacts:

| File | Status | Notes |
| --- | --- | --- |
| `uboot_p1.img` | present in both copies | Full 64 MiB `uboot` partition, read-only backup. |
| `logo_p4.img` | present in both copies | Full 64 MiB `logo` partition, read-only backup. |
| `current-inventory.txt` | present in both copies | Current partition map, cmdline, VCOM, EBC, DRM/input, and service state. |
| `dpkg-query.txt` | present in both copies | Stock Debian package inventory. |
| `pinenote-dbus-introspection.txt` | present in both copies | `org.pinenote.ebc`, `.pen`, `.usb`, and `.misc` D-Bus API inventory. |
| `service-units.txt` | present in both copies | Relevant stock systemd unit definitions. |
| `ssh-host-keys.txt`, `ssh-host-key-fingerprints.txt` | present in both copies | Public SSH host keys/fingerprints only; no private keys or passwords. |
| `uboot-env-printenv.txt` | present in both copies | Device-tree model/compatible strings plus read-only `fw_printenv` attempt. |

## Backup sufficiency checklist

### Must have before any reinstall or `os2` experiment

- Verified duplicate backup roots on local storage and NFS.
- `SHA256SUMS` verified in both backup roots.
- `waveform_p2.img` or equivalent raw `/dev/mmcblk0p2` backup.
- `ebc_orig.wbf` or equivalent firmware-form waveform copy.
- `uboot_env_p3.img` or equivalent raw `/dev/mmcblk0p3` backup.
- Current partition map with sizes, labels, PARTUUIDs, and mountpoints.
- Current kernel command line.
- Current VCOM value: `1430000` microvolts.
- Known-good rescue path: stock Debian `os1` boots to SSH at
  `user@192.168.86.141`.
- Explicit operator approval for any command that writes to eMMC, bootloader
  environment, partitions, firmware paths, or OS slots.

### Should have before any reinstall or persistent slot work

- Full raw backup of `uboot` (`/dev/mmcblk0p1`, 64 MiB): satisfied by
  `2026-05-10/uboot_p1.img`.
- Raw backup of `logo` (`/dev/mmcblk0p4`, 64 MiB): satisfied by
  `2026-05-10/logo_p4.img`.
- Inventory of stock Debian packages related to PineNote support, including:
  `pinenote-basic-support`, `pinenote-dbus-service`,
  `pinenote-gnome-extension`, and the installed PineNote kernel packages:
  satisfied by `2026-05-10/dpkg-query.txt`.
- Systemd service inventory for PineNote, D-Bus, NetworkManager, Bluetooth,
  GDM, and SSH: satisfied by `2026-05-10/current-inventory.txt` and
  `2026-05-10/service-units.txt`.
- D-Bus introspection output for `org.pinenote.ebc`, `org.pinenote.pen`,
  `org.pinenote.usb`, and `org.pinenote.misc`: satisfied by
  `2026-05-10/pinenote-dbus-introspection.txt`.
- EBC module parameter dump from `/sys/module/rockchip_ebc/parameters`:
  satisfied by `2026-05-10/current-inventory.txt`.
- DRM and input-device inventory, including `card0-DPI-1` mode and pen/touch
  device names: satisfied by `2026-05-10/current-inventory.txt`.
- SSH access note with hostname/IP, username, and host-key fingerprint. Do not
  store private keys or passwords in this repository. Public host keys and
  fingerprints are in the 2026-05-10 supplement.
- U-Boot environment text dump if readable. Current read-only `fw_printenv`
  output is backed up in `2026-05-10/uboot-env-printenv.txt`, but it reports
  `Cannot initialize environment`; rely on `uboot_env_p3.img` for raw backup.

### Optional but useful

- Read-only package list from stock Debian.
- Read-only copy of unit files for PineNote-specific services.
- Serial-console setup notes and power-recovery procedure.
- Photos of the current partition table, boot menu, and working stock display.

## Gate 6 stop conditions

Stop before any temporary boot attempt if any of these are true:

- The local and NFS backup roots do not both verify cleanly.
- The waveform or U-Boot environment backup is missing.
- The rescue path back to stock Debian `os1` is unclear.
- The target command would persistently alter boot order, U-Boot environment,
  partition layout, or eMMC contents.
- The operator has not explicitly approved a hardware-facing write step.

## Read-only commands used for inventory

These are safe to repeat over SSH because they do not write to the device:

```sh
hostname
id
uname -a
cat /etc/os-release
cat /proc/cmdline
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,MOUNTPOINTS
findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -l /dev/disk/by-partlabel /dev/disk/by-uuid
lsmod
cat /sys/module/rockchip_ebc/parameters/*
cat /sys/class/regulator/regulator.*/name
cat /sys/class/regulator/regulator.*/microvolts
ls -l /sys/class/drm /dev/dri /dev/input
cat /proc/bus/input/devices
systemctl --no-pager --type=service --state=running
busctl --system list
busctl --system introspect org.pinenote.ebc /ebc
busctl --system introspect org.pinenote.pen /pen
busctl --system introspect org.pinenote.usb /usb
busctl --system introspect org.pinenote.misc /misc
```

Do not add write-oriented commands to this runbook without a separate, explicit
approval step.
