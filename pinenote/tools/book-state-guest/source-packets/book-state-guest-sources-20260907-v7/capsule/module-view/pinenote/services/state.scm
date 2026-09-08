(define-module (pinenote services state)
  #:use-module (gnu services)
  #:use-module (guix records)
  #:export (pinenote-state-configuration
            pinenote-state-configuration?
            pinenote-state-configuration-label
            pinenote-state-service-type))

(define-record-type* <pinenote-state-configuration>
  pinenote-state-configuration make-pinenote-state-configuration
  pinenote-state-configuration?
  (label pinenote-state-configuration-label
         (default "PNGuixState")))

(define pinenote-state-service-type
  (service-type
   (name 'pinenote-state)
   (extensions '())
   (default-value (pinenote-state-configuration))
   (description
    "Document the expected label for a later optional state partition.  This
service intentionally adds no activation code and performs no storage changes.")))
