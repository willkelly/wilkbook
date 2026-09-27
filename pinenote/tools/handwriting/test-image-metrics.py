#!/usr/bin/env python3
"""Guard the baseline's scoring conventions without model dependencies."""
import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
