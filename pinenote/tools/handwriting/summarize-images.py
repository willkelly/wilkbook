#!/usr/bin/env python3
"""Compare saved recognition runs without re-running inference."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import statistics

spec = importlib.util.spec_from_file_location("evaluate", Path(__file__).with_name("evaluate-images.py"))
evaluate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluate)


def lexical(text):
    # A secondary word-content score: casefold, omit punctuation, retain apostrophes
    # within words. Numbers separated by decimal/colon punctuation become tokens.
    return re.findall(r"\w+(?:['’]\w+)*", text.casefold())


def lexical_score(rows):
    pairs = [(lexical(r["truth"]), lexical(r["prediction"])) for r in rows]
    edits = sum(evaluate.distance(a, b) for a, b in pairs)
    count = sum(len(a) for a, _ in pairs)
    return dict(word_edits=edits, words=count, wer=edits / count,
                exact=sum(a == b for a, b in pairs))


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", type=Path)
    parser.add_argument("--shared", action="store_true", help="explicitly score only sample IDs shared by all runs")
    args = parser.parse_args()
    results = [json.loads(path.read_text()) for path in args.results]
    omitted = set()
    if args.shared:
        ids = [{r["sample"] for r in result["rows"]} for result in results]
        shared = set.intersection(*ids)
        if not shared:
            raise ValueError("no shared samples")
        omitted = set.union(*ids) - shared
        for result in results:
            result["rows"] = [r for r in result["rows"] if r["sample"] in shared]
            result["all_lines"] = evaluate.scores(result["rows"])
            result["median_line_seconds"] = statistics.median(r["seconds"] for r in result["rows"])
    reference = [(r["sample"], r["image_sha256"], r["label_sha256"]) for r in results[0]["rows"]]
    for result in results:
        assert reference == [(r["sample"], r["image_sha256"], r["label_sha256"]) for r in result["rows"]], "different evaluation data"
    print("# Local handwriting baseline\n")
    if args.shared:
        print("Shared sample IDs only. Omitted: " + (", ".join(sorted(omitted)) or "none") + ".\n")
    print("Raw scores preserve case, punctuation and spacing. Secondary lexical WER")
    print("casefolds and extracts word/number tokens (internal apostrophes retained).")
    print("It omits punctuation errors; raw CER/WER remain the primary scores.\n")
    print("| Model | Raw CER | Raw WER | Lexical WER | Exact lines (raw / lexical) | Median s/line | Peak process MiB |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for r in results:
        s, lex = r["all_lines"], lexical_score(r["rows"])
        print(f'| {r["model"]} | {s["cer"]:.2%} | {s["wer"]:.2%} | {lex["wer"]:.2%} | {s["exact"]} / {lex["exact"]} of {s["lines"]} | {r["median_line_seconds"]:.3f} | {r["peak_process_rss_mib"]:.1f} |')
    print("\n## All predictions\n")
    print("| Line | Confirmed writing | " + " | ".join(r["model"] for r in results) + " |")
    print("|---|---|" + "---|" * len(results))
    for i, row in enumerate(results[0]["rows"]):
        print("| " + " | ".join([row["sample"], cell(row["truth"])] + [cell(r["rows"][i]["prediction"]) for r in results]) + " |")


if __name__ == "__main__":
    main()
