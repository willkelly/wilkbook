# PineNote platform-controls tests

This directory contains the offline tests for the production suspend broker,
protocol, Wi-Fi helper, KOReader integration, and Shepherd wiring. The packaged
sources live in `pinenote/packages/platform-controls/`.

Run the suite from the repository root:

```sh
make platform-controls-check
```

`test-banner.lua` executes the production broker's renderer and fallback
transaction with only the OS boundaries replaced. It checks every byte of
RGB565 and XRGB8888 framebuffers, including padded strides, visible offsets,
clipped screens and untouched margins/guards; rejects malformed geometry and
unsupported layouts; and injects open/ioctl/write/sync/close failures. Short
writes and EINTR are retried. A failed banner remains best-effort: it logs the
failure and the normal suspend transaction still runs.

The renderer queries both fbdev info ioctls through the descriptor it writes,
accepts little-endian packed truecolor RGB565/XRGB8888 only, and writes at most
96 visible rows. The 16384-pixel virtual-dimension cap bounds allocations and
geometry arithmetic. Display-mode changes by another process during rendering
are not serialized; the broker does not own modesetting. Hardware still owes a
missed-acknowledgement fallback on the direct driver's RGB565 framebuffer and
the retained banner's appearance and cleanup after wake.

The retired Phase 1 runtime-overlay record is preserved under
`doc/artifacts/pinenote-platform-controls-v1-20260831/`.
