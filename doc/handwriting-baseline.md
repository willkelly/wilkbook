# Handwriting recognition: first local baseline

2026-09-27, wkelly's completed five-page sampler. **Promising word recovery,
insufficient literal transcription.** Microsoft TrOCR Base improves on Small,
but its modest accuracy gain costs substantially more host CPU time and memory.

## What ran

- 20 ink-only images from production journal replay, including the erased and
  rewritten final line. Printed template text and rules are absent.
- Labels visually reviewed before inference; the operator confirmed the two
  ambiguous readings. Source journals, images and labels remain private under
  `pinenote/tools/handwriting/build/collection-20260927/`.
- Microsoft `trocr-small-handwritten` at
  `b4648cfa171985a6745f37ddd637e98c0da958ac` and `trocr-base-handwritten` at
  `eaacaf452b06415df8f10bb6fad3a4c11e609406`, pretrained and IAM-fine-tuned
  upstream. No local training or sample-dependent model/preprocessing tuning.
- Full 1404×240 line bands, RGB conversion, stock model processor
  (`use_fast=False`); greedy decoding, maximum 128 new tokens, no prompt or
  spelling correction. Neither model hit the token limit. All predictions were
  saved before the evaluation program opened labels.
- Ryzen 9 9950X3D workstation, eight CPU threads, float32, Python 3.11.14,
  PyTorch 2.8.0+cpu, Transformers 4.56.2. Models ran sequentially in separate
  processes. One blank-image warm-up each. Per-line wall time includes image
  loading, preprocessing, generation and decoding; excludes download, model
  loading and warm-up. One pass, not a latency distribution study.

The loader warns about newly initialized `encoder.pooler.dense` weights. Source
inspection of Transformers 4.56.2's `VisionEncoderDecoderModel.forward` shows
that the decoder receives `encoder_outputs[0]` (sequence hidden states), not
the pooler output. These unused pooler parameters do not imply an untrained
recognition decoder. The original warnings are retained in the local logs.

## Results

Rates are corpus-weighted Levenshtein edits divided by reference length, not
mean per-line rates. Raw CER includes spaces, case and punctuation; raw WER
splits only on whitespace. There are 710 reference characters and 133 raw words.

| Measure | TrOCR Small | TrOCR Base |
|---|---:|---:|
| Parameters, loaded | 61,596,672 | 333,921,792 |
| Raw character error rate | 11.69% (83/710) | 9.72% (69/710) |
| Raw word error rate | 57.14% (76/133) | 54.14% (72/133) |
| Secondary lexical word error rate | 14.71% | 11.03% |
| Exact lines, raw | 0/20 | 0/20 |
| Exact lines, lexical | 8/20 | 10/20 |
| Median line wall time | 0.122 s | 0.847 s |
| Peak process RSS | 651.8 MiB | 2537.5 MiB |
| Shared 19-line raw CER | 12.05% | 9.97% |

The secondary lexical measure casefolds and extracts word/number tokens with
internal apostrophes retained. Decimal points and colons separate numeric
tokens. It is a word-content diagnostic and intentionally does not measure
punctuation fidelity. Both models produce spaces before punctuation, inflating
raw WER and preventing exact matches even when words are correct. Keep both
views; the secondary measure is not a replacement accuracy headline.

RSS is the Linux process high-water mark including Python, PyTorch, model load
and warm-up, not just weights or an isolated steady-state working set. These
are desktop measurements, not ARM latency or memory qualification.

### What the errors mean

- Ordinary prose is often recognizable; Base recovers more words correctly.
- Numerals, currency and some word shapes remain substantial weaknesses.
- Both models add punctuation to a line written without terminal punctuation.
- Both silently normalize an operator-confirmed spelling slip. Recognition
  must therefore be derived, correctable text, never an overwrite of the ink.
- Raster replay handled the erasure normally. No discarded/hidden strokes were
  supplied to either recognizer. The final line remains excluded from the
  19-line trajectory comparison set.

This is one writer and 20 short prompted lines. It establishes a reproducible
feasibility baseline, not general accuracy, page segmentation performance or
reliability. Further choices made using these results require fresh handwriting
for independent confirmation. Keep Small as the inexpensive baseline; compare
another recognition family and preprocessing on an explicit development set
before spending a hardware session on deployment.

## First trajectory baseline (same day)

