#!/usr/bin/env python3
"""Local CPU Gemma vision transcription of ink-only PNGs; score labels last."""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import platform
import resource
import statistics
import time
from gemma_selector import GemmaSelector

PROMPT = ('Transcribe the handwritten text in this image exactly as written. '
          'Preserve spelling, capitalization, numbers, and punctuation; do not correct mistakes. '
          'Return only the transcription, with no explanation, added quotation marks, or Markdown.')


def image_request(png):
    return dict(messages=[dict(role='user', content=[
        dict(type='image_url', image_url=dict(url='data:image/png;base64,' + base64.b64encode(png).decode('ascii'))),
        dict(type='text', text=PROMPT)])],
        temperature=0, seed=0, max_tokens=128, cache_prompt=False,
        chat_template_kwargs=dict(enable_thinking=False))


def transcription(response):
    if len(response['choices']) != 1:
        raise ValueError('expected one transcription')
    choice = response['choices'][0]
    if choice['finish_reason'] not in ('stop', 'length'):
        raise ValueError('unexpected completion finish reason')
    text = choice['message']['content']
    if not isinstance(text, str):
        raise ValueError('missing transcription text')
    # Retain spelling, punctuation, internal whitespace and any unwanted prose.
    return text.strip(), choice['finish_reason'] == 'length'


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('collection', type=Path)
    parser.add_argument('weights', type=Path)
    parser.add_argument('projector', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--llama-server', type=Path, required=True)
    args = parser.parse_args()
    paths = sorted((args.collection / 'rendered').glob('line-*.png'))
    if not paths:
        raise ValueError('no line images')
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'responses').mkdir()
    from PIL import Image
    start = time.perf_counter()
    runtime = GemmaSelector(args.weights, args.llama_server, args.output, projector=args.projector)
    load_seconds = time.perf_counter() - start
    try:
        if not runtime.props['modalities']['vision']:
            raise ValueError('server did not enable vision')
        blank = io.BytesIO()
        Image.new('RGB', (1404, 240), 'white').save(blank, format='PNG')
        warm = runtime.request('/v1/chat/completions', image_request(blank.getvalue()))
        (args.output / 'warmup.json').write_text(json.dumps(warm, indent=2) + '\n')
        rows = []
        for path in paths:
            start = time.perf_counter()
            png = path.read_bytes()
            with Image.open(io.BytesIO(png)) as image:
                size = image.size
            request = image_request(png)
            response = runtime.request('/v1/chat/completions', request)
            seconds = time.perf_counter() - start
            sample = path.stem.removeprefix('line-')
            # Preserve even unexpected/truncated model output for diagnosis.
            (args.output / 'responses' / f'{sample}.json').write_text(
                json.dumps(dict(request=request, response=response), indent=2) + '\n')
            text, limited = transcription(response)
            row = dict(sample=sample, prediction=text, seconds=seconds,
                image_sha256=hashlib.sha256(png).hexdigest(), image_size=size,
                generated_tokens=response['usage']['completion_tokens'], hit_token_limit=limited,
                usage=response['usage'], timings=response.get('timings'))
            rows.append(row)
            print(json.dumps(row), flush=True)
        (args.output / 'predictions.json').write_text(json.dumps(rows, indent=2) + '\n')
    finally:
        server_rss = runtime.close()
    # Images and output are fixed before accessing reference transcriptions.
    metrics = module('metrics', 'evaluate-images.py')
    summary = module('summary', 'summarize-images.py')
    common = module('common', 'evaluate-von.py')
    for row in rows:
        data = (args.collection / 'transcriptions' / f'{row["sample"]}.txt').read_bytes()
        row['truth'] = data.decode('utf-8').removesuffix('\n').removesuffix('\r')
        row['label_sha256'] = hashlib.sha256(data).hexdigest()
        if not row['truth'] or '\n' in row['truth']:
            raise ValueError('expected nonempty single-line label')
    shared = [r for r in rows if r['sample'] != '20']
    result = dict(model='Gemma 4 E2B IT Q4_0 + BF16 vision projector',
        model_repo='ggml-org/gemma-4-E2B-it-GGUF',
        revision='b4243c156154b6dca9324415f8c7ccc098b4aed1',
        prompt=PROMPT, generation=dict(temperature=0, seed=0, max_tokens=128,
            enable_thinking=False, cache_prompt=False),
        preprocessing='Original PNG bytes; native llama.cpp multimodal preprocessing and image-token defaults',
        output_processing='strip outer whitespace only; preserve all other model output',
        python=platform.python_version(), platform=platform.platform(),
        llama_version=runtime.version, command=runtime.command, device='cpu', threads=8,
        load_seconds=load_seconds, peak_process_rss_mib=server_rss,
        measured_process='llama-server; client RSS reported separately',
        client_peak_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        median_line_seconds=statistics.median(r['seconds'] for r in rows),
        mean_line_seconds=statistics.mean(r['seconds'] for r in rows),
        all_lines=metrics.scores(rows), shared_trajectory_lines=metrics.scores(shared),
        lexical_all_lines=summary.lexical_score(rows), lexical_shared_lines=summary.lexical_score(shared),
        weights={p.name: common.sha(p) for p in (args.weights, args.projector)},
        source_sha256={str(p): common.sha(p) for p in [Path(__file__)] + runtime.source_files},
        rows=rows)
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2))


if __name__ == '__main__':
    main()
