#!/usr/bin/env python3
"""Digitizer report rate and stroke counts from raw evdev captures.

Usage: report-rate.py pen-1.bin [pen-2.bin ...]

Each capture is `cat /dev/input/eventN` of the w9013 "Stylus" node:
aarch64 struct input_event records (24 bytes: s64 sec, s64 usec, u16
type, u16 code, s32 value).  A report is one SYN_REPORT; intervals over
50 ms are pauses between strokes and are left out of the rate.
"""
import statistics
import struct
import sys

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN_TOUCH = 330
AXES = {0: "X", 1: "Y", 24: "PRESSURE", 25: "DISTANCE", 26: "TILT_X", 27: "TILT_Y"}


def rate(ts):
    d = sorted(b - a for a, b in zip(ts, ts[1:]) if 0 < b - a < 0.05)
    if not d:
        return "n/a"
    med = statistics.median(d)
    return (f"n={len(d)} median={med * 1000:.2f} ms (~{1 / med:.0f} Hz) "
            f"p10={d[len(d) // 10] * 1000:.2f} p90={d[len(d) * 9 // 10] * 1000:.2f} ms "
            f"in-stroke={sum(d):.1f} s")


for path in sys.argv[1:]:
    data = open(path, "rb").read()
    touching, strokes = False, 0
    down, hover, axes = [], [], {}
    for i in range(len(data) // 24):
        sec, usec, typ, code, value = struct.unpack_from("<qqHHi", data, i * 24)
        t = sec + usec / 1e6
        if typ == EV_KEY and code == BTN_TOUCH:
            if value and not touching:
                strokes += 1
            touching = bool(value)
        elif typ == EV_ABS:
            name = AXES.get(code, str(code))
            axes[name] = axes.get(name, 0) + 1
        elif typ == EV_SYN and code == 0:
            (down if touching else hover).append(t)
    print(f"{path}: strokes={strokes}")
    print(f"  pen-down reports: {rate(down)}")
    print(f"  hover reports:    {rate(hover)}")
    print(f"  axis events: {axes}")
