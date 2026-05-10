(define-module (pinenote systems pinenote-slim)
  #:use-module (pinenote systems base)
  #:export (pinenote-slim-operating-system))

(define pinenote-slim-operating-system
  (make-pinenote-operating-system
   #:host-name "pinenote-slim"
   ;; Intentionally omit Guix %base-packages to measure the smallest current
   ;; PineNote release-slot target.
   #:packages %pinenote-local-packages))

pinenote-slim-operating-system
