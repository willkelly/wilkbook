#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Host-only stand-in for a VM plus a TERM-resistant writer descendant.
(use-modules (ice-9 textual-ports))

(define (start-time pid)
  (let* ((text (call-with-input-file (format #f "/proc/~a/stat" pid)
                 get-string-all))
         (close (string-rindex text #\)))
         (fields (string-tokenize (substring text (+ close 2)))))
    (list-ref fields 19)))

(define (write-record path role pid)
  (let ((port (fdopen (open-fdes path
                                 (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC)
                                 #o600)
                      "w")))
    (write `((schema . 1) (role . ,role) (pid . ,pid)
             (start-time . ,(start-time pid))) port)
    (newline port)
    (force-output port)
    (close-port port)))

(unless (= (length (command-line)) 2)
  (primitive-exit 2))
(for-each (lambda (signal-number) (sigaction signal-number SIG_IGN))
          (list SIGINT SIGHUP SIGTERM SIGPIPE))
(let ((child (primitive-fork)))
  (if (zero? child)
      (let loop () (usleep 100000) (loop))
      (begin
        (write-record (cadr (command-line)) 'stubborn-writer child)
        (usleep 50000)
        (display "COOPERATIVE_GUEST_BUDGET_EXPIRED_BUT_HELPER_STILL_LIVE\n")
        (force-output)
        (let loop () (usleep 100000) (loop)))))
