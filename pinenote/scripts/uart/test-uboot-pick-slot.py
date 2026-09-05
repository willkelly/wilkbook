#!/usr/bin/env python3
"""Offline test of uboot-pick-slot.sh: the picker against a pseudo-terminal.

The harness owns the master side of a pty pair and hands the slave to the
script as its --tty.  Through the master it replays the REAL bytes the
2026-09-04 cold boot put on the UART (doc/artifacts/
pinenote-gen16-deploy-20260904/uart-coldboot.log: SPL, U-Boot, the
ANSI-drawn slot menu with its mid-line drops, extlinux's own generation
menu) and reads back what the script writes to the port.  It asserts:

  * the port is set up before the first read (the termios= line in the
    handle file says 1500000 baud, raw, no echo, no flow control);
  * the handle file names the script's pid, its process group (== pid: a
    group of its own, so `kill -- -PGID` reaps script and reader together)
    and the reader, whether the script was started the way make does
    (setsid execs in place) or the way a shell with job control does
    (setsid forks; the caller's pid is a wrapper that has exited);
  * nothing is sent before the slot menu -- not for U-Boot's earlier
    "Hit key to stop autoboot('CTRL+C')" prompt (fed both in its place in
    the boot and alone: it is different text from the menu's own "Hit any
    key to stop autoboot" countdown line), and not for extlinux's
    generation menu, which is drawn by the same bootmenu code and shares
    "U-Boot Boot Menu" and "Press UP/DOWN ..." with the slot menu;
  * the slot menu gets exactly the keystrokes for the slot (two DOWNs and
    ENTER for os2, one DOWN and ENTER for os1) from its ONE draw -- U-Boot
    draws the entries once and then reprints only the countdown line each
    second; the capture's later draws answer the picker's own keys -- even
    when that draw has "U-Boot Boot Menu", "Boot OS2 (part 6)" and "Search
    for extlinux.conf ..." each clipped by a 25-byte drop of the size the
    capture shows, and even when all three entry lines are clipped and
    only the countdown line "Hit any key to stop autoboot" is intact (the
    one string that repeats for the 15 s the menu is up);
  * the script exits 0 and records exit=0, the reader outlives it (the
    capture keeps running by design), and the recorded group reaps both;
  * with no menu it exits 1 after WILKBOOK_UBOOT_MENU_TIMEOUT seconds,
    records exit=1, and takes its reader with it;
  * reaped by its group before any menu, it records exit=terminated and
    never exit=0 (the handle's "menu seen, slot chosen") -- under `sh`,
    and under dash or bash too when the other is on PATH: bash runs an
    EXIT trap on an untrapped SIGTERM with $? of the last command, dash
    runs none, and the picker now traps TERM/INT/HUP itself.

No device, no /dev/ttyUSB*: run it anywhere with python3 and setsid.
"""
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
SCRIPT = os.path.join(HERE, 'uboot-pick-slot.sh')
CAPTURE = os.path.join(REPO, 'doc', 'artifacts', 'pinenote-gen16-deploy-20260904', 'uart-coldboot.log')

KEYS = {'os2': b'\x1b[B\x1b[B\r', 'os1': b'\x1b[B\r'}
DROP = 25  # bytes lost per drop in the captures (19-29 measured; device-access.md)
ENTRIES = (b'Search for extlinux.conf on all partitions', b'Boot OS1 (part 5)', b'Boot OS2 (part 6)')
COUNTDOWN = b'Hit any key to stop autoboot'

failures = 0
cases = 0


def check(cond, what):
    global failures
    if cond:
        print('  ok   ' + what)
    else:
        failures += 1
        print('  FAIL ' + what)


def capture_regions():
    lines = open(CAPTURE, 'rb').read().split(b'\n')
    # 1-based lines of the committed capture: 68 = "DDR Version" (SPL),
    # 219 = U-Boot's CTRL+C autoboot prompt, 220 = the slot menu (one line:
    # cursor escapes, no newlines) -- its one draw, the countdown line, and
    # the two redraws that answered the picker's DOWN, DOWN (the first after
    # the one keypress clear, the second directly after it) -- 221-232 =
    # extlinux, its generation menu, the kernel load.
    pre = b'\n'.join(lines[67:219]) + b'\n'
    prompt = lines[218] + b'\n'
    menu = lines[219] + b'\n'
    post = b'\n'.join(lines[220:232]) + b'\n'
    assert pre.startswith(b'DDR Version'), pre[:40]
    assert prompt.startswith(b"Hit key to stop autoboot('CTRL+C')"), prompt
    assert pre.endswith(prompt) and COUNTDOWN not in pre
    assert b'*** U-Boot Boot Menu ***' in menu and all(e in menu for e in ENTRIES)
    assert menu.count(COUNTDOWN) == 1 and menu.count(b'\x1b[9;1H\x1b[2K') == 2, "one countdown value; draw 1's own statusline clear plus the one post-countdown keypress clear"
    assert b'wilkbook generations' in post and b'Press UP/DOWN to move, ENTER to select' in post
    assert b'Enter choice:' in post and COUNTDOWN not in post
    assert b'Boot OS' not in post and b'Search for extlinux' not in post
    return pre, prompt, menu, post


