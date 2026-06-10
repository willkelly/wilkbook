# PineNote Guix Minimal Bring-Up Plan

## Goal

Build a minimal, immutable, Guix-built PineNote image that boots far enough to begin working on native e-ink rendering.

We are attempting to build an a distro for our pine note.  The first step is going to be establishing our build system.

This is **not** the full Phase 1 reader OS yet. This is Phase 1A: the smallest useful image that proves the build system, kernel, firmware/waveform handling, Shepherd boot, and direct EBC rendering path.

## Safety Scope

This plan is a historical design reference. Hardware-oriented commands and
manual boot examples below are not authorized runbook steps for the current
static preflight phase. Do not run device reads, writes, flashing, repartitioning,
bootloader environment changes, or persistent boot-selection changes until the
target PineNote edition, partition labels, rescue path, and explicit operator
approval are documented outside this plan.

The target outcome is:

```text
x86_64 build machine
  -> Guix custom channel
  -> cross-built aarch64-linux-gnu PineNote image
  -> bootable on PineNote
  -> Shepherd starts a direct DRM/EBC render test
  -> no Wayland, no wlroots, no MuPDF, no Waydroid yet
```

## Non-goals for this first bring-up image

Explicitly do **not** include yet:

- Wayland
- wlroots
- WinkShell/Sway runtime
- MuPDF
- Waydroid
- GUI browser
- Guile book/marginalia layer
- on-device package management
- Guix daemon in the daily/minimal image
- A/B update machinery, except perhaps partition awareness

The first image should be boring and small: kernel, init, firmware, EBC test program, diagnostics.

## Reference systems to study

### PNDeb / Debian PineNote image

Use PNDeb as the main board-support reference. It already encodes several PineNote-specific lessons:

- Debian image build pipeline using `debos` YAML stages.
- First-boot extraction of waveform data from the `waveform` partition into `/usr/lib/firmware/rockchip/ebc.wbf`.
- Kernel and patch choices.
- U-Boot/extlinux boot assumptions.
- Partition-layout expectations.
- EBC sysfs/module tuning values.
- GNOME e-ink helper behavior.

Useful PNDeb files/repos to mirror conceptually:

```text
PNDeb/pinenote-debian-image
  01_rootminfs.yaml
  02_waveforms.yaml
  03_basic_system.yaml
  04_fix_root_partition.yaml
  06_finalsetup.yaml
  12_create_disc_image.yaml
  13_extract_partition_image.yaml
  scripts/
  partition_tables/
  uboot_env/
```

We should not copy the Debian build method, but we should treat it as the practical reference for what must happen on real hardware.

### PineNote kernel references

Start with Guix's current `linux-libre` source and carry the PineNote downstream display/pen support as explicit local patches:

```text
Guix linux-libre source + pinenote/patches/linux-pinenote-7.0-forward-port.patch
```

Keep m-weigand's and hrdl's kernel trees as reference sources for forward-porting and later experiments because they contain downstream EBC and responsiveness/per-pixel scheduling ideas.

### WinkShell reference

WinkShell is not part of the minimal no-Wayland image. However, keep it as a reference for later e-ink Wayland/shell behavior:

- Sway/wlroots configuration choices.
- EPD-oriented UI compromises.
- Gesture handling.
- Launcher/menu behavior.
- Contrast/focus conventions.
- PineNote touch/pen pain points.

For Phase 1A, we only read it. We do not package it yet.

## Preservation and safety checklist

Before flashing anything custom, preserve all PineNote-specific calibration and boot data.

### Must record by hand

On the factory Debian system, read and write down the VCOM voltage:

```sh
cat /sys/module/tps65185_regulator/drivers/i2c\:tps65185/3-0068/regulator/regulator.29/microvolts
```

Store it in at least three places:

```text
paper note
laptop backup
project secrets/notes directory
```

Reason: the Debian/PineNote docs warn that each EBC panel has an individual VCOM bias voltage and that overwriting bootloader-related data could make this relevant later.

### Must back up before experimenting

Use `rkdeveloptool list-partitions` and back up at least:

```text
uboot
trust
waveform
dtbo
vbmeta
boot
recovery
logo
device
partition table / beginning of disk if possible
```

The absolute minimum unique critical items are:

```text
waveform partition
VCOM value
U-Boot / boot assets
partition table / unpartitioned beginning of disk
possible MAC/device identity data
```

The waveform partition is only about 2 MB, but it contains data controlling E Ink transitions and is device-specific enough that it should be treated as precious.

### Do not overwrite these in early experiments

Early Guix images should not touch:

