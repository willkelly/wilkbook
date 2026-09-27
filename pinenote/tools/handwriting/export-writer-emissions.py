#!/usr/bin/env python3
"""Reopen saved fold checkpoints and export only their held-out emissions."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
from adaptation import greedy


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pilot', 'collection', 'upstream', 'output'):
        p.add_argument(name, type=Path)
    args = p.parse_args()
    plan = json.loads((args.pilot / 'plan.json').read_text())
    for file, digest in plan['source_sha256'].items():
        assert sha(Path(file)) == digest
    for file, digest in plan['input_sha256'].items():
        assert sha(Path(file)) == digest
    args.output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(args.upstream.resolve()))
    import numpy as np
    import torch
    from src.data.transforms import Carbune2020, DictToTensor
    torch.set_num_threads(4)
    spec = importlib.util.spec_from_file_location('common', Path(__file__).with_name('evaluate-trajectories.py'))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    features = {}
    for file in sorted((args.collection / 'inkml').glob('line-*.inkml')):
        raw = common.read_ink(file)
        transformed = Carbune2020()(raw)
        assert np.count_nonzero(transformed['n']) == raw['stroke_nr'][-1] + 1
        features[file.stem.removeprefix('line-')] = DictToTensor(['x', 'y', 't', 'n'])(transformed)['ink'].unsqueeze(1)

    class Model(torch.nn.Module):
        def __init__(self, saved):
            super().__init__()
            a = saved['architecture']
            self.lstm_stack = torch.nn.LSTM(a['number_of_channels'], a['nodes_per_layer'],
                a['number_of_layers'], bidirectional=True)
            self.linear = torch.nn.Linear(2 * a['nodes_per_layer'], len(saved['alphabet']) + 1)
            self.load_state_dict(saved['state_dict'], strict=True)
            self.eval()

        def forward(self, ink):
            return torch.log_softmax(self.linear(self.lstm_stack(ink)[0]), dim=2)

    runs = sorted(p for p in args.pilot.iterdir() if p.is_dir() and (p / 'results.json').exists())
    control_path = args.pilot / 'head-seed-0/fold-1.pt'
    control = torch.load(control_path, weights_only=True)
    assert control['selected_epoch'] == 0
    baseline = json.loads((args.pilot / 'baseline.json').read_text())['rows']
    configurations = [('expanded-control', [(control_path, list(features))], baseline)]
    for run in runs:
        results = json.loads((run / 'results.json').read_text())
        configurations.append((run.name, [(run / f'fold-{page}.pt', group['test'])
                              for page, group in enumerate(plan['folds'])], results['rows']))
    with torch.inference_mode():
        for name, checkpoints, expected in configurations:
            expected = {r['sample']: r['prediction'] for r in expected}
            capture = args.output / name
            (capture / 'emissions').mkdir(parents=True)
            (capture / 'emissions/alphabet.json').write_text(json.dumps(plan['alphabet']) + '\n')
            rows, hashes = [], {}
            for file, samples in checkpoints:
                saved = torch.load(file, weights_only=True)
                assert saved['alphabet'] == plan['alphabet']
                if name != 'expanded-control':
                    assert saved['test'] == samples
                    assert not (set(samples) & (set(saved['train']) | set(saved['validation'])))
                model = Model(saved)
                hashes[str(file)] = sha(file)
                for sample in samples:
                    frames = model(features[sample])[:, 0]
                    text = greedy(frames, plan['alphabet'])
                    assert text == expected[sample], (name, sample)
                    np.savez_compressed(capture / 'emissions' / f'line-{sample}.npz', log_probs=frames.numpy())
                    rows.append(dict(sample=sample, prediction=text,
                        image_sha256=sha(args.collection / 'rendered' / f'line-{sample}.png'),
                        inkml_sha256=sha(args.collection / 'inkml' / f'line-{sample}.inkml')))
            rows.sort(key=lambda row: row['sample'])
            assert len(rows) == 19 and len({r['sample'] for r in rows}) == 19
            (capture / 'predictions.json').write_text(json.dumps(rows, indent=2) + '\n')
            (capture / 'metadata.json').write_text(json.dumps(dict(checkpoints=hashes,
                expanded_control=name == 'expanded-control', pilot_plan_sha256=sha(args.pilot / 'plan.json'),
                exporter_sha256=sha(Path(__file__))), indent=2) + '\n')
            print(name, 'PASS: reconstructed all 19 saved predictions', flush=True)


if __name__ == '__main__':
    main()
