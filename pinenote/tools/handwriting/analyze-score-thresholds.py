#!/usr/bin/env python3
"""Post-hoc confidence gates: baseline fallback AND selective coverage metrics."""
import argparse
import importlib.util
import json
from pathlib import Path

FIELDS = ('confidence', 'answer_confidence', 'normalized_score')
GRID = (0, .05, .1, .15, .2, .25, .3, .35, .4, .45, .5, .6, .7, .8, .9, 1)


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def gated_rows(rows, field, threshold):
    return [dict(r, prediction=r['proposed'] if r[field] >= threshold else r['baseline']) for r in rows]


def point(rows, field, threshold, metrics, summary):
    gated = gated_rows(rows, field, threshold)
    eligible = [r for r in gated if r[field] >= threshold]
    changes = [r for r in gated if r['prediction'] != r['baseline']]
    deltas = [metrics.distance(r['truth'], r['baseline']) - metrics.distance(r['truth'], r['prediction'])
              for r in changes]
    return dict(threshold=threshold, accepted_changes=len(changes),
        improved_lines=sum(d > 0 for d in deltas), harmed_lines=sum(d < 0 for d in deltas),
        equal_error_changes=sum(d == 0 for d in deltas),
        accepted_samples=[r['sample'] for r in changes], full_corpus=metrics.scores(gated),
        lexical=summary.lexical_score(gated),
        selective=dict(lines=len(eligible), coverage=len(eligible) / len(rows),
                       scores=metrics.scores(eligible) if eligible else None))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('run', type=Path)
    p.add_argument('collection', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--methods', nargs='+', default=['score_8', 'score_direct'])
    args = p.parse_args()
    common = module('common', 'evaluate-von.py')
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    metadata = json.loads((args.run / 'metadata.json').read_text())
    if common.sha(args.run / 'predictions.json') != metadata['predictions_sha256']:
        raise ValueError('predictions changed')
    data = json.loads((args.run / 'predictions.json').read_text())
    results = {}
    for method in args.methods:
        rows = []
        for row in data['rows']:
            chosen = row['readings'][method]
            c = next(c for c in row['candidates'] if c['text'] == chosen)
            assessment = c['assessments']['score']
            label = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
            rows.append(dict(sample=row['sample'], baseline=row['readings']['base'], proposed=chosen,
                truth=label.read_text().removesuffix('\n').removesuffix('\r'), label_sha256=common.sha(label),
                confidence=assessment['answer']['confidence'],
                answer_confidence=assessment['answer']['answer_confidence'],
                normalized_score=assessment['normalized_score']))
        curves = {}
        for field in FIELDS:
            # Each observed value is an inclusive cutoff; also report simple
            # fixed grid points. These are post-hoc development diagnostics.
            thresholds = sorted(set(GRID) | {r[field] for r in rows})
            curves[field] = [point(rows, field, t, metrics, summary) for t in thresholds]
        results[method] = dict(rows=rows, curves=curves)
    args.output.mkdir(parents=True, exist_ok=False)
    result = dict(selector=metadata['selector'], evidence=metadata.get('evidence', 'stroke'),
        predictions_sha256=metadata['predictions_sha256'],
        gate='Use proposed text when selected candidate assessment >= threshold; otherwise keep character-LM baseline.',
        definitions=dict(confidence='1 - normalized entropy of the five ordinal category probabilities',
            answer_confidence='maximum probability of any ordinal category, not probability of a correct transcription',
            normalized_score='expected ordinal category / 4, a quality rating not confidence'),
        interpretation='All thresholds are explored on the same 19 development lines; no independent threshold validation.',
        methods=results)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    text = ['# Post-hoc ordinal-score threshold curves', '',
        '| Method | Field | Threshold | Accepted changes | Better / worse | Full-corpus CER | Selective lines | Selective CER |',
        '|---|---|---:|---:|---:|---:|---:|---:|']
    for method, data in results.items():
        for field, curve in data['curves'].items():
            best = min(p['full_corpus']['character_edits'] for p in curve)
            print(method, field, 'best development CER:', best / curve[0]['full_corpus']['characters'])
            for pt in curve:
                if pt['threshold'] not in GRID:
                    continue
                selective = pt['selective']['scores']
                selective_cer = f'{selective["cer"]:.2%}' if selective else '—'
                text.append(f'| {method} | {field} | {pt["threshold"]:g} | {pt["accepted_changes"]} | '
                    f'{pt["improved_lines"]} / {pt["harmed_lines"]} | {pt["full_corpus"]["cer"]:.2%} | '
                    f'{pt["selective"]["lines"]} | {selective_cer} |')
    (args.output / 'comparison.md').write_text('\n'.join(text) + '\n')


if __name__ == '__main__':
    main()
