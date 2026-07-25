(define-module (pinenote packages orientation)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages))

(define-public pinenote-orientation-bridge
  (package
    (name "pinenote-orientation-bridge")
    (version "0.1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build utils))
           #:builder
           #~(begin
               (use-modules (guix build utils))
               (let ((dir (string-append #$output "/share/pinenote-orientation")))
                 (mkdir-p dir)
                 (copy-file #$(local-file "../tools/orientation/orientation-bridge.lua")
                            (string-append dir "/orientation-bridge.lua"))
                 (copy-file #$(local-file "../tools/orientation/orientation_core.lua")
                            (string-append dir "/orientation_core.lua"))
                 (copy-file #$(local-file "../tools/orientation/orientation_scan.lua")
                            (string-append dir "/orientation_scan.lua"))))))
    (home-page "https://wiki.pine64.org/wiki/PineNote")
    (synopsis "Buffered SC7A20 orientation bridge for PineNote")
    (description "Create a persistent standard-uinput orientation device from coherent SC7A20 buffered IIO scans.")
    (license gpl3+)))
