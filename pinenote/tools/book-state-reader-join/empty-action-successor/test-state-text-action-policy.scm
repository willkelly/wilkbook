;;; Focused review delta for the trusted state-text endpoint policy.
(use-modules (book-protocol blocking-io)
             (book-session)
             (book-state-protocol)
             (book-state-session-delegate)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define (field object name) (assoc-ref object name))

(define (session-error-kind thunk)
  (catch 'book-session-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (pump-one! endpoint)
  (let loop ((attempts 0))
    (when (= attempts 1000) (error "input pump did not complete a frame"))
    (let* ((result (endpoint-pump-input! endpoint))
           (values (endpoint-pump-result-values result)))
      (if (pair? values)
          (car values)
          (begin (usleep 1000) (loop (+ attempts 1)))))))

(define (initialize! endpoint peer)
  (write-frame peer '(("type" . "hello") ("version" . 1)))
  (pump-one! endpoint))

(define (present-for action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(define (unused-state-factory)
  (define (open-binding owner)
    (make-state-endpoint-binding
     owner (vector 'unused owner) "state_text_policy" 1 'read-write))
  (define (run-operation operation)
    (error "focused policy test dispatched an unexpected state operation"))
  (define (revoke-binding binding) 'revoked)
  (make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(test-begin "book-session-state-text-action-policy")

;; The accepted public constructors retain their exact nonempty 2,048-byte
;; action semantics.
(let ((host (make-book-session-host)))
  (call-with-values
      (lambda () (open-session-endpoint! host "ordinary-policy"))
    (lambda (endpoint peer)
      (initialize! endpoint peer)
      (test-equal "ordinary endpoint accepts its exact old bound"
        2048 (string-length
              (field (host-action! endpoint "ordinary" (make-string 2048 #\x))
                     "text")))
      (test-eq "ordinary endpoint still rejects empty action text"
        'schema (session-error-kind
                 (lambda () (host-action! endpoint "ordinary" ""))))
      (test-eq "ordinary endpoint still rejects 2,049 action bytes"
        'schema
        (session-error-kind
         (lambda ()
           (host-action! endpoint "ordinary" (make-string 2049 #\x)))))
      (release-session-endpoint! endpoint)
      (close-port peer))))

;; Only the explicitly constructed state-text endpoint receives 0..4,096-byte
;; actions.  The same endpoint policy validates the book's presentation side.
(let ((host
       (make-book-session-host-with-state-text-observer
        (unused-state-factory))))
  (call-with-values
      (lambda () (open-session-endpoint! host "state-text-policy"))
    (lambda (endpoint peer)
      (initialize! endpoint peer)
      (let ((empty-action (host-action! endpoint "save-note" "")))
        (test-equal "state-text endpoint carries exact empty action" ""
          (field empty-action "text"))
        (write-frame peer (present-for empty-action ""))
        (let ((presented (pump-one! endpoint)))
          (test-assert "state-text endpoint accepts matching empty presentation"
            (and (presented-text? presented)
                 (string=? (presented-text-value presented) "")))))
      (test-equal "state-text endpoint accepts exact backend/UI bound"
        4096
        (string-length
         (field (host-action! endpoint "save-note" (make-string 4096 #\x))
                "text")))
      (test-eq "state-text endpoint rejects 4,097 action bytes"
        'schema
        (session-error-kind
         (lambda ()
           (host-action! endpoint "save-note" (make-string 4097 #\x)))))
      (release-session-endpoint! endpoint)
      (close-port peer))))

(test-end "book-session-state-text-action-policy")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