```text
waveform
uboot
trust
dtbo
vbmeta
super
factory Android partitions
factory Debian os1, if using Community Edition layout
```

Prefer booting from or flashing into the experimental OS slot if available.

### Use OS2 / experimental partition first

On Community Edition-style partitioning, the Debian handbook describes two OS partitions, `os1` and `os2`, each around 15 GB, with the default install on `os1` and `os2` available for experiments. Use `os2` first.

Target early layout:

```text
os1       factory/community Debian rescue system
os2       Guix minimal bring-up image
state     existing data/user partition or a small test state partition
waveform  untouched
uboot     untouched initially
```

### Keep a rescue path

Before changing boot order, verify at least one of:

```text
UART console works
rkdeveloptool/Maskrom path works
factory Debian still boots
U-Boot menu can boot os1 manually
```

For the first few runs, prefer manual U-Boot boot commands over permanent boot changes.

## Build strategy

### Use Guix System + Shepherd

Use Guix System as the image definition layer and Shepherd as PID 1.

This is now coherent with the later Guile plan:

```text
Guix/Scheme:
  image definition
  services
  Shepherd init

Rust or C:
  EBC/direct-render test
  later raster engine
```

Daily/minimal image policy:

```text
include Shepherd
include Guile runtime required by Shepherd
exclude guix-daemon
exclude on-device package management
exclude compilers/debug tooling unless building a dev image
```

### Cross-build target

Primary target:

```text
aarch64-linux-gnu
```

Use true Guix cross-compilation rather than QEMU-native builds as the default:

```sh
guix system image \
  -L . \
  --target=aarch64-linux-gnu \
  --image-type=pinenote-raw \
  pinenote-minimal.scm
```

If the custom image type embeds the target, the command may later simplify, but keep the target explicit at first.

### Host-native vs target-built artifacts

Host-native tools run on the x86_64 build machine:

```text
mkfs/ext4 tools
partition image tools
squashfs tools, if used
manifest generation
signing/compression
```

Target/aarch64 outputs go into the PineNote image:

```text
kernel Image
DTBs
kernel modules
Shepherd/Guile runtime
EBC test program
libdrm or direct ioctl dependencies
firmware/waveform copy or extraction logic
```

### Cross-compilation dependency discipline

In Guix package definitions:

```scheme
(native-inputs ...)
```

are build-machine tools such as:

```text
pkg-config
meson/ninja/cmake
bison/flex
python used by build scripts
clang/bindgen helper tools
protoc if it runs during build
```

```scheme
(inputs ...)
```

are target libraries that end up in the aarch64 output, such as:

```text
libdrm
zlib
freetype later
harfbuzz later
mupdf later
```

Keep this strict from day one.

### Rust vs C fallback

For the first rendering test, Rust is desirable but not mandatory.

Recommended order:

1. Try a small Rust workspace with vendored dependencies and no large crates.
2. If Rust-on-Guix cross-compilation becomes friction, write `pinenote-ebc-test` in C first.
3. Keep the test program's API/data structures compatible with the later Rust raster engine.

Initial Rust dependency rule:

```text
no async stack
no GUI crates
no bindgen if avoidable
no network/TLS stack
no large proc-macro ecosystem
no nightly
```

A tiny C program using `libdrm` may be the fastest hardware proof.

## Guix repository layout

Create a private channel:

```text
pinenote-guix/
├── channels.scm
├── pinenote/
│   ├── packages/
│   │   ├── kernel.scm
│   │   ├── firmware.scm
│   │   ├── boot.scm
│   │   ├── ebc-test.scm
│   │   ├── rust.scm
│   │   └── system-tools.scm
│   ├── services/
│   │   ├── ebc.scm
│   │   ├── diagnostics.scm
│   │   └── state.scm
│   ├── systems/
│   │   ├── pinenote-minimal.scm
│   │   └── pinenote-dev.scm
│   └── images/
│       ├── pinenote-image-type.scm
│       ├── pinenote-partitions.scm
│       └── pinenote-initramfs.scm
└── README.md
```

## Packages to define first

### `linux-pinenote`

Source:

```text
Guix linux-libre source + pinenote/patches/linux-pinenote-7.0-forward-port.patch
```

Guix package state:

- `linux-pinenote` inherits the current Guix `linux-libre`,
- the package appends the repo-local PineNote forward-port patch to the inherited source patches,
- its configure phase runs the carried `pinenote_defconfig` directly,
- Guix's standard kernel phases own the full build and install of the kernel
  image, modules, and DTBs.

Full realization should produce uncompressed `arch/arm64/boot/Image`, modules,
and DTBs including `rk3566-pinenote-v1.2.dtb`; derivation computation is the
safe gate before attempting that full build.

