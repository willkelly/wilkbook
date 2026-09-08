;;; Synthetic binding injection for host-only unit tests.
;;; Production code and its CLI never import this module.
(define-module (two-boot bundle-test-fixture)
  #:use-module (srfi srfi-13)
  #:use-module (two-boot bundle)
  #:use-module (two-boot image-binding)
  #:export (synthetic-bundle-metadata
            synthetic-image-binding
            validate-synthetic-binding!))

(define (h character) (make-string 64 character))

(define metadata-fields (@@ (two-boot bundle) metadata-fields))

(define (synthetic-field name)
  (case name
    ((schema) 3)
    ((bundle-id) "synthetic-unit-binding")
    ((image-partition-table) 'dos-mbr-not-gpt)
    ((prepared-payload-source-transformation) 'private-ext4-label-only)
    ((image-output-size) 2063552512)
    ((image-partition-start-sector) 2048)
    ((image-partition-sector-count) 4028328)
    ((image-partition-byte-offset) 1048576)
    ((image-partition-byte-size) 2062503936)
    ((prepared-payload-source-changed-bytes) 97)
    ((prepared-payload-source-changed-ranges) 27)
    ((guest-cooperative-budget-seconds) 300)
    ((required-outer-qemu-timeout-seconds) 360)
    ((required-outer-term-grace-seconds) 5)
    ((image-source-filesystem-label) "Guix_image")
    ((root-filesystem-label) "PNGuixRoot")
    ((state-filesystem-label) "WBBookStateV1")
    (else
     (if (string-suffix? "sha256" (symbol->string name))
         (h #\a)
         "synthetic-closed-role-value"))))

(define synthetic-bundle-metadata
  (map (lambda (name) (cons name (synthetic-field name))) metadata-fields))

(define synthetic-image-binding
  (append
   `((schema . 3)
     (status . available)
     (unavailable-reason . none)
     (binding-id . "synthetic-unit-binding")
     (binding-evidence-sha256 . ,(h #\b))
     (bundle-manifest-sha256 . ,(h #\c)))
   (cdr synthetic-bundle-metadata)))

(define (validate-synthetic-binding! metadata binding)
  ((@@ (two-boot bundle)
       validate-two-boot-bundle-metadata-against-binding!)
   metadata binding))
