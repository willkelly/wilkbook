(use-modules (book-protocol)
             (book-protocol blocking-io)
             (book-session)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 format)
             (ice-9 threads)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-9)
             (srfi srfi-64))

(define endpoint-socket-for-test
  (lambda (endpoint)
    ((@@ (book-session) endpoint-binding-socket)
     ((@@ (book-session) session-endpoint-binding) endpoint))))
(define decoded-message-hook-for-test
  (@@ (book-session) decoded-message-hook))

(define runner (test-runner-simple))
(test-runner-current runner)

(define-record-type <mock-storage>
  (%make-mock-storage mutex condition next owners revocations calls mode
                      entered release? revoke-hook)
  mock-storage?
  (mutex mock-mutex)
  (condition mock-condition)
  (next mock-next set-mock-next!)
  (owners mock-owners set-mock-owners!)
  (revocations mock-revocations set-mock-revocations!)
  (calls mock-calls set-mock-calls!)
  (mode mock-mode %set-mock-mode!)
  (entered mock-entered set-mock-entered!)
  (release? mock-release? set-mock-release?!)
  (revoke-hook mock-revoke-hook set-mock-revoke-hook!))

(define (make-mock-storage)
  (%make-mock-storage
   (make-mutex) (make-condition-variable) 0 '() '() '() 'none 0 #f #f))

(define (with-mock-lock mock thunk)
  (dynamic-wind
    (lambda () (lock-mutex (mock-mutex mock)))
    thunk
    (lambda () (unlock-mutex (mock-mutex mock)))))

(define (mock-factory mock)
  (define (open-binding owner)
    (with-mock-lock
     mock
     (lambda ()
       (let ((generation (+ 1 (mock-next mock))))
         (set-mock-next! mock generation)
         (set-mock-owners! mock (append (mock-owners mock) (list owner)))
         (make-state-endpoint-binding
          owner (vector 'mock-grant generation owner)
          (format #f "state_~a" generation) generation 'read-write)))))
  (define (run-operation operation)
    (let ((block? #f))
      (lock-mutex (mock-mutex mock))
      (set-mock-calls! mock (append (mock-calls mock) (list operation)))
      (set! block?
            (or (eq? (mock-mode mock) 'all)
                (and (eq? (mock-mode mock) 'commit)
                     (state-commit-operation? operation))))
      (when block?
        (set-mock-entered! mock (+ 1 (mock-entered mock)))
        (broadcast-condition-variable (mock-condition mock))
        (let wait ()
          (unless (mock-release? mock)
            (wait-condition-variable (mock-condition mock) (mock-mutex mock))
            (wait))))
      (unlock-mutex (mock-mutex mock))
      (cond
       ((state-read-operation? operation)
        (make-state-read-result operation #f 0 ""))
       ((state-commit-operation? operation)
        (make-state-commit-receipt
         operation
         (+ 1 (state-commit-operation-expected-state-version operation))
         (bytevector-length
          (string->utf8 (state-commit-operation-text operation)))))
       (else (error "mock received unknown typed operation")))))
  (define (revoke binding)
    (with-mock-lock
     mock
     (lambda ()
       (set-mock-revocations!
        mock (append (mock-revocations mock) (list binding)))
       (when (mock-revoke-hook mock) ((mock-revoke-hook mock)))
       (broadcast-condition-variable (mock-condition mock))
       'revoked)))
  (make-book-state-delegate-factory open-binding run-operation revoke))

(define (mock-snapshot mock)
  (with-mock-lock
   mock
   (lambda ()
     (list (length (mock-owners mock))
           (length (mock-revocations mock))
           (length (mock-calls mock))
           (mock-entered mock)))))

(define (set-mock-block-mode! mock mode)
  (with-mock-lock
   mock
   (lambda ()
     (%set-mock-mode! mock mode)
     (set-mock-release?! mock #f))))

(define (release-mock-storage! mock)
  (with-mock-lock
   mock
   (lambda ()
     (set-mock-release?! mock #t)
     (broadcast-condition-variable (mock-condition mock)))))

(define (wait-for predicate message)
  (let loop ((attempts 0))
    (when (= attempts 10000) (error message))
    (if (predicate)
        #t
        (begin (usleep 1000) (loop (+ attempts 1))))))

(define (wait-for-entered mock count)
  (wait-for
   (lambda ()
     (with-mock-lock mock (lambda () (>= (mock-entered mock) count))))
   "mock backend operation did not enter"))

(define (field object name)
  (assoc-ref object name))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (session-error-kind thunk)
  (catch 'book-session-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (state-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (delegate-error-kind thunk)
  (catch 'book-state-session-delegate-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (write-state-message port message)
  (put-bytevector port (encode-state-message message))
  (force-output port))

(define (pump-eventually endpoint)
  (let loop ((attempts 0))
    (when (= attempts 10000) (error "timed out waiting for input pump"))
    (let ((result (endpoint-pump-input! endpoint)))
      (if (memq (endpoint-pump-result-status result)
                '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempts 1)))
          result))))

(define (flush-output! endpoint)
  (let loop ((attempts 0))
    (when (= attempts 10000) (error "timed out flushing output"))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (if (memq status '(budget would-block interrupted))
          (begin (usleep 1000) (loop (+ attempts 1)))
          status))))

(define (initialize-state-endpoint! endpoint peer)
  (write-frame peer '( ("type" . "hello") ("version" . 1)))
  (let* ((result (pump-eventually endpoint))
         (dispatch-values (endpoint-pump-result-values result)))
    (unless (and (eq? (endpoint-pump-result-status result) 'committed)
                 (= (length dispatch-values) 2))
      (error "state-enabled hello did not return initialize plus state-ready"))
    (endpoint-queue-message! endpoint (car dispatch-values))
    (endpoint-queue-message! endpoint (cadr dispatch-values))
    (flush-output! endpoint)
    (let ((initialize (read-frame peer))
          (ready (read-frame peer)))
      (values initialize ready (cadr dispatch-values)))))

(define (wait-for-state-output! endpoint peer)
  (wait-for (lambda () (positive? (snapshot endpoint "outbound_frames")))
            "worker did not queue a state response")
  (flush-output! endpoint)
  (read-frame peer))

(define (close-peer! peer)
  (unless (port-closed? peer) (close-port peer)))

(test-begin "book-session-state-integration")

(let ((host (make-book-session-host)))
  (call-with-values
      (lambda () (open-session-endpoint! host "state-disabled"))
    (lambda (endpoint peer)
      (write-frame peer '(("type" . "hello") ("version" . 1)))
      (let ((hello (pump-eventually endpoint)))
        (test-equal "ordinary endpoint hello still returns one value" 1
          (length (endpoint-pump-result-values hello))))
      (write-state-message peer (make-state-read-message "guessed" 1))
      (test-equal "ordinary endpoint has no optional state dispatcher" 'schema
        (session-error-kind (lambda () (pump-eventually endpoint))))
      (test-equal "state attempt does not disturb the ordinary surface" 'active
        (snapshot endpoint "state"))
      (close-session! endpoint)
      (close-peer! peer))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "initial-state"))
    (lambda (endpoint peer)
      (write-frame peer '(("type" . "hello") ("version" . 1)))
      (let* ((hello (pump-eventually endpoint))
             (values (endpoint-pump-result-values hello))
             (initialize (car values))
             (ready (cadr values)))
        (test-equal "state-enabled hello preserves exact initialize first"
          '("initialize" 7 1)
          (list (field initialize "type") (length initialize)
                (field initialize "grant_count")))
        (test-assert "state-enabled hello adds one typed state-ready"
          (and (= (length values) 2) (state-ready-message? ready)))
        (write-state-message
         peer
         (make-state-read-message
          (state-ready-message-grant-handle ready)
          (state-ready-message-grant-generation ready)))
        (test-equal "state operation cannot precede queued grant announcement"
          'state
          (delegate-error-kind (lambda () (pump-eventually endpoint))))
        (test-equal "pre-announcement rejection performs no backend work"
          '(1 0 0 0) (mock-snapshot mock))
        (endpoint-queue-message! endpoint initialize)
        (endpoint-queue-message! endpoint ready)
        (flush-output! endpoint)
        (test-equal "initialize is physically before state-ready"
          '("initialize" "state-ready")
          (list (field (read-frame peer) "type")
                (field (read-frame peer) "type")))
        (write-state-message peer (make-state-value-message #f 0 ""))
        (test-equal "authority-to-book state shape is rejected inbound"
          'schema (state-error-kind (lambda () (pump-eventually endpoint))))
        (write-frame
         peer
         `(("type" . "state-read")
           ("protocol_version" . 1)
           ("grant_handle" . ,(state-ready-message-grant-handle ready))
           ("grant_generation" .
            ,(state-ready-message-grant-generation ready))
           ("owner" . "book-selected")))
        (test-equal "state decoder rejects book-supplied authority fields"
          'schema (state-error-kind (lambda () (pump-eventually endpoint))))
        (test-equal "state grammar errors perform no backend work"
          '(1 0 0 0) (mock-snapshot mock))
        (write-state-message
         peer
         (make-state-read-message
          (state-ready-message-grant-handle ready)
          (state-ready-message-grant-generation ready)))
        (test-assert "valid read dispatches through the owned worker"
          (state-delegate-dispatch-result?
           (car (endpoint-pump-result-values (pump-eventually endpoint)))))
        (test-equal "valid read returns the typed absent snapshot"
          '("state-value" #f 0 "")
          (let ((response (wait-for-state-output! endpoint peer)))
            (list (field response "type") (field response "present")
                  (field response "state_version") (field response "text"))))
        (write-state-message
         peer
         (make-state-commit-message
          (state-ready-message-grant-handle ready)
          (state-ready-message-grant-generation ready)
          "InitialSave_1" 0 "saved text"))
        (pump-eventually endpoint)
        (test-equal "valid commit returns a distinct durable receipt message"
          '("state-committed" "InitialSave_1" 1 10)
          (let ((response (wait-for-state-output! endpoint peer)))
            (list (field response "type") (field response "operation_id")
                  (field response "state_version")
                  (field response "text_bytes")))))
      (let ((revoke-reentry #f))
        (set-mock-revoke-hook!
         mock
         (lambda ()
           (set! revoke-reentry
                 (session-error-kind
                  (lambda ()
                    (host-action! endpoint "during-revoke" "must-reject"))))))
        (close-session! endpoint)
        (test-equal "backend revocation runs outside endpoint authority mutex"
          'state revoke-reentry))
      (test-equal "state-enabled close revokes its exact retained binding"
        '(1 1 2 0) (mock-snapshot mock))
      (close-peer! peer))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "bounded-state-output"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (do ((index 0 (+ index 1)))
              ((= index max-outbound-frames))
            (endpoint-queue-message!
             endpoint `(("type" . "queued") ("index" . ,index))))
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (test-equal "full bounded output rejects state work before dispatch"
            'backpressure
            (session-error-kind (lambda () (pump-eventually endpoint))))
          (test-equal "output reservation failure adds no task or backend call"
            `(,max-outbound-frames (1 0 0 0))
            (list (snapshot endpoint "outbound_frames")
                  (mock-snapshot mock)))
          (close-session! endpoint)
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-block-mode! mock 'all)
  (call-with-values
      (lambda () (open-session-endpoint! host "responsive-worker"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (let* ((started-at (get-internal-real-time))
                 (dispatch (pump-eventually endpoint))
                 (elapsed (/ (- (get-internal-real-time) started-at)
                             internal-time-units-per-second)))
            (test-assert "state input pump queues one task without storage wait"
              (let ((value (car (endpoint-pump-result-values dispatch))))
                (and (< elapsed 1)
                     (state-delegate-dispatch-result? value)
                     (eq? (state-delegate-dispatch-result-status value)
                          'queued)))))
          (wait-for-entered mock 1)
          (let* ((action (host-action! endpoint "surface-while-state" "input"))
                 (present
                  `(("type" . "present")
                    ("request_id" . ,(field action "request_id"))
                    ("action_id" . ,(field action "action_id"))
                    ("surface_handle" . ,(field action "surface_handle"))
                    ("surface_generation" .
                     ,(field action "surface_generation"))
                    ("sequence" . ,(field action "sequence"))
                    ("count" . 1)
                    ("text" . "surface remains responsive"))))
            (write-frame peer present)
            (let ((surface-result (pump-eventually endpoint)))
              (test-equal "surface presentation commits during blocked storage"
                "surface remains responsive"
                (presented-text-value
                 (car (endpoint-pump-result-values surface-result))))))
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (test-equal "single pending state operation rejects a second task"
            'state (state-error-kind (lambda () (pump-eventually endpoint))))
          (test-equal "second state operation never reaches backend"
            '(1 0 1 1) (mock-snapshot mock))
          (release-mock-storage! mock)
          (test-equal "worker publishes the typed read result after reentry"
            '("state-value" #f 0 "")
            (let ((response (wait-for-state-output! endpoint peer)))
              (list (field response "type") (field response "present")
                    (field response "state_version")
                    (field response "text"))))
          (close-session! endpoint)
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "close-before-dispatch"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((gate (make-mutex))
                (condition (make-condition-variable))
                (decoded? #f)
                (release? #f))
            (define (pause-after-decode ignored-endpoint ignored-message)
              (lock-mutex gate)
              (set! decoded? #t)
              (signal-condition-variable condition)
              (let wait ()
                (unless release?
                  (wait-condition-variable condition gate)
                  (wait)))
              (unlock-mutex gate))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (let ((reader
                   (call-with-new-thread
                    (lambda ()
                      (parameterize
                          ((decoded-message-hook-for-test pause-after-decode))
                        (endpoint-pump-input! endpoint))))))
              (lock-mutex gate)
              (let wait ()
                (unless decoded?
                  (wait-condition-variable condition gate)
                  (wait)))
              (close-session! endpoint)
              (set! release? #t)
              (signal-condition-variable condition)
              (unlock-mutex gate)
              (let ((late (join-thread reader)))
                (test-equal "close after decode wins before state dispatch"
                  '(stale 0 0)
                  (list (endpoint-pump-result-status late)
                        (endpoint-pump-result-frames late)
                        (length (endpoint-pump-result-values late))))
                (test-equal "close-before-dispatch runs no storage and revokes"
                  '(1 1 0 0) (mock-snapshot mock)))))
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "close-during-commit"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (pump-eventually endpoint)
          (wait-for-state-output! endpoint peer)
          (set-mock-block-mode! mock 'commit)
          (write-state-message
           peer
           (make-state-commit-message
            (field ready "grant_handle") (field ready "grant_generation")
            "CloseRace_1" 0 "durable-result-must-not-escape"))
          (pump-eventually endpoint)
          (wait-for-entered mock 1)
          (let ((closer
                 (call-with-new-thread (lambda () (close-session! endpoint)))))
            (wait-for
             (lambda () (= (cadr (mock-snapshot mock)) 1))
             "close did not reach backend revocation")
            (test-equal "local endpoint is closed before revocation wait ends"
              '(closed #f 0)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "transport_open")
                    (snapshot endpoint "outbound_frames")))
            (release-mock-storage! mock)
            (join-thread closer)
            (test-equal "late commit result queues no acknowledgement after close"
              '(closed 0 2 1)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "outbound_frames")
                    (caddr (mock-snapshot mock))
                    (cadr (mock-snapshot mock)))))
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (call-with-values
      (lambda () (open-session-endpoint! host "old-state-endpoint"))
    (lambda (old-endpoint old-peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! old-endpoint old-peer))
        (lambda (old-initialize old-ready old-typed-ready)
          (call-with-values
              (lambda () (restart-session! old-endpoint "fresh-state-endpoint"))
            (lambda (new-endpoint new-peer)
              (call-with-values
                  (lambda () (initialize-state-endpoint! new-endpoint new-peer))
                (lambda (new-initialize new-ready new-typed-ready)
                  (test-assert "restart owns a fresh state grant and endpoint owner"
                    (and (not (string=? (field old-ready "grant_handle")
                                        (field new-ready "grant_handle")))
                         (not (= (field old-ready "grant_generation")
                                 (field new-ready "grant_generation")))
                         (let ((owners
                                (with-mock-lock
                                 mock (lambda () (mock-owners mock)))))
                           (and (= (length owners) 2)
                                (not (eq? (car owners) (cadr owners)))))))
                  (write-state-message
                   new-peer
                   (make-state-read-message
                    (field old-ready "grant_handle")
                    (field old-ready "grant_generation")))
                  (test-equal "old grant cannot select the fresh endpoint" 'binding
                    (state-error-kind
                     (lambda () (pump-eventually new-endpoint))))
                  (test-equal "grant mismatch closes/revokes only fresh lifetime"
                    '(closed 2 2 0)
                    (list (snapshot new-endpoint "state")
                          (car (mock-snapshot mock))
                          (cadr (mock-snapshot mock))
                          (caddr (mock-snapshot mock))))
                  (close-peer! old-peer)
                  (close-peer! new-peer))))))))))

(test-end "book-session-state-integration")
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
