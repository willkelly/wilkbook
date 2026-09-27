"""Jev wire adapters and two-decimal response checks; no network or labels."""
import json
import math
from sentence_scoring import LEVELS, WEIGHTS, question, select, state


def assessment_questions(evidence):
    # jeveval takes neutral questions; keep the actual wire rubric identical to
    # the local Von/Laya experiment, batching both questions about one subject.
    questions = {}
    for kind in ('noul', 'score'):
        q = question(kind, evidence)
        questions[kind] = dict(type=kind, question=q['instructions'])
        if kind == 'noul':
            questions[kind]['criteria'] = q['criteria']
        else:
            questions[kind]['rubric'] = [dict(id=str(i), label=text)
                                        for i, text in enumerate(q['criteria'])]
    return questions


def choice_spec(candidates, evidence):
    # The actual sentences identify the alternatives, rather than list indexes.
    # Both ids and descriptions are meaningful; no labels or decoder rankings.
    options = {c['text']: c['text'] for c in candidates}
    if len(options) != len(candidates) or not 2 <= len(options) <= 255:
        raise ValueError('choice requires 2..255 distinct readings')
    context = dict(task='Alternative recognizer readings of one handwritten line. '
                   'The intended text is unknown. You cannot see the ink.')
    if evidence == 'stroke':
        context['readings'] = [json.loads(state(c, evidence)) for c in candidates]
    elif evidence != 'text-only':
        raise ValueError('unknown evidence mode')
    prompt = ('Which proposed reading makes the most sense in its sentence context? '
              'Select only from the supplied readings. Notes may be fragments and '
              'contain names or numbers. Do not assume polished prose is correct.')
    if evidence == 'stroke':
        prompt += ' Consider the supplied stroke evidence as well as sentence context.'
    return context, dict(reading=dict(type='choice', question=prompt,
        options=[dict(id=k, label=v) for k, v in options.items()]))


def probability(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError('invalid Jev probability')
    return value


def distribution(answer, keys):
    probabilities = answer['probabilities']
    if set(probabilities) != set(keys):
        raise ValueError('wrong Jev probability keys')
    for value in probabilities.values():
        probability(value)
    # Jev rounds independently to two decimals. Keep the wire values; do not
    # renormalize and silently change the chosen scoring rule.
    if abs(sum(probabilities.values()) - 1) > len(keys) * .005 + 1e-9:
        raise ValueError('invalid rounded Jev probability mass')
    return probabilities


def normalized_score(answer, kind):
    if answer.get('type') != kind:
        raise ValueError('wrong Jev answer type')
    if kind == 'noul':
        return probability(answer['noul'])
    if kind != 'score':
        raise ValueError('unknown assessment type')
    p = distribution(answer, [str(i) for i in range(len(LEVELS))])
    value = answer['score']
    probability(value / (len(LEVELS) - 1))
    expectation = sum(int(k) * v for k, v in p.items())
    # The separately rounded expectation may differ from the expectation of
    # rounded probabilities by at most .005 + sum(level * .005).
    tolerance = .005 * (1 + sum(range(len(LEVELS))))
    if abs(expectation - value) > tolerance + 1e-9:
        raise ValueError('inconsistent Jev ordinal expectation')
    if answer.get('legend') != {str(i): text for i, text in enumerate(LEVELS)}:
        raise ValueError('wrong Jev ordinal legend')
    probability(answer['confidence'])
    return value / (len(LEVELS) - 1)


def choice_readings(candidates, answer):
    if answer.get('type') != 'choice':
        raise ValueError('wrong Jev choice type')
    p = distribution(answer, [c['text'] for c in candidates])
    if answer['choice'] not in p:
        raise ValueError('unknown Jev choice')
    probability(answer['confidence'])
    # Choice probabilities use log categorical mass, not the scalar logit used
    # for independent Noul/Score. All weights are fixed before calling Jev.
    readings = dict(choice_direct=answer['choice'])
    for weight in WEIGHTS:
        readings[f'choice_{weight:g}'] = min(candidates, key=lambda c: (
            -(c['base_score'] + weight * math.log(max(p[c['text']], 1e-6))),
            -c['base_score'], c['text']))['text']
    return readings


def readings(row):
    candidates = row['candidates']
    result = dict(greedy=row['greedy_prediction'], previous=row['previous_prediction'],
                  base=select(candidates))
    for kind in ('noul', 'score'):
        result[kind + '_direct'] = select(candidates, kind, direct=True)
        for weight in WEIGHTS:
            result[f'{kind}_{weight:g}'] = select(candidates, kind, weight)
    result.update(choice_readings(candidates, row['choice_answer']))
    return result
