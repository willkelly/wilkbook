;;; Trusted native subprocess proof for the real Book State + Book Session join.
(use-modules (book-session)
             (book-state-integration)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (json)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-9))

(define deadline-seconds 30)
(define loop-sleep-microseconds 2000)
(define max-child-log-bytes (* 128 1024))
(define tool-dir (dirname (canonicalize-path (car (command-line)))))

(define-record-type <owned-child>
  (%make-owned-child label pid start-time process-group record-path log-path
                     status)
  owned-child?
  (label child-label)
  (pid child-pid)
  (start-time child-start-time)
  (process-group child-process-group)
  (record-path child-record-path)
  (log-path child-log-path)
  (status child-status set-child-status!))

(define-record-type <native-peer>
  (%make-native-peer label endpoint donation child phase operation-id child-mode
                     edit-text initialize ready dispatch-statuses load-text
                     receipt-text released?)
  native-peer?
  (label peer-label)
  (endpoint peer-endpoint)
  (donation peer-donation set-peer-donation!)
  (child peer-child set-peer-child!)
  (phase peer-phase set-peer-phase!)
  (operation-id peer-operation-id)
  (child-mode peer-child-mode)
  (edit-text peer-edit-text)
  (initialize peer-initialize set-peer-initialize!)
  (ready peer-ready set-peer-ready!)
  (dispatch-statuses peer-dispatch-statuses set-peer-dispatch-statuses!)
  (load-text peer-load-text set-peer-load-text!)
  (receipt-text peer-receipt-text set-peer-receipt-text!)
  (released? peer-released? set-peer-released?!))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (marker text . arguments)
  (format #t "BOOK_STATE_NATIVE_AUTHORITY: ~a~%"
          (apply format #f text arguments))
  (force-output))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (field object name)
  (let ((entry (assoc name object)))
    (and entry (cdr entry))))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (now-ticks)
  (get-internal-real-time))

(define (after-seconds seconds)
  (+ (now-ticks) (* seconds internal-time-units-per-second)))

