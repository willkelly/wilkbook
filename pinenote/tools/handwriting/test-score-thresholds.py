#!/usr/bin/env python3
"""Verify rejection means baseline fallback, not removing errors from the corpus."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('thresholds', Path(__file__).with_name('analyze-score-thresholds.py'))
thresholds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(thresholds)


class Gates(unittest.TestCase):
    def test_inclusive_gate_and_full_denominator(self):
        rows = [dict(sample='1', truth='cat', baseline='cot', proposed='cat', confidence=.2),
                dict(sample='2', truth='dog', baseline='dog', proposed='dig', confidence=.1)]
        metrics = thresholds.module('metrics', 'evaluate-images.py')
        summary = thresholds.module('summary', 'summarize-images.py')
        p = thresholds.point(rows, 'confidence', .2, metrics, summary)
        self.assertEqual(p['accepted_samples'], ['1'])
        self.assertEqual(p['full_corpus']['characters'], 6)
        self.assertEqual(p['full_corpus']['character_edits'], 0)
        self.assertEqual(p['selective']['scores']['characters'], 3)
        self.assertEqual(p['selective']['coverage'], .5)
        p = thresholds.point(rows, 'confidence', .3, metrics, summary)
        self.assertEqual(p['full_corpus']['character_edits'], 1)
        self.assertEqual(p['full_corpus']['characters'], 6)
        self.assertIsNone(p['selective']['scores'])
        self.assertEqual(p['accepted_changes'], 0)


if __name__ == '__main__':
    unittest.main()
