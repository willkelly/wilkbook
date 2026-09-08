(use-modules (book-protocol)
             (book-protocol blocking-io)
             (book-session)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 format)
             (ice-9 threads)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9)
             (srfi srfi-64))

(define endpoint-socket-for-test
  (lambda (endpoint)
    ((@@ (book-session) endpoint-binding-socket)
     ((@@ (book-session) session-endpoint-binding) endpoint))))
(define decoded-message-hook-for-test
  (@@ (book-session) decoded-message-hook))
(define json-encoder-for-test
  (@@ (book-protocol) json-encoder))
(define state-response-reservation-for-test
  (@@ (book-session) max-state-outbound-frame-bytes))
(define delegate-for-test
  (@@ (book-session) endpoint-state-delegate))
(define delegate-worker-for-test
  (@@ (book-state-session-delegate) delegate-worker))
(define make-unchecked-state-read-result-for-test
  (@@ (book-state-protocol) %make-state-read-result))

(define runner (test-runner-simple))
(test-runner-current runner)

(define-record-type <mock-storage>
  (%make-mock-storage mutex condition next owners revocations calls mode
                      entered release? revoke-hook response)
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
  (revoke-hook mock-revoke-hook set-mock-revoke-hook!)
  (response mock-response set-mock-response-under-lock!))

