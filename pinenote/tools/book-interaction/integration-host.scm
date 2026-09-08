;;; Trusted host-only vertical fixture: Book Session + book peer + KOReader UI.
(use-modules (book-session)
             (private-control)
             (ice-9 ftw)
             (ice-9 match)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9))

(define control-generation 1)
(define linux-msg-nosignal #x4000)
(define max-retained-log-bytes (* 128 1024))
(define loop-sleep-microseconds 5000)
(define fixture-deadline-seconds 15)
(define fixture-tool-dir
  (dirname (canonicalize-path (car (command-line)))))

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

(define (marker text)
  (format #t "BOOK_INTERACTION_HOST: ~a~%" text)
  (force-output))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (system-would-block? arguments)
  (memv (system-error-errno arguments) (list EAGAIN EWOULDBLOCK)))

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

(define (now-ticks)
  (get-internal-real-time))

(define (seconds->ticks seconds)
  (* seconds internal-time-units-per-second))

(define (after-seconds seconds)
  (+ (now-ticks) (seconds->ticks seconds)))

(define (snapshot endpoint name)
  (let ((entry (assoc name (host-session-snapshot endpoint))))
    (and entry (cdr entry))))

(define (read-process-start-time pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((stat (call-with-input-file path get-string-all))
                    (close (string-rindex stat #\)))
                    (fields
                     (and close
                          (string-tokenize
                           (substring stat (+ close 2))))))
               ;; The suffix begins at field 3; start time is field 22.
               (and fields (>= (length fields) 20) (list-ref fields 19))))
           (lambda arguments #f)))))

(define (await-process-start-time pid)
  (let loop ((attempt 0))
    (let ((start (read-process-start-time pid)))
      (cond
       (start start)
       ((>= attempt 100) (fail "could not identify child process ~a" pid))
       (else (usleep 1000) (loop (+ attempt 1)))))))

(define (write-process-record! path pid start-time)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port) (format port "~a ~a~%" pid start-time)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (close-unrelated-fds!)
  ;; SCANDIR closes its own directory descriptor before this returned list is
  ;; consumed. The exec child retains only stdin/out/err and donated FD 3.
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

(define (assert-sanitized-child-fds!)
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
      (error "exec child retained unrelated descriptors" unexpected))))

(define (child-exec! name gate-input donation log-path executable arguments
                     environment workdir)
  (close-port-quietly! gate-input)
  ;; This procedure is entered only after the gate byte has already been read;
  ;; its parameter remains solely to make ownership explicit at the call site.
  (let ((null-input (open-file "/dev/null" "r"))
        (log-output (open-file log-path "w0")))
    (setrlimit 'fsize max-retained-log-bytes max-retained-log-bytes)
    (dup2 (fileno null-input) 0)
    (dup2 (fileno log-output) 1)
    (dup2 (fileno log-output) 2)
    (dup2 (fileno donation) 3)
    (close-unrelated-fds!)
    (assert-sanitized-child-fds!)
    (format #t "BOOK_INTERACTION_SPAWN: ~a:fd-hygiene:only-stdio-and-donated~%"
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
                  ;; No unrecorded child executes repository fixture code.
                  (put-u8 gate-output 1)
                  (force-output gate-output)
                  (close-port-quietly! gate-output)
                  (set! published? #t)
                  (%make-owned-child name pid start-time record-path log-path
                                     #f)))
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

(define (decode-child-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
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
  (let ((start (read-process-start-time (child-pid child))))
    (and start (string=? start (child-start-time child)))))

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
          (let kill-loop ((kill-attempt 0))
            (cond
             ((reap-child! child) #t)
             ((< kill-attempt 20)
              (usleep 100000)
              (kill-loop (+ kill-attempt 1)))
             (else (fail "could not reap exact ~a child" (child-name child)))))))))
    (when (file-exists? (child-record-path child))
      (delete-file (child-record-path child)))))

(define (child-exited-zero? child)
  (equal? (reap-child! child) '(exit . 0)))

(define (child-log-string child)
  (unless (file-exists? (child-log-path child))
    (fail "~a did not create its bounded log" (child-name child)))
  (let ((size (stat:size (stat (child-log-path child)))))
    (when (>= size max-retained-log-bytes)
      (fail "~a reached its ~a-byte log limit"
            (child-name child) max-retained-log-bytes))
    (call-with-input-file (child-log-path child) get-string-all)))

(define (make-control-owner socket)
  (let* ((flags (fcntl socket F_GETFL))
         (result (fcntl socket F_SETFL (logior flags O_NONBLOCK)))
         (effective (fcntl socket F_GETFL)))
    (unless (and (zero? result)
                 (= (logand effective O_NONBLOCK) O_NONBLOCK))
      (fail "Guile private control socket did not become nonblocking")))
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

(define (queue-control! control kind value)
  (unless (control-open? control)
    (fail "private control channel is closed"))
  (let* ((frame
         (encode-control-line kind control-generation value
                               reader-command-kinds))
         (queue (control-queue control))
         (frame-length (bytevector-length frame)))
    (when (or (>= (length queue) max-control-queue-frames)
              (> (+ (control-queued-bytes control) frame-length)
                 max-control-queue-bytes))
      (fail "private control output queue reached its bound"))
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
                  (lambda () (send (control-socket control) slice
                                   linux-msg-nosignal))
                  (lambda arguments
                    (cond
                     ((system-would-block? arguments) 'would-block)
                     ((= (system-error-errno arguments) EINTR) 'interrupted)
                     (else (apply throw arguments)))))))
          (cond
           ((memq sent '(would-block interrupted)) #f)
           ((zero? sent) (fail "private control write returned zero"))
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
  ;; Return at most one complete private event per scheduler turn.
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
                   (fail "private control input buffer reached its bound"))
                 (set-control-input! control input)
                 (let ((event (take-control-event! control)))
                   (when (and (not event)
                              (> (bytevector-length input)
                                 max-control-line-bytes))
                     (fail "private control line reached its bound"))
                   event))))))))

(define (queue-session-message! endpoint message)
  (endpoint-queue-message! endpoint message))

(define (pump-session-output! endpoint)
  (when (> (snapshot endpoint "outbound_frames") 0)
    (when (memq 'output (endpoint-ready-events endpoint))
      (endpoint-pump-output! endpoint))))

(define (count-exact-line text expected)
  (count (lambda (line) (string=? line expected)) (string-split text #\newline)))

(define (require-log-line-once child text)
  (unless (= (count-exact-line (child-log-string child) text) 1)
    (fail "~a log did not contain exactly one ~s" (child-name child) text)))

(define (validate-final-logs! reader peer expected-revision expected-result)
  (let ((reader-log (child-log-string reader))
        (peer-log (child-log-string peer)))
    (when (or (string-contains reader-log "BOOK_INTERACTION_READER: FAIL:")
              (string-contains peer-log "BOOK_INTERACTION_PEER: FAIL:")
              (string-contains reader-log "Saving failed."))
      (fail "a fixture child reported failure"))
    (require-log-line-once
     reader (string-append " [*] Version: " expected-revision))
    (require-log-line-once
     reader
     "BOOK_INTERACTION_SPAWN: koreader:fd-hygiene:only-stdio-and-donated")
    (require-log-line-once
     peer
     "BOOK_INTERACTION_SPAWN: book-peer:fd-hygiene:only-stdio-and-donated")
    (for-each
     (lambda (line) (require-log-line-once reader line))
      '("BOOK_INTERACTION_READER: plugin-init:trusted-native-fixture"
        "BOOK_INTERACTION_READER: dialog-shown"
        "BOOK_INTERACTION_READER: dialog-topmost"
        "BOOK_INTERACTION_READER: private-source-registered"
        "BOOK_INTERACTION_READER: ui-wait-task:navigation:topmost-during-delay"
        "BOOK_INTERACTION_READER: ui-wait-task:close:topmost-during-delay"
        "BOOK_INTERACTION_READER: stale-navigation:dialog-preserved"
        "BOOK_INTERACTION_READER: close:dialog-responsive-and-preserved"
        "BOOK_INTERACTION_READER: cleanup-audit:before-quit"
        "BOOK_INTERACTION_READER: cleanup-audit:dialog-source-channel-fd-callback:clean"
        "BOOK_INTERACTION_UI_AUDIT: cleanup:dialog-source-counts-closed-fd-no-callback:ok"
        "BOOK_INTERACTION_READER: result:ok"))
    (require-log-line-once
     reader (string-append "BOOK_INTERACTION_READER: present-painted-exact:"
                           expected-result))
    (require-log-line-once
     reader (string-append "BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:"
                           expected-result))
    (for-each
     (lambda (line) (require-log-line-once peer line))
     '("BOOK_INTERACTION_PEER: initialize:accepted"
       "BOOK_INTERACTION_PEER: update:presented"
       "BOOK_INTERACTION_PEER: navigation:late-present-attempted"
       "BOOK_INTERACTION_PEER: close:late-present-rejected"
       "BOOK_INTERACTION_PEER: result:ok"))))

(define (run-fixture run-dir koreader-dir luajit book peer-label
                     guile python expected-revision update-input
                     expected-result)
  (let* ((tool-dir fixture-tool-dir)
         (expected-book
          (canonicalize-path (string-append run-dir "/fixture-book.txt")))
         (protocol-dir
          (canonicalize-path (string-append tool-dir "/../book-protocol")))
         (peer-source
          (canonicalize-path
           (string-append tool-dir
                          (if (string=? peer-label "guile")
                              "/fixture-book.scm"
                              "/fixture_book.py"))))
         (peer-executable
          (if (string=? peer-label "guile") guile python))
         (peer-arguments
          (if (string=? peer-label "guile")
              (list "--no-auto-compile" "-L" protocol-dir peer-source)
              (list peer-source)))
         (path (or (getenv "PATH") ""))
         (host (make-book-session-host))
         (endpoint #f)
         (session-peer #f)
         (control #f)
         (reader-peer #f)
         (reader-child #f)
         (peer-child #f)
         (completed? #f)
         (cleaned? #f))
    (unless (string=? book expected-book)
      (fail "only the generated inert fixture document may be opened"))
    (define (cleanup!)
      (unless cleaned?
        (set! cleaned? #t)
        (when endpoint
          (catch #t
            (lambda () (release-session-endpoint! endpoint))
            (lambda arguments (close-session! endpoint))))
        (close-control! control)
        (close-port-quietly! session-peer)
        (close-port-quietly! reader-peer)
        (terminate-child! peer-child)
        (terminate-child! reader-child)
        (unless completed?
          (when peer-child
            (format (current-error-port) "--- bounded book-peer log ---~%~a"
                    (child-log-string peer-child)))
          (when reader-child
            (format (current-error-port) "--- bounded KOReader log ---~%~a"
                    (child-log-string reader-child)))
          (force-output (current-error-port)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host peer-label))
          (lambda (new-endpoint new-peer)
            (set! endpoint new-endpoint)
            (set! session-peer new-peer)))
        (let ((pair
               (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
          (set! control (make-control-owner (car pair)))
          (set! reader-peer (cdr pair)))

        (set! peer-child
              (spawn-owned-child
               "book-peer" (string-append run-dir "/peer.pid")
               (string-append run-dir "/peer.log") session-peer
               peer-executable peer-arguments
               (append
                (list (string-append "PATH=" path)
                      "LC_ALL=C"
                      (string-append "HOME=" run-dir "/home")
                      (string-append "TMPDIR=" run-dir "/tmp")
                      (string-append "PYTHONPATH=" protocol-dir)
                      "PYTHONDONTWRITEBYTECODE=1"
                      "GUILE_AUTO_COMPILE=0"
                      "BOOK_SESSION_FD=3")
                (filter-map
                 (lambda (name)
                   (let ((value (getenv name)))
                     (and value (string-append name "=" value))))
                 '("GUILE_LOAD_PATH" "GUILE_LOAD_COMPILED_PATH")))
               tool-dir))
        (close-port-quietly! session-peer)
        (set! session-peer #f)

        (set! reader-child
              (spawn-owned-child
               "koreader" (string-append run-dir "/reader.pid")
               (string-append run-dir "/reader.log") reader-peer
               luajit (list "reader.lua" book)
               (list (string-append "PATH=" path)
                     "LC_ALL=C"
                     (string-append "HOME=" run-dir "/home")
                     (string-append "KO_HOME=" run-dir "/ko")
                     (string-append "XDG_CONFIG_HOME=" run-dir "/home/.config")
                     (string-append "XDG_CACHE_HOME=" run-dir "/home/.cache")
                     (string-append "XDG_DATA_HOME=" run-dir "/home/.local/share")
                     (string-append "TMPDIR=" run-dir "/tmp")
                      (string-append "BOOK_INTERACTION_ROOT=" run-dir)
                      "BOOK_INTERACTION_TRUSTED_NATIVE_FIXTURE=1"
                      "BOOK_INTERACTION_CONTROL_FD=3"
                      (string-append "BOOK_INTERACTION_UPDATE_INPUT="
                                     update-input)
                      (string-append "BOOK_INTERACTION_EXPECTED_RESULT="
                                     expected-result)
                      "SDL_VIDEODRIVER=offscreen"
                     "SDL_AUDIODRIVER=dummy")
               koreader-dir))
        (close-port-quietly! reader-peer)
        (set! reader-peer #f)

        (let ((phase 'boot)
              (session-ready? #f)
              (reader-ready? #f)
              (navigation-tick? #f)
              (close-tick? #f)
              (close-at #f)
              (deadline (after-seconds fixture-deadline-seconds)))
          (define (start-if-ready!)
            (when (and session-ready? reader-ready? (eq? phase 'boot))
              (queue-control! control 'input-update update-input)
              (set! phase 'update-submit)))
          (define (handle-control-event! event)
            (match event
              (('ready 1 "dialog")
               (unless (eq? phase 'boot)
                 (fail "duplicate or late reader ready event"))
               (set! reader-ready? #t)
               (start-if-ready!))
              (('submit 1 value)
               (case phase
                  ((update-submit)
                   (unless (string=? value update-input)
                     (fail "update submitted unexpected dialog text"))
                  (queue-session-message!
                   endpoint (host-action! endpoint "update" value))
                  (set! phase 'update-present))
                 ((navigation-submit)
                  (unless (string=? value "Navigation draft")
                    (fail "navigation submitted unexpected dialog text"))
                  (queue-session-message!
                   endpoint (host-action! endpoint "navigate-stale" value))
                  (unless (= (navigate! endpoint) 2)
                    (fail "navigation did not advance the surface generation"))
                  (unless (= (snapshot endpoint "pending_requests") 0)
                    (fail "navigation did not retire its pending request"))
                  (set! phase 'navigation-stale))
                 ((close-submit)
                  (unless (string=? value "Close draft")
                    (fail "close submitted unexpected dialog text"))
                  (queue-session-message!
                   endpoint (host-action! endpoint "close-stale" value))
                  (set! phase 'close-drain))
                 (else (fail "submit event arrived in phase ~a" phase))))
              (('tick 1 value)
               (cond
                ((string=? value "navigation")
                 (set! navigation-tick? #t))
                ((string=? value "close") (set! close-tick? #t))
                ((string=? value "update") #t)
                (else (fail "unknown UI tick value ~s" value))))
              (('applied 1 value)
               (case phase
                  ((update-applied)
                   (unless (string=? value expected-result)
                     (fail "reader acknowledged the wrong presentation"))
                  (queue-control!
                   control 'input-navigation "Navigation draft")
                  (set! phase 'navigation-submit))
                 ((navigation-applied)
                  (unless (and navigation-tick?
                               (string=? value "navigation"))
                    (fail "navigation rejection lacked a live UI tick"))
                  (queue-control! control 'input-close "Close draft")
                  (set! phase 'close-submit))
                 ((close-applied)
                  (unless (and close-tick? (string=? value "close"))
                    (fail "close rejection lacked a live UI tick"))
                  (queue-control! control 'finish "")
                  (set! phase 'finish))
                 (else (fail "applied event arrived in phase ~a" phase))))
              (('done 1 "ok")
               (unless (eq? phase 'finish)
                 (fail "reader completed in phase ~a" phase))
               (set! phase 'done))
              (_ (fail "unexpected private control event: ~s" event))))
          (define (handle-presented! value)
            (unless (and (eq? phase 'update-present)
                          (string=? (presented-text-action-id value) "update")
                          (string=? (presented-text-value value)
                                    expected-result))
              (fail "unexpected committed Book Session presentation"))
            (queue-control! control 'present (presented-text-value value))
            (set! phase 'update-applied))
          (define (handle-session-input!)
            (when (memq 'input (endpoint-ready-events endpoint))
              (catch 'book-session-error
                (lambda ()
                  (let ((result (endpoint-pump-input! endpoint)))
                    (when (eq? (endpoint-pump-result-status result) 'committed)
                      (let ((value (car (endpoint-pump-result-values result))))
                        (if (presented-text? value)
                            (handle-presented! value)
                            (begin
                              (unless (and (list? value)
                                           (equal? (assoc-ref value "type")
                                                   "initialize"))
                                (fail "unexpected hello dispatch result"))
                              (queue-session-message! endpoint value)
                              (set! session-ready? #t)
                              (start-if-ready!)))))))
                (lambda (key kind message)
                  (if (and (eq? kind 'state)
                           (eq? phase 'navigation-stale)
                           (string=? message
                                     "presentation uses a stale surface generation")
                           (eq? (snapshot endpoint "state") 'active)
                           (= (snapshot endpoint "surface_generation") 2)
                           (= (snapshot endpoint "pending_requests") 0))
                      (begin
                        ;; The authority rejection and independent UI tick may
                        ;; arrive in either order. Publish the rejection only
                        ;; after both have been observed.
                        (set! phase 'navigation-rejected))
                      (fail "Book Session rejected input in phase ~a: ~a ~a"
                            phase kind message))))))
          (define (advance-close!)
            (cond
             ((and (eq? phase 'navigation-rejected) navigation-tick?)
              (queue-control! control 'stale-navigation "")
              (set! phase 'navigation-applied))
             ((and (eq? phase 'close-drain)
                   (= (snapshot endpoint "outbound_frames") 0))
              ;; Let the already-sent action reach the blocking fixture peer.
              ;; This is fixture choreography, not a Book Session deadline.
              (set! close-at (+ (now-ticks)
                                (/ (seconds->ticks 3) 20)))
              (set! phase 'close-grace))
             ((and (eq? phase 'close-grace)
                   (>= (now-ticks) close-at))
              (close-session! endpoint)
              (unless (and (eq? (snapshot endpoint "state") 'closed)
                           (zero? (snapshot endpoint "pending_requests")))
                (fail "close did not synchronously retire authority"))
              (set! phase 'close-peer))
             ((and (eq? phase 'close-peer)
                   (child-exited-zero? peer-child)
                   close-tick?
                   (= (count-exact-line
                       (child-log-string peer-child)
                       "BOOK_INTERACTION_PEER: close:late-present-rejected")
                      1))
              ;; KOReader remains live on its unrelated private channel after
              ;; the book endpoint and peer have both closed and been reaped.
              (unless (not (child-status reader-child))
                (fail "KOReader sibling exited with the book peer"))
              (queue-control! control 'closed "")
              (set! phase 'close-applied))))
          (let loop ()
            (when (> (now-ticks) deadline)
              (fail "fixture exceeded its internal 15-second deadline"))
            (reap-child! reader-child)
            (reap-child! peer-child)
            (when (and (child-status peer-child)
                       (not (or (eq? phase 'close-peer)
                                (eq? phase 'close-applied)
                                (eq? phase 'finish)
                                (eq? phase 'done))))
              (fail "book peer exited early in phase ~a with ~s"
                    phase (child-status peer-child)))
            (when (child-status reader-child)
              (if (eq? phase 'done)
                  (unless (equal? (child-status reader-child) '(exit . 0))
                    (fail "KOReader cleanup failed with ~s"
                          (child-status reader-child)))
                  (fail "KOReader exited early in phase ~a with ~s"
                        phase (child-status reader-child))))
            (pump-control-output! control)
            (let ((event (pump-control-input! control)))
              (cond
               ((eq? event 'eof)
                (unless (eq? phase 'done)
                  (fail "KOReader closed private control before completion")))
               (event (handle-control-event! event))))
            (handle-session-input!)
            (pump-session-output! endpoint)
            (advance-close!)
            (pump-control-output! control)
            (if (and (eq? phase 'done) (child-exited-zero? reader-child))
                (begin
                  (unless (child-exited-zero? peer-child)
                    (fail "book peer was not reaped successfully"))
                   (validate-final-logs!
                    reader-child peer-child expected-revision expected-result)
                  (marker
                   (string-append "language=" peer-label
                                  " update-present-navigation-close:ok"))
                  (set! completed? #t))
                (begin
                  (usleep loop-sleep-microseconds)
                  (loop))))))
      cleanup!)))

(define (main arguments)
  (unless (= (length arguments) 10)
    (display
     (string-append
      "usage: integration-host.scm RUN_DIR KOREADER_DIR "
       "LUAJIT BOOK PEER_LABEL GUILE PYTHON EXPECTED_REVISION "
       "UPDATE_INPUT EXPECTED_RESULT\n")
     (current-error-port))
    (exit 2))
  (match arguments
    ((run-dir koreader-dir luajit book peer-label guile python
                expected-revision update-input expected-result)
     (unless (member peer-label '("guile" "python"))
       (fail "peer label must be guile or python"))
     (run-fixture (canonicalize-path run-dir)
                  (canonicalize-path koreader-dir) (canonicalize-path luajit)
                   (canonicalize-path book) peer-label
                   (canonicalize-path guile) (canonicalize-path python)
                   expected-revision update-input expected-result)
     0)))

(sigaction SIGPIPE SIG_IGN)

(exit
 (catch #t
   (lambda () (main (cdr (command-line))))
   (lambda (key . arguments)
     (format (current-error-port)
             "BOOK_INTERACTION_HOST: FAIL:~s ~s~%" key arguments)
     (force-output (current-error-port))
     1)))
