#!/usr/bin/env python3
"""Run pinned OnlineHTR code/weights locally on exported InkML trajectories."""
import argparse
import collections
import functools
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import sys
import time
import typing
import xml.etree.ElementTree as ET

UPSTREAM_COMMIT = "a80693a2d278b16f91332a4d17e0bb47863cc183"
NS = "{http://www.w3.org/2003/InkML}"


def read_ink(path):
    """Ignore annotations; keep document stroke order, invert Y, convert ms to s."""
    root = ET.parse(path).getroot()
    channels = [(c.get("name"), c.get("units")) for c in root.findall(NS + "traceFormat/" + NS + "channel")]
    if channels != [("X", "dev"), ("Y", "dev"), ("T", "ms"), ("F", None), ("TX", None), ("TY", None)]:
        raise ValueError("expected notebook exporter X Y T(ms) F TX TY channels")
    sample = dict(x=[], y=[], t=[], stroke_nr=[], label="", sample_name=path.stem)
    previous = -math.inf
    for number, trace in enumerate(root.findall(NS + "trace")):
        if not trace.text or not trace.text.strip():
            raise ValueError("empty stroke")
        for point in trace.text.split(","):
            values = list(map(float, point.split()))
            if len(values) != 6 or not all(map(math.isfinite, values)):
                raise ValueError("invalid point")
            x, y, milliseconds, *_ = values
            if milliseconds < previous:
                raise ValueError("nonmonotonic recorded time")
            previous = milliseconds
            sample["x"].append(x)
            sample["y"].append(-y)
            sample["t"].append(milliseconds / 1000)
            sample["stroke_nr"].append(number)
    if not sample["x"] or max(sample["y"]) == min(sample["y"]):
        raise ValueError("empty or zero-height ink")
    return sample


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("collection", type=Path)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("weights", type=Path, help="unpacked model directory")
    parser.add_argument("output", type=Path, help="new directory")
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--save-emissions", action="store_true", help="retain frame log probabilities for decoder experiments")
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "-C", str(args.upstream), "rev-parse", "HEAD"], text=True).strip()
    if revision != UPSTREAM_COMMIT:
        raise ValueError("unexpected upstream revision")
    if subprocess.check_output(["git", "-C", str(args.upstream), "status", "--porcelain", "--untracked-files=no"]):
        raise ValueError("modified upstream code")
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
    from src.data.tokenisers import AlphabetMapper

    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    checkpoint = get_best_checkpoint_path(args.weights / "checkpoints")
    start = time.perf_counter()
    with torch.serialization.safe_globals([int, list, dict, set, torch.optim.Adam,
            AnyNode, ListConfig, GreedyCTCDecoder, ContainerMetadata,
            collections.defaultdict, Metadata, functools.partial, typing.Any]):
        saved = torch.load(checkpoint, map_location="cpu", weights_only=True)
    alphabet = load_alphabet(args.weights / "alphabet.json")
    assert alphabet == list(saved["hyper_parameters"]["alphabet"])
    if args.save_emissions:
        (args.output / "emissions").mkdir()
        (args.output / "emissions" / "alphabet.json").write_text(json.dumps(alphabet) + "\n")
    model = LitModule1(**saved["hyper_parameters"])
    model.load_state_dict(saved["state_dict"], strict=True)
    model.eval()
    decoder = saved["hyper_parameters"]["decoder"]
    mapper = AlphabetMapper(alphabet)
    load_s = time.perf_counter() - start
    transform, tensorize = Carbune2020(), DictToTensor(["x", "y", "t", "n"])
    rows = []
    with torch.inference_mode():
        # Shape-only warmup, not an evaluation line.
        model(torch.zeros(100, 1, 4))
        for path in sorted((args.collection / "inkml").glob("line-*.inkml")):
            start = time.perf_counter()
            sample = read_ink(path)
            transformed = transform(sample)
            if not isinstance(transformed, dict):
                raise ValueError(f"upstream rejected {path}")
            n_strokes = sample["stroke_nr"][-1] + 1
            starts = transformed["n"]
            if (np.count_nonzero(starts) != n_strokes
                    or not np.all(np.isin(starts, [0, 1]))):
                raise ValueError(f"upstream dropped or changed stroke boundaries: {path}")
            ink = tensorize(transformed)["ink"].unsqueeze(1)
            if not torch.isfinite(ink).all():
                raise ValueError("nonfinite features")
            emissions = model(ink)
            prediction = decoder(emissions, mapper)[0]
            elapsed = time.perf_counter() - start
            number = path.stem.removeprefix("line-")
            if args.save_emissions:
                np.savez_compressed(args.output / "emissions" / f"line-{number}.npz",
                                    log_probs=emissions[:, 0, :].numpy())
            row = dict(sample=number, prediction=prediction, seconds=elapsed,
                inkml_sha256=sha(path), image_sha256=sha(args.collection / "rendered" / f"line-{number}.png"),
                strokes=n_strokes, input_points=len(sample["x"]), model_points=len(ink))
            rows.append(row)
            print(json.dumps(row), flush=True)
    if not rows:
        raise ValueError("no InkML lines")
    (args.output / "predictions.json").write_text(json.dumps(rows, indent=2) + "\n")
    for row in rows:
        path = args.collection / "transcriptions" / (row["sample"] + ".txt")
        row["truth"] = path.read_text().removesuffix("\n").removesuffix("\r")
        row["label_sha256"] = sha(path)
        # Scoring-only consistency check of the embedded annotation.
        root = ET.parse(args.collection / "inkml" / f'line-{row["sample"]}.inkml').getroot()
        assert root.find(NS + "annotation[@type='truth']").text == row["truth"]
        row["out_of_alphabet"] = sorted(set(row["truth"]) - set(alphabet))
    spec = importlib.util.spec_from_file_location("metrics", Path(__file__).with_name("evaluate-images.py"))
    metrics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metrics)
    result = dict(model="OnlineHTR IAM-OnDB LSTM", revision=revision,
        checkpoint=checkpoint.name, checkpoint_sha256=sha(checkpoint),
        alphabet_sha256=sha(args.weights / "alphabet.json"),
        preprocessing="Upstream Carbune2020: height normalization, time interpolation at 20 points/unit path length, dx/dy/dt/stroke-start; Y up, seconds",
        decoder="upstream greedy CTC; no language model", threads=args.threads,
        device="cpu", dtype="torch.float32", torch=torch.__version__, numpy=np.__version__,
        python=platform.python_version(), platform=platform.platform(),
        parameters=sum(p.numel() for p in model.parameters()), load_seconds=load_s,
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        median_line_seconds=statistics.median(r["seconds"] for r in rows),
        mean_line_seconds=statistics.mean(r["seconds"] for r in rows),
        all_lines=metrics.scores(rows), rows=rows)
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