Watch out: older PineNote U-Boot may not support `Image.gz`; use uncompressed `Image` initially.

### `pinenote-firmware`

Contains or installs:

```text
waveform extraction script
runtime waveform source from device partition or local state only
Wi-Fi/BT firmware if needed later
firmware install paths expected by kernel
```

Do not redistribute private waveform/font/APK/firmware blobs accidentally.

Waveform policy:

```text
minimal image first boot:
  if /dev/disk/by-partlabel/waveform exists:
    copy/extract to /lib/firmware/rockchip/ebc.wbf
  else if /state/firmware/ebc.wbf exists:
    use that
  else:
    fail visibly and do not try to drive the panel
```

Mirror the Debian behavior conceptually: extract waveform from `/dev/disk/by-partlabel/waveform` and place it where `rockchip_ebc` expects it.

### `pinenote-ebc-test`

First hardware test program. It should work without Wayland.

Minimum responsibilities:

```text
open DRM device
find EBC connector/CRTC/plane if exposed
create/map dumb buffer or use driver-supported path
fill Y4/Gray4 patterns
optionally generate Gray8 internally and quantize to Y4
submit full-screen update
submit partial rectangle update
switch waveform via sysfs parameter or ioctl path
log timing and errors
```

Initial test screens:

```text
white screen
black screen
16-step grayscale ramp
4-step grayscale ramp
1-bit checkerboard
large serif-like text bitmap or built-in test glyphs
partial rectangle movement
A2 live-stroke simulation
DU4 -> GC16 staged update test
```

If direct DRM modesetting is too opaque initially, a simpler first test can write sysfs parameters and use existing framebuffer/DRM behavior, but the goal is a direct EBC-facing test harness.

### `pinenote-diagnostics`

A small shell/Rust/C diagnostics tool:

```text
print kernel version
print mounted partitions
print VCOM path if available
print EBC sysfs parameters
print DRM devices/connectors/properties
print input devices
print firmware/waveform status
print memory usage
```

## Minimal Guix System definition

`pinenote-minimal.scm` should define:

```scheme
(operating-system
  (host-name "pinenote-guix")
  (timezone "America/Denver")
  (locale "en_US.utf8")
  (kernel linux-pinenote)
  (initrd pinenote-initrd)
  (firmware (list pinenote-firmware))
  (bootloader ...)
  (file-systems ...)
  (users ...)
  (packages
    (list
      pinenote-ebc-test
      pinenote-diagnostics
      kmod
      util-linux
      bash-minimal
      coreutils))
  (services
    (list
      ;; enough device management to load modules and expose /dev
      ;; serial/getty or emergency console
      ;; pinenote waveform extraction/firmware service
      ;; pinenote EBC test Shepherd service
      )))
```

Do not start from a full desktop service set. Use a minimal service list and add only what is needed.

Dev image may include:

```text
sshd
guix-daemon, temporarily
strace
gdb
drm_info
busybox/static rescue tools
```

Daily/minimal image should not.

## Shepherd service graph

Initial services:

```text
root file systems mounted
/dev populated
kernel modules loaded
waveform extracted/installed
EBC sysfs defaults applied
pinenote-ebc-test runs
serial/getty available
```

Conceptual services:

```scheme
pinenote-waveform-service
  requires: file-systems, udev/devices
  action: copy waveform partition to /lib/firmware/rockchip/ebc.wbf if absent

pinenote-ebc-params-service
  requires: kernel-modules
  action: write known-safe defaults to /sys/module/rockchip_ebc/parameters

pinenote-ebc-test-service
  requires: pinenote-waveform-service, pinenote-ebc-params-service
  action: run pinenote-ebc-test once or keep diagnostic UI alive
```

Do not run pen/render hot paths through Shepherd. Shepherd starts services; rendering code owns rendering.

## EBC defaults to test

Use PNDeb/kernel docs as the starting reference. Initial safe config candidates:

For m-weigand-style kernel:

```text
rockchip_ebc direct_mode=0
rockchip_ebc auto_refresh=1
rockchip_ebc refresh_threshold=60
rockchip_ebc split_area_limit=0 initially, then tune
rockchip_ebc panel_reflection=1 or as needed
rockchip_ebc prepare_prev_before_a2=0 initially
rockchip_ebc dclk_select=0 initially
```

The exact defaults should be recorded per kernel version. The minimal image should dump current values on boot.

Waveform IDs to test:

```text
1: A2      fast black/white
3: DU4     4-level grayscale
4: GC16    high-quality 16-level grayscale
5: GCC16   less-flashy 16-level grayscale
6: GL16    less-flashy 16-level grayscale
7/8: GLR16/GLD16 anti-ghosting variants
```

