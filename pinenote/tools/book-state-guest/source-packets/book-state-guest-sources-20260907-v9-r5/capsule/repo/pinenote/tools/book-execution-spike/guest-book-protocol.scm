;;; In-guest Guile authority for the first real Book Protocol-through-runsc
;;; gate.  This is a fixed test adapter, not a general broker or book launcher.
(define-module (guest-book-protocol)
  #:use-module (book-protocol)
  #:use-module (book-protocol blocking-io)
  #:use-module (book-session)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt random)
  #:use-module (guest-smoke)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module ((rnrs io ports)
                #:select (get-bytevector-some get-u8 put-u8 put-bytevector))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (guest-book-protocol-main
            run-protocol-pair!
            run-protocol-self-tests!))

(define whole-run-timeout-seconds 360.0)
(define host-test-timeout-seconds 15.0)
(define term-grace-seconds 3.0)
(define scheduler-sleep-microseconds 5000)
(define guest-fd 3)
(define expected-language-closure-count 45)
(define max-capture-bytes (* 4 1024 1024))
(define max-runtime-state-diagnostic-entries 4)
(define max-runtime-state-diagnostic-mounts-per-entry 2)
(define max-runtime-state-diagnostic-root-mounts 2)
(define accepted-language-closure-sha256
  "48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc")
(define accepted-source-sha256
  '(("guest-smoke.scm"
     . "74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa")
    ("oci-bundle.scm"
     . "a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c")
    ("book-protocol.scm"
     . "91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44")
    ("blocking-io.scm"
     . "543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd")
    ("book_protocol.py"
     . "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735")
    ("book-session.scm"
     . "f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668")
    ("oci-book-bundle.scm"
     . "c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7")
    ("guest-protocol-book.scm"
     . "9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a")
    ("guest_protocol_book.py"
     . "b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0")))
(define source-provenance-checked? #f)

(define guile-action-specs
  '(("guile-transform-1" "Ada")
    ("guile-transform-2" "élan λ")))
(define python-action-specs
  '(("python-transform-1" "Grace")
    ("python-transform-2" "東京")))

