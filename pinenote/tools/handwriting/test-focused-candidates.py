#!/usr/bin/env python3
import itertools
import importlib.util
import math
from pathlib import Path
import unittest
from ctc_candidates import sequence_logp
from focused_candidates import greedy_alignment, word_windows, substitute, options_for, relative_probabilities, question_state


class Focused(unittest.TestCase):
    def test_lattice_oracle_matches_exhaustive_whole_choices(self):
        spec = importlib.util.spec_from_file_location('diagnostic', Path(__file__).with_name('summarize-focused.py'))
        diagnostic = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(diagnostic)
        spec = importlib.util.spec_from_file_location('metrics', Path(__file__).with_name('evaluate-images.py'))
        metrics = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(metrics)
        spans = [dict(start=0, end=2, original='ab', ambiguous=True,
                      options=[dict(text='cd'), dict(text='a bc')]),
                 dict(start=3, end=5, original='ef', ambiguous=True,
                      options=[dict(text='gh'), dict(text='i')])]
        texts = [a + ' ' + b for a, b in itertools.product(['ab', 'cd', 'a bc'], ['ef', 'gh', 'i'])]
        for truth in ['ad eh', 'ab i', 'a bc gh', '', 'abcdefghij']:
            self.assertEqual(diagnostic.oracle_edits(truth, 'ab ef', spans),
                             min(metrics.distance(truth, text) for text in texts))

    def test_exact_ctc_score_against_all_paths(self):
        probabilities = [[.2, .5, .3], [.4, .35, .25], [.1, .3, .6]]
        frames = [[math.log(v) for v in row] for row in probabilities]
        for target in ['', 'a', 'b', 'aa', 'ab', 'ba', 'bb']:
            total = 0
            for path in itertools.product(range(3), repeat=3):
                text = ''.join('ab'[c - 1] for i, c in enumerate(path)
                               if c and (i == 0 or c != path[i - 1]))
                if text == target:
                    total += math.prod(probabilities[t][c] for t, c in enumerate(path))
            self.assertAlmostEqual(math.exp(sequence_logp(frames, target, 'ab')), total)

    def test_word_windows_keep_repeats_and_freeze_punctuation(self):
        alphabet = list("helo wrd,!")
        text = 'hello, world!'
        frames = []
        for c in text:
            for label in [0, alphabet.index(c) + 1, alphabet.index(c) + 1]:
                frame = [-20.] * (len(alphabet) + 1)
                frame[label] = 0.
                frames.append(frame)
        self.assertEqual(greedy_alignment(frames, alphabet)[0], text)
        actual, spans = word_windows(frames, alphabet)
        self.assertEqual([s['original'] for s in spans], ['hello', 'world'])
        self.assertEqual([s['context'] for s in spans], ['___, world!', 'hello, ___!'])
        self.assertEqual(substitute(actual, spans, ['good bye', 'earth']), 'good bye, earth!')
        self.assertEqual(substitute(actual, spans, ['hello', 'world']), text)

    def test_ambiguity_and_original_retention(self):
        frames = [[math.log(.01), math.log(.5), math.log(.49)]]
        options, ambiguous = options_for(frames, 'ab', 'a')
        self.assertTrue(ambiguous)
        self.assertEqual({c['text'] for c in options}, {'a', 'b'})
        _, ambiguous = options_for([[math.log(.001), math.log(.998), math.log(.001)]], 'ab', 'a')
        self.assertFalse(ambiguous)

    def test_refuses_wrong_source_span(self):
        with self.assertRaises(ValueError):
            substitute('abc', [dict(start=0, end=2, original='wrong')], ['x'])

    def test_probabilities_are_in_context_and_stay_with_option(self):
        span = dict(context='The ___ moved.', original='cot', options=[
            dict(text='cot', ctc_logp=-1000), dict(text='cat', ctc_logp=-1000 - math.log(3))])
        probabilities = relative_probabilities(span['options'])
        self.assertAlmostEqual(probabilities[0], .75)
        self.assertAlmostEqual(probabilities[1], .25)
        state, options = question_state(span)
        reversed_state, reversed_options = question_state(span, reverse=True)
        self.assertIn("'cot': 0.75000000", state)
        self.assertIn("'cat': 0.25000000", reversed_state)
        self.assertEqual(options, reversed_options)
        self.assertEqual(list(options), list(reversed(reversed_options)))
        self.assertIn('The ___ moved.', state)


if __name__ == '__main__':
    unittest.main()
