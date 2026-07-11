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

HARDWARE_CHECKLIST -- all five device values were PINNED live on 2026-07-11
(over the ACM console; see the constants below):

  1. BACKLIGHT_NODES  -- frontlight is TWO nodes, backlight_{cool,warm}
                         (max_brightness 255); illuminant sets both.  [ok]
  2. PANEL_TEMP_HWMON -- hwmon2 name = tps65185, temp1_input in m°C.   [ok]
  3. KOREADER_STORE   -- /gnu/store/*koreader*/lib/koreader confirmed.  [ok]
  4. NEXT_PAGE_INJECT -- /dev/uinput exists; KOReader's pinenote target maps
                         KEY_FORWARD(159)->next, KEY_BACK(158)->prev, so page
                         turns inject via a uinput key device (KOReaderBackend +
                         optics-inject.lua).  Mechanism identified + harness-
                         proven offline; live end-to-end still unproven.
  5. FB_FORMAT        -- /dev/fb0 is 32bpp XR24, 1872x1404, stride 7488 (NOT
                         8-bit); write + GLOBAL_REFRESH proven live.  [ok]
"""
from __future__ import annotations

import base64
import gzip
import os
import shlex

import recorder  # DeviceDriver ABC + run_scenario orchestration live there

# Driver-side default for the trace-harvest contract (PLAN task 6): the
# base DeviceDriver answers None ("no trace"), concrete drivers override.
# recorder.py is where this belongs long-term; installed from here so the
# recorder side of task 6 (the trace.<run_id>.log sidecar) can call
# driver.harvest_trace() unconditionally the moment it lands.
if not hasattr(recorder.DeviceDriver, "harvest_trace"):
    recorder.DeviceDriver.harvest_trace = lambda self: None


# --- known-good device surfaces (proven in-repo / on hardware) --------------
EBC_PARAM_DIR = "/sys/module/rockchip_ebc/parameters"
REFRESH_WAVEFORM = EBC_PARAM_DIR + "/refresh_waveform"   # 4=GC16, 6=GL16
FB_DEV = "/dev/fb0"                                       # deferred-io framebuffer
EBC_REFRESH = "pinenote-ebc-refresh"                     # GLOBAL_REFRESH ioctl tool
WAVEFORM_CANDIDATES = ("/run/pinenote/ebc.wbf", "/state/firmware/ebc.wbf")

# --- device values, PINNED on hardware 2026-07-11 (was the HARDWARE_CHECKLIST) -
# Frontlight is TWO nodes (warm + cool natural-light LEDs); the standardized
# illuminant sets both to the same level.  [?1 resolved]
BACKLIGHT_NODES = ("/sys/class/backlight/backlight_cool",
                   "/sys/class/backlight/backlight_warm")   # max_brightness 255 each
PANEL_TEMP_HWMON = ("tps65185",)            # hwmon2/name = tps65185; temp1_input m°C [?2 ok]
KOREADER_STORE = "/gnu/store/*koreader*/lib/koreader"       # confirmed present    [?3 ok]
KOREADER_HOME = "/root/.config/koreader"    # the dogfooding profile; optics runs
                                            # use KOReaderBackend.KO_HOME instead
# KOReader's pinenote target maps the ws8100 pen buttons: KEY_FORWARD(159)->next,
# KEY_BACK(158)->prev (device.lua event_map).  /dev/uinput exists live, so page
# turns inject via the optics-inject.lua uinput daemon (see KOReaderBackend).
# Status [?4]: mechanism identified live 2026-07-11; the 159/158 ->
# RPgFwd/RPgBack chain and the 'wilkbook-optics' device-name whitelist are
# harness-proven offline (pinenote/tools/koreader-input); the live end-to-end
# (daemon create -> KOReader enumerates -> injected turn) is still unproven
# on hardware -- it is step 1 of the next SSH session.
NEXT_PAGE_KEY = "KEY_FORWARD"               # evdev code 159
PREV_PAGE_KEY = "KEY_BACK"                  # evdev code 158
NEXT_PAGE_CODE, PREV_PAGE_CODE = 159, 158
# Framebuffer is 32bpp XR24 at 1872x1404, stride 7488 (no pad) — NOT 8-bit gray;
# grayscale content is B=G=R=v, X=0xFF.  Write + GLOBAL_REFRESH proven live.  [?5]
FB_BYTES_PER_PIXEL = 4
FB_WIDTH, FB_HEIGHT = 1872, 1404


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


def _lua_repr(v):
    """A Python value as a Lua literal for the seeded settings.reader.lua."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return '"%s"' % str(v).replace("\\", "\\\\").replace('"', '\\"')


