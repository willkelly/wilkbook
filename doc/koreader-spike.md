# KOReader packaging spike (2026-07-04)

Question (ROADMAP track 4, priority raised 2026-07-04 because an
external user wants to run it): what is the cheapest sound way to get
KOReader running on wilkbook, and what does the device integration
actually require?

**Headline: package the upstream release binary (`koreader-bin`,
done — `pinenote/packages/koreader.scm`), run it under a `cage`
Wayland kiosk on the device (also done offline: `cage-pixman` +
`reader-session` service + the `reader` flavor, all cross-built; the
exact compositor+client pairing validated end-to-end on the
workstation). A from-source Guix build is a real project (~30 vendored
third-party deps behind a network-fetching build system) and stays
future work.**

## 1. What upstream ships

`v2026.03` release assets include generic Linux builds:
`koreader-linux-{x86_64,arm64}-v2026.03.tar.xz` (~27 MB), plus
arm64 `.deb`s and AppImages built from the same target. Inspection of
the arm64 tarball:

- Layout: `bin/koreader` (symlink → `../lib/koreader/koreader.sh`,
  which `cd`s to its own directory and loops `./reader.lua`), payload
  in `lib/koreader/` with bundled **luajit**, **SDL3**, mupdf/crengine/
  k2pdfopt/djvu/webp/harfbuzz/ssl/... and fonts. Only two ELF
  *executables*: `luajit` and `sdcv`.
- Every bundled object carries classic `DT_RPATH`
  `$ORIGIN:$ORIGIN/libs` — the bundle resolves itself; external needs
  are just glibc (interpreter `/lib/ld-linux-aarch64.so.1`, `libm`,
  `libgcc_s`) plus whatever SDL3 `dlopen`s.
- The bundled SDL3's video backends are **wayland, offscreen, dummy —
  no kmsdrm, no x11**. So: a Wayland compositor is required on the
  device; headless/offscreen works anywhere (that is how the smoke
  test below runs). SDL3 dlopens `libwayland-client/-cursor`,
  `libxkbcommon`, `libdecor` (and optionally dbus/udev/GL, all with
  graceful fallbacks — KOReader renders in software, so no GL needed).

## 2. The package (`koreader-bin`)

`pinenote/packages/koreader.scm`, `gnu-build-system` (configure/build
deleted) + `patchelf` — deliberately *not* dependent on nonguix beyond
what the channel already uses:

- per-arch tarball: `arm64` for aarch64, `x86_64` for the workstation,
  selected via `%current-target-system` — the same package definition
  is testable offline and cross-buildable for the device. Two Guix
  gotchas cost real debugging time and are worth remembering:
  - a package's `source` field is evaluated at module load, *not* at
    build time, so it cannot dispatch on the target. The tarball is a
    labeled entry in the (thunked) `inputs` field instead, and
    `source` is `#f`.
  - `copy-build-system` cannot cross-compile at all — its `lower`
    drops `#:target`, so `--target=aarch64-linux-gnu` silently
    produced an ARM payload patched against x86_64 glibc. Hence
    `gnu-build-system` with the irrelevant phases deleted. Always
    inspect a cross-built artifact (`file`, `readelf -d`) — the broken
    build *succeeded*.
  - toolchain pieces must not be regular `inputs` under `--target`:
    listing `glibc` (or `cross-gcc`) there makes Guix *cross-compile
    the toolchain itself* — a Canadian cross that fails (gcc dies in
    fixincludes, glibc in configure). They go in `native-inputs`,
    dispatched on `%current-target-system` to `cross-libc`/`cross-gcc`
    — whose payload is target-arch and is exactly what every
    cross-built package in the image links against.
  - the bundle's C++ engines (crengine, k2pdfopt) need
    `libstdc++.so.6`/`libgcc_s.so.1`, which upstream doesn't ship;
    they are copied out of the toolchain into the bundle's `libs/`
    (GCC runtime-library exception) rather than rpath'ing a gcc
    package into the closure.
- `patchelf --set-interpreter` on `luajit` and `sdcv`;
- `--force-rpath --set-rpath '$ORIGIN:$ORIGIN/libs:<deps>'` on the
  executables and on `libSDL3.so.0` (classic RPATH on purpose: the
  bundle's dlopened Lua C modules inherit the executable's `DT_RPATH`,
  and upstream already relies on that);
- runtime inputs: `glibc`, `gcc:lib`, `wayland`, `libxkbcommon`. No
  `libdecor` — it fails to cross-build (a `pyproject` dep) and SDL3
  only dlopens it for client-side window decorations, which a
  fullscreen kiosk never shows;
- `#:validate-runpath? #f` because `$ORIGIN` and bundled sonames are
  load-bearing; `#:strip-binaries? #f`; `#:substitutable? #f` (27 MB
  binary repack; upstream is the canonical source).

