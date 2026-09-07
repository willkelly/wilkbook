;;; Test-only adapter for exercising the Guile module with a fake store.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (ice-9 rdelim)
             (oci-bundle))

(define (read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse lines)
              (loop (cons line lines))))))))

(define (main arguments)
  (catch 'book-execution-bundle-error
    (lambda ()
      (case (string->symbol (car arguments))
        ((generate)
         (let ((profile (list-ref arguments 1))
               (book (list-ref arguments 2))
               (bundle (list-ref arguments 3))
               (store (list-ref arguments 4))
               (closure-file (list-ref arguments 5))
               (execution-profile (list-ref arguments 6))
               (container-id (list-ref arguments 7)))
           (display
            (generate-bundle
             #:profile-input profile
             #:book-input book
             #:bundle-input bundle
             #:container-id container-id
             #:execution-profile execution-profile
             #:requisites-runner (lambda (_) (read-lines closure-file))
             #:store-root store))
           (newline)))
        ((guix-requisites)
         (for-each
          (lambda (line) (display line) (newline))
          (run-guix-requisites (list-ref arguments 1)
                                (list-ref arguments 2))))
        ((json-controls)
         (display
          (bundle-json-string
           `(("controls" . ,(list->string
                              (map integer->char (iota 32))))
             ("supplementary" . "😀"))))
         (newline))
        (else (error "unknown test adapter mode" (car arguments))))
      0)
    (lambda (key message)
      (format (current-error-port) "FAIL: ~a~%" message)
      1)))

(exit (main (cdr (command-line))))
