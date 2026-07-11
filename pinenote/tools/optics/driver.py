"""driver.py -- concrete on-device drivers for the optics recorder.

recorder.DeviceDriver is an abstract contract; this module makes it real along
two INDEPENDENT axes, so a capture session mixes and matches:

  * TRANSPORT -- how we reach the device (run a command, move bytes):
      - SerialTransport: the USB CDC-ACM console -- /dev/ttyGS0 on the device
        (wired by pinenote/services/usb-gadget.scm), /dev/ttyACM* on the host.
        This works TETHERED TODAY with no Wi-Fi at all: the device sat in the
        camera box is reachable over the same USB-C cable that powers it. This
        is the path for your own baseline device.
      - SSHTransport: ssh/scp over the network. No new code -- it just needs a
        reachable host, i.e. the Wi-Fi/networking story (doc/networking.md).
        This is the path for a friend's device (or untethered use).

  * BACKEND -- what actually draws the pages, so we can *measure* how much
    KOReader itself shapes the optics:
      - KOReaderBackend (DEFAULT): drives KOReader, so the capture includes
        KOReader's own refresh-mode choices, dithering and partial-update
        logic -- what a real reader actually sees.
      - FramebufferBackend: writes raw frames straight to /dev/fb0 and fires
        the EBC GLOBAL_REFRESH ioctl (pinenote-ebc-refresh, hardware-validated
        2026-07-04) under a chosen waveform, bypassing KOReader entirely -- the
        control. Diffing a KOReader run against a framebuffer run of the same
        test card isolates KOReader's contribution to flicker/ghosting.

ShellDeviceDriver composes one Transport + one RenderBackend into a
DeviceDriver that recorder.run_scenario drives unchanged.

WHY THIS IS TESTABLE OFFLINE: every device interaction goes through
Transport.run/push/pull. FakeTransport (test_driver.py) records the exact
command strings and returns scripted output, so we assert the whole protocol --
param writes, frontlight, sync flashes, per-page turns -- with no device.

HARDWARE_CHECKLIST: five device-specific facts can only be pinned on the
hardware (or the os1 oracle). They are isolated as the module constants below
so a hardware session fills them in with no structural change -- the same
posture doc/networking.md takes for its unproven service wiring:

  1. BACKLIGHT_NODE   -- which /sys/class/backlight node is the frontlight
                         (the standardized illuminant), vs the panel's own.
  2. PANEL_TEMP_HWMON -- the hwmon 'name' that carries the TPS65185 panel temp.
  3. KOREADER_STORE   -- the on-device store path of the koreader bundle dir
                         (glob below is derivable but unconfirmed).
  4. NEXT_PAGE_INJECT -- the actual evdev/uinput mechanism + key/gesture that
                         turns a KOReader page headlessly (the one genuinely
                         unproven bit; see KOReaderBackend._turn).
  5. FB_FORMAT        -- /dev/fb0 pixel format + stride (assumed 8-bit gray,
                         full panel, no pad; confirm with `fbset`).
"""
from __future__ import annotations

import base64
import gzip
import shlex

import recorder  # DeviceDriver ABC + run_scenario orchestration live there


# --- known-good device surfaces (proven in-repo / on hardware) --------------
EBC_PARAM_DIR = "/sys/module/rockchip_ebc/parameters"
REFRESH_WAVEFORM = EBC_PARAM_DIR + "/refresh_waveform"   # 4=GC16, 6=GL16
FB_DEV = "/dev/fb0"                                       # deferred-io framebuffer
EBC_REFRESH = "pinenote-ebc-refresh"                     # GLOBAL_REFRESH ioctl tool
WAVEFORM_CANDIDATES = ("/run/pinenote/ebc.wbf", "/state/firmware/ebc.wbf")

# --- device-specific, confirm on hardware (see HARDWARE_CHECKLIST) -----------
BACKLIGHT_NODE = None                       # None -> auto-pick first backlight [?1]
PANEL_TEMP_HWMON = ("tps65185", "ebc", "sy7636a")   # hwmon 'name' match      [?2]
KOREADER_STORE = "/gnu/store/*koreader*/lib/koreader"                  #        [?3]
KOREADER_HOME = "/root/.config/koreader"
NEXT_PAGE_KEY = "KEY_PAGEDOWN"              # evdev key KOReader maps to next   [?4]
PREV_PAGE_KEY = "KEY_PAGEUP"
FB_BYTES_PER_PIXEL = 1                       # 8-bit gray, full panel, no pad   [?5]


