;;; Regression receipts from two production authorities, each with its own
;;; SQLite connection. The UI must accept these successful independent-CAS
;;; interleavings. No preview or source execution is involved.
;;; Extracted from the independent review's two-authority reproduction.
(use-modules (book-workspace) (workbench-authority) (rnrs io ports))

(define root (getenv "BOOK_WORKBENCH_TEST_ROOT"))
(unless root (error "BOOK_WORKBENCH_TEST_ROOT must name a private test directory"))
(define directory (string-append root "/ui-receipt-workspaces"))
(mkdir directory #o700)

(define (call authority op . arguments)
  (let ((reply (workbench-request! authority (cons (cons "op" op) arguments))))
    (unless (eq? #t (assoc-ref reply "ok")) (error "receipt fixture operation failed" reply))
    reply))
(define (emit sequence reply)
  (put-bytevector (current-output-port) (encode-workbench-line "reply" sequence reply)))
(define (with-pair name body)
  (let ((path (string-append directory "/" name)))
    (mkdir path #o700)
    (let* ((one (open-workspace-store path "seed"))
           (two (open-workspace-store path "seed"))
           (runner (lambda _ (error "receipt fixture must not execute source"))))
      (dynamic-wind
        (lambda () #t)
        (lambda () (body (make-workbench-authority one runner)
                         (make-workbench-authority two runner)))
        (lambda () (close-workspace-store! two) (close-workspace-store! one))))))

;; A opened v0/e0. B advances only activation to e1; A's draft CAS remains
;; valid, and the successful save returns v1/e1 with A's submitted bytes.
(with-pair "save"
  (lambda (a b)
    (emit 1 (call a "open"))
    (call b "rollback" '("expected_activation" . 0))
    (emit 2 (call a "save" '("expected_version" . 0) '("source" . "A draft")))))

;; A opened v0/e0. B advances only the draft to v1; A's activation CAS remains
;; valid, and rollback returns v1/e1 with B's newly committed draft.
(with-pair "rollback"
  (lambda (a b)
    (emit 1 (call a "open"))
    (call b "save" '("expected_version" . 0) '("source" . "B draft"))
    (emit 2 (call a "rollback" '("expected_activation" . 0)))))
