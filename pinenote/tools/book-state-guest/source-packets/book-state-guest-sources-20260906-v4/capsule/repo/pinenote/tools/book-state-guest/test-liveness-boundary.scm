;;; Bounded host test for BSG-2's two liveness classes.  It calls the real
;;; authority stop poll and the real accepted outer process guardian.  QEMU,
;;; runsc, target code, SQLite, mounts, and devices are not used.
(use-modules (book-state-guest-authority)
             (disposable-qemu)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define (join-path . parts) (string-join parts "/"))
(define tool (canonicalize-path (cadr (command-line))))
(define guile (canonicalize-path (caddr (command-line))))
(define repo (canonicalize-path (join-path tool ".." ".." "..")))
(define execution (join-path repo "pinenote" "tools" "book-execution-spike"))
(define ui (join-path repo "pinenote" "tools" "book-state-reader"))
(define join (join-path repo "pinenote" "tools" "book-state-reader-join"))
(define protocol (join-path repo "pinenote" "tools" "book-protocol"))
(define backend (join-path repo "pinenote" "tools" "book-state"))
(define state (join-path repo "pinenote" "tools" "book-state-protocol"))
(define session (join-path state "session-integration"))
(define fixture (join-path tool "test-liveness-fixture.scm"))
(define scratch
  (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp/opencode")
                            "/book-state-guest-liveness.XXXXXX")))
(chmod scratch #o700)

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (fixture-argv mode record)
  (append
   (list guile "--no-auto-compile")
   (append-map (lambda (path) (list "-L" path))
               (list tool execution ui join
                     (join-path join "empty-action-successor")
                     protocol backend state session))
   (list "-l" (join-path execution "guest-book-protocol.scm")
         "-s" fixture mode record)))

(define (fixture-environment)
  (append
   (list "GUILE_AUTO_COMPILE=0"
         "LANG=C.UTF-8"
         "LC_ALL=C.UTF-8"
         (string-append "HOME=" scratch)
         (string-append "TMPDIR=" scratch))
   (filter-map
    (lambda (name)
      (let ((value (getenv name)))
        (and value (string-append name "=" value))))
    '("GUILE_LOAD_PATH" "GUILE_LOAD_COMPILED_PATH"
      "GUILE_EXTENSIONS_PATH" "LTDL_LIBRARY_PATH"))))

(define (read-all path)
  (call-with-input-file path get-string-all))

(define (read-one path)
  (call-with-input-file path
    (lambda (port)
      (let ((value (read port)) (tail (read port)))
        (unless (eof-object? tail) (error "trailing process record" path))
        value))))

(define (process-group-gone? group)
  (catch 'system-error
    (lambda () (kill (- group) 0) #f)
    (lambda arguments
      (= (system-error-errno arguments) ESRCH))))

(define (close-quietly port)
  (when (and port (not (port-closed? port))) (close-port port)))

(define (progress label)
  (format #t "LIVENESS-TEST stage=~a~%" label)
  (force-output))

(test-begin "book-state-guest-liveness-boundary")
(define runner (test-runner-current))

;; The repaired production wait polls with WNOHANG and returns control when its
;; cooperative deadline expires.  Its ordinary failure cleanup kills/reaps the
;; exact child without waiting for the hard outer boundary.
(progress "cooperative-child-start")
(let* ((record (join-path scratch "never-stop.record"))
       (stdout (open-output-file (join-path scratch "never-stop.stdout")))
       (stderr (open-output-file (join-path scratch "never-stop.stderr")))
       (null (open-input-file "/dev/null"))
       (pid (spawn guile (fixture-argv "never-stop" record)
                   #:search-path? #f
                   #:environment (fixture-environment)
                   #:input null #:output stdout #:error stderr))
       (started (now-seconds))
       (expired? #f)
       (reaped? #f))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (set! expired?
            (catch 'book-state-guest-error
              (lambda ()
                ((@@ (book-state-guest-authority) wait-for-stopped-child!)
                 pid (+ (now-seconds) 0.15))
                #f)
              (lambda arguments #t))))
    (lambda ()
      (set! reaped?
            ((@@ (book-state-guest-authority)
                 kill-and-reap-child/best-effort!) pid))
      (for-each close-quietly (list null stdout stderr))))
  (test-assert "non-stopping adapter child reaches cooperative deadline"
    expired?)
  (test-assert "non-stopping adapter child deadline returns promptly"
    (< (- (now-seconds) started) 2.0))
  (test-assert "ordinary adapter-start failure reaps its exact child"
    reaped?))
(progress "cooperative-child-complete")

(define (run-outer-case mode expected-lines forbidden-lines)
  (progress (string-append mode "-start"))
  (let* ((stdout-path (join-path scratch (string-append mode ".stdout")))
         (stderr-path (join-path scratch (string-append mode ".stderr")))
         (record-path (join-path scratch (string-append mode ".record")))
         (root-liveness (pipe))
         (started (now-seconds))
         (result
          ((@@ (disposable-qemu) run-owned-process)
           (fixture-argv mode record-path) (fixture-environment) scratch
           stdout-path stderr-path 1.20 0.10 (cdr root-liveness)))
         (elapsed (- (now-seconds) started))
         (output (read-all stdout-path))
         (record (read-one record-path))
         (group (assq-ref record 'process-group)))
    (for-each close-quietly
              (list (car root-liveness) (cdr root-liveness)))
    (test-equal (string-append mode " is reported as an outer timeout")
      '(124 . #t) result)
    (test-assert (string-append mode " reaches every pre-block marker")
      (every (lambda (line) (string-contains output line)) expected-lines))
    (test-assert (string-append mode " synthesizes no cleanup or success")
      (every (lambda (line) (not (string-contains output line)))
             (append forbidden-lines
                     '("result=pass" "SYNC-COMPLETE" "HALT-REQUESTED"))))
    (test-assert (string-append mode " hard owner returns within its bound")
      (< elapsed 4.0))
    (test-assert (string-append mode " exact process group is gone and reaped")
      (and (= group (assq-ref record 'direct-process))
           (process-group-gone? group)))
  (progress (string-append mode "-complete"))))

(run-outer-case
 "blocking-waitpid"
 '("INTENTIONAL-BLOCKING-WAITPID-ENTERED")
 '("FORBIDDEN-WAITPID-RETURN"))
(run-outer-case
 "blocked-revoke"
 '("BLOCKED-DELEGATE-WORKER-ENTERED"
   "GUEST-COOPERATIVE-BUDGET-EXPIRED"
   "DELEGATE-LOCAL-CLOSE-COMPLETE"
   "DELEGATE-CLOSE-WAIT-ENTERED mode=revoke"
   "DELEGATE-REVOKE-WAIT-ENTERED")
 '("FORBIDDEN-DELEGATE-CLOSE-RETURN"))
(run-outer-case
 "blocked-join"
 '("BLOCKED-DELEGATE-WORKER-ENTERED"
   "GUEST-COOPERATIVE-BUDGET-EXPIRED"
   "DELEGATE-LOCAL-CLOSE-COMPLETE"
   "DELEGATE-CLOSE-WAIT-ENTERED mode=join"
   "DELEGATE-REVOKE-RETURNED")
 '("FORBIDDEN-DELEGATE-CLOSE-RETURN"))

(test-end "book-state-guest-liveness-boundary")
(for-each
 (lambda (name)
   (unless (member name '("." ".."))
     (delete-file (join-path scratch name))))
 (scandir scratch))
(rmdir scratch)
(when (positive? (test-runner-fail-count runner)) (exit 1))
