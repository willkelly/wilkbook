(define-module (pinenote systems pinenote-reader-debug)
  #:use-module (gnu system)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote systems pinenote-reader)
  #:export (pinenote-reader-debug-operating-system))

;; The reader flavor with the diagnostic kernel (linux-pinenote-debug:
;; the EXTRACT_FBS belief-dump ioctl; doc/driver-findings-report.md and
;; doc/pageturn-program.md §5.2).  Deltas from pinenote-reader: the
;; kernel, the host name (makes the flashed slot identifiable at the
;; login prompt), and one inert CLI tool (ebc-dump-grab, the EXTRACT_FBS
;; grabber — it only acts when invoked, so kernel A/Bs stay clean).
;; Delete this file together with the linux-pinenote-debug variant and
;; its patches when the investigations close.

(define pinenote-reader-debug-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-dbg")
    (kernel linux-pinenote-debug)
    (packages (cons pinenote-ebc-dump
                    (operating-system-packages
                     pinenote-reader-operating-system)))))

pinenote-reader-debug-operating-system