(define (read-process-start-time pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((text (call-with-input-file path get-string-all))
                    (close (string-rindex text #\)))
                    (fields
                     (and close
                          (string-tokenize (substring text (+ close 2))))))
               ;; The suffix starts at field 3; Linux start time is field 22.
               (and fields (>= (length fields) 20) (list-ref fields 19))))
           (lambda arguments #f)))))

(define (read-process-group pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((text (call-with-input-file path get-string-all))
                    (close (string-rindex text #\)))
                    (fields
                     (and close
                          (string-tokenize (substring text (+ close 2))))))
               ;; The suffix starts at field 3; process group is field 5.
               (and fields (>= (length fields) 3)
                    (string->number (list-ref fields 2) 10))))
           (lambda arguments #f)))))

(define (write-process-record! path pid start-time process-group)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port)
        (format port "~a ~a ~a~%" pid start-time process-group)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (decode-child-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   ((status:stop-sig status) => (lambda (value) (cons 'stopped value)))
   (else (cons 'unknown status))))

(define (wait-stopped-child! pid)
  (let retry ()
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid pid WUNTRACED))
             (lambda arguments
               (if (= (system-error-errno arguments) EINTR)
                   #f
                   (apply throw arguments))))))
      (if (not waited)
          (retry)
          (let ((decoded (decode-child-status (cdr waited))))
            (unless (and (= (car waited) pid)
                         (eq? (car decoded) 'stopped)
                         (= (cdr decoded) SIGSTOP))
              (fail "child ~a did not stop before protocol work: ~s"
                    pid decoded)))))))

(define (find-executable name)
  (or (search-path (parse-path (getenv "PATH")) name)
      (fail "required executable is absent: ~a" name)))

(define (child-environment language)
  (let ((common
         (list "BOOK_SESSION_FD=0"
               "HOME=/nonexistent"
               "LANG=C.UTF-8"
               "LC_ALL=C.UTF-8"
               "PATH=/nonexistent")))
    (case language
      ((guile)
       (append
        common
        (list "GUILE_AUTO_COMPILE=0"
              (string-append
               "GUILE_LOAD_PATH="
               (or (getenv "BOOK_FIXTURE_GUILE_LOAD_PATH")
                   (fail "exact Guile fixture source path is unset")))
              (string-append
               "GUILE_LOAD_COMPILED_PATH="
               (or (getenv "BOOK_FIXTURE_GUILE_LOAD_COMPILED_PATH")
                   (fail "exact Guile fixture compiled path is unset"))))))
      ((python)
       (append
        common
        (list "PYTHONDONTWRITEBYTECODE=1"
              "PYTHONUTF8=1")))
      (else (fail "unknown child language: ~s" language)))))

(define (spawn-arguments language mode operation-id)
  (case language
    ((guile)
     (let ((guile (find-executable "guile")))
       (cons guile
             (list "--no-auto-compile"
                   (string-append tool-dir "/fixture-book.scm")
                   mode operation-id "0"))))
    ((python)
     (let ((python (find-executable "python3")))
       (cons python
              (list "-I" "-S"
                    (or (getenv "BOOK_FIXTURE_PYTHON_LAUNCHER")
                        (fail "exact Python fixture launcher is unset"))
                    (or (getenv "BOOK_FIXTURE_PYTHON_CODEC")
                        (fail "exact Python codec path is unset"))
                    (string-append tool-dir "/fixture_book.py")
                    mode operation-id "0"))))
    (else (fail "unknown child language: ~s" language))))

(define (assert-donation-cloexec! donation)
  (let ((flags (fcntl donation F_GETFD)))
    (unless (positive? (logand flags FD_CLOEXEC))
      (fail "accepted Book Session peer is not FD_CLOEXEC"))))

(define (spawn-owned-child! peer language run-directory)
  (let* ((donation (peer-donation peer))
         (label (peer-label peer))
         (record-path (string-append run-directory "/" label ".pid"))
         (log-path (string-append run-directory "/" label ".log"))
         (arguments
          (spawn-arguments language (peer-child-mode peer)
                           (peer-operation-id peer)))
         (executable (car arguments))
         (log-port (open-file log-path "w0"))
         (pid #f)
         (published? #f))
    (chmod log-path #o600)
    (assert-donation-cloexec! donation)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; Guile spawn inherits only selected stdio descriptors.  The accepted
        ;; socketpair peer becomes bidirectional FD 0; no SQLite or sibling
        ;; endpoint descriptor is inherited.
        (set! pid
              (spawn executable arguments
                     #:search-path? #f
                     #:environment (child-environment language)
                     #:input donation #:output log-port #:error log-port))
        (wait-stopped-child! pid)
        (let ((start-time (read-process-start-time pid))
              (process-group (read-process-group pid)))
          (unless (and start-time (= process-group pid))
            (fail "child did not establish its recorded process identity"))
          (write-process-record! record-path pid start-time process-group)
          (let ((child
                 (%make-owned-child
                  label pid start-time process-group record-path log-path #f)))
            (set-peer-child! peer child)
            (close-port-quietly! donation)
            (set-peer-donation! peer #f)
            (close-port-quietly! log-port)
            (kill pid SIGCONT)
            (set! published? #t)
            child)))
      (lambda ()
        (unless published?
          (close-port-quietly! log-port)
          (close-port-quietly! donation)
          (set-peer-donation! peer #f)
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
                   #f
                   (apply throw arguments))))))
      (when (and waited (not (zero? (car waited))))
        (set-child-status! child (decode-child-status (cdr waited)))
        (when (file-exists? (child-record-path child))
          (delete-file (child-record-path child))))))
  (child-status child))

(define (child-current? child)
  (let ((start-time (read-process-start-time (child-pid child))))
    (and start-time (string=? start-time (child-start-time child)))))

(define (process-group-exists? process-group)
  (catch 'system-error
    (lambda () (kill (- process-group) 0) #t)
    (lambda arguments
      (not (= (system-error-errno arguments) ESRCH)))))

(define (signal-child-group! child signal-number)
  (when (child-current? child)
    (catch 'system-error
      (lambda () (kill (- (child-process-group child)) signal-number))
      (lambda arguments
        (unless (= (system-error-errno arguments) ESRCH)
          (apply throw arguments))))))

(define (wait-child-ended! child deadline)
  (let loop ()
    (reap-child! child)
    (if (and (child-status child)
             (not (process-group-exists? (child-process-group child))))
        #t
        (and (< (now-ticks) deadline)
             (begin (usleep 20000) (loop))))))

(define (terminate-child! child)
  (when child
    (reap-child! child)
    (unless (and (child-status child)
                 (not (process-group-exists? (child-process-group child))))
      (signal-child-group! child SIGTERM)
      (unless (wait-child-ended!
               child (after-seconds 2))
        (signal-child-group! child SIGKILL)
        (unless (wait-child-ended!
                 child (after-seconds 2))
          (fail "could not reap exact child ~a" (child-label child)))))
    (when (file-exists? (child-record-path child))
      (delete-file (child-record-path child)))))

(define (peer-edit-action-text peer)
  (case (string->symbol (peer-child-mode peer))
    ((save) (peer-edit-text peer))
    ((save-loaded) "SAVE-LOADED")
    ((replay) "REPLAY-LOADED")
    ((boundary-save) "SAVE-NUL-4096")
    (else (fail "unknown peer child mode: ~a" (peer-child-mode peer)))))

(define (handle-hello! peer values)
  (unless (and (= (length values) 2)
               (list? (car values))
               (string=? (field (car values) "type") "initialize")
               (state-ready-message? (cadr values)))
    (fail "~a hello did not return initialize then typed state-ready"
          (peer-label peer)))
  (set-peer-initialize! peer (car values))
  (set-peer-ready! peer (cadr values))
  ;; Physical queue order is part of the seam: initialize, state-ready, then
  ;; the first fixed action.  Queueing state-ready also announces the grant.
  (endpoint-queue-message! (peer-endpoint peer) (car values))
  (endpoint-queue-message! (peer-endpoint peer) (cadr values))
  (endpoint-queue-message!
   (peer-endpoint peer)
   (host-action! (peer-endpoint peer) "load-display" "DISPLAY-LOADED"))
  (set-peer-phase! peer 'load))

(define (handle-dispatch-result! peer value)
  (let ((status (state-delegate-dispatch-result-status value)))
    (unless (memq status '(queued already-pending cached))
      (fail "~a returned unknown state scheduling status ~s"
            (peer-label peer) status))
    ;; Scheduling facts are deliberately retained separately and never passed
    ;; to surface presentation handling.
    (set-peer-dispatch-statuses!
     peer (append (peer-dispatch-statuses peer) (list status)))))

(define (handle-presentation! peer value)
  (let ((action-id (presented-text-action-id value))
        (text (presented-text-value value)))
    (case (peer-phase peer)
      ((load)
       (unless (string=? action-id "load-display")
         (fail "~a presented the wrong load action" (peer-label peer)))
       (set-peer-load-text! peer text)
       (endpoint-queue-message!
        (peer-endpoint peer)
        (host-action! (peer-endpoint peer) "edit-save"
                      (peer-edit-action-text peer)))
       (set-peer-phase! peer 'save))
      ((save)
       (unless (string=? action-id "edit-save")
         (fail "~a presented the wrong save action" (peer-label peer)))
       (set-peer-receipt-text! peer text)
       (set-peer-phase! peer 'done))
      (else
       (fail "~a produced a presentation in phase ~s"
             (peer-label peer) (peer-phase peer))))))

(define (handle-committed-values! peer values)
  (case (peer-phase peer)
    ((hello) (handle-hello! peer values))
    (else
     (unless (= (length values) 1)
       (fail "~a input pump committed ~a values outside hello"
             (peer-label peer) (length values)))
     (let ((value (car values)))
       (cond
        ((state-delegate-dispatch-result? value)
         (handle-dispatch-result! peer value))
        ((presented-text? value) (handle-presentation! peer value))
        (else
         (fail "~a returned an unrecognized dispatch value"
               (peer-label peer))))))))

(define (pump-peer! peer)
  (let ((endpoint (peer-endpoint peer)))
    (when (memq 'input (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-input! endpoint)))
        (case (endpoint-pump-result-status result)
          ((committed)
           (handle-committed-values!
            peer (endpoint-pump-result-values result)))
          ((eof closed stale)
           (unless (eq? (peer-phase peer) 'done)
             (fail "~a endpoint closed in phase ~s"
                   (peer-label peer) (peer-phase peer))))
          ((would-block interrupted budget) #t)
          (else
           (fail "~a returned unknown input status ~s"
                 (peer-label peer) (endpoint-pump-result-status result))))))
    (when (positive? (or (snapshot endpoint "outbound_frames") 0))
      (let ((status
             (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
        (unless (memq status '(drained budget would-block interrupted))
          (fail "~a returned terminal output status ~s"
                (peer-label peer) status))))
    (let ((status (reap-child! (peer-child peer))))
      (when (and status (not (equal? status '(exit . 0))))
        (fail "~a child failed: ~s; log: ~a"
              (peer-label peer) status (child-log-string (peer-child peer)))))))

(define (child-log-string child)
  (unless (file-exists? (child-log-path child))
    (fail "~a child log is absent" (child-label child)))
  (let ((size (stat:size (stat (child-log-path child)))))
    (when (>= size max-child-log-bytes)
      (fail "~a child reached its log limit" (child-label child)))
    (call-with-input-file (child-log-path child) get-string-all)))

(define (peer-finished? peer)
  (and (eq? (peer-phase peer) 'done)
       (equal? (reap-child! (peer-child peer)) '(exit . 0))
       (not (process-group-exists?
             (child-process-group (peer-child peer))))))

(define (release-peer! peer)
  (unless (peer-released? peer)
    (catch #t
      (lambda () (release-session-endpoint! (peer-endpoint peer)))
      (lambda arguments
        (catch #t
          (lambda () (close-session! (peer-endpoint peer)))
          (lambda ignored #f))))
    (close-port-quietly! (peer-donation peer))
    (set-peer-donation! peer #f)
    (terminate-child! (peer-child peer))
    (set-peer-released?! peer #t)))

(define (make-peer host label operation-id child-mode edit-text)
  (call-with-values
      (lambda ()
        (open-session-endpoint!
         (native-book-instance-session-host host) label))
    (lambda (endpoint donation)
      (%make-native-peer label endpoint donation #f 'hello operation-id
                         child-mode edit-text #f #f '() #f #f #f))))

(define (mode-configuration mode edits)
  (cond
   ((string=? mode "save")
    (unless (= (length edits) 2)
      (fail "save mode requires exactly two trusted edit values"))
    (values "normal" "save" edits))
   ((string=? mode "replay")
    (unless (null? edits) (fail "replay mode accepts no state value"))
    (values "normal" "replay" '(#f #f)))
   ((string=? mode "save-loaded")
    (unless (null? edits) (fail "save-loaded mode accepts no state value"))
    (values "normal" "save-loaded" '(#f #f)))
   ((string=? mode "boundary-save")
    (unless (null? edits) (fail "boundary-save accepts no state value"))
    (values "boundary" "boundary-save" '(#f #f)))
   ((string=? mode "boundary-reopen")
    (unless (null? edits) (fail "boundary-reopen accepts no state value"))
    (values "boundary" "save-loaded" '(#f #f)))
   (else (fail "unknown authority phase mode: ~a" mode))))

(define (status-exit-code status)
  (and status (eq? (car status) 'exit) (cdr status)))

(define (peer->json peer)
  (let ((child (peer-child peer))
        (initialize (peer-initialize peer))
        (ready (peer-ready peer)))
    `(("label" . ,(peer-label peer))
      ("pid" . ,(child-pid child))
      ("start_time" . ,(child-start-time child))
      ("process_group" . ,(child-process-group child))
      ("exit_code" . ,(status-exit-code (child-status child)))
      ("session_id" . ,(snapshot (peer-endpoint peer) "session_id"))
      ("surface_handle" . ,(field initialize "surface_handle"))
      ("state_grant_handle" .
       ,(state-ready-message-grant-handle ready))
      ("state_grant_generation" .
       ,(state-ready-message-grant-generation ready))
      ("dispatch_statuses" .
       ,(list->vector
         (map symbol->string (peer-dispatch-statuses peer))))
      ("load_text" . ,(peer-load-text peer))
      ("receipt_text" . ,(peer-receipt-text peer)))))

(define (write-result! path mode peers)
  (let ((temporary (string-append path ".new"))
        (authority-start (read-process-start-time (getpid))))
    (call-with-output-file temporary
      (lambda (port)
        (display
         (scm->json-string
          `(("format" . 1)
            ("mode" . ,mode)
            ("authority_pid" . ,(getpid))
            ("authority_start_time" . ,authority-start)
            ("peers" . ,(list->vector (map peer->json peers))))
          #:unicode #t #:pretty #t)
         port)
        (newline port)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (run-phase root run-directory result-path mode operation-ids edits)
  (unless (= (length operation-ids) 2)
    (fail "phase requires exactly two operation IDs"))
  (call-with-values
      (lambda () (mode-configuration mode edits))
    (lambda (suite child-mode edit-values)
      (let* ((runtime (open-native-book-state-runtime root))
             ;; These trusted identities are fixed in authority source and are
             ;; never argv, environment, or wire fields.
             (guile-host
              (open-native-book-instance-host!
               runtime
               (string-append "native-state-note/" suite "/guile@1")
               "stable-notebook-guile"))
             (python-host
              (open-native-book-instance-host!
               runtime
               (string-append "native-state-note/" suite "/python@1")
               "stable-notebook-python"))
             (guile-peer
              (make-peer guile-host "guile" (car operation-ids)
                         child-mode (car edit-values)))
             (python-peer
              (make-peer python-host "python" (cadr operation-ids)
                         child-mode (cadr edit-values)))
             (peers (list guile-peer python-peer))
             (complete? #f))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            ;; Both endpoints exist before either process starts.  Child-side
            ;; spawn/FD checks therefore prove sibling and SQLite descriptors
            ;; are not inherited.
            (spawn-owned-child! guile-peer 'guile run-directory)
            (spawn-owned-child! python-peer 'python run-directory)
            (let ((deadline (after-seconds deadline-seconds)))
              (let loop ()
                (for-each pump-peer! peers)
                (cond
                 ((every peer-finished? peers) #t)
                 ((>= (now-ticks) deadline)
                  (fail "native phase ~a timed out" mode))
                 (else (usleep loop-sleep-microseconds) (loop)))))
            ;; Preserve result fields before endpoint release invalidates the
            ;; surface.  Children are already reaped; release revokes grants.
            (write-result! result-path mode peers)
            (for-each release-peer! peers)
            (close-native-book-state-runtime! runtime)
            (set! complete? #t)
            (marker "phase ~a complete" mode))
          (lambda ()
            (unless complete?
              (for-each release-peer! peers)
              (catch #t
                (lambda () (close-native-book-state-runtime! runtime))
                (lambda arguments #f)))))))))

(let ((arguments (cdr (command-line))))
  (unless (>= (length arguments) 6)
    (fail
     "usage: native-authority.scm ROOT RUN-DIR RESULT MODE GUILE-OP PYTHON-OP [GUILE-TEXT PYTHON-TEXT]"))
  (let ((root (list-ref arguments 0))
        (run-directory (list-ref arguments 1))
        (result-path (list-ref arguments 2))
        (mode (list-ref arguments 3))
        (operation-ids (list (list-ref arguments 4)
                             (list-ref arguments 5)))
        (edits (drop arguments 6)))
    (run-phase root run-directory result-path mode operation-ids edits)))
