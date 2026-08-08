(define-module (pinenote systems pinenote-reader-ultra)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote systems pinenote-reader)
  #:export (pinenote-reader-ultra-operating-system))

;; BENCH-ONLY flavor: the reader with hrdl's ultra rail payload.
;;
;; This image suspends with vcca_1v8_pmu, vdda_0v9_pmu and vcc_3v3_pmu OFF.
;; The last of those powers pmuio1/pmuio2 -- the GPIO0 pad bank carrying
;; every external wake interrupt on this board.  If the wake question does
;; not resolve the way hrdl's device resolves it, a suspend on this image
;; ends in a ten-second power-button hold.  Never deploy it to a device
;; you are not sitting in front of with a UART attached.
;;
;; It exists because R11 (2026-08-08) measured what ultra is worth --
;; ~3 mA against deep's ~20 mA, i.e. roughly 7 days of standby versus 35 --
;; and showed the wake failure is NOT misconfiguration: firmware received
;; bit-for-bit identical words on the mem suspend that woke and the ultra
;; suspend that did not, printing "Enable GPIO0 interrupt as wakeup source"
;; both times.  The rails are the entire remaining difference from the only
;; configuration anyone has working.
;;
;; TWO DELIBERATE DIFFERENCES FROM THE READER, both safety rather than taste:
;;
;;   1. Auto-suspend ships DISABLED.  Rails-off + `mem' is every bit as
;;      unsupported as the rails-on + ultra we already proved unwakeable --
;;      it is the same experiment with the other half missing.  An image
;;      that idles into that state unattended is the failure we are trying
;;      to study, arriving by accident.  The operator arms each suspend by
;;      hand, with ultra_arm set, while watching.
;;   2. A distinct host name, so the flashed slot is identifiable at a
;;      login prompt and nobody mistakes this for the reader.
;;
;; Delete this file, linux-pinenote-ultra, and
;; pinenote/patches/linux-pinenote-7.0-ultra-rails.patch together once the
;; question is answered either way.

(define %ultra-autosuspend-off
  ;; The daemon reads /data/wilkbook/autosuspend.conf first and falls back
  ;; to /var/lib.  p7 survives a reflash and therefore may already carry an
  ;; enabled=1 from the reader; this file cannot override that, which is
  ;; exactly why the procedure has the operator check p7 by hand as a
  ;; precondition rather than trusting the image.
  (plain-file "autosuspend.conf"
              "# BENCH IMAGE: auto-suspend is off on purpose.\n\
# Suspending this image with the PMU rails cut is a supervised experiment,\n\
# not something to drift into while idle.  See\n\
# doc/artifacts/pinenote-ultra-r11-20260808/ and the procedure beside it.\n\
enabled=0\n\
idle=300\n\
backstop=3600\n"))

(define pinenote-reader-ultra-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-ultra")
    (kernel linux-pinenote-ultra)
    (services
     (cons (simple-service 'pinenote-ultra-autosuspend-off
                           etc-service-type
                           (list `("wilkbook-autosuspend-default"
                                   ,%ultra-autosuspend-off)))
           (operating-system-user-services pinenote-reader-operating-system)))))

pinenote-reader-ultra-operating-system
