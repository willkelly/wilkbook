# Handwriting: first labelled lines

The pre-sampler device notebooks are mostly scribbles. They remain useful for
capture/replay and performance tests, but do not measure recognition accuracy.
The completed 2026-09-27 sampler now provides 20 reviewed image lines and 19
trajectory-compatible lines. The first local TrOCR baseline is recorded in
[`doc/handwriting-baseline.md`](../../../doc/handwriting-baseline.md).
The **host-side sample exporter** is not a recognizer or training pipeline.
It neither changes the reader nor writes to the copied journals. The companion
sampler generator creates an EPUB and a fresh notebook with fixed paper.

## Local image baseline

`evaluate-images.py` runs pinned Microsoft TrOCR Small or Base on the ink-only
`rendered/line-*.png` files in a collection. It saves all predictions before
opening `transcriptions/NN.txt`, then computes corpus-weighted character and
word edit rates. Images and labels stay local; only public model downloads use
the network. Model cache, environment, handwriting and results belong in the
gitignored `build/` directory. Run each model in its own process, sequentially,
so peak RSS and latency are attributable to that run.

```sh
python3 -m venv pinenote/tools/handwriting/build/eval-venv
pinenote/tools/handwriting/build/eval-venv/bin/python -m pip install \
  torch==2.8.0 --index-url https://download.pytorch.org/whl/cpu
pinenote/tools/handwriting/build/eval-venv/bin/python -m pip install \
  transformers==4.56.2 Pillow==11.3.0 sentencepiece==0.2.1 protobuf==7.36.2
HF_HOME="$PWD/pinenote/tools/handwriting/build/hf-cache" \
  pinenote/tools/handwriting/build/eval-venv/bin/python \
  pinenote/tools/handwriting/evaluate-images.py COLLECTION NEW_OUTPUT --model small
# Repeat with a different NEW_OUTPUT and --model base.
python3 pinenote/tools/handwriting/summarize-images.py \
  SMALL_OUTPUT/results.json BASE_OUTPUT/results.json > COMPARISON.md
make -C pinenote/tools/handwriting image-metrics-check
```

Output directories must be new. `predictions.json` preserves raw text,
per-image hashes and measured times; `results.json` adds labels, label hashes,
model revisions, environment, generation settings, peak process RSS and scores.
The comparison refuses mismatched image/label sets. Its secondary lexical score
ignores case and punctuation, explicitly retaining raw CER/WER alongside it.
There is no prompt injection, dictionary correction, training or label-guided
preprocessing. The first run uses the original 1404×240 bands and each model's
standard image processor, greedy decoding, float32 CPU inference and eight
threads. Subsequent tuning on these lines makes them development data; use new
writing for the next independent evaluation.

## Local trajectory baseline

