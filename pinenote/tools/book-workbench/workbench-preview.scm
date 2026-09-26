;;; Offline Workbench execution. preview-native is a TRUSTED NATIVE FIXTURE,
;;; never a fallback for runsc and never confinement of hostile authored code.
;;; OCI preparation below writes data only; no authored Scheme is loaded here.
(define-module (workbench-preview)
  #:use-module (book-session)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (system foreign)
  #:export (preview-native
            max-workbench-source-bytes
            generate-workbench-preview-bundle
            workbench-preview-launch-argv))

(define max-workbench-source-bytes 16384)
(define capture-limit 16384)
(define native-mutex (make-mutex))
(define libc (dynamic-link))
(define c-read
  (pointer->procedure ssize_t (dynamic-func "read" libc) (list int '* size_t)
                     #:return-errno? #t))
(define c-prctl
  (pointer->procedure int (dynamic-func "prctl" libc)
                     (list int unsigned-long unsigned-long unsigned-long unsigned-long)))

(define (fail message) (throw 'workbench-preview-error message))
(define (now) (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(define (field object key) (assoc-ref object key))
(define (bounded-text! value limit label)
  (unless (and (string? value) (<= 1 (string-length value) limit)
               (not (string-index value #\nul))
               (<= (bytevector-length (string->utf8 value)) limit))
    (fail (format #f "~a must be 1..~a UTF-8 bytes without NUL" label limit))))
(define (source-bytes source)
  (when (and (bytevector? source)
             (not (<= 1 (bytevector-length source) max-workbench-source-bytes)))
    (fail "source must be 1..16384 UTF-8 bytes without NUL"))
  (let* ((bytes (if (bytevector? source) (bytevector-copy source)
                   (begin (bounded-text! source max-workbench-source-bytes "source")
                          (string->utf8 source))))
         (text (utf8->string bytes)))
    (bounded-text! text max-workbench-source-bytes "source")
    bytes))
(define (close-quietly port)
  (when (and (port? port) (not (port-closed? port))) (close-port port)))
(define (exists path)
  (catch 'system-error (lambda () (lstat path))
    (lambda args
      (if (= (system-error-errno args) ENOENT) #f (apply throw 'system-error args)))))
;; Private parameters let tests expire the clock during a real incremental
;; traversal. Production always uses the monotonic clock and readdir directly.
(define cleanup-clock (make-parameter now))
(define cleanup-read-directory (make-parameter readdir))
(define* (remove-owned-tree path #:optional deadline)
  ;; Called only for an exclusively created private fixture/bundle directory.
  ;; Never follow a symlink made by native fixture code, or enumerate an entire
  ;; authored directory before checking the deadline. Ancestors remain present
  ;; if the traversal stops, and dynamic-wind closes every opened directory.
  ;; The no-deadline form is for trusted test/never-executed OCI preparation
  ;; cleanup; the native runtime must supply its original absolute deadline.
  (define (check-time!)
    (when (and deadline (>= ((cleanup-clock)) deadline))
      (throw 'workbench-preview-cleanup-incomplete
             "runtime tree cleanup reached its deadline" path)))
  (define (walk current)
    (check-time!)
    (let ((info (exists current)))
      (when info
        (check-time!)
        (if (eq? (stat:type info) 'directory)
            (begin
              (let ((directory (opendir current)))
                (dynamic-wind
                  (lambda () #t)
                  (lambda ()
                    (let loop ()
                      (check-time!)
                      (let ((name ((cleanup-read-directory) directory)))
                        (check-time!)
                        (unless (eof-object? name)
                          (unless (member name '("." ".."))
                            (walk (string-append current "/" name)))
                          (loop)))))
                  (lambda () (closedir directory))))
              (check-time!)
              (rmdir current))
            (delete-file current)))))
  (walk path))
(define (write-exclusive path bytes mode)
  (let ((port (fdopen (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                                mode) "wb")))
    (dynamic-wind (lambda () #t)
                  (lambda () (put-bytevector port bytes) (force-output port)
                    (chmod path mode))
                  (lambda () (close-port port)))))
(define (trusted-path path executable?)
  (unless (and (string? path) (string-prefix? "/" path)
               (not (string-index path #\nul))
               (eq? (stat:type (stat path)) 'regular)
               (or (not executable?) (access? path X_OK)))
    (fail "native fixture requires explicit absolute trusted program paths"))
  path)

(define-record-type <capture>
  (make-capture port bytes chunks eof?) capture?
  (port capture-port) (bytes capture-bytes set-capture-bytes!)
  (chunks capture-chunks set-capture-chunks!) (eof? capture-eof? set-capture-eof!))
;; Private acquisition/configuration hooks are used only by fault-injection
;; tests. Keep the pair owned here until it is fully configured for publication.
(define capture-open-pipe (make-parameter pipe))
(define capture-fcntl (make-parameter fcntl))
(define (capture-pipe)
  (let ((pair ((capture-open-pipe))) (configured? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (for-each (lambda (port) ((capture-fcntl) port F_SETFD FD_CLOEXEC))
                  (list (car pair) (cdr pair)))
        ((capture-fcntl) (car pair) F_SETFL
                         (logior O_NONBLOCK ((capture-fcntl) (car pair) F_GETFL)))
        (set! configured? #t)
        pair)
      (lambda ()
        (unless configured?
          ;; Closing one end must not prevent attempting the other.
          (dynamic-wind
            (lambda () #t)
            (lambda () (close-quietly (car pair)))
            (lambda () (close-quietly (cdr pair)))))))))
(define (pump-capture! capture)
  (unless (capture-eof? capture)
    (let ((bytes (make-bytevector 4096)))
      (call-with-values
          (lambda () (c-read (fileno (capture-port capture)) (bytevector->pointer bytes) 4096))
        (lambda (count errno)
          (cond
           ((zero? count) (set-capture-eof! capture #t))
           ((positive? count)
            (set-capture-bytes! capture (+ count (capture-bytes capture)))
            (when (> (capture-bytes capture) capture-limit)
              (fail "native child exceeded its 16 KiB stdout/stderr bound"))
            (let ((part (make-bytevector count)))
              (bytevector-copy! bytes 0 part 0 count)
              (set-capture-chunks! capture (cons part (capture-chunks capture)))))
           ((memv errno (list EINTR EAGAIN)) #f)
           (else (fail "terminal child-capture read failure"))))))))
(define (capture-text capture)
  (if (not capture) ""
      (catch #t
        (lambda ()
          (let ((bytes (make-bytevector (apply + (map bytevector-length (capture-chunks capture))))))
            (let loop ((parts (reverse (capture-chunks capture))) (offset 0))
              (if (null? parts) (utf8->string bytes)
                  (let ((n (bytevector-length (car parts))))
                    (bytevector-copy! (car parts) 0 bytes offset n)
                    (loop (cdr parts) (+ offset n)))))))
        (lambda _ "[non-UTF-8 child diagnostics]"))))
(define* (result status text diagnostic #:optional (started? #f) (cleaned? #f))
  `((status . ,status) (text . ,text)
    (execution-started? . ,started?) (cleanup-complete? . ,cleaned?)
    (diagnostic . ,(string-append "trusted-native-fixture: "
                                (substring diagnostic 0 (min 1024 (string-length diagnostic)))))))

(define (subreaper?)
  (let ((out (make-bytevector 4 0)))
    (unless (zero? (c-prctl 37 (pointer-address (bytevector->pointer out)) 0 0 0))
      (fail "PR_GET_CHILD_SUBREAPER unavailable"))
    (not (zero? (bytevector-s32-native-ref out 0)))))
(define (set-subreaper! enabled?)
  (unless (zero? (c-prctl 36 (if enabled? 1 0) 0 0 0))
    (fail "PR_SET_CHILD_SUBREAPER unavailable")))
(define (group-exists? pid)
  (catch 'system-error (lambda () (kill (- pid) 0) #t)
    (lambda args (not (= (system-error-errno args) ESRCH)))))
(define (process-start-time pid)
  (catch 'system-error
    (lambda ()
      (let* ((text (call-with-input-file (format #f "/proc/~a/stat" pid) get-string-all))
             (fields (string-tokenize (substring text (+ 2 (string-rindex text #\)))))))
        (list-ref fields 19)))
    (lambda args
      (if (= (system-error-errno args) ENOENT) #f (apply throw 'system-error args)))))
(define (require-owned-pid! pid identity)
  (let ((observed (process-start-time pid)))
    (when (and identity observed (not (equal? identity observed)))
      (fail "refusing a reused native process-group identity"))))
(define (signal-child! pid signal identity)
  ;; Before the stop handshake the process group may not exist yet. Both
  ;; identities are still owned children; the leader is not reused until reaped.
  (require-owned-pid! pid identity)
  (for-each (lambda (target)
              (catch 'system-error (lambda () (kill target signal))
                (lambda args
                  (unless (= (system-error-errno args) ESRCH)
                    (apply throw 'system-error args)))))
            (list (- pid) pid)))
(define (wait-child target options)
  (catch 'system-error (lambda () (waitpid target options))
    (lambda args
      (case (system-error-errno args)
        ((4) '(0 . 0)) ((10) #f) (else (apply throw 'system-error args))))))

(define (run-native source text guile runner protocol-directory timeout)
  (let* ((bytes (source-bytes source))
         (_ (bounded-text! text 2048 "preview input"))
         (_ (trusted-path guile #t)) (_ (trusted-path runner #f))
         (_ (trusted-path (string-append protocol-directory "/book-protocol.scm") #f))
         (deadline (+ (now) timeout))
         ;; Reserve cleanup inside the requested wall-clock budget.
         (work-deadline (- deadline (min 0.30 (/ timeout 4))))
         (old-subreaper (subreaper?))
         (root #f) (pid #f) (pid-identity #f) (leader-status #f) (leader-reaped? #f)
         (endpoint #f) (donation #f) (out #f) (err #f) (ports '())
         (answer #f) (initialized? #f) (protocol-eof? #f) (failure #f)
         (action-queued? #f) (action-dispatched? #f)
         (descendant? #f) (cleanup-failed? #f))
    (define (own-capture-pipe!)
      (let ((pair (capture-pipe)))
        ;; Publish each acquisition before attempting the next pipe or any
        ;; later setup that can throw. capture-pipe owns configuration failures.
        (set! ports (cons (car pair) (cons (cdr pair) ports)))
        pair))
    (define (pump-action!)
      (case (endpoint-pump-result-status (endpoint-pump-output! endpoint))
        ((drained budget would-block interrupted)
         ;; Budget is checked before queue emptiness by Book Session. A final
         ;; budget-limited send counts only with a fresh empty/live snapshot.
         (when action-queued?
           (let ((snapshot (host-session-snapshot endpoint)))
             (when (and (eq? (field snapshot "state") 'active)
                        (field snapshot "transport_open")
                        (zero? (field snapshot "outbound_frames"))
                        (zero? (field snapshot "outbound_bytes")))
               (set! action-dispatched? #t)))))
        (else (fail "ordinary session output failed"))))
    (define (reap!)
      (when pid
        (require-owned-pid! pid pid-identity)
        (let loop ((budget 64))
          (when (positive? budget)
            (let ((waited (wait-child (- pid) WNOHANG)))
              (when (and waited (positive? (car waited)))
                (if (= (car waited) pid)
                    (begin (set! leader-status (cdr waited)) (set! leader-reaped? #t))
                    (set! descendant? #t))
                (loop (- budget 1))))))))
    (define (stop!)
      (when pid
        (require-owned-pid! pid pid-identity)
        (unless (and leader-reaped? (not (group-exists? pid)))
          ;; Native execution is fixture-only. Kill the owned process group
          ;; rather than giving authored infinite loops an extra TERM grace.
          (if leader-reaped?
              (when (group-exists? pid) (kill (- pid) SIGKILL))
              (signal-child! pid SIGKILL pid-identity)))
        (let loop ()
          (reap!)
          ;; A child failing before setpgid is not in the new process group.
          (unless leader-reaped?
            (let ((waited (wait-child pid WNOHANG)))
              (when (and waited (positive? (car waited)))
                (set! leader-status (cdr waited)) (set! leader-reaped? #t))))
          (unless (and leader-reaped? (not (group-exists? pid)))
            (if (< (now) deadline) (begin (usleep 1000) (loop))
                (set! cleanup-failed? #t))))))
    (dynamic-wind
      (lambda () (set-subreaper! #t))
      (lambda ()
        (catch #t
          (lambda ()
            (set! root (mkdtemp "/tmp/opencode/workbench-preview.XXXXXX"))
            (chmod root #o700)
            (write-exclusive (string-append root "/program.scm") bytes #o400)
            (call-with-values
                (lambda () (open-session-endpoint! (make-book-session-host)
                                                   "workbench-trusted-native-fixture"))
              (lambda (e d) (set! endpoint e) (set! donation d)))
            (let* ((stdout (own-capture-pipe!)) (stderr (own-capture-pipe!))
                   (profile (dirname (dirname guile)))
                   (environment
                    (list "HOME=/nonexistent" "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
                          "GUILE_AUTO_COMPILE=0" "BOOK_SESSION_FD=3"
                          (string-append "PATH=" profile "/bin")
                          (string-append "GUILE_LOAD_PATH=" profile "/share/guile/site/3.0")
                          (string-append "GUILE_LOAD_COMPILED_PATH=" profile "/lib/guile/3.0/site-ccache"))))
              (set! out (make-capture (car stdout) 0 '() #f))
              (set! err (make-capture (car stderr) 0 '() #f))
              (set! pid
                    (spawn guile
                           (list guile "--no-auto-compile" "-L" protocol-directory
                                 runner "--trusted-native-fixture"
                                 (string-append root "/program.scm") guile protocol-directory)
                           #:search-path? #f #:environment environment
                           #:input donation #:output (cdr stdout) #:error (cdr stderr)))
              (close-quietly (cdr stdout)) (close-quietly (cdr stderr))
              (close-quietly donation) (set! donation #f))
            (let wait-stop ()
              (when (>= (now) work-deadline) (fail "timeout before native child ownership"))
              (let ((waited (wait-child pid (logior WUNTRACED WNOHANG))))
                (cond
                 ((and waited (zero? (car waited))) (usleep 1000) (wait-stop))
                 ((and waited (equal? (status:stop-sig (cdr waited)) SIGSTOP))
                  (set! pid-identity (process-start-time pid))
                  (unless pid-identity (fail "stopped child has no process identity"))
                  (kill pid SIGCONT))
                 (else
                  (when waited (set! leader-reaped? #t) (set! leader-status (cdr waited)))
                  (fail "native runner exited before its ownership handshake")))))
            (let loop ()
              (when (>= (now) work-deadline) (fail "preview wall-clock timeout"))
              (unless protocol-eof?
                (when (memq 'input (endpoint-ready-events endpoint))
                  (let ((pumped (endpoint-pump-input! endpoint)))
                    (case (endpoint-pump-result-status pumped)
                      ((committed)
                       (for-each
                        (lambda (value)
                          (cond
                            ((presented-text? value)
                             (unless action-dispatched? (fail "presentation before action delivery"))
                            (when answer (fail "duplicate preview result"))
                            (set! answer (presented-text-value value))
                            (bounded-text! answer 4096 "preview result"))
                           ((and (list? value) (equal? (field value "type") "initialize")
                                 (not initialized?))
                            (set! initialized? #t)
                            (endpoint-queue-message! endpoint value)
                             (endpoint-queue-message!
                              endpoint (host-action! endpoint "workbench-preview" text))
                             (set! action-queued? #t))
                           (else (fail "unexpected ordinary session result"))))
                        (endpoint-pump-result-values pumped)))
                      ((eof closed)
                       (set! protocol-eof? #t)
                       (unless answer (fail "child closed without a protocol result")))
                      ((would-block interrupted budget) #t)
                      (else (fail "ordinary session input failed"))))))
              (when (memq 'output (endpoint-ready-events endpoint))
                (pump-action!))
              (pump-capture! out) (pump-capture! err) (reap!)
              (when (and leader-reaped?
                         (or (not (equal? (status:exit-val leader-status) 0))
                             descendant? (group-exists? pid)))
                (fail "native runner failed or left descendants"))
              (unless (and leader-reaped? answer protocol-eof?
                           (capture-eof? out) (capture-eof? err))
                (usleep 1000) (loop))))
          (lambda (key . arguments)
            (set! failure (format #f "~a: ~s" key arguments)))))
      (lambda ()
        ;; Attempt every owned cleanup even when an earlier step failed. Do not
        ;; remove runtime evidence after an unproven process/descriptor cleanup.
        (define (cleanup procedure)
          (catch #t procedure
            (lambda (key . args)
              (set! cleanup-failed? #t)
              (unless failure (set! failure (format #f "cleanup ~a: ~s" key args))))))
        (cleanup (lambda () (when endpoint (release-session-endpoint! endpoint))))
        (cleanup (lambda () (close-quietly donation)))
        (cleanup stop!)
        (for-each (lambda (port) (cleanup (lambda () (close-quietly port)))) ports)
        (cleanup (lambda () (set-subreaper! old-subreaper)))
        (when (and root (not cleanup-failed?))
          (cleanup (lambda () (remove-owned-tree root deadline))))))
    (if (or failure cleanup-failed?)
        (result 'failed ""
                (string-append
                               (if cleanup-failed?
                                   (string-append "cleanup-incomplete"
                                                  (if root (string-append "; retained-root=" root) "")
                                                  "; ") "")
                               (or failure "cleanup exceeded wall-clock budget")
                                "\n" (capture-text err))
                 action-dispatched? (not cleanup-failed?))
        (result 'ok answer "ordinary protocol result, zero exit, captures drained; group reaped"
                action-dispatched? #t))))

(define* (preview-native source text #:key guile runner protocol-directory (timeout-seconds 3))
  "TRUSTED NATIVE FIXTURE ONLY. Return status/text/diagnostic; never use as a
runsc fallback. Timeout is positive and at most three seconds including the
reserved kill/reap/tree-cleanup window. Native code retains the caller's
filesystem rights. execution-started? reports host-observed delivery of the
initialize/action frames, not source completion. A cleanup deadline leaves the
remaining root for inspection."
  (catch #t
    (lambda ()
      (unless (and (real? timeout-seconds) (> timeout-seconds 0) (<= timeout-seconds 3))
        (fail "timeout must be positive and at most three seconds"))
      ;; Subreaper is process-wide; reject overlapping fixture calls, preserve
      ;; its previous value, and wait only on our process group (never wait -1).
      (unless (try-mutex native-mutex) (fail "a native preview is already running"))
      (dynamic-wind (lambda () #t)
                    (lambda () (run-native source text guile runner protocol-directory timeout-seconds))
                    (lambda () (unlock-mutex native-mutex))))
    (lambda (key . args) (result 'failed "" (format #f "~a: ~s" key args)))))

;;; OCI preparation. Resolve only the installed trusted base module, never a
;;; module/path named by source bytes. No runtime is executed by this API.
(define (base name)
  (resolve-interface '(oci-bundle))
  (module-ref (resolve-module '(oci-bundle)) name))
(define (replace-field object key value)
  (map (lambda (entry) (if (equal? (car entry) key) (cons key value) entry)) object))
(define (sha256-hex bytes)
  (string-concatenate (map (lambda (byte) (format #f "~2,'0x" byte))
                           (bytevector->u8-list (sha256 bytes)))))
(define (immutable-source raw closure store)
  ;; Same fixed-source restriction as the accepted protocol generator. The new
  ;; authored resource is a distinct exclusively created snapshot, not an
  ;; exception for caller-selected files to this immutable-source validator.
  (let* ((path ((base 'canonical-existing) raw "immutable Workbench adapter source"))
         (item ((base 'store-item) path store "immutable Workbench adapter source")))
    (unless (and (string=? path item) (not (member item closure)))
      (fail "runner/protocol must be distinct top-level store files outside the language closure"))
    (let ((info ((base 'require-type) path 'regular "immutable adapter source")))
      (unless (zero? (logand (stat:mode info) #o222))
        (fail "immutable adapter source is writable")))
    path))
(define (workbench-preview-launch-argv bundle container-id)
  ;; Preserve every base isolation-userns runtime flag; only add the reviewed
  ;; ordinary Book Protocol socket donation to its fixed `run` command.
  (append-map (lambda (argument)
                (if (string=? argument "run") '("run" "--pass-fd=3:3") (list argument)))
              ((base 'make-launch-argv) bundle container-id "isolation-userns")))

(define* (generate-workbench-preview-bundle
          #:key source profile-input runner-input protocol-input blocking-input
          bundle-input container-id requisites-runner (store-root "/gnu/store") cleanup-deadline
          (editor? #f))
  "Prepare (do not run) a no-state Guile preview bundle. All paths and the
closure reader are trusted broker inputs. SOURCE is bounded UTF-8 data. Return
the exclusively created bundle directory; an existing destination is refused.
CLEANUP-DEADLINE, when supplied by an execution owner, bounds failure cleanup
using that owner's original monotonic deadline; expiration retains the root."
  (unless (boolean? editor?) (fail "editor variant must be boolean"))
  (let* ((bytes (source-bytes source))
         (store ((base 'canonical-store-root) store-root))
         (profile ((base 'validate-profile) profile-input store))
         (closure ((base 'validate-requisites) (requisites-runner profile) profile store))
         (sources (map (lambda (path) (immutable-source path closure store))
                        (list runner-input protocol-input blocking-input))))
    (when (and editor? (> (bytevector-length bytes) 8192))
      (fail "editor source exceeds 8192 bytes"))
    ((base 'validate-profile-entry) profile closure store "guile")
    ((base 'validate-profile-entry) profile closure store "python3")
    ((base 'validate-container-id) container-id)
    (unless (= (length (delete-duplicates sources string=?)) 3)
      (fail "runner/protocol sources must be distinct"))
    (let* ((bundle ((base 'validate-bundle-destination) bundle-input store))
           (parent (lstat (dirname bundle))) (owned #f)
           (snapshot (string-append bundle "/program.scm")))
      (catch #t
        (lambda ()
          ((base 'mkdir-mode) bundle #o700)
          (set! owned (lstat bundle))
          (let ((after (lstat (dirname bundle))))
            (unless (and (= (stat:dev parent) (stat:dev after))
                         (= (stat:ino parent) (stat:ino after)))
              (fail "bundle parent identity changed")))
          (write-exclusive snapshot bytes #o444)
          (let* ((spec ((base 'make-spec) profile closure snapshot container-id))
                 (process (field spec "process"))
                 (linux (field spec "linux"))
                 (destinations (list "/book/runner.scm" "/book/modules/book-protocol.scm"
                                     "/book/modules/book-protocol/blocking-io.scm"))
                 (mounts (vector->list (field spec "mounts"))))
            ;; Replace only the compatibility fixture's one selected input
            ;; destination; all inherited namespace/device/scratch restrictions
            ;; and exactly the selected language closure remain in force.
            (set! mounts
                  (map (lambda (mount)
                         (if (equal? (field mount "destination") "/book/input")
                             (replace-field mount "destination" "/book/program.scm") mount)) mounts))
            (set! mounts (append mounts
                                 (map (lambda (path destination)
                                        ((base 'bind-mount) path destination #:noexec? #t))
                                      sources destinations)))
            (set! process
                  (replace-field process "args"
                                 #("/profile/bin/guile" "--no-auto-compile" "-L" "/book/modules"
                                   "/book/runner.scm" "--sandbox")))
            (set! process
                  (replace-field process "env"
                    #("HOME=/scratch" "LANG=C.UTF-8" "LC_ALL=C.UTF-8" "PATH=/profile/bin"
                      "TMPDIR=/scratch" "BOOK_SESSION_FD=3" "GUILE_AUTO_COMPILE=0"
                      "GUILE_LOAD_PATH=/profile/share/guile/site/3.0"
                      "GUILE_LOAD_COMPILED_PATH=/profile/lib/guile/3.0/site-ccache")))
            (set! process
                  (replace-field process "rlimits"
                    (list->vector
                     (append (vector->list (field process "rlimits"))
                              ;; gVisor accounts approximate runnable-task CPU
                              ;; ticks during interpreter startup too. Two seconds
                              ;; can kill Guile before hello; see PREVIEW.md.
                               (if editor? '()
                                   '((("type" . "RLIMIT_CPU") ("soft" . 10) ("hard" . 10))))
                               '((("type" . "RLIMIT_NPROC") ("soft" . 32) ("hard" . 32)))))))
            ;; Requested OCI cgroup limits include runsc support-process costs.
             ;; Guest task enforcement and these limits still require runsc/QEMU
             ;; execution tests; configuration is not evidence of enforcement.
             ;; The 46-path ARM closure needs 51 LisaFS connections: at two
             ;; channels each, their socket/channel/watchdog waits alone can use
             ;; 204 host tasks. 256 leaves 52 for other runtime work; see PREVIEW.md.
            (set! linux (cons '("resources" .
                                (("memory" . (("limit" . 268435456)))
                                 ("cpu" . (("period" . 100000) ("quota" . 50000)))
                                  ("pids" . (("limit" . 256))))) linux))
            (set! spec (replace-field (replace-field (replace-field spec "process" process)
                                                     "linux" linux)
                                      "mounts" (list->vector mounts)))
            ((base 'make-rootfs) (string-append bundle "/rootfs") profile closure)
            ((base 'mkdir-mode) (string-append bundle "/rootfs/book/modules") #o755)
            ((base 'mkdir-mode) (string-append bundle "/rootfs/book/modules/book-protocol") #o755)
            (for-each (lambda (destination)
                        ((base 'touch-mode) (string-append bundle "/rootfs" destination) #o444))
                      (cons "/book/program.scm" destinations))
            (for-each (lambda (name) ((base 'mkdir-mode) (string-append bundle "/" name) #o700))
                      '("runsc-state" "supervisor-tmp" "runsc-debug" "runsc-panic"))
            ((base 'write-json) (string-append bundle "/config.json") spec)
            ((base 'write-json) (string-append bundle "/launch.json")
             `(("argv" . ,(list->vector (workbench-preview-launch-argv bundle container-id)))
                ("claim" . ,(if editor? "workbench-editor-preparation-only"
                                "workbench-preview-preparation-only"))
               ("cgroupsPath" . ,(field linux "cgroupsPath"))
               ("executionProfile" . "isolation-userns")
                ("fixtureKind" . ,(if editor? "workbench-guile-editor" "workbench-guile-preview"))
               ("guestProtocolFd" . 3)
               ("requiredKernelConfig" . #("CONFIG_USER_NS=y"))
               ("sourceSha256" . ,(sha256-hex bytes))
               ("sourceBytes" . ,(bytevector-length bytes))
               ("supervisorEnv" . ,(field ((base 'make-launch-record) bundle container-id
                                            "isolation-userns") "supervisorEnv"))
               ("supervisorUid" . 0))))
          bundle)
        (lambda (key . args)
          (let ((current (exists bundle)))
            (when (and owned current (= (stat:dev owned) (stat:dev current))
                       (= (stat:ino owned) (stat:ino current)))
              (remove-owned-tree bundle cleanup-deadline)))
          (apply throw key args))))))