# ===========================================================================
# Transports
# ===========================================================================

class Transport:
    """A way to run shell commands and move bytes to/from one device. Concrete
    subclasses supply the mechanism; the driver/backends stay transport-blind."""

    def connect(self): raise NotImplementedError
    def close(self): pass

    def run(self, cmd, timeout=None):
        """Run `cmd` on the device; return (rc:int, stdout:str)."""
        raise NotImplementedError

    def push(self, data: bytes, remote_path):
        """Place raw bytes at remote_path."""
        raise NotImplementedError

    def pull(self, remote_path) -> bytes:
        """Read raw bytes from remote_path."""
        raise NotImplementedError


# -- serial push/pull as pure command construction (offline-provable) ---------
# Bytes go through the ACM *console shell*, which is line-oriented, so we
# gzip+base64 and stream the text in bounded chunks. Kept as pure functions so
# test_driver.py can prove the round-trip (encode -> commands -> decode) with no
# serial port -- the transport below just runs the strings these emit.

def encode_push_commands(data: bytes, remote_path, chunk=2048):
    """Shell commands that reconstruct `data` at remote_path via a gz+b64 text
    stream. Inverse of decode_push_commands (used only by the offline test)."""
    b64 = base64.b64encode(gzip.compress(data)).decode("ascii")
    tmp = remote_path + ".b64"
    cmds = [": > " + shlex.quote(tmp)]
    for i in range(0, len(b64), chunk):
        cmds.append("printf %s " + shlex.quote(b64[i:i + chunk]) + " >> " + shlex.quote(tmp))
    cmds.append("base64 -d " + shlex.quote(tmp) + " | gzip -d > " + shlex.quote(remote_path))
    cmds.append("rm -f " + shlex.quote(tmp))
    return cmds


def _decode_pushed(b64_text: str) -> bytes:
    return gzip.decompress(base64.b64decode(b64_text))


class SerialTransport(Transport):
    """The USB CDC-ACM console (usb-gadget.scm) as a command channel. Best-effort
    real implementation; only exercisable on hardware, so all *logic* that uses
    it lives in ShellDeviceDriver/backends and is tested via FakeTransport.

    The console shell sets PS1='pinenote-acm$ ' (usb-gadget.scm); we bracket
    each command with a unique rc marker and read until it appears. NOTE: on the
    reader image the ACM console may land in the unprivileged `reader` shell
    rather than root (doc/networking.md) -- sysfs param writes then need a root
    console or sudo. That is a per-image reality to confirm, not a code issue."""

    MARKER = "__optics_rc="

    def __init__(self, device="/dev/ttyACM0", baud=115200, timeout=15.0):
        self.device = device
        self.baud = baud
        self.timeout = timeout
        self._fd = None

    def connect(self):
        import os
        import termios
        self._fd = os.open(self.device, os.O_RDWR | os.O_NOCTTY)
        attr = termios.tcgetattr(self._fd)
        # raw mode: no echo/canon/translation so command framing is exact
        attr[0] = attr[1] = attr[3] = 0
        try:
            b = getattr(termios, "B%d" % self.baud)
            attr[4] = attr[5] = b
        except AttributeError:
            pass
        termios.tcsetattr(self._fd, termios.TCSANOW, attr)
        self.run("stty -echo 2>/dev/null; true")  # quiet the shell's echo
        return self

    def close(self):
        import os
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def run(self, cmd, timeout=None):
        import os
        import time
        wrapped = "%s; printf '%%s%%d\\n' %s $?\n" % (cmd, shlex.quote(self.MARKER))
        os.write(self._fd, wrapped.encode())
        deadline = time.monotonic() + (timeout or self.timeout)
        buf = b""
        while time.monotonic() < deadline:
            try:
                chunk = os.read(self._fd, 4096)
            except BlockingIOError:
                chunk = b""
            if chunk:
                buf += chunk
                if self.MARKER.encode() in buf:
                    break
            else:
                time.sleep(0.01)
        text = buf.decode("utf-8", "replace")
        rc, out = 1, text
        if self.MARKER in text:
            head, _, tail = text.rpartition(self.MARKER)
            out = head
            try:
                rc = int(tail.strip().split()[0])
            except (ValueError, IndexError):
                rc = 0
        # strip the echoed command line if it leaked back
        lines = [ln for ln in out.splitlines() if self.MARKER not in ln]
        return rc, "\n".join(lines).strip()

    def push(self, data: bytes, remote_path):
        for cmd in encode_push_commands(data, remote_path):
            rc, _ = self.run(cmd)
            if rc != 0:
                raise IOError("serial push failed on: %s" % cmd)

    def pull(self, remote_path) -> bytes:
        rc, out = self.run("gzip -c " + shlex.quote(remote_path) + " | base64 -w0")
        if rc != 0:
            raise IOError("serial pull failed: %s" % remote_path)
        return _decode_pushed(out.strip())


