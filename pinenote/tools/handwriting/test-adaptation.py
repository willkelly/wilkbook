#!/usr/bin/env python3
import unittest
from adaptation import encode, expanded_alphabet, split, trainable


class Adaptation(unittest.TestCase):
    def test_folds_are_disjoint_and_each_page_is_tested_once(self):
        samples = [f'{i:02}' for i in range(1, 20)]
        all_tests = []
        for page in range(5):
            parts = split(samples, page)
            self.assertEqual(set().union(*map(set, parts.values())), set(samples))
            self.assertFalse(set(parts['train']) & set(parts['validation']))
            self.assertFalse(set(parts['train']) & set(parts['test']))
            self.assertFalse(set(parts['validation']) & set(parts['test']))
            all_tests += parts['test']
        self.assertEqual(sorted(all_tests), samples)

    def test_alphabet_extension_preserves_old_indices_and_blank(self):
        old = ['z', 'a', ' ']
        new = expanded_alphabet(old)
        self.assertEqual(new[:3], old)
        self.assertEqual(encode('za ', new), [1, 2, 3])
        self.assertEqual(set(new), {chr(i) for i in range(32, 127)})
        self.assertNotIn(0, encode('$ = {x}', new))
        with self.assertRaises(KeyError):
            encode('λ', new)

    def test_parameter_boundary_includes_both_top_layer_directions(self):
        self.assertTrue(trainable('linear.bias', 'head', 3))
        self.assertFalse(trainable('lstm_stack.weight_ih_l2', 'head', 3))
        self.assertTrue(trainable('lstm_stack.weight_ih_l2', 'last-layer', 3))
        self.assertTrue(trainable('lstm_stack.weight_hh_l2_reverse', 'last-layer', 3))
        self.assertFalse(trainable('lstm_stack.weight_hh_l1_reverse', 'last-layer', 3))
        self.assertTrue(trainable('lstm_stack.bias_ih_l0', 'full', 3))


if __name__ == '__main__':
    unittest.main()
