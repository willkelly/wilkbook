#!/usr/bin/env python3
"""CPU-only Von selection among fixed CTC hypotheses; score labels afterwards."""
import argparse
import hashlib
import importlib.metadata
import importlib.util
import inspect
import json
import math
import os
from pathlib import Path
import resource
import statistics
import time
from ctc_candidates import rerank

STATE = "A handwriting recognizer produced alternative readings of one English line. The intended text is unknown. Some alternatives contain letter recognition errors."
QUESTION = "Which proposed reading makes the most sense in its sentence context? Select only from the supplied readings."


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def validate_choice(answer, options):
    if answer['choice'] not in options or set(answer['probabilities']) != set(options):
        raise ValueError('Von returned unknown or missing candidates')
    probabilities = answer['probabilities']
    if any(not math.isfinite(v) or v < 0 or v > 1 for v in probabilities.values()):
        raise ValueError('invalid Von probability')
    if abs(sum(probabilities.values()) - 1) > len(options) * 0.0001:
        raise ValueError('Von probability mass mismatch')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('candidates', type=Path)
    p.add_argument('collection', type=Path)
    p.add_argument('weights', type=Path, help='existing pinned local Von snapshot')
    p.add_argument('output', type=Path, help='new directory')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    import torch
    import transformers
    from von.backends.option_marker_backend import OptionMarkerBackend
    from von.types import Choice
    torch.set_num_threads(8)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    data = json.loads(args.candidates.read_text())
    backend = OptionMarkerBackend(checkpoint_dir=str(args.weights.resolve()), device='cpu')
    started = time.perf_counter()
    model = backend._get_model()
    model_load_s = time.perf_counter() - started
    assert next(model.parameters()).device.type == 'cpu'
    backend.evaluate_choice('warmup', 'A red object.', Choice(type='choice',
        instructions='Which color?', criteria={'red': 'red', 'blue': 'blue'}))
    predictions = []
    for row in data['rows']:
        options = {f'c{i:02d}': c['text'] for i, c in enumerate(row['candidates'])}
        if not options:
            raise ValueError('empty candidate set')
        packed = model.pack_sequence(STATE, QUESTION, list(options.values()))
        token_ids = model.tokenizer(packed)['input_ids']
        if len(token_ids) > model.encoder.config.max_position_embeddings:
            raise ValueError('candidate set exceeds model context')
        if token_ids.count(model.mask_token_id) != len(options):
            raise ValueError('unexpected option marker count')
        answers, timings = [], []
        for criteria in (options, dict(reversed(list(options.items())))):
            start = time.perf_counter()
            answer = backend.evaluate_choice('reading', STATE,
                Choice(type='choice', instructions=QUESTION, criteria=criteria)).model_dump()
            timings.append(time.perf_counter() - start)
            validate_choice(answer, options)
            answers.append(answer)
        # Von's public API rounds probabilities to four decimals. The floor is
        # explicit; these are scoring heuristics, not calibrated HTR confidence.
        fused = []
        for answer in answers:
            language = [math.log(max(answer['probabilities'][key], 1e-6)) for key in options]
            fused.append(rerank(row['candidates'], language, weight=0.2)[0]['text'])
        record = dict(row, von_answers=answers, von_seconds=timings,
            von_prediction=options[answers[0]['choice']],
            von_reverse_prediction=options[answers[1]['choice']],
            fused_prediction=fused[0], fused_reverse_prediction=fused[1],
            packed_tokens=len(token_ids))
        predictions.append(record)
        print(json.dumps(dict(sample=row['sample'], von=record['von_prediction'],
            fused=fused[0], reverse=record['von_reverse_prediction'],
            order_flip=answers[0]['choice'] != answers[1]['choice'], seconds=timings)), flush=True)
    (args.output / 'predictions.json').write_text(json.dumps(predictions, indent=2) + '\n')
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    methods = ['greedy', 'beam', 'von', 'fused', 'von_reverse', 'fused_reverse']
    rows = {method: [] for method in methods}
    oracle_edits = exact_available = 0
    for r in predictions:
        label = args.collection / 'transcriptions' / f'{r["sample"]}.txt'
        truth = label.read_text().removesuffix('\n').removesuffix('\r')
        oracle_edits += min(metrics.distance(truth, c['text']) for c in r['candidates'])
        exact_available += any(truth == c['text'] for c in r['candidates'])
        for method in methods:
            text = r['prediction'] if method == 'greedy' else (
                r['candidates'][0]['text'] if method == 'beam' else r[f'{method}_prediction'])
            rows[method].append(dict(sample=r['sample'], truth=truth, prediction=text,
                image_sha256=r['image_sha256'], inkml_sha256=r['inkml_sha256'], label_sha256=sha(label)))
    results = {method: dict(raw=metrics.scores(values), lexical=summary.lexical_score(values), rows=values)
               for method, values in rows.items()}
    result = dict(settings=dict(**data['settings'], state=STATE, question=QUESTION,
        combination='CTC logp + 0.2 * log(max(Von probability, 1e-6))',
        probability_note='API values rounded to four decimals; confidence is top-two margin, not HTR calibration',
        device='cpu', dtype=str(next(model.parameters()).dtype), threads=8,
        model_parameters=sum(v.numel() for v in model.parameters()),
        torch=torch.__version__, transformers=transformers.__version__,
        von=importlib.metadata.version('von-sdk'), model_load_seconds=model_load_s,
        snapshot=args.weights.name, candidate_file_sha256=sha(args.candidates),
        backend_source_sha256=sha(Path(inspect.getfile(OptionMarkerBackend))),
        model_source_sha256=sha(Path(inspect.getfile(type(model)))),
        weights={f.name: sha(f) for f in args.weights.iterdir() if f.is_file()}),
        median_beam_seconds=statistics.median(r['beam_seconds'] for r in predictions),
        median_von_seconds=statistics.median(r['von_seconds'][0] for r in predictions),
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        von_order_flips=sum(r['von_prediction'] != r['von_reverse_prediction'] for r in predictions),
        fused_order_flips=sum(r['fused_prediction'] != r['fused_reverse_prediction'] for r in predictions),
        oracle_diagnostic_only=dict(character_edits=oracle_edits,
            cer=oracle_edits / sum(len(r['truth']) for r in rows['greedy']),
            exact_lines_available=exact_available), results=results)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v if k != 'results' else {m: {a: b for a, b in r.items() if a != 'rows'}
        for m, r in v.items()} for k, v in result.items()}, indent=2))
    text = ['# Von candidate selection: CPU, frozen settings, 19 lines', '',
        '| Line | Truth | Greedy | Beam | Von choice | Stroke + Von |', '|---|---|---|---|---|---|']
    for i, row in enumerate(rows['greedy']):
        text.append('| ' + ' | '.join(summary.cell(v) for v in [row['sample'], row['truth'],
            row['prediction'], rows['beam'][i]['prediction'], rows['von'][i]['prediction'],
            rows['fused'][i]['prediction']]) + ' |')
    (args.output / 'comparison.md').write_text('\n'.join(text) + '\n')


if __name__ == '__main__':
    main()
