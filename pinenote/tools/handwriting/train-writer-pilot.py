#!/usr/bin/env python3
"""CPU OnlineHTR adaptation: 5 page-disjoint folds, 3 policies, 3 fixed seeds."""
import argparse
import collections
import copy
import functools
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import statistics
import subprocess
import sys
import time
import typing
from adaptation import MAX_EPOCHS, PATIENCE, POLICIES, SEEDS, encode, expanded_alphabet, greedy, split, trainable


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('collection', 'upstream', 'weights', 'baseline', 'output'):
        p.add_argument(name, type=Path)
    args = p.parse_args()
    common = module('trajectories', 'evaluate-trajectories.py')
    metrics = module('metrics', 'evaluate-images.py')
    assert subprocess.check_output(['git', '-C', str(args.upstream), 'rev-parse', 'HEAD'], text=True).strip() == common.UPSTREAM_COMMIT
    assert not subprocess.check_output(['git', '-C', str(args.upstream), 'status', '--porcelain', '--untracked-files=no'])
    args.output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(args.upstream.resolve()))
    import numpy as np
    import torch
    from omegaconf.nodes import AnyNode
    from omegaconf.listconfig import ListConfig
    from omegaconf.base import ContainerMetadata, Metadata
    from src.models.carbune_module import LitModule1
    from src.data.transforms import Carbune2020, DictToTensor
    from src.utils.decoders import GreedyCTCDecoder
    from src.utils.io import get_best_checkpoint_path, load_alphabet
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    torch.use_deterministic_algorithms(True)
    checkpoint = get_best_checkpoint_path(args.weights / 'checkpoints')
    with torch.serialization.safe_globals([int, list, dict, set, torch.optim.Adam,
            AnyNode, ListConfig, GreedyCTCDecoder, ContainerMetadata,
            collections.defaultdict, Metadata, functools.partial, typing.Any]):
        saved = torch.load(checkpoint, map_location='cpu', weights_only=True)
    original = load_alphabet(args.weights / 'alphabet.json')
    assert original == list(saved['hyper_parameters']['alphabet'])
    alphabet = expanded_alphabet(original)
    base = LitModule1(**saved['hyper_parameters'])
    base.load_state_dict(saved['state_dict'], strict=True)
    base.eval()
    paths = sorted((args.collection / 'inkml').glob('line-*.inkml'))
    samples = [p.stem.removeprefix('line-') for p in paths]
    assert samples == [f'{i:02}' for i in range(1, 20)]
    old = {r['sample']: r for r in json.loads(args.baseline.read_text())['rows']}
    folds = [split(samples, page) for page in range(5)]
    sources = [Path(__file__), Path(__file__).with_name('adaptation.py'),
               Path(__file__).with_name('evaluate-trajectories.py')]
    sources += sorted((args.upstream / 'src').rglob('*.py'))
    inputs = paths + [args.collection / 'transcriptions' / f'{s}.txt' for s in samples]
    plan = dict(policies=POLICIES, seeds=SEEDS, max_epochs=MAX_EPOCHS, patience=PATIENCE,
        validation='minimum held-out validation-page mean CTC loss; epoch zero eligible; test page never selects checkpoint',
        folds=folds, original_alphabet=original, alphabet=alphabet,
        new_symbol_initialization='zero weights, bias -20; preserve all old rows including blank',
        optimizer='Adam, no weight decay, per-line batches, gradient norm clip 1.0',
        new_data='No code blocks or later-session pages enter training or selection',
        interpretation='Development cross-validation on repeatedly examined same-session prose, not fresh-session qualification',
        checkpoint_sha256=sha(checkpoint), baseline_sha256=sha(args.baseline),
        input_sha256={str(f): sha(f) for f in inputs}, source_sha256={str(f): sha(f) for f in sources},
        torch=torch.__version__, numpy=np.__version__, threads=4, device='cpu')
    write(args.output / 'plan.json', plan)
    features, labels, targets = {}, {}, {}
    transform, tensorize = Carbune2020(), DictToTensor(['x', 'y', 't', 'n'])
    baseline_rows = []
    with torch.inference_mode():
        for path, sample in zip(paths, samples):
            raw = common.read_ink(path)
            transformed = transform(raw)
            assert isinstance(transformed, dict)
            assert np.count_nonzero(transformed['n']) == raw['stroke_nr'][-1] + 1
            features[sample] = tensorize(transformed)['ink'].unsqueeze(1)
            assert torch.isfinite(features[sample]).all()
            # Reproduce the original model before any change, using exact inputs.
            prediction = greedy(base(features[sample])[:, 0], original)
            assert prediction == old[sample]['prediction'], sample
            assert sha(path) == old[sample]['inkml_sha256']
            label = args.collection / 'transcriptions' / f'{sample}.txt'
            assert sha(label) == old[sample]['label_sha256']
            labels[sample] = label.read_text().removesuffix('\n').removesuffix('\r')
            targets[sample] = torch.tensor(encode(labels[sample], alphabet), dtype=torch.long)
            # Explicitly reject impossible CTC alignments, rather than masking
            # an infinite loss through zero_infinity.
            needed = len(targets[sample]) + sum(a == b for a, b in zip(labels[sample], labels[sample][1:]))
            assert features[sample].shape[0] >= needed
            baseline_rows.append(dict(sample=sample, truth=labels[sample], prediction=prediction))
    write(args.output / 'baseline.json', dict(scores=metrics.scores(baseline_rows), rows=baseline_rows))
    old_linear = base.linear
    base.linear = torch.nn.Linear(old_linear.in_features, len(alphabet) + 1)
    with torch.no_grad():
        base.linear.weight.zero_()
        base.linear.bias.fill_(-20)
        base.linear.weight[:len(original)+1].copy_(old_linear.weight)
        base.linear.bias[:len(original)+1].copy_(old_linear.bias)
    with torch.inference_mode():
        for row in baseline_rows:
            assert greedy(base(features[row['sample']])[:, 0], alphabet) == row['prediction']
    # Feature tensors created in inference_mode cannot be saved for backward.
    features = {key: value.clone() for key, value in features.items()}
    targets = {key: value.clone() for key, value in targets.items()}
    loss_fn = torch.nn.CTCLoss(blank=0, reduction='mean', zero_infinity=False)

    def loss(model, sample):
        output = model(features[sample])
        return loss_fn(output, targets[sample], [len(output)], [len(targets[sample])])

    def validation(model, names):
        model.eval()
        with torch.no_grad():
            return statistics.mean(loss(model, name).item() for name in names)

    results = {}
    started = time.monotonic()
    for policy, learning_rate in POLICIES.items():
        for seed in SEEDS:
            out = args.output / f'{policy}-seed-{seed}'
            out.mkdir()
            test_rows, diagnostics = [], []
            for page, groups in enumerate(folds):
                torch.manual_seed(seed)
                rng = random.Random(seed)
                model = copy.deepcopy(base)
                for name, param in model.named_parameters():
                    param.requires_grad_(trainable(name, policy, model.lstm_stack.num_layers))
                parameters = [p for p in model.parameters() if p.requires_grad]
                optimizer = torch.optim.Adam(parameters, lr=learning_rate)
                best_loss = validation(model, groups['validation'])
                best_state = copy.deepcopy(model.state_dict())
                best_epoch, stale = 0, 0
                history = [dict(epoch=0, validation_ctc=best_loss)]
                for epoch in range(1, MAX_EPOCHS + 1):
                    model.train()
                    if policy == 'head':
                        model.lstm_stack.eval()
                    order = list(groups['train'])
                    rng.shuffle(order)
                    losses = []
                    for sample in order:
                        optimizer.zero_grad(set_to_none=True)
                        value = loss(model, sample)
                        if not torch.isfinite(value):
                            raise ValueError('nonfinite training loss')
                        value.backward()
                        torch.nn.utils.clip_grad_norm_(parameters, 1.0, error_if_nonfinite=True)
                        optimizer.step()
                        losses.append(value.item())
                    score = validation(model, groups['validation'])
                    history.append(dict(epoch=epoch, train_ctc=statistics.mean(losses), validation_ctc=score))
                    if score < best_loss:
                        best_loss, best_epoch, stale = score, epoch, 0
                        best_state = copy.deepcopy(model.state_dict())
                    else:
                        stale += 1
                    if stale >= PATIENCE:
                        break
                model.load_state_dict(best_state)
                model.eval()
                with torch.no_grad():
                    for sample in groups['test']:
                        test_rows.append(dict(sample=sample, truth=labels[sample],
                            prediction=greedy(model(features[sample])[:, 0], alphabet)))
                torch.save(dict(state_dict=best_state, alphabet=alphabet,
                    architecture=dict(nodes_per_layer=model.lstm_stack.hidden_size,
                        number_of_layers=model.lstm_stack.num_layers,
                        number_of_channels=model.lstm_stack.input_size),
                    train=groups['train'], validation=groups['validation'], test=groups['test'],
                    policy=policy, seed=seed, selected_epoch=best_epoch), out / f'fold-{page}.pt')
                diagnostics.append(dict(page=page, groups=groups, selected_epoch=best_epoch,
                    trainable_parameters=sum(p.numel() for p in parameters), history=history))
                print(json.dumps(dict(policy=policy, seed=seed, page=page,
                                      selected_epoch=best_epoch, epochs_run=epoch)), flush=True)
            test_rows.sort(key=lambda row: row['sample'])
            assert [r['sample'] for r in test_rows] == samples
            deltas = [metrics.distance(a['truth'], a['prediction']) - metrics.distance(b['truth'], b['prediction'])
                      for a, b in zip(baseline_rows, test_rows)]
            result = dict(scores=metrics.scores(test_rows), rows=test_rows, folds=diagnostics,
                          improved_lines=sum(d > 0 for d in deltas), harmed_lines=sum(d < 0 for d in deltas))
            write(out / 'results.json', result)
            results[f'{policy}-seed-{seed}'] = {k: v for k, v in result.items() if k not in ('rows', 'folds')}
            print(json.dumps(dict(run=f'{policy}-seed-{seed}', **results[f'{policy}-seed-{seed}'])), flush=True)
    for path, digest in plan['input_sha256'].items():
        assert sha(Path(path)) == digest
    assert sha(checkpoint) == plan['checkpoint_sha256']
    write(args.output / 'results.json', dict(baseline=metrics.scores(baseline_rows), runs=results,
        seconds=time.monotonic()-started, original_parameters=sum(p.numel() for p in base.parameters()) -
            (len(alphabet)-len(original)) * (base.linear.in_features+1),
        expanded_parameters=sum(p.numel() for p in base.parameters()), new_symbols=alphabet[len(original):]))


if __name__ == '__main__':
    main()
