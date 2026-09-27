# Handwriting: first labelled lines

The current device notebooks are mostly scribbles. They remain useful for
capture/replay and performance tests, but do not measure recognition accuracy.
The **host-side sample exporter** is not a recognizer or training pipeline.
It neither changes the reader nor writes to the copied journals. The companion
sampler generator creates an EPUB and a fresh notebook with fixed paper.

## Copy-and-write sampler

Generate five pages of four prompts: everyday prose, Workbench-like requests,
numbers and punctuation. Each prompt has a generous ruled writing area beneath
it. The same artwork produces the EPUB's page images and the notebook's paper.

```sh
guix shell guile librsvg imagemagick zip font-dejavu -- \
  guile --no-auto-compile -s pinenote/tools/handwriting/make-sampler.scm \
  pinenote/tools/handwriting/build
```

The output directory must not exist. Outputs:
- `handwriting-sampler.epub`: five fixed-layout portrait pages. KOReader's
  EPUB engine may fit the artwork within reader margins; the notebook uses
  the full-resolution artwork, not a screenshot of that fitted EPUB.
- `notebooks/<new-id>/`: an ordinary stroke journal notebook plus the immutable
  `backgrounds.conf` and five `background-N.pgm` pages. The ID is generated at
  creation; subsequent runs never replace a filled notebook.
- `regions.tsv`: 20 numbered writing areas, in upright portrait pixels.
- `transcriptions/01.txt` … `20.txt`: the prompt text, **not yet verified truth**.
- `handwriting-sampler-kit.zip`: the EPUB, notebook, prompts, regions and
  installation instructions together.

**Requires the background-template reader change.** Generation 24 does not
display these backgrounds; older readers ignore the companion files and show
blank paper. After installing the qualified reader change, close Notebook,
copy the entire new notebook directory to `/data/notebooks/` on the real data
partition, refusing any existing destination, and sync it before opening.
Keep all background files with the journal in backups. In Tools → Notebook →
Open, select the newly created notebook by its UTC timestamp. Pages are 0–4;
after that they are blank. Orient the tablet so the prompts are upright (the
seeded portrait mode 1) and keep that orientation while writing. Ink and paper
remain attached to physical pixels when the controls rotate.

Use Ball or Fine, write normally above each rule, and lift between lines.
Close Notebook when finished; preserve a complete host-side snapshot and
checksums. Correct the transcription files to **what was actually written**,
including mistakes. Export a writing area using its row of `regions.tsv`:

```sh
guix shell luajit -- luajit pinenote/tools/handwriting/export-line.lua \
  /path/to/copied/notebooks NOTEBOOK-ID 0 transcriptions/01.txt \
  88 390 1228 180 > sample-01.inkml
```

The optional `X Y W H` selects whole strokes in logical, upright coordinates;
coordinates stay in that source space and the region is recorded in InkML.
A stroke touching both sides of its boundary is refused, including its brush
width. Choose a larger unambiguous region if needed, rather than silently
cutting a letter. Area erasing that intersects the selected region needs raster
recognition and is refused; an eraser whose entire brush box is outside the
region does not invalidate that line. Whole-page export still refuses any
active area eraser. Undo and whole-stroke erase replay correctly.
The printed prompts and rules never enter the stroke export.

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
No line segmentation or crop selection is inferred: without an explicit region,
one page is one labelled line.

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
