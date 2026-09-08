;;; Optional Book Session owner for one typed persistent-state endpoint.
(define-module (book-state-session-delegate)
  #:use-module (book-state-protocol)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-9)
  #:export (make-book-state-delegate-factory
            book-state-delegate-factory?
            open-book-state-session-delegate
            book-state-session-delegate?
            start-book-state-session-delegate!
            book-state-session-delegate-ready-message
            announce-book-state-session-delegate!
            decode-book-state-session-payload
            dispatch-book-state-session-message!
            state-delegate-dispatch-result?
            state-delegate-dispatch-result-status
            state-delegate-dispatch-result-response
            apply-book-state-session-backend-result!
            note-book-state-session-response-queued!
            book-state-session-delegate-phase
            book-state-session-delegate-closing?
            close-book-state-session-delegate-local!
            finish-book-state-session-delegate-close!
            book-state-session-delegate-worker-snapshot))

(define (delegate-error kind message)
  (throw 'book-state-session-delegate-error kind message))

;; This is one declared typed seam, not a registry.  OPEN-BINDING receives only
;; the opaque owner object created by Book Session.  Namespace/store selection
;; remains captured by trusted supervisor code.  RUN-OPERATION receives only a
;; typed operation; REVOKE-BINDING receives only the retained typed binding.
(define-record-type <book-state-delegate-factory>
  (%make-book-state-delegate-factory open-binding run-operation revoke-binding)
  book-state-delegate-factory?
  (open-binding delegate-factory-open-binding)
  (run-operation delegate-factory-run-operation)
  (revoke-binding delegate-factory-revoke-binding))

(define (make-book-state-delegate-factory open-binding run-operation
                                          revoke-binding)
  (unless (and (procedure? open-binding)
               (procedure? run-operation)
               (procedure? revoke-binding))
    (delegate-error 'factory
                    "state delegate factory requires three procedures"))
  (%make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(define-record-type <book-state-session-delegate>
  (%make-book-state-session-delegate binding session run-operation
                                     revoke-binding mutex condition task
                                     stopping? worker completion announced?
                                     cleanup-owner)
  book-state-session-delegate?
  (binding delegate-binding)
  (session delegate-session)
  (run-operation delegate-run-operation)
  (revoke-binding delegate-revoke-binding)
  (mutex delegate-mutex)
  (condition delegate-condition)
  (task delegate-task set-delegate-task!)
  (stopping? delegate-stopping? set-delegate-stopping?!)
  (worker delegate-worker set-delegate-worker!)
  (completion delegate-completion set-delegate-completion!)
  (announced? delegate-announced? set-delegate-announced?!)
  (cleanup-owner delegate-cleanup-owner set-delegate-cleanup-owner!))

(define-record-type <state-delegate-dispatch-result>
  (%make-state-delegate-dispatch-result status response)
  state-delegate-dispatch-result?
  (status state-delegate-dispatch-result-status)
  (response state-delegate-dispatch-result-response))

(define (with-delegate-lock delegate thunk)
  (dynamic-wind
    (lambda () (lock-mutex (delegate-mutex delegate)))
    thunk
    (lambda () (unlock-mutex (delegate-mutex delegate)))))

(define (open-book-state-session-delegate factory owner)
  (unless (book-state-delegate-factory? factory)
    (delegate-error 'factory "typed state delegate factory required"))
  (unless owner
    (delegate-error 'owner "Book Session endpoint owner is required"))
  ;; The trusted binding/grant factory may perform backend work.  Book Session
  ;; calls this function only after releasing host/endpoint authority mutexes.
  (let ((binding ((delegate-factory-open-binding factory) owner)))
    (unless (state-endpoint-binding? binding)
      (delegate-error 'binding
                      "factory did not return a state endpoint binding"))
    (catch #t
      (lambda ()
        (%make-book-state-session-delegate
         binding (make-state-session binding)
         (delegate-factory-run-operation factory)
         (delegate-factory-revoke-binding factory)
         (make-mutex) (make-condition-variable) #f #f #f #f #f #f))
      (lambda arguments
        ;; A binding acquired by a failing open must not escape active.
        ((delegate-factory-revoke-binding factory) binding)
        (apply throw arguments)))))

(define (book-state-session-delegate-ready-message delegate)
  (unless (book-state-session-delegate? delegate)
    (delegate-error 'delegate "typed state session delegate required"))
  (state-session-ready-message (delegate-session delegate)))

(define (same-ready-message? left right)
  (and (state-ready-message? left)
       (state-ready-message? right)
       (string=? (state-ready-message-grant-handle left)
                 (state-ready-message-grant-handle right))
       (= (state-ready-message-grant-generation left)
          (state-ready-message-grant-generation right))
       (eq? (state-ready-message-access left)
            (state-ready-message-access right))))

(define (announce-book-state-session-delegate! delegate message)
  ;; Called while the endpoint authority mutex atomically queues STATE-READY.
  (unless (same-ready-message?
           message (book-state-session-delegate-ready-message delegate))
    (delegate-error 'authority
                    "state-ready does not name this endpoint delegate"))
  (with-delegate-lock
   delegate
   (lambda ()
     (when (delegate-stopping? delegate)
       (delegate-error 'closed "state delegate is closing"))
     (when (delegate-announced? delegate)
       (delegate-error 'state "state-ready was already announced"))
     (unless (procedure? (delegate-completion delegate))
       (delegate-error 'state "state delegate worker is not started"))
     (set-delegate-announced?! delegate #t)
     'announced)))

(define (delegate-completion-procedure delegate)
  (delegate-completion delegate))

(define (decode-book-state-session-payload payload)
  (decode-state-payload payload 'book-to-authority))

(define (queue-delegate-operation! delegate operation)
  (with-delegate-lock
   delegate
   (lambda ()
     (when (delegate-stopping? delegate)
       (delegate-error 'closed "state delegate is closing"))
     (when (delegate-task delegate)
       (delegate-error 'queue "bounded state task slot is occupied"))
     (set-delegate-task! delegate operation)
     (signal-condition-variable (delegate-condition delegate))
     'queued)))

(define (dispatch-book-state-session-message! delegate message)
  ;; Book Session invokes this while holding its endpoint authority mutex.  The
  ;; pure FSM transition and one-slot queue publication therefore linearize
  ;; with surface presentation, close, and endpoint replacement.
  (unless (delegate-announced? delegate)
    (delegate-error 'state "state grant has not been announced"))
  (let ((result (state-session-receive! (delegate-session delegate) message)))
    (cond
     ((state-read-operation? result)
      (queue-delegate-operation! delegate result)
      (%make-state-delegate-dispatch-result 'queued #f))
     ((eq? result 'staged)
      (let ((operation
             (state-session-dispatch-commit! (delegate-session delegate))))
        (queue-delegate-operation! delegate operation)
        (%make-state-delegate-dispatch-result 'queued #f)))
     ((memq result '(pending staged))
      (%make-state-delegate-dispatch-result 'already-pending #f))
     ((or (state-committed-message? result)
          (state-conflict-message? result)
          (state-commit-failed-message? result))
      (%make-state-delegate-dispatch-result 'cached result))
     (else
      (delegate-error 'state "state FSM returned an unknown dispatch result")))))

(define (apply-book-state-session-backend-result! delegate result)
  ;; Book Session invokes this after the worker's backend call, after reacquiring
  ;; the endpoint authority mutex.  Exact pending operation identity and grant
  ;; generation are rechecked by the accepted pure FSM here.
  (state-session-apply-backend-result! (delegate-session delegate) result))

(define (note-book-state-session-response-queued! delegate response)
  (when (state-committed-message? response)
    (state-session-note-commit-ack-sent! (delegate-session delegate)))
  'queued)

(define (book-state-session-delegate-phase delegate)
  (state-session-phase (delegate-session delegate)))

(define (book-state-session-delegate-closing? delegate)
  (eq? (book-state-session-delegate-phase delegate) 'closing))

(define (take-delegate-task! delegate)
  (let ((mutex (delegate-mutex delegate)))
    (lock-mutex mutex)
    (let wait ()
      (cond
       ((delegate-task delegate)
        => (lambda (task)
             (set-delegate-task! delegate #f)
             (unlock-mutex mutex)
             task))
       ((delegate-stopping? delegate)
        (unlock-mutex mutex)
        #f)
       (else
        (wait-condition-variable (delegate-condition delegate) mutex)
        (wait))))))

(define (run-delegate-worker delegate)
  (let loop ()
    (let ((operation (take-delegate-task! delegate)))
      (when operation
        ;; No Book Session or delegate mutex is held around this potentially
        ;; blocking storage call.
        (let ((outcome
               (catch #t
                 (lambda ()
                   (cons 'result
                         ((delegate-run-operation delegate) operation)))
                 (lambda (key . arguments)
                   (cons 'error (cons key arguments))))))
          ((delegate-completion-procedure delegate)
           delegate operation (car outcome) (cdr outcome)))
        (loop)))))

(define (start-book-state-session-delegate! delegate completion)
  (unless (and (book-state-session-delegate? delegate)
               (procedure? completion))
    (delegate-error 'worker
                    "state delegate and completion procedure required"))
  (with-delegate-lock
   delegate
   (lambda ()
     (when (or (delegate-worker delegate)
               (delegate-completion delegate)
               (delegate-stopping? delegate))
       (delegate-error 'worker "state delegate worker cannot be restarted"))
     (set-delegate-completion! delegate completion)))
  (let ((worker
         (call-with-new-thread (lambda () (run-delegate-worker delegate)))))
    (with-delegate-lock
     delegate
     (lambda () (set-delegate-worker! delegate worker)))
    delegate))

(define (close-book-state-session-delegate-local! delegate reason)
  ;; The caller holds Book Session's endpoint mutex.  Invalidate the model and
  ;; remove a not-yet-started task before any backend revocation can block.
  (state-session-close! (delegate-session delegate) reason)
  (with-delegate-lock
   delegate
   (lambda ()
     (set-delegate-stopping?! delegate #t)
     (set-delegate-task! delegate #f)
     (broadcast-condition-variable (delegate-condition delegate))))
  'closing)

(define (finish-book-state-session-delegate-close! delegate)
  ;; Book Session calls this with no authority mutex held.  Revocation
  ;; linearizes under the backend's own mutex against an operation already in
  ;; RUN-OPERATION.  Exactly one cleanup caller owns the revoke/join sequence.
  (let ((owner?
         (with-delegate-lock
          delegate
          (lambda ()
            (if (delegate-cleanup-owner delegate)
                #f
                (begin
                  (set-delegate-cleanup-owner!
                   delegate (current-thread))
                  #t))))))
    (if (not owner?)
        'already-closing
        (let ((outcome
               (catch #t
                 (lambda ()
                   (cons 'result
                         ((delegate-revoke-binding delegate)
                          (delegate-binding delegate))))
                 (lambda (key . arguments)
                   (cons 'error (cons key arguments))))))
          (let ((worker (delegate-worker delegate)))
            (when (and worker (not (eq? worker (current-thread))))
              (join-thread worker)))
          (if (eq? (car outcome) 'result)
              (let ((result (cdr outcome)))
                (unless (memq result '(revoked already-revoked))
                  (delegate-error
                   'revocation
                   "state backend did not confirm revocation"))
                result)
              (apply throw (cdr outcome)))))))

(define (book-state-session-delegate-worker-snapshot delegate)
  (with-delegate-lock
   delegate
   (lambda ()
     `((announced . ,(not (not (delegate-announced? delegate))))
       (queued_tasks . ,(if (delegate-task delegate) 1 0))
       (stopping . ,(delegate-stopping? delegate))
       (cleanup_started . ,(not (not (delegate-cleanup-owner delegate))))))))
