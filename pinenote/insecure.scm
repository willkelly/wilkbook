(define-module (pinenote insecure)
  #:export (%very-insecure-for-convenience?
            insecure-build-marker
            insecure-build-banner))

;; Development conveniences that must never ship on by accident.
;;
;; The problem was never that this device has an unauthenticated root
;; shell -- for bring-up on a device with one USB port and no serial wake
;; source, that is the difference between a five-minute fix and a
;; teardown.  The problem was that it was UNCONDITIONAL and INVISIBLE: a
;; built image gave no way to tell whether it carried them, and nobody
;; had to decide.
;;
;; So they are opt-in, off by default, and an image that carries them
;; SAYS SO -- see insecure-build-marker, which lands in /etc on every
;; build either way.  A image you cannot interrogate is worse than an
;; insecure one you can.
;;
;; Turn it on for a build with either:
;;
;;   WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE=1 make image-reader
;;
;; or, so you do not have to remember it every time, a gitignored
;; local.mk at the repo root:
;;
;;   export WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE = 1
;;
;; The Makefile `-include`s that file, so it is per-checkout and cannot
;; be committed by accident (.gitignore carries it).
;;
;; What it gates today:
;;   * the USB ACM gadget console, which execs a shell on /dev/ttyGS0
;;     with NO login prompt at all;
;;   * passwordless sudo for the `reader` account, which is what makes
;;     that shell root-equivalent.
;; Both are listed explicitly rather than "the insecure stuff", so
;; adding to the list is a deliberate edit and shows up in review.

(define %very-insecure-for-convenience?
  (let ((value (getenv "WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE")))
    (and value
         ;; Accept only affirmative spellings.  An unset-but-exported
         ;; empty variable, or a leftover "0", must read as OFF -- the
         ;; failure that matters here is shipping the conveniences by
         ;; accident, so anything ambiguous resolves to secure.
         (member (string-downcase value) '("1" "yes" "true" "on"))
         #t)))

;; Written into /etc on EVERY build, both ways round, so a running system
;; and a mounted image can both answer "which build is this?" without
;; guessing from behaviour.
(define (insecure-build-marker)
  (if %very-insecure-for-convenience?
      "\
WILKBOOK_BUILD=very-insecure-for-convenience
# This image carries development conveniences that a shipped reader must
# not have: an unauthenticated root-equivalent shell on the USB ACM
# gadget, and passwordless sudo for the reader account.  Anyone with
# physical access and a USB cable owns this device.  It was built this
# way ON PURPOSE, by setting WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE.
"
      "\
WILKBOOK_BUILD=default
# No development conveniences: no unauthenticated gadget console, no
# passwordless sudo.  Recovery is the UART or a reflash.
"))

(define (insecure-build-banner)
  (if %very-insecure-for-convenience?
      "\n*** VERY INSECURE BUILD: unauthenticated USB console, passwordless sudo. ***\n"
      ""))
