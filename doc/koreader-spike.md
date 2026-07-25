# KOReader on the PineNote (spike → first light)

Question (ROADMAP track 4, priority raised 2026-07-04 because an
external user wants to run it): what is the cheapest sound way to get
KOReader running on wilkbook, and what does the device integration
actually require?

**Headline (updated after first light, 2026-07-05): KOReader runs
natively on the framebuffer — no compositor, no SDL.** The
`koreader-bin` package repacks the upstream release binary and grafts
in a wilkbook-authored "pinenote" device target (fbdev output, pure-Lua
evdev input, EBC global-refresh ioctl). Validated on hardware: the
quickstart guide renders on the panel, pen taps navigate the UI,
KOReader can be exited from its own menu. The original cage/SDL kiosk
plan was **abandoned for cause** — §3 documents the dead end so nobody
retries it.

## 1. What upstream ships

`v2026.03` release assets include generic Linux builds:
`koreader-linux-{x86_64,arm64}-v2026.03.tar.xz` (~27 MB). Inspection of
the arm64 tarball:

- Layout: `bin/koreader` (symlink → `../lib/koreader/koreader.sh`),
  payload in `lib/koreader/` with bundled **luajit**, **SDL3**,
  mupdf/crengine/k2pdfopt/djvu/webp/harfbuzz/ssl/... and fonts. Only
  two ELF *executables*: `luajit` and `sdcv`.
- Every bundled object carries classic `DT_RPATH`
  `$ORIGIN:$ORIGIN/libs` — the bundle resolves itself; external needs
  are just glibc plus whatever SDL3 `dlopen`s.
- **Not shipped**: `libs/libkoreader-input.so`, the compiled evdev
  input module every e-ink device target uses. Desktop bundles assume
  SDL input. This is the gap the pure-Lua evdev backend fills (§4).
- The bundled SDL3's video backends are **wayland, offscreen, dummy —
  no kmsdrm, no x11**.

## 2. The package (`koreader-bin`)

`pinenote/packages/koreader.scm`, `gnu-build-system` (configure/build
deleted) + `patchelf`. Cross-compilation gotchas that cost real
debugging time (details in the package comments): a package's `source`
field can't dispatch on the target (tarball is a thunked labeled input
instead); `copy-build-system` silently drops `#:target`; toolchain
pieces go in `native-inputs` as `cross-gcc`/`cross-libc`, never plain
`inputs`; and the default `patch-shebangs` phases rewrite
`koreader.sh`'s `#!/bin/sh` to a *build-machine* x86_64 bash under
`--target` — all three shebang phases are deleted (foreign bundle,
leave it alone).

## 3. The dead end: cage/SDL kiosk (do not retry)

The first integration ran KOReader under a `cage` Wayland kiosk
(`wlroots-pixman`/`cage-pixman` in `pinenote/packages/kiosk.scm`,
which still cross-build and stay in the repo for possible future use).
It passed every offline test — nested cage on a workstation runs
KOReader end to end — and failed on hardware in three nested layers,
each diagnosed live over the gadget console on 2026-07-04/05:

1. **fbcon stomping.** The image boots with `console=tty0
   ignore_loglevel`; every kernel message makes fbcon redraw the text
   console, and the DRM fbdev emulation's flushes kept committing over
   the compositor's frames in the EBC driver's buffers (`1872x1392`
   full-frame blits at up to ~8 Hz in the `drm.debug=0x2` trace —
   enabling that flag itself feeds the loop, since its printk lines
   redraw fbcon). The panel showed stale console text while cage and
   KOReader ran "correctly" underneath. Fix: the reader-session
   service unbinds fbcon (`/sys/class/vtconsole/vtcon1/bind`) while
   the reader owns the panel and re-binds it on stop.
2. **SDL3 first-frame deadlock (cosmetic here, fatal elsewhere).**
   SDL3's show/fullscreen dance requests a `wl_surface.frame` callback
   and then commits a nil buffer (unmapping the surface); wlroots
   never fires frame callbacks for unmapped surfaces, so SDL waits
   forever before attaching its first real buffer. Desktop compositors
   are lenient; wlroots-on-DRM is not — which is why every offline
   test passed and the device hung with both threads parked in
   `ppoll`, zero CPU.
