#!/usr/bin/env python3
"""Compare fixed character-LM fusion settings on saved CTC emissions."""
import argparse
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import platform
import resource
import statistics
import time
from character_lm import CharacterLM, character_token
from ctc_candidates import beam_search

MODES = {'none': dict(alpha=0.0, beta=0.0),
         'light': dict(alpha=0.2, beta=0.0),
         'standard': dict(alpha=0.5, beta=0.0),
         'length': dict(alpha=0.5, beta=0.5)}
SEARCH = dict(width=128, token_top_k=8)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('collection', type=Path)
    parser.add_argument('lm', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', choices=MODES, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    common = module('common', 'evaluate-von.py')
    import numpy as np
    alphabet = json.loads((args.capture / 'emissions/alphabet.json').read_text())
    original = json.loads((args.capture / 'predictions.json').read_text())
    metadata = json.loads((args.lm / 'metadata.json').read_text())
    binary = args.lm / 'char-6gram.binary'
    if common.sha(binary) != metadata['binary_sha256']:
        raise ValueError('LM checksum mismatch')
    start = time.perf_counter()
    lm = CharacterLM(binary) if args.mode != 'none' else None
    load_seconds = time.perf_counter() - start
    rows = []
    for old in original:
        path = args.capture / 'emissions' / f'line-{old["sample"]}.npz'
        with np.load(path, allow_pickle=False) as archive:
            frames = archive['log_probs'].tolist()
        ids = [max(range(len(frame)), key=frame.__getitem__) for frame in frames]
        greedy = ''.join(alphabet[c - 1] for i, c in enumerate(ids)
                         if c and (i == 0 or c != ids[i - 1]))
        if greedy != old['prediction']:
            raise ValueError('emissions no longer match the frozen greedy prediction')
        start = time.perf_counter()
        candidates = beam_search(frames, alphabet, language_model=lm, **SEARCH, **MODES[args.mode])[:32]
        elapsed = time.perf_counter() - start
        row = dict(sample=old['sample'], prediction=candidates[0]['text'],
            greedy_prediction=greedy, seconds=elapsed, candidates=candidates,
            image_sha256=old['image_sha256'], inkml_sha256=old['inkml_sha256'],
            emissions_sha256=common.sha(path))
        rows.append(row)
        print(json.dumps({k: v for k, v in row.items() if k != 'candidates'}), flush=True)
    (args.output / 'predictions.json').write_text(json.dumps(rows, indent=2) + '\n')
    # Only score after all model outputs have been fixed and saved.
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    oracle_edits = exact_available = better = worse = 0
    for row in rows:
        path = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
        truth = path.read_text().removesuffix('\n').removesuffix('\r')
        row.update(truth=truth, label_sha256=common.sha(path))
        delta = metrics.distance(truth, row['greedy_prediction']) - metrics.distance(truth, row['prediction'])
        better += delta > 0
        worse += delta < 0
        oracle_edits += min(metrics.distance(truth, c['text']) for c in row['candidates'])
        exact_available += any(c['text'] == truth for c in row['candidates'])
    result = dict(model='OnlineHTR + character 6-gram ' + args.mode, mode=args.mode,
        search=SEARCH, lm_settings=MODES[args.mode], lm_metadata=metadata,
        lm_missing_alphabet_chars=[c for c in alphabet if character_token(c) not in lm.model] if lm else [],
        scoring='CTC log probability + alpha * character LM natural log probability including EOS + beta * character count',
        python=platform.python_version(), numpy=np.__version__, kenlm=importlib.metadata.version('kenlm'),
        device='cpu', load_seconds=load_seconds,
        all_lines=metrics.scores(rows), lexical=summary.lexical_score(rows),
        lower_error_lines=better, higher_error_lines=worse,
        median_line_seconds=statistics.median(r['seconds'] for r in rows),
        mean_line_seconds=statistics.mean(r['seconds'] for r in rows),
        timing_note='custom Python decoder only, not optimized or matched to pyctcdecode pruning',
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        oracle_diagnostic_only=dict(character_edits=oracle_edits,
            cer=oracle_edits / sum(len(r['truth']) for r in rows), exact_lines_available=exact_available),
        rows=rows)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2))


if __name__ == '__main__':
    main()
