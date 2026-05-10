(define-module (pinenote services diagnostics)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages system-tools)
  #:export (pinenote-diagnostics-service-type))

(define (pinenote-diagnostics-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-diagnostics))
    (requirement '(root-file-system udev))
    (documentation "Run read-only PineNote diagnostics once during boot.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$(file-append pinenote-diagnostics
                                        "/bin/pinenote-diagnostics")))))
    (stop #~(const #t)))))

(define pinenote-diagnostics-service-type
  (service-type
   (name 'pinenote-diagnostics)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-diagnostics-shepherd-service)))
   (default-value #f)
   (description "Run PineNote boot diagnostics without mutating storage or boot configuration.")))
