# Archived documents

These documents are kept for historical reference. They record completed
phases or superseded states of the project and should not be treated as
current instructions.

- `phase1a-bringup-plan.md` — the original Phase 1A design document for the
  minimal bring-up image. The backup, preflight, and first-boot work it plans
  has been completed; its safety quarantine language predates the OS2
  deployment workflow now described in `doc/hardware-deploy.md`.
- `gate6-serial-uboot.md` — U-Boot serial worksheet from before the UART
  console was established. It claims no UART path exists; a CH340 UART at
  1500000 baud is now the primary control surface. Its artifact hashes and
  store paths are dead.
- `gate6-temporary-boot.md` — point-in-time ledger (2026-05-10) of the first
  OS2 write attempts. OS2 has been rewritten many times since; the current
  state lives in `doc/status.md`.
