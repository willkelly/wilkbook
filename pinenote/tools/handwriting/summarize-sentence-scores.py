#!/usr/bin/env python3
"""Score frozen independent sentence assessments, opening references only here."""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
from sentence_scoring import normalized_score, select, WEIGHTS


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('collection', type=Path)
    p.add_argument('runs', nargs='+', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    common = module('common', 'evaluate-von.py')
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    # Validate every frozen output before reading any reference.
    loaded = []
    for run in args.runs:
        meta = json.loads((run / 'metadata.json').read_text())
        if common.sha(run / 'predictions.json') != meta['predictions_sha256']:
            raise ValueError('predictions changed')
        data = json.loads((run / 'predictions.json').read_text())
        loaded.append((run, meta, data))
    if len({m['candidate_sha256'] for _, m, _ in loaded}) != 1:
        raise ValueError('different candidate inputs')
    output = {}
    lines = ['# Independent native Noul / Score sentence assessment', '',
        '| Model | Method | CER | Raw WER | Lexical WER | Exact | Better / worse vs previous |',
        '|---|---|---:|---:|---:|---:|---:|']
    for run, meta, data in loaded:
        name = meta['selector'] + '/' + meta.get('evidence', 'stroke')
        methods = {name: [] for name in data['rows'][0]['readings']}
        oracle_edits = oracle_exact = 0
        for row in data['rows']:
            sample = row['sample']
            path = args.collection / 'transcriptions' / f'{sample}.txt'
            truth = path.read_text().removesuffix('\n').removesuffix('\r')
            for c in row['candidates']:
                for kind, a in c['assessments'].items():
                    if abs(normalized_score(a['answer'], kind) - a['normalized_score']) > 1e-12:
                        raise ValueError('assessment mismatch')
            # Independently re-order to verify candidate presentation is absent
            # from the selection rule (not a claim about rubric/polarity bias).
            candidates = list(reversed(row['candidates']))
            if select(candidates) != row['readings']['base']:
                raise ValueError('base selection mismatch')
            for kind in ('noul', 'score'):
                for weight in WEIGHTS:
                    if select(candidates, kind, weight) != row['readings'][f'{kind}_{weight:g}']:
                        raise ValueError('fused selection mismatch')
                if select(candidates, kind, direct=True) != row['readings'][kind + '_direct']:
                    raise ValueError('direct selection mismatch')
            for method, text in row['readings'].items():
                methods[method].append(dict(sample=sample, truth=truth, prediction=text,
                    label_sha256=common.sha(path), image_sha256=row['image_sha256'],
                    inkml_sha256=row['inkml_sha256']))
            oracle_edits += min(metrics.distance(truth, c['text']) for c in candidates)
            oracle_exact += any(c['text'] == truth for c in candidates)
        results = {}
        for method, rows in methods.items():
            previous = methods['previous']
            deltas = [metrics.distance(r['truth'], old['prediction']) - metrics.distance(r['truth'], r['prediction'])
                      for r, old in zip(rows, previous)]
            results[method] = dict(raw=metrics.scores(rows), lexical=summary.lexical_score(rows),
                lower_error_lines=sum(d > 0 for d in deltas), higher_error_lines=sum(d < 0 for d in deltas),
                lost_exact_lines=sum(old['prediction'] == r['truth'] and r['prediction'] != r['truth']
                                     for old, r in zip(previous, rows)), rows=rows)
            r = results[method]
            lines.append(f'| {name} | {method} | {r["raw"]["cer"]:.2%} | '
                f'{r["raw"]["wer"]:.2%} | {r["lexical"]["wer"]:.2%} | {r["raw"]["exact"]}/19 | '
                f'{r["lower_error_lines"]} / {r["higher_error_lines"]} |')
        characters = results['base']['raw']['characters']
        assessment_ranges = {kind: dict(
            min=min(c['assessments'][kind]['normalized_score'] for r in data['rows'] for c in r['candidates']),
            max=max(c['assessments'][kind]['normalized_score'] for r in data['rows'] for c in r['candidates']),
            median_within_line_range=statistics.median(
                max(c['assessments'][kind]['normalized_score'] for c in r['candidates']) -
                min(c['assessments'][kind]['normalized_score'] for c in r['candidates']) for r in data['rows']))
            for kind in ('noul', 'score')}
        if name in output:
            raise ValueError('duplicate model/evidence run')
        output[name] = dict(metadata=meta, results=results, assessment_ranges=assessment_ranges,
            oracle_diagnostic_only=dict(character_edits=oracle_edits, cer=oracle_edits / characters,
                                        exact_lines_available=oracle_exact))
        # Keep every method in the private side-by-side, rather than cherry-pick.
        comparison = ['| Line | Truth | ' + ' | '.join(methods) + ' |',
                      '|---|---|' + '---|' * len(methods)]
        for i, row in enumerate(methods['base']):
            comparison.append('| ' + ' | '.join(summary.cell(x) for x in
                [row['sample'], row['truth']] + [rows[i]['prediction'] for rows in methods.values()]) + ' |')
        (run / 'comparison.md').write_text('\n'.join(comparison) + '\n')
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'results.json').write_text(json.dumps(output, indent=2) + '\n')
    (args.output / 'comparison.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
