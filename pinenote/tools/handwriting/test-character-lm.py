#!/usr/bin/env python3
"""Check fusion against exhaustive CTC paths and independently scored strings."""
import itertools
import math
import os
import unittest
from character_lm import CharacterLM, character_token
from ctc_candidates import beam_search


class ToyLM:
    def start(self):
        return ''

    def extend(self, state, c):
        probability = (.8 if c == 'b' else .2) if state.endswith('a') else (.7 if c == 'a' else .3)
        return state + c, math.log(probability)

    def finish(self, state):
        return math.log(.1 if state.endswith('a') else .9)


class CharacterFusion(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('CHAR_LM_BINARY'), 'optional real KenLM checkpoint')
    def test_incremental_kenlm_matches_full_sequence_api(self):
        lm = CharacterLM(os.environ['CHAR_LM_BINARY'])
        for text in ['', 'Aa a!', 'letter 11', 'a  b', '42: x.']:
            state, score = lm.start(), 0.
            for char in text:
                state, increment = lm.extend(state, char)
                score += increment
            score += lm.finish(state)
            expected = lm.model.score(' '.join(character_token(c) for c in text), bos=True, eos=True) * math.log(10)
            self.assertAlmostEqual(score, expected, places=4)

    def test_ctc_marginals_and_lm_are_counted_once_per_text(self):
        probabilities = [[.2, .5, .3], [.4, .35, .25], [.1, .3, .6]]
        frames = [[math.log(p) for p in row] for row in probabilities]
        masses = {}
        for path in itertools.product(range(3), repeat=3):
            text = ''.join('ab'[c - 1] for i, c in enumerate(path)
                           if c and (i == 0 or c != path[i - 1]))
            masses[text] = masses.get(text, 0.) + math.prod(probabilities[t][c] for t, c in enumerate(path))
        expected = {}
        for text, mass in masses.items():
            score = 0.
            for i, char in enumerate(text):
                probability = (.8 if char == 'b' else .2) if text[:i].endswith('a') else (.7 if char == 'a' else .3)
                score += math.log(probability)
            score += math.log(.1 if text.endswith('a') else .9)
            expected[text] = math.log(mass) + .4 * score + .2 * len(text)
        got = beam_search(frames, 'ab', width=100, token_top_k=0,
                          language_model=ToyLM(), alpha=.4, beta=.2)
        self.assertEqual(set(expected), {c['text'] for c in got})
        for c in got:
            self.assertAlmostEqual(math.exp(c['ctc_logp']), masses[c['text']])
            self.assertAlmostEqual(c['combined_score'], expected[c['text']])
        self.assertEqual(got[0]['text'], max(expected, key=expected.get))
        # Zero weighting cannot alter the stroke-only ranking or path sums.
        plain = beam_search(frames, 'ab', width=100, token_top_k=0)
        zero = beam_search(frames, 'ab', width=100, token_top_k=0, language_model=ToyLM())
        self.assertEqual([(c['text'], c['ctc_logp']) for c in plain],
                         [(c['text'], c['ctc_logp']) for c in zero])

    def test_eos_affects_last_frame_pruning(self):
        frame = [[math.log(.01), math.log(.6), math.log(.39)]]
        self.assertEqual(beam_search(frame, 'ab', width=1)[0]['text'], 'a')
        self.assertEqual(beam_search(frame, 'ab', width=1, language_model=ToyLM(), alpha=1)[0]['text'], 'b')

    def test_character_encoding_is_injective_and_preserves_spaces(self):
        chars = ' aA<>/.,é\n'
        tokens = [character_token(c) for c in chars]
        self.assertEqual(len(tokens), len(set(tokens)))
        self.assertEqual(character_token(' '), 'U000020')
        self.assertTrue(all(not any(c.isspace() for c in t) for t in tokens))
        with self.assertRaises(ValueError):
            character_token('ab')


if __name__ == '__main__':
    unittest.main()
