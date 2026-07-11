#!/usr/bin/env python3
"""Offline validation of the on-device drivers (driver.py) with NO device.

Every device interaction goes through a Transport, so a FakeTransport that
records command strings and returns scripted output lets us assert the whole
protocol -- serial byte push round-trips, sysfs param/frontlight/temp reads and
writes, and both render backends' page-turn command sequences -- exactly, with
no serial port and no PineNote. This is the proof that when the five
HARDWARE_CHECKLIST values in driver.py are pinned on hardware, the recorder
drives a real capture with no structural change.

Run: python3 test_driver.py  (needs numpy for the framebuffer frame builder).
"""
import sys

import driver
import recorder
import testepub as te

_fails = []


def check(name, cond, detail=""):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not cond:
        _fails.append(name)


class FakeTransport(driver.Transport):
    """Records every command; answers reads from a substring->(rc,out) table.
    push/pull keep bytes in memory so backends can be driven end to end."""

    def __init__(self, responses=None):
        self.cmds = []
        self.files = {}
        self.responses = responses or {}

    def connect(self):
        self.cmds.append("__connect__")
        return self

    def close(self):
        self.cmds.append("__close__")

    def run(self, cmd, timeout=None):
        self.cmds.append(cmd)
        for key, val in self.responses.items():
            if key in cmd:
                return val(cmd) if callable(val) else val
        return (0, "")

    def push(self, data, remote_path):
        self.files[remote_path] = data
        self.cmds.append(("push", remote_path, len(data)))

    def pull(self, remote_path):
        return self.files.get(remote_path, b"")

    # test helpers
    def ran(self, needle):
        return [c for c in self.cmds if isinstance(c, str) and needle in c]

    def count(self, needle):
        return len(self.ran(needle))


