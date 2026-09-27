"""Word-sized CTC alternatives with immutable surrounding recognition text."""
import math
import re
from ctc_candidates import beam_search, sequence_logp

WORDS = re.compile(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)*")
READING = re.compile(r"[A-Za-z0-9]+(?:[' ][A-Za-z0-9]+)*\Z")


def greedy_alignment(frames, alphabet):
    """Return text and nonblank emission runs, one run per decoded character."""
    runs = []
    previous = None
    for t, frame in enumerate(frames):
        label = max(range(len(frame)), key=frame.__getitem__)
        if label and label != previous:
            runs.append([alphabet[label - 1], t, t + 1])
        elif label and label == previous:
            runs[-1][2] = t + 1
        previous = label
    return ''.join(r[0] for r in runs), runs


def word_windows(frames, alphabet):
    text, runs = greedy_alignment(frames, alphabet)
    windows = []
    for word in WORDS.finditer(text):
        a, b = word.span()
        # Exclude neighboring delimiter emission runs; include intervening blanks.
        first = runs[a - 1][2] if a else 0
        last = runs[b][1] if b < len(runs) else len(frames)
        window = frames[first:last]
        decoded, _ = greedy_alignment(window, alphabet)
        if decoded != word.group():
            raise ValueError('word/frame alignment mismatch')
        windows.append(dict(start=a, end=b, frame_start=first, frame_end=last,
                            original=word.group(), context=text[:a] + '___' + text[b:]))
    return text, windows


def options_for(window, alphabet, original):
    candidates = beam_search(window, alphabet, width=64, token_top_k=8)
    texts = {c['text'] for c in candidates if READING.fullmatch(c['text'])}
    texts.add(original)
    scored = sorted((dict(text=t, ctc_logp=sequence_logp(window, t, alphabet)) for t in texts),
                    key=lambda c: (-c['ctc_logp'], c['text']))
    top = [c for c in scored if c['ctc_logp'] >= scored[0]['ctc_logp'] - 5.0][:5]
    if not any(c['text'] == original for c in top):
        top = top[:4] + [next(c for c in scored if c['text'] == original)]
        top.sort(key=lambda c: (-c['ctc_logp'], c['text']))
    # A log-odds gap is an ambiguity heuristic, not calibrated confidence.
    ambiguous = len(top) > 1 and top[0]['ctc_logp'] - top[1]['ctc_logp'] <= math.log(10)
    return top, ambiguous


def substitute(text, spans, replacements):
    if len(spans) != len(replacements):
        raise ValueError('replacement count mismatch')
    parts, cursor = [], 0
    for span, replacement in zip(spans, replacements):
        a, b = span['start'], span['end']
        if a < cursor or b <= a or text[a:b] != span['original']:
            raise ValueError('invalid or overlapping source span')
        parts.extend([text[cursor:a], replacement])
        cursor = b
    return ''.join(parts) + text[cursor:]


def relative_probabilities(options):
    """Normalize exact CTC mass only across the retained local candidates."""
    maximum = max(o['ctc_logp'] for o in options)
    values = [math.exp(o['ctc_logp'] - maximum) for o in options]
    total = sum(values)
    return [value / total for value in values]


def question_state(span, reverse=False):
    probabilities = relative_probabilities(span['options'])
    indexed = list(enumerate(zip(span['options'], probabilities)))
    if reverse:
        indexed.reverse()
    options = {f'c{i:02d}': option['text'] for i, (option, _) in indexed}
    evidence = '\n'.join(f"- {option['text']!r}: {probability:.8f}"
                         for _, (option, probability) in indexed)
    state = (f"An imperfect handwriting transcription has one uncertain span.\n"
             f"Sentence with that span blanked: {span['context']}\n"
             f"Original recognizer reading of the span: {span['original']!r}\n"
             "Stroke-recognizer probabilities, normalized only among these listed candidates; "
             "not calibrated correctness probabilities:\n" + evidence)
    return state, options
