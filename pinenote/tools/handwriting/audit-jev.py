#!/usr/bin/env python3
"""Verify Jev requests against frozen inputs, then measure within-line ranking."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
from jev_scoring import choice_readings, choice_spec, normalized_score
from sentence_scoring import question, state


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def wire_choice(candidates, evidence):
    context, neutral = choice_spec(candidates, evidence)
    q = neutral['reading']
    return context, dict(reading=dict(type='choice', instructions=q['question'],
        criteria={o['id']: o['label'] for o in q['options']}))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('run', type=Path)
    p.add_argument('collection', type=Path)
    args = p.parse_args()
    root = args.run
    plan = json.loads((root / 'plan.json').read_text())
    meta = json.loads((root / 'metadata.json').read_text())
    assert sha(root / 'calls.jsonl') == meta['calls_sha256']
    assert sha(root / 'plan.json') == meta['plan_sha256']
    assert sha(root / 'candidates.json') == plan['candidate_sha256']
    for source, digest in plan['source_sha256'].items():
        assert sha(root / 'source' / Path(source).name) == digest
    calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
    ok = [r for r in calls if r['outcome'] == 'ok']
    by_request = {json.dumps(r['request'], sort_keys=True): r for r in ok}
    assert len(by_request) == len(ok)
    assert sorted({r['model_version'] for r in ok}) == meta['returned_models']
    assert len(meta['returned_models']) == 1
    expected = set()
    data = json.loads((root / 'candidates.json').read_text())
    outputs = {}
    # Verify every model input and response before opening a reference file.
    for evidence in plan['evidence']:
        arm = root / evidence
        arm_meta = json.loads((arm / 'metadata.json').read_text())
        assert sha(arm / 'predictions.json') == arm_meta['predictions_sha256']
        output = json.loads((arm / 'predictions.json').read_text())
        assert [r['sample'] for r in output['rows']] == [r['sample'] for r in data['rows']]
        outputs[evidence] = output
        for original, row in zip(data['rows'], output['rows']):
            assert len(original['candidates']) == len(row['candidates'])
            for before, after in zip(original['candidates'], row['candidates']):
                assert all(after[k] == v for k, v in before.items())
                context = state(before, evidence)
                assert after['context'] == context
                request = dict(model=plan['requested_model'], state=context,
                               questions={k: question(k, evidence) for k in ('noul', 'score')})
                key = json.dumps(request, sort_keys=True)
                expected.add(key)
                response = by_request[key]['response']
                for kind in ('noul', 'score'):
                    assessment = after['assessments'][kind]
                    assert response['answers'][kind] == assessment['answer']
                    assert normalized_score(assessment['answer'], kind) == assessment['normalized_score']
            context, questions = wire_choice(original['candidates'], evidence)
            key = json.dumps(dict(model=plan['requested_model'], state=context, questions=questions), sort_keys=True)
            expected.add(key)
            assert by_request[key]['response']['answers']['reading'] == row['choice_answer']
            for method, text in choice_readings(row['candidates'], row['choice_answer']).items():
                assert row['readings'][method] == text
    assert expected == set(by_request)
    assert len(expected) == 2 * sum(len(r['candidates']) + 1 for r in data['rows'])
    assert sum(r['input_tokens'] for r in ok) == meta['input_tokens']
    module = importlib.util.spec_from_file_location('metrics', Path(__file__).with_name('evaluate-images.py'))
    metrics = importlib.util.module_from_spec(module)
    module.loader.exec_module(metrics)
    report = dict(request_response_audit='pass', successful_requests=len(ok),
                  other_attempts=len(calls) - len(ok), ranking={})
    for evidence, output in outputs.items():
        ranks = {kind: [] for kind in ('noul', 'score', 'choice')}
        for row in output['rows']:
            label = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
            truth = label.read_text().removesuffix('\n').removesuffix('\r')
            distances = [metrics.distance(truth, c['text']) for c in row['candidates']]
            for kind in ranks:
                values = [row['choice_answer']['probabilities'][c['text']] if kind == 'choice'
                          else c['assessments'][kind]['normalized_score'] for c in row['candidates']]
                exact_pairs, ordered_pairs = [], []
                for i, d in enumerate(distances):
                    for j, other in enumerate(distances):
                        if d >= other:
                            continue
                        value = float(values[i] > values[j]) + .5 * (values[i] == values[j])
                        ordered_pairs.append(value)
                        if d == 0:
                            exact_pairs.append(value)
                ranks[kind].append(dict(sample=row['sample'], label_sha256=sha(label),
                    exact_vs_imperfect_auroc=statistics.mean(exact_pairs) if exact_pairs else None,
                    lower_edit_distance_concordance=statistics.mean(ordered_pairs) if ordered_pairs else None))
        calls_in_arm = [r for r in ok if r['condition'] == evidence]
        report['ranking'][evidence] = {kind: dict(rows=rows,
            exact_reference_lines=sum(r['exact_vs_imperfect_auroc'] is not None for r in rows),
            macro_exact_auroc=statistics.mean(r['exact_vs_imperfect_auroc'] for r in rows
                                            if r['exact_vs_imperfect_auroc'] is not None),
            macro_edit_concordance=statistics.mean(r['lower_edit_distance_concordance'] for r in rows
                                                 if r['lower_edit_distance_concordance'] is not None))
            for kind, rows in ranks.items()}
        report['ranking'][evidence]['timing'] = dict(
            paired_assessment_median_seconds=statistics.median(r['latency_s'] for r in calls_in_arm
                                                               if 'noul' in r['request']['questions']),
            choice_median_seconds=statistics.median(r['latency_s'] for r in calls_in_arm
                                                     if 'reading' in r['request']['questions']))
    report['interpretation'] = ('Within-line, unweighted macro averages; exact-reference AUROC excludes '
        'lines with no exact candidate. Half credit for ties. Diagnostics on development data, '
        'not confidence calibration or independent validation. No threshold selected.')
    (root / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v if k != 'ranking' else {e: {m: {a: b for a, b in x.items() if a != 'rows'}
        for m, x in y.items()} for e, y in v.items()} for k, v in report.items()}, indent=2))


if __name__ == '__main__':
    main()
