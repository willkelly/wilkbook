;;; Trusted host-only rehearsal for donating one Book Session peer to each
;;; future runsc process.  This does not execute runsc in the host test: a
;;; strict fake validates the exact CLI and execs the two native fixture books.
(use-modules (book-session)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             ((rnrs io ports) #:select (get-u8 put-u8))
             (srfi srfi-1)
             (srfi srfi-9))

(define fixture-deadline-seconds 15)
(define scheduler-sleep-microseconds 5000)
(define guest-fd 3)

(define-record-type <owned-runsc>
  (make-owned-runsc name pid start-time process-group record-path status)
  owned-runsc?
  (name owned-runsc-name)
  (pid owned-runsc-pid)
  (start-time owned-runsc-start-time)
  (process-group owned-runsc-process-group)
  (record-path owned-runsc-record-path)
  (status owned-runsc-status set-owned-runsc-status!))

(define-record-type <fixture-peer>
  (make-fixture-peer label endpoint donation child phase action-id input
                     expected)
  fixture-peer?
  (label fixture-peer-label)
  (endpoint fixture-peer-endpoint)
  (donation fixture-peer-donation set-fixture-peer-donation!)
  (child fixture-peer-child set-fixture-peer-child!)
  (phase fixture-peer-phase set-fixture-peer-phase!)
  (action-id fixture-peer-action-id)
  (input fixture-peer-input)
  (expected fixture-peer-expected))

(define (fail message . arguments)
  (error (apply format #f message arguments)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

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

(define (close-unrelated-fds!)
  ;; SCANDIR closes its own descriptor before this returned list is consumed.
  ;; At exec, only stdio and this child's selected donation may remain.
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

(define (clear-close-on-exec! fd)
  (let ((flags (fcntl fd F_GETFD)))
    (when (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logand flags (lognot FD_CLOEXEC))))
    (when (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
      (fail "donated FD ~a remained close-on-exec" fd))))

(define (assert-exec-fds!)
  (let ((unexpected
         (filter-map
          (lambda (entry)
            (let ((fd (string->number entry 10)))
              (and fd (> fd guest-fd)
                   (catch 'system-error
                     (lambda () (fcntl fd F_GETFD) fd)
                     (lambda arguments #f)))))
          (scandir "/proc/self/fd"
                   (lambda (entry)
                     (and (not (member entry '("." "..")))
                          (string->number entry 10)))))))
    (unless (null? unexpected)
      (fail "runsc child retained unrelated descriptors: ~s" unexpected)))
  (fcntl guest-fd F_GETFD)
  (clear-close-on-exec! guest-fd))

(define pinned-runtime-flags
  '("--platform=systrap"
    "--network=none"
    "--sidecar-usage-policy=strict"
    "--sidecar-release-enforcement-policy=always"
    "--ignore-cgroups=false"
    "--host-uds=none"
    "--host-fifo=none"
    "--character-device-policy=emulated-only"
    "--allow-suid=false"
    "--allow-flag-override=false"
    "--allow-rootfs-tar-annotation=false"
    "--overlay2=none"
    "--rootless=false"
    "--file-access=exclusive"
    "--file-access-mounts=exclusive"
    "--net-raw=false"
    "--allow-packet-socket-write=false"
    "--directfs=false"))

(define (runsc-arguments root bundle container-id)
  (append (list (string-append "--root=" root))
          pinned-runtime-flags
          (list "run"
                "--pass-fd=3:3"
                (string-append "--bundle=" bundle)
                container-id)))

(define (child-exec! gate-input donation runsc arguments run-directory)
  (close-port-quietly! gate-input)
  (let ((null-input (open-file "/dev/null" "r"))
        (null-output (open-file "/dev/null" "w")))
    (dup2 (fileno null-input) 0)
    (dup2 (fileno null-output) 1)
    (dup2 (fileno null-output) 2)
    (dup2 (fileno donation) guest-fd)
    ;; dup2 clears CLOEXEC when it changes the number; clear it explicitly too
    ;; because the socketpair peer may already have numeric descriptor 3.
    (clear-close-on-exec! guest-fd)
    (close-unrelated-fds!)
    (assert-exec-fds!)
    (for-each (lambda (signal-number)
                (sigaction signal-number SIG_DFL))
              (list SIGINT SIGHUP SIGTERM SIGPIPE SIGCHLD))
    (environ
     (list "HOME=/nonexistent"
           "LANG=C"
           "LC_ALL=C"
           "PATH=/run/current-system/profile/bin"
           (string-append "TMPDIR=" run-directory "/tmp")))
    (chdir run-directory)
    (apply execl runsc runsc arguments)))

(define (spawn-owned-runsc name record-path donation runsc arguments
                           run-directory)
  (let* ((gate (pipe O_CLOEXEC))
         (gate-input (car gate))
         (gate-output (cdr gate))
         (pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (close-port-quietly! gate-output)
          (catch #t
            (lambda () (setpgid 0 0))
            (lambda arguments (primitive-exit 125)))
          (let ((released (get-u8 gate-input)))
            (if (and (integer? released) (= released 1))
                (catch #t
                  (lambda ()
                    (child-exec! gate-input donation runsc arguments
                                 run-directory)
                    (primitive-exit 127))
                  (lambda arguments (primitive-exit 127)))
                (primitive-exit 126))))
        (begin
          (close-port-quietly! gate-input)
          (let ((published? #f))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                ;; The child is still behind the gate. Make its dedicated
                ;; process group explicit from both sides before publication.
                (catch 'system-error
                  (lambda () (setpgid pid pid))
                  (lambda arguments
                    (unless (memv (system-error-errno arguments)
                                  (list EACCES EPERM))
                      (apply throw arguments))))
                (let ((start-time (await-process-start-time pid)))
                  (write-process-record! record-path pid start-time pid)
                  (put-u8 gate-output 1)
                  (force-output gate-output)
                  (close-port-quietly! gate-output)
                  (set! published? #t)
                  (make-owned-runsc name pid start-time pid record-path #f)))
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

(define (reap-owned-runsc! child)
  (unless (owned-runsc-status child)
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid (owned-runsc-pid child) WNOHANG))
             (lambda arguments
               (if (= (system-error-errno arguments) ECHILD)
                   #f
                   (apply throw arguments))))))
      (when (and waited (not (zero? (car waited))))
        (set-owned-runsc-status!
         child (decode-child-status (cdr waited))))))
  (owned-runsc-status child))

(define (process-group-exists? process-group)
  (catch 'system-error
    (lambda () (kill (- process-group) 0) #t)
    (lambda arguments
      (not (= (system-error-errno arguments) ESRCH)))))

(define (signal-group! process-group signal-number)
  (catch 'system-error
    (lambda () (kill (- process-group) signal-number))
    (lambda arguments
      (unless (= (system-error-errno arguments) ESRCH)
        (apply throw arguments)))))

(define (wait-child-and-group! child deadline)
  (let loop ()
    (reap-owned-runsc! child)
    (if (and (owned-runsc-status child)
             (not (process-group-exists?
                   (owned-runsc-process-group child))))
        #t
        (and (< (now-ticks) deadline)
             (begin (usleep 20000) (loop))))))

(define (terminate-owned-runsc! child)
  (when child
    (reap-owned-runsc! child)
    (when (process-group-exists? (owned-runsc-process-group child))
      (signal-group! (owned-runsc-process-group child) SIGTERM)
      (unless (wait-child-and-group!
               child
               (+ (now-ticks)
                  (* 2 internal-time-units-per-second)))
        (signal-group! (owned-runsc-process-group child) SIGKILL)
        (unless (wait-child-and-group!
                 child
                 (+ (now-ticks)
                    (* 2 internal-time-units-per-second)))
          (fail "owned runsc group survived SIGKILL: ~a"
                (owned-runsc-name child)))))
    (unless (owned-runsc-status child)
      (catch 'system-error
        (lambda ()
          (let ((waited (waitpid (owned-runsc-pid child))))
            (set-owned-runsc-status!
             child (decode-child-status (cdr waited)))))
        (lambda arguments
          (unless (= (system-error-errno arguments) ECHILD)
            (apply throw arguments)))))
    (when (file-exists? (owned-runsc-record-path child))
      (delete-file (owned-runsc-record-path child)))))

(define (snapshot endpoint name)
  (let ((entry (assoc name (host-session-snapshot endpoint))))
    (and entry (cdr entry))))

(define (handle-committed! peer value)
  (case (fixture-peer-phase peer)
    ((hello)
     (unless (and (list? value)
                  (equal? (assoc-ref value "type") "initialize"))
       (fail "~a did not produce initialize after hello"
             (fixture-peer-label peer)))
     (endpoint-queue-message! (fixture-peer-endpoint peer) value)
     (endpoint-queue-message!
      (fixture-peer-endpoint peer)
      (host-action! (fixture-peer-endpoint peer)
                    (fixture-peer-action-id peer)
                    (fixture-peer-input peer)))
     (set-fixture-peer-phase! peer 'present))
    ((present)
     (unless (and (presented-text? value)
                  (string=? (presented-text-action-id value)
                            (fixture-peer-action-id peer))
                  (string=? (presented-text-value value)
                            (fixture-peer-expected peer)))
       (fail "~a returned the wrong presentation"
             (fixture-peer-label peer)))
     (set-fixture-peer-phase! peer 'done))
    (else
     (fail "~a produced a duplicate committed value"
           (fixture-peer-label peer)))))

(define (pump-peer! peer)
  (let ((endpoint (fixture-peer-endpoint peer)))
    (when (and (not (eq? (fixture-peer-phase peer) 'done))
               (memq 'input (endpoint-ready-events endpoint)))
      (let ((result (endpoint-pump-input! endpoint)))
        (case (endpoint-pump-result-status result)
          ((committed)
           (let ((values (endpoint-pump-result-values result)))
             (unless (= (length values) 1)
               (fail "~a input pump did not commit exactly once"
                     (fixture-peer-label peer)))
             (handle-committed! peer (car values))))
          ((eof closed)
           (unless (eq? (fixture-peer-phase peer) 'done)
             (fail "~a transport closed before present"
                   (fixture-peer-label peer))))
          ((would-block interrupted budget stale) #t)
          (else
           (fail "~a returned unknown input status ~s"
                 (fixture-peer-label peer)
                 (endpoint-pump-result-status result))))))
    (when (> (snapshot endpoint "outbound_frames") 0)
      (endpoint-pump-output! endpoint))))

(define (peer-finished? peer)
  (let ((status (reap-owned-runsc! (fixture-peer-child peer))))
    (when (and status (not (equal? status '(exit . 0))))
      (fail "~a runsc process failed: ~s" (fixture-peer-label peer) status))
    (and (eq? (fixture-peer-phase peer) 'done)
         (equal? status '(exit . 0))
         (not (process-group-exists?
               (owned-runsc-process-group (fixture-peer-child peer)))))))

(define (new-fixture-peer host label action-id input expected)
  (call-with-values
      (lambda () (open-session-endpoint! host label))
    (lambda (endpoint donation)
      (make-fixture-peer label endpoint donation #f 'hello action-id input
                         expected))))

(define (start-peer! peer run-directory runsc bundle container-id)
  (let* ((root (string-append run-directory "/runsc-state-"
                              (fixture-peer-label peer)))
         (record (string-append run-directory "/runsc-"
                                (fixture-peer-label peer) ".pid")))
    (mkdir root #o700)
    (set-fixture-peer-child!
     peer
     (spawn-owned-runsc
      (fixture-peer-label peer) record (fixture-peer-donation peer) runsc
      (runsc-arguments root bundle container-id) run-directory))
    (close-port-quietly! (fixture-peer-donation peer))
    (set-fixture-peer-donation! peer #f)))

(define (release-peer! peer)
  (when peer
    (catch #t
      (lambda () (release-session-endpoint! (fixture-peer-endpoint peer)))
      (lambda arguments
        (close-session! (fixture-peer-endpoint peer))))
    (close-port-quietly! (fixture-peer-donation peer))
    (set-fixture-peer-donation! peer #f)
    (terminate-owned-runsc! (fixture-peer-child peer))))

(define (require-directory path label)
  (let ((canonical (canonicalize-path path)))
    (unless (eq? (stat:type (stat canonical)) 'directory)
      (fail "~a must be a directory" label))
    canonical))

(define (run-fixture run-directory runsc guile-bundle python-bundle)
  (let* ((run-directory (require-directory run-directory "run directory"))
         (guile-bundle (require-directory guile-bundle "Guile bundle"))
         (python-bundle (require-directory python-bundle "Python bundle"))
         (runsc (canonicalize-path runsc))
         (host (make-book-session-host))
         (guile-peer #f)
         (python-peer #f)
         (completed? #f))
    (unless (and (eq? (stat:type (stat runsc)) 'regular)
                 (access? runsc X_OK))
      (fail "runsc path must be an executable regular file"))
    (mkdir (string-append run-directory "/tmp") #o700)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! guile-peer
              (new-fixture-peer host "guile" "guile-action" "Ada"
                                "Guile book: ADA"))
        (set! python-peer
              (new-fixture-peer host "python" "python-action" "élan λ"
                                "Python book: ÉLAN Λ"))
        ;; Both endpoints exist before either fork. Child-side FD hygiene must
        ;; therefore remove the sibling peer and both private authority FDs.
        (start-peer! guile-peer run-directory runsc guile-bundle
                     "wilkbook-guile-protocol-fixture")
        (start-peer! python-peer run-directory runsc python-bundle
                     "wilkbook-python-protocol-fixture")
        (let ((deadline (after-seconds fixture-deadline-seconds)))
          (let loop ()
            (when (> (now-ticks) deadline)
              (fail "protocol fixture exceeded its whole-run deadline"))
            (pump-peer! guile-peer)
            (pump-peer! python-peer)
            (if (and (peer-finished? guile-peer)
                     (peer-finished? python-peer))
                (set! completed? #t)
                (begin
                  (usleep scheduler-sleep-microseconds)
                  (loop)))))
        (format #t "BOOKEXEC-PROTOCOL-FIXTURE=PASS peers=2 transport=fd3~%")
        (force-output))
      (lambda ()
        (release-peer! python-peer)
        (release-peer! guile-peer)
        (unless completed?
          (force-output (current-error-port)))))))

(define (main arguments)
  (unless (= (length arguments) 4)
    (format (current-error-port)
            "usage: protocol-host.scm RUN_DIRECTORY RUNSC GUILE_BUNDLE PYTHON_BUNDLE~%")
    (exit 2))
  (match arguments
    ((run-directory runsc guile-bundle python-bundle)
     (run-fixture run-directory runsc guile-bundle python-bundle)
     0)))

(sigaction SIGPIPE SIG_IGN)
(exit
 (catch #t
   (lambda () (main (cdr (command-line))))
   (lambda (key . arguments)
     (format (current-error-port)
             "BOOKEXEC-PROTOCOL-FIXTURE=FAIL key=~s details=~s~%"
             key arguments)
     (force-output (current-error-port))
     1)))
