# The notebook's first glass run: generations 22 and 23, cable-free (2026-09-26)

These are the records for `doc/status.md` 2026-09-26, "generations 22 and 23", on
wkelly's PineNote. The design is in `doc/notebook.md`. The reader's address is
redacted as `[reader address]`.

| File | What it is |
|---|---|
| `deploy-gen22.log` | `make deploy` 21→22: transfer, add, kexec trial, health, promotion, pruning of generation 17. |
| `deploy-gen23.log` | `make deploy` 22→23: the same steps; nothing pruned. |
| `notebook-penup-gen22-20260926.log` | All 218 `[notebook] pen-up` lines from `/var/log/reader-session.log`, generation 22. |
| `touch-five-fingers-20260926.bin` | The raw `cyttsp5` evdev stream (`/dev/input/event6`, 24-byte aarch64 `input_event` records, 2150 events) of a 60 s capture: five-finger holds and swipes with the notebook open, on generation 22. |
| `evidence.txt` | Excerpts: the note authority log for the `25cea98` check, the first pen-up lines, the deploy postflights, the touch-error check, the auto-suspend bytes, and generation 23's idle washes. |

SHA-256:

```
593265742e1a86790ee41192a78803517d953e9a030cde4d8b06a8ce8b34d6e9  deploy-gen22.log
b0a632dda19621c7442e4e838645787fcadb9a9d58a6955fd898d268fb40a07d  deploy-gen23.log
255b1bfa4e44988dd6cc7c6bb7e2acc8fb9da985bfb459643526755757bf48b0  notebook-penup-gen22-20260926.log
2799896a4eba9a50f7cde03b12e1c87a1ec703ce862cb9685ee4900abc9b7de7  touch-five-fingers-20260926.bin
```

## The touch capture

- **Counted per frame (at each `SYN_REPORT`):** the peak is **2 contacts** across
  255 frames. 204 frames hold exactly 2, 31 hold 1 and 20 hold 0.
- **Slots and errors:** only slots 0–3 appear, and dmesg counted
  `Num touch err` as 0 both before and after the capture.
- **Counted per `ABS_MT_TRACKING_ID` event instead:** the same stream reaches 3
  in 8 frames. A new contact's tracking ID arrives inside one frame just before
  another slot's `-1`, so a third contact never exists across a frame
  boundary. That is most likely what produced the "3" in
  `../pinenote-input-clocks-20260824/RESULT.md`.

The firmware limit and hrdl's one-byte change to it are in issue #82.

## The notebook's timings on generation 22

These come from `notebook-penup-gen22-20260926.log`, one line per stroke.

**Strokes:** 218 strokes carried 58,868 pen reports. 58,073 of those were
stamped, meaning inked or area-erased. The 805 reports of stroke-erase strokes
are hit-tested, not stamped. By kind: 196 ink, 10 rubber area erase, 8 rubber
stroke erase, 2 tip area erase and 2 tip stroke erase.

**Per stamped report:**

| Measure | Mean | Max |
|---|---|---|
| Stamp | 0.20 ms | 8.5 ms |
| Publish (fsync on the framebuffer) | 0.37 ms | 16.8 ms |

**Worst event-to-handling delay per stroke** (`lag`). This is taken when the
controller starts handling a report, before that report's own ~0.6 ms stamp
and publish. Across the 218 per-stroke worsts:

| p50 | p95 | max |
|---|---|---|
| 1.2 ms | 14.4 ms | 34.3 ms |

These are not per-report percentiles.

**Backlog:** 50 strokes drained a backlog of more than one report in a batch,
the largest being 36. So the pen path falls behind by tens of milliseconds at
times. The cause is not yet identified.

**Saving:**

| Measure | Mean | Max |
|---|---|---|
| Append at pen-up | 0.4 ms | 2.2 ms |
| fsync at the pen's leave (98 leaves) | 6.1 ms | 7.7 ms |

**Overruns:** one evdev overrun (`SYN_DROPPED`) between opening the notebook
and the first pen-up. Its batch held 22 reports, with a 19 ms delay. An unknown
number of events was lost in it.

**Not measured:** nib-to-ink on the panel. A publish is an fsync, and the
e-ink pass runs after it returns.
