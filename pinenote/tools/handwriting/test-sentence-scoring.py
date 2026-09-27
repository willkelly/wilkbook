#!/usr/bin/env python3
"""Pin scalar scoring, clipping, evidence identity and order-independent ranking."""
import itertools
import json
import math
from pathlib import Path
import tempfile
import unittest
from sentence_scoring import checkpoint_files, logit, normalized_score, question, select, state


class SentenceScoring(unittest.TestCase):
    def test_checkpoint_under_cache_is_not_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / '.cache' / 'hub' / 'snapshot'
            (root / '.cache').mkdir(parents=True)
            (root / 'model.pt').write_bytes(b'weights')
            (root / '.cache' / 'download').write_bytes(b'bookkeeping')
            self.assertEqual(checkpoint_files(root), [root / 'model.pt'])

    def test_ordinal_expectation_not_winning_level(self):
        a = dict(score=2.7, probabilities={'0': .1, '1': 0., '2': .2, '3': .5, '4': .2})
        self.assertAlmostEqual(normalized_score(a, 'score'), 2.7 / 4)
        self.assertEqual(normalized_score({'noul': .8}, 'noul'), .8)
        for bad in (float('nan'), -.1, 1.1):
            with self.assertRaises(ValueError):
                normalized_score({'noul': bad}, 'noul')
        with self.assertRaises(ValueError):
            normalized_score(dict(a, score=3.), 'score')

    def test_fusion_and_ties_ignore_candidate_order(self):
        candidates = [dict(text=t, base_score=b, assessments={'noul': {'normalized_score': p}})
                      for t, b, p in [('cot', -1., .2), ('cat', -2., .8), ('bat', -2., .8)]]
        for order in itertools.permutations(candidates):
            self.assertEqual(select(order), 'cot')
            self.assertEqual(select(order, 'noul', weight=0), 'cot')
            self.assertEqual(select(order, 'noul', weight=1), 'bat')
            self.assertEqual(select(order, 'noul', direct=True), 'bat')
        self.assertTrue(math.isfinite(logit(0)))
        self.assertAlmostEqual(logit(0), -logit(1))

    def test_context_preserves_text_and_stroke_evidence(self):
        candidate = dict(text='A "name" 42.', relative_stroke_probability=.125, stroke_loss_nats=2.5,
                         truth='must not leak', original=True, rank=1)
        context = json.loads(state(candidate))
        self.assertEqual(context['proposed_sentence'], candidate['text'])
        self.assertEqual(context['relative_stroke_probability'], .125)
        self.assertEqual(context['stroke_log_probability_loss_from_best'], 2.5)
        self.assertFalse({'truth', 'original', 'rank'} & context.keys())
        self.assertEqual(json.loads(state(candidate, 'text-only')), {'proposed_sentence': candidate['text']})
        self.assertNotIn('supplied stroke', question('noul', 'text-only')['instructions'])
        self.assertIn('supplied stroke', question('noul')['instructions'])


if __name__ == '__main__':
    unittest.main()