def main():
    print("case: serial gz+b64 push commands round-trip (no serial port)")
    data = bytes(range(256)) * 40 + b"optics"          # spans several chunks
    cmds = driver.encode_push_commands(data, "/root/blob", chunk=100)
    # replay the emitted shell into a fake filesystem to prove reconstruction
    b64 = ""
    for c in cmds:
        if c.startswith("printf %s "):
            frag = c.split("printf %s ", 1)[1].rsplit(" >>", 1)[0]
            b64 += frag.strip().strip("'")
    check("push stream decodes back to the exact bytes",
          driver._decode_pushed(b64) == data,
          f"{len(cmds)} cmds, {len(data)} bytes")
    check("push truncates the temp file first and cleans up",
          cmds[0].startswith(": > ") and cmds[-1].startswith("rm -f "))

    manifest = te.build_manifest(te.build_pages())
    n_sync = sum(1 for p in manifest["pages"] if p["kind"].startswith("sync"))
    content = [p for p in manifest["pages"] if not p["kind"].startswith("sync")]

    print("case: ShellDeviceDriver reads/writes the right device surfaces")
    ft = FakeTransport(responses={
        "uname -r": (0, "7.0.14-pinenote"),
        "device-tree/model": (0, "Pine64 PineNote"),
        "PRETTY_NAME": (0, "wilkbook os2 7.0.x"),
        "temp1_input": (0, "24500"),
        "brightness": (0, "42"),
        "parameters/refresh_waveform": (0, "6"),
        "sha256sum": (0, "deadbeefcafe"),
    })
    drv = driver.ShellDeviceDriver(ft, driver.KOReaderBackend(ft, manifest))
    info = drv.device_info()
    check("device_info parses model + kernel", info["model"] == "Pine64 PineNote"
          and info["kernel"] == "7.0.14-pinenote", f"{info}")
    check("panel temp converts millidegrees -> C", drv.read_panel_temp() == 24.5,
          f"{drv.read_panel_temp()}")
    fl = drv.set_frontlight(42)
    check("frontlight writes both warm+cool nodes + reads back", fl == 42
          and any("42 > /sys/class/backlight/backlight_cool/brightness" in c for c in ft.cmds)
          and any("42 > /sys/class/backlight/backlight_warm/brightness" in c for c in ft.cmds),
          f"applied={fl}")
    applied = drv.set_ebc_params({"refresh_waveform": 6, "refresh_threshold": 30})
    check("ebc params write each sysfs param", applied.get("refresh_waveform") == "6"
          and any("6 > /sys/module/rockchip_ebc/parameters/refresh_waveform" in c
                  for c in ft.ran("refresh_waveform")),
          f"{applied}")
    wf = drv.waveform_summary()
    check("waveform_summary returns identity only, never a raw LUT",
          set(wf) <= {"wbf_sha256", "active_refresh_waveform"}
          and wf["active_refresh_waveform"] == "6" and wf["wbf_sha256"] == "deadbeefcafe",
          f"{wf}")

    print("case: KOReaderBackend turns pages via injected next/prev events")
    ftk = FakeTransport()
    be = driver.KOReaderBackend(ftk, manifest)
    drvk = driver.ShellDeviceDriver(ftk, be)
    drvk.open_testcard()
    check("prepare stops reader-session + relaunches KOReader on the card",
          ftk.count("herd stop reader-session") == 1
          and any("reader.lua" in c and driver.KOReaderBackend.EPUB_REMOTE in c
                  for c in ftk.cmds), "launch")
    injects_before = ftk.count(be.INJECT_HELPER)
    drvk.emit_sync()
    check("emit_sync steps through exactly the sync pages",
          ftk.count(be.INJECT_HELPER) - injects_before == max(p["index"] for p in manifest["pages"]
                                                              if p["kind"].startswith("sync")),
          f"{ftk.count(be.INJECT_HELPER) - injects_before} turns for {n_sync} sync pages")
    at = be._page
    drvk.goto_page(content[0]["index"])
    fwd = content[0]["index"] - at
    check("goto_page advances by the page delta with the next-page key",
          ftk.count(driver.NEXT_PAGE_KEY) >= fwd and fwd > 0, f"delta={fwd}")

    print("case: FramebufferBackend pushes frames + fires GLOBAL_REFRESH")
    import numpy as np
    te.W, te.H = 300, 400                    # small but >= the fiducial minimum
    small = te.build_manifest(te.build_pages())
    frames = driver.frames_from_manifest(small, lambda kind: np.asarray(
        te.render_page(te.Page(0, kind, 0)), np.float32) / 255.0)
    check("frame builder yields one raw buffer per page, 32bpp XR24",
          len(frames) == len(small["pages"])
          and all(len(b) == 300 * 400 * 4 for b in frames.values()),
          f"{len(frames)} frames of {300*400*4}B")
    ftf = FakeTransport()
    bef = driver.FramebufferBackend(ftf, small, frames=frames, waveform=6)
    drvf = driver.ShellDeviceDriver(ftf, bef)
    drvf.open_testcard()
    check("prepare pushes every page frame + sets the waveform",
          len(ftf.files) == len(small["pages"])
          and any("6 > " + driver.REFRESH_WAVEFORM in c for c in ftf.cmds), "prepare")
    ref_before = ftf.count(driver.EBC_REFRESH)
    drvf.goto_page(content[0]["index"])
    check("goto_page cats the frame to /dev/fb0 then refreshes",
          any("%d.raw > %s" % (content[0]["index"], driver.FB_DEV) in c for c in ftf.cmds)
          and ftf.count(driver.EBC_REFRESH) - ref_before == 1, "show")
    te.W, te.H = 1404, 1872                  # restore module defaults

    print("case: run_scenario drives the REAL ShellDeviceDriver end to end")
    ft2 = FakeTransport()
    drv2 = driver.ShellDeviceDriver(ft2, driver.KOReaderBackend(ft2, manifest))
    drv2.connect()
    runs = recorder.run_scenario(
        drv2, manifest,
        param_sets=[("baseline", {}), ("gl16", {"refresh_waveform": 6})],
        page_period_s=1.5, clock=recorder.FakeClock())
    check("one run per param set with every content page logged",
          len(runs) == 2
          and sum(1 for e in runs[0]["events"] if e["event"] == "page") == len(content),
          f"{len(runs)} runs")
    check("the flipped GL16 param reached the device sysfs",
          any("6 > /sys/module/rockchip_ebc/parameters/refresh_waveform" in c
              for c in ft2.cmds), "param write")

    print()
    if _fails:
        print(f"driver: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("driver: ok -- transports + backends drive the protocol correctly, no device")
    return 0


if __name__ == "__main__":
    sys.exit(main())
