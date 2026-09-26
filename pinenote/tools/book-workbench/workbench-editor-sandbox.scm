;;; Long-lived editor execution owner. This module never evaluates source or
;;; handles Book Session frames. The coordinator gates all delivery on ready.
;;; Entrypoints must primitive-load guest-book-protocol BEFORE importing this
;;; module: its lifetime signal thread must start outside the module-loader lock.
(define-module (workbench-editor-sandbox)
  #:use-module (workbench-sandbox)
  #:use-module (workbench-preview)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (system foreign)
  #:export (run-editor-sandbox))

(define (sandbox name) (module-ref (resolve-module '(workbench-sandbox)) name))
(define (preview name) (module-ref (resolve-module '(workbench-preview)) name))
(define (base name) (module-ref (resolve-module '(guest-book-protocol)) name))
(define (oci name) (module-ref (resolve-module '(oci-bundle)) name))
(define (smoke name) (module-ref (resolve-module '(guest-smoke)) name))
(define (fail text) (throw 'workbench-editor-sandbox-error text))
(define (now) ((sandbox 'now)))
(define (close! port) ((preview 'close-quietly) port))
(define (field value key) (assoc-ref value key))
(define (check-time! deadline) ((sandbox 'check-time!) deadline))
(define (capture-port capture) ((@@ (workbench-sandbox) capture-port) capture))
(define (capture-eof? capture) ((@@ (workbench-sandbox) capture-eof?) capture))
(define (make-capture port chunks)
  ((@@ (workbench-sandbox) make-capture) port 0 #f #vu8() chunks))

(define (source-bytes path)
  (let* ((bytes ((sandbox 'read-owned-bytes) path 8192 #o400))
         (text (utf8->string bytes)))
    ((preview 'bounded-text!) text 8192 "editor source")
    (unless (bytevector=? bytes (string->utf8 text)) (fail "source is not strict UTF-8"))
    bytes))

(define (control-port fd)
  (unless (and (integer? fd) (> fd 2) (eq? (stat:type (stat fd)) 'socket))
    (fail "control must be a private connected Unix stream descriptor"))
  (let ((port (fdopen fd "r+0")) (accepted? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (and (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
                     (= (vector-ref (getsockname port) 0) AF_UNIX)
                     (= (vector-ref (getpeername port) 0) AF_UNIX))
          (fail "control must be a private connected Unix stream descriptor"))
        (fcntl fd F_SETFD FD_CLOEXEC)
        (fcntl fd F_SETFL (logior O_NONBLOCK (fcntl fd F_GETFL)))
        (set! accepted? #t)
        port)
      (lambda () (unless accepted? (close! port))))))

(define (control-reader port)
  ;; Raw nonblocking reads, at most 33 bytes per turn. Guile's buffered line
  ;; reader could block waiting for LF despite readiness of a partial command.
  ;; The only command is stop; malformed, oversized or extra commands fail closed.
  (let ((pending ""))
    (lambda ()
      (let ((bytes (make-bytevector 33)))
        (call-with-values
            (lambda () ((preview 'c-read) (fileno port) (bytevector->pointer bytes) 33))
          (lambda (count errno)
            (cond ((zero? count) #t)
                  ((negative? count)
                   (if (memv errno (list EINTR EAGAIN)) #f (fail "control read failed")))
                  (else
                   (when (> (+ count (string-length pending)) 32) (fail "control command exceeds bound"))
                   (let ((part (make-bytevector count)))
                     (bytevector-copy! bytes 0 part 0 count)
                     (set! pending (string-append pending (utf8->string part))))
                   (unless (string-prefix? pending "stop\n") (fail "invalid editor control command"))
                   (string=? pending "stop\n")))))))))

(define (notify! port message)
  ;; Two fixed tiny receipts only; do not wait behind an unresponsive parent.
  (unless (= (send port (string->utf8 message) MSG_DONTWAIT) (string-length message))
    (fail "control receipt was not delivered")))

(define (execute-session! root bundle id argv environment guile adapter helper
                          control startup-deadline)
  (let ((root-identity (lstat root)) (runtime #f) (stores '()) (ports '()) (captures '())
        (pid #f) (identity #f) (reaped? #f) (status #f) (proof #f)
        (ready? #f) (failure #f) (cleanup-failure #f) (deadline #f)
        (next-observation 0) (last-observation #f)
        (stop-requested? (control-reader control)))
    (define (remember! key args)
      (unless failure (set! failure (format #f "~a: ~s" key args))))
    (define (cleanup thunk)
      (catch #t thunk (lambda (key . args)
                       (unless cleanup-failure
                         (set! cleanup-failure (format #f "~a: ~s" key args))))))
    (define (own-pipe!)
      (let ((pair ((preview 'capture-pipe))))
        (set! ports (cons (car pair) (cons (cdr pair) ports))) pair))
    (define (pump!) (for-each (sandbox 'pump-capture!) captures))
    (define (pump-cleanup!)
      ;; Teardown diagnostics obey the same lifetime capture bound. Keep the
      ;; first failure, but continue draining so a healthy Destroy can finish.
      (for-each (lambda (capture)
                  (catch #t (lambda () ((sandbox 'pump-capture!) capture))
                    (lambda (key . args) (remember! key args)))) captures))
    (define (reap!)
      (when (and pid (not reaped?))
        ((preview 'require-owned-pid!) pid identity)
        (let ((waited ((preview 'wait-child) pid WNOHANG)))
          (unless waited (fail "runtime owner was reaped outside its execution domain"))
          (when (positive? (car waited))
            (set! reaped? #t) (set! status (cdr waited))))))
    (define (gone?)
      (and reaped? (not ((preview 'group-exists?) pid))))
    (define (observe!)
      (let* ((sample (parameterize (((sandbox 'observation-deadline)
                                     (if ready? (+ (now) 0.05) startup-deadline)))
                       ((sandbox 'observe-cgroup) id)))
             (valid? (and sample (field sample 'controls-match?)
                          (pair? (field sample 'members)))))
        ;; Unlike the one-shot path, we sample before the runner's hello. The
        ;; runtime creates the cgroup, writes controls, then moves processes in:
        ;; those intermediate full samples cannot authorize source delivery.
        ;; Wait within startup's existing budget; after ready, any drift fails.
        (when (and ready? sample (not valid?))
          (fail "live editor cgroup controls/membership do not match"))
        (when valid? (set! last-observation sample))
        (set! next-observation (+ (now) 0.25))
        (and valid? sample)))
    (define (stop!)
      (when pid
        (reap!)
        (unless (gone?)
          ((preview 'write-exclusive) (string-append bundle "/owner-stop") #vu8(49) #o600)
          (let loop ()
            (reap!)
            (pump-cleanup!)
            (unless (gone?) (check-time! deadline) (usleep 10000) (loop))))
        ;; No numeric metadata cleanup: only the helper's PID/start-time-bound
        ;; proof establishes that detached/adopted descendants are all gone.
        (let* ((bytes ((sandbox 'read-owned-bytes)
                       (string-append bundle "/owner-result.scm") 4096 #o600))
               (value (call-with-input-string (utf8->string bytes)
                        (lambda (port)
                          (let ((value (read port)))
                            (unless (eof-object? (read port)) (fail "trailing owner proof")) value)))))
          (unless (and (equal? (field value 'owner-pid) pid)
                       (equal? (field value 'owner-start-time) identity)
                       (eq? (field value 'children-empty?) #t)
                       (assq 'execution-failed? value)
                       (boolean? (field value 'execution-failed?))
                       (eq? (field value 'forced?) #f))
             (fail "runtime owner did not prove exact descendant cleanup"))
          (set! proof value)
          ;; Stop can bypass the main loop's reap. Cleanup evidence must not
          ;; erase an execution failure the helper had already observed.
          (when (field value 'execution-failed?)
            (remember! 'runtime-owner-execution-failed
                       (list "runtime/adapter exited before requested cleanup"
                             (field value 'runtime-status)))))
        (let drain ()
          (check-time! deadline)
          ;; A first overflow can arrive only after stop. Record it while still
          ;; reading to EOF without allocating beyond the capture's fixed storage.
          (pump-cleanup!)
          (unless (every capture-eof? captures) (usleep 1000) (drain)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (catch #t
          (lambda ()
            (check-time! startup-deadline)
            (set! stores ((smoke 'diagnostic-stores) bundle))
            (for-each (lambda (store) ((sandbox 'mount-diagnostic!) store startup-deadline)) stores)
            (set! runtime ((base 'prepare-owned-runtime-state!) bundle id))
            (let ((stdout (own-pipe!)) (stderr (own-pipe!)))
              (set! captures
                    (list (make-capture (car stdout) #f)
                          (make-capture (car stderr) '())))
              (check-time! startup-deadline)
              (set! pid
                    (spawn guile
                           (append (list guile "--no-auto-compile" helper
                                         "--guile" guile "--adapter" adapter "--session"
                                          (format #f "~a:~a" (getpid)
                                                  ((base 'read-process-start-time) (getpid)))
                                          "--startup-deadline"
                                          (number->string
                                           (+ ((sandbox 'monotonic-now)) (- startup-deadline (now))))
                                          "--directory" bundle "--") argv)
                           #:search-path? #f #:environment environment
                           #:input (current-input-port)
                           #:output (cdr stdout) #:error (cdr stderr)))
              (set! identity ((base 'read-process-start-time) pid))
              (unless identity (fail "runtime owner has no process identity"))
              (close! (cdr stdout)) (close! (cdr stderr))
              ;; The dedicated owner now holds the sole donated book endpoint.
              (close! (current-input-port)))
            (let loop ()
              (unless ready? (check-time! startup-deadline))
              (unless (stop-requested?)
                (pump!) (reap!)
                (when reaped? (fail "editor runtime exited"))
                (when (>= (now) next-observation)
                  (let ((sample (observe!)))
                    (when (and ready? (not sample)) (fail "editor cgroup disappeared"))
                    (when (and sample (not ready?))
                      (notify! control "ready\n") (set! ready? #t))))
                ;; select wakes promptly on close/stop or bounded output, while
                ;; idle reaping/cgroup observations run at four Hz. Startup's
                ;; remaining budget can shorten that wait; input never waits for
                ;; the next observation tick.
                (select (cons control
                              (map capture-port
                                   (filter (lambda (c) (not (capture-eof? c))) captures)))
                        '() '() 0
                        (max 0 (min 250000
                                    (inexact->exact
                                     (floor (* 1000000
                                               (- (if ready? next-observation
                                                      (min next-observation startup-deadline))
                                                  (now))))))))
                (loop))))
          (lambda (key . args) (remember! key args))))
      (lambda ()
        ;; Human idle time is unlimited. Only cancellation/failure starts this
        ;; finite window; the helper reserves eight seconds, leaving two here.
        (set! deadline (+ (now) 10))
        (cleanup (lambda () (close! (current-input-port))))
        (cleanup stop!)
        (for-each (lambda (port) (cleanup (lambda () (close! port)))) ports)
        (unless cleanup-failure
          (when runtime
            (cleanup (lambda () ((sandbox 'cleanup-runtime!) runtime id
                                 (and proof (field proof 'runtime-started?)) deadline)))))
        (unless cleanup-failure
          (for-each (lambda (store) (cleanup (lambda () ((sandbox 'cleanup-diagnostic!) store deadline))))
                    (reverse stores)))
        (unless cleanup-failure
          (cleanup (lambda ()
                     (unless ((sandbox 'same?) (lstat root) root-identity)
                       (fail "editor root changed identity"))
                     ((sandbox 'assert-tree-unmounted!) root)
                     ((preview 'remove-owned-tree) root deadline)
                     (when ((preview 'exists) root) (fail "editor tree remains")))))))
    ;; clean attests cleanup only, even following an execution failure. A lost
    ;; parent need not receive it; inability to send is not a cleanup failure.
    (unless cleanup-failure (catch #t (lambda () (notify! control "clean\n")) (lambda _ #f)))
    `((status . ,(if (or failure cleanup-failure) 'failed 'ok))
      (ready? . ,ready?) (cleanup-complete? . ,(not cleanup-failure))
      (runtime-owner . ,proof) (last-observation . ,last-observation)
      (diagnostic . ,((sandbox 'failure-diagnostic) root failure cleanup-failure
                      (if (and (or failure cleanup-failure) (= (length captures) 2))
                          (field ((sandbox 'capture-evidence) (cadr captures)) 'text) ""))))))

(define (run-editor-sandbox* config control-fd source-file)
  "Dedicated process API. CONFIG has make-sandbox-preview's trusted keys, with
runner selecting the immutable editor runner. Stdin is the donated book socket;
CONTROL-FD is the sole additional inherited descriptor. Send stop LF or EOF.
Receipts ready LF and clean LF attest live controls and exact cleanup respectively.
Startup is bounded to 20 seconds, cleanup to 10; human idle has no wall deadline.
The package entrypoint must initialize guest-book-protocol before this import."
  (let ((control #f) (root #f) (handed-off? #f) (startup-deadline (+ (now) 20)))
    (define (preparing!)
      (check-time! startup-deadline)
      ;; No request except cancellation is legal before ready. A partial stop
      ;; is sufficient here: no runtime exists and nothing needs to be parsed.
      (when (pair? (car (select (list control) '() '() 0)))
        (fail "editor cancelled during preparation")))
    (sigaction SIGPIPE SIG_IGN)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (catch #t
          (lambda ()
            (set! control (control-port control-fd))
            (preparing!)
            (unless (eq? (stat:type (stat (current-input-port))) 'socket)
              (fail "editor requires book socket on stdin"))
            (unless (and (= (getsockopt (current-input-port) SOL_SOCKET SO_TYPE) SOCK_STREAM)
                         (= (vector-ref (getsockname (current-input-port)) 0) AF_UNIX)
                         (= (vector-ref (getpeername (current-input-port)) 0) AF_UNIX))
              (fail "book donation must be a connected Unix stream"))
            (when ((sandbox 'same?) (stat control) (stat (current-input-port)))
              (fail "book and control must be distinct endpoints"))
            (let* ((bytes (source-bytes source-file))
                   (guile ((sandbox 'trusted-program!) (field config 'supervisor-guile) #t))
                   (adapter ((sandbox 'trusted-program!) (field config 'runsc-fd3-adapter) #f))
                   (helper ((sandbox 'trusted-program!) (field config 'runtime-owner) #f))
                   (parent ((sandbox 'private-parent!) (field config 'runtime-parent)))
                   (profile ((oci 'validate-profile) (field config 'language-profile) "/gnu/store"))
                   (selected (field config 'language-closure))
                   (closure ((oci 'validate-requisites)
                             (if (string? selected)
                                 ((sandbox 'read-language-closure) ((sandbox 'trusted-program!) selected #f))
                                 selected) profile "/gnu/store"))
                   (sources (map (lambda (key) (field config key))
                                 '(runner guile-protocol blocking-protocol))))
              (preparing!)
              (set! root (mkdtemp (string-append parent "/editor.XXXXXX"))) (chmod root #o700)
              (let* ((bundle (string-append root "/bundle"))
                     (id (string-append "workbench-" (string-downcase (basename root))))
                     (runtime-program ((sandbox 'runtime-preflight!) id)))
                (generate-workbench-preview-bundle
                 #:source bytes #:profile-input profile #:runner-input (car sources)
                 #:protocol-input (cadr sources) #:blocking-input (caddr sources)
                 #:bundle-input bundle #:container-id id #:requisites-runner (lambda (_) closure)
                 #:cleanup-deadline startup-deadline #:editor? #t)
                (preparing!)
                (call-with-values
                    (lambda () ((sandbox 'validate-launch!) bundle id bytes profile closure sources #:editor? #t))
                  (lambda (argv environment)
                    (preparing!)
                    ;; Never reselect or execute the mutable policy alias.
                    (unless (equal? runtime-program
                                    ((sandbox 'trusted-program!) "/run/current-system/profile/bin/runsc" #t))
                      (fail "runsc policy alias retargeted during editor preparation"))
                    (set! handed-off? #t)
                    (execute-session! root bundle id (cons runtime-program (cdr argv)) environment
                                      guile adapter helper control startup-deadline))))))
          (lambda (key . args)
            (let ((retained? (and root handed-off?)))
              (close! (current-input-port))
              (when (and root (not handed-off?))
                (catch #t (lambda () ((preview 'remove-owned-tree) root (+ (now) 10)))
                  (lambda _ (set! retained? #t))))
              ;; No execution was handed off: absence of children/mounts follows
              ;; from preparation, and a removed tree is still a valid clean.
              (when (and control (not retained?))
                (catch #t (lambda () (notify! control "clean\n")) (lambda _ #f)))
              `((status . failed) (ready? . #f) (cleanup-complete? . ,(not retained?))
                (diagnostic . ,((sandbox 'failure-diagnostic)
                                (or root "") (format #f "~a: ~s" key args)
                                (and retained? "editor resources retained") "")))))))
      (lambda ()
        (close! (current-input-port))
        (close! control)))))

(define (run-editor-sandbox config control-fd source-file)
  "Run the dedicated owner; see run-editor-sandbox* for the transport contract.
Failure also creates SOURCE-FILE.sandbox-error exclusively, mode 0600, containing
at most 2048 UTF-8 bytes of plain diagnostic data. It is caller-owned evidence,
outside the runtime tree; it is never read/evaluated and never overwritten."
  (let ((result (run-editor-sandbox* config control-fd source-file)))
    (when (eq? (field result 'status) 'failed)
      (catch #t
        (lambda ()
          (let* ((text (field result 'diagnostic)) (bytes (string->utf8 text)))
            ;; Bound bytes without splitting UTF-8, including non-ASCII paths.
            (let trim ((text text) (bytes bytes))
              (if (> (bytevector-length bytes) 2048)
                  (let ((shorter (substring text 0 (quotient (string-length text) 2))))
                    (trim shorter (string->utf8 shorter)))
                  ((preview 'write-exclusive) (string-append source-file ".sandbox-error") bytes #o600)))))
        (lambda _ #f)))
    result))
