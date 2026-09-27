#!/usr/bin/env python3
"""Generate scored CTC alternatives from saved emissions, without any labels."""
import argparse
import hashlib
import json
from pathlib import Path
import time
from ctc_candidates import beam_search


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("capture", type=Path)
    p.add_argument("original", type=Path, help="frozen greedy run")
    p.add_argument("output", type=Path, help="new output directory")
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    # hashlib imports before NumPy also work around a Guix wheel libz load order.
    import numpy as np
    original = json.loads((args.original / "predictions.json").read_text())
    captured = json.loads((args.capture / "predictions.json").read_text())
    for old, new in zip(original, captured, strict=True):
        for key in ("sample", "prediction", "image_sha256", "inkml_sha256"):
            assert old[key] == new[key], f"capture changed {key}"
    alphabet = json.loads((args.capture / "emissions/alphabet.json").read_text())
    predictions = []
    for row in captured:
        path = args.capture / "emissions" / f'line-{row["sample"]}.npz'
        with np.load(path, allow_pickle=False) as data:
            frames = data['log_probs'].tolist()
        start = time.perf_counter()
        candidates = beam_search(frames, alphabet, width=128, token_top_k=8)[:32]
        record = dict(row, candidates=candidates, beam_seconds=time.perf_counter() - start,
                      emissions_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        predictions.append(record)
        print(json.dumps(dict(sample=row['sample'], beam=candidates[0],
                              seconds=record['beam_seconds'])), flush=True)
    result = dict(settings=dict(beam_width=128, frame_nonblank_top_k=8, nbest=32), rows=predictions)
    (args.output / 'candidates.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
