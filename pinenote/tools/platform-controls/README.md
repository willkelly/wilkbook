# PineNote platform-controls tests

This directory contains the offline tests for the production suspend broker,
protocol, Wi-Fi helper, KOReader integration, and Shepherd wiring. The packaged
sources live in `pinenote/packages/platform-controls/`.

Run the suite from the repository root:

```sh
make platform-controls-check
```

The retired Phase 1 runtime-overlay record is preserved under
`doc/artifacts/pinenote-platform-controls-v1-20260831/`.
