(define-module (pinenote systems pinenote-reader-debug)
  #:use-module (gnu system)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote systems pinenote-reader)
  #:export (pinenote-reader-debug-operating-system))

;; The reader flavor with the quirk F diagnostic kernel
;; (linux-pinenote-debug: printk-only DSP_END straggler instrumentation;
;; doc/driver-findings-report.md, finding 2026-07-12).  Only the kernel
;; and the host name differ from pinenote-reader, so a hardware session
;; A/Bs the instrumented kernel with zero userspace delta; the host name
;; makes the flashed slot identifiable at the login prompt.  Delete this
;; file together with the linux-pinenote-debug variant and its patch when
;; the investigation closes.

(define pinenote-reader-debug-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-dbg")
    (kernel linux-pinenote-debug)))

pinenote-reader-debug-operating-system