(define (guile-computed-text input)
  (format #f "GUILE[~a]:~a" (string-length input) (string-upcase input)))

(define (python-computed-text input)
  (format #f "PYTHON[~a]:~a"
          (string-length input)
          (list->string (reverse (string->list input)))))

(define (make-nonce-actions specifications language-tag compute)
  (let ((actions
         (map (lambda (specification)
                (let ((input
                       (string-append
                        (cadr specification) "|nonce=" language-tag "-"
                        (random-token 12 'strong))))
                  (list (car specification) input (compute input))))
              specifications)))
    (unless (= (length actions)
               (length (delete-duplicates (map cadr actions) string=?)))
      (fail "strong nonce source repeated an action input"))
    actions))

(define %smoke-module (resolve-module '(guest-smoke)))
(define (smoke-private name)
  (module-ref %smoke-module name))

(define-record-type <owned-runsc>
  (make-owned-runsc name pid start-time process-group record-path captures
                    status finalized?)
  owned-runsc?
  (name owned-runsc-name)
  (pid owned-runsc-pid)
  (start-time owned-runsc-start-time)
  (process-group owned-runsc-process-group)
  (record-path owned-runsc-record-path)
  (captures owned-runsc-captures)
  (status owned-runsc-status set-owned-runsc-status!)
  (finalized? owned-runsc-finalized? set-owned-runsc-finalized?!))

(define-record-type <bounded-capture>
  (make-bounded-capture stream input output observed-bytes retained-bytes
                        overflow? eof?)
  bounded-capture?
  (stream bounded-capture-stream)
  (input bounded-capture-input)
  (output bounded-capture-output)
  (observed-bytes bounded-capture-observed-bytes
                  set-bounded-capture-observed-bytes!)
  (retained-bytes bounded-capture-retained-bytes
                  set-bounded-capture-retained-bytes!)
  (overflow? bounded-capture-overflow? set-bounded-capture-overflow?!)
  (eof? bounded-capture-eof? set-bounded-capture-eof?!))

(define-record-type <protocol-command-result>
  (make-protocol-command-result status stdout-observed-bytes
                                stderr-observed-bytes stdout-overflow?
                                stderr-overflow?)
  protocol-command-result?
  (status protocol-command-result-status)
  (stdout-observed-bytes protocol-command-result-stdout-observed-bytes)
  (stderr-observed-bytes protocol-command-result-stderr-observed-bytes)
  (stdout-overflow? protocol-command-result-stdout-overflow?)
  (stderr-overflow? protocol-command-result-stderr-overflow?))

(define-record-type <protocol-peer>
  (make-protocol-peer label endpoint donation child phase actions action-index)
  protocol-peer?
  (label protocol-peer-label)
  (endpoint protocol-peer-endpoint)
  (donation protocol-peer-donation set-protocol-peer-donation!)
  (child protocol-peer-child set-protocol-peer-child!)
  (phase protocol-peer-phase set-protocol-peer-phase!)
  (actions protocol-peer-actions)
  (action-index protocol-peer-action-index set-protocol-peer-action-index!))

(define-record-type <owned-runtime-state>
  (make-owned-runtime-state root pin root-identity placeholder-identity
                            authority-netns-identity)
  owned-runtime-state?
  (root owned-runtime-state-root)
  (pin owned-runtime-state-pin)
  (root-identity owned-runtime-state-root-identity)
  (placeholder-identity owned-runtime-state-placeholder-identity)
  (authority-netns-identity owned-runtime-state-authority-netns-identity))

(define-record-type <runtime-mountinfo>
  (make-runtime-mountinfo line mount-id parent-mount-id device root point
                          options type source super-options)
  runtime-mountinfo?
  (line runtime-mountinfo-line)
  (mount-id runtime-mountinfo-mount-id)
  (parent-mount-id runtime-mountinfo-parent-mount-id)
  (device runtime-mountinfo-device)
  (root runtime-mountinfo-root)
  (point runtime-mountinfo-point)
  (options runtime-mountinfo-options)
  (type runtime-mountinfo-type)
  (source runtime-mountinfo-source)
  (super-options runtime-mountinfo-super-options))

(define (fail message . arguments)
  (throw 'book-execution-protocol-integration-error
         (apply format #f message arguments)))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (file-sha256-string path)
  (bytevector->base16-string (file-sha256 path)))

(define (assert-file-sha256! label path expected)
  (unless (and (string? path)
               (eq? (stat:type (stat path)) 'regular)
               (string=? (file-sha256-string path) expected))
    (fail "immutable source provenance mismatch: ~a" label)))

(define (assert-source-provenance!
         profile closure-file guest-smoke base-oci protocol-oci guest-adapter
         expected-guest-adapter-sha256 guile-book python-book guile-protocol
         blocking-protocol python-protocol book-session)
  (unless (and (string? expected-guest-adapter-sha256)
               (= (string-length expected-guest-adapter-sha256) 64))
    (fail "guest adapter expected hash is malformed"))
  (for-each
   (lambda (label path expected)
     (assert-file-sha256! label path expected))
   (map car accepted-source-sha256)
   (list guest-smoke base-oci guile-protocol blocking-protocol python-protocol
         book-session protocol-oci guile-book python-book)
   (map cdr accepted-source-sha256))
  (assert-file-sha256! "guest-book-protocol.scm" guest-adapter
                       expected-guest-adapter-sha256)
  (assert-file-sha256! "accepted language closure" closure-file
                       accepted-language-closure-sha256)
  (let ((closure (read-language-closure closure-file))
        (canonical-profile (canonicalize-path profile)))
    (unless (and (eq? (stat:type (stat canonical-profile)) 'directory)
                 (member canonical-profile closure string=?))
      (fail "accepted sandbox language profile is outside its checked closure"))
    (set! source-provenance-checked? #t)
    closure))

(define (open-capture path)
  (fdopen
   (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC) #o600)
   "wb"))

(define (mark-fd-close-on-exec! fd)
  (let ((flags (fcntl fd F_GETFD)))
    (unless (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))

(define (cloexec-pipe)
  (let ((ports (pipe)))
    (mark-fd-close-on-exec! (fileno (car ports)))
    (mark-fd-close-on-exec! (fileno (cdr ports)))
    ports))

(define (capture-readable! capture)
  (let ((value (get-bytevector-some (bounded-capture-input capture))))
    (if (eof-object? value)
        (set-bounded-capture-eof?! capture #t)
        (let* ((count (bytevector-length value))
               (retained (bounded-capture-retained-bytes capture))
               (remaining (max 0 (- max-capture-bytes retained)))
               (keep (min count remaining)))
          (when (positive? keep)
            (put-bytevector (bounded-capture-output capture) value 0 keep))
          (set-bounded-capture-observed-bytes!
           capture (+ (bounded-capture-observed-bytes capture) count))
          (set-bounded-capture-retained-bytes! capture (+ retained keep))
          (when (> count remaining)
            (set-bounded-capture-overflow?! capture #t))))))

(define (pump-captures! captures microseconds)
  (let ((live (filter (lambda (capture)
                        (not (bounded-capture-eof? capture)))
                      captures)))
    (if (null? live)
        (usleep microseconds)
        (match (select (map bounded-capture-input live) '() '()
                       0 microseconds)
          ((readable () ())
           (for-each
            (lambda (capture)
              (when (memq (bounded-capture-input capture) readable)
                (capture-readable! capture)))
            live))))))

(define (finalize-captures! captures)
  ;; The owned process group is gone.  Retain a finite EOF drain in case a
  ;; future regression leaks a writer outside the group.
  (let ((deadline (+ (now-seconds) term-grace-seconds)))
    (let loop ()
      (unless (every bounded-capture-eof? captures)
        (when (>= (now-seconds) deadline)
          (for-each
           (lambda (capture)
             (close-port-quietly! (bounded-capture-input capture))
             (close-port-quietly! (bounded-capture-output capture)))
           captures)
          (fail "capture pipe remained open after owned runsc-group cleanup"))
        (pump-captures! captures 20000)
        (loop))))
  (for-each
   (lambda (capture)
     (force-output (bounded-capture-output capture))
     (close-port-quietly! (bounded-capture-input capture))
     (close-port-quietly! (bounded-capture-output capture)))
   captures))

(define (capture-overflow? result)
  (or (protocol-command-result-stdout-overflow? result)
      (protocol-command-result-stderr-overflow? result)))

(define (capture-overflow-summary result)
  (string-join
   (filter-map
    (lambda (stream observed overflow?)
      (and overflow?
           (format #f
                   "~a observed-bytes=~a retained-bytes=~a limit-bytes=~a"
                   stream observed max-capture-bytes max-capture-bytes)))
    '(stdout stderr)
    (list (protocol-command-result-stdout-observed-bytes result)
          (protocol-command-result-stderr-observed-bytes result))
    (list (protocol-command-result-stdout-overflow? result)
          (protocol-command-result-stderr-overflow? result)))
   "; "))

(define (lstat-or-false path)
  ((smoke-private 'lstat-or-false) path))

(define (directory-entry-names path)
  ((smoke-private 'directory-entry-names) path))

(define (parse-runtime-mountinfo-line line)
  ;; Keep a local data record because SRFI-9 accessors in the frozen
  ;; guest-smoke module are syntax bindings, not procedures available through
  ;; module-ref.  The parser retains the same strict Linux mountinfo shape.
  (let* ((fields (string-tokenize line))
         (separator (list-index (lambda (field) (string=? field "-")) fields)))
    (and separator
         (>= separator 6)
         (= (- (length fields) separator 1) 3)
         ((smoke-private 'decimal-string?) (list-ref fields 0))
         ((smoke-private 'decimal-string?) (list-ref fields 1))
         ((smoke-private 'device-token?) (list-ref fields 2))
         (make-runtime-mountinfo
          line
          (list-ref fields 0)
          (list-ref fields 1)
          (list-ref fields 2)
          ((smoke-private 'mountinfo-unescape) (list-ref fields 3))
          ((smoke-private 'mountinfo-unescape) (list-ref fields 4))
          (string-split (list-ref fields 5) #\,)
          (list-ref fields (+ separator 1))
          ((smoke-private 'mountinfo-unescape)
           (list-ref fields (+ separator 2)))
          (string-split (list-ref fields (+ separator 3)) #\,)))))

(define (mountinfo-at path)
  (filter-map
   (lambda (line)
     (let ((entry (parse-runtime-mountinfo-line line)))
       (and entry (string=? (runtime-mountinfo-point entry) path) entry)))
   (string-split
    (call-with-input-file "/proc/self/mountinfo" get-string-all)
    #\newline)))

(define (same-file-identity? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (snapshot endpoint name)
  (let ((entry (assoc name (host-session-snapshot endpoint))))
    (and entry (cdr entry))))

(define (read-process-start-time pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((text (call-with-input-file path get-string-all))
                    (close (string-rindex text #\)))
                    (fields (and close
                                 (string-tokenize
                                  (substring text (+ close 2))))))
               ;; The suffix starts at field 3; Linux start time is field 22.
               (and fields (>= (length fields) 20) (list-ref fields 19))))
           (lambda arguments #f)))))

(define (await-process-start-time pid)
  (let loop ((attempt 0))
    (let ((start-time (read-process-start-time pid)))
      (cond
       (start-time start-time)
       ((>= attempt 100) (fail "could not identify runsc child ~a" pid))
       (else (usleep 1000) (loop (+ attempt 1)))))))

(define (write-process-record! path pid start-time process-group)
  (let ((temporary (string-append path ".new")))
    (call-with-output-file temporary
      (lambda (port)
        (format port "~a ~a ~a~%" pid start-time process-group)))
    (chmod temporary #o600)
    (rename-file temporary path)))

(define (clear-close-on-exec! fd)
  (let ((flags (fcntl fd F_GETFD)))
    (when (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logand flags (lognot FD_CLOEXEC))))
    (when (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
      (fail "donated FD ~a remained close-on-exec" fd))))

(define (close-unrelated-fds!)
  ;; SCANDIR releases its own descriptor before this list is consumed.  The
  ;; exec into runsc receives exactly stdio and the selected connected peer.
  (for-each
   (lambda (entry)
     (let ((fd (string->number entry 10)))
       (when (and fd (> fd guest-fd))
         (catch 'system-error
           (lambda () (close-fdes fd))
           (lambda arguments #f)))))
   (scandir "/proc/self/fd"
            (lambda (entry)
              (and (not (member entry '("." "..")))
                   (string->number entry 10))))))

(define (open-exec-fds)
  (sort
   (filter-map
    (lambda (entry)
      (let ((fd (string->number entry 10)))
        (and fd
             (catch 'system-error
               (lambda () (fcntl fd F_GETFD) fd)
               (lambda arguments #f)))))
    (scandir "/proc/self/fd"
             (lambda (entry)
               (and (not (member entry '("." "..")))
                    (string->number entry 10)))))
   <))

(define (assert-exec-fds!)
  (let ((open (open-exec-fds)))
    (unless (equal? open '(0 1 2 3))
      (fail "runsc child retained unrelated descriptors: ~s" open)))
  (unless (eq? (stat:type (stat guest-fd)) 'socket)
    (fail "donated FD 3 is not a socket at runsc exec"))
  (clear-close-on-exec! guest-fd))

(define (open-fd-has-identity? identity)
  (any
   (lambda (entry)
     (let ((fd (string->number entry 10)))
       (and fd
            (catch 'system-error
              (lambda ()
                (let ((current (stat fd)))
                  (and (= (stat:dev current) (stat:dev identity))
                       (= (stat:ino current) (stat:ino identity)))))
              (lambda arguments #f)))))
   (scandir "/proc/self/fd"
            (lambda (entry)
              (and (not (member entry '("." "..")))
                   (string->number entry 10))))))

(define (assert-parent-authority-only! peer donation-identity)
  (unless (and (not (protocol-peer-donation peer))
               (snapshot (protocol-peer-endpoint peer) "transport_open")
               (not (open-fd-has-identity? donation-identity)))
    (fail "parent retained the donated peer or lost its authority endpoint")))

(define (decode-child-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   (else (cons 'unknown status))))

(define (process-group-exists? process-group)
  (catch 'system-error
    (lambda () (kill (- process-group) 0) #t)
    (lambda arguments
      (not (= (system-error-errno arguments) ESRCH)))))

(define (signal-group! child signal-number)
  (let ((observed (read-process-start-time (owned-runsc-pid child))))
    (when (and observed
               (not (string=? observed (owned-runsc-start-time child))))
      (fail "refusing to signal reused runsc PID ~a" (owned-runsc-pid child))))
  (catch 'system-error
    (lambda () (kill (- (owned-runsc-process-group child)) signal-number))
    (lambda arguments
      (unless (= (system-error-errno arguments) ESRCH)
        (apply throw 'system-error arguments)))))

(define (reap-owned-runsc! child)
  (unless (owned-runsc-status child)
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid (owned-runsc-pid child) WNOHANG))
             (lambda arguments
               (if (= (system-error-errno arguments) ECHILD)
                   #f
                   (if (= (system-error-errno arguments) EINTR)
                       '(0 . 0)
                       (apply throw 'system-error arguments)))))))
      (when (and waited (not (zero? (car waited))))
        (set-owned-runsc-status!
         child (decode-child-status (cdr waited))))))
  (owned-runsc-status child))

(define (pump-owned-captures! child microseconds)
  (pump-captures! (owned-runsc-captures child) microseconds))

(define (wait-after-signal! child seconds)
  (let ((deadline (+ (now-seconds) seconds)))
    (let loop ()
      (reap-owned-runsc! child)
      (pump-owned-captures! child 20000)
      (if (and (owned-runsc-status child)
               (not (process-group-exists?
                     (owned-runsc-process-group child))))
          #t
          (and (< (now-seconds) deadline) (loop))))))

(define (finalize-owned-runsc! child)
  (when (and child (not (owned-runsc-finalized? child)))
    (reap-owned-runsc! child)
    (when (process-group-exists? (owned-runsc-process-group child))
      (signal-group! child SIGTERM)
      (unless (wait-after-signal! child term-grace-seconds)
        (signal-group! child SIGKILL)
        (unless (wait-after-signal! child term-grace-seconds)
          (fail "owned runsc group survived SIGKILL: ~a"
                (owned-runsc-name child)))))
    (unless (owned-runsc-status child)
      (let ((waited
             (catch 'system-error
               (lambda () (waitpid (owned-runsc-pid child)))
               (lambda arguments
                 (if (= (system-error-errno arguments) ECHILD)
                     #f
                     (apply throw 'system-error arguments))))))
        (when waited
          (set-owned-runsc-status!
           child (decode-child-status (cdr waited))))))
    (when (process-group-exists? (owned-runsc-process-group child))
      (fail "owned runsc process group remained after reap: ~a"
            (owned-runsc-name child)))
    (finalize-captures! (owned-runsc-captures child))
    (when (lstat-or-false (owned-runsc-record-path child))
      (delete-file (owned-runsc-record-path child)))
    (set-owned-runsc-finalized?! child #t)))

(define (child-exec! gate-input donation argv environment directory
                     stdout-input stdout-output stdout-file
                     stderr-input stderr-output stderr-file)
  (let ((released (get-u8 gate-input)))
    (close-port-quietly! gate-input)
    (unless (and (integer? released) (= released 1))
      (primitive-exit 126)))
  (for-each (lambda (signal-number)
              (sigaction signal-number SIG_DFL))
            (list SIGINT SIGHUP SIGTERM SIGPIPE SIGCHLD))
  (let ((null-fd (open-fdes "/dev/null" (logior O_RDONLY O_CLOEXEC))))
    (dup2 null-fd 0)
    (close-fdes null-fd))
  (close-port-quietly! stdout-input)
  (close-port-quietly! stderr-input)
  (close-port-quietly! stdout-file)
  (close-port-quietly! stderr-file)
  (dup2 (fileno stdout-output) 1)
  (dup2 (fileno stderr-output) 2)
  (dup2 (fileno donation) guest-fd)
  (clear-close-on-exec! guest-fd)
  (close-unrelated-fds!)
  (assert-exec-fds!)
  (chdir directory)
  (environ environment)
  (apply execl (car argv) argv))

(define (spawn-owned-runsc name record-path donation argv environment directory
                           stdout-path stderr-path)
  (let* ((stdout-pipe (cloexec-pipe))
         (stderr-pipe (cloexec-pipe))
         (stdout-input (car stdout-pipe))
         (stdout-output (cdr stdout-pipe))
         (stderr-input (car stderr-pipe))
         (stderr-output (cdr stderr-pipe))
         (stdout-file (open-capture stdout-path))
         (stderr-file (open-capture stderr-path))
         (stdout-capture
          (make-bounded-capture 'stdout stdout-input stdout-file 0 0 #f #f))
         (stderr-capture
          (make-bounded-capture 'stderr stderr-input stderr-file 0 0 #f #f))
         (gate (pipe O_CLOEXEC))
         (gate-input (car gate))
         (gate-output (cdr gate))
         (pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (close-port-quietly! gate-output)
          (catch #t
            (lambda ()
              (setpgid 0 0)
              (child-exec! gate-input donation argv environment directory
                           stdout-input stdout-output stdout-file
                           stderr-input stderr-output stderr-file)
              (primitive-exit 127))
            (lambda arguments (primitive-exit 127))))
        (begin
          (close-port-quietly! gate-input)
          (close-port-quietly! stdout-output)
          (close-port-quietly! stderr-output)
          (let ((published? #f))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (catch 'system-error
                  (lambda () (setpgid pid pid))
                  (lambda arguments
                    (unless (memv (system-error-errno arguments)
                                  (list EACCES EPERM))
                      (apply throw 'system-error arguments))))
                (let ((start-time (await-process-start-time pid)))
                  (write-process-record! record-path pid start-time pid)
                  (put-u8 gate-output 1)
                  (force-output gate-output)
                  (close-port-quietly! gate-output)
                  (set! published? #t)
                  (make-owned-runsc
                   name pid start-time pid record-path
                   (list stdout-capture stderr-capture) #f #f)))
              (lambda ()
                (unless published?
                  (close-port-quietly! gate-output)
                  (catch 'system-error
                    (lambda () (kill (- pid) SIGKILL))
                    (lambda arguments #f))
                  (catch 'system-error
                    (lambda () (waitpid pid))
                    (lambda arguments #f))
                  (for-each
                   (lambda (capture)
                     (close-port-quietly! (bounded-capture-input capture))
                     (close-port-quietly! (bounded-capture-output capture)))
                   (list stdout-capture stderr-capture))
                  (when (lstat-or-false record-path)
                    (delete-file record-path))))))))))

(define (capture-result child)
  (unless (and child (owned-runsc-finalized? child))
    (fail "runsc capture result requested before final cleanup"))
  (let* ((captures (owned-runsc-captures child))
         (stdout (car captures))
         (stderr (cadr captures)))
    (make-protocol-command-result
     (match (owned-runsc-status child)
       (('exit . status) status)
       (('signal . signal-number) (logior #x80 signal-number))
       (_ 1))
     (bounded-capture-observed-bytes stdout)
     (bounded-capture-observed-bytes stderr)
     (bounded-capture-overflow? stdout)
     (bounded-capture-overflow? stderr))))

(define (exact-initialize? value)
  (and (list? value)
       (equal? (map car value)
               '("type" "version" "grant_count" "surface_handle"
                 "surface_generation" "max_pending_requests"
                 "max_present_text_bytes"))
       (string=? (assoc-ref value "type") "initialize")
       (= (assoc-ref value "version") 1)
       (= (assoc-ref value "grant_count") 1)
       (string? (assoc-ref value "surface_handle"))
       (not (string-null? (assoc-ref value "surface_handle")))
       (= (assoc-ref value "surface_generation") 1)
       (= (assoc-ref value "max_pending_requests") 4)
       (= (assoc-ref value "max_present_text_bytes") 4096)
       (not (assoc "identity" value))))

(define (queue-action! peer index)
  (let ((action (list-ref (protocol-peer-actions peer) index)))
    (endpoint-queue-message!
     (protocol-peer-endpoint peer)
     (host-action! (protocol-peer-endpoint peer) (car action) (cadr action)))
    (set-protocol-peer-action-index! peer index)))

(define (handle-committed! peer value)
  (case (protocol-peer-phase peer)
    ((hello)
     (unless (exact-initialize? value)
       (fail "~a did not produce the exact capability initialize envelope"
             (protocol-peer-label peer)))
     (endpoint-queue-message! (protocol-peer-endpoint peer) value)
     (queue-action! peer 0)
     (set-protocol-peer-phase! peer 'present))
    ((present)
     (let* ((index (protocol-peer-action-index peer))
            (action (list-ref (protocol-peer-actions peer) index)))
       (unless (and (presented-text? value)
                    (string=? (presented-text-action-id value) (car action))
                    (= (presented-text-surface-generation value) 1)
                    (= (presented-text-sequence value) (+ index 1))
                    (string=? (presented-text-value value) (caddr action)))
         (fail "~a returned the wrong computed protocol result at action ~a"
               (protocol-peer-label peer) (+ index 1)))
       (if (< (+ index 1) (length (protocol-peer-actions peer)))
           (queue-action! peer (+ index 1))
           (set-protocol-peer-phase! peer 'awaiting-eof))))
    (else
     (fail "~a committed an unexpected message in phase ~a"
           (protocol-peer-label peer) (protocol-peer-phase peer)))))

(define (pump-peer! peer)
  (let ((endpoint (protocol-peer-endpoint peer)))
    (when (memq 'input (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-input! endpoint)))
        (case (endpoint-pump-result-status result)
          ((committed)
           (let ((values (endpoint-pump-result-values result)))
             (unless (= (length values) 1)
               (fail "~a input pump did not commit exactly once"
                     (protocol-peer-label peer)))
             (handle-committed! peer (car values))))
          ((eof closed)
           (if (eq? (protocol-peer-phase peer) 'awaiting-eof)
               (set-protocol-peer-phase! peer 'done)
               (fail "~a transport closed before both presentations"
                     (protocol-peer-label peer))))
          ((would-block interrupted budget) #t)
          ((stale)
           (fail "~a live integration pump became stale"
                 (protocol-peer-label peer)))
          (else
           (fail "~a returned unknown input status ~s"
                 (protocol-peer-label peer)
                 (endpoint-pump-result-status result))))))
    (when (> (snapshot endpoint "outbound_frames") 0)
      (let ((result (endpoint-pump-output! endpoint)))
        (unless (memq (endpoint-pump-result-status result)
                      '(drained budget would-block interrupted))
          (fail "~a output pump failed before protocol completion: ~s"
                (protocol-peer-label peer)
                (endpoint-pump-result-status result)))))))

(define (assert-closed-session-result! peer)
  (let ((endpoint (protocol-peer-endpoint peer)))
    (unless (and (eq? (protocol-peer-phase peer) 'done)
                 (eq? (snapshot endpoint "state") 'closed)
                 (not (snapshot endpoint "transport_open"))
                 (= (snapshot endpoint "pending_requests") 0)
                 (= (snapshot endpoint "outbound_frames") 0)
                 (= (snapshot endpoint "sequence") 2)
                 (= (snapshot endpoint "retained_terminal_requests") 2))
      (fail "~a endpoint did not reach the exact closed result state: ~s"
            (protocol-peer-label peer)
            (host-session-snapshot endpoint)))))

(define (run-peer-loop! peer deadline)
  (let ((child (protocol-peer-child peer)))
    (let loop ()
      (when (>= (now-seconds) deadline)
        (fail "protocol pair exceeded its supervisor-owned whole-run deadline"))
      (pump-peer! peer)
      (reap-owned-runsc! child)
      (let ((status (owned-runsc-status child)))
        (when (and status (not (equal? status '(exit . 0))))
          (fail "~a runsc process failed: ~s"
                (protocol-peer-label peer) status))
        (if (and (eq? (protocol-peer-phase peer) 'done)
                 (equal? status '(exit . 0))
                 (not (process-group-exists?
                       (owned-runsc-process-group child))))
            (assert-closed-session-result! peer)
            (begin
              (pump-owned-captures! child scheduler-sleep-microseconds)
              (loop)))))))

(define (read-launch-record bundle expected-kind expected-container-id)
  (let* ((path (string-append bundle "/launch.json"))
         (record (call-with-input-file path
                   (lambda (port) (json->scm port #:ordered #t))))
         (make-argv
          (module-ref (resolve-module '(oci-book-bundle))
                      'make-protocol-launch-argv))
         (expected-argv (make-argv bundle expected-container-id)))
    (unless (and
             (equal? (map car record)
                     '("argv" "cgroupsPath" "claim" "executionProfile"
                       "fixtureKind" "guestProtocolFd"
                       "requiredKernelConfig" "supervisorEnv" "supervisorUid"))
             (equal? (vector->list (assoc-ref record "argv")) expected-argv)
             (string=? (assoc-ref record "cgroupsPath")
                       (string-append "/wilkbook-execution-"
                                      expected-container-id))
             (string=? (assoc-ref record "claim")
                       "fixed-book-protocol-fd-donation-gate")
             (string=? (assoc-ref record "executionProfile")
                       "isolation-userns")
             (string=? (assoc-ref record "fixtureKind") expected-kind)
             (= (assoc-ref record "guestProtocolFd") 3)
             (equal? (vector->list
                      (assoc-ref record "requiredKernelConfig"))
                     '("CONFIG_USER_NS=y"))
             (= (assoc-ref record "supervisorUid") 0))
      (fail "generated ~a launch record changed policy" expected-kind))
    (let ((environment (vector->list (assoc-ref record "supervisorEnv"))))
      (unless (equal? environment
                      (list "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                            "PATH=/run/current-system/profile/bin"
                            (string-append "TMPDIR=" bundle
                                           "/supervisor-tmp")))
        (fail "generated ~a runsc environment changed policy" expected-kind))
      (values expected-argv environment))))

(define (replace-runtime-for-host-test argv override evidence-mode)
  (case evidence-mode
    ((guest-runsc)
     (when override
       (fail "runtime override is forbidden in guest-runsc evidence mode"))
     argv)
    ((host-fake)
     (unless override
       (fail "host-fake evidence mode requires one explicit fake runtime"))
     (let ((canonical (canonicalize-path override)))
       (unless (and (eq? (stat:type (stat canonical)) 'regular)
                    (access? canonical X_OK))
         (fail "host fake runtime is not an executable regular file"))
       (cons canonical (cdr argv))))
    (else (fail "unknown protocol evidence mode: ~s" evidence-mode))))

(define (assert-cgroup2-preflight! container-id)
  (let ((mountinfo (call-with-input-file "/proc/self/mountinfo" get-string-all)))
    (unless (and (string-contains mountinfo " /sys/fs/cgroup ")
                 (string-contains mountinfo " - cgroup2 ")
                 (lstat-or-false "/sys/fs/cgroup/cgroup.controllers"))
      (fail "declared cgroup2 hierarchy is not mounted at /sys/fs/cgroup")))
  (let ((target (string-append "/sys/fs/cgroup/wilkbook-execution-"
                               container-id)))
    (when (lstat-or-false target)
      (fail "refusing stale cgroup path: ~a" target)))
  (let* ((probe (string-append "/sys/fs/cgroup/.wilkbook-protocol-preflight-"
                               (number->string (getpid))))
         (created? #f))
    (catch #t
      (lambda ()
        (when (lstat-or-false probe)
          (fail "cgroup write probe path already exists"))
        (mkdir probe #o700)
        (set! created? #t)
        (unless (lstat-or-false (string-append probe "/cgroup.procs"))
          (fail "cgroup2 child lacks cgroup.procs"))
        (rmdir probe)
        (set! created? #f))
      (lambda (key . arguments)
        (when created?
          (catch 'system-error
            (lambda () (rmdir probe))
            (lambda cleanup-arguments #f)))
        (apply throw key arguments)))))

(define (assert-runtime-state-clean! bundle container-id)
  (let ((cgroup (string-append "/sys/fs/cgroup/wilkbook-execution-"
                               container-id))
        (state (string-append bundle "/runsc-state")))
    (when (lstat-or-false cgroup)
      (fail "runtime left stale cgroup: ~a" container-id))
    (unless (and (lstat-or-false state)
                 (eq? (stat:type (lstat state)) 'directory)
                 (null? (directory-entry-names state)))
      (fail "runtime left state entries for ~a" container-id))
    (rmdir state)
    (when (lstat-or-false state)
      (fail "runtime state root survived cleanup for ~a" container-id))))

(define (private-runtime-state-root? info identity)
  (and info
       (eq? (stat:type info) 'directory)
       (same-file-identity? info identity)
       (= (logand (stat:mode info) #o7777) #o700)
       (zero? (stat:uid info))
       (zero? (stat:gid info))))

(define (owned-null-netns-placeholder? info identity)
  (and info
       (eq? (stat:type info) 'regular)
       (same-file-identity? info identity)
       (= (logand (stat:mode info) #o7777) #o444)
       (zero? (stat:uid info))
       (zero? (stat:gid info))
       (= (stat:nlink info) 1)))

(define (network-namespace-root-inode root)
  (and (string-prefix? "net:[" root)
       (string-suffix? "]" root)
       (let ((digits (substring root 5 (- (string-length root) 1))))
         (and ((smoke-private 'decimal-string?) digits)
              (string->number digits 10)))))

(define (mountinfo-device-number token)
  (match (string-split token #\:)
    ((major minor)
     (let ((major (string->number major 10))
           (minor (string->number minor 10)))
       ;; Linux's new_encode_dev(), matching stat(2)'s st_dev representation.
       (logior (ash (logand major #xfff) 8)
               (logand minor #xff)
               (ash (logand minor (lognot #xff)) 12)
               (ash (logand major (lognot #xfff)) 32))))
    (_ #f)))

(define (expected-null-netns-mount? entry mounted-info placeholder-identity
                                    authority-netns-identity)
  (let* ((root (runtime-mountinfo-root entry))
         (namespace-inode (network-namespace-root-inode root))
         (device (mountinfo-device-number (runtime-mountinfo-device entry)))
         (options (runtime-mountinfo-options entry))
         (super-options (runtime-mountinfo-super-options entry)))
    (and (string=? (runtime-mountinfo-type entry) "nsfs")
         (string=? (runtime-mountinfo-source entry) "nsfs")
         namespace-inode
         device
         (= device (stat:dev mounted-info))
         (= namespace-inode (stat:ino mounted-info))
         (eq? (stat:type mounted-info) 'regular)
         (not (same-file-identity? mounted-info placeholder-identity))
         (not (same-file-identity? mounted-info authority-netns-identity))
         (member "rw" options)
         (not (member "ro" options))
         (member "rw" super-options)
         (not (member "ro" super-options)))))

(define (prepare-owned-runtime-state! bundle container-id)
  ;; The protocol OCI generator creates this private root.  Own both its
  ;; identity and the exact underlying placeholder before runsc can replace the
  ;; latter with its default shared null-network-namespace bind mount.
  (let* ((root (string-append bundle "/runsc-state"))
         (pin (string-append root "/null-netns"))
         (root-info (lstat-or-false root)))
    (unless (and root-info
                 (eq? (stat:type root-info) 'directory)
                 (= (logand (stat:mode root-info) #o7777) #o700)
                 (zero? (stat:uid root-info))
                 (zero? (stat:gid root-info))
                 (null? (directory-entry-names root))
                 (null? (mountinfo-at root))
                 (null? (mountinfo-at pin)))
      (fail "runtime state root is not a new private empty directory for ~a"
            container-id))
    (let ((fd (open-fdes pin (logior O_RDONLY O_CREAT O_EXCL O_CLOEXEC)
                         #o444)))
      (close-fdes fd))
    ;; The supervisor's mode-0077 umask must not weaken gVisor's fixed 0444
    ;; placeholder contract.
    (chmod pin #o444)
    (let ((placeholder-info (lstat pin)))
      (unless (and (eq? (stat:type placeholder-info) 'regular)
                   (= (logand (stat:mode placeholder-info) #o7777) #o444)
                   (zero? (stat:uid placeholder-info))
                   (zero? (stat:gid placeholder-info))
                   (= (stat:nlink placeholder-info) 1))
        (fail "runtime null-netns placeholder is not fixture-owned for ~a"
              container-id))
      (make-owned-runtime-state root pin root-info placeholder-info
                                (stat "/proc/self/ns/net")))))

(define (cleanup-owned-runtime-state! owner container-id)
  ;; This runs only after endpoint release and exact runsc-group reap.  Permit
  ;; precisely gVisor's pinned default null-netns mount, unmount it non-lazily,
  ;; reveal and verify our original placeholder, then remove only that file and
  ;; the unchanged empty root.
  (let* ((root (owned-runtime-state-root owner))
         (pin (owned-runtime-state-pin owner))
         (root-identity (owned-runtime-state-root-identity owner))
         (placeholder-identity
          (owned-runtime-state-placeholder-identity owner))
         (authority-netns-identity
          (owned-runtime-state-authority-netns-identity owner))
         (root-info (lstat-or-false root)))
    (when (lstat-or-false
           (string-append "/sys/fs/cgroup/wilkbook-execution-" container-id))
      (fail "runtime left stale cgroup: ~a" container-id))
    (unless (same-file-identity? (stat "/proc/self/ns/net")
                                 authority-netns-identity)
      (fail "trusted authority network namespace changed for ~a" container-id))
    (unless (private-runtime-state-root? root-info root-identity)
      (fail "runtime state root identity changed for ~a" container-id))
    ;; A self-bind preserves all stat(2) identity fields.  Reject every mount at
    ;; the exact root before touching the one reviewed child mount.
    (unless (null? (mountinfo-at root))
      (fail "runtime state root became mounted before pin cleanup for ~a"
            container-id))
    (unless (equal? (directory-entry-names root) '("null-netns"))
      (fail "runtime left unexpected state entries for ~a" container-id))
    (let ((mounted-info (lstat-or-false pin))
          (mounts (mountinfo-at pin)))
      (unless (and mounted-info
                   (= (length mounts) 1)
                   (expected-null-netns-mount?
                    (car mounts) mounted-info placeholder-identity
                    authority-netns-identity))
        (fail "runtime null-netns mount identity changed for ~a" container-id))
      ((smoke-private 'emit)
       (format #f
               "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-CLEANUP container=~a entry=null-netns mount=nsfs namespace=net inode=~a action=nonlazy-unmount"
               container-id (stat:ino mounted-info))))
    ((smoke-private 'run-fixed-utility)
     "unmount-null-netns"
     (list (smoke-private 'umount-program) "-n" pin)
     (dirname root))
    (unless (null? (mountinfo-at pin))
      (fail "runtime null-netns remained mounted for ~a" container-id))
    (unless (private-runtime-state-root?
             (lstat-or-false root) root-identity)
      (fail "runtime state root identity changed after pin unmount for ~a"
            container-id))
    ;; Re-observe the exact root immediately before the first unlink.  This is
    ;; a controlled-fixture ownership check, not a claim to prevent arbitrary
    ;; concurrent privileged mount operations on a hostile host.
    (unless (null? (mountinfo-at root))
      (fail "runtime state root became mounted before placeholder removal for ~a"
            container-id))
    (unless (and (equal? (directory-entry-names root) '("null-netns"))
                 (owned-null-netns-placeholder?
                  (lstat-or-false pin) placeholder-identity))
      (fail "runtime null-netns placeholder identity changed after unmount for ~a"
            container-id))
    (delete-file pin)
    (unless (and (private-runtime-state-root?
                  (lstat-or-false root) root-identity)
                 (null? (directory-entry-names root)))
      (fail "runtime state root was not empty after owned pin removal for ~a"
            container-id))
    (rmdir root)
    (when (lstat-or-false root)
      (fail "runtime state root survived cleanup for ~a" container-id))))

(define (emit-runtime-state-diagnostics bundle container-id)
  ;; Report a finite metadata-only view before any accepted null-netns cleanup.
  ;; Never read, unlink, or recurse into an entry here: unexpected, non-regular,
  ;; symlink, and other-container state must remain fatal evidence.
  (let ((state (string-append bundle "/runsc-state"))
        (port ((smoke-private 'diagnostic-console-port))))
    (catch #t
      (lambda ()
        (let* ((info (lstat-or-false state))
               (directory? (and info (eq? (stat:type info) 'directory)))
               (names (if directory?
                          (sort (directory-entry-names state) string<?)
                          '()))
               (selected
                (take names
                      (min (length names)
                           max-runtime-state-diagnostic-entries)))
               (root-mounts (mountinfo-at state))
               (selected-root-mounts
                (take root-mounts
                      (min (length root-mounts)
                           max-runtime-state-diagnostic-root-mounts))))
          (cond
           ((not info)
             (format port
                     "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE container=~a state=missing root-mounts=~a root-mounts-emitted=~a root-mount-limit=~a~%"
                     container-id (length root-mounts)
                     (length selected-root-mounts)
                     max-runtime-state-diagnostic-root-mounts))
            ((not directory?)
             (format port
                     "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE container=~a state=non-directory type=~a mode-octal=~o uid=~a gid=~a size=~a root-mounts=~a root-mounts-emitted=~a root-mount-limit=~a~%"
                     container-id (stat:type info)
                     (logand (stat:mode info) #o7777)
                     (stat:uid info) (stat:gid info) (stat:size info)
                     (length root-mounts) (length selected-root-mounts)
                     max-runtime-state-diagnostic-root-mounts))
            (else
             (format port
                     "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE container=~a state=directory device=~a inode=~a mode-octal=~o uid=~a gid=~a entries=~a emitted=~a limit=~a root-mounts=~a root-mounts-emitted=~a root-mount-limit=~a~%"
                     container-id (stat:dev info) (stat:ino info)
                     (logand (stat:mode info) #o7777)
                     (stat:uid info) (stat:gid info)
                     (length names) (length selected)
                     max-runtime-state-diagnostic-entries
                     (length root-mounts) (length selected-root-mounts)
                     max-runtime-state-diagnostic-root-mounts)))
          (for-each
           (lambda (mount mount-index)
             (format port
                     "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ROOT-MOUNT mount-index=~a mount-id=~a parent-mount-id=~a device=~a type=~a root-bytes=~a source-bytes=~a~%| ~a~%"
                     mount-index
                     (runtime-mountinfo-mount-id mount)
                     (runtime-mountinfo-parent-mount-id mount)
                     (runtime-mountinfo-device mount)
                     (runtime-mountinfo-type mount)
                     (bytevector-length
                      (string->utf8 (runtime-mountinfo-root mount)))
                     (bytevector-length
                      (string->utf8 (runtime-mountinfo-line mount)))
                     ((smoke-private 'bounded-escaped-line)
                      (runtime-mountinfo-line mount))))
           selected-root-mounts
           (iota (length selected-root-mounts)))
          (when directory?
            (for-each
             (lambda (name index)
               (let* ((entry-info (lstat (string-append state "/" name)))
                      (name-bytes (string->utf8 name))
                      (mounts (mountinfo-at (string-append state "/" name)))
                      (selected-mounts
                       (take mounts
                             (min (length mounts)
                                  max-runtime-state-diagnostic-mounts-per-entry))))
                 (format port
                         "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ENTRY index=~a type=~a device=~a inode=~a mode-octal=~o uid=~a gid=~a size=~a name-bytes=~a mounts=~a mounts-emitted=~a mount-limit=~a~%"
                         index (stat:type entry-info)
                         (stat:dev entry-info) (stat:ino entry-info)
                         (logand (stat:mode entry-info) #o7777)
                         (stat:uid entry-info) (stat:gid entry-info)
                         (stat:size entry-info)
                         (bytevector-length name-bytes)
                         (length mounts) (length selected-mounts)
                         max-runtime-state-diagnostic-mounts-per-entry)
                 ((smoke-private 'write-escaped-bytevector)
                  name-bytes port)
                 (for-each
                  (lambda (mount mount-index)
                    (format port
                            "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-MOUNT entry-index=~a mount-index=~a source-bytes=~a~%| ~a~%"
                            index mount-index
                            (bytevector-length
                             (string->utf8
                              (runtime-mountinfo-line mount)))
                            ((smoke-private 'bounded-escaped-line)
                             (runtime-mountinfo-line mount))))
                  selected-mounts
                  (iota (length selected-mounts)))))
             selected
             (iota (length selected))))))
      (lambda (key . arguments)
        (format port
                "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE container=~a state=unavailable error=~a~%"
                container-id
                ((smoke-private 'bounded-escaped-line)
                 (format #f "~s ~s" key arguments)))))
    (force-output port)))

(define (assert-diagnostic-stores-unmounted! bundle)
  ;; Accepted FINAL2 cleanup removes both now-empty mountpoints after verified
  ;; unmount.  This check runs after call-with-diagnostic-stores returns.
  (for-each
   (lambda (relative)
     (when (lstat-or-false (string-append bundle "/" relative))
       (fail "diagnostic store survived verified unmount: ~a" relative)))
   '("runsc-debug" "runsc-panic")))

(define (release-peer! peer)
  (when peer
    (let ((endpoint (protocol-peer-endpoint peer))
          (first-error #f))
      (define (remember-error! arguments)
        (unless first-error (set! first-error arguments)))
      (catch #t
        (lambda () (release-session-endpoint! endpoint))
        (lambda arguments
          (remember-error! arguments)
          (catch #t
            (lambda () (close-session! endpoint))
            (lambda fallback-arguments
              (remember-error! fallback-arguments)))))
      (close-port-quietly! (protocol-peer-donation peer))
      (set-protocol-peer-donation! peer #f)
      (catch #t
        (lambda () (finalize-owned-runsc! (protocol-peer-child peer)))
        (lambda arguments (remember-error! arguments)))
      ;; A fallback transport close prevents leakage, but cannot turn a failed
      ;; host unregister into successful endpoint-release evidence.
      (when first-error
        (apply throw first-error)))))

(define (path-present-state path)
  (if (lstat-or-false path) "present" "absent"))

(define (emit-runtime-failure-diagnostics bundle container-id result)
  ;; Like the accepted FINAL2 path, render only bounded escaped diagnostics
  ;; after every owned writer has stopped.  Protocol results are never read
  ;; from either capture.
  (catch #t
    (lambda ()
      ((smoke-private 'emit)
       (format #f
               "BOOKEXEC-DIAGNOSTIC-RUNSC-EXIT container=~a status=~a cgroup=~a runtime-state=~a"
                container-id (protocol-command-result-status result)
               (path-present-state
                (string-append "/sys/fs/cgroup/wilkbook-execution-"
                               container-id))
                (path-present-state (string-append bundle "/runsc-state"))))
      (for-each
       (lambda (stream observed overflow?)
         (when overflow?
           ((smoke-private 'emit)
            (format #f
                    "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW stream=~a observed-bytes=~a retained-bytes=~a limit-bytes=~a"
                    stream observed max-capture-bytes max-capture-bytes))))
       '(stdout stderr)
       (list (protocol-command-result-stdout-observed-bytes result)
             (protocol-command-result-stderr-observed-bytes result))
       (list (protocol-command-result-stdout-overflow? result)
             (protocol-command-result-stderr-overflow? result)))
      ((smoke-private 'emit-bounded-file-diagnostic)
       "runsc-stdout" (string-append bundle "/runsc.stdout"))
      ((smoke-private 'emit-bounded-file-diagnostic)
       "runsc-support-stderr" (string-append bundle "/runsc.stderr"))
      ((smoke-private 'capture-kernel-dmesg) (dirname bundle)))
    (lambda (key . arguments)
      ((smoke-private 'emit)
       (format #f
               "BOOKEXEC-DIAGNOSTIC-RUNSC state=unavailable error=~s ~s"
               key arguments)))))

(define* (run-one-book!
          host label actions bundle container-id deadline evidence-mode
          runtime-override diagnostic-wrapper cgroup-preflight
          post-store-check marker-emitter marker)
  (let ((peer #f)
        (result #f)
        (observations #f)
        (runtime-state-owner #f)
        (runtime-state-evidence-emitted? #f)
        (store-evidence-emitted? #f))
    (define (emit-store-evidence-once! stores include-files?)
      (unless store-evidence-emitted?
        (set! store-evidence-emitted? #t)
        (when (pair? stores)
          ((smoke-private 'emit-diagnostic-store-evidence)
           bundle stores observations include-files?))))
    (diagnostic-wrapper
     bundle
     (lambda (stores)
       (catch #t
          (lambda ()
             (when (eq? evidence-mode 'guest-runsc)
               (set! runtime-state-owner
                     (prepare-owned-runtime-state! bundle container-id)))
             (dynamic-wind
              (lambda () #t)
              (lambda ()
                (call-with-values
                    (lambda ()
                      (open-session-endpoint! host label))
                  (lambda (endpoint donation)
                    (set! peer
                          (make-protocol-peer label endpoint donation #f
                                              'hello actions 0))))
                (cgroup-preflight container-id)
                (call-with-values
                    (lambda ()
                      (read-launch-record bundle label container-id))
                  (lambda (fixed-argv environment)
                    (let* ((argv
                            (replace-runtime-for-host-test
                             fixed-argv runtime-override evidence-mode))
                           (donation-identity
                            (stat (protocol-peer-donation peer)))
                           (stdout (string-append bundle "/runsc.stdout"))
                           (stderr (string-append bundle "/runsc.stderr"))
                           (record (string-append bundle "/runsc.pid")))
                      (set-protocol-peer-child!
                       peer
                       (spawn-owned-runsc label record
                                          (protocol-peer-donation peer)
                                          argv environment bundle stdout stderr))
                      ;; The parent authority keeps only its opaque endpoint.
                      ;; The selected peer is now child-owned at runsc FD 3.
                      (close-port-quietly! (protocol-peer-donation peer))
                      (set-protocol-peer-donation! peer #f)
                      (assert-parent-authority-only! peer donation-identity)
                      (run-peer-loop! peer deadline)))))
              (lambda ()
                ;; This also covers launch-record/preflight/spawn exceptions,
                ;; not only a child that reached the protocol loop.
                (release-peer! peer)))
            ;; release-peer! has closed/unregistered the endpoint, reaped the
           ;; exact runsc group, finalized both bounded pipes, and removed the
           ;; process-identity record before any success check below.
           (set! result (capture-result (protocol-peer-child peer)))
           (unless (equal? (owned-runsc-status (protocol-peer-child peer))
                           '(exit . 0))
             (fail "~a runsc did not exit zero" label))
           (when (capture-overflow? result)
             (fail "~a capture overflow: ~a" label
                   (capture-overflow-summary result)))
            (if runtime-state-owner
                (begin
                  (emit-runtime-state-diagnostics bundle container-id)
                  (set! runtime-state-evidence-emitted? #t)
                  (cleanup-owned-runtime-state!
                   runtime-state-owner container-id))
                (assert-runtime-state-clean! bundle container-id))
           (when (pair? stores)
             (set! observations
                   ((smoke-private 'observe-diagnostic-stores) stores))
             (when ((smoke-private 'diagnostic-stores-overflow?) observations)
               (fail "~a exhausted a bounded diagnostic store" label)))
           (emit-store-evidence-once! stores #f))
         (lambda (key . arguments)
           ;; All endpoint/process cleanup in the inner dynamic-wind completed
           ;; before this bounded evidence is serialized.  The stores remain
           ;; mounted until this handler rethrows into the outer wrapper.
           (when (and peer (protocol-peer-child peer)
                      (owned-runsc-finalized?
                       (protocol-peer-child peer)))
             (set! result (capture-result (protocol-peer-child peer))))
            (emit-store-evidence-once! stores #t)
            (when (eq? evidence-mode 'guest-runsc)
              (unless runtime-state-evidence-emitted?
                (emit-runtime-state-diagnostics bundle container-id)
                (set! runtime-state-evidence-emitted? #t))
              (when result
                (emit-runtime-failure-diagnostics
                 bundle container-id result)))
           (apply throw key arguments)))))
    ;; Stage-1 review caveat closure: verified diagnostic-store unmount is part
    ;; of acceptance and precedes the language PASS marker.
    (post-store-check bundle)
    (when (eq? evidence-mode 'guest-runsc)
      (marker-emitter marker))))

(define (send-raw-frame! peer message)
  (write-frame peer message))

(define (release-test-endpoint! endpoint peer)
  (close-port-quietly! peer)
  (catch #t
    (lambda () (release-session-endpoint! endpoint))
    (lambda arguments (close-session! endpoint))))

(define (run-schema-rejection-test!)
  (let ((host (make-book-session-host)) (endpoint #f) (peer #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host "schema-selftest"))
          (lambda (new-endpoint new-peer)
            (set! endpoint new-endpoint)
            (set! peer new-peer)))
        (send-raw-frame!
         peer
         '(("type" . "hello") ("version" . 1)
           ("identity" . "self-asserted-and-forbidden")))
        (let ((rejected?
               (catch 'book-session-error
                 (lambda () (endpoint-pump-input! endpoint) #f)
                 (lambda (key kind message) (eq? kind 'schema)))))
          (unless rejected?
            (fail "one-time schema self-test accepted an identity field"))))
      (lambda ()
        (when endpoint (release-test-endpoint! endpoint peer))))))

(define (single-committed-value endpoint)
  (let ((result (endpoint-pump-input! endpoint)))
    (unless (and (eq? (endpoint-pump-result-status result) 'committed)
                 (= (length (endpoint-pump-result-values result)) 1))
      (fail "one-time authority self-test did not commit exactly once"))
    (car (endpoint-pump-result-values result))))

(define (run-stale-presentation-test!)
  (let ((host (make-book-session-host)) (endpoint #f) (peer #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host "stale-selftest"))
          (lambda (new-endpoint new-peer)
            (set! endpoint new-endpoint)
            (set! peer new-peer)))
        (send-raw-frame! peer '(("type" . "hello") ("version" . 1)))
        (single-committed-value endpoint)
        (let ((action (host-action! endpoint "stale-action"
                                    "nonce=stale-913")))
          (navigate! endpoint)
          (send-raw-frame!
           peer
           `(("type" . "present")
             ("request_id" . ,(assoc-ref action "request_id"))
             ("action_id" . ,(assoc-ref action "action_id"))
             ("surface_handle" . ,(assoc-ref action "surface_handle"))
             ("surface_generation" . ,(assoc-ref action
                                                  "surface_generation"))
             ("sequence" . ,(assoc-ref action "sequence"))
             ("count" . 1)
             ("text" . "must-not-commit"))))
        (let ((rejected?
               (catch 'book-session-error
                 (lambda () (endpoint-pump-input! endpoint) #f)
                 (lambda (key kind message) (eq? kind 'state)))))
          (unless (and rejected?
                       (= (snapshot endpoint "pending_requests") 0)
                       (= (snapshot endpoint "surface_generation") 2))
            (fail "one-time stale presentation self-test did not reject"))))
      (lambda ()
        (when endpoint (release-test-endpoint! endpoint peer))))))

(define (run-close-before-frame-finish-test!)
  (let ((host (make-book-session-host)) (endpoint #f) (peer #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host "truncated-selftest"))
          (lambda (new-endpoint new-peer)
            (set! endpoint new-endpoint)
            (set! peer new-peer)))
        ;; Header says ten payload bytes; only two arrive before peer close.
        (put-bytevector peer #vu8(0 0 0 10 123 125))
        (force-output peer)
        (close-port-quietly! peer)
        (set! peer #f)
        (let ((rejected?
               (catch 'book-protocol-error
                 (lambda () (endpoint-pump-input! endpoint) #f)
                 (lambda arguments #t))))
          (unless (and rejected?
                       (eq? (snapshot endpoint "state") 'closed)
                       (not (snapshot endpoint "transport_open")))
            (fail "one-time close-before-frame-finish self-test did not reject"))))
      (lambda ()
        (when endpoint (release-test-endpoint! endpoint peer))))))

(define (run-protocol-self-tests!)
  (run-schema-rejection-test!)
  (run-stale-presentation-test!)
  (run-close-before-frame-finish-test!)
  #t)

(define* (run-protocol-pair!
          guile-bundle python-bundle
          #:key
          (evidence-mode 'guest-runsc)
          (runtime-override #f)
          (timeout-seconds
           (if (eq? evidence-mode 'guest-runsc)
               whole-run-timeout-seconds host-test-timeout-seconds))
          (diagnostic-wrapper
           (if (eq? evidence-mode 'guest-runsc)
               (smoke-private 'call-with-diagnostic-stores)
               (lambda (_bundle thunk) (thunk '()))))
          (cgroup-preflight
           (if (eq? evidence-mode 'guest-runsc)
               assert-cgroup2-preflight!
               (lambda (_container-id) #t)))
          (post-store-check
           (if (eq? evidence-mode 'guest-runsc)
               assert-diagnostic-stores-unmounted!
               (lambda (_bundle) #t)))
          (marker-emitter
           (if (eq? evidence-mode 'guest-runsc)
               (smoke-private 'emit)
               (lambda (_marker) #t))))
  (unless (and (number? timeout-seconds) (> timeout-seconds 0))
    (fail "whole-run timeout must be positive"))
  (when (and (eq? evidence-mode 'guest-runsc)
             (not source-provenance-checked?))
    (fail "guest-runsc evidence requires checked source/profile provenance"))
  (let ((host (make-book-session-host))
        (deadline (+ (now-seconds) timeout-seconds))
        (guile-actions
         (make-nonce-actions guile-action-specs "g" guile-computed-text))
        (python-actions
         (make-nonce-actions python-action-specs "p" python-computed-text)))
    (run-one-book!
     host "guile" guile-actions guile-bundle
     "wilkbook-guile-book-protocol" deadline evidence-mode runtime-override
     diagnostic-wrapper cgroup-preflight post-store-check marker-emitter
     "BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS")
    (run-one-book!
     host "python" python-actions python-bundle
     "wilkbook-python-book-protocol" deadline evidence-mode runtime-override
     diagnostic-wrapper cgroup-preflight post-store-check marker-emitter
     "BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS")
    #t))

(define (read-language-closure path)
  (let ((closure ((smoke-private 'read-closure) path)))
    (unless (= (length closure) expected-language-closure-count)
      (fail "sandbox language closure changed: expected ~a paths, got ~a"
            expected-language-closure-count (length closure)))
    closure))

(define (run-guest arguments)
  (match arguments
    ((base-oci-source protocol-oci-source profile closure-file
      guile-book python-book guile-protocol blocking-protocol python-protocol
      guest-smoke book-session guest-adapter expected-guest-adapter-sha256
      expected-kernel-release)
     (define work-root "/run/wilkbook-book-protocol-gate")
     (define guile-bundle (string-append work-root "/guile"))
     (define python-bundle (string-append work-root "/python"))
     (when (lstat-or-false work-root)
       (fail "refusing stale guest work root: ~a" work-root))
     (mkdir work-root #o700)
     (chmod work-root #o700)
     (let ((closure
            (assert-source-provenance!
             profile closure-file guest-smoke base-oci-source
             protocol-oci-source guest-adapter expected-guest-adapter-sha256
             guile-book python-book guile-protocol blocking-protocol
             python-protocol book-session)))
       ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-SOURCE-PROVENANCE-PASS")
     ((smoke-private 'assert-kernel) expected-kernel-release)
     ((smoke-private 'assert-host-boundaries))
     ((smoke-private 'assert-sidecar-layout))
     ((smoke-private 'run-version) work-root)
     (run-protocol-self-tests!)
     ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-SCHEMA-REJECTION-PASS")
     ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-STALE-REJECTION-PASS")
     ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-TRUNCATED-CLOSE-PASS")
     ;; Load the frozen validator first; the fixed protocol generator imports
     ;; it and has no standalone CLI or arbitrary-program selector.
     (primitive-load base-oci-source)
     (primitive-load protocol-oci-source)
     (let* ((module (resolve-module '(oci-book-bundle)))
            (generate-guile
             (module-ref module 'generate-guile-protocol-bundle))
            (generate-python
             (module-ref module 'generate-python-protocol-bundle)))
       (generate-guile
        #:profile-input profile
        #:book-entry-input guile-book
        #:protocol-input guile-protocol
        #:blocking-input blocking-protocol
        #:bundle-input guile-bundle
        #:container-id "wilkbook-guile-book-protocol"
        #:requisites-runner (lambda (_profile) closure))
       (generate-python
        #:profile-input profile
        #:book-entry-input python-book
        #:protocol-input python-protocol
        #:bundle-input python-bundle
        #:container-id "wilkbook-python-book-protocol"
        #:requisites-runner (lambda (_profile) closure))
       (run-protocol-pair! guile-bundle python-bundle)))
     (for-each
      (lambda (container-id)
        (when (lstat-or-false
               (string-append "/sys/fs/cgroup/wilkbook-execution-"
                              container-id))
          (fail "final cgroup teardown check failed: ~a" container-id)))
      '("wilkbook-guile-book-protocol" "wilkbook-python-book-protocol"))
     ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-CGROUP-TEARDOWN-PASS")
     ((smoke-private 'emit) "BOOKEXEC-PROTOCOL-PASS")
     0)
    (_
     (fail "expected BASE-OCI PROTOCOL-OCI PROFILE CLOSURE GUILE-BOOK PYTHON-BOOK GUILE-PROTOCOL BLOCKING-PROTOCOL PYTHON-PROTOCOL GUEST-SMOKE BOOK-SESSION GUEST-ADAPTER GUEST-ADAPTER-SHA256 KERNEL-RELEASE"))))

(define (guest-book-protocol-main argv)
  (catch #t
    (lambda () (run-guest (cdr argv)))
    (lambda (key . arguments)
      (catch #t
        (lambda ()
          ((smoke-private 'emit)
           (format #f "BOOKEXEC-PROTOCOL-FAIL ~a ~s" key arguments)))
        (lambda secondary #f))
      1)))

(sigaction SIGPIPE SIG_IGN)
