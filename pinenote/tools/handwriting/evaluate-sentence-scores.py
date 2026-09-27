#!/usr/bin/env python3
"""Native Von/Laya Noul and Score on independent sentences; never opens labels."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import statistics
import time
from sentence_scoring import SentenceAssessor, WEIGHTS, checkpoint_files, normalized_score, question, select, state


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('candidates', type=Path)
    p.add_argument('weights', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--selector', required=True, choices=('von', 'laya'))
    p.add_argument('--evidence', choices=('stroke', 'text-only'), default='stroke')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', LAYA_CPU_AMP='')
    import torch
    import transformers
    torch.set_num_threads(8)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    spec = importlib.util.spec_from_file_location('common', Path(__file__).with_name('evaluate-von.py'))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    weight_hashes = {str(f.relative_to(args.weights)): common.sha(f)
                     for f in checkpoint_files(args.weights)}
    if not weight_hashes:
        raise ValueError('empty checkpoint')
    data = json.loads(args.candidates.read_text())
    start = time.perf_counter()
    assessor = SentenceAssessor(args.selector, args.weights)
    load_seconds = time.perf_counter() - start
    selector = assessor.selector
    assert next(selector.model.parameters()).device.type == 'cpu'
    sanity = []
    for text in ('Please put the kettle on.', 'Plxase pvt the kcttle on.',
                 'The train arrives before noon.', 'The traln arrlvesbefore n00n.'):
        context = state(dict(text=text, relative_stroke_probability=.5, stroke_loss_nats=0.), args.evidence)
        answers = {kind: assessor.evaluate(context, kind, args.evidence) for kind in ('noul', 'score')}
        sanity.append(dict(text=text, context=context, answers=answers,
            normalized={kind: normalized_score(answer, kind) for kind, answer in answers.items()}))
    (args.output / 'sanity.json').write_text(json.dumps(sanity, indent=2) + '\n')
    timings = {'noul': [], 'score': []}
    # Save an append-only trace throughout inference; final predictions precede
    # any scoring script opening references, and contain no labels.
    with (args.output / 'trace.jsonl').open('w') as trace:
        for row in data['rows']:
            for c in row['candidates']:
                c['context'] = state(c, args.evidence)
                c['assessments'] = {}
                for kind in ('noul', 'score'):
                    start = time.perf_counter()
                    answer = assessor.evaluate(c['context'], kind, args.evidence)
                    elapsed = time.perf_counter() - start
                    c['assessments'][kind] = dict(answer=answer,
                        normalized_score=normalized_score(answer, kind), seconds=elapsed)
                    timings[kind].append(elapsed)
                trace.write(json.dumps(dict(sample=row['sample'], **c)) + '\n')
                trace.flush()
            row['readings'] = dict(greedy=row['greedy_prediction'],
                                   previous=row['previous_prediction'], base=select(row['candidates']))
            for kind in ('noul', 'score'):
                row['readings'][kind + '_direct'] = select(row['candidates'], kind, direct=True)
                for weight in WEIGHTS:
                    row['readings'][f'{kind}_{weight:g}'] = select(row['candidates'], kind, weight)
            print(json.dumps(dict(sample=row['sample'], readings=row['readings'])), flush=True)
    (args.output / 'predictions.json').write_text(json.dumps(data, indent=2) + '\n')
    for file, digest in weight_hashes.items():
        if common.sha(args.weights / file) != digest:
            raise ValueError('checkpoint changed during inference')
    result = dict(selector=args.selector, evidence=args.evidence, version=selector.version, config=selector.config,
        weights=weight_hashes, weight_path=str(args.weights.resolve()),
        source_sha256={str(f): common.sha(f) for f in selector.source_files},
        candidate_sha256=common.sha(args.candidates), predictions_sha256=common.sha(args.output / 'predictions.json'),
        questions={kind: question(kind, args.evidence) for kind in ('noul', 'score')}, fusion_weights=WEIGHTS,
        fusion='base_score + weight * logit(assessment clipped to [0.0001,0.9999])',
        score_note='Noul API probability or ordinal expected level / 4; neither is calibrated HTR confidence',
        device='cpu', dtype=str(next(selector.model.parameters()).dtype), threads=8,
        model_parameters=sum(p.numel() for p in selector.model.parameters()),
        torch=torch.__version__, transformers=transformers.__version__, load_seconds=load_seconds,
        median_query_seconds={k: statistics.median(v) for k, v in timings.items()},
        median_line_seconds={k: statistics.median(sum(c['assessments'][k]['seconds']
            for c in r['candidates']) for r in data['rows']) for k in timings},
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    (args.output / 'metadata.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
