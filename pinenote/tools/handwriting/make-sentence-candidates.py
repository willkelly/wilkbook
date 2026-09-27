#!/usr/bin/env python3
"""Freeze character-LM candidates with exact full-line CTC scores; no labels."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import time
from ctc_candidates import sequence_logp


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('predictions', type=Path, help='length-adjusted character-LM predictions.json, NOT results')
    p.add_argument('capture', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    import numpy as np
    spec = importlib.util.spec_from_file_location('common', Path(__file__).with_name('evaluate-von.py'))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    source = json.loads(args.predictions.read_text())
    alphabet_path = args.capture / 'emissions/alphabet.json'
    alphabet = json.loads(alphabet_path.read_text())
    rows = []
    for old in source:
        path = args.capture / 'emissions' / f'line-{old["sample"]}.npz'
        if common.sha(path) != old['emissions_sha256']:
            raise ValueError('emissions changed')
        with np.load(path, allow_pickle=False) as archive:
            frames = archive['log_probs'].tolist()
        start = time.perf_counter()
        candidates = []
        for c in old['candidates']:
            exact = sequence_logp(frames, c['text'], alphabet)
            if not math.isfinite(exact) or c['ctc_logp'] > exact + 1e-6:
                raise ValueError('invalid CTC mass')
            base = exact + .5 * c['language_score'] + .5 * len(c['text'])
            candidates.append(dict(text=c['text'], ctc_logp=exact,
                pruned_ctc_logp=c['ctc_logp'], character_lm_logp=c['language_score'], base_score=base))
        if len({c['text'] for c in candidates}) != len(candidates):
            raise ValueError('duplicate candidates')
        best = max(c['ctc_logp'] for c in candidates)
        mass = sum(math.exp(c['ctc_logp'] - best) for c in candidates)
        for c in candidates:
            c.update(relative_stroke_probability=math.exp(c['ctc_logp'] - best) / mass,
                     stroke_loss_nats=best - c['ctc_logp'])
        # Canonical order, with no original/rank IDs passed to the model.
        candidates.sort(key=lambda c: c['text'])
        rows.append(dict(sample=old['sample'], greedy_prediction=old['greedy_prediction'],
            previous_prediction=old['prediction'], candidates=candidates,
            rescore_seconds=time.perf_counter() - start,
            **{k: old[k] for k in ('image_sha256', 'inkml_sha256', 'emissions_sha256')}))
    args.output.mkdir(parents=True, exist_ok=False)
    result = dict(settings=dict(source_sha256=common.sha(args.predictions),
        alphabet_sha256=common.sha(alphabet_path),
        base_score='exact full-line CTC logp + 0.5 * character LM logp + 0.5 * character count',
        candidate_source='32 retained length-adjusted character 6-gram candidates; no new texts'), rows=rows)
    (args.output / 'candidates.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Frozen {len(rows)} lines, {sum(len(r["candidates"]) for r in rows)} candidates; labels unopened.')


if __name__ == '__main__':
    main()
