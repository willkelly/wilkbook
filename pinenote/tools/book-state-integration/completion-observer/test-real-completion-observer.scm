;;; Real backend and native-book proof for the trusted completion observer.
(use-modules (book-protocol blocking-io)
             (book-session)
             (book-state)
             (book-state-backend-adapter)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (ice-9 threads)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (put-bytevector))
             (srfi srfi-9)
             (srfi srfi-64))

(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)
(define roots '())
(define commit-fault-hook-for-test (@@ (book-state) commit-fault-hook))

(define (trace label)
  (when (getenv "OBSERVER_TEST_TRACE")
    (format (current-error-port) "observer-test: ~a~%" label)
    (force-output (current-error-port))))

(define-record-type <real-authority>
  (%make-real-authority store namespace mutex calls revocations)
  real-authority?
  (store real-store)
  (namespace real-namespace)
  (mutex real-mutex)
  (calls real-calls set-real-calls!)
  (revocations real-revocations set-real-revocations!))

(define-record-type <owned-child>
  (%make-owned-child pid start-time process-group log-path status)
  owned-child?
  (pid child-pid)
  (start-time child-start-time)
  (process-group child-process-group)
  (log-path child-log-path)
  (status child-status set-child-status!))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (make-root label)
  (let ((root
         (mkdtemp
          (string-append
           "/tmp/opencode/book-state-completion-observer-" label ".XXXXXX"))))
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
                       "book-state-v1.sqlite-shm"
                       "observer-book.log"))
       (fail "unexpected real observer artifact ~a/~a" root name))
     (delete-file (string-append root "/" name)))
   (scandir root (lambda (name) (not (member name '("." ".."))))))
  (rmdir root))

(define (cleanup-roots!)
  (for-each cleanup-root roots)
  (set! roots '()))

(define (with-real-lock authority thunk)
  (dynamic-wind
    (lambda () (lock-mutex (real-mutex authority)))
    thunk
    (lambda () (unlock-mutex (real-mutex authority)))))

(define (require-backend-value value context)
  (if (book-state-rejection? value)
      (fail "~a: backend rejected with ~s" context
            (book-state-rejection-code value))
      value))

(define (make-real-authority root revision instance)
  (let* ((store (open-book-state-store root))
         (namespace
          (require-backend-value
           (open-book-instance! store revision instance)
           "open trusted BookInstance")))
    (%make-real-authority store namespace (make-mutex) 0 0)))

(define (real-factory authority)
  (define (open-binding owner)
    (let ((grant
           (require-backend-value
            (issue-book-state-grant!
             (real-store authority) (real-namespace authority)
             owner 'read-write)
            "issue exact endpoint grant")))
      (make-state-endpoint-binding
       owner grant (book-state-grant-handle grant)
       (book-state-grant-generation grant)
       (book-state-grant-access grant))))
  (define (run-operation operation)
    (with-real-lock
     authority
     (lambda () (set-real-calls! authority (+ 1 (real-calls authority)))))
    (run-state-backend-operation (real-store authority) operation))
  (define (revoke-binding binding)
    (with-real-lock
     authority
     (lambda ()
       (set-real-revocations! authority
                              (+ 1 (real-revocations authority)))))
    (revoke-state-backend-binding! (real-store authority) binding))
  (make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(define (observer-host authority)
  (make-book-session-host-with-state-observer (real-factory authority)))

(define (field object name)
  (assoc-ref object name))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (write-state-message! peer message)
  (put-bytevector peer (encode-state-message message))
  (force-output peer))

(define (pump-eventually endpoint)
  (let loop ((attempt 0))
    (when (= attempt 20000) (fail "input pump timed out"))
    (let ((result (endpoint-pump-input! endpoint)))
      (if (memq (endpoint-pump-result-status result)
                '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          result))))

(define (flush-output! endpoint)
  (let loop ((attempt 0))
    (when (= attempt 20000) (fail "output pump timed out"))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (if (memq status '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          status))))

(define (wait-for predicate message)
  (let loop ((attempt 0))
    (when (= attempt 20000) (fail message))
    (if (predicate) #t (begin (usleep 1000) (loop (+ attempt 1))))))

(define (wait-for-completion! endpoint)
  (let loop ((attempt 0))
    (when (= attempt 20000) (fail "real completion was not published"))
    (let ((completion (endpoint-take-state-completion! endpoint)))
      (if completion completion
          (begin (usleep 1000) (loop (+ attempt 1)))))))

(define (wait-for-output! endpoint)
  (wait-for (lambda () (positive? (snapshot endpoint "outbound_frames")))
            "real worker queued no state response"))

(define (initialize! endpoint peer)
  (write-frame peer '(("type" . "hello") ("version" . 1)))
  (let* ((pump (pump-eventually endpoint))
         (committed-values (endpoint-pump-result-values pump)))
    (unless (and (= (length committed-values) 2)
                 (state-ready-message? (cadr committed-values)))
      (fail "real observer endpoint did not initialize"))
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
  (let ((dispatch
         (car (endpoint-pump-result-values (pump-eventually endpoint)))))
    (state-delegate-dispatch-result-status dispatch)))

(define (send-commit! endpoint peer ready operation-id expected text)
  (write-state-message!
   peer
   (make-state-commit-message
    (state-ready-message-grant-handle ready)
    (state-ready-message-grant-generation ready)
    operation-id expected text))
  (let ((dispatch
         (car (endpoint-pump-result-values (pump-eventually endpoint)))))
    (state-delegate-dispatch-result-status dispatch)))

(define (finish-state-response! endpoint peer)
  (wait-for-output! endpoint)
  (flush-output! endpoint)
  (read-frame peer))

(define (present-for-action action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (read-process-field pid index)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (let* ((text (call-with-input-file path get-string-all))
                (close (string-rindex text #\)))
                (fields
                 (and close (string-tokenize (substring text (+ close 2))))))
           (and fields (> (length fields) index) (list-ref fields index))))))

(define (process-start-time pid)
  ;; The suffix starts at Linux stat field 3; start time is field 22.
  (read-process-field pid 19))

(define (process-group pid)
  ;; Process group is Linux stat field 5.
  (let ((value (read-process-field pid 2)))
    (and value (string->number value 10))))

(define (wait-stopped! pid)
  (let retry ()
    (let ((waited (waitpid pid WUNTRACED)))
      (cond
       ((and (= (car waited) pid)
             (status:stop-sig (cdr waited))
             (= (status:stop-sig (cdr waited)) SIGSTOP)) #t)
       ((= (car waited) 0) (usleep 1000) (retry))
       (else (fail "native book did not stop before protocol work"))))))

(define (spawn-book! peer root)
  (let* ((guile
          (or (search-path (parse-path (getenv "PATH")) "guile")
              (fail "pinned Guile is absent")))
         (source
          (or (getenv "OBSERVER_BOOK_SOURCE")
              (fail "OBSERVER_BOOK_SOURCE is absent")))
         (log-path (string-append root "/observer-book.log"))
         (log (open-file log-path "w0"))
         (environment
          (list "BOOK_SESSION_FD=0"
                "HOME=/nonexistent"
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "PATH=/nonexistent"
                "GUILE_AUTO_COMPILE=0"
                (string-append
                 "GUILE_LOAD_PATH="
                 (or (getenv "OBSERVER_BOOK_GUILE_LOAD_PATH") ""))
                (string-append
                 "GUILE_LOAD_COMPILED_PATH="
                 (or (getenv "OBSERVER_BOOK_GUILE_LOAD_COMPILED_PATH") ""))))
         (pid
          (spawn guile (list guile "--no-auto-compile" source)
                 #:search-path? #f #:environment environment
                 #:input peer #:output log #:error log)))
    (chmod log-path #o600)
    (wait-stopped! pid)
    (let ((start (process-start-time pid))
          (group (process-group pid)))
      (unless (and start (= group pid))
        (fail "native book process identity is not stable"))
      (close-port-quietly! log)
      (close-port-quietly! peer)
      (kill pid SIGCONT)
      (%make-owned-child pid start group log-path #f))))

(define (child-current? child)
  (let ((start (process-start-time (child-pid child))))
    (and start (string=? start (child-start-time child)))))

(define (reap-child! child)
  (unless (child-status child)
    (let retry ((attempt 0))
      (when (= attempt 20000)
        (fail "native book did not exit after completing its protocol"))
      (let ((waited
             (catch 'system-error
               (lambda () (waitpid (child-pid child) WNOHANG))
               (lambda arguments
                 (if (= (system-error-errno arguments) EINTR)
                     #f
                     (apply throw arguments))))))
        (if (or (not waited) (zero? (car waited)))
            (begin (usleep 1000) (retry (+ attempt 1)))
            (set-child-status!
             child
             (if (status:exit-val (cdr waited))
                 (cons 'exit (status:exit-val (cdr waited)))
                 (cons 'signal (status:term-sig (cdr waited)))))))))
  (child-status child))

(define (terminate-child! child)
  (when (and child (not (child-status child)))
    (when (child-current? child)
      (catch 'system-error
        (lambda () (kill (- (child-process-group child)) SIGKILL))
        (lambda arguments #f)))
    (reap-child! child)))

(define (state-protocol-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(test-begin "real-book-state-completion-observer")

;; Actual native book process: an early forged present cannot become a receipt;
;; the trusted read and commit observations originate in the accepted backend.
(let* ((root (make-root "native-book"))
       (authority
        (make-real-authority root "observer/native-book@1" "stable-note"))
       (host (observer-host authority))
       (endpoint #f)
       (child #f)
       (complete? #f)
       (saved-text "receipt-backed λ — 京東"))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (call-with-values
          (lambda () (open-session-endpoint! host "actual-native-book"))
        (lambda (opened peer)
          (set! endpoint opened)
          (set! child (spawn-book! peer root))))
      (trace "native child resumed")

      (let* ((hello (pump-eventually endpoint))
             (values (endpoint-pump-result-values hello)))
        (endpoint-queue-message! endpoint (car values))
        (endpoint-queue-message! endpoint (cadr values))
        (endpoint-queue-message!
         endpoint
         (host-action! endpoint "early-forged-present" "not-storage")))
      (flush-output! endpoint)
      (trace "native initialization/action flushed")
      (let ((early
             (car (endpoint-pump-result-values
                   (pump-eventually endpoint)))))
        (test-equal "actual book forged presentation is only presentation"
          "FORGED-SAVED" (presented-text-value early))
        (test-assert "forged presentation creates no backend observer"
          (not (endpoint-take-state-completion! endpoint))))
      (trace "native early presentation received")

      (let ((dispatch (pump-eventually endpoint)))
        (test-equal "actual book read dispatches to real backend" 'queued
          (state-delegate-dispatch-result-status
           (car (endpoint-pump-result-values dispatch)))))
      (let* ((completion (wait-for-completion! endpoint))
             (response (book-state-completion-response completion)))
        (test-assert "trusted outer observes accepted absent read result"
          (and (eq? (book-state-completion-operation-kind completion) 'read)
               (state-value-message? response)
               (not (state-value-message-present? response))
               (= (state-value-message-state-version response) 0)
               (string-null? (state-value-message-text response))))
        (test-assert "real read completion drains exactly once"
          (not (endpoint-take-state-completion! endpoint))))
      (trace "native read completion observed")
      (wait-for-output! endpoint)
      (flush-output! endpoint)
      (endpoint-queue-message!
       endpoint (host-action! endpoint "ui-submit-save" saved-text))
      (flush-output! endpoint)
      (trace "native read/action flushed")

      (let ((dispatch (pump-eventually endpoint)))
        (test-equal "actual book owns the inbound state commit" 'queued
          (state-delegate-dispatch-result-status
           (car (endpoint-pump-result-values dispatch)))))
      (let* ((completion (wait-for-completion! endpoint))
             (response (book-state-completion-response completion))
             (copy (book-state-completion-text completion)))
        (test-equal "real receipt observation precedes book present"
          '(commit "ActualBookSave_1" 0 1)
          (list (book-state-completion-operation-kind completion)
                (book-state-completion-operation-id completion)
                (book-state-completion-expected-state-version completion)
                (state-committed-message-state-version response)))
        (string-set! copy 0 #\X)
        (test-equal "real observation owns a defensive text copy"
          saved-text (book-state-completion-text completion))
        (test-assert "real commit observation drains exactly once"
          (not (endpoint-take-state-completion! endpoint))))
      (trace "native commit completion observed")
      (wait-for-output! endpoint)
      (flush-output! endpoint)
      (let ((presented
             (car (endpoint-pump-result-values
                   (pump-eventually endpoint)))))
        (test-equal "book present remains after and separate from receipt"
          "BOOK-PRESENT-AFTER-RECEIPT" (presented-text-value presented))
        (test-assert "book present cannot duplicate receipt observer"
          (not (endpoint-take-state-completion! endpoint))))
      (trace "native final presentation received")
      (trace (format #f "native child state/parent before reap: ~s/~s (self ~s)"
                     (read-process-field (child-pid child) 0)
                     (read-process-field (child-pid child) 1)
                     (getpid)))
      (test-equal "native book exits only after receiving typed receipt"
        '(exit . 0) (reap-child! child))
      (trace "native child reaped")
      (test-equal "native book diagnostics are empty" ""
        (call-with-input-file (child-log-path child) get-string-all))
      (trace "native diagnostics checked")
      (release-session-endpoint! endpoint)
      (trace "native endpoint released")
      (set! endpoint #f)
      (test-equal "actual chain used read+commit and one exact revocation"
        '(2 1) (list (real-calls authority) (real-revocations authority)))

      ;; Continue with native socket peers against the same real store. This is
      ;; the changed observer path only, not a repeat of native-v1's full proof.
      (trace "begin real socket cases")
      (let ((state-host (observer-host authority)))
        (call-with-values
            (lambda () (open-session-endpoint! state-host "real-retry-client"))
          (lambda (state-endpoint peer)
            (call-with-values
                (lambda () (initialize! state-endpoint peer))
              (lambda (initialize ready typed-ready)
                (send-read! state-endpoint peer typed-ready)
                (let* ((completion (wait-for-completion! state-endpoint))
                       (response
                        (book-state-completion-response completion)))
                  (test-equal "fresh endpoint observes persisted book value"
                    (list #t 1 saved-text)
                    (list (state-value-message-present? response)
                          (state-value-message-state-version response)
                          (state-value-message-text response))))
                (finish-state-response! state-endpoint peer)

                (send-commit! state-endpoint peer typed-ready
                              "EmptyState_2" 1 "")
                (let ((completion (wait-for-completion! state-endpoint)))
                  (test-equal "committed empty remains distinct from absent"
                    '("EmptyState_2" 2 0 "")
                    (let ((response
                           (book-state-completion-response completion)))
                      (list (book-state-completion-operation-id completion)
                            (state-committed-message-state-version response)
                            (state-committed-message-text-bytes response)
                            (book-state-completion-text completion)))))
                (finish-state-response! state-endpoint peer)

                (let ((calls (real-calls authority)))
                  (test-equal "same-session exact retry uses accepted cache"
                    'cached
                    (send-commit! state-endpoint peer typed-ready
                                  "EmptyState_2" 1 ""))
                  (let ((completion
                         (wait-for-completion! state-endpoint)))
                    (test-equal "cached durable receipt is observed exactly"
                      '("EmptyState_2" 2)
                      (let ((response
                             (book-state-completion-response completion)))
                        (list (book-state-completion-operation-id completion)
                              (state-committed-message-state-version response)))))
                  (test-equal "cached observation does not call backend"
                    calls (real-calls authority)))
                (finish-state-response! state-endpoint peer)

                (send-read! state-endpoint peer typed-ready)
                (let ((completion (wait-for-completion! state-endpoint)))
                  (test-equal "read observes present empty after commit"
                    '(#t 2 "")
                    (let ((response
                           (book-state-completion-response completion)))
                      (list (state-value-message-present? response)
                            (state-value-message-state-version response)
                            (state-value-message-text response)))))
                (finish-state-response! state-endpoint peer)

                (send-commit! state-endpoint peer typed-ready
                              "AdvanceState_3" 2 "later-state")
                (wait-for-completion! state-endpoint)
                (finish-state-response! state-endpoint peer)
                (send-commit! state-endpoint peer typed-ready
                              "EmptyState_2" 1 "")
                (let ((completion (wait-for-completion! state-endpoint)))
                  (test-equal
                      "old exact retry observes original receipt after advance"
                    '("EmptyState_2" 1 2)
                    (let ((response
                           (book-state-completion-response completion)))
                      (list (book-state-completion-operation-id completion)
                            (book-state-completion-expected-state-version
                             completion)
                            (state-committed-message-state-version response)))))
                (finish-state-response! state-endpoint peer)

                ;; Keep the next read completion undrained after its wire frame
                ;; is delivered. The finite slot rejects state only.
                (send-read! state-endpoint peer typed-ready)
                (wait-for-output! state-endpoint)
                (flush-output! state-endpoint)
                (let ((wire (read-frame peer))
                      (calls (real-calls authority)))
                  (test-equal "old retry did not overwrite current state"
                    '(3 "later-state")
                    (list (field wire "state_version") (field wire "text")))
                  (write-state-message!
                   peer
                   (make-state-read-message
                    (state-ready-message-grant-handle typed-ready)
                    (state-ready-message-grant-generation typed-ready)))
                  (test-equal "real undrained sink rejects before backend"
                    'backpressure
                    (catch 'book-session-error
                      (lambda () (pump-eventually state-endpoint) #f)
                      (lambda (_ kind message) kind)))
                  (test-equal "real undrained sink retains one backend call"
                    calls (real-calls authority)))
                (let ((action
                       (host-action! state-endpoint
                                     "surface-under-real-pressure" "x")))
                  (write-frame peer (present-for-action action "responsive"))
                  (test-equal "real surface path stays responsive under sink pressure"
                    "responsive"
                    (presented-text-value
                     (car (endpoint-pump-result-values
                           (pump-eventually state-endpoint))))))
                (wait-for-completion! state-endpoint)
                (send-read! state-endpoint peer typed-ready)
                (wait-for-completion! state-endpoint)
                (finish-state-response! state-endpoint peer)

                (let ((nul (make-string max-state-text-bytes #\nul)))
                  (send-commit! state-endpoint peer typed-ready
                                "NulState_4" 3 nul)
                  (let ((completion
                         (wait-for-completion! state-endpoint)))
                    (test-equal "observer accepts exact 4096-NUL commit text"
                      4096
                      (string-length
                       (book-state-completion-text completion))))
                  (finish-state-response! state-endpoint peer)
                  (send-read! state-endpoint peer typed-ready)
                  (wait-for-output! state-endpoint)
                  (test-equal "observer leaves 4096-NUL wire bound unchanged"
                    24666 (snapshot state-endpoint "outbound_bytes"))
                  (let* ((completion
                          (wait-for-completion! state-endpoint))
                         (response
                          (book-state-completion-response completion))
                         (private-text
                          ((@@ (book-state-protocol)
                               %state-value-message-text)
                           response)))
                    (string-set! private-text 0 #\X)
                    (test-assert
                        "NUL response accessor mutation cannot change observer"
                      (string-every
                       #\nul
                       (state-value-message-text
                        (book-state-completion-response completion)))))
                  (flush-output! state-endpoint)
                  (let ((wire (read-frame peer)))
                    (test-assert
                        "observer mutation cannot change queued NUL wire bytes"
                      (string-every #\nul (field wire "text")))))

                ;; A second endpoint cannot select this endpoint's observer or
                ;; grant using copied wire tokens.
                (let ((calls (real-calls authority)))
                  (call-with-values
                      (lambda ()
                        (open-session-endpoint! state-host "wrong-endpoint"))
                    (lambda (wrong-endpoint wrong-peer)
                      (call-with-values
                          (lambda () (initialize! wrong-endpoint wrong-peer))
                        (lambda (wrong-initialize wrong-ready wrong-typed-ready)
                          (write-state-message!
                           wrong-peer
                           (make-state-read-message
                            (state-ready-message-grant-handle typed-ready)
                            (state-ready-message-grant-generation typed-ready)))
                          (test-equal "wrong endpoint token fails in accepted FSM"
                            'binding
                            (state-protocol-error-kind
                             (lambda ()
                               (pump-eventually wrong-endpoint))))
                          (test-assert "wrong endpoint exposes no completion"
                            (not (endpoint-take-state-completion!
                                  wrong-endpoint)))))
                      (release-session-endpoint! wrong-endpoint)
                      (close-port wrong-peer)))
                  (test-equal "wrong endpoint performs no backend mutation"
                    calls (real-calls authority)))
                (release-session-endpoint! state-endpoint)
                (close-port peer)))))
      (trace "real socket cases complete")
      (close-book-state-store! (real-store authority))
      (trace "native/real store closed")
      (set! complete? #t)))
    (lambda ()
      (unless complete?
        (when endpoint
          (catch #t
            (lambda () (release-session-endpoint! endpoint))
            (lambda arguments #f)))
        (terminate-child! child)
        (catch #t
          (lambda () (close-book-state-store! (real-store authority)))
          (lambda arguments #f))))))

;; Commit-first/close race with the real SQLite backend: close clears the
;; reservation before waiting for revocation. The durable write is recovered by
;; a fresh endpoint, but the old UI lifetime can never observe a false save.
(let* ((root (make-root "late-close"))
       (gate (make-mutex))
       (condition (make-condition-variable))
       (entered? #f)
       (release? #f)
       (authority #f)
       (endpoint #f)
       (peer #f))
  (trace "begin real late-close case")
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
  (trace "late-close opening store")
  (set! authority
        (make-real-authority root "observer/late-close@1" "stable-note"))
  (trace "late-close store opened")
  (parameterize ((commit-fault-hook-for-test fault-hook))
    (let ((host (observer-host authority)))
      (call-with-values
          (lambda () (open-session-endpoint! host "late-close-old"))
        (lambda (opened opened-peer)
          (set! endpoint opened)
          (set! peer opened-peer)))
      (trace "late-close endpoint opened")
      (call-with-values
          (lambda () (initialize! endpoint peer))
        (lambda (initialize ready typed-ready)
          (trace "late-close endpoint initialized")
          (send-read! endpoint peer typed-ready)
          (trace "late-close read dispatched")
          (wait-for-completion! endpoint)
          (trace "late-close read observed")
          (finish-state-response! endpoint peer)
          (trace "late-close read flushed")
          (send-commit! endpoint peer typed-ready
                        "LateCloseCommit_1" 0 "durable-no-observer")
          (trace "late-close commit dispatched")
          (wait-for
           (lambda ()
             (lock-mutex gate)
             (let ((value entered?)) (unlock-mutex gate) value))
           "real commit did not enter close race gate")
          (trace "late-close backend at barrier")
          (let ((closer (call-with-new-thread (lambda () (close-session! endpoint)))))
            (wait-for (lambda () (eq? (snapshot endpoint "state") 'closed))
                      "close did not invalidate endpoint locally")
            (test-assert "late closed endpoint cannot report saved"
              (not (endpoint-take-state-completion! endpoint)))
            (test-equal "close clears output and observer before revoke wait"
              '(0 #f)
              (list (snapshot endpoint "outbound_frames")
                    (snapshot endpoint "transport_open")))
            (trace "late-close local invalidation observed")
            (lock-mutex gate)
            (set! release? #t)
            (broadcast-condition-variable condition)
            (unlock-mutex gate)
            (join-thread closer)
            (trace "late-close closer joined")
            (test-assert "late backend completion remains unobservable"
              (not (endpoint-take-state-completion! endpoint))))))
      (close-port-quietly! peer)
      (call-with-values
          (lambda () (open-session-endpoint! host "late-close-recovery"))
        (lambda (fresh fresh-peer)
          (call-with-values
              (lambda () (initialize! fresh fresh-peer))
            (lambda (initialize ready typed-ready)
              (send-read! fresh fresh-peer typed-ready)
              (let* ((completion (wait-for-completion! fresh))
                     (response (book-state-completion-response completion)))
                (test-equal "fresh read recovers commit with lost observer"
                  '(#t 1 "durable-no-observer")
                  (list (state-value-message-present? response)
                        (state-value-message-state-version response)
                        (state-value-message-text response))))
              (finish-state-response! fresh fresh-peer)
              (send-commit! fresh fresh-peer typed-ready
                            "LateCloseCommit_1" 0 "durable-no-observer")
              (let* ((completion (wait-for-completion! fresh))
                     (response (book-state-completion-response completion)))
                (test-equal "exact retry after reopen recovers lost receipt"
                  '(commit "LateCloseCommit_1" 0 1)
                  (list (book-state-completion-operation-kind completion)
                        (book-state-completion-operation-id completion)
                        (book-state-completion-expected-state-version completion)
                        (state-committed-message-state-version response))))
              (finish-state-response! fresh fresh-peer)))
          (release-session-endpoint! fresh)
          (close-port fresh-peer)))
      (close-book-state-store! (real-store authority)))))

(test-end "real-book-state-completion-observer")
(cleanup-roots!)
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
