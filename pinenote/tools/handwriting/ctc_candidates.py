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


def beam_search(frames, alphabet, width=128, token_top_k=8,
                language_model=None, alpha=0.0, beta=0.0):
    """Sum blank/nonblank alignment paths; index zero is CTC blank.

    Pruning makes log probabilities approximations, not calibrated confidence.
    Zero token_top_k disables token pruning (useful for exhaustive test oracles).
    An optional incremental character LM ranks prefixes without changing their
    CTC path sums. alpha weights natural-log LM scores; beta rewards characters.
    EOS is scored before the last frame's beam pruning. LM state is retained
    only for the active beam, and never advanced for a blank or collapsed repeat.
    """
    if width < 1 or token_top_k < 0:
        raise ValueError("invalid beam limits")
    if not math.isfinite(alpha) or alpha < 0 or not math.isfinite(beta):
        raise ValueError("invalid fusion weights")
    if alpha and language_model is None:
        raise ValueError("alpha requires a language model")
    beam = {(): (0.0, NEG)}
    lm_states = {(): (language_model.start(), 0.0)} if language_model else {}
    for frame_index, frame in enumerate(frames):
        if len(frame) != len(alphabet) + 1 or any(not math.isfinite(p) for p in frame):
            raise ValueError("invalid log-probability frame")
        labels = list(range(1, len(frame)))
        if token_top_k:
            labels = sorted(labels, key=lambda c: frame[c], reverse=True)[:token_top_k]
        next_beam = {}
        next_lm = {}

        def add(prefix, blank=NEG, nonblank=NEG):
            if blank == NEG and nonblank == NEG:
                return
            pb, pn = next_beam.get(prefix, (NEG, NEG))
            next_beam[prefix] = logadd(pb, blank), logadd(pn, nonblank)
            if language_model and prefix not in next_lm:
                if prefix in lm_states:
                    next_lm[prefix] = lm_states[prefix]
                else:
                    state, score = lm_states[prefix[:-1]]
                    new_state, increment = language_model.extend(state, alphabet[prefix[-1] - 1])
                    next_lm[prefix] = new_state, score + increment

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
        def rank(item):
            prefix, probabilities = item
            score = logadd(*probabilities) + beta * len(prefix)
            if language_model and alpha:
                state, lm_score = next_lm[prefix]
                if frame_index == len(frames) - 1:
                    lm_score += language_model.finish(state)
                score += alpha * lm_score
            return score

        beam = dict(sorted(next_beam.items(), key=rank, reverse=True)[:width])
        if language_model:
            lm_states = {prefix: next_lm[prefix] for prefix in beam}
    candidates = []
    for prefix, (pb, pn) in beam.items():
        ctc_score = logadd(pb, pn)
        if ctc_score == NEG:
            continue
        row = dict(text="".join(alphabet[i - 1] for i in prefix), ctc_logp=ctc_score)
        if language_model or beta:
            lm_score = 0.0
            if language_model:
                state, lm_score = lm_states[prefix]
                lm_score += language_model.finish(state)
            row.update(language_score=lm_score,
                       combined_score=ctc_score + alpha * lm_score + beta * len(prefix))
        candidates.append(row)
    return sorted(candidates, key=lambda c: c.get('combined_score', c['ctc_logp']), reverse=True)


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