Rendering tests should be organized around intent:

```text
final text:        GC16/GL16
temporary UI:      DU4
live pen/motion:   A2
cleanup:           GC16/GLR16/GLD16 as available
```

## Boot approach

### First boot method

Prefer manual U-Boot boot or bootmenu entry pointing at the experimental partition.

Example shape, adapted to the actual partition labels:

```text
load mmc 0:<bootpart> ${kernel_addr_r} boot/Image
load mmc 0:<bootpart> ${fdt_addr_r} boot/rk3566-pinenote.dtb
setenv bootargs ignore_loglevel root=LABEL=guix-test rootwait
booti ${kernel_addr_r} - ${fdt_addr_r}
```

Do not permanently change boot order until the image has booted multiple times and os1 rescue remains accessible.

### Image format

First artifact can be an ext4 rootfs image for an existing OS partition:

```text
pinenote-guix-minimal.ext4
```

Later artifact can be a raw disk image or A/B rootfs set:

```text
pinenote-guix-minimal.raw
rootfs_A.ext4
rootfs_B.ext4
state.ext4
```

For first hardware tests, use the least destructive image that can boot.

## Cross-build milestone commands

### Build one tiny package

```sh
guix build -L . pinenote-ebc-test \
  --target=aarch64-linux-gnu
```

### Compute kernel package derivation

```sh
guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
  --target=aarch64-linux-gnu
```

### Build minimal system image

```sh
guix system image -L . \
  --target=aarch64-linux-gnu \
  --image-type=pinenote-raw \
  pinenote/systems/pinenote-minimal.scm
```

If cross image generation hits Guix bugs, try in order:

```text
1. simplify service list
2. remove tests/checks for problematic package
3. use --no-grafts for the image build if needed
4. patch package native-inputs/inputs split
5. temporarily use QEMU/binfmt for a single stubborn package
6. replace that package or write a smaller custom tool
```

## Rendering subsystem work enabled by this image

Once the minimal image boots, start rendering work without Wayland.

### Test program stages

#### Stage 1: panel sanity

```text
white full-screen
black full-screen
16-gray ramp
force global refresh
```

#### Stage 2: partial updates

```text
moving rectangle
small dirty rects
overlapping dirty rects
split_area_limit behavior
update timing log
```

#### Stage 3: waveform behavior

```text
same frame in GC16
same frame in DU4
DU4 approximate frame then GC16 final frame
A2 live line simulation then GC16 cleanup
```

#### Stage 4: typography test bitmap

No FreeType needed yet. Use built-in bitmap glyphs or precomputed test images.

Test:

```text
1-bit text rendered with quality waveform
4-gray text with DU4
Gray8->Y4 antialiased text with GC16
small punctuation / code-like characters
italic-ish diagonals
rounded annotation boxes
```

#### Stage 5: first raster library

Implement:

```text
Gray8 buffer
Alpha8 mask
Y4 output buffer
quantize Gray8 -> 16-level Y4
quantize Gray8 -> 4-tone Y4
threshold Gray8 -> 1-bit Y4 values 0/15
rect copy/fill
simple composition
```

This becomes the basis for the later Rust raster engine.

## What to borrow from PNDeb now

Borrow immediately:

- kernel branch/version choice,
- waveform extraction behavior,
- `/lib/firmware/rockchip/ebc.wbf` path,
- EBC sysfs/module parameter knowledge,
- partition/bootloader cautions,
- U-Boot/extlinux/root partition handling,
- VCOM warning,
- os1/os2 experimental workflow.

Do not borrow yet:

- GNOME,
- apt repository/update model,
- desktop stack,
- patched Mutter,
- Xournal++ workflow,
- Firefox/browser support.

## What to borrow from WinkShell later

Borrow later when Wayland begins:

- e-ink-friendly Sway/wlroots shell conventions,
- high-contrast focus/selection ideas,
- gesture architecture lessons,
- launcher/menu composition ideas,
- what did not work well with touch/pen arbitration.

Do not bring WinkShell into Phase 1A. Phase 1A should be lower-level: direct EBC rendering first.

## Risk register

### Risk: overwriting unique panel data

Mitigation:

- backup waveform partition,
- record VCOM,
- do not overwrite waveform/uboot/trust/GPT area,
- use os2/experimental partition,
- preserve Debian rescue.

### Risk: Guix cross-build breakage

Mitigation:

- keep dependency graph minimal,
- start with C if Rust is friction,
- avoid Wayland/MuPDF until EBC proof works,
- use target `aarch64-linux-gnu`,
- keep `native-inputs`/`inputs` strict,
- use QEMU only as fallback.

