(define-module (pinenote systems pinenote-reader-ultra)
  #:use-module (srfi srfi-1)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote services autosuspend)
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
;;   1. The auto-suspend service is NOT INSTALLED.  Not "configured off" --
;;      absent.  The first cut of this flavor shipped an /etc file saying
;;      the daemon was off, which nothing reads: the daemon's config lives on p7
;;      (/data/wilkbook/autosuspend.conf, which survives reflashes and may
;;      carry enabled=1 from the reader) with a /var/lib fallback.  A
;;      safety property that depends on a file the code never opens is not
;;      a property.  Removing the service removes the whole class: no idle
;;      timer, no power-tap suspend, no RTC-backstop re-suspend.  On this
;;      image every suspend is an operator running ultra-run.sh over SSH
;;      while watching the UART, which is the point.
;;   2. A distinct host name, so the flashed slot is identifiable at a
;;      login prompt and nobody mistakes this for the reader.
;;
;; Delete this file, linux-pinenote-ultra, and
;; pinenote/patches/linux-pinenote-7.0-ultra-rails.patch together once the
;; question is answered either way.

(define pinenote-reader-ultra-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-ultra")
    (kernel linux-pinenote-ultra)
    (services
     (remove (lambda (service)
               (eq? (service-kind service) pinenote-autosuspend-service-type))
             (operating-system-user-services pinenote-reader-operating-system)))))

pinenote-reader-ultra-operating-system
