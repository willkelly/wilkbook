;;; Runtime-only adapter from the accepted outer QEMU runner's checker hook to
;;; the accepted Book Protocol semantic checker.  This module intentionally
;;; has the legacy module name expected by disposable-qemu.scm; the runtime
;;; launcher places it in an isolated, hash-checked module view.
(define-module (guest-console-assertions)
  #:use-module (ice-9 textual-ports)
  #:use-module (protocol-console-assertions)
  #:use-module (srfi srfi-13)
  #:export (assert-guest-console-file))

(define max-console-bytes (* 16 1024 1024))

(define (assert-clean-power-down-file path)
  (let ((info (stat path)))
    (unless (eq? (stat:type info) 'regular)
      (throw 'book-execution-protocol-console-error
             "guest console path is not a regular file"))
    (when (> (stat:size info) max-console-bytes)
      (throw 'book-execution-protocol-console-error
             "guest console file exceeds the 16 MiB assertion bound")))
  (let ((text (call-with-input-file path get-string-all)))
    (unless (string-contains text "reboot: Power down")
      (throw 'book-execution-protocol-console-error
             "guest console lacks clean kernel power-down"))))

(define (assert-guest-console-file path)
  ;; The protocol checker proves the ordered semantic/cleanup chain.  Clean
  ;; kernel power-down is a separate outer-VM condition and is checked only
  ;; after that protocol chain succeeds.
  (assert-protocol-guest-console-file path)
  (assert-clean-power-down-file path)
  #t)