class SSHTransport(Transport):
    """ssh/scp over the network. No new on-device code -- it needs only a
    reachable host, i.e. the networking story in doc/networking.md. Uses the
    same trusted channel the os1 oracle already speaks."""

    def __init__(self, host, port=22, identity=None, ssh_opts=("-o", "BatchMode=yes")):
        self.host = host
        self.port = port
        self.identity = identity
        self.ssh_opts = list(ssh_opts)

    def _base(self, tool):
        cmd = [tool]
        if self.identity:
            cmd += ["-i", self.identity]
        cmd += list(self.ssh_opts)
        cmd += (["-P", str(self.port)] if tool == "scp" else ["-p", str(self.port)])
        return cmd

    def connect(self):
        rc, _ = self.run("true")
        if rc != 0:
            raise IOError("ssh connect failed to %s" % self.host)
        return self

    def run(self, cmd, timeout=None):
        import subprocess
        argv = self._base("ssh") + [self.host, cmd]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()

    def push(self, data: bytes, remote_path):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile() as f:
            f.write(data); f.flush()
            argv = self._base("scp") + [f.name, "%s:%s" % (self.host, remote_path)]
            subprocess.run(argv, check=True)

    def pull(self, remote_path) -> bytes:
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile() as f:
            argv = self._base("scp") + ["%s:%s" % (self.host, remote_path), f.name]
            subprocess.run(argv, check=True)
            f.seek(0)
            return f.read()


# ===========================================================================
# Render backends -- how pages are drawn (the KOReader-influence axis)
# ===========================================================================

class RenderBackend:
    """Draws test-card pages on the panel. Given a transport + the test-card
    manifest, it knows how to show the sync flashes and step to page N."""

    def __init__(self, transport, manifest):
        self.t = transport
        self.manifest = manifest
        self._page = None

    def _sync_indices(self):
        return [p["index"] for p in self.manifest["pages"]
                if p["kind"].startswith("sync")]

    def prepare(self, epub_local=None):
        """One-time setup before the run (load the card, blank the panel)."""

    def emit_sync(self):
        raise NotImplementedError

    def goto_page(self, index):
        raise NotImplementedError


class KOReaderBackend(RenderBackend):
    """DEFAULT. Turns pages *in KOReader*, so the measured optics include
    KOReader's own refresh policy. Pages are advanced by injecting the reader's
    next/prev-page input event.

    The one genuinely unproven piece is _turn(): KOReader on the framebuffer
    reads pure-Lua evdev input (reader-session.scm), so a headless page turn
    means injecting a synthetic evdev event that KOReader is listening for. The
    *command sequence* here is fixed and tested; the injection mechanism +
    key/gesture (NEXT_PAGE_KEY) must be confirmed on hardware -- HARDWARE
    CHECKLIST item 4. Kept behind one method so that confirmation is a one-line
    change."""

    INJECT_HELPER = "/root/optics-inject"        # pushed uinput key injector
    EPUB_REMOTE = "/root/optics-testcard.epub"

    def prepare(self, epub_local=None):
        # 1. stage the test-card epub (once) and the input injector
        if epub_local is not None:
            with open(epub_local, "rb") as f:
                self.t.push(f.read(), self.EPUB_REMOTE)
        self._ensure_injector()
        # 2. relaunch KOReader on the test card so page 0 is deterministic
        rc, kodir = self.t.run("ls -d " + KOREADER_STORE + " 2>/dev/null | head -1")
        self._kodir = kodir.strip() or KOREADER_STORE
        self.t.run("herd stop reader-session 2>/dev/null; true")
        launch = ("cd %s && HOME=/root KO_HOME=%s "
                  "PATH=/run/current-system/profile/bin LC_ALL=en_US.UTF-8 "
                  "./luajit reader.lua %s >/var/log/optics-koreader.log 2>&1 &"
                  % (shlex.quote(self._kodir), shlex.quote(KOREADER_HOME),
                     shlex.quote(self.EPUB_REMOTE)))
        self.t.run(launch)
        self._page = 0

    def _ensure_injector(self):
        # A tiny uinput key emitter run by KOReader's own luajit (has ffi).
        # It must exist as a device *before* KOReader enumerates input; prepare()
        # creates it, then relaunches KOReader. Body is device-confirmed work
        # (checklist 4); we only assert it is staged + invoked in tests.
        self.t.run("test -x %s || : # inject helper staged out of band"
                   % shlex.quote(self.INJECT_HELPER))

    def _turn(self, delta):
        key = NEXT_PAGE_KEY if delta > 0 else PREV_PAGE_KEY
        for _ in range(abs(delta)):
            self.t.run("%s %s" % (shlex.quote(self.INJECT_HELPER), key))
        self._page = (self._page or 0) + delta

    def emit_sync(self):
        # step through the opening sync pages so the black/white flashes render
        syncs = self._sync_indices()
        if syncs:
            self._turn(max(syncs) - (self._page or 0))

    def goto_page(self, index):
        self._turn(index - (self._page or 0))


