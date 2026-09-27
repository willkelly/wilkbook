#!/usr/bin/env python3
"""Local Gemma code-block transcription; preserve whitespace, score labels last."""
import argparse
import ast
import base64
import csv
import hashlib
import io
import json
from pathlib import Path
import statistics
import subprocess
import time
from code_metrics import scores, text_payload
from gemma_selector import GemmaSelector

PROMPT = ('Transcribe this handwritten {language} code exactly as written. '
          'Preserve line breaks, indentation, spelling, case, numbers and every punctuation mark. '
          'Preserve missing or unmatched parentheses and other writing mistakes; do not repair '
          'or complete the code. Do not add a line that is not written. '
          'Return only the literal code, without Markdown fences or explanation.')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request(png, language):
    return dict(messages=[dict(role='user', content=[
        dict(type='image_url', image_url=dict(url='data:image/png;base64,' + base64.b64encode(png).decode())),
        dict(type='text', text=PROMPT.format(language=language))])],
        temperature=0, seed=0, max_tokens=512, cache_prompt=False,
        chat_template_kwargs=dict(enable_thinking=False))


def syntax(text, language):
    if language == 'Python':
        try:
            ast.parse(text)
            return dict(valid=True)
        except SyntaxError as error:
            return dict(valid=False, error=str(error))
    proc = subprocess.run(['guile', '--no-auto-compile', '-c',
        '(let loop () (unless (eof-object? (read)) (loop)))'], input=text,
        capture_output=True, text=True, timeout=5)
    return dict(valid=proc.returncode == 0, error=proc.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('collection', 'weights', 'projector', 'output'):
        p.add_argument(name, type=Path)
    p.add_argument('--llama-server', required=True, type=Path)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'responses').mkdir()
    from PIL import Image
    regions = list(csv.DictReader((args.collection / 'regions-reviewed.tsv').open(), delimiter='\t'))
    inputs = {r['sample']: sha(args.collection / 'rendered' / f'block-{r["sample"]}.png') for r in regions}
    sources = [Path(__file__), Path(__file__).with_name('code_metrics.py'), Path(__file__).with_name('gemma_selector.py')]
    plan = dict(prompt=PROMPT, model_files={str(f.resolve()): sha(f) for f in (args.weights, args.projector)},
        sources={str(f): sha(f) for f in sources}, images=inputs, max_tokens=512,
        output_processing='Remove one terminal CRLF/LF only; preserve leading/internal whitespace and unwanted prose',
        note='Indentation targets use the documented annotation convention, not measured keystrokes')
    (args.output / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    start = time.monotonic()
    runtime = GemmaSelector(args.weights, args.llama_server, args.output, projector=args.projector)
    load_seconds = time.monotonic() - start
    try:
        if not runtime.props['modalities']['vision']:
            raise ValueError('no vision')
        blank = io.BytesIO()
        Image.new('RGB', (1404, 360), 'white').save(blank, format='PNG')
        warm = runtime.request('/v1/chat/completions', request(blank.getvalue(), 'source'))
        (args.output / 'warmup.json').write_text(json.dumps(warm, indent=2) + '\n')
        rows = []
        for region in regions:
            sample = region['sample']
            path = args.collection / 'rendered' / f'block-{sample}.png'
            assert sha(path) == inputs[sample]
            body = request(path.read_bytes(), region['language'])
            start = time.monotonic()
            response = runtime.request('/v1/chat/completions', body)
            elapsed = time.monotonic() - start
            (args.output / 'responses' / f'{sample}.json').write_text(json.dumps(
                dict(request=body, response=response), indent=2) + '\n')
            if len(response['choices']) != 1 or response['choices'][0]['finish_reason'] != 'stop':
                raise ValueError('incomplete code response')
            raw = response['choices'][0]['message']['content']
            row = dict(sample=sample, language=region['language'], edited=region['action'] != 'copy',
                prediction=text_payload(raw), raw_prediction=raw, seconds=elapsed,
                image_sha256=inputs[sample], usage=response['usage'], timings=response.get('timings'))
            rows.append(row)
            print(json.dumps(row), flush=True)
        (args.output / 'predictions.json').write_text(json.dumps(rows, indent=2) + '\n')
    finally:
        rss = runtime.close()
    for row in rows:
        label = args.collection / 'transcriptions' / f'{row["sample"]}.txt'
        row.update(truth=text_payload(label.read_text()), label_sha256=sha(label))
        row['reference_syntax'] = syntax(row['truth'], row['language'])
        row['prediction_syntax'] = syntax(row['prediction'], row['language'])
    groups = dict(all=rows, edited=[r for r in rows if r['edited']],
                  unedited=[r for r in rows if not r['edited']],
                  python=[r for r in rows if r['language'] == 'Python'],
                  guile=[r for r in rows if r['language'] == 'Guile Scheme'])
    result = dict(groups={name: scores(group) for name, group in groups.items()}, rows=rows,
        median_block_seconds=statistics.median(r['seconds'] for r in rows),
        peak_server_rss_mib=rss, load_seconds=load_seconds, command=runtime.command,
        llama_version=runtime.version, plan=plan)
    for path, digest in plan['model_files'].items():
        assert sha(Path(path)) == digest
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('rows', 'plan', 'command')}, indent=2))


if __name__ == '__main__':
    main()
