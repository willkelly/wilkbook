#!/usr/bin/env python3
"""Host-only TrOCR baseline. Infer from ink PNGs before opening any labels."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import time


MODELS = {
    "small": ("microsoft/trocr-small-handwritten", "b4648cfa171985a6745f37ddd637e98c0da958ac"),
    "base": ("microsoft/trocr-base-handwritten", "eaacaf452b06415df8f10bb6fad3a4c11e609406"),
}


def distance(a, b):
    """Levenshtein distance over Unicode characters or whitespace-delimited words."""
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1):
            row.append(min(row[-1] + 1, prev[j] + 1, prev[j - 1] + (x != y)))
        prev = row
    return prev[-1]


def scores(rows):
    chars = sum(len(r["truth"]) for r in rows)
    words = sum(len(r["truth"].split()) for r in rows)
    ce = sum(distance(r["truth"], r["prediction"]) for r in rows)
    we = sum(distance(r["truth"].split(), r["prediction"].split()) for r in rows)
    return dict(lines=len(rows), exact=sum(r["truth"] == r["prediction"] for r in rows),
                character_edits=ce, characters=chars, cer=ce / chars,
                word_edits=we, words=words, wer=we / words)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("collection", type=Path)
    parser.add_argument("output", type=Path, help="new directory, refuses overwrite")
    parser.add_argument("--model", choices=MODELS, required=True)
    parser.add_argument("--threads", type=int, default=8)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    import torch
    import transformers
    from PIL import Image
    from huggingface_hub import snapshot_download
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel

    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    model_id, revision = MODELS[args.model]
    start = time.perf_counter()
    snapshot = Path(snapshot_download(model_id, revision=revision,
        allow_patterns=["*.json", "*.txt", "*.model", "*.safetensors", "pytorch_model.bin"]))
    download_s = time.perf_counter() - start
    start = time.perf_counter()
    processor = TrOCRProcessor.from_pretrained(snapshot, local_files_only=True, use_fast=False)
    model = VisionEncoderDecoderModel.from_pretrained(snapshot, local_files_only=True).eval()
    load_s = time.perf_counter() - start
    generation = dict(max_new_tokens=128, num_beams=1, do_sample=False)
    rows = []
    # Fixed full-band crops; no threshold, spell correction, prompt or label access.
    with torch.inference_mode():
        warm = processor(images=Image.new("RGB", (1404, 240), "white"), return_tensors="pt")
        model.generate(warm.pixel_values, **generation)
        for path in sorted((args.collection / "rendered").glob("line-*.png")):
            start = time.perf_counter()
            with Image.open(path) as image:
                pixels = processor(images=image.convert("RGB"), return_tensors="pt").pixel_values
            ids = model.generate(pixels, **generation)
            prediction = processor.batch_decode(ids, skip_special_tokens=True)[0]
            row = dict(sample=path.stem.removeprefix("line-"), prediction=prediction,
                       seconds=time.perf_counter() - start,
                       image_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                       generated_tokens=len(ids[0]) - 1,
                       hit_token_limit=len(ids[0]) - 1 >= generation["max_new_tokens"])
            rows.append(row)
            print(json.dumps(row), flush=True)
    if not rows:
        raise ValueError("no line images")
    (args.output / "predictions.json").write_text(json.dumps(rows, indent=2) + "\n")
    # Labels are used only after all predictions have been saved.
    for row in rows:
        data = (args.collection / "transcriptions" / (row["sample"] + ".txt")).read_bytes()
        row["truth"] = data.decode("utf-8").removesuffix("\n").removesuffix("\r")
        row["label_sha256"] = hashlib.sha256(data).hexdigest()
        if not row["truth"] or "\n" in row["truth"]:
            raise ValueError("expected nonempty single-line label")
    times = [r["seconds"] for r in rows]
    result = dict(model=model_id, revision=revision, generation=generation,
        preprocessing="RGB full-band crop; unmodified model processor, use_fast=False",
        torch=torch.__version__, transformers=transformers.__version__,
        python=platform.python_version(), platform=platform.platform(),
        threads=args.threads, device="cpu", dtype=str(next(model.parameters()).dtype),
        parameters=sum(p.numel() for p in model.parameters()),
        download_seconds=download_s, load_seconds=load_s,
        peak_process_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        median_line_seconds=statistics.median(times), mean_line_seconds=statistics.mean(times),
        all_lines=scores(rows), shared_trajectory_lines=scores([r for r in rows if r["sample"] != "20"]),
        rows=rows)
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