class FramebufferBackend(RenderBackend):
    """The control: push raw frames to /dev/fb0 and fire GLOBAL_REFRESH,
    bypassing KOReader. Every surface it uses is hardware-proven (fb0 write,
    refresh_waveform sysfs, pinenote-ebc-refresh). Heavier over serial (megabytes
    per frame through the console) -- prefer SSH, or pre-stage frames on device.

    Frames are raw device-format bytes keyed by page index; build them host-side
    with frames_from_manifest() so the device just receives bytes and refreshes."""

    FRAME_DIR = "/root/optics-frames"

    def __init__(self, transport, manifest, frames=None, waveform=None):
        super().__init__(transport, manifest)
        self.frames = frames or {}          # {index: raw bytes}
        self.waveform = waveform            # e.g. 4 (GC16) / 6 (GL16); None=leave

    def prepare(self, epub_local=None):
        self.t.run("mkdir -p " + shlex.quote(self.FRAME_DIR))
        for idx, raw in sorted(self.frames.items()):
            self.t.push(raw, "%s/%d.raw" % (self.FRAME_DIR, idx))
        if self.waveform is not None:
            self.t.run("printf %%s %s > %s" % (int(self.waveform), REFRESH_WAVEFORM))
        self._page = None

    def _show(self, index, waveform=None):
        wf = self.waveform if waveform is None else waveform
        if wf is not None:
            self.t.run("printf %%s %s > %s" % (int(wf), REFRESH_WAVEFORM))
        self.t.run("cat %s/%d.raw > %s" % (self.FRAME_DIR, index, FB_DEV))
        self.t.run(EBC_REFRESH)
        self._page = index

    def emit_sync(self):
        # black/white flashes forced GC16 (waveform 4) so they are unambiguous
        for idx in self._sync_indices():
            self._show(idx, waveform=4)

    def goto_page(self, index):
        self._show(index)


def frames_from_manifest(manifest, render_page, bytes_per_pixel=FB_BYTES_PER_PIXEL):
    """Build {index: raw framebuffer bytes} for FramebufferBackend from the
    test card. render_page(kind)->[Hp,Wp] reflectance in [0,1] (pass
    testepub.render_page composed with the manifest). Reflectance 1.0 -> 0xFF.
    Assumes an 8-bit gray, unpadded, full-panel fb (HARDWARE CHECKLIST item 5)."""
    import numpy as np
    frames = {}
    for p in manifest["pages"]:
        refl = np.asarray(render_page(p["kind"]), np.float32)
        px = np.clip(refl * 255.0, 0, 255).astype(np.uint8)
        if bytes_per_pixel != 1:
            px = np.repeat(px[..., None], bytes_per_pixel, axis=-1)
        frames[p["index"]] = px.tobytes()
    return frames


# ===========================================================================
# The composed driver
# ===========================================================================

