;;; Trusted mapping between the typed state model and the durable backend.
(define-module (book-state-backend-adapter)
  #:use-module (book-state)
  #:use-module (book-state-operation-id)
  #:use-module (book-state-protocol)
  #:use-module (rnrs bytevectors)
  #:export (book-state-operation-id-contract-aligned?
            run-state-backend-operation
            revoke-state-backend-binding!
            close-state-session-and-revoke!))

(define (adapter-error code message)
  (throw 'book-state-backend-adapter-error code message))

(define (utf8-size text)
  (bytevector-length (string->utf8 text)))

(define (book-state-operation-id-contract-aligned?)
  (= book-state-wire-max-operation-id-bytes
     book-state-max-operation-id-bytes
     max-state-operation-id-bytes))

(define (operation-id-valid! operation-id)
  (unless (book-state-operation-id-contract-aligned?)
    (adapter-error 'operation-id-limit-mismatch
                   "protocol, client, and backend operation-ID limits differ"))
  (let ((wire-valid? (book-state-wire-operation-id? operation-id))
        (backend-valid? (book-state-operation-id? operation-id)))
    (unless (eq? wire-valid? backend-valid?)
      (adapter-error 'operation-id-grammar-mismatch
                     "wire and backend operation-ID predicates disagree"))
    wire-valid?))

(define (normalize-backend-rejection-code code)
  ;; A failed backend has retired its ambiguous connection and revoked all
  ;; grants. The wire/model's finite terminal storage code is storage-failure.
  (if (eq? code 'store-failed) 'storage-failure code))

(define (map-backend-rejection operation rejection)
  (make-state-backend-rejection
   operation
   (normalize-backend-rejection-code
    (book-state-rejection-code rejection))
   (book-state-rejection-current-state-version rejection)))

(define (run-state-backend-read store operation)
  (let ((result
         (read-book-state
          store
          (state-read-operation-owner operation)
          (state-read-operation-backend-grant operation)
          (state-read-operation-grant-generation operation))))
    (cond
     ((book-state-absent? result)
      (make-state-read-result
       operation #f (book-state-absent-state-version result) ""))
     ((book-state-value? result)
      (make-state-read-result
       operation #t (book-state-value-state-version result)
       (book-state-value-text result)))
     ((book-state-rejection? result)
      (map-backend-rejection operation result))
     (else
      (adapter-error 'unknown-read-result
                     "backend returned an unknown read result")))))

(define (receipt-agrees-with-operation? receipt operation)
  (and (string=? (book-state-receipt-operation-id receipt)
                 (state-commit-operation-operation-id operation))
       (= (book-state-receipt-expected-state-version receipt)
          (state-commit-operation-expected-state-version operation))
       (= (book-state-receipt-state-version receipt)
          (+ (state-commit-operation-expected-state-version operation) 1))
       (= (book-state-receipt-text-bytes receipt)
          (utf8-size (state-commit-operation-text operation)))))

(define (run-state-backend-commit store operation)
  (let ((operation-id (state-commit-operation-operation-id operation)))
    (if (not (operation-id-valid! operation-id))
        ;; The frozen protocol snapshot intentionally awaits its own review.
        ;; Fail its formerly broader string admission before any SQLite call.
        (make-state-backend-rejection
         operation 'invalid-operation-id #f)
        (let ((result
               (commit-book-state!
                store
                (state-commit-operation-owner operation)
                (state-commit-operation-backend-grant operation)
                (state-commit-operation-grant-generation operation)
                operation-id
                (state-commit-operation-expected-state-version operation)
                (state-commit-operation-text operation))))
          (cond
           ((book-state-receipt? result)
            (unless (receipt-agrees-with-operation? result operation)
              (adapter-error
               'receipt-mismatch
               "backend receipt disagrees with the exact typed operation"))
            (make-state-commit-receipt
             operation
             (book-state-receipt-state-version result)
             (book-state-receipt-text-bytes result)))
           ((book-state-rejection? result)
            (map-backend-rejection operation result))
           (else
            (adapter-error 'unknown-commit-result
                           "backend returned an unknown commit result")))))))

(define (run-state-backend-operation store operation)
  (unless (book-state-store? store)
    (adapter-error 'invalid-store "adapter requires a Book State store"))
  (cond
   ((state-read-operation? operation)
    (run-state-backend-read store operation))
   ((state-commit-operation? operation)
    (run-state-backend-commit store operation))
   (else
    (adapter-error 'invalid-operation
                   "adapter requires a typed state read or commit operation"))))

(define (assert-binding-agrees-with-grant! binding)
  (unless (state-endpoint-binding? binding)
    (adapter-error 'invalid-binding
                   "adapter revocation requires a state endpoint binding"))
  (let ((grant (state-endpoint-binding-backend-grant binding)))
    (unless (and (book-state-grant? grant)
                 (string=? (state-endpoint-binding-grant-handle binding)
                           (book-state-grant-handle grant))
                 (= (state-endpoint-binding-grant-generation binding)
                    (book-state-grant-generation grant))
                 (eq? (state-endpoint-binding-access binding)
                      (book-state-grant-access grant)))
      (adapter-error
       'binding-grant-mismatch
       "endpoint binding metadata disagrees with its retained backend grant"))))

(define (revoke-state-backend-binding! store binding)
  (unless (book-state-store? store)
    (adapter-error 'invalid-store "adapter requires a Book State store"))
  (assert-binding-agrees-with-grant! binding)
  ;; This call may wait for a commit that acquired the backend mutex first.
  ;; The caller must already have stopped accepting endpoint input and must not
  ;; hold the accepted Book Session transition mutex while waiting here.
  (let ((result
         (revoke-book-state-grant!
          store
          (state-endpoint-binding-owner binding)
          (state-endpoint-binding-backend-grant binding))))
    (unless (memq result '(revoked already-revoked))
      (adapter-error
       'revocation-failed
       "backend did not confirm state-grant revocation"))
    result))

(define (close-state-session-and-revoke! store session binding reason)
  ;; Validate the entire trusted lifecycle tuple before changing either side.
  ;; Equal-looking handles/owners/generations cannot substitute for the exact
  ;; opaque binding record retained by SESSION.
  (unless (state-session? session)
    (adapter-error 'invalid-session
                   "adapter close requires a typed state session"))
  (unless (state-endpoint-binding? binding)
    (adapter-error 'invalid-binding
                   "adapter close requires a state endpoint binding"))
  (unless (state-session-bound-to? session binding)
    (adapter-error
     'session-binding-mismatch
     "state session and revocation binding are not the same retained record"))
  (unless (book-state-store? store)
    (adapter-error 'invalid-store "adapter requires a Book State store"))
  (assert-binding-agrees-with-grant! binding)
  ;; Local authority closes first: no later peer message or backend completion
  ;; can be accepted. Backend revocation then linearizes against any operation
  ;; already inside its one mutex. A commit that won the mutex may be durable,
  ;; but its late result remains inadmissible to the closed session.
  (state-session-close! session reason)
  (revoke-state-backend-binding! store binding))
