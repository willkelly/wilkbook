#!/usr/bin/env python3
"""Guard the baseline's scoring conventions without model dependencies."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("summary", Path(__file__).with_name("summarize-images.py"))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)
distance, scores = summary.evaluate.distance, summary.evaluate.scores


class Metrics(unittest.TestCase):
    def test_edit_operations(self):
        for a, b, expected in [("kitten", "sitting", 3), ("", "abc", 3),
                               ("abc", "", 3), ("é", "e", 1), ("same", "same", 0)]:
            self.assertEqual(distance(a, b), expected)
        self.assertEqual(distance(["one", "two"], ["one", "three", "two"]), 1)

    def test_weighted_corpus_not_mean_of_rates(self):
        result = scores([dict(truth="a", prediction="b"),
                         dict(truth="123456789", prediction="123456789")])
        self.assertEqual(result["cer"], 0.1)
        self.assertEqual(result["wer"], 0.5)
        self.assertEqual(result["exact"], 1)

    def test_raw_punctuation_and_spelling_are_errors(self):
        rows = [dict(truth="Tommorrow.", prediction="Tomorrow .")]
        self.assertEqual(scores(rows)["character_edits"], 2)
        self.assertEqual(scores(rows)["word_edits"], 2)
        self.assertEqual(summary.lexical_score(rows)["word_edits"], 1)

    def test_secondary_score_is_explicitly_lossy(self):
        self.assertEqual(summary.lexical("Don't forget: $24.75!"), ["don't", "forget", "24", "75"])
        rows = [dict(truth="One word.", prediction="one word .")]
        self.assertGreater(scores(rows)["cer"], 0)
        self.assertEqual(summary.lexical_score(rows)["wer"], 0)

    def test_shared_comparison_recomputes_denominators(self):
        def result(rows):
            return dict(model="fixture", rows=rows, all_lines=scores(rows),
                        median_line_seconds=1, peak_process_rss_mib=1)
        first = dict(sample="01", truth="abc", prediction="abc", seconds=1,
                     image_sha256="image-one", label_sha256="label-one")
        second = dict(sample="02", truth="d", prediction="X", seconds=1,
                      image_sha256="image-two", label_sha256="label-two")
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / "a.json", Path(d) / "b.json"
            a.write_text(json.dumps(result([first, second])))
            b.write_text(json.dumps(result([first])))
            command = [sys.executable, str(Path(__file__).with_name("summarize-images.py")), str(a), str(b)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            comparison = subprocess.check_output(command + ["--shared"], text=True)
            self.assertIn("Omitted: 02.", comparison)
            self.assertIn("0.00%", comparison)
            self.assertNotIn("25.00%", comparison)
            first["image_sha256"] = "different-image"
            b.write_text(json.dumps(result([first])))
            self.assertNotEqual(subprocess.run(command + ["--shared"], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
