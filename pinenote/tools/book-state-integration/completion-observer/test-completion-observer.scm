;;; Focused model/queue tests for the trusted Book Session completion slot.
(use-modules (book-protocol blocking-io)
             (book-session)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 threads)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-9)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define-record-type <mock-storage>
  (%make-mock-storage mutex calls revocations read-count foreign-operation)
  mock-storage?
  (mutex mock-mutex)
  (calls mock-calls set-mock-calls!)
  (revocations mock-revocations set-mock-revocations!)
  (read-count mock-read-count set-mock-read-count!)
  (foreign-operation mock-foreign-operation set-mock-foreign-operation!))

(define (make-mock-storage)
  (%make-mock-storage (make-mutex) '() 0 0 #f))

(define (with-mock-lock mock thunk)
  (dynamic-wind
    (lambda () (lock-mutex (mock-mutex mock)))
    thunk
    (lambda () (unlock-mutex (mock-mutex mock)))))

(define (mock-factory mock)
  (define (open-binding owner)
    (make-state-endpoint-binding
     owner (vector 'mock-grant owner) "state_mock_observer" 1 'read-write))
  (define (run-operation operation)
    (with-mock-lock
     mock
     (lambda ()
       (set-mock-calls! mock (append (mock-calls mock) (list operation)))
       (cond
        ((state-read-operation? operation)
         (let ((index (+ 1 (mock-read-count mock))))
           (set-mock-read-count! mock index)
           (case index
             ((1)
              (make-state-read-result
               operation #t 1 (make-string max-state-text-bytes #\nul)))
             (else
              (make-state-read-result operation #t 2 "worker-still-live")))))
        ((state-commit-operation? operation)
          (if (mock-foreign-operation mock)
              (make-state-commit-receipt
               (mock-foreign-operation mock) 2 6)
              (cond
               ((string=? (state-commit-operation-operation-id operation)
                          "ConflictCommit_2")
                (make-state-backend-rejection operation 'stale-version 4))
               ((string=? (state-commit-operation-operation-id operation)
                          "FailedCommit_3")
                (make-state-backend-rejection
                 operation 'receipt-quota-exhausted #f))
               (else
                (make-state-commit-receipt
                 operation
                 (+ 1
                    (state-commit-operation-expected-state-version operation))
                 (bytevector-length
                  (string->utf8 (state-commit-operation-text operation))))))))
        (else (error "mock received an unknown operation"))))))
  (define (revoke-binding binding)
    (with-mock-lock
     mock
     (lambda ()
       (set-mock-revocations! mock (+ 1 (mock-revocations mock)))
       'revoked)))
  (make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(define (field object name)
  (assoc-ref object name))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (write-state-message! peer message)
  (put-bytevector peer (encode-state-message message))
  (force-output peer))

(define (pump-eventually endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000) (error "input pump timed out"))
    (let ((result (endpoint-pump-input! endpoint)))
      (if (memq (endpoint-pump-result-status result)
                '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          result))))

(define (flush-output! endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000) (error "output pump timed out"))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (if (memq status '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          status))))

(define (wait-for predicate message)
  (let loop ((attempt 0))
    (when (= attempt 10000) (error message))
    (if (predicate) #t (begin (usleep 1000) (loop (+ attempt 1))))))

(define (wait-for-output! endpoint)
  (wait-for (lambda () (positive? (snapshot endpoint "outbound_frames")))
            "state worker queued no output"))

(define (wait-for-completion! endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000) (error "trusted completion was not published"))
    (let ((completion (endpoint-take-state-completion! endpoint)))
      (if completion completion
          (begin (usleep 1000) (loop (+ attempt 1)))))))

(define (initialize! endpoint peer)
  (write-frame peer '(("type" . "hello") ("version" . 1)))
  (let* ((result (pump-eventually endpoint))
         (committed-values (endpoint-pump-result-values result)))
    (unless (and (= (length committed-values) 2)
                 (state-ready-message? (cadr committed-values)))
      (error "state observer endpoint initialization failed"))
    (endpoint-queue-message! endpoint (car committed-values))
    (endpoint-queue-message! endpoint (cadr committed-values))
    (flush-output! endpoint)
    (let ((initialize (read-frame peer))
          (ready (read-frame peer)))
      (values initialize ready (cadr committed-values)))))

(define (send-read! endpoint peer ready)
  (write-state-message!
   peer
   (make-state-read-message
    (state-ready-message-grant-handle ready)
    (state-ready-message-grant-generation ready)))
  (let* ((pump (pump-eventually endpoint))
         (dispatch (car (endpoint-pump-result-values pump))))
    (state-delegate-dispatch-result-status dispatch)))

(define (send-commit! endpoint peer ready operation-id expected text)
  (write-state-message!
   peer
   (make-state-commit-message
    (state-ready-message-grant-handle ready)
    (state-ready-message-grant-generation ready)
    operation-id expected text))
  (let* ((pump (pump-eventually endpoint))
         (dispatch (car (endpoint-pump-result-values pump))))
    (state-delegate-dispatch-result-status dispatch)))

(define (session-error-kind thunk)
  (catch 'book-session-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (state-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (present-for-action action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(test-begin "book-session-state-completion-observer")

(let* ((mock (make-mock-storage))
       (old-host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! old-host "observer-disabled"))
    (lambda (endpoint peer)
      (test-equal "accepted constructor does not silently enable observation"
        'state
        (session-error-kind
         (lambda () (endpoint-take-state-completion! endpoint))))
      (close-session! endpoint)
      (close-port peer))))

(let* ((mock (make-mock-storage))
       (host
        (make-book-session-host-with-state-observer (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "bounded-observer"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (test-assert "fresh observer slot is empty"
            (not (endpoint-take-state-completion! endpoint)))

          (let ((action (host-action! endpoint "forged-saved" "ignored")))
            (write-frame peer (present-for-action action "FORGED-SAVED"))
            (let ((value
                   (car (endpoint-pump-result-values
                         (pump-eventually endpoint)))))
              (test-equal "early book presentation remains a surface fact"
                "FORGED-SAVED" (presented-text-value value)))
            (test-assert "early presentation creates no storage observation"
              (not (endpoint-take-state-completion! endpoint))))

          (test-equal "first read owns the sole worker" 'queued
            (send-read! endpoint peer ready))
          (wait-for-output! endpoint)
          (test-equal "4096-NUL wire response retains BSD1 bound"
            24666 (snapshot endpoint "outbound_bytes"))
          (flush-output! endpoint)
          (let ((wire (read-frame peer)))
            (test-assert "book receives complete 4096-NUL value"
              (and (string=? (field wire "type") "state-value")
                   (= (string-length (field wire "text")) 4096)
                   (string-every #\nul (field wire "text")))))

          ;; The undrained completion remains after wire delivery and blocks
          ;; only further state work, never surface presentation.
          (write-state-message!
           peer
           (make-state-read-message
            (state-ready-message-grant-handle ready)
            (state-ready-message-grant-generation ready)))
          (test-equal "undrained completion rejects before state mutation"
            'backpressure
            (session-error-kind (lambda () (pump-eventually endpoint))))
          (test-equal "undrained slot did not call storage twice"
            1 (length (mock-calls mock)))
          (test-equal "completion pressure leaves endpoint active"
            'active (snapshot endpoint "state"))
          (let ((action
                 (host-action! endpoint "surface-under-pressure" "still-live")))
            (write-frame peer (present-for-action action "surface-responsive"))
            (test-equal "surface path remains responsive under slot pressure"
              "surface-responsive"
              (presented-text-value
               (car (endpoint-pump-result-values
                     (pump-eventually endpoint))))))

          (let* ((completion (wait-for-completion! endpoint))
                 (first-response (book-state-completion-response completion))
                 (private-text
                  ((@@ (book-state-protocol) %state-value-message-text)
                   first-response)))
            (test-equal "read observation binds endpoint/session/generations"
              (list (snapshot endpoint "session_id") 1
                    (state-ready-message-grant-generation ready)
                    'read #f #f)
              (list (book-state-completion-session-id completion)
                    (book-state-completion-surface-generation completion)
                    (book-state-completion-grant-generation completion)
                    (book-state-completion-operation-kind completion)
                    (book-state-completion-operation-id completion)
                    (book-state-completion-text completion)))
            (string-set! private-text 0 #\X)
            (test-assert "observer response accessor returns a defensive copy"
              (string-every
               #\nul
               (state-value-message-text
                (book-state-completion-response completion))))
            (test-assert "one accepted result is observed exactly once"
              (not (endpoint-take-state-completion! endpoint))))

          (test-equal "worker accepts state again after trusted drain" 'queued
            (send-read! endpoint peer ready))
          (let ((completion (wait-for-completion! endpoint)))
            (test-equal "same worker publishes the second typed read"
              '(read #t 2 "worker-still-live")
              (let ((response (book-state-completion-response completion)))
                (list (book-state-completion-operation-kind completion)
                      (state-value-message-present? response)
                      (state-value-message-state-version response)
                      (state-value-message-text response)))))
          (flush-output! endpoint)
          (read-frame peer)

          (test-equal "commit dispatch reaches storage" 'queued
            (send-commit! endpoint peer ready "CachedCommit_1" 2 "cached"))
          (let ((completion (wait-for-completion! endpoint)))
            (let ((response (book-state-completion-response completion)))
              (test-equal "typed commit observation retains exact operation"
                '(commit "CachedCommit_1" 2 "cached" 3 6)
                (list (book-state-completion-operation-kind completion)
                      (book-state-completion-operation-id completion)
                      (book-state-completion-expected-state-version completion)
                      (book-state-completion-text completion)
                      (state-committed-message-state-version response)
                      (state-committed-message-text-bytes response)))
              (string-set!
               ((@@ (book-state-protocol)
                    %state-committed-message-operation-id)
                response)
               0 #\X)
              (test-equal
                  "observer response mutation cannot alter retained completion"
                "CachedCommit_1"
                (state-committed-message-operation-id
                 (book-state-completion-response completion)))))
          (flush-output! endpoint)
          (read-frame peer)
          (let ((calls (length (mock-calls mock))))
            (test-equal "exact same-session retry uses typed cache" 'cached
              (send-commit!
               endpoint peer ready "CachedCommit_1" 2 "cached"))
            (let ((completion (wait-for-completion! endpoint)))
              (test-equal "cached reply creates its own exact observation"
                '("CachedCommit_1" 3)
                (let ((response
                       (book-state-completion-response completion)))
                  (list (book-state-completion-operation-id completion)
                        (state-committed-message-state-version response)))))
            (test-equal "cached observation performs no second backend call"
              calls (length (mock-calls mock))))
          (flush-output! endpoint)
          (read-frame peer)
          (test-equal "typed conflict dispatch reaches storage" 'queued
            (send-commit! endpoint peer ready "ConflictCommit_2" 3 "draft"))
          (let ((completion (wait-for-completion! endpoint)))
            (test-equal "conflict is one exact typed observation"
              '(commit "ConflictCommit_2" 3 "draft" 4)
              (let ((response (book-state-completion-response completion)))
                (list (book-state-completion-operation-kind completion)
                      (book-state-completion-operation-id completion)
                      (book-state-completion-expected-state-version completion)
                      (book-state-completion-text completion)
                      (state-conflict-message-current-state-version response)))))
          (flush-output! endpoint)
          (test-equal "conflict wire remains a separate book result"
            "state-conflict" (field (read-frame peer) "type"))
          (test-equal "typed failure dispatch reaches storage" 'queued
            (send-commit! endpoint peer ready "FailedCommit_3" 3 "draft"))
          (let ((completion (wait-for-completion! endpoint)))
            (test-equal "non-closing failure is one exact typed observation"
              '("FailedCommit_3" receipt-quota-exhausted)
              (let ((response (book-state-completion-response completion)))
                (list (book-state-completion-operation-id completion)
                      (state-commit-failed-message-code response)))))
          (flush-output! endpoint)
          (test-equal "failure wire remains a separate book result"
            "state-commit-failed" (field (read-frame peer) "type"))
          (release-session-endpoint! endpoint)
          (test-equal "release cleans one worker/grant with no retained slot"
            '(closed 1 #f)
            (list (snapshot endpoint "state") (mock-revocations mock)
                  (endpoint-take-state-completion! endpoint)))
          (close-port peer)))))

;; A typed receipt naming a different endpoint's accepted operation must be
;; rejected by the accepted FSM before any trusted completion is observable.
(let* ((source-mock (make-mock-storage))
       (source-host
        (make-book-session-host-with-state-observer
         (mock-factory source-mock)))
       (foreign-operation #f))
  (call-with-values
      (lambda () (open-session-endpoint! source-host "foreign-source"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (send-read! endpoint peer ready)
          (wait-for-completion! endpoint)
          (flush-output! endpoint)
          (read-frame peer)
          (send-commit! endpoint peer ready "ForeignOperation_1" 1 "source")
          (wait-for-completion! endpoint)
          (flush-output! endpoint)
          (read-frame peer)
          (set! foreign-operation
                (car (reverse (mock-calls source-mock))))))
      (release-session-endpoint! endpoint)
      (close-port peer)))
  (let* ((victim-mock (make-mock-storage))
         (victim-host
          (make-book-session-host-with-state-observer
           (mock-factory victim-mock))))
    (set-mock-foreign-operation! victim-mock foreign-operation)
    (call-with-values
        (lambda () (open-session-endpoint! victim-host "foreign-victim"))
      (lambda (endpoint peer)
        (call-with-values
            (lambda () (initialize! endpoint peer))
          (lambda (initialize wire-ready ready)
            (send-read! endpoint peer ready)
            (wait-for-completion! endpoint)
            (flush-output! endpoint)
            (read-frame peer)
            (send-commit! endpoint peer ready "VictimOperation_1" 1 "victim")
            (wait-for
             (lambda () (eq? (snapshot endpoint "state") 'closed))
             "forged operation did not fail the endpoint closed")
            (test-equal "foreign typed receipt produces no false observation"
              '(closed 0 #f 1)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "outbound_frames")
                    (endpoint-take-state-completion! endpoint)
                    (mock-revocations victim-mock)))))
        (close-port peer))))))

;; A completion published for one surface generation cannot be drained after
;; navigation into the next UI lifetime, and releasing that stale completion
;; frees the finite endpoint slot for subsequent state work.
(let* ((mock (make-mock-storage))
       (host
        (make-book-session-host-with-state-observer (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "published-before-navigation"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (send-read! endpoint peer ready)
          (wait-for-output! endpoint)
          (navigate! endpoint)
          (test-assert "published old-generation completion is rejected"
            (not (endpoint-take-state-completion! endpoint)))
          (flush-output! endpoint)
          (read-frame peer)
          (test-equal "stale published completion releases finite capacity"
            'queued (send-read! endpoint peer ready))
          (let ((completion (wait-for-completion! endpoint)))
            (test-equal "next generation receives only its own observation"
              2 (book-state-completion-surface-generation completion)))
          (flush-output! endpoint)
          (read-frame peer)))
      (release-session-endpoint! endpoint)
      (close-port peer))))

;; If navigation races an in-flight backend call, publication rechecks the
;; reserved surface generation under the endpoint mutex.  The stale result and
;; its wire response are discarded by local fail-close before revocation.
(let* ((gate (make-mutex))
       (condition (make-condition-variable))
       (entered? #f)
       (release? #f)
       (revocations 0))
  (define (factory)
    (define (open-binding owner)
      (make-state-endpoint-binding
       owner (vector 'gated-grant owner) "state_gated_observer" 1
       'read-write))
    (define (run-operation operation)
      (lock-mutex gate)
      (set! entered? #t)
      (broadcast-condition-variable condition)
      (let wait ()
        (unless release?
          (wait-condition-variable condition gate)
          (wait)))
      (unlock-mutex gate)
      (make-state-read-result operation #f 0 ""))
    (define (revoke-binding binding)
      (set! revocations (+ revocations 1))
      'revoked)
    (make-book-state-delegate-factory
     open-binding run-operation revoke-binding))
  (let ((host (make-book-session-host-with-state-observer (factory))))
    (call-with-values
        (lambda () (open-session-endpoint! host "inflight-navigation"))
      (lambda (endpoint peer)
        (call-with-values
            (lambda () (initialize! endpoint peer))
          (lambda (initialize wire-ready ready)
            (send-read! endpoint peer ready)
            (wait-for
             (lambda ()
               (lock-mutex gate)
               (let ((value entered?)) (unlock-mutex gate) value))
             "gated backend operation did not start")
            (navigate! endpoint)
            (lock-mutex gate)
            (set! release? #t)
            (broadcast-condition-variable condition)
            (unlock-mutex gate)
            (wait-for (lambda ()
                        (and (eq? (snapshot endpoint "state") 'closed)
                             (= revocations 1)))
                      "stale generation did not fail closed")
            (test-equal "in-flight stale result cannot publish or queue"
              '(0 #f 1)
              (list (snapshot endpoint "outbound_frames")
                    (endpoint-take-state-completion! endpoint)
                    revocations))))
        (release-session-endpoint! endpoint)
        (close-port peer)))))

;; EOF and restart both share the accepted local close transition and must clear
;; an already-published observation as well as its queued wire response.
(let* ((mock (make-mock-storage))
       (host
        (make-book-session-host-with-state-observer (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "observer-eof"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (send-read! endpoint peer ready)
          (wait-for-output! endpoint)
          (close-port peer)
          (test-equal "peer EOF closes the exact observer endpoint"
            'eof (endpoint-pump-result-status (pump-eventually endpoint)))
          (test-equal "EOF clears response, completion, and grant"
            '(0 #f 1)
            (list (snapshot endpoint "outbound_frames")
                  (endpoint-take-state-completion! endpoint)
                  (mock-revocations mock)))))
      (release-session-endpoint! endpoint))))

(let* ((mock (make-mock-storage))
       (host
        (make-book-session-host-with-state-observer (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "observer-before-restart"))
    (lambda (old-endpoint old-peer)
      (call-with-values
          (lambda () (initialize! old-endpoint old-peer))
        (lambda (initialize wire-ready ready)
          (send-read! old-endpoint old-peer ready)
          (wait-for-output! old-endpoint)
          (call-with-values
              (lambda ()
                (restart-session! old-endpoint "observer-after-restart"))
            (lambda (replacement replacement-peer)
              (test-equal "restart clears only the old observer lifetime"
                '(closed 0 #f #f 1)
                (list (snapshot old-endpoint "state")
                      (snapshot old-endpoint "outbound_frames")
                      (endpoint-take-state-completion! old-endpoint)
                      (endpoint-take-state-completion! replacement)
                      (mock-revocations mock)))
              (release-session-endpoint! replacement)
              (close-port replacement-peer)))))
      (close-port old-peer))))

(test-end "book-session-state-completion-observer")
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
