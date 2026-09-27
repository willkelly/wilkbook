#!/usr/bin/env python3
"""Build a small KenLM control from public WikiText-2, without handwriting data."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('parquet', type=Path)
    parser.add_argument('kenlm_bin', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    import pyarrow.parquet as pq
    from sacremoses import MosesDetokenizer
    detokenizer = MosesDetokenizer(lang='en')
    paragraphs = []
    for raw in pq.read_table(args.parquet, columns=['text']).column('text').to_pylist():
        raw = raw.strip()
        if not raw or raw.startswith('='):
            continue
        # Undo WikiText's tokenization with a fixed, corpus-only procedure.
        for marker, punctuation in [('@-@', '-'), ('@,@', ','), ('@.@', '.')]:
            raw = raw.replace(' ' + marker + ' ', punctuation)
        text = detokenizer.detokenize(raw.split(), return_str=True)
        paragraphs.append(text)
    corpus = args.output / 'corpus.txt'
    corpus.write_text('\n'.join(paragraphs) + '\n')
    arpa = args.output / 'word-3gram.arpa'
    binary = args.output / 'word-3gram.binary'
    start = time.perf_counter()
    command = [str((args.kenlm_bin / 'lmplz').resolve()), '-o', '3', '--memory', '256M',
               '--text', str(corpus), '--arpa', str(arpa), '--temp_prefix', str(args.output / 'tmp')]
    with (args.output / 'train.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run([str((args.kenlm_bin / 'build_binary').resolve()), 'trie', str(arpa), str(binary)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    metadata = dict(dataset='Salesforce/wikitext', config='wikitext-2-raw-v1', split='train',
        revision='b08601e04326c79dfdd32d625aee71d232d685c3',
        dataset_sha256=hashlib.sha256(args.parquet.read_bytes()).hexdigest(),
        corpus_sha256=hashlib.sha256(corpus.read_bytes()).hexdigest(),
        paragraphs=len(paragraphs), words=sum(len(p.split()) for p in paragraphs),
        preprocessing='omit blank/header records; undo @-@ @,@ @.@; Moses English detokenization; preserve case',
        sacremoses=importlib.metadata.version('sacremoses'), pyarrow=importlib.metadata.version('pyarrow'),
        command=command, train_seconds=time.perf_counter() - start,
        arpa_sha256=hashlib.sha256(arpa.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), binary_bytes=binary.stat().st_size)
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
