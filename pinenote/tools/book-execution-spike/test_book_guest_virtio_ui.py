#!/usr/bin/env python3
"""Host regressions for the guest named virtio character-port adapter."""

from __future__ import annotations

import errno
import fcntl
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import termios
import tty
import unittest


HERE = Path(__file__).resolve().parent
PRIVATE_CONTROL = HERE.parent / "book-interaction"
REPO = HERE.parents[2]


class GuestVirtioBookUiTests(unittest.TestCase):
    def guile(self, expression: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "GUILE_LOAD_COMPILED_PATH": "",
            "HOME": "/nonexistent",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
        }
        return subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                str(PRIVATE_CONTROL),
                "-L",
                str(HERE),
                "-c",
                expression,
                *arguments,
            ],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )

    def test_real_character_device_via_udev_style_symlink(self) -> None:
        master, slave = pty.openpty()
        previous = termios.tcgetattr(slave)
        try:
            tty.setraw(slave)
            target = os.ttyname(slave)
            os.set_blocking(master, False)
            with tempfile.TemporaryDirectory(
                prefix="wilkbook-virtio-port-", dir="/tmp/opencode"
            ) as raw:
                link = Path(raw) / "org.wilkbook.book-interaction"
                link.symlink_to(target)
                os.write(master, b"ready|1|6469616c6f67\n")
                expression = r"""
(use-modules (guest-virtio-book-ui))
(define now (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(define control
  (open-book-ui-control! (+ now 2.0) #:path (cadr (command-line))))
(queue-book-ui-command! control 'input-update 1 "élan λ")
(let output-loop ()
  (unless (eq? (car (pump-book-ui-output! control)) 'drained)
    (usleep 1000)
    (output-loop)))
(let input-loop ()
  (let ((event (pump-book-ui-input! control)))
    (if (list? event)
        (begin (write event) (newline))
        (begin (usleep 1000) (input-loop)))))
(let ((fd (book-ui-control-fd control)))
  (format #t "flags=~a,~a type=~a~%"
          (= (logand (fcntl fd F_GETFL) O_NONBLOCK) O_NONBLOCK)
          (= (logand (fcntl fd F_GETFD) FD_CLOEXEC) FD_CLOEXEC)
          (stat:type (stat fd))))
(close-book-ui-control! control)
"""
                result = self.guile(expression, str(link))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    result.stdout,
                    '(ready 1 "dialog")\nflags=#t,#t type=char-special\n',
                )
                self.assertEqual(result.stderr, "")
                received = bytearray()
                while True:
                    try:
                        chunk = os.read(master, 4096)
                    except BlockingIOError:
                        break
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    received.extend(chunk)
                self.assertEqual(
                    bytes(received), b"input-update|1|c3a96c616e20cebb\n"
                )
        finally:
            termios.tcsetattr(slave, termios.TCSANOW, previous)
            os.close(slave)
            os.close(master)

    def test_non_symlink_and_missing_named_port_fail_closed(self) -> None:
        expression = r"""
(use-modules (guest-virtio-book-ui))
(define now (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(catch 'book-interaction-ui-channel-error
  (lambda ()
    (open-book-ui-control! (+ now 0.05) #:path (cadr (command-line)))
    (exit 90))
  (lambda (key kind message)
    (format #t "~a:~a~%" kind message)))
"""
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-virtio-negative-", dir="/tmp/opencode"
        ) as raw:
            root = Path(raw)
            regular = root / "regular"
            regular.write_text("not a device\n", encoding="ascii")
            missing = root / "missing"
            for path, kind in ((regular, "type:"), (missing, "deadline:")):
                with self.subTest(path=path):
                    result = self.guile(expression, str(path))
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertTrue(result.stdout.startswith(kind), result.stdout)
                    self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
