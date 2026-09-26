;;; Trusted, fresh-process subreaper for one Workbench runtime. The outer FD
;;; adapter has already stopped, published identity, and normalized FDs 0..3
;;; in finite mode. Session mode starts directly with the donation on stdin and
;;; an explicit outer PID:start-time and original CLOCK_MONOTONIC startup deadline,
;;; so parent loss or cancellation during startup cannot authorize a later exec.
;;; No authored source is read here. Every child in this dedicated process is
;;; either our runtime/control child or its adopted descendant, including
;;; gVisor's setsid Sentry and Gofer. Never reap the caller's unrelated children.
(use-modules (ice-9 ftw) (rnrs bytevectors)
             (rnrs io ports) (srfi srfi-1) (system foreign))
(define libc (dynamic-link))
(define prctl (pointer->procedure int (dynamic-func "prctl" libc)
                                 (list int unsigned-long unsigned-long unsigned-long unsigned-long)))
(define pidfd-open (pointer->procedure int (dynamic-func "pidfd_open" libc)
                                      (list int unsigned-int) #:return-errno? #t))
(define pidfd-signal (pointer->procedure int (dynamic-func "pidfd_send_signal" libc)
                                        (list int int '* unsigned-int) #:return-errno? #t))
(define clock-gettime (pointer->procedure int (dynamic-func "clock_gettime" libc) (list int '*)))
(define (now)
  (unless (= (sizeof long) 8) (fail "runtime owner requires a 64-bit Linux host"))
  (let ((out (make-bytevector 16 0)))
    (unless (zero? (clock-gettime 1 (bytevector->pointer out))) (fail "CLOCK_MONOTONIC unavailable"))
    (+ (bytevector-s64-native-ref out 0) (/ (bytevector-s64-native-ref out 8) 1000000000.0))))
(define (fail message) (error message))
(define (exists path)
  (catch 'system-error (lambda () (lstat path))
    (lambda args (if (= (system-error-errno args) ENOENT) #f (apply throw 'system-error args)))))
(define (read-bounded path limit)
  (call-with-input-file path
    (lambda (port)
      (let ((value (get-string-n port (+ limit 1))))
        (cond ((eof-object? value) "") ((> (string-length value) limit) (fail "owner input bound"))
              (else value))))))
(define (identity pid)
  (catch 'system-error
    (lambda ()
      (let* ((text (read-bounded (format #f "/proc/~a/stat" pid) 4096))
             (fields (string-tokenize (substring text (+ 2 (string-rindex text #\)))))))
        (list (string->number (list-ref fields 1)) (list-ref fields 19))))
    (lambda args (if (= (system-error-errno args) ENOENT) #f (apply throw 'system-error args)))))
(define (direct-children)
  ;; spawn may use a Guile worker thread; include every thread's child list.
  (delete-duplicates
   (append-map
    (lambda (tid)
      (catch 'system-error
        (lambda ()
          (map string->number
               (string-tokenize (read-bounded (format #f "/proc/self/task/~a/children" tid) 65536))))
        (lambda args (if (= (system-error-errno args) ENOENT) '() (apply throw 'system-error args)))))
    (scandir "/proc/self/task" (lambda (name) (string->number name))))))
(define (same? left right)
  (and (= (stat:dev left) (stat:dev right)) (= (stat:ino left) (stat:ino right))))
(define (write-exclusive path value)
  (let ((port (fdopen (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC) #o600) "w")))
    (dynamic-wind (lambda () #t) (lambda () (write value port) (newline port) (force-output port))
                  (lambda () (close-port port)))))

(define (owner-main arguments)
  (sigaction SIGCHLD SIG_DFL)
  (sigaction SIGPIPE SIG_IGN)
  (unless (and (>= (length arguments) 8) (equal? (take arguments 1) '("--guile"))
               (equal? (list-ref arguments 2) "--adapter")
               (or (and (equal? (list-ref arguments 4) "--deadline")
                        (equal? (list-ref arguments 6) "--"))
                    (and (>= (length arguments) 12)
                         (equal? (list-ref arguments 4) "--session")
                         (equal? (list-ref arguments 6) "--startup-deadline")
                         (equal? (list-ref arguments 8) "--directory")
                         (equal? (list-ref arguments 10) "--"))))
    (fail "owner requires --guile G --adapter A and either --deadline END -- COMMAND or --session PID:START --startup-deadline END --directory BUNDLE -- COMMAND"))
  (let* ((guile (list-ref arguments 1)) (adapter (list-ref arguments 3))
         (session? (equal? (list-ref arguments 4) "--session"))
         (parent (and session? (string-split (list-ref arguments 5) #\:)))
         (deadline (if session? #f (string->number (list-ref arguments 5))))
         (budget (if session? 20 (- deadline (now))))
         (argv (drop arguments (if session? 11 7)))
         (_ (when session? (chdir (list-ref arguments 9)) (setpgid 0 0)))
         (bundle (getcwd)) (bundle-id (lstat bundle))
         (state (string-append bundle "/runsc-state")) (state-id (lstat state))
         (run-position (list-index (lambda (arg) (string=? arg "run")) argv))
         (container-id (last argv))
         (work-end (if session? (string->number (list-ref arguments 7))
                       (- deadline (min 3 (/ budget 3)))))
         (runtime-pid #f) (runtime-status #f) (control-status '()) (control-results '()) (known '())
         (reaped 0) (stopping? #f) (forced? #f) (error-text #f) (next-scan 0)
         (runtime-started? #f) (execution-failed? #f))
    (unless (and (real? budget) (< 0 budget 30.01) run-position)
      (fail "invalid bounded runtime command"))
    (when session?
      (unless (and (= (length parent) 2)
                   (string->number (car parent))
                   (every char-numeric? (string->list (cadr parent)))
                   (positive? (string-length (cadr parent)))
                   (real? work-end) (< -inf.0 work-end (+ (now) 20.01)))
        (fail "session requires outer owner PID:start-time and original finite startup deadline")))
    (unless (zero? (prctl 36 1 0 0 0)) (fail "dedicated subreaper unavailable"))
    (define (parent-live?)
      ;; Explicit identity from the spawning owner closes the exec/startup race:
      ;; learning getppid here could silently accept init after owner death.
      (or (not session?)
          (let* ((pid (string->number (car parent))) (current (identity pid)))
            (and (= (getppid) pid) current (equal? (cadr current) (cadr parent))))))
    (define (cleanup-deadline!)
      (unless deadline (set! deadline (+ (now) 8))))
    (define (pin-child! pid)
      (unless (assv pid known)
        (let ((before (identity pid)))
          (when (and before (= (car before) (getpid)))
            (call-with-values (lambda () (pidfd-open pid 0))
              (lambda (fd errno)
                (when (< fd 0) (fail "cannot pin owned child with pidfd"))
                (if (equal? before (identity pid))
                    (set! known (cons (cons pid (cons fd before)) known))
                    (begin (close-fdes fd) (fail "owned child identity changed while pinning")))))))))
    (define (scan!)
      (for-each pin-child! (direct-children))
      (set! next-scan (+ (now) (if (and session? (not stopping?)) 0.25 0.01))))
    (define (signal! pair signal)
      ;; pidfd signalling cannot target a reused PID, even after the stat check.
      (call-with-values (lambda () (pidfd-signal (cadr pair) signal %null-pointer 0))
        (lambda (status errno)
          (unless (or (zero? status) (= errno ESRCH)) (fail "owned pidfd signal failed")))))
    (define (observe-runtime-exit! status)
      (set! runtime-status status)
      ;; A session is meant to remain live until cleanup is requested. Preserve
      ;; an exit already observed before stop!, including exit zero. Do not infer
      ;; failure from the kill/137 expected after requested cleanup has begun.
      (when (and session? (not stopping?)) (set! execution-failed? #t)))
    (define (reap!)
      ;; Exact waitpid polling is cheap. Enumerate thread child lists at most
      ;; 100 Hz in finite mode, 4 Hz in an idle session. A zombie cannot disappear
      ;; before our waitpid; empty? rechecks actual membership before success.
      (when (or (null? known) runtime-status (>= (now) next-scan)) (scan!))
      (for-each
       (lambda (pair)
         (let ((waited (catch 'system-error (lambda () (waitpid (car pair) WNOHANG))
                         (lambda args
                           (if (= (system-error-errno args) EINTR) '(0 . 0)
                               (apply throw 'system-error args))))))
           (when (> (car waited) 0)
              (when (= (car pair) (or runtime-pid -1)) (observe-runtime-exit! (cdr waited)))
             (set! control-status (acons (car pair) (cdr waited) control-status))
             (close-fdes (cadr pair)) (set! known (delq pair known)) (set! reaped (+ reaped 1)))))
       (list-copy known)))
    (define (empty?) (and (null? known) (null? (direct-children))))
    (define (wait-until! end predicate)
      (let loop ()
        (reap!)
        (or (predicate) (and (< (now) end) (begin (usleep 1000) (loop))))))
    (define (validate-control-owner!)
      (unless (and (same? (lstat bundle) bundle-id) (same? (lstat state) state-id)
                   (eq? (stat:type (lstat state)) 'directory)
                   (= (stat:uid (lstat state)) (getuid))
                   (= (logand (stat:mode (lstat state)) #o7777) #o700))
        (fail "runtime root identity changed before control command")))
    (define (control! command end)
      ;; Keep this a guest RPC, not a general runsc control entrypoint. In
      ;; particular, delete/Destroy can signal numeric support PIDs from saved
      ;; metadata after our waitpid has released those identities for reuse.
      (unless (equal? command (list "kill" "--all" container-id "KILL"))
        (fail "only the fixed guest kill RPC is permitted"))
      (validate-control-owner!)
      (let* ((args (append (take argv run-position) command))
             (null (open-file "/dev/null" "r"))
             (pid (dynamic-wind
                    (lambda () #t)
                    (lambda () (spawn (car args) args #:search-path? #f #:environment (environ)
                                      #:input null #:output (current-output-port) #:error (current-error-port)))
                    (lambda () (close-port null)))))
        (pin-child! pid)
        (let ((finished? (wait-until! end (lambda () (assv pid control-status)))))
          (unless finished?
            (let ((pair (assv pid known))) (when pair (signal! pair SIGKILL))))
          (set! control-results (cons (list (car command) (and finished? (assv-ref control-status pid)))
                                      control-results))
          (and finished? (equal? (status:exit-val (assv-ref control-status pid)) 0)))))
    (define (slice fraction)
      (min deadline (+ (now) (* fraction (max 0 (- deadline (now)))))))
    (define (kill-owned!)
      (let loop ()
        (reap!)
        (for-each (lambda (pair) (signal! pair SIGKILL)) known)
        (unless (empty?)
          (when (>= (now) deadline) (fail "owned processes survived deadline"))
          (usleep 1000) (loop))))
    (define (stop!)
      (cleanup-deadline!)
      (set! stopping? #t)
      (if (not runtime-started?)
          ;; The fixed adapter cannot exec runsc before our SIGCONT. Reap its
          ;; pinned identity directly, including a delayed pre-SIGSTOP startup.
          ;; No runtime metadata or guest exists, so no RPC/Destroy is required
          ;; and successful exact reaping remains a valid cleanup proof.
          (kill-owned!)
          (begin
            ;; Nonterminal runsc does NOT forward host TERM/KILL. Kill the guest
            ;; via its control API, preserving the main process's deferred Destroy.
            (unless (and runtime-status (empty?))
              (control! (list "kill" "--all" container-id "KILL") (slice 0.30)))
            (unless (wait-until! (slice 0.35) (lambda () (and runtime-status (empty?))))
              (set! forced? #t)
              (kill-owned!))
            ;; Reaping releases numeric PIDs. Never force-delete saved metadata:
            ;; a stable runtime root does not establish saved process identities.
            (when forced?
              (fail "forced pidfd termination completed; runtime state retained; unsafe force-delete prohibited"))))
      (unless (wait-until! deadline empty?) (fail "control descendants survived deadline")))
    (catch #t
      (lambda ()
        (call-with-current-continuation
         (lambda (finished)
           (define (check-startup!)
             (if session?
                 (when (or (not (parent-live?))
                           (exists (string-append bundle "/owner-stop"))
                           (>= (now) work-end))
                   (stop!)
                   (finished #t))
                 (when (>= (now) work-end) (fail "runtime adapter ownership timeout"))))
           (check-startup!)
           (let ((donation (if session? (current-input-port) (fdopen 3 "r+0"))))
             (set! runtime-pid
                   (spawn guile (append (list guile "--no-auto-compile" adapter "--directory" bundle "--") argv)
                          #:search-path? #f #:environment (environ) #:input donation
                          #:output (current-output-port) #:error (current-error-port)))
             (close-port donation))
           (pin-child! runtime-pid)
           (let wait-stop ()
             (check-startup!)
             (let ((waited (waitpid runtime-pid (logior WNOHANG WUNTRACED))))
               (cond
                ((zero? (car waited)) (usleep 1000) (wait-stop))
                ((equal? (status:stop-sig (cdr waited)) SIGSTOP)
                 ;; Recheck after waitpid too: cancellation while the adapter
                 ;; was entering SIGSTOP must not become execution permission.
                 (check-startup!)
                 ;; Set before signalling: a failed SIGCONT cannot justify a
                 ;; claim that the runtime certainly never received permission.
                 (set! runtime-started? #t)
                 (signal! (assv runtime-pid known) SIGCONT))
                (else
                 (observe-runtime-exit! (cdr waited))
                 (let ((pair (assv runtime-pid known)))
                   (close-fdes (cadr pair)) (set! known (delq pair known))
                   (set! reaped (+ reaped 1)))
                 (if session?
                     ;; The adapter was never resumed: its unexpected exit is
                     ;; an execution failure, but exact pre-exec cleanup is safe.
                     (begin (stop!) (finished #t))
                     (fail (format #f "runtime adapter exited before stop: ~s" runtime-status)))))))
           (let loop ()
             (reap!)
             (cond
              ((and runtime-status (empty?))
               (unless (equal? (status:exit-val runtime-status) 0) (stop!)))
              ((or (and (not session?) (>= (now) work-end))
                   (not (parent-live?)) (exists (string-append bundle "/owner-stop"))
                   (and runtime-status
                        (or session? (not (equal? (status:exit-val runtime-status) 0)))))
               (stop!))
              ;; Session idle checks parent identity, stop-file presence and
              ;; child state at four Hz. Handshake/cleanup waits remain 1 ms.
              (else (usleep (if session? 250000 5000)) (loop)))))))
      (lambda (key . args)
        (set! error-text (format #f "~s: ~s" key args))
        (cleanup-deadline!)
        ;; Even a failed control command must not leak live/adopted children.
        ;; Retain an incomplete proof if state cleanup could not be established.
        (let loop ()
          (reap!) (for-each (lambda (pair) (signal! pair SIGKILL)) known)
          (unless (or (empty?) (>= (now) deadline)) (usleep 1000) (loop)))))
    (when (and (not error-text) (empty?))
      (write-exclusive (string-append bundle "/owner-result.scm")
                       `((owner-pid . ,(getpid)) (owner-start-time . ,(cadr (identity (getpid))))
                         (children-reaped . ,reaped) (children-empty? . #t)
                         (controls . ,(reverse control-results))
                         (runtime-started? . ,runtime-started?)
                         ,@(if session? `((execution-failed? . ,execution-failed?)) '())
                         (runtime-status . ,runtime-status) (stopped? . ,stopping?) (forced? . ,forced?))))
    (when error-text (display error-text (current-error-port)) (newline (current-error-port)))
    (primitive-exit (if (and (not error-text) (not stopping?) (not execution-failed?)
                             (equal? (status:exit-val runtime-status) 0)) 0 1))))
(owner-main (cdr (command-line)))
