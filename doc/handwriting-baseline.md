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

## Architecture assessment: recognition, decoding, then personalization

At the operator's request, three independent agent reviews examined the linked
[OCR-assisted character-BERT paper](https://www.techscience.com/cmc/v85n3/64172/html),
our decoding implementation, and writer adaptation. The following is a research
recommendation, not a measured new recognizer or a hardware qualification.

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
