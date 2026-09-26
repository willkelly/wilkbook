# September 26 parallel implementation batch

Baseline: `1f36e77` (generation 23's operator cold-boot record). Integration
branch: `batch/integration`. Seven independent workers used separate worktrees;
the parent integrated their commits and shared entrypoints. This is an offline
engineering record, not a new hardware-status entry.

## Delivered scope

| Task | Result | Remaining boundary |
| --- | --- | --- |
| Update teardown | Stop the optional note authority, require runtime cleanup and root/data read-only remounts, preserve prior state on refusal; executable failure-path tests | Updated QEMU systems and real filesystem/Shepherd/device qualification |
| Notebook | Persistent panel-contact ownership, one-pass inverted framebuffer paint, hover-aware washer hold, deferred page charges, acknowledged Refresh debt receipts, richer pen-up logs | Panel behavior and backlog cause |
| Platform broker | Validated RGB565/XRGB8888 fallback rendering; MONOTONIC deadlines/evdev, BOOTTIME suspend duration; cancel RTC alarm on deep-mode refusal | Physical fallback appearance, evdev clock selection and ultra-suspend accounting; RTC writer serialization remains open |
| Settings | Guile coupling audit, mutation checks and real Lua configuration parser fixtures; proposed durable enumerable API | General settings backend/schema migration/UI remain proposed |
| Manuals | Installed-profile census plus real native KOReader rendering, TOC/link/Back navigation and negative controls | 49 recorded corpus omissions; command-example display hyphens; device check |
| Refresh diagnostics | Full-log transport validated by length/hash; checked analyzers; context and clock uncertainty explicit | New end-to-end QEMU campaign and future field evidence |
| Workbench device | Guile coordinator composition plan and owner-receipt gate | Coordinator/service implementation and qualification; no device launcher yet |

Python remains available. New system/build scripts in this batch use Guile;
KOReader work uses Lua. Focused fixes to existing Lua/shell/Python code preserve
their interfaces without combining them with unrelated migrations.

## Offline evidence

Worker checks were reused where sources and inputs were unchanged. Parent
integration also ran:

- `update-path-check`: 203 executable trial assertions, ledger and structural
  checks. The worker additionally passed `reader-stop-check`, `uart-pick-check`
  and the existing authority control-structure test.
- `platform-controls-check`, including byte-exact framebuffer, clock-step and
  deep-suspend refusal tests; `timesync-check`.
- `settings-check`: shipping defaults/debt inventory, 303 mutation/extraction
  checks and 52 Lua broker-parser checks.
- `koreader-input-check` with native bundle
  `/gnu/store/11jrzxbvx4cn4m4ryhllr5a1w93zr1a0-koreader-bin-2026.03`.
  The integrated device seam tests execute the actual global-refresh and
  full-refresh closures for missing fd, failed ioctl and successful ioctl.
- `refresh-episodes-check`, `refresh-trigger-check`, `refresh-capture-check`
  (22 capture/report checks). The field corpus still has 764 traces,
  412 full-panel partials, five episodes and four menu hits.
- `book-workbench-device-check`: 88 receipt-ordering assertions.
- `pinenote/tools/book-state-device/run-tests.sh`: source, authority lifecycle,
  service composition and real native reader checks.
- Source-capsule export and preparation from a fresh explicit candidate, with
  hashes updated for the changed KOReader files and root Makefile.

The manuals worker passed both `manuals-check` and installed/native acceptance.
Replay identities, corpus exceptions, assertion output and representative
screenshots are committed under `pinenote/tools/manuals/evidence/2026-09-26/`.

The ambient derivation check refused kernel 7.1.13 as intended. Repeating with
`guix time-machine -C channels.scm -- repl -L .
pinenote/tools/book-state-device/derive-system.scm` passed the exact kernel
`334ljs8q` and gVisor `djgy782a` pins and lowered
`/gnu/store/y43fbj5x91p7h2fkzbwld0jv0b00rqqh-system.drv` at the integrated source.
This is derivation evidence, not a realized system or closure check.

QEMU update-flow was not rerun: cached system inputs contain older helpers and
the harness correctly requires both generations to match the current helper.
New matching A/B inputs must be built first. No device was contacted, deployed
or rebooted for this batch.

## Review

Three independent adversarial reviewers examine project fit, exhaustive logic
and performance. The first-slice review found no new blockers and produced two
corrections: narrower language-policy wording, and an executable fix for the
pre-existing RTC alarm left armed when deep suspend is unavailable. Parent
review also required terminal socket EOF before Workbench preview eligibility.
The final project-fit review confirmed the scope and evidence boundaries. It
found a stale root Makefile hash (caught and fixed by parent capsule preparation
too), a hardcoded test temporary-directory parent (changed to honor `TMPDIR`),
and two stale statements (updated). The final performance/clarity review found
no blockers. It confirmed that night-mode conversion is repaint-only (about
5 MiB temporary storage for a full RGB565 page), washer holds park rather than
poll, and neither broker nor teardown adds steady-state polling. These are
source/host-test conclusions, not measured ARM performance. Final logic review
is recorded below when complete.

## Next acceptance sequence

1. Realize/check the candidate system closure using the pinned channel. Build
   matching QEMU A/B inputs and exercise update-flow success and refusal; run
   the full-log page-turn campaign against matching inputs.
2. In an authorized attended generation session, verify the authority releases
   its SQLite/runtime resources and a failed data remount refuses handoff with
   prior services restored. Use the target helper's identity; older rollback
   targets retain the manual-stop requirement. Preserve the retained fallback.
3. On the panel: panel-owned contact/dropout tails, night-mode full repaint and
   panel Close in both rotations, hover longer than the idle-wash threshold,
   page buttons near the debt ceiling, successful Refresh followed by new ink,
   close/reopen, KOReader restart and suspend/resume. Log brush/size/span/backlog
   observations; ioctl acceptance alone does not prove wash completion.
4. Exercise broker acknowledged and fallback suspend, RGB565 banner clipping
   and cleanup, power/cover inputs, RTC wake/settle, and BOOTTIME accounting.
   Active RTC writes still require separate race coordination; monotonic timers
   do not solve that race.
5. Open representative man and Info pages, use TOC/link/Back on the tablet and
   inspect long examples. Record omissions and typography separately from
   navigation success.

Workbench W1 (the Guile authority-channel slice) and the durable settings
backend are subsequent implementation tasks, not part of panel acceptance for
this batch. Cover electrical measurements remain deferred until tied to a
specific wake-control or suspend change.
