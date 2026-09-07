;;; Trusted one-book authority for the deterministic commit/close/retry test.
;;; Its test-only RUN-OPERATION wrapper invokes the real accepted adapter and
;;; pauses only after that adapter has returned, before the worker can publish.
(use-modules (book-session)
             (book-state)
             (book-state-backend-adapter)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (ice-9 threads)
             (json)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-9))

(define deadline-seconds 20)
(define max-child-log-bytes (* 128 1024))
(define tool-dir (dirname (canonicalize-path (car (command-line)))))

(define-record-type <owned-child>
  (%make-owned-child pid start-time process-group record-path log-path status)
  owned-child?
  (pid child-pid)
  (start-time child-start-time)
  (process-group child-process-group)
  (record-path child-record-path)
  (log-path child-log-path)
  (status child-status set-child-status!))

(define (fail message . details) (error message details))
(define (field object name) (assoc-ref object name))
(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))
(define (now-ticks) (get-internal-real-time))
(define (after-seconds seconds)
  (+ (now-ticks) (* seconds internal-time-units-per-second)))

(define (marker text . arguments)
  (format #t "BOOK_STATE_LOST_ACK_AUTHORITY: ~a~%"
          (apply format #f text arguments))
  (force-output))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (read-process-fields pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((text (call-with-input-file path get-string-all))
                    (close (string-rindex text #\))))
               (and close (string-tokenize (substring text (+ close 2))))))
           (lambda arguments #f)))))

(define (read-process-start-time pid)
  (let ((fields (read-process-fields pid)))
    (and fields (>= (length fields) 20) (list-ref fields 19))))

(define (read-process-group pid)
  (let ((fields (read-process-fields pid)))
    (and fields (>= (length fields) 3)
         (string->number (list-ref fields 2) 10))))

(define (decode-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   ((status:stop-sig status) => (lambda (value) (cons 'stopped value)))
   (else (cons 'unknown status))))

(define (wait-stopped! pid)
  (let loop ()
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid pid WUNTRACED))
             (lambda arguments
               (if (= (system-error-errno arguments) EINTR)
                   #f (apply throw arguments))))))
      (if (not waited)
          (loop)
          (let ((decoded (decode-status (cdr waited))))
            (unless (and (= (car waited) pid)
                         (equal? decoded (cons 'stopped SIGSTOP)))
              (fail "book did not stop before protocol work" decoded)))))))

(define (write-process-record! path pid start-time process-group)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port)
        (format port "~a ~a ~a~%" pid start-time process-group)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (find-executable name)
  (or (search-path (parse-path (getenv "PATH")) name)
      (fail "required executable is absent" name)))

(define (spawn-book! run-directory mode operation-id donation)
  (let* ((guile (find-executable "guile"))
         (record-path (string-append run-directory "/lost-ack.pid"))
         (log-path (string-append run-directory "/lost-ack.log"))
         (log-port (open-file log-path "w0"))
         (arguments
          (list guile "--no-auto-compile"
                (string-append tool-dir "/lost-ack-book.scm")
                mode operation-id))
         (environment
          (list "BOOK_SESSION_FD=0"
                "HOME=/nonexistent"
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "PATH=/nonexistent"
                "GUILE_AUTO_COMPILE=0"
                (string-append "GUILE_LOAD_PATH="
                               (or (getenv "BOOK_FIXTURE_GUILE_LOAD_PATH")
                                   (fail "exact Guile fixture source path is unset")))
                (string-append
                 "GUILE_LOAD_COMPILED_PATH="
                 (or (getenv "BOOK_FIXTURE_GUILE_LOAD_COMPILED_PATH")
                     (fail "exact Guile fixture compiled path is unset")))))
         (pid #f)
         (published? #f))
    (chmod log-path #o600)
    (unless (positive? (logand (fcntl donation F_GETFD) FD_CLOEXEC))
      (fail "Book Session donation is not FD_CLOEXEC"))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! pid
              (spawn guile arguments #:search-path? #f
                     #:environment environment #:input donation
                     #:output log-port #:error log-port))
        (wait-stopped! pid)
        (let ((start-time (read-process-start-time pid))
              (process-group (read-process-group pid)))
          (unless (and start-time (= process-group pid))
            (fail "book did not establish exact process identity"))
          (write-process-record! record-path pid start-time process-group)
          (close-port-quietly! donation)
          (close-port-quietly! log-port)
          (kill pid SIGCONT)
          (set! published? #t)
          (%make-owned-child pid start-time process-group
                             record-path log-path #f)))
      (lambda ()
        (unless published?
          (close-port-quietly! donation)
          (close-port-quietly! log-port)
          (when pid
            (catch 'system-error
              (lambda () (kill pid SIGKILL))
              (lambda arguments #f))
            (catch 'system-error
              (lambda () (waitpid pid))
              (lambda arguments #f)))
          (when (file-exists? record-path) (delete-file record-path)))))))

(define (reap-child! child)
  (unless (child-status child)
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid (child-pid child) WNOHANG))
             (lambda arguments
               (if (= (system-error-errno arguments) ECHILD)
                   #f (apply throw arguments))))))
      (when (and waited (not (zero? (car waited))))
        (set-child-status! child (decode-status (cdr waited)))
        (when (file-exists? (child-record-path child))
          (delete-file (child-record-path child))))))
  (child-status child))

(define (child-current? child)
  (let ((start (read-process-start-time (child-pid child))))
    (and start (string=? start (child-start-time child)))))

(define (group-exists? group)
  (catch 'system-error
    (lambda () (kill (- group) 0) #t)
    (lambda arguments
      (not (= (system-error-errno arguments) ESRCH)))))

(define (signal-group! child signal)
  (when (child-current? child)
    (catch 'system-error
      (lambda () (kill (- (child-process-group child)) signal))
      (lambda arguments
        (unless (= (system-error-errno arguments) ESRCH)
          (apply throw arguments))))))

(define (wait-child-ended! child deadline)
  (let loop ()
    (reap-child! child)
    (cond
     ((and (child-status child)
           (not (group-exists? (child-process-group child)))) #t)
     ((>= (now-ticks) deadline) #f)
     (else (usleep 10000) (loop)))))

(define (terminate-child! child)
  (when child
    (reap-child! child)
    (unless (and (child-status child)
                 (not (group-exists? (child-process-group child))))
      (signal-group! child SIGTERM)
      (unless (wait-child-ended! child (after-seconds 2))
        (signal-group! child SIGKILL)
        (unless (wait-child-ended! child (after-seconds 2))
          (fail "could not reap exact lost-ack book"))))
    (when (file-exists? (child-record-path child))
      (delete-file (child-record-path child)))))

(define (child-log child)
  (let ((size (stat:size (stat (child-log-path child)))))
    (when (>= size max-child-log-bytes)
      (fail "lost-ack book reached its log bound"))
    (call-with-input-file (child-log-path child) get-string-all)))

(define (backend-value! context value)
  (if (book-state-rejection? value)
      (fail context (book-state-rejection-code value))
      value))

(define (make-test-factory store namespace mode gate condition entered release)
  (define (open-binding owner)
    (let ((grant
           (backend-value!
            "could not issue lost-ack grant"
            (issue-book-state-grant! store namespace owner 'read-write))))
      (make-state-endpoint-binding
       owner grant (book-state-grant-handle grant)
       (book-state-grant-generation grant) (book-state-grant-access grant))))
  (define (run-operation operation)
    ;; This call is the real accepted adapter.  The baton is deliberately after
    ;; it returns and before this callback returns to the delegate worker.
    (let ((result (run-state-backend-operation store operation)))
      (when (and (string=? mode "lose")
                 (state-commit-operation? operation))
        (lock-mutex gate)
        (set-car! entered #t)
        (broadcast-condition-variable condition)
        (let wait ()
          (unless (car release)
            (wait-condition-variable condition gate)
            (wait)))
        (unlock-mutex gate))
      result))
  (define (revoke-binding binding)
    (revoke-state-backend-binding! store binding))
  (make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(define (pump-eventually endpoint)
  (let loop ((attempt 0))
    (when (= attempt 10000) (fail "timed out pumping book input"))
    (let ((result (endpoint-pump-input! endpoint)))
      (if (memq (endpoint-pump-result-status result)
                '(would-block interrupted budget))
          (begin (usleep 1000) (loop (+ attempt 1)))
          result))))

(define (pump-output! endpoint)
  (when (positive? (or (snapshot endpoint "outbound_frames") 0))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (unless (memq status '(drained budget would-block interrupted))
        (fail "unexpected endpoint output status" status)))))

(define (state-dispatch? value)
  (and (state-delegate-dispatch-result? value)
       (memq (state-delegate-dispatch-result-status value)
             '(queued cached))))

(define (write-json! path value)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port)
        (display (scm->json-string value #:unicode #t #:pretty #t) port)
        (newline port)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (wait-for predicate deadline message)
  (let loop ()
    (cond
     ((predicate) #t)
     ((>= (now-ticks) deadline) (fail message))
     (else (usleep 1000) (loop)))))

(define (handle-hello! endpoint items)
  (unless (and (= (length items) 2)
               (state-ready-message? (cadr items)))
    (fail "hello did not return initialize then state-ready"))
  (endpoint-queue-message! endpoint (car items))
  (endpoint-queue-message! endpoint (cadr items))
  (values (car items) (cadr items)))

(define (run root run-directory result-path mode operation-id edit-text)
  (let* ((store (open-book-state-store root))
         (namespace
          (backend-value!
           "could not open lost-ack namespace"
           (open-book-instance!
            store "native-state-note/lost-ack/guile@1" "stable-lost-ack")))
         (gate (make-mutex))
         (condition (make-condition-variable))
         (entered (list #f))
         (release (list #f))
         (factory
          (make-test-factory store namespace mode gate condition entered release))
         (host (make-book-session-host-with-state factory))
         (endpoint #f)
         (donation #f)
         (child #f)
         (initialize #f)
         (ready #f)
         (phase 'hello)
         (receipt-text #f)
         (complete? #f))
    (define (cleanup!)
      (when (and endpoint (not (eq? (snapshot endpoint "state") 'closed)))
        (catch #t
          (lambda () (release-session-endpoint! endpoint))
          (lambda arguments
            (catch #t (lambda () (close-session! endpoint))
                   (lambda ignored #f)))))
      (close-port-quietly! donation)
      (terminate-child! child)
      (when (eq? (book-state-store-phase store) 'open)
        (catch #t
          (lambda () (close-book-state-store! store))
          (lambda arguments #f)))
      (unless complete?
        (when child
          (format (current-error-port) "--- lost-ack book log ---~%~a"
                  (child-log child)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host "lost-ack-guile"))
          (lambda (new-endpoint new-donation)
            (set! endpoint new-endpoint)
            (set! donation new-donation)))
        (set! child (spawn-book! run-directory mode operation-id donation))
        (set! donation #f)
        (let ((deadline (after-seconds deadline-seconds)))
          (let loop ()
            (when (>= (now-ticks) deadline)
              (fail "lost-ack authority phase timed out" mode phase))
            (when (memq 'input (endpoint-ready-events endpoint))
              (let ((pump (endpoint-pump-input! endpoint)))
                (when (eq? (endpoint-pump-result-status pump) 'committed)
                  (let ((values (endpoint-pump-result-values pump)))
                    (case phase
                      ((hello)
                       (call-with-values
                           (lambda () (handle-hello! endpoint values))
                         (lambda (new-initialize new-ready)
                           (set! initialize new-initialize)
                           (set! ready new-ready)))
                       (endpoint-queue-message!
                        endpoint (host-action! endpoint "load-display" "DISPLAY"))
                       (set! phase 'load))
                      ((load)
                       (let ((value (car values)))
                         (if (state-dispatch? value)
                             #t
                             (begin
                               (unless (presented-text? value)
                                 (fail "load phase returned unknown value" value))
                               (endpoint-queue-message!
                                endpoint
                                (host-action!
                                 endpoint "edit-save"
                                 (if (string=? mode "lose")
                                     edit-text "RETRY-LOADED")))
                               (set! phase 'save)))))
                      ((save)
                       (let ((value (car values)))
                         (cond
                          ((state-dispatch? value) (set! phase 'commit))
                          ((presented-text? value)
                           (set! receipt-text (presented-text-value value))
                           (set! phase 'done))
                          (else (fail "save phase returned unknown value" value)))))
                      ((commit)
                       (let ((value (car values)))
                         (cond
                          ((state-dispatch? value) #t)
                          ((presented-text? value)
                           (set! receipt-text (presented-text-value value))
                           (set! phase 'done))
                          (else
                           (fail "commit phase returned unknown value" value)))))
                      (else (fail "input arrived after phase completion")))))))
            (pump-output! endpoint)
            (reap-child! child)
            (cond
             ((and (string=? mode "lose") (car entered)) #t)
             ((and (string=? mode "retry")
                   (eq? phase 'done)
                   (equal? (child-status child) '(exit . 0))) #t)
             ((and (string=? mode "pretend-loss")
                   (eq? phase 'commit)
                   (equal? (child-status child) '(exit . 0))) #t)
             ((child-status child)
              (fail "lost-ack book exited early" (child-status child) phase))
             (else (usleep 1000) (loop)))))

        (if (string=? mode "lose")
            (let ((close-finished? #f)
                  (closer #f)
                  (barrier-path
                   (string-append run-directory "/adapter-returned.json"))
                  (release-path (string-append run-directory "/release")))
              (unless (zero? (snapshot endpoint "outbound_frames"))
                (fail "response queued before post-adapter baton"))
              (set! closer
                    (call-with-new-thread
                     (lambda ()
                       (close-session! endpoint)
                       (set! close-finished? #t))))
              (wait-for (lambda () (eq? (snapshot endpoint "state") 'closed))
                        (after-seconds 5)
                        "endpoint did not invalidate while callback paused")
              (wait-for
               (lambda ()
                 (and (equal? (reap-child! child) '(exit . 0))
                      (not (group-exists? (child-process-group child)))))
               (after-seconds 5)
               "loss book did not observe EOF and exit")
              (let ((log (child-log child)))
                (unless (and (= (count
                                  (lambda (line)
                                    (string=? line
                                      "LOST_ACK_BOOK: EOF-before-state-committed:ok"))
                                  (string-split log #\newline)) 1)
                             (not (string-contains
                                   log "state-committed-consumed")))
                  (fail "loss book did not prove EOF before receipt")))
              (write-json!
               barrier-path
               `(("format" . 1)
                 ("authority_pid" . ,(getpid))
                 ("authority_start_time" . ,(read-process-start-time (getpid)))
                 ("child_pid" . ,(child-pid child))
                 ("child_start_time" . ,(child-start-time child))
                 ("operation_id" . ,operation-id)
                 ("adapter_returned" . #t)
                 ("endpoint_closed" . #t)
                 ("outbound_frames" . ,(snapshot endpoint "outbound_frames"))
                 ("state_committed_consumed" . #f)))
              (wait-for (lambda () (file-exists? release-path))
                        (after-seconds 10)
                        "external SQLite oracle did not release callback baton")
              (lock-mutex gate)
              (set-car! release #t)
              (broadcast-condition-variable condition)
              (unlock-mutex gate)
              (join-thread closer)
              (unless (and close-finished?
                           (zero? (snapshot endpoint "outbound_frames")))
                (fail "close did not reap callback without acknowledgement"))
              ;; CLOSE invalidates transport/delegate first; RELEASE now only
              ;; removes the already-closed endpoint from the host registry.
              (release-session-endpoint! endpoint))
            (begin
              (unless (equal? (child-status child) '(exit . 0))
                (fail "acknowledged/retry book did not exit zero"))))

        (let ((log (child-log child)))
          (write-json!
           result-path
           `(("format" . 2)
             ("mode" . ,mode)
             ("authority_pid" . ,(getpid))
             ("authority_start_time" . ,(read-process-start-time (getpid)))
             ("child_pid" . ,(child-pid child))
             ("child_start_time" . ,(child-start-time child))
             ("child_exit_code" . ,(and (child-status child)
                                        (eq? (car (child-status child)) 'exit)
                                        (cdr (child-status child))))
             ("session_id" . ,(snapshot endpoint "session_id"))
             ("surface_handle" . ,(field initialize "surface_handle"))
             ("state_grant_handle" .
              ,(state-ready-message-grant-handle ready))
             ("state_grant_generation" .
              ,(state-ready-message-grant-generation ready))
             ("operation_id" . ,operation-id)
             ("adapter_returned" . ,(if (string=? mode "lose") #t #f))
             ("endpoint_closed" .
              ,(eq? (snapshot endpoint "state") 'closed))
             ("outbound_frames" . ,(snapshot endpoint "outbound_frames"))
             ("state_committed_consumed" .
              ,(not (not (or (string-contains log "state-committed-consumed")
                             (string-contains
                              log "original-receipt-consumed-after-restart")))))
             ("eof_before_state_committed" .
              ,(not (not (string-contains
                          log "EOF-before-state-committed:ok"))))
             ("receipt_text" . ,(or receipt-text "")))))
        (unless (string=? mode "lose")
          (release-session-endpoint! endpoint))
        (close-book-state-store! store)
        (set! complete? #t)
        (marker "phase ~a complete" mode))
      cleanup!)))

(let ((arguments (cdr (command-line))))
  (unless (or (= (length arguments) 5) (= (length arguments) 6))
    (fail
     "usage: lost-ack-authority.scm ROOT RUN-DIR RESULT MODE OPERATION-ID [TEXT]"))
  (let ((mode (list-ref arguments 3))
        (edit-text (and (= (length arguments) 6) (list-ref arguments 5))))
    (unless (member mode '("lose" "retry" "pretend-loss"))
      (fail "invalid lost-ack authority mode" mode))
    (when (and (string=? mode "lose") (not edit-text))
      (fail "loss phase requires one trusted edit value"))
    (when (and (not (string=? mode "lose")) edit-text)
      (fail "retry/counterexample phase must not receive state text"))
    (run (list-ref arguments 0) (list-ref arguments 1)
         (list-ref arguments 2) mode (list-ref arguments 4) edit-text)))
