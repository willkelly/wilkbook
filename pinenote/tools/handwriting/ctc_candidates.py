"""Host experiment: CTC prefix beam search, retaining scored text alternatives."""
import math

NEG = -math.inf


def logadd(a, b):
    if a == NEG:
        return b
    if b == NEG:
        return a
    hi, lo = max(a, b), min(a, b)
    return hi + math.log1p(math.exp(lo - hi))


def beam_search(frames, alphabet, width=128, token_top_k=8):
    """Sum blank/nonblank alignment paths; index zero is CTC blank.

    Pruning makes log probabilities approximations, not calibrated confidence.
    Zero token_top_k disables token pruning (useful for exhaustive test oracles).
    """
    if width < 1 or token_top_k < 0:
        raise ValueError("invalid beam limits")
    beam = {(): (0.0, NEG)}
    for frame in frames:
        if len(frame) != len(alphabet) + 1 or any(not math.isfinite(p) for p in frame):
            raise ValueError("invalid log-probability frame")
        labels = list(range(1, len(frame)))
        if token_top_k:
            labels = sorted(labels, key=lambda c: frame[c], reverse=True)[:token_top_k]
        next_beam = {}

        def add(prefix, blank=NEG, nonblank=NEG):
            pb, pn = next_beam.get(prefix, (NEG, NEG))
            next_beam[prefix] = logadd(pb, blank), logadd(pn, nonblank)

        for prefix, (pb, pn) in beam.items():
            total = logadd(pb, pn)
            add(prefix, blank=total + frame[0])
            # Keep a repeat even if it falls below token_top_k.
            choices = labels if not prefix or prefix[-1] in labels else labels + [prefix[-1]]
            for c in choices:
                p = frame[c]
                if prefix and c == prefix[-1]:
                    add(prefix, nonblank=pn + p)
                    add(prefix + (c,), nonblank=pb + p)
                else:
                    add(prefix + (c,), nonblank=total + p)
        beam = dict(sorted(next_beam.items(), key=lambda item: logadd(*item[1]), reverse=True)[:width])
    return [dict(text="".join(alphabet[i - 1] for i in prefix), ctc_logp=logadd(pb, pn))
            for prefix, (pb, pn) in sorted(beam.items(), key=lambda item: logadd(*item[1]), reverse=True)
            if logadd(pb, pn) != NEG]


def rerank(candidates, language_scores, weight=0.2):
    """Combine fixed recognition candidates with contextual scores, no rewriting."""
    if weight < 0:
        raise ValueError("negative language weight")
    if len(candidates) != len(language_scores):
        raise ValueError("candidate/score mismatch")
    ranked = []
    for c, score in zip(candidates, language_scores):
        ranked.append(dict(c, language_score=score, combined_score=c["ctc_logp"] + weight * score))
    return sorted(ranked, key=lambda c: c["combined_score"], reverse=True)


def sequence_logp(frames, text, alphabet):
    """Exact CTC forward probability for one fixed text (no beam pruning)."""
    lookup = {c: i + 1 for i, c in enumerate(alphabet)}
    labels = [0]
    for c in text:
        labels.extend([lookup[c], 0])
    previous = [NEG] * len(labels)
    previous[0] = 0.0
    for frame in frames:
        current = [NEG] * len(labels)
        for i, label in enumerate(labels):
            value = previous[i]
            if i:
                value = logadd(value, previous[i - 1])
            if i > 1 and label != 0 and label != labels[i - 2]:
                value = logadd(value, previous[i - 2])
            current[i] = value + frame[label]
        previous = current
    return logadd(previous[-1], previous[-2]) if len(labels) > 1 else previous[0]
