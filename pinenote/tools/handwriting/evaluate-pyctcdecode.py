#!/usr/bin/env python3
"""Decode frozen trajectory emissions with pyctcdecode and optional word KenLM."""
import argparse
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import platform
import resource
import statistics
import time

MODES = {'none': None,
         'default': dict(alpha=0.5, beta=1.5, unk_score_offset=-10.0),
         'conservative': dict(alpha=0.2, beta=0.0, unk_score_offset=-2.0)}
SEARCH = dict(beam_width=128, beam_prune_logp=-10.0, token_min_logp=-5.0, prune_history=False)


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('collection', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', choices=MODES, required=True)
    parser.add_argument('--lm', type=Path, help='directory from train-ctc-word-lm.py')
    args = parser.parse_args()
    if args.mode != 'none' and args.lm is None:
        parser.error('language-model modes need --lm')
    args.output.mkdir(parents=True, exist_ok=False)
    common = module('common', 'evaluate-von.py')
    import numpy as np
    from pyctcdecode import build_ctcdecoder
    from pyctcdecode.language_model import load_unigram_set_from_arpa
    alphabet = json.loads((args.capture / 'emissions/alphabet.json').read_text())
    labels = [''] + alphabet  # OnlineHTR has blank at frame-column zero.
    start = time.perf_counter()
    if args.mode == 'none':
        decoder = build_ctcdecoder(labels)
    else:
        decoder = build_ctcdecoder(labels,
            kenlm_model_path=str(args.lm / 'word-3gram.binary'),
            unigrams=load_unigram_set_from_arpa(str(args.lm / 'word-3gram.arpa')),
            **MODES[args.mode], lm_score_boundary=True)
    if decoder._alphabet.labels != labels:
        raise ValueError('decoder changed the emission alphabet')
    load_seconds = time.perf_counter() - start
    original = json.loads((args.capture / 'predictions.json').read_text())
    predictions = []
    for row in original:
        path = args.capture / 'emissions' / f'line-{row["sample"]}.npz'
        with np.load(path, allow_pickle=False) as archive:
            frames = archive['log_probs']
        greedy_ids = frames.argmax(axis=1).tolist()
        greedy = ''.join(labels[c] for i, c in enumerate(greedy_ids)
                         if c and (i == 0 or c != greedy_ids[i - 1]))
        if greedy != row['prediction']:
            raise ValueError('saved emissions do not reproduce frozen greedy text')
        start = time.perf_counter()
        beams = decoder.decode_beams(frames, **SEARCH)
        seconds = time.perf_counter() - start
        candidates = [dict(text=b[0], ctc_score=float(b[3]), combined_score=float(b[4]),
            word_frames=[dict(word=w, start=int(a), end=int(z)) for w, (a, z) in b[2]]) for b in beams[:32]]
        if not candidates:
            raise ValueError('empty decoding result')
        record = dict(sample=row['sample'], prediction=candidates[0]['text'],
            greedy_prediction=row['prediction'], seconds=seconds,
            image_sha256=row['image_sha256'], inkml_sha256=row['inkml_sha256'],
            emissions_sha256=common.sha(path), candidates=candidates)
        predictions.append(record)
        print(json.dumps({k: v for k, v in record.items() if k != 'candidates'}), flush=True)
    (args.output / 'predictions.json').write_text(json.dumps(predictions, indent=2) + '\n')
    # Reference labels are opened only after every hypothesis has been saved.
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    oracle_edits = exact_available = better = worse = 0
    for row in predictions:
        path = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
        truth = path.read_text().removesuffix('\n').removesuffix('\r')
        row.update(truth=truth, label_sha256=common.sha(path))
        delta = metrics.distance(truth, row['greedy_prediction']) - metrics.distance(truth, row['prediction'])
        better += delta > 0
        worse += delta < 0
        oracle_edits += min(metrics.distance(truth, c['text']) for c in row['candidates'])
        exact_available += any(c['text'] == truth for c in row['candidates'])
    result = dict(model='OnlineHTR + pyctcdecode ' + args.mode, mode=args.mode,
        search=SEARCH, lm_settings=MODES[args.mode], hotwords=[],
        lm_metadata=json.loads((args.lm / 'metadata.json').read_text()) if args.mode != 'none' else None,
        pyctcdecode=importlib.metadata.version('pyctcdecode'), kenlm=importlib.metadata.version('kenlm'),
        numpy=np.__version__, python=platform.python_version(), device='cpu',
        load_seconds=load_seconds, all_lines=metrics.scores(predictions),
        lexical=summary.lexical_score(predictions), lower_error_lines=better, higher_error_lines=worse,
        median_line_seconds=statistics.median(r['seconds'] for r in predictions),
        mean_line_seconds=statistics.mean(r['seconds'] for r in predictions),
        timing_note='decoder only; add recognizer inference separately',
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        oracle_diagnostic_only=dict(character_edits=oracle_edits,
            cer=oracle_edits / sum(len(r['truth']) for r in predictions), exact_lines_available=exact_available),
        rows=predictions)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2))


if __name__ == '__main__':
    main()
