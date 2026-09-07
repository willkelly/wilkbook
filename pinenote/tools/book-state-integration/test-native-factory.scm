;;; Focused real-backend tests for the narrow trusted factory and close seam.
(use-modules (book-protocol blocking-io)
             (book-session)
             (book-state)
             (book-state-integration)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 ftw)
             (ice-9 threads)
             (rnrs io ports)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define roots '())
(define commit-fault-hook-for-test (@@ (book-state) commit-fault-hook))

(define (make-test-root label)
  (let ((root
         (mkdtemp
          (string-append
           "/tmp/opencode/book-state-native-factory-" label ".XXXXXX"))))
    (chmod root #o700)
    (set! roots (cons root roots))
    root))

(define (cleanup-root root)
  (for-each
   (lambda (name)
     (unless (member name
                     '("book-state-v1.sqlite"
                       "book-state-v1.sqlite-journal"
                       "book-state-v1.sqlite-wal"
                       "book-state-v1.sqlite-shm"))
       (error "unexpected native factory test artifact" root name))
     (delete-file (string-append root "/" name)))
   (scandir root (lambda (name) (not (member name '("." ".."))))))
  (rmdir root))

(define (cleanup-roots!)
  (for-each cleanup-root roots)
  (set! roots '()))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (field object name)
  (assoc-ref object name))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (pump-eventually endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000)
      (error "timed out waiting for native factory input"))
    (let ((result (endpoint-pump-input! endpoint)))
      (if (memq (endpoint-pump-result-status result)
                '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          result))))

(define (flush-output! endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000)
      (error "timed out flushing native factory output"))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (if (memq status '(budget would-block interrupted))
          (begin (usleep 1000) (loop (+ attempt 1)))
          status))))

(define (wait-for-output! endpoint peer)
  (let loop ((attempt 0))
    (when (= attempt 10000)
      (error "timed out waiting for native factory worker output"))
    (if (positive? (snapshot endpoint "outbound_frames"))
        (begin (flush-output! endpoint) (read-frame peer))
        (begin (usleep 1000) (loop (+ attempt 1))))))

(define (initialize! endpoint peer)
  (write-frame peer '(("type" . "hello") ("version" . 1)))
  (let* ((result (pump-eventually endpoint))
         (committed-values (endpoint-pump-result-values result)))
    (unless (and (eq? (endpoint-pump-result-status result) 'committed)
                 (= (length committed-values) 2)
                 (state-ready-message? (cadr committed-values)))
      (error "native factory state hello failed"))
    (endpoint-queue-message! endpoint (car committed-values))
    (endpoint-queue-message! endpoint (cadr committed-values))
    (flush-output! endpoint)
    (let ((initialize (read-frame peer))
          (ready (read-frame peer)))
      (values initialize ready (cadr committed-values)))))

(define (write-state-message! peer message)
  (put-bytevector peer (encode-state-message message))
  (force-output peer))

(define (dispatch-read! endpoint peer ready)
  (write-state-message!
   peer
   (make-state-read-message
    (state-ready-message-grant-handle ready)
    (state-ready-message-grant-generation ready)))
  (let* ((pump (pump-eventually endpoint))
         (value (car (endpoint-pump-result-values pump))))
    (unless (and (state-delegate-dispatch-result? value)
                 (eq? (state-delegate-dispatch-result-status value) 'queued))
      (error "native factory read did not queue exactly once")))
  (wait-for-output! endpoint peer))

(define (state-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (wait-for predicate message)
  (let loop ((attempt 0))
    (when (= attempt 10000) (error message))
    (if (predicate)
        #t
        (begin (usleep 1000) (loop (+ attempt 1))))))

(test-begin "book-state-native-factory")

(let* ((root (make-test-root "namespace"))
       (runtime (open-native-book-state-runtime root))
       (host-a
        (open-native-book-instance-host!
         runtime "native-factory/a@1" "stable-a"))
       (host-b
        (open-native-book-instance-host!
         runtime "native-factory/b@1" "stable-b")))
  (call-with-values
      (lambda ()
        (open-session-endpoint!
         (native-book-instance-session-host host-a) "namespace-a"))
    (lambda (endpoint-a peer-a)
      (call-with-values
          (lambda ()
            (open-session-endpoint!
             (native-book-instance-session-host host-b) "namespace-b"))
        (lambda (endpoint-b peer-b)
          (call-with-values
              (lambda () (initialize! endpoint-a peer-a))
            (lambda (initialize-a wire-ready-a ready-a)
              (call-with-values
                  (lambda () (initialize! endpoint-b peer-b))
                (lambda (initialize-b wire-ready-b ready-b)
                  (test-assert "separate trusted namespaces issue separate grants"
                    (not (string=?
                          (state-ready-message-grant-handle ready-a)
                          (state-ready-message-grant-handle ready-b))))
                  (write-state-message!
                   peer-b
                   (make-state-read-message
                    (state-ready-message-grant-handle ready-a)
                    (state-ready-message-grant-generation ready-a)))
                  (test-equal
                      "one namespace grant cannot select the other endpoint"
                    'binding
                    (state-error-kind
                     (lambda () (pump-eventually endpoint-b))))
                  (test-equal "wrong grant closes only its receiving endpoint"
                    '(active closed)
                    (list (snapshot endpoint-a "state")
                          (snapshot endpoint-b "state")))
                  (let ((value (dispatch-read! endpoint-a peer-a ready-a)))
                    (test-equal "unrelated valid namespace remains absent"
                      '("state-value" #f 0 "")
                      (list (field value "type") (field value "present")
                            (field value "state_version")
                            (field value "text"))))
                  (release-session-endpoint! endpoint-a)
                  (release-session-endpoint! endpoint-b)
                  (close-port-quietly! peer-a)
                  (close-port-quietly! peer-b)))))))))
  (call-with-values
      (lambda ()
        (open-session-endpoint!
         (native-book-instance-session-host host-b) "namespace-b-fresh"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (let ((value (dispatch-read! endpoint peer ready)))
            (test-equal "wrong-namespace attempt wrote nothing"
              '(#f 0 "")
              (list (field value "present")
                    (field value "state_version")
                    (field value "text"))))))
      (release-session-endpoint! endpoint)
      (close-port-quietly! peer)))
  (test-equal "runtime closes after all exact endpoint revocations"
    'closed (close-native-book-state-runtime! runtime)))

(let* ((root (make-test-root "late-close"))
       (runtime (open-native-book-state-runtime root))
       (instance
        (open-native-book-instance-host!
         runtime "native-factory/race@1" "stable-race"))
       (gate (make-mutex))
       (condition (make-condition-variable))
       (entered? #f)
       (release? #f)
       (close-finished? #f)
       (old-endpoint #f)
       (old-peer #f))
  (define (fault-hook point)
    (when (eq? point 'before-commit)
      (lock-mutex gate)
      (set! entered? #t)
      (broadcast-condition-variable condition)
      (let wait ()
        (unless release?
          (wait-condition-variable condition gate)
          (wait)))
      (unlock-mutex gate)))
  (parameterize ((commit-fault-hook-for-test fault-hook))
    (call-with-values
        (lambda ()
          (open-session-endpoint!
           (native-book-instance-session-host instance) "late-close"))
      (lambda (endpoint peer)
        (set! old-endpoint endpoint)
        (set! old-peer peer)))
    (call-with-values
        (lambda () (initialize! old-endpoint old-peer))
      (lambda (initialize wire-ready ready)
        (dispatch-read! old-endpoint old-peer ready)
        (write-state-message!
         old-peer
         (make-state-commit-message
          (state-ready-message-grant-handle ready)
          (state-ready-message-grant-generation ready)
          "LateClose_1" 0 "durable-before-late-close"))
        (let* ((pump (pump-eventually old-endpoint))
               (dispatch (car (endpoint-pump-result-values pump))))
          (test-assert "real commit dispatch returns before backend completion"
            (and (state-delegate-dispatch-result? dispatch)
                 (eq? (state-delegate-dispatch-result-status dispatch)
                      'queued))))))
    (wait-for
     (lambda ()
       (lock-mutex gate)
       (let ((value entered?)) (unlock-mutex gate) value))
     "real backend commit did not reach the in-transaction close gate")
    (let ((closer
           (call-with-new-thread
            (lambda ()
              (close-session! old-endpoint)
              (set! close-finished? #t)))))
      (wait-for (lambda () (eq? (snapshot old-endpoint "state") 'closed))
                "local endpoint did not close before backend revocation")
      (test-assert "close invalidates locally while real backend owns its mutex"
        (not close-finished?))
      (test-equal "late durable result cannot queue a commit acknowledgement"
        0 (snapshot old-endpoint "outbound_frames"))
      (lock-mutex gate)
      (set! release? #t)
      (broadcast-condition-variable condition)
      (unlock-mutex gate)
      (join-thread closer)
      (test-assert "close completes after commit/revocation linearization"
        close-finished?)
      (test-equal "late completion still queued no acknowledgement"
        0 (snapshot old-endpoint "outbound_frames"))))

  (call-with-values
      (lambda () (restart-session! old-endpoint "late-close-reopen"))
    (lambda (endpoint peer)
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize wire-ready ready)
          (let ((value (dispatch-read! endpoint peer ready)))
            (test-equal
                "fresh endpoint reads commit that won before revocation"
              '(#t 1 "durable-before-late-close")
              (list (field value "present")
                    (field value "state_version")
                    (field value "text"))))))
      (release-session-endpoint! endpoint)
      (close-port-quietly! peer)))
  (close-port-quietly! old-peer)
  (test-equal "race runtime closes cleanly" 'closed
    (close-native-book-state-runtime! runtime)))

(test-end "book-state-native-factory")
(cleanup-roots!)
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
