;;; Executable native fixture tests and separate OCI configuration tests.
;;; Invoke with native supervisor Guile and explicit project module paths;
;;; BOOK_WORKBENCH_GUILE (or GUILE_TEST) names that same supervisor's bin/guile,
;;; not a base Guile symlink.
(use-modules (workbench-preview)
             (ice-9 ftw)
             (json)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(define here (dirname (canonicalize-path (car (command-line)))))
(define guile (or (getenv "BOOK_WORKBENCH_GUILE") (getenv "GUILE_TEST")
                  "/gnu/store/3xw1bj8vzhq8cnikbqa9xm7g3zh3sv5c-wilkbook-book-state-device-supervisor/bin/guile"))
(define protocol (canonicalize-path (string-append here "/../book-protocol")))
(define runner (string-append here "/workbench-runner.scm"))
(define seed (call-with-input-file (string-append here "/seed.scm") get-string-all))
(define test-root (mkdtemp "/tmp/opencode/workbench-preview-tests.XXXXXX"))
(chmod test-root #o700)
(define remove-tree (@@ (workbench-preview) remove-owned-tree))
(define (read-text path) (call-with-input-file path get-string-all))
(define (write-text path text)
  (call-with-output-file path (lambda (port) (display text port))))
(define (field value name) (assoc-ref value name))
(define (clock) (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(define* (preview source #:optional (text "sample") #:key (timeout 3) (program runner))
  (preview-native source text #:guile guile #:runner program
                  #:protocol-directory protocol #:timeout-seconds timeout))
(define (failure label source)
  (let ((result (preview source)))
    (test-equal label 'failed (field result 'status))
    (test-equal (string-append label " has no usable result") "" (field result 'text))))
(define (rejected? procedure)
  (catch #t (lambda () (procedure) #f) (lambda _ #t)))
(define (live? pid)
  (catch 'system-error (lambda () (kill pid 0) #t) (lambda _ #f)))
(define (private-roots)
  (scandir "/tmp/opencode"
           (lambda (name) (string-prefix? "workbench-preview." name))))
(define roots-before (private-roots))
(define subreaper-before ((@@ (workbench-preview) subreaper?)))
(define cleanup-clock (@@ (workbench-preview) cleanup-clock))
(define cleanup-read-directory (@@ (workbench-preview) cleanup-read-directory))
(define capture-open-pipe (@@ (workbench-preview) capture-open-pipe))
(define capture-fcntl (@@ (workbench-preview) capture-fcntl))
(define (fd-closed? fd)
  (catch 'system-error (lambda () (fcntl fd F_GETFD) #f)
    (lambda args
      (if (= (system-error-errno args) EBADF) #t (apply throw 'system-error args)))))
(define (open-fds)
  (sort (filter-map (lambda (name)
                     (let ((fd (string->number name)))
                       (and fd (not (fd-closed? fd)) fd)))
                   (scandir "/proc/self/fd")) <))

(set! test-log-to-file #f)
(test-begin "workbench-preview")
(dynamic-wind
  (lambda () #t)
  (lambda ()
    (display "Evidence mode: trusted-native-fixture (no runsc, no containment claim)\n")
    (let ((result (preview seed "你好")))
      (test-equal "seed executes through ordinary protocol" 'ok (field result 'status))
      (test-equal "exact child result" "Workbench: 你好" (field result 'text))
      (test-eq "successful execution has host-observed action delivery" #t
        (field result 'execution-started?))
      (test-eq "successful execution has proven cleanup" #t
        (field result 'cleanup-complete?))
      (test-assert "native mode cannot be confused with sandbox proof"
        (string-prefix? "trusted-native-fixture:" (field result 'diagnostic))))
    (test-equal "editing source changes executable behavior" "SAMPLE"
      (field (preview "(define (workbench text) (string-upcase text))") 'text))
    ;; Exercise the real bounded output pump, including final-budget emptiness
    ;; and transport closure that clears pending frames without delivering them.
    (let* ((session (resolve-module '(book-session)))
           (pump (module-ref session 'endpoint-pump-output!))
           (byte-budget (module-ref session 'max-output-bytes-per-pump))
           (frame-budget (module-ref session 'max-output-frames-per-pump)))
      (for-each
       (lambda (mode)
         (let ((partial? #f) (final-budget? #f) (pumps 0))
           (dynamic-wind
             (lambda ()
               (module-set! session 'max-output-bytes-per-pump
                            (if (memq mode '(partial closed-after-budget)) 1 byte-budget))
               (module-set! session 'max-output-frames-per-pump (if (eq? mode 'final-budget) 1 frame-budget))
               (module-set! session 'endpoint-pump-output!
                 (lambda (endpoint)
                   (set! pumps (+ pumps 1))
                   (when (eq? mode 'broken-write)
                     ;; A real socket write failure before any queued byte.
                     (shutdown ((@@ (book-session) endpoint-binding-socket)
                                ((@@ (book-session) session-endpoint-binding) endpoint)) 1))
                   (let* ((pumped (pump endpoint))
                          (status ((@ (book-session) endpoint-pump-result-status) pumped))
                          (snapshot ((@ (book-session) host-session-snapshot) endpoint)))
                     (when (eq? status 'budget)
                       (if (positive? (field snapshot "outbound_frames")) (set! partial? #t)
                           (set! final-budget? #t)))
                     (if (memq mode '(partial closed-after-budget))
                         (begin ((@ (book-session) close-session!) endpoint)
                                (if (eq? mode 'partial) (pump endpoint) pumped))
                         pumped)))))
             (lambda ()
               (let ((value (preview "(define (workbench text)")))
                 (test-assert (format #f "native ~a reached queued output" mode) (positive? pumps))
                 (test-equal (format #f "native ~a fails" mode) 'failed (field value 'status))
                 (test-equal (format #f "native ~a delivery evidence" mode) (eq? mode 'final-budget)
                   (field value 'execution-started?))
                 (test-equal (format #f "native ~a cleanup independent" mode) #t (field value 'cleanup-complete?))
                 (when (memq mode '(partial closed-after-budget))
                   (test-assert "native partial byte budget left unsent frames" partial?))
                 (when (eq? mode 'final-budget)
                   (test-assert "native final send hit budget with empty queue" final-budget?))))
             (lambda ()
               (module-set! session 'endpoint-pump-output! pump)
               (module-set! session 'max-output-bytes-per-pump byte-budget)
               (module-set! session 'max-output-frames-per-pump frame-budget)))))
       '(broken-write partial closed-after-budget final-budget)))
    (test-equal "stdin is EOF, not an alias of the Book Session socket" "sample"
      (field (preview "(define (workbench text) (if (eof-object? (read-char)) text \"wrong stdin\"))") 'text))
    (test-equal "exact stdout capture limit succeeds" 'ok
      (field (preview "(define (workbench text) (display (make-string 16384 #\\x)) (force-output) text)") 'status))
    (test-equal "exact input byte bound" 'ok
      (field (preview "(define (workbench text) text)" (make-string 2048 #\x)) 'status))
    (let* ((text (make-string 2048 (integer->char 1)))
           (value (preview "(define (workbench text) text)" text)))
      (test-equal "escaped input crosses production output byte budget intact" text (field value 'text))
      (test-equal "multi-pump input has delivery evidence" #t (field value 'execution-started?)))
    (test-equal "exact result byte bound" 4096
      (string-length
       (field (preview "(define (workbench text) (make-string 4096 #\\x))") 'text)))
    (let ((code "(define (workbench text) text)\n;"))
      (test-equal "exact 16 KiB source limit" 'ok
        (field (preview (string-append code (make-string (- 16384 (string-length code)) #\x)))
               'status)))
    (for-each
     (lambda (pair) (failure (car pair) (cdr pair)))
     `(("syntax error" . "(define (workbench text)")
       ("missing function" . "(define other 1)")
       ("wrong arity" . "(define (workbench) \"wrong\")")
       ("non-text result" . "(define (workbench text) 17)")
       ("empty result" . "(define (workbench text) \"\")")
       ("oversized result" . "(define (workbench text) (make-string 4097 #\\x))")
       ("result byte bound is UTF-8 not characters" . "(define (workbench text) (make-string 2049 #\\é))")
       ("result NUL" . "(define (workbench text) (string #\\nul))")
       ("empty source" . "")
       ("oversized source" . ,(make-string 16385 #\x))
       ("oversized bytevector source" . ,(make-bytevector 16385 65))
       ("source byte bound is UTF-8 not characters" . ,(make-string 8193 #\é))
       ("source NUL" . ,(string-append seed (string #\nul)))
       ("invalid UTF-8 source" . ,(u8-list->bytevector '(195 40)))
       ("stdout is not a protocol result" . "(display \"SUCCESS\") (force-output) (primitive-exit 0)")
       ("stdout overflow" . "(define (workbench text) (display (make-string 20000 #\\x)) (force-output) text)")
       ("stderr overflow" . "(define (workbench text) (display (make-string 20000 #\\x) (current-error-port)) (force-output (current-error-port)) text)")
       ("malformed Book Protocol" . "(use-modules (rnrs io ports)) (put-bytevector (fdopen 3 \"w0\") #vu8(0 0 0 1 33)) (force-output) (define (workbench text) text)")))
    (test-equal "empty input is rejected by unchanged ordinary contract" 'failed
      (field (preview seed "") 'status))
    (test-eq "preflight refusal is not an executed failure" #f
      (field (preview seed "") 'execution-started?))
    (test-equal "oversized input" 'failed
      (field (preview seed (make-string 2049 #\x)) 'status))
    (test-equal "input byte bound is UTF-8 not characters" 'failed
      (field (preview seed (make-string 1025 #\é)) 'status))
    (test-equal "invalid timeout is not silently expanded" 'failed
      (field (preview seed #:timeout 4) 'status))
    (let* ((start (clock))
           (result (preview "(define (workbench text) (let loop () (loop)))" #:timeout 0.7)))
      (test-equal "infinite loop fails" 'failed (field result 'status))
      (test-eq "timed-out execution reached its handshake" #t (field result 'execution-started?))
      (test-eq "timed-out execution was cleaned up" #t (field result 'cleanup-complete?))
      (test-assert "loop is wall-clock bounded including reap" (< (- (clock) start) 1.2))
      (test-assert "timeout has a diagnostic" (string-contains (field result 'diagnostic) "timeout")))
    ;; Native fixture source writes its own PID to prove where evaluation ran.
    (let* ((path (string-append test-root "/child-pid"))
           (source (format #f "(call-with-output-file ~s (lambda (p) (display (getpid) p))) (define (workbench text) text)" path)))
      (test-equal "top-level authored code runs successfully in child" 'ok
        (field (preview source) 'status))
      (let ((pid (string->number (read-text path))))
        (test-assert "authored source never evaluated in broker" (not (= pid (getpid))))
        (test-assert "native leader was reaped" (not (live? pid)))))
    ;; A presentation plus exit 0 is insufficient if a descendant outlives the
    ;; leader. SIGTERM resistance exercises group kill and subreaper waitpid.
    (let* ((path (string-append test-root "/descendant-pid"))
           (source
            (format #f
             "(define (workbench text) (let ((pid (primitive-fork))) (if (zero? pid) (begin (sigaction SIGTERM SIG_IGN) (let loop () (sleep 1) (loop))) (begin (call-with-output-file ~s (lambda (p) (display pid p))) text))))" path)))
      (test-equal "leftover descendant invalidates preview" 'failed (field (preview source) 'status))
      (test-assert "descendant is killed and reaped" (not (live? (string->number (read-text path))))))
    (let* ((path (string-append test-root "/exit7-runner.scm"))
           (text (read-text runner))
           (needle "    (close-port port)))")
           (where (string-contains text needle)))
      (unless where (error "runner zero-exit fixture join changed"))
      (write-text path (string-append (substring text 0 where)
                                     "    (close-port port) (primitive-exit 7)))"
                                     (substring text (+ where (string-length needle)))))
      (test-equal "valid present followed by nonzero exit fails" 'failed
        (field (preview seed #:program path) 'status)))

    ;; Advance a deterministic clock only when readdir yields an actual entry.
    ;; The third entry exhausts the deadline. Holding the directory object also
    ;; prevents a GC finalizer from masking a missing closedir in the unwind.
    (let ((tree (string-append test-root "/deadline-tree"))
          (time 0) (reads 0) (directories '()) (fds-before (open-fds)))
      (mkdir tree)
      (for-each (lambda (index)
                  (write-text (string-append tree "/" (number->string index)) "owned\n"))
                (iota 20))
      (let ((outcome
             (parameterize
                 ((cleanup-clock (lambda () time))
                  (cleanup-read-directory
                   (lambda (directory)
                     (unless (memq directory directories)
                       (set! directories (cons directory directories)))
                     (let ((name (readdir directory)))
                       (unless (or (eof-object? name) (member name '("." "..")))
                         (set! reads (+ reads 1))
                         (set! time reads))
                       name))))
               (catch 'workbench-preview-cleanup-incomplete
                 (lambda () (remove-tree tree 3) 'unexpected-completion)
                 (lambda (key . _) key)))))
        (test-equal "tree cleanup reports deadline exhaustion"
          'workbench-preview-cleanup-incomplete outcome)
        (test-equal "incremental traversal stops at the deadline entry" 3 reads)
        (test-assert "deadline retains the runtime root" (file-exists? tree))
        (test-equal "unvisited entries remain rather than being eagerly enumerated/deleted" 18
          (length (scandir tree (lambda (name) (not (member name '("." "..")))))))
        (test-equal "deadline unwind closes its still-referenced directory descriptor"
          fds-before (open-fds))
        (test-equal "regression held the real opened directory" 1 (length directories)))
      (remove-tree tree)
      (test-assert "trusted no-deadline cleanup remains available" (not (file-exists? tree))))

    ;; A successful protocol/child result must still fail when runtime deletion
    ;; cannot finish within the ORIGINAL absolute preview deadline.
    (let* ((outcome (parameterize ((cleanup-clock (lambda () (+ (clock) 10))))
                      (preview seed)))
           (diagnostic (field outcome 'diagnostic))
           (roots
            (filter-map
             (lambda (part)
               (let ((part (string-trim-both part)) (prefix "retained-root="))
                 (and (string-prefix? prefix part)
                      (substring part (string-length prefix)))))
             (string-split diagnostic #\;))))
      (test-equal "native preview passes its deadline to tree cleanup" 'failed (field outcome 'status))
      (test-equal "incomplete cleanup cannot return usable preview text" "" (field outcome 'text))
      (test-eq "incomplete cleanup is not an accepted executed-failure receipt" #f
        (field outcome 'cleanup-complete?))
      (test-assert "incomplete cleanup is explicit in the result"
        (string-contains diagnostic "cleanup-incomplete"))
      (test-equal "incomplete cleanup reports one retained root" 1 (length roots))
      (when (= (length roots) 1)
        (test-assert "reported root and untouched snapshot are retained"
          (file-exists? (string-append (car roots) "/program.scm")))
        (remove-tree (car roots))))

    ;; Fault-injected pipe acquisition retains strong references to BOTH port
    ;; objects and their integer descriptors. No gc call or loss of references
    ;; can accidentally turn a leak into a passing closed-descriptor assertion.
    (let ((calls 0) (pairs '()) (fds '()))
      (let ((outcome
             (parameterize
                 ((capture-open-pipe
                   (lambda ()
                     (set! calls (+ calls 1))
                     (when (= calls 2) (throw 'fixture-second-pipe-error))
                     (let ((pair (pipe)))
                       (set! pairs (cons pair pairs))
                       (set! fds (append (list (fileno (car pair)) (fileno (cdr pair))) fds))
                       pair))))
               (preview seed))))
        (test-equal "second capture pipe failure is reported" 'failed (field outcome 'status))
        (test-equal "second-pipe regression reached the intended acquisition" 2 calls)
        (test-equal "first successful pair was retained by the regression" 1 (length pairs))
        (test-assert "second-pipe failure closes both first-pipe descriptors without GC"
          (every fd-closed? fds))
        (test-assert "first pair's still-referenced Scheme ports were explicitly closed"
          (every (lambda (pair) (and (port-closed? (car pair)) (port-closed? (cdr pair)))) pairs))))
    ;; Four fcntl operations configure each pair. Exercise failures at every
    ;; operation on both the first and second pair, including F_GETFL/F_SETFL.
    (for-each
     (lambda (fail-at)
       (let ((calls 0) (pairs '()) (fds '()))
         (let ((outcome
                (parameterize
                    ((capture-open-pipe
                      (lambda ()
                        (let ((pair (pipe)))
                          (set! pairs (cons pair pairs))
                          (set! fds (append (list (fileno (car pair)) (fileno (cdr pair))) fds))
                          pair)))
                     (capture-fcntl
                      (lambda arguments
                        (set! calls (+ calls 1))
                        (when (= calls fail-at) (throw 'fixture-capture-fcntl-error fail-at))
                        (apply fcntl arguments))))
                  (preview seed))))
           (test-equal (format #f "fcntl fault ~a is reported" fail-at) 'failed (field outcome 'status))
           (test-equal (format #f "fcntl fault ~a reached the intended operation" fail-at) fail-at calls)
           (test-equal (format #f "fcntl fault ~a held every acquired pair" fail-at)
             (if (<= fail-at 4) 1 2) (length pairs))
           (test-assert (format #f "fcntl fault ~a closes all numeric descriptors without GC" fail-at)
             (every fd-closed? fds))
           (test-assert (format #f "fcntl fault ~a explicitly closes all referenced ports" fail-at)
             (every (lambda (pair) (and (port-closed? (car pair)) (port-closed? (cdr pair)))) pairs)))))
     (iota 8 1))
    (test-equal "native tests leave no private run roots" roots-before (private-roots))
    (test-equal "native fixture restores caller subreaper setting" subreaper-before
      ((@@ (workbench-preview) subreaper?)))

    (display "Evidence mode: OCI preparation policy only (gVisor not executed)\n")
    (let* ((store (string-append test-root "/store"))
           (prefix (make-string 32 #\a))
           (profile (string-append store "/" prefix "-languages"))
           (runner-source (string-append store "/" prefix "-runner.scm"))
           (codec-source (string-append store "/" prefix "-codec.scm"))
           (blocking-source (string-append store "/" prefix "-blocking.scm"))
           (bundle (string-append test-root "/bundle")))
      (mkdir store) (mkdir profile) (mkdir (string-append profile "/bin"))
      (write-text (string-append profile "/manifest") "test-only manifest\n")
      (for-each (lambda (name)
                  (let ((path (string-append profile "/bin/" name)))
                    (write-text path "not an executable test\n") (chmod path #o555)))
                '("guile" "python3"))
      (for-each (lambda (path text) (write-text path text) (chmod path #o444))
                (list runner-source codec-source blocking-source)
                (list (read-text runner) "; codec fixture\n" "; blocking fixture\n"))
      (define* (generate destination #:optional (selected runner-source) (source seed))
        (generate-workbench-preview-bundle
         #:source source #:profile-input profile #:runner-input selected
         #:protocol-input codec-source #:blocking-input blocking-source
         #:bundle-input destination #:container-id "workbench-preview-test"
         #:requisites-runner (lambda (_) (list profile)) #:store-root store))
      (test-equal "exclusive new-source bundle generated" bundle (generate bundle))
      (let* ((spec (call-with-input-file (string-append bundle "/config.json") json->scm))
             (launch (call-with-input-file (string-append bundle "/launch.json") json->scm))
             (mounts (vector->list (field spec "mounts")))
             (snapshot (find (lambda (mount) (equal? (field mount "destination") "/book/program.scm")) mounts))
             (process (field spec "process"))
             (resources (field (field spec "linux") "resources")))
        (test-equal "source snapshot has exact bytes" seed (read-text (string-append bundle "/program.scm")))
        (test-equal "source snapshot has one link" 1 (stat:nlink (lstat (string-append bundle "/program.scm"))))
        (test-equal "source snapshot is read-only" #o444 (logand #o777 (stat:mode (lstat (string-append bundle "/program.scm")))))
        (test-equal "snapshot is fixed-path read-only/noexec mount"
          '("bind" "ro" "nosuid" "nodev" "noexec") (vector->list (field snapshot "options")))
        (test-equal "only three base mounts, closure and four sources" 8 (length mounts))
        (test-assert "no database, whole store, live workspace or UI mount"
          (every (lambda (mount)
                   (not (member (field mount "destination")
                                '("/data" "/run" "/gnu/store" "/var/lib" "/workspace")))) mounts))
        (test-equal "fixed sandbox runner command"
          '("/profile/bin/guile" "--no-auto-compile" "-L" "/book/modules" "/book/runner.scm" "--sandbox")
          (vector->list (field process "args")))
        (test-equal "nonroot" 65534 (field (field process "user") "uid"))
        (test-equal "read-only root" #t (field (field spec "root") "readonly"))
        (test-equal "256 MiB memory limit" 268435456 (field (field resources "memory") "limit"))
        (test-equal "half CPU quota" 50000 (field (field resources "cpu") "quota"))
        (test-equal "256 host tasks including LisaFS startup headroom" 256 (field (field resources "pids") "limit"))
        (test-assert "guest task and CPU rlimits requested"
          (every (lambda (name)
                   (find (lambda (limit) (equal? (field limit "type") name))
                         (vector->list (field process "rlimits")))) '("RLIMIT_CPU" "RLIMIT_NPROC")))
        (test-equal "source bytes bound in launch metadata"
          (bytevector-length (string->utf8 seed)) (field launch "sourceBytes"))
        (test-equal "ten-second guest CPU rlimit, both soft and hard"
          '(10 10)
          (let ((limit (find (lambda (limit) (equal? (field limit "type") "RLIMIT_CPU"))
                            (vector->list (field process "rlimits")))))
            (list (field limit "soft") (field limit "hard"))))
        (test-equal "guest NPROC remains 32, both soft and hard"
          '(32 32)
          (let ((limit (find (lambda (limit) (equal? (field limit "type") "RLIMIT_NPROC"))
                            (vector->list (field process "rlimits")))))
            (list (field limit "soft") (field limit "hard"))))
        (test-equal "SHA256 formatting includes leading zero nibbles"
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          ((@@ (workbench-preview) sha256-hex) (string->utf8 "abc")))
        (test-equal "new record does not claim runtime evidence"
          "workbench-preview-preparation-only" (field launch "claim"))
        (test-equal "launch argv is exactly regenerable"
          (workbench-preview-launch-argv bundle "workbench-preview-test")
          (vector->list (field launch "argv")))
        (for-each
         (lambda (flag)
           (test-assert (string-append "inherited runtime flag " flag)
             (member flag (vector->list (field launch "argv")))))
         '("--platform=systrap" "--network=none" "--host-uds=none" "--directfs=false"
           "--ignore-cgroups=false" "--pass-fd=3:3")))
      (test-assert "existing bundle is refused and preserved" (rejected? (lambda () (generate bundle))))
      (test-equal "refusal preserved source" seed (read-text (string-append bundle "/program.scm")))
      (test-assert "non-store runner is refused"
        (rejected? (lambda () (generate (string-append test-root "/bad-native-runner") runner))))
      (test-assert "malformed new source fails before claiming bundle"
        (rejected? (lambda () (generate (string-append test-root "/bad-source") runner-source
                                       (string-append seed (string #\nul))))))
      (test-assert "no partial bundle on source failure"
        (not (file-exists? (string-append test-root "/bad-source"))))
      (chmod runner-source #o644)
      (test-assert "writable supposedly immutable runner rejected"
        (rejected? (lambda () (generate (string-append test-root "/bad-mode")))))
      (chmod runner-source #o444)
      (let ((link (string-append store "/" prefix "-linked.scm")))
        (symlink runner-source link)
        (test-assert "linked immutable source rejected"
          (rejected? (lambda () (generate (string-append test-root "/bad-link") link)))))))
  (lambda () (remove-tree test-root)))
(let ((runner (test-runner-current)))
  (test-end "workbench-preview")
  (exit (if (zero? (test-runner-fail-count runner)) 0 1)))