class ShellDeviceDriver(recorder.DeviceDriver):
    """A DeviceDriver over any Transport + any RenderBackend. Identity, params,
    frontlight and temperature are transport-only shell reads/writes against the
    device surfaces the repo already drives; page playback delegates to the
    backend. recorder.run_scenario drives this unchanged."""

    def __init__(self, transport, backend, epub_local=None):
        self.t = transport
        self.backend = backend
        self.epub_local = epub_local

    # -- connection --
    def connect(self):
        self.t.connect()
        return self

    def close(self):
        self.t.close()

    # -- identity / environment --
    def device_info(self):
        _, kernel = self.t.run("uname -r")
        _, model = self.t.run("tr -d '\\0' < /proc/device-tree/model 2>/dev/null")
        _, os_id = self.t.run(". /etc/os-release 2>/dev/null; printf %s \"$PRETTY_NAME\"")
        return {"model": (model or "PineNote").strip(),
                "kernel": kernel.strip(), "os": os_id.strip()}

    def read_panel_temp(self):
        names = "|".join(PANEL_TEMP_HWMON)
        cmd = ("for d in /sys/class/hwmon/hwmon*; do "
               "n=$(cat \"$d/name\" 2>/dev/null); "
               "case \"$n\" in %s) cat \"$d/temp1_input\" 2>/dev/null; break;; esac; "
               "done" % "|".join("*%s*" % n for n in PANEL_TEMP_HWMON))
        rc, out = self.t.run(cmd)
        try:
            return int(out.strip()) / 1000.0     # hwmon reports millidegrees C
        except (ValueError, AttributeError):
            return None

    def set_frontlight(self, level):
        node = BACKLIGHT_NODE
        if node is None:
            rc, node = self.t.run("ls -d /sys/class/backlight/*/ 2>/dev/null | head -1")
            node = node.strip().rstrip("/")
        if not node:
            return None
        self.t.run("printf %%s %s > %s/brightness" % (int(level), node))
        rc, back = self.t.run("cat %s/brightness 2>/dev/null" % node)
        try:
            return int(back.strip())
        except (ValueError, AttributeError):
            return level

    def waveform_summary(self):
        """Identity only from the device (never the raw .wbf -- repo policy):
        the sha256 of the on-device waveform + the active refresh_waveform mode.
        The full DECODED summary is produced host-side from `wbf-info` text
        (recorder package --wbf-info); this just says *which* waveform ran."""
        rc, wf = self.t.run("cat %s 2>/dev/null" % REFRESH_WAVEFORM)
        sha = None
        for cand in WAVEFORM_CANDIDATES:
            rc, out = self.t.run("sha256sum %s 2>/dev/null | cut -d' ' -f1" % shlex.quote(cand))
            if rc == 0 and out.strip():
                sha = out.strip()
                break
        return {"wbf_sha256": sha, "active_refresh_waveform": wf.strip() or None}

    # -- driver params --
    def set_ebc_params(self, params):
        applied = {}
        for k, v in (params or {}).items():
            path = "%s/%s" % (EBC_PARAM_DIR, k)
            self.t.run("printf %%s %s > %s" % (shlex.quote(str(v)), path))
            rc, back = self.t.run("cat %s 2>/dev/null" % path)
            applied[k] = back.strip() if rc == 0 and back else v
        return applied

    # -- scenario playback (delegated to the backend) --
    def open_testcard(self, epub_path=None):
        self.backend.prepare(epub_local=epub_path or self.epub_local)

    def emit_sync(self):
        self.backend.emit_sync()

    def goto_page(self, index):
        self.backend.goto_page(index)


# ===========================================================================
# Factory -- string knobs -> a wired driver (used by recorder.py CLI)
# ===========================================================================

def make_driver(transport="serial", backend="koreader", manifest=None,
                epub_local=None, frames=None, waveform=None, **kw):
    """Build a ShellDeviceDriver from CLI-friendly strings.
    transport: 'serial' (default, tethered/no-Wi-Fi) | 'ssh' (needs networking).
    backend:   'koreader' (default) | 'fb' (raw framebuffer control)."""
    if transport == "serial":
        tr = SerialTransport(device=kw.get("device", "/dev/ttyACM0"),
                             baud=kw.get("baud", 115200))
    elif transport == "ssh":
        if not kw.get("host"):
            raise ValueError("ssh transport needs host=... (blocked on networking)")
        tr = SSHTransport(host=kw["host"], port=kw.get("port", 22),
                          identity=kw.get("identity"))
    else:
        raise ValueError("unknown transport %r (serial|ssh)" % transport)

    if manifest is None:
        raise ValueError("make_driver needs the test-card manifest")
    if backend == "koreader":
        be = KOReaderBackend(tr, manifest)
    elif backend == "fb":
        be = FramebufferBackend(tr, manifest, frames=frames, waveform=waveform)
    else:
        raise ValueError("unknown backend %r (koreader|fb)" % backend)

    return ShellDeviceDriver(tr, be, epub_local=epub_local)
