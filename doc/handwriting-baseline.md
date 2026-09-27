# Handwriting recognition: first local baseline

2026-09-27, wkelly's completed five-page sampler. **Latest result: direct Gemma
4 E2B vision is the strongest measured recognizer on this small corpus:** 0.85%
CER across all 20 images, 15 exact lines, 1.18 s/line on the workstation CPU,
5156.5 MiB inference-server peak RSS. It still normalizes a confirmed spelling
slip. This is development evidence, not deployment or general-accuracy proof.
See "Gemma 4 E2B direct image recognition" below.

The following sections record the experiments in order. The initial TrOCR
finding was **promising word recovery, insufficient literal transcription**:
Base improved on Small at substantially greater host CPU time and memory.

## Current objective: one writer with a correction loop

Operator direction, 2026-09-27: optimize recognition for **one willing writer**,
who can supply sheets with known text and accept/reject the resulting readings.
The immediate stroke-track target is below **5% raw character error**, moving
toward zero; continue reporting word error, exact lines and introduced errors
so a small character gain does not conceal worse word recovery. The direct
Gemma image reference is already below 1% on this development sampler, at the
larger memory cost recorded above.

Recognition quality is the first experiment gate. CPU is a useful baseline,
but GPU/NPU deployment is in scope: PineNote has a Mali-G52 GPU and the RK3566
NPU. Our logs establish Panfrost probing, not neural inference qualification;
the NPU conversion/runtime/driver path remains untested in this system. No
on-device latency or energy number is inferred from host measurements.

Native **Noul/Score** sentence assessment with the installed Von and Laya
checkpoints has now run: text-only Von Noul fused with stroke/character-LM
evidence reaches **4.46% CER**, while the original evidence-in-input Laya Score
reaches **4.76% with a post-hoc confidence gate** (details below). Jev names the
structured-decision model, not JEPA. Earlier runs used `choice`; this comparison
scores individual sentences rather than presenting competing candidate lists.

For personalization, preserve the ink/sample ID, model version, shown candidate
and score, accept/reject answer, and any corrected literal text. Acceptance can
label a full line; rejection provides a negative example but needs a chosen or
entered correction to supply its positive target. The confirmed sheet labels
already supply positives, and mistaken recognition alternatives supply hard
negatives. Keep later sessions/prompt families for checking improvement on new
writing. These first repeated sheets are development data, not an independent
test set. No local recognizer or decision-model fine-tuning has run yet.

**Code and erasing are in scope (operator follow-up).** The supplement
includes handwritten Python and Guile Scheme, including indentation and literal
syntax, plus area-erase-and-rewrite tasks. `make-sampler.scm OUT code-edits`
creates a six-page supplement (12 four-line blocks), reserving its last two
pages for a later-session check. Intended prompts remain separate from verified
labels; evaluate final visible ink, not erased history. Erased lines are part of
the recognition target, not cases to omit. The existing image replay preserves
area erasure; raw trajectory export refuses affected lines. No new on-device
eraser qualification is implied by generating the kit.

**Collected 2026-09-27 on generation 25:** pages 1–4 now provide eight code
blocks with **31 written lines and one writer-confirmed blank slot**. Pages 5–6
remain unwritten for a later session. The complete journal is hash-verified:
945 pen strokes and 12 area erasers, clean production replay. The writer accepts
erasing as clean and surviving Refresh/close-reopen. Four specified edits are
visible in the final ink. Labels preserve a writer-confirmed missing closing
parenthesis in one Scheme block; parsing fails there as expected, without repair.
Private evidence: `pinenote/tools/handwriting/build/collection-code-20260927/`.

Use the **eight full-width block crops**, expanded to 1404×360 at y=440/1200
so guide-boundary overshoot is retained. Several written lines overlap in their
vertical extents; the printed line boxes are not yet qualified segmentation.
Labels preserve visible indentation levels using the prompt's column convention
and conventional inter-token spaces: handwritten gaps do not define a literal
keystroke count. This whitespace convention is explicit in the collection README;
geometry stays with the labels. No code recognizer or adaptation has run yet.

This also exposes a hard limit beyond prose CER: the frozen OnlineHTR alphabet
cannot emit `=`, `_`, `{}`, `<`, `>`, backslash, backtick, `~` or `%`. Code
adaptation requires vocabulary/output-head work or another recognizer. Existing
prose runners do not qualify multiline/indentation handling; code needs exact
line/block and whitespace-sensitive metrics. Syntax checks are diagnostic,
not permission to silently rewrite the transcription. An English-fluency
selector is not a suitable correctness criterion for code.

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

## Focused span selection: Von and Laya, with stroke probabilities

The operator asked to narrow the decision to a word/short span, include the
recognizer's probabilities in the input context, and also try **Laya**. Both
ran locally on CPU against the same 19 trajectory-compatible lines. No model
was adapted, and no prompt/threshold search was performed for this run.

### Fixed inputs and selection procedure

- Align greedy characters to their CTC emission runs; use word-sized frame
  windows between neighboring delimiter emissions. Surrounding punctuation and
  spaces stay fixed. A reading may insert an internal word space, but the
  windows cannot merge across existing word boundaries or repair punctuation.
- Independently search each window with beam 64 and eight nonblank labels per
  frame. Re-score proposed strings with the **exact CTC forward probability**
  on that window. Keep at most five candidates within five natural-log units
  of the top score, always including the original reading. Restrict alternatives
  to alphanumeric words with internal apostrophes/spaces. Ask a question only
  if the best/second-best score gap is at most `ln(10)`.
- This produced **44 questions out of 128 spans**: five with two options,
  three with three, four with four, and 32 with five. This count is tokenization
  specific, not the metric's reference word count.
- Each question gets the **unchanged original sentence with one span replaced
  by `___`**, the original span, and each candidate's probability as text:
  `exp(local CTC logp) / sum(exp(local CTC logp))` over the retained options.
  Those are conditional relative stroke scores, not calibrated correctness
  probabilities or estimates including discarded readings.
- The question is: **"Which candidate best fills the gap? Use both the
  surrounding sentence and the supplied stroke-recognizer probabilities. Select
  only a supplied reading. Other words in the sentence may also have recognition
  errors."** The reference transcription and printed writing prompt are absent.
- Primary presentation sorts by stroke score. Reverse both the options and
  probability list for a diagnostic, preserving IDs and values. Record an
  additional agreement gate: apply a replacement only when both presentations
  choose exactly the same text. All questions use frozen original context;
  apply the changes together afterwards, avoiding correction cascades.
- Both selectors' **88 forward/reversed API inputs match exactly**, including
  options and probability contexts. Each SDK uses its native encoding: Laya
  includes the IDs in option text, Von does not. Every Laya question was checked
  for state, instruction and option truncation; none was truncated. Save all
  predictions before opening labels for scoring.

