;;; Test-only entry that substitutes a fixed fake-coordinator source roster.
;;; The production entry has no roster/source override.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (disposable-qemu)
             (disposable-reader-qemu)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define arguments (command-line))
(unless (>= (length arguments) 3)
  (error "test entry requires ROSTER and reader outer arguments"))
(define roster-path (cadr arguments))
(define roster
  (call-with-input-file roster-path read))
(define expected-relatives
  '("qemu-coordinator.scm"
    "fixture/bookinteractionprobe.koplugin/_meta.lua"
    "fixture/bookinteractionprobe.koplugin/main.lua"
    "fixture/bookinteractionprobe.koplugin/private_channel.lua"
    "fixture/bookinteractionprobe.koplugin/ui_audit.lua"))
(unless (and (list? roster)
             (= (length roster) 5)
             (equal? (map car roster) expected-relatives)
             (every (lambda (entry)
                      (and (pair? entry)
                           (string? (car entry))
                           (string? (cdr entry))
                           (= (string-length (cdr entry)) 64)
                           (every (lambda (character)
                                    (or (char-numeric? character)
                                        (and (char>=? character #\a)
                                             (char<=? character #\f))))
                                  (string->list (cdr entry)))))
                    roster))
  (error "invalid test-only fake coordinator roster"))
(module-set! (resolve-module '(disposable-reader-qemu))
             'coordinator-source-sha256 roster)
(define reader-arguments (cons (car arguments) (cddr arguments)))
(define package-tail (member "--koreader-package" reader-arguments string=?))
(unless (and package-tail (pair? (cdr package-tail)))
  (error "test entry lacks fake KOReader package"))
(module-set! (resolve-module '(disposable-reader-qemu))
             'expected-koreader-package
             (canonicalize-path (cadr package-tail)))

(umask #o077)
(sigaction SIGCHLD SIG_DFL)
(for-each
 (lambda (signal-number)
   (sigaction signal-number
              (lambda (received)
                (note-disposable-qemu-signal received))))
 (list SIGINT SIGTERM SIGHUP))
(exit (disposable-reader-qemu-main reader-arguments))
