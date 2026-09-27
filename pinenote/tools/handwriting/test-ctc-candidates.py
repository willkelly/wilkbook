#!/usr/bin/env python3
"""Check CTC path marginalization against exhaustive enumeration, not itself."""
import collections
import itertools
import importlib.util
import math
from pathlib import Path
import unittest
from ctc_candidates import beam_search, rerank


class Candidates(unittest.TestCase):
    def test_exhaustive_alignment_oracle(self):
        probabilities = [[0.2, 0.5, 0.3], [0.4, 0.35, 0.25], [0.1, 0.3, 0.6]]
        expected = collections.defaultdict(float)
        for path in itertools.product(range(3), repeat=3):
            collapsed = [c for i, c in enumerate(path) if (i == 0 or c != path[i - 1]) and c != 0]
            text = ''.join("ab"[c - 1] for c in collapsed)
            expected[text] += math.prod(probabilities[t][c] for t, c in enumerate(path))
        got = beam_search([[math.log(p) for p in row] for row in probabilities], "ab", width=100, token_top_k=0)
        self.assertEqual(set(expected), {c['text'] for c in got})
        for c in got:
            self.assertAlmostEqual(math.exp(c['ctc_logp']), expected[c['text']])
        self.assertAlmostEqual(sum(math.exp(c['ctc_logp']) for c in got), 1)

    def test_blank_separates_repeated_letters(self):
        frames = [[-20, 0], [0, -20], [-20, 0]]
        self.assertEqual(beam_search(frames, "a")[0]['text'], "aa")
        self.assertEqual(beam_search([frames[0]] * 3, "a")[0]['text'], "a")

    def test_prior_can_resolve_ambiguity_but_cannot_invent_candidate(self):
        candidates = [dict(text="cot", ctc_logp=-1), dict(text="cat", ctc_logp=-1.2)]
        language_scores = [-10, -1]
        self.assertEqual(rerank(candidates, language_scores, 0)[0]['text'], "cot")
        self.assertEqual(rerank(candidates, language_scores)[0]['text'], "cat")
        self.assertEqual({c['text'] for c in rerank(candidates, language_scores)}, {"cot", "cat"})

    def test_von_must_choose_and_score_only_known_options(self):
        spec = importlib.util.spec_from_file_location('von_eval', Path(__file__).with_name('evaluate-von.py'))
        evaluator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(evaluator)
        options = {'a': 'cot', 'b': 'cat'}
        evaluator.validate_choice({'choice': 'a', 'probabilities': {'a': 0.6, 'b': 0.4}}, options)
        for answer in [
            {'choice': 'other', 'probabilities': {'a': 0.6, 'b': 0.4}},
            {'choice': 'a', 'probabilities': {'a': 1.0}},
            {'choice': 'a', 'probabilities': {'a': float('nan'), 'b': 0.4}},
            {'choice': 'a', 'probabilities': {'a': 0.8, 'b': 0.8}},
        ]:
            with self.subTest(answer=answer), self.assertRaises(ValueError):
                evaluator.validate_choice(answer, options)


if __name__ == '__main__':
    unittest.main()