### Risk: kernel/EBC mismatch

Mitigation:

- start from PNDeb's known kernel branch,
- package exact version,
- record module parameters,
- keep a diagnostic dump in every boot log.

### Risk: image boots but screen does not update

Mitigation:

- UART/getty rescue,
- serial logs,
- hard reset procedure known,
- Debian os1 rescue path,
- EBC test can be run manually from shell.

### Risk: waveform path missing

Mitigation:

- fail early and visibly,
- log partition detection,
- support `/state/firmware/ebc.wbf`,
- never silently drive panel without expected waveform.

## Concrete next steps

The commands in this section are reference material. Treat every hardware-facing
command as quarantined until the Safety Scope conditions above are satisfied.

### Step 0: collect references locally

Clone or bookmark:

```sh
git clone https://github.com/PNDeb/pinenote-debian-image
git clone https://github.com/m-weigand/linux
# Use as reference only; forward-port into pinenote/patches/ against Guix linux-libre.
git clone https://github.com/hmpthcs/WinkShell
```

Also save relevant Pine64 and PNDeb handbook pages.

### Step 1: preserve device-specific state

On factory Debian:

```sh
cat /sys/module/tps65185_regulator/drivers/i2c\:tps65185/3-0068/regulator/regulator.29/microvolts
```

From host with `rkdeveloptool`:

```sh
rkdeveloptool list-partitions
rkdeveloptool read-partition waveform waveform_backup.img
rkdeveloptool read-partition uboot uboot_backup.img
rkdeveloptool read-partition trust trust_backup.img
rkdeveloptool read-partition dtbo dtbo_backup.img
rkdeveloptool read-partition boot boot_backup.img
```

Expand backup set as desired.

### Step 2: create `pinenote-guix` channel

Create packages for:

```text
linux-pinenote
pinenote-firmware
pinenote-ebc-test
```

Do not create the full reader stack yet.

### Step 3: cross-build tiny EBC test

First in C or tiny Rust:

```sh
guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu
```

### Step 4: compute kernel derivation, then cross-build deliberately

```sh
guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' --target=aarch64-linux-gnu
```

Only after the derivation gate succeeds and a full kernel realization is
intentionally started, verify the realized output contains:

```text
Image
rk3566-pinenote-v1.2.dtb
modules
```

### Step 5: build minimal Shepherd image

Services:

```text
mount file systems
populate /dev
extract waveform
set EBC params
run diagnostics
run EBC test
start emergency getty
```

### Step 6: boot manually into os2

Do not change default boot permanently yet.

Use U-Boot manual boot or temporary bootmenu entry.

### Step 7: run rendering matrix

Record photos/videos and logs for:

```text
GC16 text/ramp
DU4 ramp
A2 line simulation
partial rect behavior
DU4->GC16 staged update
BW mode threshold behavior
```

### Step 8: decide Rust vs C for raster foundation

If Rust cross-build is painless, continue Rust.

If Rust blocks progress, keep hardware-test code in C and move the higher-level raster model into Rust later.

## Exit criteria for Phase 1A

Phase 1A is complete when:

```text
Guix can build the image from x86_64.
Temporary manual boot reaches userspace on PineNote without destroying factory
calibration data or mutating persistent bootloader state.
Shepherd starts.
Waveform file is installed or detected.
EBC test can draw full-screen and partial updates.
A2, DU4, and GC16 behavior has been characterized.
A minimal Gray8/Alpha8/Y4 raster path exists.
Debian os1 or another rescue path remains available.
```

After this, begin Phase 1B:

```text
FreeType/HarfBuzz text rendering tests
real raster layer cache
damage/refresh scheduler
then Wayland/wlroots/WinkShell-informed shell work
```

## Reference links

- PNDeb PineNote Debian image: https://github.com/PNDeb/pinenote-debian-image
- PNDeb handbook: https://pndeb.github.io/pinenote-handbook/user_guide/
- PNDeb getting started: https://pndeb.github.io/pinenote-tweaks/getting_started/
- Pine64 PineNote development: https://pine64.org/documentation/PineNote/Development/
- Pine64 PineNote kernel build: https://pine64.org/documentation/PineNote/Development/Building_kernel/
- Pine64 flashing/backup: https://wiki.pine64.org/wiki/PineNote_Development/Flashing
- WinkShell: https://github.com/hmpthcs/WinkShell
- Guix System image API: https://cs.petrsu.ru/~kryshen/guix/cookbook/en/Guix-System-Image-API.html
- Guix package reference: https://guix-home.trop.in/package-Reference.html
