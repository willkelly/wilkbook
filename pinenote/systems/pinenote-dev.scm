(define-module (pinenote systems pinenote-dev)
  #:use-module (pinenote systems base)
  #:export (pinenote-dev-operating-system))

(define pinenote-dev-operating-system
  (make-pinenote-operating-system
   #:host-name "pinenote-dev"
   #:services %pinenote-dev-services))

pinenote-dev-operating-system
