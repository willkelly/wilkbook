#!/usr/bin/env python3
"""Generate local ambiguity questions from emissions without reading labels."""
import argparse
import hashlib
import json
from pathlib import Path
import time
from focused_candidates import word_windows, options_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    import numpy as np
    alphabet = json.loads((args.capture / 'emissions/alphabet.json').read_text())
    rows = json.loads((args.capture / 'predictions.json').read_text())
    for row in rows:
        path = args.capture / 'emissions' / f'line-{row["sample"]}.npz'
        with np.load(path, allow_pickle=False) as data:
            frames = data['log_probs'].tolist()
        started = time.perf_counter()
        text, spans = word_windows(frames, alphabet)
        assert text == row['prediction']
        for span in spans:
            span['options'], span['ambiguous'] = options_for(
                frames[span['frame_start']:span['frame_end']], alphabet, span['original'])
        row['spans'] = spans
        row['candidate_seconds'] = time.perf_counter() - started
        row['emissions_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        print(json.dumps(dict(sample=row['sample'], words=len(spans),
            questions=sum(s['ambiguous'] for s in spans), seconds=row['candidate_seconds'])), flush=True)
    result = dict(settings=dict(beam_width=64, frame_top_k=8, max_options=5,
        max_ctc_loss_nats=5, ambiguity_top_two_gap='<= ln(10)',
        candidate_scores='exact local CTC forward probability',
        context='unchanged original greedy line with only the current span replaced by ___'), rows=rows)
    (args.output / 'candidates.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
