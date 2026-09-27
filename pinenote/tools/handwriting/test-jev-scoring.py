#!/usr/bin/env python3
"""Check hosted quantization and lossless candidate/evidence wiring offline."""
import json
import unittest
from jev_scoring import assessment_questions, choice_readings, choice_spec, normalized_score
from sentence_scoring import LEVELS, question


class JevScoring(unittest.TestCase):
    def test_wire_questions_match_local_experiment(self):
        for evidence in ('stroke', 'text-only'):
            questions = assessment_questions(evidence)
            for kind, q in questions.items():
                self.assertEqual(q['question'], question(kind, evidence)['instructions'])
            self.assertEqual(questions['noul']['criteria'], question('noul', evidence)['criteria'])
            self.assertEqual([r['label'] for r in questions['score']['rubric']], LEVELS)

    def test_rounded_score_keeps_native_expectation(self):
        # Underlying probabilities [.124, .124, .124, .314, .314] round down
        # independently: mass .98 and expectation 2.53, while native E = 2.57.
        answer = dict(type='score', score=2.57, confidence=.2,
                      probabilities={'0': .12, '1': .12, '2': .12, '3': .31, '4': .31},
                      legend={str(i): text for i, text in enumerate(LEVELS)})
        self.assertEqual(normalized_score(answer, 'score'), 2.57 / 4)
        for bad in (dict(answer, score=3), dict(answer, confidence=float('nan')),
                    dict(answer, legend={}), dict(answer, probabilities={})):
            with self.assertRaises(ValueError):
                normalized_score(bad, 'score')
        for value in (float('nan'), True, -.1, 1.1):
            with self.assertRaises(ValueError):
                normalized_score(dict(type='noul', noul=value), 'noul')

    def test_choice_retains_all_readings_and_only_permitted_evidence(self):
        candidates = [dict(text=text, base_score=-i, relative_stroke_probability=.5,
                           stroke_loss_nats=i, truth='SECRET')
                      for i, text in enumerate(('  a = "cat"', '  a = "cot"'))]
        for evidence in ('stroke', 'text-only'):
            context, questions = choice_spec(candidates, evidence)
            self.assertNotIn('SECRET', json.dumps([context, questions]))
            self.assertEqual([c['text'] for c in candidates],
                             [o['id'] for o in questions['reading']['options']])
            self.assertEqual('readings' in context, evidence == 'stroke')
        answer = dict(type='choice', choice=candidates[1]['text'], confidence=.8,
                      probabilities={candidates[0]['text']: 0., candidates[1]['text']: 1.})
        self.assertEqual(choice_readings(candidates, answer), choice_readings(candidates[::-1], answer))
        self.assertEqual(choice_readings(candidates, answer)['choice_direct'], candidates[1]['text'])
        with self.assertRaises(ValueError):
            choice_readings(candidates, dict(answer, probabilities={'unknown': 1.}))
        with self.assertRaises(ValueError):
            choice_spec([candidates[0], candidates[0]], 'text-only')


if __name__ == '__main__':
    unittest.main()
