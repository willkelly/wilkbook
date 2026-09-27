# Generation 25 handwriting sampler — wkelly PineNote, 2026-09-26

Source: `0a989eb` on `notebook/background-template`, based on the recognition
export branch (`1ea0e3f`). This does not include the separate data-recovery PR.
Operator requested the update and loading the sampler, then directly invoked
`I invoke the trial!!` in this conversation. No UART.

## Offline qualification

- Full native KOReader input suite passed, including 36 dedicated background
  assertions. The final plugin test adds page-transition, refusal and lifecycle
  checks; it passed after the suite run (no further runtime-source edits).
- `make handwriting-check`: 23 replay/region assertions and eight CLI/XML/source
  preservation assertions passed.
- Native KOReader opened the generated EPUB and rendered exactly five pages;
  all five were nonblank, and the first screenshot was visually inspected.
  XML parsing and ZIP integrity checks passed.
- All five generated notebook backgrounds loaded through the packaged production
  Store and Background modules. A three-pixel grid comparison against each
  portrait EPUB image passed after the mode-1 physical coordinate conversion.
- Pinned native reader build:
  `/gnu/store/650rsnr7cp2736fgpzjgk9nhqjz4389i-koreader-bin-2026.03`.
- Pinned experimental system derivation:
  `/gnu/store/h19zc0wj9sdcss79iswlhxahs0wy4z5i-system.drv`.
- Target system:
  `/gnu/store/yy13ywsn16qa5y6kwbgg1ibhgaxzcxpc-system`.
- `check-system-closure.sh` passed against that exact output, comparing both
  installed notebook plugins with the checkout and checking kernel/gVisor pins.
- Kernel and update-helper Lua sources are unchanged from generation 24;
  recursive comparison of the installed helper source directories passed. The
  wrapper's store paths changed with the KOReader dependency, but its LuaJIT
  executable is byte-identical. Applicable earlier update-path/QEMU proofs are
  reused. Target Image SHA-256 equals both retained
  generations 24 and 23:
  `5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.

## Preparation

Source was generation 24, promoted, boot ID
`7d56208a-02f4-4a1c-9386-ef61cd7d0859`, system
`/gnu/store/13cg7sg6waa3ahj3ivxhmkagia0kbwi1-system`.
Verified root p6, actual writable data p7, source health, 100% battery, DEFAULT
24 and pinned generation 23. Recovery fallback is cold-booted generation 23,
`/gnu/store/x3qqz8r52pdh7jzghzfj8l44gfrqkncb-system`.

The previous `enabled=1` suspend file was backed up byte-for-byte at
`/data/wilkbook/diagnostic-backups/gen24-before-sampler-20260926/autosuspend.conf`,
then suspend was paused with `enabled=0`. A preparation command stopped at
`readlink /boot/gen-default` (that file is regular, not a link); the following
read-only check used `cat`, verified DEFAULT 24, and passed source health.
This was before handoff, not a failed trial.

Installed a new, previously absent notebook directory
`/data/notebooks/20260927T051718Z-d466ff` and EPUB
`/data/books/handwriting-sampler.epub`, through a staged, checksum-verified
archive and same-filesystem moves. Existing notebooks were not overwritten.
Archive SHA-256:
`7a0a3f18e52b4947291fe3920de2078d068b8925e4da43b3996434fc2589f295`.

`open-sampler-once.lua` was copied to KOReader's user-patch directory as
`2-open-handwriting-sampler.lua`. On startup it calls the ordinary notebook
launch path, checks the correct notebook has a loaded paper layer, captures
the blank first-page framebuffer, and removes itself. It adds no persistent
auto-open behavior. The import archive, prompt map and transcriptions remain
in the diagnostic backup directory for collection later.

Handoff command uses the pinned time-machine profile first on PATH,
`WILKBOOK_UART` unset, `timeout --kill-after=15s 600 make deploy
DEVICE=pinenote-os2 FLAVOR=book-state-device-reader KEEP=20`. The large keep
count retains the entire existing ledger.

## Outcome and cleanup

Deploy exited 0: 27/488 missing paths transferred, 25 registered while DEFAULT
remained 24, target health passed, 25 promoted, no pruning. New boot ID
`c664cad7-f825-4657-b2b1-b2fffa1af280`. A separate health check passed, real p6/p7
were writable, reader and authority were running. The one-shot patch opened
sampler page 0 and removed itself; `sampler-first-page.png` is its blank
framebuffer capture, before writing. Pen-up/append/fsync logs subsequently show
writing on that page. No handwritten samples are committed here.

Auto-suspend was restored byte-for-byte to `enabled=1`; no recovery intervention.
Pins 10/16/18/23 are retained. Generation 25 remains kexec-only, unpinned.
Operator appearance/interaction acceptance is pending; automated health and a
framebuffer capture do not establish it.

Log notes: `postflight.log` omits stale pre-update font-registration messages
from the long-lived reader log. `notebook-open.log` uses grep's text mode: the
reader log contains NULs that made the initial grep report a binary match.
The first service query used the nonexistent `pinenote-book-state-device-authority`
name, so suspend restoration was executed independently; the corrected query
proves `pinenote-book-state-device` running. The guessed `/var/log/shepherd.log`
does not exist, so that query supplies no authority-stop evidence. The normal
handoff's gates passed; no manual authority stop was used.