class KOReaderBackend(RenderBackend):
    """DEFAULT. Turns pages *in KOReader*, so the measured optics include
    KOReader's own refresh policy.

    Page turns go through a persistent uinput injector daemon
    (optics-inject.lua, pushed and started by prepare() BEFORE the KOReader
    relaunch -- KOReader enumerates input exactly once, at init, so the
    'wilkbook-optics' device must already exist and must persist; device.lua
    whitelists the name and opens it).  _turn() then just writes 'KEY <code>'
    lines into the daemon's FIFO.  The whole chain short of hardware --
    daemon protocol, device-name whitelist, 159/158 -> RPgFwd/RPgBack through
    KOReader's verbatim input stack -- is proven offline (test_driver.py +
    pinenote/tools/koreader-input); the live end-to-end is step 1 of the
    next SSH session.

    Reader-side knobs ('ko' param namespace, stashed here by
    ShellDeviceDriver.set_ebc_params) are seeded into a DEDICATED
    KO_HOME's settings.reader.lua in prepare()'s stop->relaunch window, so
    every run records an explicit refresh regime and the dogfooding profile
    at /root/.config/koreader stays untouched."""

    INJECT_DAEMON = "/root/optics-inject.lua"    # the pushed uinput daemon
    INJECT_FIFO = "/run/optics-inject.fifo"
    INJECT_PID = "/run/optics-inject.pid"        # written by the daemon AFTER
                                                 # UI_DEV_CREATE = ready marker
    INJECT_LOG = "/var/log/optics-inject.log"
    EPUB_REMOTE = "/root/optics-testcard.epub"
    KO_HOME = "/root/.config/koreader-optics"    # dedicated per-capture profile
    LOG = "/var/log/optics-koreader.log"         # harvested per run (task 6)

    # Always-explicit reader settings, so the bundle records the regime it
    # measured (ko params override):
    #  - refresh_on_pages_with_images: readerview.lua:289 gates image-page
    #    full-refresh promotion on G_reader_settings:nilOrTrue(...) -- ABSENT
    #    means ON, so the key must be PRESENT and false to disable
    #    (makeFalse semantics; deleting it re-enables promotion).
    #  - full_refresh_count: UIManager's promotion cadence ("partial
    #    refreshes before the next gets promoted to full"); 0 = the menu's
    #    "Never", 6 = KOReader's DEFAULT_FULL_REFRESH_COUNT.
    #  - pinenote_flash_area_fraction: device.lua's flash policy threshold.
    KO_DEFAULTS = {
        "refresh_on_pages_with_images": False,
        "full_refresh_count": 6,
        "pinenote_flash_area_fraction": 0.60,
    }

    # Hard readiness check: FIFO present AND the daemon's pid (written only
    # after UI_DEV_CREATE) alive, polled up to ~10 s.  Runs in a child shell
    # so the `exit`s never touch the ACM console shell itself.
    ENSURE_INJECTOR = ("sh -c 'n=0; while [ $n -lt 50 ]; do "
                       "if [ -p {fifo} ] && "
                       "kill -0 \"$(cat {pid} 2>/dev/null)\" 2>/dev/null; "
                       "then exit 0; fi; sleep 0.2; n=$((n+1)); done; exit 1'")

    def __init__(self, transport, manifest):
        super().__init__(transport, manifest)
        self._ko_params = {}
        self._seeded_settings = None

    # -- 'ko' param namespace ------------------------------------------------
    def set_ko_params(self, ko):
        """Stash this run's reader-side params (the 'ko' namespace); consumed
        by prepare() into the seeded settings.reader.lua. Replaces the previous
        run's set. Returns the normalized values ('never' -> 0)."""
        norm = {}
        for k, v in (ko or {}).items():
            if k == "full_refresh_count" and isinstance(v, str):
                v = 0 if v == "never" else int(v)
            norm[k] = v
        self._ko_params = norm
        return dict(norm)

    # -- prepare: injector daemon -> stop old reader -> seed -> relaunch ------
    def prepare(self, epub_local=None):
        # 0. stage the test-card epub (once per session)
        if epub_local is not None:
            with open(epub_local, "rb") as f:
                self.t.push(f.read(), self.EPUB_REMOTE)
        rc, kodir = self.t.run("ls -d " + KOREADER_STORE + " 2>/dev/null | head -1")
        self._kodir = kodir.strip() or KOREADER_STORE
        # 1. injector daemon BEFORE KOReader: the uinput device must exist
        #    when KOReader enumerates input, and must persist afterwards
        #    (the daemon holds the fd; it survives across runs on purpose).
        self._start_injector()
        self._ensure_injector()
        # 2. stop the dogfooding reader AND any previous optics run's
        #    KOReader -- an exiting instance flushes G_reader_settings on
        #    the way out and would overwrite the seed below.
        self.t.run("herd stop reader-session 2>/dev/null; true")
        self.t.run("pkill -f 'reader.lua %s' 2>/dev/null; true" % self.EPUB_REMOTE)
        # 3. seed the dedicated KO_HOME with this run's explicit regime
        self._seed_ko_home()
        # 4. relaunch KOReader on the test card so page 0 is deterministic.
        #    ( ... & ) keeps the trailing background token inside a subshell:
        #    the serial transport appends '; printf <marker>' to every
        #    command, and a bare '... &;' is a shell syntax error.
        launch = ("( cd %s && HOME=/root KO_HOME=%s "
                  "PATH=/run/current-system/profile/bin LC_ALL=en_US.UTF-8 "
                  "./luajit reader.lua %s >%s 2>&1 & )"
                  % (shlex.quote(self._kodir), shlex.quote(self.KO_HOME),
                     shlex.quote(self.EPUB_REMOTE), self.LOG))
        self.t.run(launch)
        self._page = 0

    def _start_injector(self):
        """Stage optics-inject.lua and start it (idempotent): FIFO first, then
        the daemon under setsid via the koreader bundle's own luajit."""
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "optics-inject.lua")
        with open(src, "rb") as f:
            self.t.push(f.read(), self.INJECT_DAEMON)
        # FIFO created first: the daemon opens its read side at startup
        self.t.run("test -p %s || mkfifo %s"
                   % (self.INJECT_FIFO, self.INJECT_FIFO))
        # start only if not already alive -- the uinput device persisting
        # across KOReader relaunches is the whole point of the daemon
        self.t.run("kill -0 \"$(cat %s 2>/dev/null)\" 2>/dev/null || "
                   "( setsid %s/luajit %s >>%s 2>&1 & )"
                   % (self.INJECT_PID, shlex.quote(self._kodir),
                      shlex.quote(self.INJECT_DAEMON), self.INJECT_LOG))

    def _ensure_injector(self):
        """HARD check (PLAN task 1): raise unless the daemon is running and
        the FIFO exists. The pid file doubles as the UI_DEV_CREATE-succeeded
        marker, so passing here also means the uinput device exists before
        KOReader enumerates input."""
        rc, _ = self.t.run(self.ENSURE_INJECTOR.format(
            fifo=self.INJECT_FIFO, pid=self.INJECT_PID))
        if rc != 0:
            raise RuntimeError(
                "optics-inject daemon not running (no live pid at %s / no "
                "FIFO at %s): page turns cannot be injected -- check %s on "
                "the device" % (self.INJECT_PID, self.INJECT_FIFO,
                                self.INJECT_LOG))

    def _seed_ko_home(self):
        settings = dict(self.KO_DEFAULTS)
        settings.update(self._ko_params)
        body = "".join("    [%s] = %s,\n" % (_lua_repr(k), _lua_repr(v))
                       for k, v in sorted(settings.items()))
        content = ("-- seeded by the optics harness (driver.py); one dedicated\n"
                   "-- KO_HOME per capture -- KOReader rewrites this file on exit\n"
                   "return {\n%s}\n" % body)
        self.t.run("mkdir -p " + shlex.quote(self.KO_HOME))
        self.t.push(content.encode(), self.KO_HOME + "/settings.reader.lua")
        self._seeded_settings = dict(settings)   # for bundle attribution

    def _turn(self, delta):
        code = NEXT_PAGE_CODE if delta > 0 else PREV_PAGE_CODE
        for _ in range(abs(delta)):
            self.t.run("printf 'KEY %d\\n' > %s" % (code, self.INJECT_FIFO))
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
        """Set the frontlight (the standardized illuminant) to `level` on BOTH
        the warm and cool LED nodes, and return the level read back from the
        first that exists (or None if the frontlight is absent)."""
        applied = None
        for node in BACKLIGHT_NODES:
            self.t.run("printf %%s %s > %s/brightness 2>/dev/null" % (int(level), node))
            rc, back = self.t.run("cat %s/brightness 2>/dev/null" % node)
            if rc == 0 and back.strip():
                try:
                    applied = int(back.strip())
                except ValueError:
                    applied = level
        return applied

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
        """Apply one run's param set.  Two accepted shapes:

          * flat dict (back-compat): every key is a rockchip_ebc sysfs param;
          * namespaced {'ebc': {...}, 'ko': {...}}: 'ebc' goes to sysfs as
            before, 'ko' holds reader-side settings (full_refresh_count,
            pinenote_flash_area_fraction, ...) stashed on the KOReader
            backend and seeded into its KO_HOME at prepare() -- which
            run_scenario calls right after this, so ko params land in the
            same stop->relaunch window with zero extra restarts.

        Returns what was applied, in the same shape it was given."""
        params = params or {}
        if "ebc" in params or "ko" in params:
            unknown = set(params) - {"ebc", "ko"}
            if unknown:
                raise ValueError("unknown param namespace(s): %s"
                                 % ", ".join(sorted(unknown)))
            ko = dict(params.get("ko") or {})
            if hasattr(self.backend, "set_ko_params"):
                applied_ko = self.backend.set_ko_params(ko)
            elif ko:
                raise ValueError(
                    "'ko' params need the KOReader backend (the fb backend "
                    "has no reader to configure): %s" % ", ".join(sorted(ko)))
            else:
                applied_ko = {}
            return {"ebc": self._apply_ebc(params.get("ebc") or {}),
                    "ko": applied_ko}
        return self._apply_ebc(params)

    def _apply_ebc(self, params):
        applied = {}
        for k, v in (params or {}).items():
            path = "%s/%s" % (EBC_PARAM_DIR, k)
            self.t.run("printf %%s %s > %s" % (shlex.quote(str(v)), path))
            rc, back = self.t.run("cat %s 2>/dev/null" % path)
            applied[k] = back.strip() if rc == 0 and back else v
        return applied

    # -- trace harvest (PLAN task 6, driver side) --
    def harvest_trace(self):
        """The reader-side trace for the run that just finished: KOReader's
        stdout/err log (the [pn-refresh] intent lines) as text, or None when
        the backend has no reader log (fb backend) or the pull fails. The
        recorder side turns this into the trace.<run_id>.log sidecar."""
        log = getattr(self.backend, "LOG", None)
        if not log:
            return None
        try:
            data = self.t.pull(log)
        except Exception:
            return None
        if not data:
            return None
        return data.decode("utf-8", "replace")

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
