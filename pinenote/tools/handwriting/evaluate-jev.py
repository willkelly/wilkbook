#!/usr/bin/env python3
"""Hosted Jev on frozen candidates; uses the existing jev/eval client, no labels."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time
from jev_scoring import assessment_questions, choice_spec, normalized_score, readings
from sentence_scoring import WEIGHTS, state


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('candidates', type=Path)
    p.add_argument('output', type=Path, help='new run directory, or same directory with --resume')
    p.add_argument('--jev-repo', required=True, type=Path, help='checkout containing jeveval and PROMPTING.md')
    p.add_argument('--model', default='jev-latest')
    p.add_argument('--smoke', action='store_true', help='synthetic compatibility requests only')
    p.add_argument('--resume', action='store_true', help='reuse successful requests verbatim')
    args = p.parse_args()
    sys.path.insert(0, str(args.jev_repo.resolve()))
    from jeveval import auth, config
    from jeveval.client import Call, JevClient
    from jeveval.wire import build_request
    if config.API_URL != 'https://api.typesafe.ai/v1/systemone':
        raise ValueError('this runner requires the hosted TypeSafe HTTPS endpoint')
    auth.get_api_key(allow_prompt=False)
    args.output.mkdir(parents=True, exist_ok=args.resume)
    sources = [Path(__file__), Path(__file__).with_name('jev_scoring.py'),
               Path(__file__).with_name('sentence_scoring.py'),
               Path(__file__).with_name('summarize-sentence-scores.py'),
               args.jev_repo / 'PROMPTING.md']
    sources += sorted((args.jev_repo / 'jeveval').glob('*.py'))
    plan = dict(candidate_sha256=sha(args.candidates), requested_model=args.model,
        smoke=args.smoke, evidence=['stroke', 'text-only'], weights=WEIGHTS,
        scalar_fusion='base_score + weight * logit(clipped assessment)',
        ordinal='native reported expected level / 4 (rounded to two decimals)',
        choice_fusion='base_score + weight * log(max(choice probability, 1e-6))',
        concurrency=4, source_sha256={str(f.resolve()): sha(f) for f in sources},
        endpoint=config.API_URL, usd_per_input_token=config.USD_PER_INPUT_TOKEN)
    # Fix candidates, prompts, code and settings before the first network call.
    plan_path = args.output / 'plan.json'
    if args.resume:
        if json.loads(plan_path.read_text()) != json.loads(json.dumps(plan)):
            raise ValueError('resume plan changed')
    else:
        write(plan_path, plan)
        (args.output / 'source').mkdir()
        for f in sources:
            shutil.copyfile(f, args.output / 'source' / f.name)
        shutil.copyfile(args.candidates, args.output / 'candidates.json')
    cache = {}
    log = args.output / 'calls.jsonl'
    if log.exists():
        for line in log.read_text().splitlines():
            record = json.loads(line)
            if record['outcome'] == 'ok':
                key = json.dumps(record['request'], sort_keys=True)
                if key in cache:
                    raise ValueError('duplicate successful request in cache')
                cache[key] = record
    data = json.loads(args.candidates.read_text())
    rate = config.RateConfig(start_concurrency=4, max_concurrency=4,
                             request_timeout=30, max_retries=3)
    started = time.monotonic()
    with JevClient(run_dir=args.output, model=args.model, rate=rate) as client:
        def ask(context, questions, evidence, sample):
            wire = build_request(state=context, questions=questions, model=args.model)
            key = json.dumps(wire, sort_keys=True)
            if key in cache:
                return cache[key]['response']
            result = client.call(Call(experiment='handwriting', condition=evidence,
                                     instance_id=sample, state=context, questions=questions))
            if not result.ok:
                raise RuntimeError(auth.redact(f'Jev failed: {result.error}'))
            return result.raw_response

        if args.smoke:
            candidates = [dict(text=text, base_score=0, relative_stroke_probability=.5,
                               stroke_loss_nats=0) for text in
                          ('Please put the kettle on.', 'Plxase pvt the kcttle on.')]
            for evidence in plan['evidence']:
                for c in candidates:
                    response = ask(state(c, evidence), assessment_questions(evidence), evidence, 'smoke')
                    values = {k: normalized_score(response['answers'][k], k) for k in ('noul', 'score')}
                    print(json.dumps(dict(evidence=evidence, text=c['text'], values=values,
                                          usage=response['usage'])), flush=True)
                context, questions = choice_spec(candidates, evidence)
                from jev_scoring import choice_readings
                response = ask(context, questions, evidence, 'smoke-choice')
                print(json.dumps(choice_readings(candidates, response['answers']['reading'])), flush=True)
        else:
            for evidence in plan['evidence']:
                output = args.output / evidence
                output.mkdir(exist_ok=args.resume)
                arm = json.loads(json.dumps(data))
                for row in arm['rows']:
                    def assess(c):
                        response = ask(state(c, evidence), assessment_questions(evidence), evidence, row['sample'])
                        c['context'] = state(c, evidence)
                        c['assessments'] = {k: dict(answer=response['answers'][k],
                            normalized_score=normalized_score(response['answers'][k], k))
                            for k in ('noul', 'score')}
                    with ThreadPoolExecutor(max_workers=4) as pool:
                        list(pool.map(assess, row['candidates']))
                    context, questions = choice_spec(row['candidates'], evidence)
                    response = ask(context, questions, evidence, row['sample'])
                    row['choice_answer'] = response['answers']['reading']
                    row['readings'] = readings(row)
                    print(json.dumps(dict(evidence=evidence, sample=row['sample'],
                                          readings=row['readings'])), flush=True)
                write(output / 'predictions.json', arm)
                write(output / 'metadata.json', dict(selector='jev', evidence=evidence,
                    candidate_sha256=plan['candidate_sha256'],
                    predictions_sha256=sha(output / 'predictions.json'), plan=plan))
    records = [json.loads(line) for line in log.read_text().splitlines()]
    ok = [r for r in records if r['outcome'] == 'ok']
    versions = sorted({r['model_version'] for r in ok})
    if len(versions) != 1 or not versions[0]:
        raise ValueError('missing or mixed returned model versions; do not pool this run')
    if any(sha(Path(f)) != digest for f, digest in plan['source_sha256'].items()):
        raise ValueError('source changed during inference')
    if sha(args.candidates) != plan['candidate_sha256']:
        raise ValueError('input changed during inference')
    tokens = sum(r['input_tokens'] for r in ok)
    metadata = dict(returned_models=versions, successful_requests=len(ok), attempts=len(records),
        input_tokens=tokens, cost_usd=tokens * config.USD_PER_INPUT_TOKEN,
        max_request_input_tokens=max(r['input_tokens'] for r in ok),
        elapsed_this_invocation_seconds=time.monotonic() - started,
        calls_sha256=sha(log), plan_sha256=sha(plan_path))
    write(args.output / 'metadata.json', metadata)
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
