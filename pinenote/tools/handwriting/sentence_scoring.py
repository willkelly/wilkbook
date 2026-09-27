"""Native Noul/Score sentence assessment, separate from candidate-list choice."""
import json
import math
from focused_selectors import LayaSelector, VonSelector

INSTRUCTION = ('Assess whether this proposed handwritten note reads coherently, without '
               'obvious character-recognition errors. Use sentence context and the supplied '
               'stroke evidence. Notes may be fragments and contain names or numbers. '
               'You cannot see the ink; do not claim certainty about literal correctness.')
CRITERIA = {
    'true': 'Coherent reading with no obvious recognition corruption.',
    'false': 'Reading contains apparent letter errors, broken words or misplaced spaces.',
}
LEVELS = [
    'Severely corrupted or unintelligible reading.',
    'Several obvious recognition errors.',
    'Understandable but at least one apparent recognition error.',
    'Plausible reading with a minor uncertainty.',
    'Coherent reading with no obvious recognition errors.',
]
WEIGHTS = (0.5, 2.0, 8.0)


def checkpoint_files(root):
    # A Hugging Face snapshot itself commonly lives below ~/.cache. Exclude
    # download bookkeeping INSIDE the snapshot, never that ancestor directory.
    return sorted(f for f in root.rglob('*')
                  if f.is_file() and '.cache' not in f.relative_to(root).parts)


def instruction(evidence='stroke'):
    if evidence not in ('stroke', 'text-only'):
        raise ValueError('unknown evidence mode')
    return (INSTRUCTION if evidence == 'stroke' else INSTRUCTION.replace(
        'Use sentence context and the supplied stroke evidence.', 'Use sentence context.'))


def question(kind, evidence='stroke'):
    if kind not in ('noul', 'score'):
        raise ValueError('unknown assessment type')
    return dict(type=kind, instructions=instruction(evidence),
                criteria=CRITERIA if kind == 'noul' else LEVELS)


def state(candidate, evidence='stroke'):
    instruction(evidence)  # Validate mode even when only constructing input.
    if evidence == 'text-only':
        return json.dumps(dict(proposed_sentence=candidate['text']), ensure_ascii=False)
    return json.dumps(dict(
        proposed_sentence=candidate['text'],
        relative_stroke_probability=candidate['relative_stroke_probability'],
        stroke_log_probability_loss_from_best=candidate['stroke_loss_nats'],
        evidence_note='Probability is normalized over retained readings only, not correctness confidence.'),
        ensure_ascii=False)


def normalized_score(answer, kind):
    """Return a heuristic in [0,1]; ordinal expectations are NOT probabilities."""
    if kind == 'noul':
        value = answer['noul']
    elif kind == 'score':
        p = answer['probabilities']
        if set(p) != {str(i) for i in range(len(LEVELS))}:
            raise ValueError('wrong ordinal levels')
        if any(not math.isfinite(v) or not 0 <= v <= 1 for v in p.values()):
            raise ValueError('invalid ordinal probabilities')
        if abs(sum(p.values()) - 1) > len(LEVELS) * .0001 + 1e-9:
            raise ValueError('invalid ordinal probability mass')
        expectation = sum(int(k) * v for k, v in p.items())
        if not math.isfinite(answer['score']) or abs(expectation - answer['score']) > .011:
            raise ValueError('inconsistent ordinal expectation')
        value = expectation / (len(LEVELS) - 1)
    else:
        raise ValueError('unknown assessment type')
    if not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError('invalid assessment')
    return value


def logit(value):
    if not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError('invalid assessment')
    value = max(1e-4, min(1 - 1e-4, value))
    return math.log(value) - math.log1p(-value)


def select(candidates, kind=None, weight=0.0, direct=False):
    """Deterministic scoring; list order never breaks ties."""
    def key(c):
        base = c['base_score']
        if kind is None:
            score = base
        elif direct:
            score = c['assessments'][kind]['normalized_score']
        else:
            score = base + weight * logit(c['assessments'][kind]['normalized_score'])
        return -score, -base, c['text']
    return min(candidates, key=key)['text']


class SentenceAssessor:
    def __init__(self, name, weights):
        if name not in ('von', 'laya'):
            raise ValueError('unknown selector')
        self.name = name
        self.selector = (VonSelector if name == 'von' else LayaSelector)(weights)

    def evaluate(self, text, kind, evidence='stroke'):
        q = question(kind, evidence)
        selector = self.selector
        if self.name == 'von':
            from von.types import Noul, Score
            # Von packs Noul true then false; Score levels are ascending.
            descriptions = list(CRITERIA.values()) if kind == 'noul' else LEVELS
            selector.validate(text, q['instructions'], dict(enumerate(descriptions)))
            method = selector.backend.evaluate_noul if kind == 'noul' else selector.backend.evaluate_score
            typed = (Noul if kind == 'noul' else Score)(**q)
            return method('reading', text, typed).model_dump()
        from laya.common import build_sequence, encode_text, render_options
        internal = dict(t=kind, ins=q['instructions'], crit=q['criteria'])
        backend = selector.backend
        tok = backend.tok
        if any(len(encode_text(tok, ' ' + option, add_special_tokens=False)['input_ids']) > 48
               for option in render_options(internal)):
            raise ValueError('rubric would be clipped')
        packed = build_sequence(tok, text, internal, backend.cfg['max_len'], backend.cfg['head_max_len'])
        full = build_sequence(tok, text, internal, 8192, 8192)
        if packed != full:
            raise ValueError('assessment would be clipped')
        return backend.predict(text, {'reading': q})['answers']['reading']
