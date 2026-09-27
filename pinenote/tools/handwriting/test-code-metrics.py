#!/usr/bin/env python3
import unittest
from code_metrics import aligned_lines, scores, text_payload


class CodeMetrics(unittest.TestCase):
    def test_indentation_and_missing_parenthesis_count(self):
        a = 'def f():\n    return (1'
        b = 'def f():\n  return (1)'
        result = scores([dict(truth=a, prediction=b)])
        self.assertEqual(result['character_edits'], 3)
        self.assertEqual(result['nonspace_edits'], 1)
        self.assertEqual(result['exact_blocks'], 0)
        self.assertEqual(result['exact_aligned_lines'], 1)
        self.assertEqual(result['indentation_matches'], 1)

    def test_extra_line_does_not_shift_every_match(self):
        result = scores([dict(truth='a\nb\nc', prediction='# explanation\na\nb\nc')])
        self.assertEqual(result['line_edits'], 1)
        self.assertEqual(result['exact_aligned_lines'], 3)
        self.assertEqual(result['extra_lines'], 1)
        self.assertEqual(aligned_lines('a\na', 'a')['exact'], 1)

    def test_only_one_terminal_newline_removed(self):
        self.assertEqual(text_payload('    x = 1\n'), '    x = 1')
        self.assertEqual(text_payload('\n    x = 1\n\n'), '\n    x = 1\n')
        self.assertEqual(text_payload('```python\nx = 1\n```'), '```python\nx = 1\n```')


if __name__ == '__main__':
    unittest.main()