**Validation so far (offline):**

- x86_64 build + headless smoke test: `SDL_VIDEODRIVER=offscreen
  bin/koreader` boots the entire frontend — FFI loads every bundled
  lib through the patched paths, SDL3 initializes on the offscreen
  backend, fonts/plugins/settings/gesture defaults come up, and it
  sits in the UI event loop until killed. That exercises exactly the
  patchelf surface the device build uses.
- aarch64 cross-build: same recipe, `--target=aarch64-linux-gnu`
  (patchelf edits foreign ELFs fine; the interpreter comes from
  `cross-libc` — the same glibc every cross-built package in the image
  links). Verified by inspection (`file`, `readelf -d`) *and* by
  execution: the patched `luajit` runs under `qemu-aarch64` user
  emulation and prints its banner, so the interpreter/RPATH chain is
  known-good on the target architecture.

The offscreen backend is also a gift for the test ladder: KOReader can
run fully headless on CI/workstation, which pairs naturally with
rung 5 (vkms/screenshot validation) later.

## 3. The kiosk stack (built same day)

**Compositor.** `cage`, but not the stock package: stock cage pulls
`wlroots`, which propagates **mesa — and mesa does not cross-compile**
(meson configure dies immediately under `--target`). The fix is
principled, not a workaround: the PineNote has no GPU path worth
having — the kiosk runs wlroots' *pixman* renderer on DRM dumb
buffers, needing neither EGL nor GBM. `pinenote/packages/kiosk.scm`
defines `wlroots-pixman` (renderers/Xwayland/x11-backend disabled,
mesa/vulkan/xcb dropped, `libdrm` added back — it used to arrive
transitively via mesa) and `cage-pixman` against it. Both cross-build.

**Service and flavor.** `pinenote/services/reader-session.scm` runs
`cage-pixman -- koreader` as a respawning Shepherd service (root +
`LIBSEAT_BACKEND=builtin` for v1: no seatd, no seat-group plumbing;
hardening is follow-up), after udev/waveform/EBC-params, with a
bounded wait for `/dev/dri/card0`. `pinenote/systems/pinenote-reader.scm`
is the usb-console flavor plus that service (`make reader` /
`make rootfs-reader`); the gadget console stays as the escape hatch.

**Offline validation of the exact stack:**

- the full reader *system closure* cross-builds;
- `cage-pixman` nested in a real Wayland session running KOReader:
  works end to end, no crashes — this is the same compositor binary +
  client pairing the device boots;
- KOReader alone against a desktop compositor: works;
- **known offline-only failure, isolated:** under a *headless* wlroots
  backend (cage or sway alike), KOReader's SDL3 segfaults in
  `wl_proxy_get_version` right after the initial roundtrip. Protocol
  traces show the headless seat advertises `capabilities(0)` — no
  input devices — and SDL3's seat handling dereferences a
  never-created input proxy. On the device libinput always finds the
  cyttsp5 touchscreen and WS8100 pen, so the zero-capability path
  cannot occur; a real DRM output (with a real refresh rate, another
  headless artifact) is also present. Verify at first light, but this
  is a test-environment artifact, not a device risk.

## 4. Remaining device integration

1. **Input mapping**: pen/touch via libinput inside wlroots; KOReader
   sees SDL pointer events. Upstream gap #14694 (stylus tagged as
   finger) applies when we get there.
2. **Refresh policy**: initially every SDL present = full-plane damage
   = GC16-class partial refresh of the whole screen — usable but
   suboptimal. The improvement path is upstream #14017 (route
   Dispatcher full-refresh to `DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH`)
   plus the `org.pinenote.ebc` dbus service for mode control
   (`doc/eink-research.md` §5); keep our driver's UAPI compatible so
   the community tooling runs unmodified.
3. **Hardware session goal**: boot the reader flavor, page turn,
   verify refresh behavior and pen/touch — rides along with the
   already-queued cherry-pick validation (`doc/status.md`).

What only hardware can prove: panel optics, e-ink refresh feel, pen
latency — as ever. (qemu-virt can't reach the session either way until
the udev deadlock is fixed.)

## 5. The from-source path (future work, evidence)

KOReader's build (`koreader/koreader-base`) vendors ~30 third-party
projects (luajit, mupdf with its own vendored libs, crengine,
k2pdfopt, …) behind CMake/kodev machinery that fetches at build time —
incompatible with Guix builds without prefetching every component as a
fixed-output origin and patching the superbuild. Debian/Alpine do not
package KOReader from source either (upstream's own binaries are the
de-facto distribution); nixpkgs packages the *release binary* with
autoPatchelfHook, same approach as ours. Revisit if/when we want
reproducibility or PineNote-specific patches (e.g. #14017) compiled
in; until then the binary package plus UAPI compatibility is the
pragmatic reader.
