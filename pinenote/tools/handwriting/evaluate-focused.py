#!/usr/bin/env python3
"""Ask a local CPU selector about one ambiguous span, with stroke probabilities."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import statistics
import time
from focused_candidates import question_state, relative_probabilities, substitute
from focused_selectors import LayaSelector, VonSelector

QUESTION = "Which candidate best fills the gap? Use both the surrounding sentence and the supplied stroke-recognizer probabilities. Select only a supplied reading. Other words in the sentence may also have recognition errors."


def load_module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidates', type=Path)
    parser.add_argument('collection', type=Path)
    parser.add_argument('weights', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--selector', choices=['von', 'laya', 'gemma'], required=True)
    parser.add_argument('--llama-server', type=Path, help='CPU llama.cpp executable for Gemma')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    common = load_module('von_eval', 'evaluate-von.py')
    if args.selector != 'gemma':
        import torch
        import transformers
        torch.set_num_threads(8)
        torch.set_num_interop_threads(1)
        torch.manual_seed(0)
    data = json.loads(args.candidates.read_text())
    start = time.perf_counter()
    if args.selector == 'gemma':
        if args.llama_server is None:
            parser.error('--llama-server is required for Gemma')
        from gemma_selector import GemmaSelector
        selector = GemmaSelector(args.weights, args.llama_server, args.output)
        runtime = dict(device='cpu', dtype='GGUF mixed quantization; see server log', threads=8)
    else:
        selector = (VonSelector if args.selector == 'von' else LayaSelector)(args.weights)
        model = selector.model
        assert next(model.parameters()).device.type == 'cpu'
        runtime = dict(device='cpu', dtype=str(next(model.parameters()).dtype), threads=8,
            model_parameters=sum(p.numel() for p in model.parameters()),
            torch=torch.__version__, transformers=transformers.__version__)
    load_seconds = time.perf_counter() - start
    selector.evaluate('A red object.', 'Which color?', {'red': 'red', 'blue': 'blue'})
    methods = ['original', 'local_beam', 'selected', 'reverse', 'stable']
    query_times, line_times = [], []
    flips = 0
    for row in data['rows']:
        replacements = {name: [] for name in methods}
        row_times = []
        for span in row['spans']:
            original = span['original']
            readings = dict.fromkeys(methods, original)
            if span['ambiguous']:
                answers, contexts, choices, times = [], [], [], []
                for reverse in [False, True]:
                    state, options = question_state(span, reverse=reverse)
                    selector.validate(state, QUESTION, options)
                    start = time.perf_counter()
                    answer = selector.evaluate(state, QUESTION, options)
                    times.append(time.perf_counter() - start)
                    if args.selector != 'gemma':
                        common.validate_choice(answer, options)
                    answers.append(answer)
                    choices.append(options[answer['choice']])
                    contexts.append(dict(state=state, options=options))
                readings.update(local_beam=span['options'][0]['text'], selected=choices[0], reverse=choices[1],
                                stable=choices[0] if choices[0] == choices[1] else original)
                flips += choices[0] != choices[1]
                span.update(contexts=contexts, selector_answers=answers, chosen=choices, selector_seconds=times,
                            stroke_probabilities=relative_probabilities(span['options']))
                query_times.append(times[0])
                row_times.append(times[0])
                print(json.dumps(dict(sample=row['sample'], context=span['context'],
                    original=original, options=[o['text'] for o in span['options']],
                    stroke_probabilities=span['stroke_probabilities'], selected=choices,
                    seconds=times)), flush=True)
            for name in methods:
                replacements[name].append(readings[name])
        row['readings'] = {name: substitute(row['prediction'], row['spans'], parts)
                           for name, parts in replacements.items()}
        line_times.append(sum(row_times))
    (args.output / 'predictions.json').write_text(json.dumps(data, indent=2) + '\n')
    if args.selector == 'gemma':
        runtime['server_peak_rss_mib'] = selector.close()
    # Only now read labels. Selection contexts contain no template or truth.
    metrics = common.module('metrics', 'evaluate-images.py')
    summary = common.module('summary', 'summarize-images.py')
    rows = {name: [] for name in methods}
    for row in data['rows']:
        path = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
        truth = path.read_text().removesuffix('\n').removesuffix('\r')
        for name in methods:
            rows[name].append(dict(sample=row['sample'], truth=truth, prediction=row['readings'][name],
                image_sha256=row['image_sha256'], inkml_sha256=row['inkml_sha256'], label_sha256=common.sha(path)))
    results = {}
    for name, values in rows.items():
        deltas = [metrics.distance(a['truth'], a['prediction']) - metrics.distance(b['truth'], b['prediction'])
                  for a, b in zip(rows['original'], values)]
        results[name] = dict(raw=metrics.scores(values), lexical=summary.lexical_score(values),
            lower_error_lines=sum(d > 0 for d in deltas), higher_error_lines=sum(d < 0 for d in deltas),
            unchanged_error_lines=sum(d == 0 for d in deltas), rows=values)
    result = dict(settings=dict(**data['settings'], question=QUESTION,
        stroke_evidence='softmax of exact local CTC log probabilities across retained options, supplied in text',
        update_policy='all questions use frozen original context; substitutions applied simultaneously',
        stable_policy='apply only if forward and reversed presentations select identical text; otherwise retain original',
        **runtime, snapshot=args.weights.name,
        selector=args.selector, selector_version=selector.version, selector_config=selector.config,
        candidate_file_sha256=common.sha(args.candidates),
        source_sha256={str(f): common.sha(f) for f in selector.source_files},
        weights=({args.weights.name: common.sha(args.weights)} if args.weights.is_file() else
            {str(f.relative_to(args.weights)): common.sha(f) for f in args.weights.rglob('*')
             if f.is_file() and '.cache' not in f.relative_to(args.weights).parts})),
        words=sum(len(r['spans']) for r in data['rows']), questions=len(query_times),
        order_flips=flips, model_load_seconds=load_seconds,
        median_query_seconds=statistics.median(query_times) if query_times else 0,
        median_line_selector_seconds=statistics.median(line_times),
        median_line_candidates_seconds=statistics.median(r['candidate_seconds'] for r in data['rows']),
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        results=results)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v if k != 'results' else {name: {key: value for key, value in r.items() if key != 'rows'}
        for name, r in v.items()} for k, v in result.items()}, indent=2))
    text = [f'# Focused {args.selector}: one span, fixed context, stroke probabilities', '',
        '| Line | Truth | Original | Local beam | Selector | Reversed | Order-agreement gate |',
        '|---|---|---|---|---|---|---|']
    for i, row in enumerate(rows['original']):
        text.append('| ' + ' | '.join(summary.cell(v) for v in [row['sample'], row['truth']] +
                    [rows[name][i]['prediction'] for name in methods]) + ' |')
    (args.output / 'comparison.md').write_text('\n'.join(text) + '\n')


if __name__ == '__main__':
    main()