(define (make-mock-storage)
  (%make-mock-storage
   (make-mutex) (make-condition-variable) 0 '() '() '() 'none 0 #f #f #f))

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
    (let ((block? #f) (response #f))
      (lock-mutex (mock-mutex mock))
      (set-mock-calls! mock (append (mock-calls mock) (list operation)))
      (set! response (mock-response mock))
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
       (response (response operation))
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

(define (set-mock-response! mock response)
  (unless (or (not response) (procedure? response))
    (error "mock response must be false or a procedure"))
  (with-mock-lock
   mock
   (lambda () (set-mock-response-under-lock! mock response))))

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

(define (max-sized-output-message)
  ;; {"x":""} contributes eight bytes around X in the pinned compact codec.
  `(("x" . ,(make-string (- max-frame-size 8) #\a))))

(define (quote-backslash-heavy-text)
  (list->string
   (map (lambda (index) (if (even? index) #\" #\\))
        (iota max-state-text-bytes))))

(define (wait-for-endpoint-closed endpoint mock delegate)
  (wait-for
   (lambda ()
     (and (eq? (snapshot endpoint "state") 'closed)
          (= (cadr (mock-snapshot mock)) 1)
          (thread-exited? (delegate-worker-for-test delegate))))
   "failed state completion did not close, revoke, and terminate its worker"))

(test-begin "book-session-state-integration")

(let* ((nul-text (make-string max-state-text-bytes #\nul))
       (quoted-text (quote-backslash-heavy-text))
       (maximum-value
        (encode-state-message
         (make-state-value-message #t max-safe-integer nul-text)))
       (reviewer-value
        (encode-state-message (make-state-value-message #t 1 nul-text)))
       (quoted-value
        (encode-state-message (make-state-value-message #t 1 quoted-text)))
       (maximum-operation-id
        (make-string max-state-operation-id-bytes #\A))
       (other-output-shapes
        (list
         (encode-state-message
          (make-state-ready-message
           (make-string max-state-grant-handle-bytes #\nul)
           max-safe-integer 'read-write))
         (encode-state-message
          (make-state-committed-message
           maximum-operation-id max-safe-integer max-state-text-bytes))
         (encode-state-message
          (make-state-conflict-message maximum-operation-id max-safe-integer))
         (encode-state-message
          (make-state-commit-failed-message
           maximum-operation-id 'receipt-quota-exhausted)))))
  (test-equal "static reservation is the exact maximum state-value frame"
    24681
    state-response-reservation-for-test)
  (test-equal "reviewer's 4096-NUL version-one frame is 24666 bytes"
    24666 (bytevector-length reviewer-value))
  (test-equal "4096 quote/backslash characters use two-byte escaping"
    8282 (bytevector-length quoted-value))
  (test-equal "worst text and fixed metadata attain the reservation"
    state-response-reservation-for-test (bytevector-length maximum-value))
  (test-assert "reservation fits both codec frame and whole output queue"
    (and (<= state-response-reservation-for-test (+ max-frame-size 4))
         (<= state-response-reservation-for-test max-outbound-bytes)))
  (test-assert "every other bounded typed output shape fits the reservation"
    (every (lambda (frame)
             (<= (bytevector-length frame)
                 state-response-reservation-for-test))
           other-output-shapes)))

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

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock)))
       (nul-text (make-string max-state-text-bytes #\nul))
       (quoted-text (quote-backslash-heavy-text)))
  (set-mock-response!
   mock (lambda (operation) (make-state-read-result operation #t 1 nul-text)))
  (call-with-values
      (lambda () (open-session-endpoint! host "reviewer-4096-nul"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (test-equal "4096-NUL read dispatch is queued"
            'queued
            (state-delegate-dispatch-result-status
             (car (endpoint-pump-result-values
                   (pump-eventually endpoint)))))
          (wait-for (lambda () (= (snapshot endpoint "outbound_frames") 1))
                    "4096-NUL response was not queued")
          (test-equal "4096-NUL worker frame consumes its exact bounded bytes"
            24666 (snapshot endpoint "outbound_bytes"))
          (let ((response (wait-for-state-output! endpoint peer)))
            (test-assert "4096-NUL response is complete typed JSON"
              (and (string=? (field response "type") "state-value")
                   (field response "present")
                   (= (field response "state_version") 1)
                   (string=? (field response "text") nul-text))))
          (set-mock-response!
           mock
           (lambda (operation)
             (make-state-read-result operation #t 2 quoted-text)))
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (pump-eventually endpoint)
          (wait-for (lambda () (= (snapshot endpoint "outbound_frames") 1))
                    "quote-heavy response was not queued")
          (test-equal "quote-heavy worker frame uses bounded queue accounting"
            8282 (snapshot endpoint "outbound_bytes"))
          (let ((response (wait-for-state-output! endpoint peer)))
            (test-assert "worker continues after the maximum escaped response"
              (and (= (field response "state_version") 2)
                   (string=? (field response "text") quoted-text))))
          (test-equal "two valid large reads reached the sole worker"
            2 (caddr (mock-snapshot mock)))
          (close-session! endpoint)
          (test-equal "successful large responses still close and revoke once"
            '(closed 1)
            (list (snapshot endpoint "state")
                  (cadr (mock-snapshot mock))))
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock)))
       (max-frame (max-sized-output-message)))
  (set-mock-block-mode! mock 'all)
  (call-with-values
      (lambda () (open-session-endpoint! host "exact-byte-capacity"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (do ((index 0 (+ index 1)))
              ((= index (- max-outbound-frames 1)))
            (endpoint-queue-message! endpoint max-frame))
          (test-equal "seven codec-maximum frames leave one exact frame slot"
            `(,(- max-outbound-frames 1)
              ,(* (- max-outbound-frames 1) (+ max-frame-size 4)))
            (list (snapshot endpoint "outbound_frames")
                  (snapshot endpoint "outbound_bytes")))
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (test-equal "schema-sized reservation accepts at exact queue capacity"
            'queued
            (state-delegate-dispatch-result-status
             (car (endpoint-pump-result-values
                   (pump-eventually endpoint)))))
          (wait-for-entered mock 1)
          (release-mock-storage! mock)
          (wait-for
           (lambda () (= (snapshot endpoint "outbound_frames")
                         max-outbound-frames))
           "state response did not consume the eighth frame slot")
          (test-equal "eighth response retains exact bounded byte accounting"
            (+ (* (- max-outbound-frames 1) (+ max-frame-size 4))
               (bytevector-length
                (encode-state-message
                 (make-state-value-message #f 0 ""))))
            (snapshot endpoint "outbound_bytes"))
          (close-session! endpoint)
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock)))
       (max-frame (max-sized-output-message)))
  (call-with-values
      (lambda () (open-session-endpoint! host "partial-frame-capacity"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (do ((index 0 (+ index 1)))
              ((= index max-outbound-frames))
            (endpoint-queue-message! endpoint max-frame))
          (let ((output (endpoint-pump-output! endpoint)))
            (test-equal "partial output spends bytes but retains all frame slots"
              `(budget ,max-outbound-frames
                       ,(- max-outbound-bytes max-output-bytes-per-pump))
              (list (endpoint-pump-result-status output)
                    (snapshot endpoint "outbound_frames")
                    (snapshot endpoint "outbound_bytes"))))
          (write-state-message
           peer
           (make-state-read-message
            (field ready "grant_handle") (field ready "grant_generation")))
          (test-equal "partial head cannot masquerade as a free response slot"
            'backpressure
            (session-error-kind (lambda () (pump-eventually endpoint))))
          (test-equal "partial-frame rejection publishes no backend task"
            0 (caddr (mock-snapshot mock)))
          (close-session! endpoint)
          (close-peer! peer))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-block-mode! mock 'all)
  (call-with-values
      (lambda () (open-session-endpoint! host "completion-output-pressure"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((delegate (delegate-for-test endpoint)))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (pump-eventually endpoint)
            (wait-for-entered mock 1)
            ;; This second wire request is deliberately left unread.  It must
            ;; not turn into a stranded task after completion fails closed.
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (do ((index 0 (+ index 1)))
                ((= index max-outbound-frames))
              (endpoint-queue-message!
               endpoint `(("type" . "pressure") ("index" . ,index))))
            (release-mock-storage! mock)
            (wait-for-endpoint-closed endpoint mock delegate)
            (test-equal "completion pressure atomically clears output and closes"
              '(closed #f 0 0)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "transport_open")
                    (snapshot endpoint "outbound_frames")
                    (snapshot endpoint "outbound_bytes")))
            (test-equal "failed completion releases task slot and starts cleanup"
              '(0 #t #t)
              (let ((worker
                     (book-state-session-delegate-worker-snapshot delegate)))
                (list (assoc-ref worker 'queued_tasks)
                      (assoc-ref worker 'stopping)
                      (assoc-ref worker 'cleanup_started))))
            (test-equal "read after completion failure observes closed endpoint"
              'closed
              (endpoint-pump-result-status (endpoint-pump-input! endpoint)))
            (test-equal "no second read reaches a dead or replacement worker"
              1 (caddr (mock-snapshot mock)))
            (close-session! endpoint)
            (test-equal "repeated close after worker fail-close does not revoke twice"
              1 (cadr (mock-snapshot mock)))
            (close-peer! peer)))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-response! mock (lambda (operation) '(not-a-typed-result)))
  (call-with-values
      (lambda () (open-session-endpoint! host "out-of-schema-result"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((delegate (delegate-for-test endpoint)))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (pump-eventually endpoint)
            (wait-for-endpoint-closed endpoint mock delegate)
            (test-equal "out-of-schema trusted result fails closed without output"
              '(closed 0 1)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "outbound_frames")
                    (cadr (mock-snapshot mock))))
            (close-peer! peer)))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-response!
   mock
   (lambda (operation)
     (make-unchecked-state-read-result-for-test
      operation #t 1 (make-string (+ max-state-text-bytes 1) #\nul))))
  (call-with-values
      (lambda () (open-session-endpoint! host "oversized-result"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((delegate (delegate-for-test endpoint)))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (pump-eventually endpoint)
            (wait-for-endpoint-closed endpoint mock delegate)
            (test-equal "unchecked oversized typed result cannot strand the worker"
              '(closed 0 1 #t)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "outbound_frames")
                    (cadr (mock-snapshot mock))
                    (thread-exited? (delegate-worker-for-test delegate))))
            (close-peer! peer)))))))

(let ((real-json-encoder (json-encoder-for-test)))
  (parameterize
      ((json-encoder-for-test
        (lambda (message)
          (if (and (assoc "type" message)
                   (string=? (assoc-ref message "type") "state-value"))
              (error "injected state response encoding failure")
              (real-json-encoder message)))))
    (let* ((mock (make-mock-storage))
           (host (make-book-session-host-with-state (mock-factory mock))))
      (call-with-values
          (lambda () (open-session-endpoint! host "encoding-failure"))
        (lambda (endpoint peer)
          (call-with-values
              (lambda () (initialize-state-endpoint! endpoint peer))
            (lambda (initialize ready typed-ready)
              (let ((delegate (delegate-for-test endpoint)))
                (write-state-message
                 peer
                 (make-state-read-message
                  (field ready "grant_handle")
                  (field ready "grant_generation")))
                (pump-eventually endpoint)
                (wait-for-endpoint-closed endpoint mock delegate)
                (test-equal "unexpected encoder exception is completion-total"
                  '(closed 0 1 #t)
                  (list (snapshot endpoint "state")
                        (snapshot endpoint "outbound_frames")
                        (cadr (mock-snapshot mock))
                        (thread-exited?
                         (delegate-worker-for-test delegate))))
                (close-peer! peer)))))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-response!
   mock (lambda (operation) (error "injected RUN-OPERATION exception")))
  (call-with-values
      (lambda () (open-session-endpoint! host "callback-failure"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((delegate (delegate-for-test endpoint)))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (pump-eventually endpoint)
            (wait-for-endpoint-closed endpoint mock delegate)
            (test-equal "callback exception closes, revokes, and reaps once"
              '(closed 0 1 #t)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "outbound_frames")
                    (cadr (mock-snapshot mock))
                    (thread-exited? (delegate-worker-for-test delegate))))
            (close-peer! peer)))))))

(let* ((mock (make-mock-storage))
       (host (make-book-session-host-with-state (mock-factory mock))))
  (set-mock-response! mock (lambda (operation) '(not-a-typed-result)))
  (set-mock-revoke-hook!
   mock (lambda () (error "injected REVOKE-BINDING exception")))
  (call-with-values
      (lambda () (open-session-endpoint! host "completion-revoke-failure"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize-state-endpoint! endpoint peer))
        (lambda (initialize ready typed-ready)
          (let ((delegate (delegate-for-test endpoint)))
            (write-state-message
             peer
             (make-state-read-message
              (field ready "grant_handle") (field ready "grant_generation")))
            (pump-eventually endpoint)
            (wait-for-endpoint-closed endpoint mock delegate)
            (test-equal "cleanup exception cannot reactivate or escape completion"
              '(closed #f 0 1 #t)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "transport_open")
                    (snapshot endpoint "outbound_frames")
                    (cadr (mock-snapshot mock))
                    (thread-exited? (delegate-worker-for-test delegate))))
            (close-peer! peer)))))))

(let ((real-json-encoder (json-encoder-for-test))
      (gate (make-mutex))
      (condition (make-condition-variable))
      (encoding? #f)
      (release-encoding? #f))
  (define (blocking-state-value-encoder message)
    (when (and (assoc "type" message)
               (string=? (assoc-ref message "type") "state-value"))
      (lock-mutex gate)
      (set! encoding? #t)
      (broadcast-condition-variable condition)
      (let wait ()
        (unless release-encoding?
          (wait-condition-variable condition gate)
          (wait)))
      (unlock-mutex gate))
    (real-json-encoder message))
  (parameterize ((json-encoder-for-test blocking-state-value-encoder))
    (let* ((mock (make-mock-storage))
           (host (make-book-session-host-with-state (mock-factory mock))))
      (call-with-values
          (lambda () (open-session-endpoint! host "close-during-completion"))
        (lambda (endpoint peer)
          (call-with-values
              (lambda () (initialize-state-endpoint! endpoint peer))
            (lambda (initialize ready typed-ready)
              (let ((delegate (delegate-for-test endpoint)))
                (write-state-message
                 peer
                 (make-state-read-message
                  (field ready "grant_handle")
                  (field ready "grant_generation")))
                (pump-eventually endpoint)
                (lock-mutex gate)
                (let wait ()
                  (unless encoding?
                    (wait-condition-variable condition gate)
                    (wait)))
                (unlock-mutex gate)
                (let ((closer
                       (call-with-new-thread
                        (lambda () (close-session! endpoint)))))
                  (usleep 10000)
                  (test-assert "close waits rather than deadlocking completion owner"
                    (not (thread-exited? closer)))
                  (lock-mutex gate)
                  (set! release-encoding? #t)
                  (broadcast-condition-variable condition)
                  (unlock-mutex gate)
                  (join-thread closer)
                  (wait-for-endpoint-closed endpoint mock delegate)
                  (test-equal "close during completion publishes no late response"
                    '(closed 0 1 #t)
                    (list (snapshot endpoint "state")
                          (snapshot endpoint "outbound_frames")
                          (cadr (mock-snapshot mock))
                          (thread-exited?
                           (delegate-worker-for-test delegate)))))
                (close-peer! peer)))))))))

(test-end "book-session-state-integration")
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
