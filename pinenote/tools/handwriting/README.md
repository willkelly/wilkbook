# Handwriting: first labelled lines

The current device notebooks are mostly scribbles. They remain useful for
capture/replay and performance tests, but do not measure recognition accuracy.
This is a **host-side sample exporter**, not a recognizer or training pipeline.
It neither changes the reader nor writes to the copied journals.

## Collect a small evaluation set

1. Use a fresh notebook, Ball or Fine, and **one short line per page**. Keep one
   writing orientation per page. Write normally; do not carefully imitate print.
2. Start with 12–20 lines: prose, a few Workbench-like labels, and numbers or
   punctuation. For example: `Find my notes about suspend`, `Chapter 3, page 42`,
   `Try the simpler explanation first.` Use what you actually wrote as truth,
   including mistakes, case and punctuation—not what a prompt asked you to write.
3. Close the notebook so its journal is fsynced. Copy its directory to the host
   with the existing device-access conventions. Preserve this snapshot and its
   `sha256sum` manifest; do not edit its JSONL to add labels.
4. Put each exact transcription in a separate UTF-8 text file. Export:

   ```sh
   guix shell luajit -- luajit pinenote/tools/handwriting/export-line.lua \
     /path/to/copied/notebooks 20260926T120000Z-00c0de 0 line-0.txt > line-0.inkml
   ```

InkML contains ordered active traces with upright logical pixel coordinates,
relative recorded time in milliseconds, raw pressure and raw tilt, plus notebook,
page and KOReader rotation-mode annotations. Export converts that mode to
Blitbuffer's opposite rotation before computing upright coordinates.
The notebook's **production replay** resolves
undo/redo and whole-stroke erase. Area-erased pages are refused because exporting
the surviving pen trajectories alone would resurrect visually erased text.
Mixed writing orientations, contact gaps, damaged/ignored records and torn tails
also fail visibly. The source snapshot remains the authority; InkML is derived.
No line segmentation or crop selection is inferred: one page is one labelled line.

Notebook timestamps come from realtime, clamped within each stroke. They are
not a fresh measurement of pen timing; downstream preprocessing must tolerate
clock steps between strokes. Source snapshots carry the original absolute data.

## First experiment

Compare a trajectory model (for example OnlineHTR) and a line-image model (for
example `microsoft/trocr-small-handwritten`) on the **same held-out lines**.
Separate recognizer-code, model-weight and training-data licenses before
choosing a distributable model; a repository's code license does not settle the
other two. OnlineHTR's public implementation and weight link are leads, not a
qualified PineNote runtime. TrOCR's model card specifically describes single-line
input; whole-page inference needs separate segmentation.

Measure character/word errors, punctuation and numbers separately, and host
latency/RSS. Then test a viable candidate on ARM before choosing on-device
inference. Keep later pages or a separate writing session held out; do not tune
and report accuracy on the same handful of lines. Do not train a new model on
this tiny corpus. Recognition stays asynchronous and derived; ink and its journal
remain intact when recognition is wrong or unavailable.

Sources inspected 2026-09-26:
- <https://github.com/PellelNitram/OnlineHTR>
- <https://lellep.xyz/blog/online-htr.html>
- <https://huggingface.co/microsoft/trocr-small-handwritten>

Run `make handwriting-check`: replay/rotation/error cases plus a real CLI
round trip checked by Guile's independent XML parser and source-byte comparisons.
