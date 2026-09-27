#!/usr/bin/env python3
"""Post-selection diagnostics; uses labels and must never select predictions."""
import argparse
import json
from pathlib import Path


def oracle_edits(truth, original, spans):
    """Minimum Levenshtein distance over all permitted span combinations.

    A text lattice avoids enumerating the Cartesian product. At a branch merge,
    keep the best cost for each reference prefix, never blend candidate letters.
    """
    costs = list(range(len(truth) + 1))

    def advance(start, text):
        row = start
        for char in text:
            next_row = [row[0] + 1]
            for i, target in enumerate(truth, 1):
                next_row.append(min(next_row[-1] + 1, row[i] + 1,
                                    row[i - 1] + (char != target)))
            row = next_row
        return row

    cursor = 0
    for span in spans:
        costs = advance(costs, original[cursor:span['start']])
        texts = {span['original']}
        if span['ambiguous']:
            texts.update(o['text'] for o in span['options'])
        paths = [advance(costs, text) for text in texts]
        costs = [min(values) for values in zip(*paths)]
        cursor = span['end']
    return advance(costs, original[cursor:])[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidates', type=Path)
    parser.add_argument('runs', type=Path, nargs='+')
    args = parser.parse_args()
    candidates = json.loads(args.candidates.read_text())
    for run in args.runs:
        result = json.loads((run / 'results.json').read_text())
        rows = result['results']['original']['rows']
        if [r['sample'] for r in rows] != [r['sample'] for r in candidates['rows']]:
            raise ValueError('sample sets differ')
        distances = [oracle_edits(r['truth'], c['prediction'], c['spans'])
                     for r, c in zip(rows, candidates['rows'])]
        report = dict(oracle_diagnostic_only=dict(
            character_edits=sum(distances), cer=sum(distances) / sum(len(r['truth']) for r in rows),
            exact_lines_available=sum(d == 0 for d in distances)),
            candidate_counts={str(n): sum(s['ambiguous'] and len(s['options']) == n
                for r in candidates['rows'] for s in r['spans']) for n in range(2, 6)},
            metrics={n: {k: v for k, v in values.items() if k != 'rows'}
                     for n, values in result['results'].items()})
        (run / 'diagnostics.json').write_text(json.dumps(report, indent=2) + '\n')
        print(run, json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
