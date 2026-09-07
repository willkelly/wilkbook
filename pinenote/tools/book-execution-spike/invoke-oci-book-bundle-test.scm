;;; Host-test adapter for the fixed protocol OCI generator.  Not installed.
(use-modules (ice-9 match)
             (ice-9 rdelim)
             (oci-book-bundle))

(define (read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse lines)
              (loop (cons line lines))))))))

(match (cdr (command-line))
  (("guile" profile entry protocol blocking bundle store closure container-id)
   (generate-guile-protocol-bundle
    #:profile-input profile
    #:book-entry-input entry
    #:protocol-input protocol
    #:blocking-input blocking
    #:bundle-input bundle
    #:container-id container-id
    #:store-root store
    #:requisites-runner (lambda (_profile) (read-lines closure)))
   (display bundle)
   (newline))
  (("python" profile entry protocol bundle store closure container-id)
   (generate-python-protocol-bundle
    #:profile-input profile
    #:book-entry-input entry
    #:protocol-input protocol
    #:bundle-input bundle
    #:container-id container-id
    #:store-root store
    #:requisites-runner (lambda (_profile) (read-lines closure)))
   (display bundle)
   (newline))
  (_
   (error "invalid fixed protocol OCI host-test invocation")))
