#!/usr/bin/env python3
"""Guard units, orientation, temporal order and label isolation at the adapter."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("trajectory", Path(__file__).with_name("evaluate-trajectories.py"))
trajectory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trajectory)

FORMAT = '''<traceFormat>
<channel name="X" units="dev"/><channel name="Y" units="dev"/>
<channel name="T" units="ms"/><channel name="F"/>
<channel name="TX"/><channel name="TY"/></traceFormat>'''


class Input(unittest.TestCase):
    def read(self, traces, label="DO NOT FEED THIS TO THE MODEL", fmt=FORMAT):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "line-01.inkml"
            p.write_text('<ink xmlns="http://www.w3.org/2003/InkML">'
                         + f'<annotation type="truth">{label}</annotation>' + fmt
                         + ''.join(f'<trace>{s}</trace>' for s in traces) + '</ink>')
            return trajectory.read_ink(p)

    def test_units_orientation_and_later_leftward_stroke(self):
        s = self.read(["10 20 1000 42 1 -1, 30 40 1500 50 2 -2",
                       "5 10 2000 80 3 -3"])
        self.assertEqual(s["x"], [10, 30, 5])  # No spatial reordering.
        self.assertEqual(s["y"], [-20, -40, -10])
        self.assertEqual(s["t"], [1, 1.5, 2])
        self.assertEqual(s["stroke_nr"], [0, 0, 1])
        self.assertEqual(s["label"], "")

    def test_annotations_do_not_change_model_input(self):
        ink = ["1 2 0 50 0 0, 2 3 100 60 0 0"]
        self.assertEqual(self.read(ink, "correct"), self.read(ink, "unrelated"))

    def test_refuses_time_reversal_and_wrong_units(self):
        with self.assertRaises(ValueError):
            self.read(["1 2 100 50 0 0, 2 3 0 60 0 0"])
        with self.assertRaises(ValueError):
            self.read(["1 2 0 50 0 0, 2 3 100 60 0 0"], fmt=FORMAT.replace('"ms"', '"s"'))

    def test_refuses_malformed_and_degenerate_ink(self):
        for traces in [[], [""], ["1 2 0 50 0 0"],
                       ["1 2 0 50 0"], ["1 2 0 50 0 0, nan 3 100 60 0 0"]]:
            with self.subTest(traces=traces), self.assertRaises(ValueError):
                self.read(traces)


if __name__ == "__main__":
    unittest.main()
