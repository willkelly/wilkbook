#!/usr/bin/env python3
"""Train a pruned character 6-gram from the existing independent LM corpus."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
from character_lm import character_token


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('word_lm', type=Path, help='directory holding corpus.txt and metadata.json')
    parser.add_argument('kenlm_bin', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    text = (args.word_lm / 'corpus.txt').read_bytes()
    metadata = json.loads((args.word_lm / 'metadata.json').read_text())
    if hashlib.sha256(text).hexdigest() != metadata['corpus_sha256']:
        raise ValueError('source corpus changed')
    corpus = args.output / 'characters.txt'
    paragraphs = text.decode('utf-8').splitlines()
    with corpus.open('w') as stream:
        for paragraph in paragraphs:
            stream.write(' '.join(character_token(c) for c in paragraph) + '\n')
    arpa, binary = args.output / 'char-6gram.arpa', args.output / 'char-6gram.binary'
    command = [str((args.kenlm_bin / 'lmplz').resolve()), '-o', '6', '--memory', '256M',
        '--prune', '0', '0', '1', '1', '2', '2', '--text', str(corpus), '--arpa', str(arpa),
        '--temp_prefix', str(args.output / 'tmp')]
    start = time.perf_counter()
    with (args.output / 'train.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run([str((args.kenlm_bin / 'build_binary').resolve()), 'trie', str(arpa), str(binary)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    result = dict(source=metadata, source_corpus_sha256=hashlib.sha256(text).hexdigest(),
        character_corpus_sha256=hashlib.sha256(corpus.read_bytes()).hexdigest(),
        paragraphs=len(paragraphs), characters=sum(map(len, paragraphs)),
        encoding='one Unicode code point per Uxxxxxx token; space is U000020',
        order=6, prune_counts=[0, 0, 1, 1, 2, 2], command=command,
        train_seconds=time.perf_counter() - start,
        arpa_sha256=hashlib.sha256(arpa.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), binary_bytes=binary.stat().st_size)
    (args.output / 'metadata.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
