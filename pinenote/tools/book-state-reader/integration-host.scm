;;; Trusted host fixture for the persistent-note KOReader UI.  This Guile
;;; process is a scripted authority seam, not the production state adapter.
(use-modules (private-control)
             (ice-9 ftw)
             (ice-9 match)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9))

(define linux-msg-nosignal #x4000)
(define max-retained-log-bytes (* 128 1024))
(define loop-sleep-microseconds 5000)
(define fixture-deadline-seconds 18)

(define-record-type <owned-child>
  (%make-owned-child pid start-time record-path log-path status)
  owned-child?
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
  (format #t "BOOK_STATE_READER_HOST: ~a~%" text)
  (force-output))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (now-ticks) (get-internal-real-time))
(define (seconds->ticks seconds)
  (* seconds internal-time-units-per-second))
(define (after-seconds seconds) (+ (now-ticks) (seconds->ticks seconds)))

(define (read-process-start-time pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((stat (call-with-input-file path get-string-all))
                    (close (string-rindex stat #\)))
                    (fields
                     (and close
                          (string-tokenize (substring stat (+ close 2))))))
               (and fields (>= (length fields) 20) (list-ref fields 19))))
           (lambda arguments #f)))))

(define (await-process-start-time pid)
  (let loop ((attempt 0))
    (let ((start (read-process-start-time pid)))
      (cond
       (start start)
       ((>= attempt 100) (fail "could not identify KOReader child ~a" pid))
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
      (fail "KOReader retained unrelated descriptors: ~s" unexpected))))

(define (child-exec! gate-input donation log-path executable arguments
                     environment workdir)
  (close-port-quietly! gate-input)
  (let ((null-input (open-file "/dev/null" "r"))
        (log-output (open-file log-path "w0")))
    (setrlimit 'fsize max-retained-log-bytes max-retained-log-bytes)
    (dup2 (fileno null-input) 0)
    (dup2 (fileno log-output) 1)
    (dup2 (fileno log-output) 2)
    (dup2 (fileno donation) 3)
    (close-unrelated-fds!)
    (assert-sanitized-child-fds!)
    (format #t "BOOK_STATE_READER_SPAWN: koreader:fd-hygiene:only-stdio-and-donated~%")
    (force-output)
    (environ environment)
    (chdir workdir)
    (apply execl executable executable arguments)))

(define (spawn-reader record-path log-path donation executable arguments
                      environment workdir)
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
                    (child-exec! gate-input donation log-path executable
                                 arguments environment workdir)
                    (primitive-exit 127))
                  (lambda (key . details)
                    (format (current-error-port) "child exec failed: ~s ~s~%"
                            key details)
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
                  (%make-owned-child pid start-time record-path log-path #f)))
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
          (let kill-loop ((attempt 0))
            (cond
             ((reap-child! child) #t)
             ((< attempt 20) (usleep 100000) (kill-loop (+ attempt 1)))
             (else (fail "could not reap exact KOReader child"))))))))
    (when (file-exists? (child-record-path child))
      (delete-file (child-record-path child)))))

(define (child-log-string child)
  (unless (file-exists? (child-log-path child))
    (fail "KOReader did not create its bounded log"))
  (let ((size (stat:size (stat (child-log-path child)))))
    (when (>= size max-retained-log-bytes)
      (fail "KOReader reached its bounded log limit"))
    (call-with-input-file (child-log-path child) get-string-all)))

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

(define (queue-command! control kind generation value)
  (unless (control-open? control) (fail "private control channel is closed"))
  (let* ((frame
          (encode-control-line kind generation value reader-command-kinds))
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
                  (lambda ()
                    (send (control-socket control) slice linux-msg-nosignal))
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

(define (take-event! control)
  (let* ((input (control-input control))
         (newline (newline-index input)))
    (and newline
         (let ((line (bytevector-slice input 0 newline)))
           (set-control-input!
            control
            (bytevector-slice input (+ newline 1) (bytevector-length input)))
           (decode-control-line line reader-event-kinds)))))

(define (pump-control-input! control)
  (or (take-event! control)
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
                 (let ((event (take-event! control)))
                   (when (and (not event)
                              (> (bytevector-length input)
                                 max-control-line-bytes))
                     (fail "private control line reached its bound"))
                   event))))))))

(define (command! control kind generation value)
  (queue-command! control kind generation value)
  (pump-control-output! control))

(define (await-event! control child deadline label)
  (let loop ()
    (when (> (now-ticks) deadline)
      (fail "timed out waiting for ~a" label))
    (when (reap-child! child)
      (fail "KOReader exited early while waiting for ~a: ~s"
            label (child-status child)))
    (pump-control-output! control)
    (let ((event (pump-control-input! control)))
      (cond
       ((eq? event 'eof) (fail "KOReader closed control while waiting for ~a" label))
       (event event)
       (else (usleep loop-sleep-microseconds) (loop))))))

(define (expect! control child deadline kind generation value)
  (let ((event
         (await-event! control child deadline
                       (format #f "~a/~a" kind generation))))
    (unless (equal? event (list kind generation value))
      (fail "expected ~s but received ~s" (list kind generation value) event))
    event))

(define (count-exact-line text expected)
  (count (lambda (line) (string=? line expected))
         (string-split text #\newline)))

(define (require-line-count text line wanted)
  (let ((actual (count-exact-line text line)))
    (unless (= actual wanted)
      (fail "KOReader log line count for ~s is ~a, wanted ~a"
            line actual wanted))))

(define (validate-automated-log! child expected-revision)
  (let ((log (child-log-string child)))
    (when (or (string-contains log "BOOK_STATE_READER: FAIL:")
              (string-contains log "Saving failed."))
      (fail "KOReader fixture reported a failure or generic save modal"))
    (require-line-count log (string-append " [*] Version: " expected-revision) 1)
    (for-each
     (lambda (line) (require-line-count log line 1))
     '("BOOK_STATE_READER_SPAWN: koreader:fd-hygiene:only-stdio-and-donated"
       "BOOK_STATE_READER: plugin-init:trusted-automated-fixture"
       "BOOK_STATE_READER: private-source-registered"
       "BOOK_STATE_READER: selection-action:registered"
       "BOOK_STATE_READER: startup-overlays-dismissed:2"
       "BOOK_STATE_READER: commit-failed:storage-failure:draft-retained"
       "BOOK_STATE_READER: cleanup-audit:before-quit"
       "BOOK_STATE_READER_UI_AUDIT: cleanup:dialogs-source-fd-action-callback:clean"
       "BOOK_STATE_READER: cleanup-audit:all-generations-clean"))
    ;; Three Save callbacks are legitimate: failed attempt, exact retry, and a
    ;; commit whose reply arrives after navigation. Duplicate Save commands do
    ;; not invoke a fourth callback or submission.
    (unless (= (count
                (lambda (line)
                  (string-prefix? "BOOK_STATE_READER: submit:" line))
                (string-split log #\newline))
               3)
      (fail "KOReader did not emit exactly three legitimate submissions"))
    ;; Only the one matching receipt shown before navigation may paint Saved.
    (require-line-count
     log "BOOK_STATE_READER: status-painted:generation=3:state=saved" 1)
    (require-line-count
     log (string-append
          "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=3:state=saved:text-bytes="
          (number->string (bytevector-length (string->utf8 "Brouillon sauvé — 東京 λ"))))
     1)
    (unless (= (count
                (lambda (line)
                  (string-contains line ":state=saved"))
                (string-split log #\newline))
               2)
      (fail "Saved appeared without exactly one state marker and one paint audit"))))

(define (base-environment run-dir mode)
  (let ((path (or (getenv "PATH") "")))
    (append
     (list (string-append "PATH=" path)
           "LC_ALL=C"
           (string-append "HOME=" run-dir "/home")
           (string-append "KO_HOME=" run-dir "/ko")
           (string-append "XDG_CONFIG_HOME=" run-dir "/home/.config")
           (string-append "XDG_CACHE_HOME=" run-dir "/home/.cache")
           (string-append "XDG_DATA_HOME=" run-dir "/home/.local/share")
           (string-append "TMPDIR=" run-dir "/tmp")
           (string-append "BOOK_STATE_READER_ROOT=" run-dir)
           "BOOK_STATE_READER_TRUSTED_FIXTURE=1"
           "BOOK_STATE_READER_CONTROL_FD=3"
           (string-append "BOOK_STATE_READER_MODE=" mode)
           "SDL_AUDIODRIVER=dummy")
     (if (string=? mode "automated")
         '("SDL_VIDEODRIVER=offscreen")
         (filter-map
          (lambda (name)
            (let ((value (getenv name)))
              (and value (string-append name "=" value))))
          '("DISPLAY" "WAYLAND_DISPLAY" "XDG_RUNTIME_DIR"
            "SDL_VIDEODRIVER"))))))

(define (run-automated! control child deadline)
  (define existing-note "Déjà lu — 東京 λ")
  (define failed-draft "Brouillon sauvé — 東京 λ")
  (define late-draft "Après navigation — élan 東京")
  (define storage-present? #f)
  (define storage-version 0)
  (define storage-text "")
  (define (seed! present text)
    (set! storage-present? present)
    (set! storage-text text)
    (set! storage-version (if present (+ storage-version 1) 0)))
  (define (load! generation)
    (if storage-present?
        (command! control 'load-value generation storage-text)
        (command! control 'load-absent generation ""))
    (expect! control child deadline 'status generation
             (if storage-present? "loaded-value" "loaded-absent"))
    (expect! control child deadline 'applied generation storage-text))
  (define (open-and-load! generation)
    (command! control 'open generation "")
    (expect! control child deadline 'ready generation "")
    (load! generation))
  (define (edit! generation text)
    (command! control 'edit generation text)
    (expect! control child deadline 'status generation "dirty"))
  (define (save! generation text)
    (command! control 'save generation "")
    ;; Submission precedes the inherited paint confirmation of Pending.
    (expect! control child deadline 'submit generation text)
    (expect! control child deadline 'status generation "pending"))
  (define (commit-storage! text)
    (set! storage-present? #t)
    (set! storage-version (+ storage-version 1))
    (set! storage-text text))

  (expect! control child deadline 'channel-ready 1 "")

  ;; Absent and present-empty are different authority snapshots.  Both reach
  ;; the actual widget and inherited paint without any preceding Save.
  (open-and-load! 1)
  (command! control 'navigate 1 "")
  (expect! control child deadline 'navigated 1 "")
  (command! control 'present 1 "must not paint")
  (expect! control child deadline 'ignored 1 "present")

  (seed! #t "")
  (open-and-load! 2)
  (command! control 'close 2 "")
  (expect! control child deadline 'closed 2 "")
  (command! control 'load-value 2 "late closed value")
  (expect! control child deadline 'ignored 2 "load-value")

  (seed! #t existing-note)
  (open-and-load! 3)
  (edit! 3 failed-draft)
  (save! 3 failed-draft)
  (command! control 'save 3 "")
  (expect! control child deadline 'ignored 3 "save")
  (command! control 'commit-failed 3 "storage-failure")
  (expect! control child deadline 'status 3 "failed")
  ;; No edit command intervenes: exact resubmission proves the failed draft
  ;; remained in the real editable InputDialog.
  (save! 3 failed-draft)
  (command! control 'save 3 "")
  (expect! control child deadline 'ignored 3 "save")
  (commit-storage! failed-draft)
  (marker (format #f "storage-committed:version=~a:text-bytes=~a"
                  storage-version
                  (bytevector-length (string->utf8 storage-text))))
  (command! control 'commit-ok 3 storage-text)
  (expect! control child deadline 'status 3 "saved")
  (marker "ui-committed-confirmation-after-storage")
  ;; Presentation and applied paint are deliberately a later exchange.
  (command! control 'present 3 storage-text)
  (expect! control child deadline 'applied 3 storage-text)
  (marker "ui-applied-after-separate-presentation")
  (command! control 'navigate 3 "")
  (expect! control child deadline 'navigated 3 "")

  ;; A fresh interaction can recover only through a fresh authority load.
  (open-and-load! 4)
  (edit! 4 late-draft)
  (save! 4 late-draft)
  (commit-storage! late-draft)
  (command! control 'navigate 4 "")
  (expect! control child deadline 'navigated 4 "")
  (command! control 'commit-ok 4 storage-text)
  (expect! control child deadline 'ignored 4 "commit-ok")
  (command! control 'present 4 storage-text)
  (expect! control child deadline 'ignored 4 "present")

  (command! control 'open 5 "")
  (expect! control child deadline 'ready 5 "")
  (command! control 'load-value 4 "stale generation value")
  (expect! control child deadline 'ignored 4 "load-value")
  (load! 5)
  (command! control 'close 5 "")
  (expect! control child deadline 'closed 5 "")
  (command! control 'load-value 5 "late after close")
  (expect! control child deadline 'ignored 5 "load-value")
  (command! control 'finish 5 "")
  (expect! control child deadline 'done 5 "ok")
  (marker "absent-empty-nonempty-failure-commit-paint-late-reopen:ok"))

(define (run-interactive! control child deadline)
  (define storage-present? #f)
  (define storage-version 0)
  (define storage-text "")
  (define pending #f)
  (define active-generation #f)
  (define (load! generation)
    (command! control
              (if storage-present? 'load-value 'load-absent)
              generation storage-text))
  (expect! control child deadline 'channel-ready 1 "")
  (command! control 'open 1 "")
  (let loop ()
    (when (reap-child! child)
      (marker "interactive-reader-exited")
      (set! child #f))
    (when child
      (pump-control-output! control)
      (let ((event (pump-control-input! control)))
        (match event
          (('ready generation "")
           (set! active-generation generation)
           (load! generation))
          (('submit generation text)
           (unless (and active-generation (= generation active-generation)
                        (not pending))
             (fail "interactive submission violated single-pending state"))
           (set! pending (cons generation text)))
          (('status generation "pending")
           (unless (and pending (= generation (car pending)))
             (fail "interactive pending confirmation has no submission"))
           (set! storage-present? #t)
           (set! storage-version (+ storage-version 1))
           (set! storage-text (cdr pending))
           (command! control 'commit-ok generation storage-text))
          (('status generation "saved")
           (unless (and pending (= generation (car pending))
                        (string=? storage-text (cdr pending)))
             (fail "interactive saved confirmation mismatched storage"))
           (set! pending #f)
           (command! control 'present generation storage-text))
          (('status _ _) #t)
          (('applied generation text)
           (marker
            (format #f "interactive-applied:generation=~a:text-bytes=~a"
                    generation (bytevector-length (string->utf8 text)))))
          ((or ('closed generation "") ('navigated generation ""))
           (when (and active-generation (= generation active-generation))
             (set! active-generation #f)
             (set! pending #f)
             (marker "interactive-closed; use the selection action to reopen")))
          ('eof
           (marker "interactive-control-eof")
           (set! child #f))
          (#f (usleep loop-sleep-microseconds))
          (_ (fail "unexpected interactive UI event: ~s" event)))
      (loop)))))

(define (run-fixture run-dir koreader-dir luajit book expected-revision mode)
  (let ((reader-peer #f)
        (control #f)
        (child #f)
        (completed? #f))
    (define (cleanup!)
      (close-control! control)
      (close-port-quietly! reader-peer)
      (terminate-child! child)
      (unless completed?
        (when child
          (format (current-error-port) "--- bounded KOReader log ---~%~a"
                  (child-log-string child))
          (force-output (current-error-port)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((pair
               (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
          (set! control (make-control-owner (car pair)))
          (set! reader-peer (cdr pair)))
        (set! child
              (spawn-reader
               (string-append run-dir "/reader.pid")
               (string-append run-dir "/reader.log") reader-peer
               luajit (list "reader.lua" book)
               (base-environment run-dir mode) koreader-dir))
        (close-port-quietly! reader-peer)
        (set! reader-peer #f)
        (if (string=? mode "automated")
            (begin
              (run-automated! control child
                              (after-seconds fixture-deadline-seconds))
              (let wait ((attempt 0))
                (cond
                 ((equal? (reap-child! child) '(exit . 0)) #t)
                 ((child-status child)
                  (fail "KOReader cleanup exited with ~s" (child-status child)))
                 ((>= attempt 200) (fail "KOReader did not exit after done"))
                 (else (usleep 10000) (wait (+ attempt 1)))))
              (validate-automated-log! child expected-revision)
              (marker "result:ok"))
            (run-interactive! control child
                              (after-seconds fixture-deadline-seconds)))
        (set! completed? #t))
      cleanup!)))

(define (main arguments)
  (unless (= (length arguments) 6)
    (display
     "usage: integration-host.scm RUN_DIR KOREADER_DIR LUAJIT BOOK EXPECTED_REVISION MODE\n"
     (current-error-port))
    (exit 2))
  (match arguments
    ((run-dir koreader-dir luajit book expected-revision mode)
     (unless (member mode '("automated" "interactive"))
       (fail "mode must be automated or interactive"))
     (run-fixture (canonicalize-path run-dir)
                  (canonicalize-path koreader-dir)
                  (canonicalize-path luajit)
                  (canonicalize-path book)
                  expected-revision mode)
     0)))

(sigaction SIGPIPE SIG_IGN)

(exit
 (catch #t
   (lambda () (main (cdr (command-line))))
   (lambda (key . arguments)
     (format (current-error-port) "BOOK_STATE_READER_HOST: FAIL:~s ~s~%"
             key arguments)
     (force-output (current-error-port))
     1)))