### Checkpoints and CPU execution

Von is the same installed SDK 1.0.1 and snapshot as the full-line experiment.
[Laya](https://github.com/NandhaKishorM/laya) is SDK/source version **0.3.20**, clean
source commit `4066d5d5fbf08b66c6757ddeedbd797bd7655bc0`, using the English
`convaiinnovations/laya` checkpoint pinned to
`55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`. Its ModernBERT-large decision model
contains **421,293,827 parameters**. The multilingual and typed-decisions
checkpoints were not used. Downloaded only the pinned model/config/tokenizer
files before inference; model inference runs in offline mode with local files.

Both use the existing runtime's PyTorch 2.9.1+rocm6.4 / Transformers 5.17.0,
explicit **CPU float32, eight threads**. Laya runs without compilation, GPU fast
path or autocast. No existing package or Von checkpoint was upgraded. Laya's
weights and configuration hashes match before/after loading. Its native SDK
warns about clamping the checkpoint's `choice:11+` temperature, a bucket these
2–5-choice questions never use. The applicable shipped temperatures are 1.90636
for two choices and 1.76015 for 3–5 choices. Neither model's published
calibration has been validated on handwriting decisions.

### Results

| Method | Raw CER | Raw WER | Lexical WER | Exact lines |
|---|---:|---:|---:|---:|
| Original / local beam | 7.14% | 26.77% | 23.08% | 2/19 |
| Focused Von, primary order | 7.14% | 25.98% | 22.31% | 2/19 |
| Focused Von, reversed | 9.52% | 37.80% | 31.54% | 2/19 |
| Focused Laya, primary order | **6.85%** | **25.20%** | **20.77%** | **3/19** |
| Focused Laya, reversed | 8.04% | 29.92% | 23.85% | 2/19 |
| Either selector, agreement gate | 7.14% | 26.77% | 23.08% | 2/19 |

Primary Von improves character error on two lines and worsens two. Primary
Laya improves two and worsens none (48 → 46 character edits). It changes three
words across three lines; one spelling improvement leaves strict character
distance unchanged because the original's final letter occupied the position
of a missing period. Raw CER and lexical WER therefore tell different parts
of the story.

**Order sensitivity remains decisive:** Von changes its answer on **32/44**
questions, Laya on **15/44**, under reversed presentation. The agreement gate
makes **zero text changes** for either model. The test reverses the probability
list too, so it diagnoses presentation sensitivity rather than isolating which
input position causes it. Keeping stroke ranks in candidate IDs and naming
the original may also anchor the decision; there is no ablation of those cues.
There is no probability-free focused run, so the contribution of the supplied
probabilities is not isolated either.

Candidate coverage is still limited. The truth-assisted lattice oracle over
all permitted span combinations reaches **4.32% CER (29/672)**, with exact
references possible for **5/19** lines. This is diagnostic only, not a selector
result. It was independently checked against exhaustive combinations on tiny
examples. Even a perfect selector cannot repair the remaining errors under
these window, threshold, alphabet and candidate-list restrictions.

| Workstation CPU cost | Von | Laya |
|---|---:|---:|
| Median single question | 198 ms | 227 ms |
| Median forward-order selection per line | 408 ms | 471 ms |
| Process peak RSS | 3775 MiB | 3157 MiB |

Shared candidate generation costs a median **164 ms/line**. Timings exclude
load/warm-up; reverse diagnostics require additional calls. These are sequential
workstation measurements, not PineNote latency, energy measurements or a
controlled memory comparison between architectures. Neither is a tiny model.

**Conclusion:** the focused Laya result is a small improvement in the primary
ordering, but neither selector supports dependable automatic correction yet.
Retain alternatives and original ink; investigate candidate coverage and
presentation robustness before adding corrections to the notebook. This corpus
is development evidence; an independent claim needs fresh held-out writing.

Reproduction and native-input details: `pinenote/tools/handwriting/README.md`.
Private evidence: `build/focused-20260927/` under that tool contains the common
candidates, all question/probability contexts, both models' answers, comparisons,
diagnostic bounds, logs, hashes and runtime provenance.

## Gemma 4 E2B: same focused task, quantized CPU comparison

The operator next asked about Gemma 4. Tested **Gemma 4 E2B IT Q4_0**, using
[`ggml-org/gemma-4-E2B-it-GGUF`](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF)
revision `b4243c156154b6dca9324415f8c7ccc098b4aed1`, file
`gemma-4-E2B-it-Q4_0.gguf`. CPU-only llama.cpp source is pinned to
`7ac59a6e3ad851cd41af00f678effab0598ba9a8`. The GGUF contains 4,628,569,635
text-model tensor parameters and occupies **2,841,481,184 bytes**; E2B is the
effective-size designation, not the total stored parameter count. No image
projector or handwriting image enters this experiment.

The evaluator starts and owns an offline, loopback-only server with eight CPU
threads, zero GPU layers, one slot and a 4096-token context. It uses the embedded
Gemma chat template, disables thinking, uses temperature zero and disables
prompt caching. The same question, sentence context, original span, candidates
and eight-decimal relative stroke probabilities are supplied as in the focused
Von/Laya runs. A JSON-output instruction and JSON Schema constrain the answer
to one supplied candidate ID. Every request/response is saved. There are no
generated option probabilities; none are inferred from deterministic output.
All 88 forward/reversed state/options presentations match the earlier inputs;
unrounded internal Python probabilities differ by at most floating-point
roundoff between runtimes, without changing the actual displayed probabilities.

**Result: no corrections.** All 44 primary selections retain the original,
as do all 44 reversed selections. Character error remains **7.14% (48/672)**,
raw WER **26.77%**, lexical WER **23.08%**, and exact lines **2/19**. There are
zero reversal flips, but that stability provides no recognition improvement.
The agreement gate also changes nothing.

Because this outcome could indicate an output-constraint bug, checked four
separate synthetic choice questions afterwards, without handwriting or labels.
The model correctly chooses red over blue, 4 over 5 for 2+2, and dog over cat
for barking when the right answer has ID `c01`, and follows an ID remapping for
red. The interface can select non-first/non-`c00` answers. The handwriting result
may reflect anchoring on the original or the strongest stroke probability, but
no ablation establishes that explanation. This run does not show that Gemma
cannot supply a useful independently measured language score.

Median cost: **1.137 s/question**, **2.367 s/line** for the forward-order
selector, plus the shared **164 ms/line** candidate generation. Reverse-order
diagnostics require another set of calls. Measured server peak RSS is
**3976.9 MiB**; the Python client separately peaks at 29.2 MiB. These are
workstation measurements after warm-up, not tablet measurements. Server-side
responses confirm zero cached prompt tokens. The owned server is stopped after
the run; the synthetic diagnostic server was also stopped.

Private evidence: `pinenote/tools/handwriting/build/focused-20260927/gemma4-e2b/`
and sibling `gemma4-e2b-sanity/`, including GGUF/source identity, all requests and
answers, server logs/configuration, timings, comparison and result files.
The E4B and larger Gemma variants remain untested.

## Gemma 4 E2B direct image recognition

The operator asked whether Gemma's vision/OCR had been tested, then requested
that comparison. **This is a different task from the text-only candidate
selection above.** It recognizes the image directly, without any trajectory
prediction or candidate list. No model was fine-tuned. The proposed adaptation
target remains the small **OnlineHTR stroke model**, not TrOCR.

### Inputs and execution

- Same 20 original 1404×240 ink-only PNGs, including line 20's visible erasure.
  Exact request image bytes and image/label hashes match the TrOCR evaluation.
  Printed sampler text, rules, reference transcriptions and candidate readings
  are absent from model input.
- Same Gemma E2B IT Q4_0 and llama.cpp pins as above, now with
  **`mmproj-gemma-4-E2B-it-BF16.gguf`** from the same model repository revision.
  The projector file is 986,833,664 bytes. Both text and multimodal offload are
  disabled; eight CPU threads, one slot, 4096-token context. Server properties
  confirm vision enabled. Native image preprocessing/token defaults; no
  sample-dependent crop, threshold, resizing or prompt changes.
- Fixed instruction: **"Transcribe the handwritten text in this image exactly
  as written. Preserve spelling, capitalization, numbers, and punctuation; do
  not correct mistakes. Return only the transcription, with no explanation,
  added quotation marks, or Markdown."**
- Temperature zero, seed zero, thinking disabled, maximum 128 output tokens,
  no constrained candidate vocabulary and no prompt caching. One blank-image
  warm-up. Each request contains only its image and the fixed instruction.
- All predictions saved before opening labels. Preserve full requests and
  responses; strip only outer whitespace for scoring. All 20 completions ended
  normally, none hit the token limit, server logs show no truncation, and all
  responses report zero cached prompt tokens.

### Results

| Measure | All 20 image lines | Shared 19 trajectory lines |
|---|---:|---:|
| Raw CER | **0.85% (6/710)** | **0.74% (5/672)** |
| Raw WER | **4.51% (6/133)** | **3.94% (5/127)** |
| Secondary lexical WER | **3.68% (5/136)** | **3.08% (4/130)** |
| Exact lines, raw | **15/20** | **15/19** |
| Exact lines, lexical | 16/20 | 16/19 |
| Median line wall time | **1.182 s** | **1.186 s** |

The shared comparison is substantially better than both the trajectory
baseline (7.14% CER, 23.08% lexical WER) and TrOCR Base (9.97% CER, 10.77%
lexical WER). It handles the numeric/currency lines exactly and preserves the
deliberately absent period on line 04. It is the strongest measured recognizer
in these experiments, not merely a better candidate selector.

Five image lines differ from their references: one merged word boundary, one
missing final period, two incorrect words, and the confirmed doubled-letter
spelling slip normalized to the usual spelling. That final case remains an
error under literal transcription even though the output is conventionally
spelled. The prompt does not guarantee spelling preservation.

Inference-server peak RSS: **5156.5 MiB (about 5.04 GiB)**. The Python client
separately peaks at 27.5 MiB. These include load/warm-up high-water marks;
per-line wall time includes image reading, request encoding, vision processing
and text generation, excluding model load/warm-up. The CPU server is stopped
after inference. The measured process footprint exceeds the PineNote's 4 GiB
RAM; this configuration is a host accuracy reference, not an on-device fit.
No quantization/runtime-memory optimization or ARM timing was attempted.

### Effect on the architecture recommendation

**This result changes the quality reference.** Gemma vision now deserves direct
evaluation on fresh natural handwriting and a deployment-cost investigation.
It should not be dismissed on the basis of the failed text-selection test.
For a host-assisted recognition path, it is the leading measured candidate.
For a self-contained PineNote, the small stroke recognizer remains the practical
adaptation/decoder target; its prospective accuracy after those improvements
is still unknown and must be compared against this stronger image baseline.
Possible selective fallback or hybrid recognition should be measured rather
than assumed to beat Gemma alone.

One writer, 20 short prompted lines, one pass: these results do not establish
unprompted-note accuracy, names/rare-word fidelity, page segmentation, an energy
budget or adaptation benefit. Fresh held-out writing is still required.
Private evidence: `pinenote/tools/handwriting/build/gemma-vision-20260927/`,
including full 20-line and shared 19-line comparisons, model/projector hashes,
requests, predictions, timings and server logs. Runner:
`pinenote/tools/handwriting/evaluate-gemma-images.py`.

## pyctcdecode + word KenLM: first integrated-decoder measurement

The operator suggested [pyctcdecode](https://github.com/kensho-technologies/pyctcdecode).
It is a good implementation match for the proposed search experiment: although
marketed for speech, it consumes CTC frame distributions, so our saved OnlineHTR
emissions work directly. Its standard KenLM integration scores **words**, not
characters; a character-CTC alphabet does not make its language model character
based. Language evidence and partial-word vocabulary scores participate before
beam pruning, rather than selecting from a final short list.

### Fixed setup

- pyctcdecode **0.5.0**, KenLM Python **0.3.0**, NumPy **1.26.4** in a fresh
  environment. KenLM builder source:
  `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`, CMake Release.
- Frozen 19-line emissions, original mixed-case/punctuation alphabet and blank
  at index zero. Each emission file reproduces its saved greedy text before
  decoding. No recognizer weights, input preprocessing or labels are changed.
- A small independent word trigram is trained on **WikiText-2 raw training
  split**, from [`Salesforce/wikitext`](https://huggingface.co/datasets/Salesforce/wikitext),
  revision `b08601e04326c79dfdd32d625aee71d232d685c3`. Input parquet SHA-256:
  `e83889baabc497075506f91975be5fac0d45c5290b6b20582c8cd1e853d0c9f7`.
  Omit blank/header records, undo WikiText placeholders, Moses-detokenize
  (sacremoses 0.1.1), preserve case. This gives **17,556 paragraphs / 1,705,812
  whitespace tokens**. No handwriting labels or prompts enter training.
- Unpruned modified Kneser-Ney 3-gram, binary trie **24,245,941 bytes**
  (23.1 MiB); 149,482 unigrams, 841,503 bigrams, 1,402,930 trigrams. Training and
  binary conversion took 1.51 s, excluding corpus preparation. The public
  WikiText source is CC-BY-SA; the trained artifacts remain under `build/`.
- Fixed search: beam width 128, beam pruning log gap 10, token minimum log
  probability -5, `prune_history=False`, retain up to 32 final hypotheses.
  No hotwords. The primary LM settings are the library defaults: **alpha=.5,
  beta=1.5, unknown-word offset=-10**, sentence-boundary scoring on. A separately
  named conservative run uses **alpha=.2, beta=0, unknown offset=-2**. Both
  settings were defined before scoring; no weight search or best-score tuning.
- Run the no-LM control, default LM, then conservative LM sequentially in
  separate processes. Save predictions before labels. Metrics and image/label
  hashes match the existing shared-line comparison.

### Results on the shared 19 lines

| Decoder | Raw CER | Raw WER | Lexical WER | Exact lines | Median decode time | Decoder-process peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| pyctcdecode, no LM | 7.14% | 26.77% | 23.08% | 2/19 | 35.1 ms | 48.7 MiB |
| **Word LM, default weights** | **5.65%** | **22.83%** | **13.08%** | **4/19** | **4.35 ms** | **124.1 MiB** |
| Word LM, conservative weights | 6.70% | 25.20% | 20.77% | 0/19 | 18.4 ms | 124.6 MiB |

The no-LM result matches the original greedy and our earlier beam top-1 on
every line. Default LM reduces **48 → 38 character edits** and **30 → 17
lexical word edits**: character error improves on eight lines, worsens on four,
and is unchanged on seven. It recovers some full word sequences and changes
boundaries; it also damages case/punctuation and some numerical text. One
formerly exact line loses its initial capital. The conservative run is not
uniformly safer and loses both previously exact lines.

The LM run is faster here because scoring/pruning can leave a smaller active
search set; beam width is a maximum, not a fixed amount of work. This is not a
general claim that adding an LM accelerates decoding. Times are one host pass,
**decoder only**, excluding the recognizer's separately measured ~30 ms/line
and LM loading. RSS excludes the recognizer too; these are not measured
end-to-end latency/memory or tablet qualifications.

Default LM's retained-list oracle improves from **4.46% to 3.57% CER**
(30 → 24 edits), with seven exact references available versus five without
the LM. This demonstrates improved candidate coverage under integrated search,
not an achieved 3.57% recognizer. The unchanged alphabet still cannot emit `$`.

### Corpus and interpretation checks

The SDK warns **"Unigrams and labels don't seem to agree."** Its check triggers
when more than 20% of *distinct characters* in the LM vocabulary are outside
the decoder alphabet. Inspection finds 931/1011 distinct LM characters outside
our 81-character alphabet, spread over only 3860/149482 unigram entries; the
public corpus includes Unicode names and additional punctuation. The warning
does not indicate shuffled frame columns: label equality and synthetic
blank/repeat/case tests pass. Keep it visible; an alphabet-aware corpus and
punctuation/OOV policy remain future comparisons, not silently applied fixes.

A post-scoring corpus audit finds **zero exact reference lines** in training
text. This is not proof against phrase overlap or an independent validation
claim. These 19 handwritten lines remain development evidence.

**Conclusion:** this is the most useful low-cost stroke-decoding improvement
measured so far. It substantially outperforms the Von/Laya/Gemma text-choice
setups while leaving OnlineHTR unchanged. It remains well behind direct Gemma
vision (0.74% CER / 3.08% lexical WER), but its cost is much more compatible with
the device track. Next priorities are better-matched language modeling,
held-out tuning/fidelity checks, and writer adaptation of the **stroke model**;
the word trigram trained here is not recognizer fine-tuning.

Private evidence: `pinenote/tools/handwriting/build/pyctcdecode-20260927/`.
Runners: `train-ctc-word-lm.py`, `evaluate-pyctcdecode.py`; tests include a real
package CTC check against exhaustive tiny alignment probabilities.

## Character 6-gram: small-model integrated-search experiment

The operator requested a cheap character n-gram comparison. This uses the
**identical detokenized WikiText-2 training corpus** as the word LM above:
17,556 paragraphs, now **10,317,120 character tokens**. No handwriting labels,
sample prompts or recognizer retraining enter the model. Source corpus hash
`bf172d62c224589acd353d0207f480ba7b49143af1208e658d1af931f2d1ddbc`
is verified before training.

### Model and decoder

- Modified-Kneser-Ney **character 6-gram**, pruned with counts `0 0 1 1 2 2`:
  retain all uni/bigrams, discard count-one tri/fourgrams, and discard counts
  at most two for five/sixgrams. Same KenLM builder and Python binding as the
  word experiment. Binary trie **6,671,503 bytes (6.36 MiB)**; estimation and
  binary conversion took **1.36 s**, excluding tokenization.
- Encode every Unicode code point as a `Uxxxxxx` token. Thus literal space is
  `U000020`, distinct from KenLM's token separators; case, digits and punctuation
  are not normalized away. All 81 recognizer characters occur in this LM.
  It sees at most five preceding characters, not full-sentence semantics.
- Extend the existing Python prefix decoder with incremental LM state. CTC
  blank/nonblank alignment sums remain separate. A collapsed repeat or blank
  adds **no** LM increment; a new character advances the LM once. Rank with
  `CTC logp + alpha * LM logp + beta * character count`; convert KenLM base-10
  scores to natural logs and include EOS before final-frame beam pruning.
  Retain LM states only for the current beam, not all historical candidates.
- Keep the prior search settings: width 128, eight nonblank frame labels plus
  blank/prefix repeat, retain 32 final texts. This is **not pyctcdecode** and
  does not use its score-gap/token-threshold pruning. It is a correctness-first
  Python experiment, not a matched optimized-decoder benchmark.
- Prespecified comparisons: no LM `(alpha,beta)=(0,0)`, light `(.2,0)`, standard
  `(.5,0)`, and length-adjusted `(.5,.5)`. The same three weighted configurations
  run once each; no parameter search after scoring. All outputs precede label
  access in each run.

### Results on the shared 19 lines

| Decoder | Raw CER | Raw WER | Lexical WER | Exact lines | Median decoding | Decoder-process peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| Python beam, no LM | 7.14% | 26.77% | 23.08% | 2/19 | 286 ms | 45.4 MiB |
| Earlier pyctcdecode word LM | 5.65% | 22.83% | **13.08%** | 4/19 | **4.35 ms** | 124.1 MiB |
| Character LM, light | 6.10% | 20.47% | 18.46% | 3/19 | 840 ms | 54.9 MiB |
| Character LM, standard | **5.21%** | **16.54%** | 14.62% | **5/19** | 868 ms | 54.1 MiB |
| Character LM, length-adjusted | **5.06%** | **16.54%** | 14.62% | **5/19** | 846 ms | 53.9 MiB |

Standard fusion reduces **48 → 35 character edits**, improving ten lines and
worsening one. The length adjustment reduces that to **34 edits**: its entire
additional gain is one character on one numeric line, not evidence of a broadly
better setting. Light weighting improves seven lines and harms two; the stronger
settings improve literal fidelity while the word LM still recovers more lexical
word content overall. The standard/length runs preserve both previously exact
lines and add three more. One previously correct word changes incorrectly.

The model is **smaller than the 23.1 MiB word LM**, but this implementation is
much slower. The no-LM Python decoder already takes 286 ms versus pyctcdecode's
35 ms no-LM control; adding character scoring raises that to about 0.85 s.
Do not interpret the 4.35 ms versus 850 ms comparison as the inherent cost of
word versus character language modeling. Times exclude the separately measured
stroke inference and are one workstation pass; RSS is the decoder process,
not an integrated recognizer or on-device measurement.

Candidate coverage improves: standard and length-adjusted lists have a
truth-assisted **2.38% CER oracle (16/672)** with **11/19 exact references
available**, compared with 3.57% and 7/19 for word-LM search. These are retained
list diagnostics only, not achieved recognition accuracy. `$` remains absent
from the recognizer alphabet even though the character LM can represent it.

### Correctness and interpretation

Exhaustive tiny CTC alignment tests verify unchanged path marginalization and
exactly-once character scoring, zero-weight parity, and EOS-sensitive pruning.
The real KenLM incremental API agrees with its independent full-sequence scorer
on synthetic text. All **19 no-LM top-32 lists match the previous beam run
exactly**, including scores. An additional audit checks all 57 weighted winners:
incremental LM scores agree with full-sequence scoring within 0.000019 nats;
pruned CTC scores do not exceed exact forward probabilities (largest missing
log-mass gap 0.0254 nats); combined scores reconstruct correctly.

**Conclusion:** character-level fusion adds useful literal fidelity and
candidate diversity with a small LM. It does not yet beat word fusion on
word-content error, and the current decoder needs substantial optimization for
the device track. Comparing a character/word combination or an improved selector
on the richer candidates is justified; a gain is not established. Gemma vision
remains the measured accuracy reference at 0.74% CER. These four runs are
development evidence on the already examined sampler, not held-out validation.

Private evidence: `pinenote/tools/handwriting/build/character-lm-20260927/`.
Runners: `train-character-lm.py`, `evaluate-character-lm.py`; scoring adapter:
`character_lm.py`; independent checks: `test-character-lm.py` and saved
`score-audit.json`.

## Independent native Noul / Score sentence assessment

The operator requested Jev-style **Noul or Score** assessment using the installed
Von and Laya models. The earlier experiments used `choice`. Here each model
assesses a **single complete sentence per question**, so competing sentences
cannot acquire preference from their position in a candidate list. Native
Noul true/false and ordinal level positions remain fixed inside the SDK; that
does not establish absence of rubric, polarity or numeric-context bias.

### Frozen candidate set and scoring

- Use the existing **32 length-adjusted character-LM candidates on each of 19
  lines**, 608 assessments per primitive and model. No reference or synthetic
  correction is added to the lists. Recompute every candidate's exact full-line
  CTC forward likelihood; all 19 control predictions remain unchanged at
  **5.06% CER, 14.62% lexical WER and 5/19 exact lines**.
- Primary input contains the candidate sentence, its relative stroke probability
  normalized over the 32 retained readings, and its log-likelihood loss from the
  strongest retained stroke candidate. No original/rank marker, other candidate,
  writing prompt, reference or image enters the model.
- Native **Noul** asks whether the sentence reads coherently without obvious
  recognition corruption. Native **Score** assesses five ordered levels:
  severely corrupted; several obvious errors; understandable with an apparent
  error; plausible with minor uncertainty; coherent without obvious errors.
- The control is `exact CTC + .5 * character LM + .5 * character count`.
  Combine it with `weight * logit(s)`, using fixed weights **0.5, 2, 8**, clipping
  `s` to `[.0001,.9999]`. Noul supplies its API value; Score uses the expected
  level divided by four, reconstructed from its category probabilities to avoid
  Von's two-decimal expectation rounding. **Ordinal expectation is not a
  probability**, and neither SDK is calibrated for handwriting. These are
  heuristic scoring functions, not independent Bayesian evidence—especially
  when the model input already contains stroke evidence.
- Report direct ranking by each scalar too, using the control as tie-breaker.
  Final ties use text order, never candidate presentation order. No score weight
  is fitted to the references. Weights/checkpoints are the same as the earlier
  runs; CPU float32, eight threads, local/offline execution, no fine-tuning.
- The inference runner has no label-directory argument. Both model runs finish
  before a separate summarizer opens references. It verifies saved prediction
  hashes, reconstructs scalar scores and verifies selections after reversing
  candidate order. This checks the selection rule, not model rubric invariance.

### Primary result: numeric stroke evidence in the assessment input

| Model / primitive | Direct scalar CER | Fusion .5 CER | Fusion 2 CER | Fusion 8 CER |
|---|---:|---:|---:|---:|
| Von Noul | 5.65% | 5.21% | 5.06% | 5.21% |
| Von Score | 6.70% | 5.06% | 5.06% | 5.36% |
| Laya Noul | 8.33% | 5.21% | 5.36% | 6.55% |
| Laya Score | 5.95% | 5.06% | 5.21% | 5.06% |

**None beats the 5.06% character-LM control.** Laya Score at weight 8 improves
three lines and worsens four by character distance, ending with the same 34
character edits. Lexical WER improves slightly to **13.85%**, raw WER worsens
to **18.11%**, and exact lines stay at five. It recovers `ogene → opened`,
`try → Try` and `IS → 15`, but also changes `find → Sind`, loses a correct
capitalization and damages a previously correct parenthesized phrase.

Sanity controls used two unrelated clean sentences and deliberately corrupted
versions with identical stroke numbers. Von Noul returns **1.0 on all four**;
Von Score prefers both clean versions. On the actual candidates, however, Von
Score's normalized values compress to **0.499925–0.548075**, with a median
within-line spread of just **0.00435**. Laya's Noul sanity control prefers the
corrupted version in one of two pairs; its Score prefers both clean versions.
These diagnostics prompted a text-only assessment ablation, keeping exact
stroke evidence in final fusion and all candidates/rubrics/coefficients fixed.

Median assessment time per complete line (32 candidates), excluding candidate
generation and model load: **Von 5.93 s Noul / 6.52 s Score; Laya 6.34 s /
7.44 s**. Peak process RSS: **3772.5 MiB Von / 3158.9 MiB Laya**. Each reported
arm needs only its own primitive; the experiment measures both. These are host
CPU measurements, not PineNote or accelerator measurements.

### Follow-up: text-only assessment, stroke evidence retained in fusion

Both models then ran the same 608 sentences and native primitives again with
`--evidence text-only`. Remove the stroke numbers and their explanatory note
from the assessment input; change the instruction's evidence sentence to
"Use sentence context." Keep the rubric, candidates, fusion coefficients and
models unchanged. This is a **follow-up motivated by the primary results**,
not an independently prespecified confirmation run.

| Model / primitive | Direct scalar CER | Fusion .5 CER | Fusion 2 CER | Fusion 8 CER |
|---|---:|---:|---:|---:|
| Von Noul | 4.46% | 5.06% | **4.46%** | **4.46%** |
| Von Score | 7.59% | 5.06% | 4.91% | 5.06% |
| Laya Noul | 8.18% | 5.21% | 5.36% | 6.10% |
| Laya Score | 4.91% | 5.06% | 5.06% | **4.76%** |

**Von Noul fusion at weights 2 and 8 gives the same improved transcription:**
**30/672 character edits (4.46%)**, raw WER **14.96%**, lexical WER **13.08%**,
**6/19 exact**. It improves two lines and worsens none: `IS → 15` on line 12
and `boos → box` on line 17. Direct Noul ranking happens to reach the same
aggregate CER, but with different predictions (three improved lines, one
worsened); prefer reporting the actual fused result rather than treating
equal aggregate scores as identical behavior.

Laya Score at weight 8 reaches **32/672 (4.76%)**, raw WER **14.17%**, lexical
WER **12.31%**, **5/19 exact**. It improves three lines and harms two:
`morninglight → morning light`, `Close → close`, and improvements to the fox
sentence; it also lowercases correct `Keep` and changes a numeric `1` to `I`.
Thus it has better word-content error than Von here, but worse character error.

Text-only median assessment time per line: **Von 4.13 s Noul / 4.90 s Score;
Laya 4.64 s / 5.70 s**, excluding candidate generation and load. Peak RSS:
**3770.9 / 3159.6 MiB**. These are sequential single-pass workstation timings.
This establishes a development-set gain from the tested scoring setup, not a
general claim that numeric stroke evidence is harmful or that these checkpoints
understand handwriting. They still never see ink.

### User-requested confidence-threshold analysis

`analyze-score-thresholds.py` reads the frozen Laya answers without any new
inference. Primary policy: **apply a proposed change only if its selected
candidate's ordinal confidence meets the threshold; otherwise retain the
character-LM baseline**. Every full-corpus CER still uses all **672 characters**.
The script separately reports selective accuracy/coverage when low-confidence
lines are omitted entirely; those figures must not replace full-corpus results.

Laya exposes two distinct fields:

- `confidence`: **1 minus normalized entropy** of the five ordinal-category
  probabilities. It measures concentration, not the probability that the
  transcription is correct. **0.20 does not mean 20% correctness.**
- `answer_confidence`: the **largest category probability**, which can express
  confidence that a reading is *corrupted*. The SDK's general calibration claims
  do not establish calibration for this handwriting task.

For the primary **stroke-evidence-in-input, Score weight 8** run:

| Entropy-confidence cutoff | Accepted changes | Lines improved / harmed | Full-corpus CER |
|---|---:|---:|---:|
| 0 (all proposals) | 8 | 3 / 4 | 5.06% |
| .10 | 7 | 3 / 4 | 5.06% |
| .15 | 2 | 1 / 1 | 5.06% |
| **.20** | **1** | **1 / 0** | **4.76%** |
| .25 | 0 | 0 / 0 | 5.06% |

The .20 gate keeps only line 12's `IS → 15` (confidence **.2070**) and rejects
all harmful proposals. Its improvement is **34 → 32 character edits**, with
lexical WER **13.85%**, raw WER **15.75%**, and **5/19 exact**. The gate behaves
identically for cutoffs **(.1874, .2070]**. If instead we literally omit every
below-threshold line, only **1/19 lines** remains, with **7.69% CER**: the
accepted line still has three other character errors. This is useful change
filtering, not evidence that high-confidence lines are error-free.

Searching the alternative `answer_confidence` thresholds finds **4.61% CER
(31/672), 6/19 exact**, retaining four changes: three improve and one harms.
Its best interval is extremely narrow: **(.3643, .3646]**. Rounding to .365
already loses one improvement. This is a post-hoc development optimum, not a
recommended magic constant. Thresholding the normalized ordinal *rating*
(not confidence) at .5 reproduces the one-change 4.76% result.

The text-only Laya follow-up **already reaches 4.76% without gating**. Applying
the same .20 entropy-confidence cutoff worsens it to **4.91%**; none of the
tested scalar gates improves that fused result below 4.76%. Direct ordinal
ranking can reach **4.61%** with a post-hoc gate, but this chooses a different
ranking policy as well as a threshold. Both full threshold curves are saved.

**Interpretation, including the operator's challenge:** this does **not**
establish that confidence reliably distinguishes helpful from harmful changes.
The .20 gate retains one favorable case; the .3646 optimum is particularly
fragile. Deterministic predictions can still yield chance sample-specific gains
after many model, input, weight and threshold comparisons. The operator aptly
challenged this as looking like randomness rather than demonstrated quality.
No confidence threshold is accepted for automatic correction. Text-only Von
Noul's 4.46% is the stronger observed stroke-track result, but its four-edit
gain across two lines is also exploratory rather than independent evidence of
generalization. Freeze a scoring setup and any development-selected gate before
testing on a fresh writing session; report harmful and helpful corrections as
well as net error. No decision model has been personalized yet.

The unchanged candidate-list oracle is **2.38% CER, 11/19 exact references
available**. That potential remains unachieved. The native decision scores are
not substitutes for the writer's actual accept/reject labels.

Private evidence: `build/sentence-scores-20260927/` under the handwriting tool,
including immutable input candidates, per-candidate raw API traces, synthetic
controls, every fixed method's predictions and comparisons, source snapshots,
weight hashes and provenance. Runners: `make-sentence-candidates.py`,
`evaluate-sentence-scores.py`, `summarize-sentence-scores.py`; adapter and pure
checks: `sentence_scoring.py`, `test-sentence-scoring.py`.
Threshold checks: `test-score-thresholds.py` verifies baseline fallback and
separate full/selected denominators. A provenance audit caught an initial hash
filter that skipped Von's checkpoint because its absolute path included
`~/.cache`; the runner now filters paths relative to the checkpoint and rejects
an empty inventory. Original run metadata is preserved, with separate audits
verifying every current weight hash and SDK source against the earlier pinned
experiments. This bookkeeping fix does not alter model inputs or predictions.

## Hosted Jev: native assessments and one flat choice (2026-09-27)

The operator supplied API access and requested a comparison with the Von work,
specifically pointing to our **Jev prompting guide**. Read
[`PROMPTING.md`](https://github.com/willkelly/jev-evaluation/blob/d80f375621ad4b9306c6dff6941242925d7e2386/PROMPTING.md)
before constructing the requests. The existing evaluation client's clean source
at **`d80f375621ad4b9306c6dff6941242925d7e2386`** provides transport and raw logging.
Every response, including the six synthetic compatibility requests, identifies
**`jev-1.13.0`** (requested alias `jev-latest`).

### Fixed experiment and guide application

- Identical **608 candidates: 32 per line on the shared 19**. No model retraining,
  new candidate search or label changes. Candidates retain exact full-line CTC,
  character-LM and length evidence. Base is the prior **5.06% CER** decoder.
- Native Noul and five-level Score use **the identical rubrics and state** as
  the Von/Laya experiment, with both questions about one sentence in one request.
  Each candidate is still judged without seeing the other candidates. Repeat
  the existing `stroke` and `text-only` input arms. Stroke evidence remains in
  final code-side fusion in both arms.
- The guide additionally motivates **one flat Choice over all 32 readings**,
  one request per line: actual sentences are option ids and descriptions,
  without a filter pass or pairwise tournament. In the stroke arm, each reading
  carries its numeric stroke evidence; in text-only, the options carry only
  candidate text. No order-shuffle requests. This Choice prompt is separately
  specified, not an exact replica of the old Von full-line choice experiment.
- Fixed fusion weights **.5, 2, 8**, plus direct ranking. Independent assessments
  use the previous clipped-logit fusion; categorical Choice uses
  `base + weight * log(max(probability, 1e-6))`. Native Score's reported expected
  level divided by four is a rating, not a correctness probability. Jev rounds
  probabilities to two decimals; validate mass/expectation within those rounding
  bounds without silently renormalizing the response.
- Hash source, candidates and settings before sending; cache raw responses and
  reuse them for every downstream calculation. No labelled few-shot examples,
  threshold fitting or hidden answer validation by another model. Only candidate
  text and optional numeric evidence go to the explicitly requested hosted
  experiment; neither ink nor reference labels are sent. It is not an on-device
  recognition implementation. The supplied credential stayed in process memory
  and a mode-0600 session-specific tmpfs file, removed after the run.

### Results: every specified method

| Method | Stroke-input CER | Text-only-input CER |
|---|---:|---:|
| Base decoder | 5.06% | 5.06% |
| Noul direct | 4.17% | 4.02% |
| Noul, weight .5 | 5.21% | 4.76% |
| Noul, weight 2 | 4.46% | **3.87%** |
| Noul, weight 8 | 4.32% | 4.02% |
| Score direct | 4.61% | 4.32% |
| Score, weight .5 | 5.21% | 4.76% |
| Score, weight 2 | 4.61% | 4.32% |
| Score, weight 8 | 4.46% | 4.02% |
| Choice direct | 5.80% | **3.72%** |
| Choice, weight .5 | 5.36% | 4.61% |
| Choice, weight 2 | 4.91% | **3.72%** |
| Choice, weight 8 | 5.80% | **3.72%** |

Text-only Choice fusion at weights 2 and 8 returns the same aggregate scores:
**25/672 character edits (3.72% CER), 13/127 raw word edits (10.24% WER),
12/130 lexical word edits (9.23%), 9/19 exact lines**. Relative to the base's
34 character edits and 5 exact lines, eight lines improve, one worsens, and no
formerly exact line is lost. These two weights differ in the capitalization of
one still-incorrect word on line 18 (`auick` versus `Auick`). Direct Choice has
the same aggregate CER/WER but
**8 exact lines**, improving eight lines and harming two; the aggregate masks
different selected readings. Candidate coverage remains **16/672 oracle edits
(2.38%), 11/19 exact references available**, not an achieved recognizer score.

Examples of useful changes include recovering a space, `ogene → opened`,
`books → looks` and sentence-initial capitalization. Failure modes remain:
the damaged page number changes `U2 → U` rather than recovering `42`, and
`boos → book` is a plausible word but the writing says `box`. Literal number,
case, punctuation and rare-word accuracy still need ink evidence. Text-only
Noul at weight 2 gives **26 edits, 7 exact lines**, improving six lines and
harming none in character-edit count; some changed readings have equal error.

The guide's ranking advice is diagnostic here, not a reason to fit a gate.
Among the **11 lines containing an exact candidate**, within-line exact-versus-
imperfect AUROC, macro-averaged across lines, is **.968 Noul / .979 Score /
.991 Choice** in the text-only arm. Many losing candidates are visibly corrupt,
so this easy ranking task can score highly while top-1 still misses lines.
Across *all* lines, ranking lower-edit candidates above higher-edit ones yields
only **.690 / .712 / .613** concordance respectively, with half credit for ties.
Neither statistic validates Jev's confidence as transcription confidence.

### Cost, verification and interpretation

Full run: **1,254 successful requests, zero retries/failures**, **774,205 reported
input tokens**, estimated **$0.03251661** at the published $42/billion input-token
rate (output free). Six preliminary synthetic requests add **3,055 tokens /
$0.00012831**. Four concurrent requests; **50.92 seconds** for the full run.
Median request latency in the text-only arm is **131 ms** for a paired Noul/Score
assessment of one candidate and **136 ms** for Choice over an entire line.
The latter needs one request/line, versus 32 paired assessment requests. These
are network-inclusive workstation measurements, excluding candidate decoding;
no tablet latency, memory or offline deployment claim follows from them.
Largest request: **4,947 reported input tokens**.

`audit-jev.py` reconstructs every expected request from frozen candidates,
checks every response against saved predictions, checks all snapshots/hashes,
then opens labels for ranking diagnostics. The metric summarizer separately
recomputes fusion with reversed candidate order. A full `--resume` replay with
network access disabled reproduced both prediction files and the original call
log byte-for-byte, without another request. The original handwriting/label
snapshot remains unchanged.

**Conclusion:** Jev provides the lowest measured stroke-track CER so far and
the flat-choice route is much cheaper in requests than per-candidate scoring.
It is only **five fewer character edits than text-only Von's 30**, and these
same sheets have now seen many methods. Even with frozen within-run settings,
choosing the best method from this table is development selection. This is
not independently demonstrated sub-5% recognition, a near-zero-error solution,
or personalization. Direct Gemma vision remains substantially stronger on the
same 19 lines (**5 edits, 0.74% CER, 15 exact**). Freeze a candidate/model/fusion
policy before fresh-session evaluation; actual writer adaptation remains unrun.

Private artifacts: `pinenote/tools/handwriting/build/jev-20260927/` and sibling
`jev-20260927-smoke/`: pre-call plan/source snapshots, requests/responses,
predictions, every comparison, ranking audit and cache-replay check. Runners:
`evaluate-jev.py`, `jev_scoring.py`, `audit-jev.py`; adapter checks:
`test-jev-scoring.py`. No API credential is included in these artifacts.

## Architecture assessment: recognition, decoding, then personalization

At the operator's request, three independent agent reviews examined the linked
[OCR-assisted character-BERT paper](https://www.techscience.com/cmc/v85n3/64172/html),
our decoding implementation, and writer adaptation. The following is a research
recommendation, not a measured new recognizer or a hardware qualification.
The assessment preceded the direct-vision experiment above; that result makes
Gemma the accuracy reference while leaving the small-model recommendations as
the CPU/memory-constrained device track.
The subsequent pyctcdecode experiment now supplies an initial positive
measurement for integrated word-LM decoding. The character 6-gram experiment
above subsequently improves character fidelity/candidate coverage with a
smaller model but a slower decoder; writer adaptation remains untested.

### What the linked paper establishes

Lee, Park and Lee (2025), **OCR-Assisted Masked BERT for Homoglyph Restoration
towards Multiple Phishing Text Downstream Tasks**, addresses Unicode homoglyph
substitutions in phishing text. It renders individual glyphs, runs Tesseract,
and creates a 13,488-entry normalization mapping before character-level
contextual restoration. Algorithm 1 and Figure 3 qualify the prose: OCR is
applied in the **zero-shot** inference branch; fine-tuned inference does not
require it. Its Table 2 reports 95.16 ± 12.89% word accuracy before homoglyph
fine-tuning and 99.59 ± 0.08% after it, with 21,342/5,336 train/held-out examples
in Table 1. Zero-shot still includes language-model pretraining on clean text,
including domain-specific spam.

Transferable principle: resolve visual ambiguity using character-sensitive
context. Important limits:

- This is not handwritten-stroke recognition. Non-ASCII corruption supplies
  localization cues that an ordinary but wrong ASCII recognition lacks.
- The authors explicitly acknowledge equal-length restoration. Insertions,
  deletions and word-boundary mistakes require different decoding/edit support.
- Word restoration accuracy is not Levenshtein WER. The paper defines an
  all-word denominator, while the related [BitAbuse evaluation code](https://github.com/CAU-AutoML/Bitabuse/blob/main/metrics.py)
  scores originally corrupted words. That repository targets the earlier
  BitAbuse paper; whether CMC used that exact implementation is unverified.
- Fifty random 80:20 splits do not establish template/campaign-disjoint
  generalization. Template overlap is a risk to check, not demonstrated leakage.
- The paper reports no latency, memory or FLOPs. Its pretraining-ablation prose
  and table coverage are inconsistent, and annotation is described as both
  single- and multiple-annotator in different sections.

Public related resources exist: [character-MLM training code](https://github.com/lhy0718/bert-character-mlm)
and [`lhy/char-bert-base-uncased`](https://huggingface.co/lhy/char-bert-base-uncased),
revision `4d6af8e4c911ccc9737d5ca2fb0aed7c62580b78` (12 layers, hidden size 768,
881 vocabulary entries, 512 positions). Its sparse model card and 2023 date do
not establish it as the checkpoint behind the 2025 CMC results. It was not run
here; neither its footprint nor its quality is a measured handwriting result.

### Recommended CPU-first path

**1. Improve decoding before adding another large option classifier.** Preserve
the small stroke recognizer's frame evidence and combine a character language
model with CTC during prefix search, including spaces and punctuation. A useful
starting score is `log P_CTC(text|ink) + alpha * log P_LM(text) + beta * length`.
Tune weights on development data; this is log-linear fusion, not a calibrated
Bayesian posterior. Apply character-LM increments only when the collapsed text
grows, not on blank/repeated frames. A pruned character n-gram is the first
cost baseline; a small character RNN is a later comparison.

This lets context preserve alternatives **before pruning**, and lets word
boundaries move. Our current focused windows are anchored to greedy delimiters;
their exact CTC scores are exact only within each cropped window, not the full
line. The 4.32% oracle is a bound for the retained candidates, not the intrinsic
limit of the recognizer's entire output distribution. `$` is genuinely absent
from its alphabet and needs an output-head/tokenizer change plus training.
Relevant precedents: [CTC prefix search with language-model integration](https://arxiv.org/abs/1408.2873)
and [Fast Multi-language LSTM-based Online Handwriting Recognition](https://arxiv.org/abs/1902.10525).
Their benchmark gains do not predict gains on this checkpoint or writer.

**2. Test writer-specific adaptation of the 245k-parameter recognizer.** Compare
head-only, last-recurrent-layer-plus-head, and conservative full fine-tuning,
using line-level CTC labels, early stopping and preservation of the original
model. A model this small does not initially need LoRA. Collect onboarding
coverage and natural writing; choose collection size from measured learning
curves rather than promising that a fixed number of pages suffices. Pressure
and tilt remain a separate training experiment because the existing input
representation does not consume them.

**3. Use a second recognizer or contextual model selectively.** Image recognition
has complementary word accuracy and handles visible ink after area erasure.
Evaluate candidate unions/late fusion before training a joint image/stroke
model. A second-pass language model should score each complete candidate
independently, combining that score with full-line exact CTC evidence; this
removes option-list ordering from the model input. Masked-LM
[pseudo-log-likelihood rescoring](https://aclanthology.org/2020.acl-main.240/)
is one established method, with length handling and inference cost to measure.
It is not a normalized sequence probability, and simply reading unmasked BERT
logits is not equivalent. Gemma is a useful quality/cost challenger and possible
occasional helper, not an assumed always-resident tablet component.

### Experiment order and acceptance

First measure search loss on saved emissions: vary pruning, exact-rescore full
lines, and report oracle CER, reference inclusion and boundary coverage. Then
compare CTC-only, finished-list LM rescoring and integrated character-LM search
at explicit compute budgets. In parallel, define adaptation splits before
collecting further handwriting. Keep the existing sampler as development data;
separate fresh train/dev/test by writing session and prompt family, with names,
numbers, symbols, natural notes and intentional spelling mistakes. Label actual
writing, not the printed prompt. Never feed held-out labels to adaptation or
language-model tuning.

Accept improvements on actual top-1 CER/WER, numeric/symbol fidelity, introduced
errors and correction effort, not oracle improvements alone. Recognition runs
after pauses/completed lines, outside the drawing path; the bidirectional model
does not imply causal per-stroke recognition. A lean runtime for its roughly
0.94 MiB float32 weights needs parity checks and measured memory; Python's
425 MiB baseline is not an intrinsic model requirement. Tablet latency and
energy remain separate later gates after host quality is demonstrated.

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