def clip(data, needle):
    """Model the capture's drops: lose DROP bytes from each occurrence of needle."""
    out = bytearray()
    i = 0
    while True:
        j = data.find(needle, i)
        if j < 0:
            out += data[i:]
            return bytes(out)
        out += data[i:j + 3]  # the first bytes of the string arrive, then the hole
        i = j + 3 + DROP


def alive(pid):
    try:
        os.kill(pid, 0)
        with open('/proc/%d/stat' % pid) as f:
            state = f.read().rsplit(')', 1)[1].split()[0]
        return state not in ('Z', 'X')
    except (ProcessLookupError, FileNotFoundError):
        return False


def read_handle(path):
    h = {}
    try:
        with open(path) as f:
            for line in f:
                k, _, v = line.rstrip('\n').partition('=')
                h[k] = v
    except FileNotFoundError:
        pass
    return h


def wait_until(pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def feed(master, data):
    for k in range(0, len(data), 256):
        os.write(master, data[k:k + 256])
        time.sleep(0.002)


def read_keys(master, want, seconds):
    got = b''
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            got += os.read(master, 4096)
            if len(got) >= len(want):
                # a short grace for anything extra the script might send
                r, _, _ = select.select([master], [], [], 0.3)
                if r:
                    got += os.read(master, 4096)
                break
    return got


def run_case(name, feeds, slot='os2', timeout=20, via_setsid=False, expect_pick=True, reap=False, shell='sh'):
    global cases
    cases += 1
    print('== ' + name)
    # The directory goes with the case, pass or fail: mkdtemp alone left a
    # /tmp/uboot-pick-* behind on every `make check-host`.
    with tempfile.TemporaryDirectory(prefix='uboot-pick-') as tmp:
        master, slave = os.openpty()
        p = pgid = None
        try:
            p, pgid = drive_case(tmp, master, slave, feeds, slot, timeout, via_setsid, expect_pick, reap, shell)
        finally:
            if pgid:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if p is not None:
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            os.close(master)
            os.close(slave)


def drive_case(tmp, master, slave, feeds, slot, timeout, via_setsid, expect_pick, reap, shell):
    log = os.path.join(tmp, 'uart.log')
    pick = log + '.pick'
    handle = log + '.watcher'
    tty = os.ttyname(slave)
    cmd = [shell, SCRIPT, log, '--slot', slot, '--tty', tty]
    if via_setsid:
        cmd = ['setsid'] + cmd
    env = dict(os.environ, WILKBOOK_UBOOT_MENU_TIMEOUT=str(timeout))
    with open(pick, 'wb') as out:
        # start_new_session: the child is a session leader, as under make's
        # `setsid sh ... &` (execs in place) -- and with via_setsid the
        # setsid(1) in front finds itself a group leader and forks, which is
        # exactly what a shell with job control does to `setsid sh ... &`.
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    check(wait_until(lambda: 'reader' in read_handle(handle), 5), 'handle file %s appears with reader= within 5 s' % handle)
    h = read_handle(handle)
    pid = int(h.get('pid', 0) or 0)
    pgid = int(h.get('pgid', 0) or 0)
    reader = int(h.get('reader', 0) or 0)
    termios = h.get('termios', '')
    if via_setsid:
        check(pid != p.pid and p.wait(timeout=5) == 0, 'setsid forked: the caller\'s pid %d is a wrapper that exited, the file says pid %d' % (p.pid, pid))
    else:
        check(pid == p.pid, 'pid= is the script itself (%d)' % pid)
    check(pid > 0 and alive(pid), 'the script is alive')
    check(pgid == pid and os.getpgid(pid) == pgid, 'pgid= %d is the script\'s own group (a group of its own to reap)' % pgid)
    check(reader > 0 and alive(reader) and os.getpgid(reader) == pgid, 'reader= %d is alive and in that group' % reader)
    for want in ('speed 1500000 baud', '-icanon', '-echo ', '-ixon', '-ixoff', '-crtscts', '-icrnl', '-inlcr', '-igncr', '-opost', '-isig', 'clocal', 'cs8', '-parenb', '-cstopb', 'min = 1'):
        check(want in termios, 'termios: %s' % want)

    got = b''
    for label, data in feeds:
        feed(master, data)
        if label == 'menu':
            got = read_keys(master, KEYS[slot], 10)
        else:
            r, _, _ = select.select([master], [], [], 0.7)
            check(not r, 'nothing sent for %s' % label)
    if reap:
        check('exit' not in read_handle(handle), 'no exit= before the reap')
        os.killpg(pgid, signal.SIGTERM)
        check(wait_until(lambda: not alive(pid), 5), 'kill -- -%d (SIGTERM) ended the script' % pgid)
        h = read_handle(handle)
        check(h.get('exit') != '0', 'the handle does not say exit=0 -- "menu seen, slot chosen" -- for a reaped picker (%r)' % h.get('exit'))
        check(h.get('exit') == 'terminated', 'exit=terminated recorded (%r)' % h.get('exit'))
        check(got == b'', 'nothing sent at all (got %r)' % got)
        check(b'== menu seen' not in open(pick, 'rb').read(), 'no pick was reported')
        check(wait_until(lambda: not alive(reader), 5), 'the group signal took the reader too')
    elif expect_pick:
        check(got == KEYS[slot], 'the slot menu got exactly %r for %s (got %r)' % (KEYS[slot], slot, got))
        check(wait_until(lambda: not alive(pid), 12), 'the script exited after its post-pick summary')
        h = read_handle(handle)
        check(h.get('exit') == '0', 'exit=0 recorded (%r)' % h.get('exit'))
        picked = open(pick, 'rb').read()
        check(b'== menu seen at poll' in picked and (': selected %s' % slot).encode() in picked, 'the pick was reported: ' + repr([l for l in picked.split(b'\n') if l.startswith(b'== menu')]))
        captured = open(log, 'rb').read()
        check(b'DDR Version' in captured and b'Hit any key' in captured, 'the capture holds what the port said (%d bytes)' % len(captured))
        check(alive(reader), 'the reader outlives the pick (the capture keeps running)')
        os.killpg(pgid, signal.SIGTERM)
        check(wait_until(lambda: not alive(reader), 5), 'kill -- -%d reaped the reader' % pgid)
    else:
        check(got == b'', 'nothing sent at all (got %r)' % got)
        check(wait_until(lambda: not alive(pid), timeout + 6), 'the script gave up within %d s + slack' % timeout)
        h = read_handle(handle)
        check(h.get('exit') == '1', 'exit=1 recorded (%r)' % h.get('exit'))
        picked = open(pick, 'rb').read()
        check(('!! no U-Boot menu in %d s' % timeout).encode() in picked, 'the timeout was reported')
        check(wait_until(lambda: not alive(reader), 5), 'the reader was taken down with it')
    return p, pgid


def reap_shells():
    """`sh`, plus whichever of dash and bash is on PATH and is not what sh resolves to."""
    sh = shutil.which('sh')
    real = os.path.realpath(sh) if sh else ''
    shells = ['sh']
    for alt in ('dash', 'bash'):
        w = shutil.which(alt)
        if w and os.path.realpath(w) != real:
            shells.append(alt)
    return shells, real


def main():
    if not os.path.exists(CAPTURE):
        print('missing capture: ' + CAPTURE)
        return 2
    pre, prompt, menu, post = capture_regions()
    clipped = clip(clip(clip(menu, b'U-Boot Boot Menu'), b'Boot OS2 (part 6)'), b'Search for extlinux.conf on all partitions')
    assert b'U-Boot Boot Menu' not in clipped and b'Boot OS2 (part 6)' not in clipped and b'Search for extlinux' not in clipped
    assert b'Boot OS1 (part 5)' in clipped
    countdown_only = menu
    for e in ENTRIES:
        countdown_only = clip(countdown_only, e)
    assert not any(e in countdown_only for e in ENTRIES) and COUNTDOWN in countdown_only
    run_case('the real cold-boot bytes, os2 (started as make starts it)',
             [('SPL, U-Boot and its CTRL+C autoboot prompt', pre), ('menu', menu), ('extlinux and the generation menu', post)])
    run_case('the same, os1', [('SPL and U-Boot', pre), ('menu', menu)], slot='os1')
    run_case('the one draw with "U-Boot Boot Menu", "Boot OS2 (part 6)" and "Search for extlinux.conf ..." each clipped by a %d-byte drop' % DROP,
             [('SPL and U-Boot', pre), ('menu', clipped)])
    run_case('all three entry lines clipped by a %d-byte drop; only the countdown line "Hit any key to stop autoboot" intact' % DROP,
             [('SPL and U-Boot', pre), ('menu', countdown_only)])
    run_case('started as a shell with job control starts it (setsid forks; $! is the wrapper)',
             [('SPL and U-Boot', pre), ('menu', menu)], via_setsid=True)
    run_case('no slot menu: U-Boot\'s CTRL+C prompt, then extlinux\'s generation menu -- neither is answered; the script gives up',
             [('SPL, U-Boot and its CTRL+C autoboot prompt', pre), ('extlinux and the generation menu (shares "U-Boot Boot Menu" and "Press UP/DOWN")', post)],
             timeout=2, expect_pick=False)
    run_case('the pre-menu "Hit key to stop autoboot(\'CTRL+C\')" line alone -- not the countdown line, not answered; the script gives up',
             [('the CTRL+C autoboot prompt by itself', prompt)], timeout=2, expect_pick=False)
    shells, real = reap_shells()
    for shell in shells:
        run_case('reaped by its group before any menu, under %s%s: the handle says exit=terminated, never exit=0' % (shell, ' (%s)' % real if shell == 'sh' else ''),
                 [('SPL and U-Boot', pre)], reap=True, shell=shell)
    if failures:
        print('FAIL: %d assertion(s) in %d cases' % (failures, cases))
        return 1
    print('PASS: %d cases -- uboot-pick-slot.sh picks the slot from the real captured menu bytes, records a reapable handle that never claims a pick it did not make, and gives up without one' % cases)
    return 0


if __name__ == '__main__':
    sys.exit(main())
