#!/usr/bin/env python3
"""Pin OnlineHTR label/blank compatibility against the real decoder package."""
import itertools
import math
import unittest
import numpy as np
from pyctcdecode import build_ctcdecoder


class CTCAdapter(unittest.TestCase):
    def test_blank_repeats_and_case_are_preserved(self):
        labels = ['', 'a', 'A', ' ']
        decoder = build_ctcdecoder(labels)
        self.assertEqual(decoder._alphabet.labels, labels)
        for path, expected in [([1, 1], 'a'), ([1, 0, 1], 'aa'),
                               ([2, 1], 'Aa'), ([2, 3, 1], 'A a')]:
            frames = np.full((len(path), len(labels)), -30.)
            frames[np.arange(len(path)), path] = 0.
            self.assertEqual(decoder.decode(frames), expected)

    def test_no_lm_top_choice_matches_exhaustive_alignment_oracle(self):
        labels = ['', 'a', 'b', ' ']
        probabilities = [[.2, .5, .3], [.4, .35, .25], [.1, .3, .6]]
        masses = {}
        for path in itertools.product(range(3), repeat=3):
            text = ''.join(labels[c] for i, c in enumerate(path)
                           if c and (i == 0 or c != path[i - 1]))
            masses[text] = masses.get(text, 0.) + math.prod(probabilities[t][c] for t, c in enumerate(path))
        # Space has negligible mass; library clips tiny values, hence tolerance.
        frames = np.log(np.array([p + [1e-20] for p in probabilities]))
        beams = build_ctcdecoder(labels).decode_beams(frames, beam_width=128,
            beam_prune_logp=-100, token_min_logp=-100, prune_history=False)
        self.assertEqual(beams[0][0], max(masses, key=masses.get))
        self.assertAlmostEqual(math.exp(beams[0][3]), max(masses.values()), places=10)


if __name__ == '__main__':
    unittest.main()