**Trajectories are now tested:** the released English checkpoint from
[Martin Lellep's OnlineHTR](https://github.com/PellelNitram/OnlineHTR), an
independent implementation of Carbune et al. (2020), *Fast multi-language
LSTM-based online handwriting recognition*. This is not Google's production
recognizer or its trained weights. It is a small three-layer, bidirectional
LSTM with 64 hidden units per direction, trained on IAM-OnDB, with greedy CTC
decoding and no language model. Total: **245,074 parameters**.

### Input and reproducibility

- Upstream commit `a80693a2d278b16f91332a4d17e0bb47863cc183`, imported unchanged.
  Its model, transform, tokenizer and decoder sources were diff-checked against
  the checkpoint's recorded training commit
  `fb3eee853eb7437fd55ea5a03f674ddbf528f932`: identical.
- [Author's download page](https://lellep.xyz/blog/online-htr.html#the-model-weights)
  resolves to Google Drive file `1_F9B18_tMtWAsvkRvPRgme0RDxOBgSWb`.
  Archive SHA-256:
  `d54f092929cd2290f2330981f33d058faa852e95dde5e7ea3b5e4824d45233fa`.
  The upstream selector chooses `epoch=000699_step=0000106400_val_loss=0.2650.ckpt`
  by lowest upstream validation loss, not by our sampler performance. Checkpoint
  SHA-256: `f906a239e1cf769c269f8f991ec1062ef5c4d53df403e1272966b58b0ea7ef44`.
- InkML preserves original stroke order. The adapter discards truth annotations
  from model input, negates screen Y to the training convention (upward Y),
  converts milliseconds to seconds and keeps pen-up time gaps. The upstream
  transform normalizes line height, chooses per-stroke sample counts at 20
  points per normalized path-length unit, interpolates uniformly in time, then
  derives `dx, dy, dt, stroke-start`. Pressure and tilt are not model channels.
- Every input stroke boundary survived preprocessing; no line was rejected or
  silently dropped. Source timestamps were monotonic, with no equal adjacent
  timestamps or stationary multi-point strokes. Area-erased line 20 was excluded
  as planned. The checkpoint alphabet lacks **`$`**; that character cannot be
  recognized by this release. It remains in the reference and counts as an error.
- Same CPU, eight threads, float32, separate process, one shape-only warmup.
  Python 3.11.14, PyTorch 2.8.0+cpu, NumPy 1.26.4, pandas 2.2.3,
  SciPy 1.14.1, Lightning 2.4.0, torchmetrics 1.4.3. No retraining,
  beam search, word list or sample-specific normalization.

### Fair comparison: the shared 19 lines

All image rates and median times below are recalculated on lines 01–19, not
copied from the earlier 20-line table. Hashes match the same images and labels.
There are 672 reference characters, 127 whitespace words and 130 lexical tokens.

| Measure | TrOCR Small | TrOCR Base | OnlineHTR trajectories |
|---|---:|---:|---:|
| Raw CER | 12.05% | 9.97% | **7.14% (48/672)** |
| Raw WER | 57.48% | 54.33% | **26.77% (34/127)** |
| Secondary lexical WER | 14.62% | **10.77%** | 23.08% (30/130) |
| Exact lines, raw | 0/19 | 0/19 | **2/19** |
| Exact lines, lexical | 8/19 | **10/19** | 4/19 |
| Median line time | 0.122 s | 0.851 s | **0.030 s** |
| Peak process RSS | 651.8 MiB | 2537.5 MiB | **424.9 MiB** |

The trajectory result has fewer character edits and much better punctuation
spacing, while the image models recover more whole words after punctuation
and case are ignored. Do not declare an overall accuracy winner from raw CER
alone. The trajectory model preserved the deliberately absent terminal period
and some words both TrOCR variants missed, but also produced character-level
misspellings within otherwise correct phrases. Numbers remain weak. The erased
final line was not tested, so there is no trajectory result for its confirmed
spelling slip.

Its parameters occupy about **0.935 MiB in float32** (arithmetic from parameter
count), versus about 235 MiB for TrOCR Small. The 424.9 MiB process peak includes
PyTorch/Lightning and other Python libraries, plus checkpoint loading; it is
not an ARM inference requirement. At roughly 30 ms/line on this workstation,
this is a plausible compact model family to investigate for the tablet. No
tablet timing, export or quantization has been tested.

### Next experiment

Keep this frozen, unadapted result. A small trajectory model with inspectable
training code makes writer adaptation practical to investigate, but benefit
from a few onboarding sheets is not yet measured. Before requesting new sheets,
define the adaptation procedure and a separate fresh evaluation set. The
existing 19 lines can become development data; they must not be used both to
fine-tune and to claim an independent improvement. Broader pretrained coverage
(especially numbers/symbols) and a stronger sequence model remain candidates.

The source/adaptation opportunity here is distinct from the production-quality
offline APIs: [Google ML Kit digital ink](https://developers.google.com/ml-kit/vision/digital-ink-recognition)
supports stroke-based offline recognition on Android and iOS, not a documented
Linux SDK. Its accuracy is not represented by this independent implementation.
The Microsoft/InkFM leads below remain relevant research, with no additional
released trajectory weights established during this search.

## Candidate selection with the existing Von installation (same day)

The operator proposed retaining uncertain recognition alternatives and using a
small contextual classifier to choose what makes sense, specifically the recent
**Jev-style** decision models, then identified the existing local installation
as **Von**. CPU was explicitly preferred for this experiment.

### What ran

- Re-ran the unchanged trajectory model with emission capture. All 19 greedy
  predictions and input hashes match the frozen baseline. Retained frame-level
  log probabilities permit decoder experiments without more model inference.
- A tested CTC prefix beam sums alignment paths with separate blank/nonblank
  states. Fixed beam width 128, top eight nonblank labels per frame plus blank
  and any prefix-repeat label, top 32 final text candidates. No spelling repair
  or template hints. Plain beam top-1 matches greedy on every sample.
- Used the operator's **existing Von 1.0.1 SDK**, option-marker backend,
  cached `wfzyx/von-1.0` snapshot
  `aa2fdc9630ecdadef32c56073553b3a69bed38bf`. The runtime uses
  PyTorch 2.9.1+rocm6.4 and Transformers 5.17.0, but inference here was explicitly
  **CPU**, float32, eight threads. No server or cloud service was used. Downloads
  were disabled. The existing environment and cached model were not upgraded.
- The installed model has **395,310,081 parameters**, a ModernBERT encoder with
  an option-marker scoring head. It is not a tiny classifier despite the small
  size of the head. The local snapshot lacks a calibration file; the installed
  backend uses temperature 1 and reports a top-two probability margin as
  `confidence`. Its rounded option probabilities are not calibrated handwriting
  probabilities. Strict loading of `option_marker.pt` succeeded; the encoder's
  unused classification-head keys in the base-model load report are retained
  in the run log.
- Input state describes alternative readings of an unknown handwritten English
  line. The fixed question is: **"Which proposed reading makes the most sense
  in its sentence context? Select only from the supplied readings."** Von sees
  the candidate texts, not images, pen trajectories, printed prompts or labels.
- Compared direct Von choice and a fixed combined score:
  `CTC logp + 0.2 * log(max(Von probability, 1e-6))`. The probability floor
  handles the API's four-decimal rounding. The coefficient was fixed before
  the run and not searched against these labels. Choices remain constrained to
  actual candidate texts.
- Every query was repeated with the same candidate IDs/texts in reverse order.
  This is a diagnostic, not an opportunity to pick the better ordering after
  seeing labels. Saved all choices/probabilities before opening labels.

### Results: no reliable improvement from this installed selector

| Method | Raw CER | Raw WER | Lexical WER | Exact lines |
|---|---:|---:|---:|---:|
| Greedy / plain CTC beam | 7.14% | 26.77% | 23.08% | 2/19 |
| Von choice, CTC-ranked option order | 9.82% | 41.73% | 30.00% | 1/19 |
| Stroke score + Von, same order | 8.04% | 29.13% | 24.62% | 1/19 |
| Von choice, reversed option order | 8.78% | 36.22% | 29.23% | 0/19 |
| Stroke score + Von, reversed order | 6.85% | 24.41% | 20.77% | 2/19 |

**Reversing options changed Von's selected text on 17/19 lines**, and the
combined-score winner on 15/19. Direct forward-order choice improved character
error on four lines and worsened twelve; forward fusion improved five and
worsened eleven. The small gain from reversed fusion cannot justify deploying
an order-sensitive selector. One previously exact line lost a correct word
space. This is a negative result for this checkpoint/query/decoder combination,
not evidence that contextual selection is inherently ineffective.

**The alternatives do contain useful information:** the exact reference is
present among the 32 candidates for 5/19 lines. A truth-assisted oracle choosing
the lowest-character-error candidate could achieve **4.46% CER (30/672)** versus
greedy's 7.14% (48/672). This is an unattainable-without-truth diagnostic bound
for the retained lists, not an achieved recognition score. Correcting all errors
is impossible with these candidates: many intended words never reach the list,
and the missing dollar symbol remains outside the recognizer's alphabet.

CPU cost on the workstation: median **0.252 s/line** for the unoptimized Python
beam search, **0.407 s/line** for one Von choice, excluding its 2.38 s model load
and warm-up. The reversed-order diagnostic incurs a second choice call. Von
process peak RSS was **3769.4 MiB**, including weights/runtime/load. These are
separate measured stages, not a PineNote latency measurement.

### Model identity and next direction

[Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) is TypeSafe's
September 2026 structured-decision release; its architecture is not publicly
established as BERT. [Von](https://github.com/wfzyx/von) is the open ModernBERT
option-marker implementation actually tested. **Jev is not JEPA**. An initial
JEPA interpretation in conversation was corrected before model selection.

The [current online Von card](https://huggingface.co/wfzyx/von-1.0) redirects to
a newer 1.2 release and describes independent-option attention to remove order
dependence. That is not the installed 1.0.1 SDK/snapshot and was not tested.
Do not attach those newer claims to this result. The local run records actual
weight and implementation hashes.

Keep the candidate interface: it is reusable for a specialized contextual
ranker, a smaller masked-language model or a later Von checkpoint. Before
trusting automatic selection, improve candidate coverage, test order stability
and measure both corrected and newly introduced errors on fresh writing. For
the current release, the ink and original recognition remain available; no
automatic notebook correction was added.

Private evidence:
`pinenote/tools/handwriting/build/candidates-20260927/` contains emission capture,
the 32-candidate lists, every forward/reversed Von answer, full comparisons,
timings, settings, source/weight hashes and dependency versions.

## Microsoft Research and related work

- **[TrOCR](https://www.microsoft.com/en-us/research/publication/trocr-transformer-based-optical-character-recognition-with-pre-trained-models/)**
  (AAAI 2023): the directly actionable Microsoft result for these cropped
  handwritten lines. [Official code and model table](https://github.com/microsoft/unilm/tree/master/trocr)
  list Small/Base/Large as 62M/334M/558M parameters and IAM CERs of
  4.22/3.42/2.89%. Those published dataset scores are not our results.
  [Small weights](https://huggingface.co/microsoft/trocr-small-handwritten) and
  [Base weights](https://huggingface.co/microsoft/trocr-base-handwritten) are
  the releases used here.
- **[Project Ink Analysis](https://www.microsoft.com/en-us/research/project/ink-analysis/)**:
  relevant system design for stroke-based recognition, layout and shapes.
  Its project page advertises handwriting in 67 languages. The material
  inspected did not establish a downloadable Linux-compatible pretrained
  trajectory recognizer; no such engine was run in this baseline.
- **[Florence-2](https://huggingface.co/microsoft/Florence-2-base)**:
  released Microsoft vision models with OCR tasks; Base is 0.23B parameters.
  Worth a later comparison, but the general vision/OCR model card is not proof
  of performance on this handwriting. Not run here.
- **[InkFM](https://arxiv.org/html/2503.23081v1)** (2025) is **Google DeepMind**,
  not Microsoft. It studies full-page online ink segmentation, recognition
  and classification. Relevant trajectory/page-understanding research, but
  the reviewed paper did not establish an immediately usable released model
  for this host comparison. The trajectory run above uses OnlineHTR instead.

## Replay and evidence

Tooling and setup: [`pinenote/tools/handwriting/README.md`](../pinenote/tools/handwriting/README.md).
Private run directory:
`pinenote/tools/handwriting/build/evaluation-20260927/` holds raw predictions,
full side-by-side `comparison.md`, scores, logs, dependency versions and hashes.
The committed metric tests cover edit operations, Unicode, corpus weighting,
literal spelling/punctuation and the explicitly lossy secondary measure.
Trajectory evidence is under
`pinenote/tools/handwriting/build/trajectory-evaluation-20260927/`: the full
three-model 19-line comparison, predictions, results, dependency versions,
upstream feature/CTC contract check and run log. Adapter tests pin Y orientation,
time units, stroke order, label isolation and malformed-input refusals; the
shared-comparison test pins recomputed denominators and mismatched-hash refusal.
No tablet changes or hardware session were needed.