3. **The fatal one: SDL3 cannot present on Wayland without a GPU.**
   SDL3 dropped SDL2's wl_shm software framebuffer path; presenting
   requires GL or Vulkan. On the device, opengl/opengles2/vulkan all
   fail (no mesa — it doesn't cross-compile; no libvulkan), and
   KOReader ignores `SDL_CreateRenderer`'s failure and runs blind
   (`SDL_LOGGING=*=debug` shows the renderer cascade failing). The
   workstation validation had silently used desktop mesa via dlopen.
   No compositor choice fixes this; the SDL frontend is structurally
   wrong for a GPU-less Wayland device until SDL grows a software
   present path.

Also observed: SDL 3.4 deprioritizes Wayland when the compositor
lacks the `fifo-v1` protocol (harmless here — no x11 fallback exists
in the bundle).

## 4. The native port (what actually ships)

KOReader's e-ink device targets (Kobo, reMarkable, ...) don't use SDL
at all: fbdev output + evdev input. The desktop bundle contains the
complete fbdev backend (`ffi/framebuffer_linux.lua`, pure Lua+FFI) —
only the compiled input module is missing. So the port is three Lua
files, grafted into the bundle by the package
(`pinenote/packages/koreader-device/`):

- `ffi/input_evdev.lua` — pure-LuaJIT evdev backend implementing the
  `libkoreader-input` contract (`open`/`close`/`closeAll`/
  `waitForEvent` via `poll(2)`, per the spec in
  `frontend/device/input.lua`), plus an `absinfo()` helper (EVIOCGABS)
  for digitizer scaling.
- `frontend/device/pinenote/device.lua` — the device target:
  `framebuffer_linux` on `/dev/fb0` (32bpp XR24, 1872×1404);
  `wacom_protocol = true` input with the pen's absolute axes
  (20966×15725) scaled to the screen (queried at init, not
  hardcoded); `refreshPartialImp` a no-op (the DRM fbdev emulation's
  deferred-io publishes every mmap write as damage on its own — this
  is load-bearing and was verified on hardware with a raw mmap test
  before writing the port); `refreshFullImp` calls
  `DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH` on `/dev/dri/card0`, so page
  turns and UI flashes get a real GC16 wash.
- `frontend/device/pinenote/powerd.lua` — frontlight via the two PWM
  backlights (`/sys/class/backlight/backlight_{cool,warm}`, warmth
  cross-fades between them); battery support targets the RK817 fuel gauge,
  and the DTS-enabled 2026-07-24 boot now exposes the hardware-qualified
  `rk817-battery` supply. Capacity accuracy remains provisional until a
  controlled charge/discharge cycle.

The probe hook (patched into `frontend/device.lua` before the SDL
fallback) matches `PineNote` in `/proc/device-tree/model`.

`pinenote/services/reader-session.scm` runs the bundled `luajit
reader.lua` directly as a respawning Shepherd service (root, v1) after
udev/waveform/EBC-params, unbinding fbcon for the session's duration.

**Hardware status (2026-07-05):** quickstart guide renders, pen taps
and UI navigation work, exit via menu works. Finger touch requires the
cyttsp5 touchscreen — driver was enabled but the mainline DTS carries
no node for it; the forward-port patch now adds one (untested on
hardware as of this writing; see `doc/kernel-forward-port.md`).

## 5. Remaining work

1. **Touchscreen**: validate the new cyttsp5 DTS node; if coordinates
   come out garbage, the mainline driver's missing sysinfo fallbacks
   (m-weigand's tree patches them in) are the first suspect.
2. **Refresh polish**: partial refreshes ride deferred-io defaults;
   tune refresh_threshold / explicit flash policy per KOReader's
   refresh hints (it distinguishes partial/UI/full — the plumbing to
   map more of those onto EBC behavior is in place).
3. **Pen niceties**: hover cursor, pen buttons (ws8100, `event5`),
   pressure curves; upstream gap #14694 (stylus tagged as finger).
4. **Hardening**: unprivileged user, read-only bundle, books dir
   convention (`home_dir` is `/root` for now).
5. **Upstreaming**: the pinenote device target + pure-Lua evdev
   backend are candidates for upstream KOReader once touch and a
   couple of weeks of dogfooding are in.

## 6. The from-source path (future work, evidence)

KOReader's build (`koreader/koreader-base`) vendors ~30 third-party
projects behind CMake/kodev machinery that fetches at build time —
incompatible with Guix builds without prefetching every component as a
fixed-output origin and patching the superbuild. Debian/Alpine do not
package KOReader from source either; nixpkgs packages the *release
binary* with autoPatchelfHook, same approach as ours. Revisit if/when
we want reproducibility or PineNote-specific patches compiled in.