`evaluate-trajectories.py` runs the released English IAM-OnDB checkpoint from
[OnlineHTR](https://github.com/PellelNitram/OnlineHTR), Martin Lellep's independent
implementation of Carbune et al.'s Google paper. It imports the upstream model,
preprocessor and greedy CTC decoder unchanged. Inputs are the collection's
`inkml/line-*.inkml`; embedded truth annotations never enter model features.
Our adapter negates logical-panel Y (upstream expects Y increasing upward),
converts milliseconds to seconds, and preserves original stroke order and
pen-up gaps. Pressure and tilt remain in the archive but this four-channel
model does not consume them.

Use a separate virtual environment: the upstream preprocessor uses NumPy's
`alltrue`, removed in NumPy 2. Download and unpack the author's
[released weights](https://lellep.xyz/blog/online-htr.html#the-model-weights)
under `build/`; the archive SHA-256 and selected checkpoint are recorded in
`doc/handwriting-baseline.md`. The lowest upstream validation-loss checkpoint
is selected, independently of our labels.

```sh
git clone https://github.com/PellelNitram/OnlineHTR.git \
  pinenote/tools/handwriting/build/OnlineHTR
git -C pinenote/tools/handwriting/build/OnlineHTR checkout \
  a80693a2d278b16f91332a4d17e0bb47863cc183
python3 -m venv pinenote/tools/handwriting/build/trajectory-venv
pinenote/tools/handwriting/build/trajectory-venv/bin/python -m pip install \
  torch==2.8.0 --index-url https://download.pytorch.org/whl/cpu
pinenote/tools/handwriting/build/trajectory-venv/bin/python -m pip install \
  numpy==1.26.4 pandas==2.2.3 scipy==1.14.1 lightning==2.4.0 \
  torchmetrics==1.4.3 hydra-core==1.3.2 rich==13.9.4 GitPython==3.1.43
pinenote/tools/handwriting/build/trajectory-venv/bin/python \
  pinenote/tools/handwriting/evaluate-trajectories.py COLLECTION \
  pinenote/tools/handwriting/build/OnlineHTR UNPACKED_MODEL_DIR NEW_OUTPUT
python3 pinenote/tools/handwriting/summarize-images.py --shared \
  SMALL_OUTPUT/results.json BASE_OUTPUT/results.json NEW_OUTPUT/results.json \
  > SHARED_COMPARISON.md
make -C pinenote/tools/handwriting trajectory-input-check image-metrics-check
```

The runner refuses changed upstream source, malformed channels, reversed time,
zero-height ink, nonfinite features or preprocessing that drops stroke
boundaries. It saves predictions before opening transcription files, then
checks their consistency with InkML annotations and reports characters outside
the checkpoint's alphabet. The shared comparison explicitly omits line 20 and
recomputes accuracy and median latency over the same 19 lines for every model;
image/label hashes must match. Peak RSS remains each original process's
high-water mark. No cloud recognizer or training is involved.

## Retaining alternatives and testing a contextual selector

The trajectory runner's optional `--save-emissions` stores per-frame log
probabilities under `emissions/`. `evaluate-candidates.py` verifies that the
new greedy predictions and source hashes match the frozen baseline, then
performs CTC prefix beam search: width 128, eight highest-scoring nonblank
frame labels (plus blank and repeated-prefix label), retain 32 line candidates.
It sums blank/nonblank alignment paths; it does not independently guess letters
or run a spellchecker. The exhaustive small-alphabet test is the oracle for
repeat/blank path accounting. Beam pruning makes these approximate scores,
not calibrated confidence.

`evaluate-von.py` uses an existing **local Von option-marker checkpoint** to
choose among those texts on CPU. It records direct Von selection and a fixed
combination, `CTC logp + 0.2 * log(max(Von probability, 1e-6))`. It repeats the
same query with the option order reversed. The installed older Von API rounds
probabilities to four decimals and calls the top-two probability margin
`confidence`; neither is validated handwriting confidence. No printed prompts,
reference labels, fine-tuning or freely generated corrections enter selection.
All predictions are saved before labels are opened for evaluation. The
truth-assisted best-candidate score is diagnostic only, never a selectable
recognizer or a reported achieved result.

```sh
# Repeat the earlier trajectory command into a NEW_CAPTURE with --save-emissions.
pinenote/tools/handwriting/build/eval-venv/bin/python \
  pinenote/tools/handwriting/evaluate-candidates.py \
  NEW_CAPTURE ORIGINAL_GREEDY_OUTPUT NEW_BEAM_OUTPUT
# Use the existing Von runtime's Python and library-path setup. This command
# explicitly uses CPU and local files; no server or remote API is contacted.
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 "$VON_PYTHON" \
  pinenote/tools/handwriting/evaluate-von.py \
  NEW_BEAM_OUTPUT/candidates.json COLLECTION LOCAL_VON_SNAPSHOT NEW_VON_OUTPUT
make -C pinenote/tools/handwriting candidate-check
```

The evaluation records the actual model snapshot, weight/source hashes and
runtime versions. The local cached model may predate the current online model
card; results name that local version rather than silently downloading newer
weights. Images, emissions and candidates remain under gitignored `build/`.

### Focused word/span selection with stroke probabilities

`make-focused-candidates.py` aligns the original greedy characters to emission
frames, takes word-sized windows between delimiter runs, and searches each
window independently (beam 64, eight frame labels). It scores retained strings
with the exact CTC forward algorithm, keeps up to five readings within five
log-probability units of the best, and always retains the original. It asks the
selector only when the top-two gap is at most `ln(10)`. These fixed thresholds
are heuristics; they were set before this run, not optimized on its labels.

`evaluate-focused.py` supports `--selector von` and `--selector laya`. Both get
the identical sentence with the current span blanked, the original span, and
**each option's relative stroke probability in the input context** (normalized
over only the listed readings). The sentence stays at the original recognition
for every question; changes are applied simultaneously afterwards. The primary
order is descending stroke probability. The diagnostic reverses both the
option list and the probability list, keeping IDs, texts and probabilities
together. A separate agreement gate applies a change only if both presentations
select identical text. It is not proof of invariance under all permutations.

```sh
"$NUMPY_PYTHON" pinenote/tools/handwriting/make-focused-candidates.py \
  CAPTURE NEW_FOCUSED_CANDIDATES
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 LAYA_CPU_AMP= \
  "$SELECTOR_PYTHON" pinenote/tools/handwriting/evaluate-focused.py \
  NEW_FOCUSED_CANDIDATES/candidates.json COLLECTION LOCAL_SNAPSHOT NEW_RUN \
  --selector laya
python3 pinenote/tools/handwriting/summarize-focused.py \
  NEW_FOCUSED_CANDIDATES/candidates.json NEW_RUN
make -C pinenote/tools/handwriting candidate-check
```

Use a runtime with the chosen SDK available; for a pinned Laya source checkout,
put its root on `PYTHONPATH`. The recorded runs use the existing Von runtime's
Python/library setup for both selectors, float32 CPU, eight threads, and no
dependency upgrades. Laya's native packing is checked against an untruncated
sequence before inference. Its SDK displays candidate IDs alongside texts;
Von's displays texts alone. These are native SDK encodings of identical API
inputs, not identical token sequences. `summarize-focused.py` reads saved truth
only after prediction, and calculates a diagnostic candidate-coverage bound
over all allowed span combinations. Never use that oracle to select text.

Results and exact source/model pins: `doc/handwriting-baseline.md`, focused
selection section. All question contexts, probabilities, answers, labels and
comparisons remain under private gitignored `build/focused-20260927/`.

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
