;;; Verify that the functional run selects only the newly compiled app cache.
(use-modules (book-protocol)
             (book-state)
             (book-state-backend-adapter)
             (book-state-operation-id)
             (book-state-protocol)
             (ice-9 format))

(define expected (cadr (command-line)))
(unless (string=? (car %load-compiled-path) expected)
  (error "private adapter ccache is not first" %load-compiled-path))

;; This private V2-only manifest constant distinguishes the accepted backend
;; correction from the rejected V1 source in addition to compile provenance.
(unless (equal? (@@ (book-state) known-schema-table-names)
                '("metadata" "book_instances" "commit_receipts"))
  (error "loaded Book State module lacks accepted V2 schema identity"))

(format #t "BOUND-CCACHE first=~a~%" (car %load-compiled-path))
(display "PASS: private adapter ccache loaded accepted backend V2 identity\n")
