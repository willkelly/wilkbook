;;; Production-shaped trusted Guile join for one KOReader persistent-note
;;; interaction, one fixed book process, and one durable SQLite BookInstance.
(use-modules (book-session)
             (book-state-protocol)
             (book-state-reader-bridge)
             (book-state-session-delegate)
             (private-control)
             (ice-9 ftw)
             (ice-9 match)
             (json)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9)
             (srfi srfi-13))

(define tool-dir (dirname (canonicalize-path (car (command-line)))))
(define control-generation 1)
(define linux-msg-nosignal #x4000)
(define max-log-bytes (* 128 1024))
(define loop-sleep-microseconds 3000)
(define phase-deadline-seconds 25)

(define-record-type <owned-child>
  (%make-owned-child name pid start-time record-path log-path status)
  owned-child?
  (name child-name)
  (pid child-pid)
  (start-time child-start-time)
  (record-path child-record-path)
  (log-path child-log-path)
  (status child-status set-child-status!))

(define-record-type <control-owner>
  (%make-control-owner socket input queue queued-bytes open?)
  control-owner?
  (socket control-socket)
  (input control-input set-control-input!)
  (queue control-queue set-control-queue!)
  (queued-bytes control-queued-bytes set-control-queued-bytes!)
  (open? control-open? set-control-open!))

(define-record-type <world>
  (%make-world endpoint control book reader initialize ready dispatch-statuses
               presentations completions ui-events closing?)
  world?
  (endpoint world-endpoint)
  (control world-control)
  (book world-book)
  (reader world-reader)
  (initialize world-initialize set-world-initialize!)
  (ready world-ready set-world-ready!)
  (dispatch-statuses world-dispatch-statuses set-world-dispatch-statuses!)
  (presentations world-presentations set-world-presentations!)
  (completions world-completions set-world-completions!)
  (ui-events world-ui-events set-world-ui-events!)
  (closing? world-closing? set-world-closing?!))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (marker message . arguments)
  (format #t "BOOK_STATE_READER_JOIN: ~a~%"
          (apply format #f message arguments))
  (force-output))

(define (field object name)
  (let ((entry (and (list? object) (assoc name object))))
    (and entry (cdr entry))))

(define (now-ticks) (get-internal-real-time))
(define (after-seconds seconds)
  (+ (now-ticks) (* seconds internal-time-units-per-second)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

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
               (and fields (>= (length fields) 20) (list-ref fields 19))))
           (lambda arguments #f)))))

(define (await-process-start-time pid)
  (let loop ((attempt 0))
    (let ((value (read-process-start-time pid)))
      (cond
       (value value)
       ((>= attempt 100) (fail "could not record process ~a" pid))
       (else (usleep 1000) (loop (+ attempt 1)))))))

(define (write-process-record! path pid start-time)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port) (format port "~a ~a~%" pid start-time)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (close-unrelated-fds!)
  (for-each
   (lambda (entry)
     (let ((fd (string->number entry 10)))
       (when (and fd (> fd 3))
         (catch 'system-error
           (lambda () (close-fdes fd))
           (lambda arguments #f)))))
   (scandir "/proc/self/fd"
            (lambda (entry)
              (and (not (member entry '("." "..")))
                   (string->number entry 10))))))

(define (assert-child-fds!)
  (let ((unexpected
         (filter-map
          (lambda (entry)
            (let ((fd (string->number entry 10)))
              (and fd (> fd 3)
                   (catch 'system-error
                     (lambda () (fcntl fd F_GETFD) fd)
                     (lambda arguments #f)))))
          (scandir "/proc/self/fd"
                   (lambda (entry)
                     (and (not (member entry '("." "..")))
                          (string->number entry 10)))))))
    (unless (null? unexpected)
      (fail "child retained unrelated descriptors: ~s" unexpected))))

(define (child-exec! name gate-input donation log-path executable arguments
                     environment workdir)
  (close-port-quietly! gate-input)
  (let ((null-input (open-file "/dev/null" "r"))
        (log-output (open-file log-path "w0")))
    (setrlimit 'fsize max-log-bytes max-log-bytes)
    (dup2 (fileno null-input) 0)
    (dup2 (fileno log-output) 1)
    (dup2 (fileno log-output) 2)
    (dup2 (fileno donation) 3)
    ;; dup2(old, old) preserves CLOEXEC, so clear it even when donation was 3.
    (fcntl 3 F_SETFD 0)
    (close-unrelated-fds!)
    (assert-child-fds!)
    (format #t "BOOK_STATE_READER_JOIN_SPAWN: ~a:fd-hygiene:only-stdio-and-donated~%"
            name)
    (force-output)
    (environ environment)
    (chdir workdir)
    (apply execl executable executable arguments)))

(define (spawn-owned-child name record-path log-path donation executable
                           arguments environment workdir)
  (force-output (current-output-port))
  (force-output (current-error-port))
  (let* ((gate (pipe O_CLOEXEC))
         (gate-input (car gate))
         (gate-output (cdr gate))
         (pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (close-port-quietly! gate-output)
          (let ((released (get-u8 gate-input)))
            (if (and (integer? released) (= released 1))
                (catch #t
                  (lambda ()
                    (child-exec! name gate-input donation log-path executable
                                 arguments environment workdir)
                    (primitive-exit 127))
                  (lambda (key . details)
                    (format (current-error-port)
                            "child exec failed: ~s ~s~%" key details)
                    (force-output (current-error-port))
                    (primitive-exit 127)))
                (primitive-exit 126))))
        (begin
          (close-port-quietly! gate-input)
          (let ((published? #f))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let ((start-time (await-process-start-time pid)))
                  (write-process-record! record-path pid start-time)
                  (put-u8 gate-output 1)
                  (force-output gate-output)
                  (close-port-quietly! gate-output)
                  (set! published? #t)
                  (%make-owned-child name pid start-time record-path log-path #f)))
              (lambda ()
                (unless published?
                  (close-port-quietly! gate-output)
                  (catch 'system-error
                    (lambda () (kill pid SIGKILL))
                    (lambda arguments #f))
                  (catch 'system-error
                    (lambda () (waitpid pid))
                    (lambda arguments #f))
                  (when (file-exists? record-path)
                    (delete-file record-path))))))))))

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
          (let ((status (decode-child-status (cdr waited))))
            (unless (and (= (car waited) pid)
                         (equal? status (cons 'stopped SIGSTOP)))
              (fail "book child did not stop before project execution: ~s"
                    status)))))))

(define (spawn-book-child name record-path log-path donation executable
                          arguments environment workdir)
  ;; Guile's SPAWN is the already-accepted native-v2 helper used after a Book
  ;; Session worker exists.  The child-side adapter stops before project code,
  ;; then moves selected stdin to FD 3 and closes unrelated descriptors.
  (let* ((guile (or (search-path (parse-path (getenv "PATH")) "guile")
                    (fail "Guile executable for FD adapter is unavailable")))
         (adapter (string-append tool-dir "/book-fd3-exec.scm"))
         (wrapper-arguments
          (append (list guile "--no-auto-compile" adapter executable)
                  arguments))
         (log-port (open-file log-path "w0"))
         (pid #f)
         (published? #f))
    (chmod log-path #o600)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! pid
              (spawn guile wrapper-arguments
                     #:search-path? #f
                     #:environment environment
                     #:input donation #:output log-port #:error log-port))
        (wait-stopped-child! pid)
        (let ((start-time (read-process-start-time pid)))
          (unless start-time (fail "could not identify stopped book child"))
          (write-process-record! record-path pid start-time)
          (close-port-quietly! log-port)
          (kill pid SIGCONT)
          (set! published? #t)
          (%make-owned-child name pid start-time record-path log-path #f)))
      (lambda ()
        (unless published?
          (close-port-quietly! log-port)
          (when pid
            (catch 'system-error
              (lambda () (kill pid SIGKILL))
              (lambda arguments #f))
            (catch 'system-error
              (lambda () (waitpid pid))
              (lambda arguments #f)))
          (when (file-exists? record-path) (delete-file record-path)))))))

(define (decode-child-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   ((status:stop-sig status) => (lambda (value) (cons 'stopped value)))
   (else (cons 'unknown status))))

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

(define (terminate-child! child)
  (when child
    (reap-child! child)
    (unless (child-status child)
      (when (child-current? child)
        (catch 'system-error
          (lambda () (kill (child-pid child) SIGTERM))
          (lambda arguments #f)))
      (let loop ((attempt 0))
        (cond
         ((reap-child! child) #t)
         ((< attempt 20) (usleep 100000) (loop (+ attempt 1)))
         (else
          (when (child-current? child)
            (catch 'system-error
              (lambda () (kill (child-pid child) SIGKILL))
              (lambda arguments #f)))
          (let kill-loop ((attempt 0))
            (cond
             ((reap-child! child) #t)
             ((< attempt 20) (usleep 100000) (kill-loop (+ attempt 1)))
             (else (fail "could not reap exact child ~a" (child-name child)))))))))
    (when (file-exists? (child-record-path child))
      (delete-file (child-record-path child)))))

(define (child-log-string child)
  (unless (file-exists? (child-log-path child))
    (fail "~a has no bounded log" (child-name child)))
  (let ((size (stat:size (stat (child-log-path child)))))
    (when (>= size max-log-bytes)
      (fail "~a reached its log bound" (child-name child)))
    (call-with-input-file (child-log-path child) get-string-all)))

(define (await-clean-child-exit! child deadline)
  (let loop ()
    (let ((status (reap-child! child)))
      (cond
       ((equal? status '(exit . 0)) #t)
       (status (fail "~a exited with ~s; log:~%~a"
                     (child-name child) status (child-log-string child)))
       ((>= (now-ticks) deadline)
        (fail "timed out waiting for ~a exit" (child-name child)))
       (else (usleep 10000) (loop))))))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(define (bytevector-append left right)
  (let* ((left-length (bytevector-length left))
         (right-length (bytevector-length right))
         (result (make-bytevector (+ left-length right-length))))
    (bytevector-copy! left 0 result 0 left-length)
    (bytevector-copy! right 0 result left-length right-length)
    result))

(define (system-would-block? arguments)
  (memv (system-error-errno arguments) (list EAGAIN EWOULDBLOCK)))

(define (make-control-owner socket)
  (let* ((flags (fcntl socket F_GETFL))
         (result (fcntl socket F_SETFL (logior flags O_NONBLOCK)))
         (effective (fcntl socket F_GETFL)))
    (unless (and (zero? result)
                 (= (logand effective O_NONBLOCK) O_NONBLOCK))
      (fail "private UI control socket did not become nonblocking")))
  (setvbuf socket 'none)
  (%make-control-owner socket (make-bytevector 0) '() 0 #t))

(define (close-control! control)
  (when control
    (when (control-open? control)
      (set-control-open! control #f)
      (set-control-input! control (make-bytevector 0))
      (set-control-queue! control '())
      (set-control-queued-bytes! control 0))
    (let ((socket (control-socket control)))
      (when (and (port? socket) (not (port-closed? socket)))
        (catch 'system-error
          (lambda () (shutdown socket 2))
          (lambda arguments #f))
        (close-port-quietly! socket)))))

(define (queue-command! control kind generation value)
  (unless (control-open? control) (fail "private UI control is closed"))
  (let* ((frame
          (encode-control-line kind generation value reader-command-kinds))
         (queue (control-queue control))
         (frame-length (bytevector-length frame)))
    (when (or (>= (length queue) max-control-queue-frames)
              (> (+ (control-queued-bytes control) frame-length)
                 max-control-queue-bytes))
      (fail "private UI output queue reached its bound"))
    (set-control-queue! control (append queue (list (cons frame 0))))
    (set-control-queued-bytes!
     control (+ (control-queued-bytes control) frame-length))))

(define (pump-control-output! control)
  (when (and (control-open? control) (pair? (control-queue control)))
    (let loop ((bytes 0) (frames 0))
      (when (and (< bytes 4096) (< frames 4)
                 (pair? (control-queue control)))
        (let* ((head (car (control-queue control)))
               (frame (car head))
               (offset (cdr head))
               (end (min (bytevector-length frame) (+ offset (- 4096 bytes))))
               (slice (bytevector-slice frame offset end))
               (sent
                (catch 'system-error
                  (lambda ()
                    (send (control-socket control) slice linux-msg-nosignal))
                  (lambda arguments
                    (cond
                     ((system-would-block? arguments) 'would-block)
                     ((= (system-error-errno arguments) EINTR) 'interrupted)
                     (else (apply throw arguments)))))))
          (cond
           ((memq sent '(would-block interrupted)) #f)
           ((zero? sent) (fail "private UI control write returned zero"))
           (else
            (let ((next (+ offset sent)))
              (set-control-queued-bytes!
               control (- (control-queued-bytes control) sent))
              (if (= next (bytevector-length frame))
                  (begin
                    (set-control-queue! control (cdr (control-queue control)))
                    (loop (+ bytes sent) (+ frames 1)))
                  (begin
                    (set-control-queue!
                     control
                     (cons (cons frame next) (cdr (control-queue control))))
                    (loop (+ bytes sent) frames)))))))))))

(define (newline-index bytes)
  (let ((length (bytevector-length bytes)))
    (let loop ((index 0))
      (and (< index length)
           (if (= (bytevector-u8-ref bytes index) 10)
               index
               (loop (+ index 1)))))))

(define (take-control-event! control)
  (let* ((input (control-input control))
         (newline (newline-index input)))
    (and newline
         (let ((line (bytevector-slice input 0 newline)))
           (set-control-input!
            control
            (bytevector-slice input (+ newline 1) (bytevector-length input)))
           (decode-control-line line reader-event-kinds)))))

(define (pump-control-input! control)
  (or (take-control-event! control)
      (and (control-open? control)
           (let* ((buffer (make-bytevector 4096))
                  (received
                   (catch 'system-error
                     (lambda () (recv! (control-socket control) buffer))
                     (lambda arguments
                       (cond
                        ((system-would-block? arguments) 'would-block)
                        ((= (system-error-errno arguments) EINTR) 'interrupted)
                        (else (apply throw arguments)))))))
             (cond
              ((memq received '(would-block interrupted)) #f)
              ((zero? received)
               (set-control-open! control #f)
               'eof)
              (else
               (let ((input
                      (bytevector-append
                       (control-input control)
                       (bytevector-slice buffer 0 received))))
                 (when (> (bytevector-length input)
                          (+ max-control-line-bytes 4096))
                   (fail "private UI control input reached its bound"))
                 (set-control-input! control input)
                 (let ((event (take-control-event! control)))
                   (when (and (not event)
                              (> (bytevector-length input)
                                 max-control-line-bytes))
                     (fail "private UI control line reached its bound"))
                   event))))))))

(define (queue-ui! world kind value)
  (queue-command! (world-control world) kind control-generation value)
  (pump-control-output! (world-control world)))

(define (plain-initialize? value)
  (and (list? value) (string=? (or (field value "type") "") "initialize")))

(define (handle-session-value! world value)
  (cond
   ((plain-initialize? value)
    (when (world-initialize world) (fail "duplicate initialize value"))
    (set-world-initialize! world value)
    (endpoint-queue-message! (world-endpoint world) value))
   ((state-ready-message? value)
    (when (world-ready world) (fail "duplicate state-ready value"))
    (set-world-ready! world value)
    (endpoint-queue-message! (world-endpoint world) value))
   ((state-delegate-dispatch-result? value)
    (let ((status (state-delegate-dispatch-result-status value)))
      (unless (memq status '(queued cached already-pending))
        (fail "unknown state dispatch status ~s" status))
      (set-world-dispatch-statuses!
       world (append (world-dispatch-statuses world) (list status)))))
   ((presented-text? value)
    (set-world-presentations!
     world (append (world-presentations world) (list value))))
   (else (fail "Book Session returned unknown trusted value ~s" value))))

(define (pump-world! world)
  (pump-control-output! (world-control world))
  (let ((event (pump-control-input! (world-control world))))
    (cond
     ((eq? event 'eof)
      (unless (world-closing? world)
        (fail "KOReader closed its private control early")))
     (event
      (set-world-ui-events!
       world (append (world-ui-events world) (list event))))))
  (let ((events (endpoint-ready-events (world-endpoint world))))
    (when (memq 'input events)
      (let ((result (endpoint-pump-input! (world-endpoint world))))
        (case (endpoint-pump-result-status result)
          ((committed)
           (for-each
            (lambda (value) (handle-session-value! world value))
            (endpoint-pump-result-values result)))
          ((would-block interrupted budget) #t)
          ((eof closed stale)
           (unless (world-closing? world)
             (fail "book endpoint closed before lifecycle cleanup")))
          (else (fail "unknown input pump status ~s"
                      (endpoint-pump-result-status result))))))
    (when (memq 'output events)
      (let ((result (endpoint-pump-output! (world-endpoint world))))
        (unless (memq (endpoint-pump-result-status result)
                      '(drained budget would-block interrupted closed stale))
          (fail "unknown output pump status ~s"
                (endpoint-pump-result-status result))))))
  (let ((completion
         (endpoint-take-state-completion! (world-endpoint world))))
    (when completion
      (set-world-completions!
       world (append (world-completions world) (list completion)))))
  (unless (world-closing? world)
    (when (reap-child! (world-reader world))
      (fail "KOReader exited before cleanup: ~s; log:~%~a"
            (child-status (world-reader world))
            (child-log-string (world-reader world))))
    (when (reap-child! (world-book world))
      (fail "book exited before endpoint cleanup: ~s; log:~%~a"
            (child-status (world-book world))
            (child-log-string (world-book world)))))
  (usleep loop-sleep-microseconds))

(define (await! world predicate label)
  (let ((deadline (after-seconds phase-deadline-seconds)))
    (let loop ()
      (let ((value (predicate)))
        (cond
         (value value)
         ((>= (now-ticks) deadline) (fail "timed out waiting for ~a" label))
         (else (pump-world! world) (loop)))))))

(define (pop-ui-event! world)
  (let ((values (world-ui-events world)))
    (and (pair? values)
         (begin
           (set-world-ui-events! world (cdr values))
           (car values)))))

(define (expect-ui! world kind value)
  (let ((event
         (await! world (lambda () (pop-ui-event! world))
                 (format #f "UI ~a" kind))))
    (unless (equal? event (list kind control-generation value))
      (fail "expected UI event ~s, received ~s"
            (list kind control-generation value) event))
    event))

(define (pop-completion! world)
  (let ((values (world-completions world)))
    (and (pair? values)
         (begin
           (set-world-completions! world (cdr values))
           (car values)))))

(define (pop-presentation! world)
  (let ((values (world-presentations world)))
    (and (pair? values)
         (begin
           (set-world-presentations! world (cdr values))
           (car values)))))

(define (require-private-path path type mode)
  (unless (and (string-prefix? "/" path)
               (string=? path (canonicalize-path path)))
    (fail "path is not absolute and canonical: ~a" path))
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) type)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) mode))
      (fail "path has wrong owner/type/mode: ~a" path)))
  path)

(define (read-script-input path plan-kind)
  (if (string=? plan-kind "load")
      (begin
        (unless (string=? path "-")
          (fail "non-editing plan accepts no scripted value path"))
        #f)
      (begin
        (require-private-path path 'regular #o600)
        (let ((text
               (call-with-input-file path
                 (lambda (port)
                   ;; The test plan is ordinary UI UTF-8, independent of the
                   ;; host locale available to this bounded Guix shell.
                   (set-port-encoding! port "UTF-8")
                   (get-string-all port)))))
          (when (or (string-index text #\nul)
                     (> (bytevector-length (string->utf8 text))
                        max-state-text-bytes))
            (fail "scripted UI text is outside the joined UI/action bound"))
          text))))

(define (profile-config profile)
  ;; Language to namespace identity is fixed here.  Neither book nor UI can
  ;; provide book revision, instance ID, access, or fixture selection.
  (cond
   ((string=? profile "guile-note")
    '(guile "reader-note/guile@1" "persistent-note-guile" normal normal))
   ((string=? profile "python-note")
    '(python "reader-note/python@1" "persistent-note-python" normal normal))
   ((string=? profile "guile-empty")
    '(guile "reader-note/empty@1" "persistent-note-empty" normal normal))
    ((string=? profile "guile-read-only")
     '(guile "reader-note/read-only-test@1" "persistent-note-read-only" read-only-test normal))
    ((string=? profile "guile-read-only-seed")
     '(guile "reader-note/read-only-test@1" "persistent-note-read-only" normal normal))
    ((string=? profile "guile-max-text")
     '(guile "reader-note/max-text@1" "persistent-note-max-text" normal normal))
    ((string=? profile "guile-retry")
     '(guile "reader-note/retry@1" "persistent-note-retry" normal normal))
   ((string=? profile "guile-delayed-edit")
    '(guile "reader-note/delayed-edit@1" "persistent-note-delayed-edit" normal normal))
   ((string=? profile "guile-forged-present")
    '(guile "reader-note/forged-present@1" "persistent-note-forged-present" normal forged-present))
   ((string=? profile "guile-mismatched-commit")
    '(guile "reader-note/mismatched-commit@1" "persistent-note-mismatched-commit" normal mismatched-commit))
   ((string=? profile "guile-mismatched-recover")
    '(guile "reader-note/mismatched-commit@1" "persistent-note-mismatched-commit" normal normal))
   (else (fail "unknown fixed reader/book profile: ~a" profile))))

(define (required-environment name)
  (or (getenv name) (fail "trusted runner did not set ~a" name)))

(define (book-command language variant)
  (case language
    ((guile)
     (let ((guile (or (search-path (parse-path (getenv "PATH")) "guile")
                      (fail "Guile executable is unavailable"))))
       (list guile
             (list "--no-auto-compile"
                   (string-append
                    tool-dir "/"
                    (case variant
                      ((normal) "joined-note-book.scm")
                      ((forged-present) "forged-present-book.scm")
                      ((mismatched-commit) "mismatched-commit-book.scm")
                      (else (fail "unknown fixed Guile book variant ~s"
                                  variant))))))))
    ((python)
     (unless (eq? variant 'normal)
       (fail "Python profile selected an adversarial Guile fixture"))
     (let ((python (or (search-path (parse-path (getenv "PATH")) "python3")
                       (fail "Python executable is unavailable"))))
       (list python
             (list "-I" "-S"
                   (string-append tool-dir "/python-book-launcher.py")
                   (required-environment "BOOK_JOIN_PYTHON_CODEC")
                   (string-append tool-dir "/joined_note_book.py")))))
    (else (fail "unsupported book language ~s" language))))

(define (book-environment language)
  (append
   '("BOOK_SESSION_FD=3" "HOME=/nonexistent" "LANG=C.UTF-8"
     "LC_ALL=C.UTF-8" "PATH=/nonexistent")
   (case language
     ((guile)
      (list "GUILE_AUTO_COMPILE=0"
            (string-append
             "GUILE_LOAD_PATH="
             (required-environment "BOOK_JOIN_BOOK_GUILE_LOAD_PATH"))
            (string-append
             "GUILE_LOAD_COMPILED_PATH="
             (required-environment "BOOK_JOIN_BOOK_GUILE_COMPILED_PATH"))))
     ((python) '("PYTHONDONTWRITEBYTECODE=1" "PYTHONUTF8=1"))
     (else '()))))

(define (reader-environment run-dir)
  (list
   (string-append "PATH=" (or (getenv "PATH") ""))
   "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
   (string-append "HOME=" run-dir "/home")
   (string-append "KO_HOME=" run-dir "/ko")
   (string-append "XDG_CONFIG_HOME=" run-dir "/home/.config")
   (string-append "XDG_CACHE_HOME=" run-dir "/home/.cache")
   (string-append "XDG_DATA_HOME=" run-dir "/home/.local/share")
   (string-append "TMPDIR=" run-dir "/tmp")
   (string-append "BOOK_STATE_READER_ROOT=" run-dir)
   "BOOK_STATE_READER_TRUSTED_FIXTURE=1"
   "BOOK_STATE_READER_CONTROL_FD=3"
   "BOOK_STATE_READER_MODE=automated"
   "SDL_VIDEODRIVER=offscreen" "SDL_AUDIODRIVER=dummy"))

(define (action->identity action)
  `(("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))))

(define (completion->identity completion)
  (let ((response (book-state-completion-response completion)))
    `(("session_id" . ,(book-state-completion-session-id completion))
      ("surface_generation" .
       ,(book-state-completion-surface-generation completion))
      ("grant_generation" .
       ,(book-state-completion-grant-generation completion))
      ("operation_kind" .
       ,(symbol->string (book-state-completion-operation-kind completion)))
      ("operation_id" . ,(or (book-state-completion-operation-id completion)
                              #f))
      ("expected_state_version" .
       ,(or (book-state-completion-expected-state-version completion) #f))
      ("text" . ,(or (book-state-completion-text completion) #f))
       ("response_type" .
        ,(cond
         ((state-value-message? response) "state-value")
         ((state-committed-message? response) "state-committed")
         ((state-conflict-message? response) "state-conflict")
         ((state-commit-failed-message? response) "state-commit-failed")
          (else "unknown")))
      ("resulting_state_version" .
       ,(and (state-committed-message? response)
             (state-committed-message-state-version response)))
      ("result_text_bytes" .
       ,(and (state-committed-message? response)
             (state-committed-message-text-bytes response)))
      ("current_state_version" .
       ,(and (state-conflict-message? response)
             (state-conflict-message-current-state-version response)))
      ("failure_code" .
       ,(and (state-commit-failed-message? response)
             (symbol->string
              (state-commit-failed-message-code response)))))))

(define (validate-presentation! presentation action text)
  (unless (and (presented-text? presentation)
               (string=? (presented-text-session-id presentation)
                         (field action "session_id"))
               (string=? (presented-text-request-id presentation)
                         (field action "request_id"))
               (string=? (presented-text-action-id presentation)
                         (field action "action_id"))
               (string=? (presented-text-surface-handle presentation)
                         (field action "surface_handle"))
               (= (presented-text-surface-generation presentation)
                  (field action "surface_generation"))
               (= (presented-text-sequence presentation)
                  (field action "sequence"))
               (string=? (presented-text-value presentation) text))
    (fail "book presentation does not match exact post-receipt action")))

(define (begin-ui-save! world load-owner surface-handle state-version text
                        action-id)
  (queue-ui! world 'save "")
  (expect-ui! world 'submit text)
  (expect-ui! world 'status "pending")
  (let* ((action (host-action! (world-endpoint world) action-id text))
         (pending
          (make-reader-pending-save
           control-generation text state-version load-owner surface-handle action)))
    (endpoint-queue-message! (world-endpoint world) action)
    (values pending action)))

(define (run-save-attempt! world load-owner surface-handle state-version text
                           action-id)
  (call-with-values
      (lambda ()
        (begin-ui-save!
         world load-owner surface-handle state-version text action-id))
    (lambda (pending action)
      (let* ((completion
              (await! world (lambda () (pop-completion! world))
                      "typed save completion"))
             (decision (reader-save-completion->decision completion pending)))
        (values decision action completion)))))

(define (wait-for-dispatch-count! world wanted)
  (await! world
          (lambda ()
            (and (>= (length (world-dispatch-statuses world)) wanted)
                 (length (world-dispatch-statuses world))))
          (format #f "~a state dispatches" wanted)))

(define (write-result! path profile plan-kind world load-value action
                        completion retry-action retry-completion decision
                        presentation-action saved?)
  (let* ((book (world-book world))
         (reader (world-reader world))
         (initialize (world-initialize world))
         (ready (world-ready world))
         (temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port)
        (display
         (scm->json-string
          `(("format" . 2)
            ("profile" . ,profile)
            ("plan" . ,plan-kind)
            ("authority" .
             (("pid" . ,(getpid))
              ("start_time" . ,(read-process-start-time (getpid)))))
            ("book" .
             (("pid" . ,(child-pid book))
              ("start_time" . ,(child-start-time book))
              ("exit_code" . ,(and (child-status book)
                                    (eq? (car (child-status book)) 'exit)
                                    (cdr (child-status book))))))
            ("reader" .
             (("pid" . ,(child-pid reader))
              ("start_time" . ,(child-start-time reader))
              ("exit_code" . ,(and (child-status reader)
                                    (eq? (car (child-status reader)) 'exit)
                                    (cdr (child-status reader))))))
            ("session_id" . ,(field (host-session-snapshot
                                      (world-endpoint world)) "session_id"))
            ("surface_handle" . ,(field initialize "surface_handle"))
            ("surface_generation" . ,(field initialize "surface_generation"))
            ("grant_generation" .
             ,(state-ready-message-grant-generation ready))
            ("grant_handle" . ,(state-ready-message-grant-handle ready))
            ("grant_access" .
             ,(symbol->string (state-ready-message-access ready)))
            ("load" .
             (("present" . ,(eq? (car load-value) 'value))
              ("state_version" . ,(cadr load-value))
              ("text" . ,(caddr load-value))
              ("ui_applied_text" . ,(caddr load-value))))
            ("save_action" . ,(if action (action->identity action) #f))
            ("save_completion" .
             ,(if completion (completion->identity completion) #f))
            ("retry_action" .
             ,(if retry-action (action->identity retry-action) #f))
            ("retry_completion" .
             ,(if retry-completion
                  (completion->identity retry-completion) #f))
            ("save_decision" .
             ,(if decision
                  (list->vector
                   (map (lambda (value)
                          (if (symbol? value) (symbol->string value) value))
                        decision))
                  #()))
            ("presentation_action" .
             ,(if presentation-action
                  (action->identity presentation-action) #f))
            ("ui_saved" . ,saved?)
            ("ui_saved_text" . ,(if saved?
                                      (list-ref decision 3) #f))
            ("dispatch_statuses" .
             ,(list->vector
               (map symbol->string (world-dispatch-statuses world))))
            ("cleanup" . "endpoint-revoked-before-ui-finish"))
          #:unicode #t #:pretty #t)
         port)
        (newline port)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (run-lifecycle root run-dir result-path profile plan-kind input-path
                       koreader-dir book-document)
  (require-private-path root 'directory #o700)
  (require-private-path run-dir 'directory #o700)
  (let* ((config (profile-config profile))
         (language (list-ref config 0))
         (book-revision (list-ref config 1))
         (instance-id (list-ref config 2))
         (access-mode (list-ref config 3))
         (book-variant (list-ref config 4))
         (text (read-script-input input-path plan-kind))
         (runtime (open-reader-state-runtime root))
         (book-host
          (if (eq? access-mode 'read-only-test)
              (open-reader-book-host-for-read-only-observer-test!
               runtime book-revision instance-id)
              (open-reader-book-host!
               runtime book-revision instance-id 'read-write)))
         (host (reader-book-session-host book-host))
         (endpoint #f)
         (book-peer #f)
         (control #f)
         (reader-peer #f)
         (book-child #f)
         (reader-child #f)
         (world #f)
         (load-value #f)
          (save-action #f)
          (save-completion #f)
          (retry-action #f)
          (retry-completion #f)
          (save-decision #f)
         (presentation-action #f)
         (saved? #f)
         (completed? #f))
    (define (cleanup!)
      (when world (set-world-closing?! world #t))
      (when endpoint
        (catch #t
          (lambda () (release-session-endpoint! endpoint))
          (lambda arguments
            (catch #t
              (lambda () (close-session! endpoint))
              (lambda ignored #f)))))
      (close-control! control)
      (close-port-quietly! book-peer)
      (close-port-quietly! reader-peer)
      (terminate-child! book-child)
      (terminate-child! reader-child)
      (catch #t
        (lambda () (close-reader-state-runtime! runtime))
        (lambda arguments #f))
      (unless completed?
        (when book-child
          (format (current-error-port) "--- bounded book log ---~%~a"
                  (child-log-string book-child)))
        (when reader-child
          (format (current-error-port) "--- bounded KOReader log ---~%~a"
                  (child-log-string reader-child)))
        (force-output (current-error-port))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; KOReader is started before opening the state endpoint.  This keeps
        ;; the fork+exec UI helper outside the lifetime of the delegate worker;
        ;; the later book uses Guile's accepted SPAWN path instead of forking a
        ;; multithreaded authority.
        (let ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
          (set! control (make-control-owner (car pair)))
          (set! reader-peer (cdr pair)))
        (let ((luajit (string-append koreader-dir "/luajit")))
          (set! reader-child
                (spawn-owned-child
                 "koreader" (string-append run-dir "/reader.pid")
                 (string-append run-dir "/reader.log") reader-peer
                 luajit (list "reader.lua" book-document)
                 (reader-environment run-dir) koreader-dir)))
        (close-port-quietly! reader-peer)
        (set! reader-peer #f)
        (call-with-values
            (lambda () (open-session-endpoint! host profile))
          (lambda (new-endpoint new-peer)
            (set! endpoint new-endpoint)
            (set! book-peer new-peer)))
        (let* ((command (book-command language book-variant))
               (executable (car command))
               (arguments (cadr command)))
          (set! book-child
                (spawn-book-child
                 "book" (string-append run-dir "/book.pid")
                 (string-append run-dir "/book.log") book-peer
                 executable arguments (book-environment language) tool-dir)))
        (close-port-quietly! book-peer)
        (set! book-peer #f)
        (set! world
              (%make-world endpoint control book-child reader-child #f #f
                           '() '() '() '() #f))

        ;; UI and book start independently.  The first load command is created
        ;; only from the endpoint-owned typed read completion.
        (expect-ui! world 'channel-ready "")
        (queue-ui! world 'open "")
        (expect-ui! world 'ready "")
        (await! world (lambda () (and (world-initialize world)
                                     (world-ready world)))
                "book initialize/state-ready")
        (let* ((snapshot (host-session-snapshot endpoint))
               (load-owner
                (make-reader-load-owner
                 (field snapshot "session_id")
                 (field snapshot "surface_generation")
                 (state-ready-message-grant-generation (world-ready world))))
               (read-completion
                (await! world (lambda () (pop-completion! world))
                        "typed state read")))
          (set! load-value
                (reader-load-completion->value read-completion load-owner))
          (wait-for-dispatch-count! world 1)
          (queue-ui! world
                     (if (eq? (car load-value) 'value)
                         'load-value 'load-absent)
                     (caddr load-value))
          (expect-ui! world 'status
                      (if (eq? (car load-value) 'value)
                          "loaded-value" "loaded-absent"))
          (expect-ui! world 'applied (caddr load-value))
          (marker "load-observer->ui:present=~a:version=~a:text-bytes=~a"
                  (eq? (car load-value) 'value) (cadr load-value)
                  (bytevector-length (string->utf8 (caddr load-value))))

          (cond
           ((string=? plan-kind "load")
            (unless (not text) (fail "load plan unexpectedly has input")))
           ((member plan-kind
                     '("save" "retry-same-operation" "read-only-failure"
                       "delayed-edit"
                       "forged-present" "mismatched-commit")
                     string=?)
            (unless text (fail "editing plan lacks scripted operator text"))
            (queue-ui! world 'edit text)
            (expect-ui! world 'status "dirty")
            (cond
             ((string=? plan-kind "forged-present")
              (unless (eq? book-variant 'forged-present)
                (fail "forged presentation plan has the wrong fixed book"))
              (call-with-values
                  (lambda ()
                    (begin-ui-save!
                     world load-owner (field (world-initialize world)
                                              "surface_handle")
                     (cadr load-value) text "save-note"))
                (lambda (pending action)
                  (set! save-action action)))
              (let* ((presentation
                      (await! world (lambda () (pop-presentation! world))
                              "forged early presentation"))
                     (comparison
                      (cons (cons "session_id" (field snapshot "session_id"))
                            save-action)))
                (validate-presentation! presentation comparison text)
                ;; Presentation is a surface fact only.  It is deliberately not
                ;; forwarded to the pending UI and creates no observer receipt.
                (do ((attempt 0 (+ attempt 1))) ((= attempt 20))
                  (pump-world! world))
                (unless (null? (world-completions world))
                  (fail "forged present created a storage completion"))
                (set! save-decision
                      (list 'rejected-forged-present #f #f text))
                (marker "forged-book-present:rejected-as-save-evidence")))
             ((string=? plan-kind "mismatched-commit")
              (unless (eq? book-variant 'mismatched-commit)
                (fail "mismatched completion plan has the wrong fixed book"))
              (call-with-values
                  (lambda ()
                    (begin-ui-save!
                     world load-owner (field (world-initialize world)
                                              "surface_handle")
                     (cadr load-value) text "save-note"))
                (lambda (pending action)
                  (set! save-action action)
                  (set! save-completion
                        (await! world (lambda () (pop-completion! world))
                                "mismatched typed completion"))
                  (let ((rejected?
                         (catch 'book-state-reader-bridge-error
                           (lambda ()
                             (reader-save-completion->decision
                              save-completion pending)
                             #f)
                           (lambda arguments #t))))
                    (unless rejected?
                      (fail "mismatched book commit authorized UI success")))))
              (wait-for-dispatch-count! world 2)
              (set! save-decision
                    (list 'rejected-mismatched-completion
                          (book-state-completion-operation-id save-completion)
                          (state-committed-message-state-version
                           (book-state-completion-response save-completion))
                          (book-state-completion-text save-completion)))
              (marker "mismatched-book-commit:durable-but-no-ui-commit-ok"))
             (else
              (call-with-values
                  (lambda ()
                    (run-save-attempt!
                     world load-owner (field (world-initialize world)
                                              "surface_handle")
                     (cadr load-value) text
                     (if (string=? plan-kind "retry-same-operation")
                         "retry-save-note" "save-note")))
                (lambda (decision action completion)
                  (set! save-decision decision)
                  (set! save-action action)
                  (set! save-completion completion)))
               (if (string=? plan-kind "retry-same-operation")
                   (begin
                     (set! retry-completion
                           (await! world (lambda () (pop-completion! world))
                                   "same-operation retry completion"))
                     (let ((retry-decision
                            (reader-save-completion->decision
                             retry-completion
                             (make-reader-pending-save
                              control-generation text (cadr load-value)
                              load-owner
                              (field (world-initialize world) "surface_handle")
                              save-action))))
                       (unless (equal? retry-decision save-decision)
                         (fail "same-operation retry changed typed receipt")))
                     (wait-for-dispatch-count! world 3)
                     (marker "same-operation-retry:original-receipt-returned"))
                   (wait-for-dispatch-count! world 2))
              (case (car save-decision)
                ((committed)
                 (cond
                   ((member plan-kind '("save" "retry-same-operation") string=?)
                   (queue-ui! world 'commit-ok text)
                   (expect-ui! world 'status "saved")
                   (set! saved? #t)
                   (marker
                    "typed-receipt->ui-commit-ok:version=~a:text-bytes=~a"
                    (list-ref save-decision 2)
                    (bytevector-length (string->utf8 text)))
                   ;; No book presentation exists yet.  Saved was painted solely
                   ;; from the correlated observer receipt.
                   (unless (null? (world-presentations world))
                     (fail "book presentation preceded UI commit confirmation"))
                   (set! presentation-action
                         (host-action! endpoint "present-saved" text))
                   (let ((comparison
                          (cons (cons "session_id"
                                      (field snapshot "session_id"))
                                presentation-action)))
                     (endpoint-queue-message! endpoint presentation-action)
                     (let ((presentation
                            (await! world
                                    (lambda () (pop-presentation! world))
                                    "separate book presentation")))
                       (validate-presentation! presentation comparison text)
                       (queue-ui! world 'present text)
                       (expect-ui! world 'applied text)
                       (marker
                        "book-present->ui-paint:separate-after-commit"))))
                  ((string=? plan-kind "delayed-edit")
                   ;; The installed join-only operator plugin edits the actual
                   ;; InputDialog while this receipt is deliberately withheld.
                   ;; The accepted UI must consume the old matching receipt yet
                   ;; remain Dirty for the newer widget text.
                   (do ((attempt 0 (+ attempt 1))) ((= attempt 100))
                     (pump-world! world))
                   (queue-ui! world 'commit-ok text)
                   (expect-ui! world 'status "dirty")
                   (marker
                    "delayed-matching-receipt:newer-widget-draft-not-saved"))
                   (else (fail "failure plan unexpectedly committed"))))
                ((failed)
                 (unless (string=? plan-kind "read-only-failure")
                   (fail "ordinary save unexpectedly failed"))
                 (unless (eq? (list-ref save-decision 2) 'read-only)
                   (fail "read-only test returned ~s" save-decision))
                 (queue-ui! world 'commit-failed "read-only")
                 (expect-ui! world 'status "failed")
                 ;; No edit intervenes.  A second real Save callback must submit
                 ;; the exact retained draft and receive a second actual backend
                 ;; read-only rejection through the observer.
                 (call-with-values
                     (lambda ()
                       (run-save-attempt!
                         world load-owner (field (world-initialize world)
                                                 "surface_handle")
                         (cadr load-value) text "save-note"))
                    (lambda (second-decision second-action second-completion)
                      (unless (and (eq? (car second-decision) 'failed)
                                   (eq? (list-ref second-decision 2) 'read-only)
                                   (string=? (list-ref second-decision 3) text)
                                   (not (string=?
                                         (list-ref second-decision 1)
                                         (list-ref save-decision 1))))
                        (fail
                         "retained-draft retry was not a fresh exact failure"))
                      (set! retry-action second-action)
                      (set! retry-completion second-completion)))
                 (wait-for-dispatch-count! world 3)
                 (queue-ui! world 'commit-failed "read-only")
                 (expect-ui! world 'status "failed")
                 (marker
                  "read-only-backend-failure:draft-retained-and-resubmitted"))
                (else (fail "unexpected save decision ~s" save-decision)))
             )))
           (else (fail "unknown lifecycle plan ~a" plan-kind))))

        ;; The exact endpoint/grant is revoked before this UI process confirms
        ;; finish.  A later authority may reuse UI generation 1, but cannot
        ;; receive any event from this endpoint lifetime.
        (if (member plan-kind
                    '("read-only-failure" "delayed-edit" "forged-present"
                      "mismatched-commit") string=?)
            (begin
              (queue-ui! world 'navigate "")
              (expect-ui! world 'navigated ""))
            (begin
              (queue-ui! world 'close "")
              (expect-ui! world 'closed "")))
        (set-world-closing?! world #t)
        (release-session-endpoint! endpoint)
        (await-clean-child-exit! book-child (after-seconds 3))
        (queue-ui! world 'finish "")
        (expect-ui! world 'done "ok")
        (await-clean-child-exit! reader-child (after-seconds 5))
        (unless (not (endpoint-take-state-completion! endpoint))
          (fail "released endpoint retained a late completion"))
        (close-reader-state-runtime! runtime)
        (write-result! result-path profile plan-kind world load-value save-action
                       save-completion retry-action retry-completion save-decision
                       presentation-action saved?)
        (set! completed? #t)
        (marker "result:ok"))
      (lambda () (cleanup!)))))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 8)
    (fail "usage: reader-join-authority.scm ROOT RUN-DIR RESULT PROFILE PLAN INPUT|- KOREADER-DIR BOOK"))
  (apply run-lifecycle arguments))
