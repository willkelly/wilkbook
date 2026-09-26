;;; Fixed adversarial programs for the real sandbox only. The host tests inject
;;; callback results; they never execute these allocation/fork/access probes.
(define-module (resource-scenario)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (run-resource-scenario!))

(define (source forms)
  (string-join (map (lambda (form) (format #f "~s" form)) forms) "\n"))

(define access-source
  (source
   '((use-modules (ice-9 textual-ports))
     (define (denied label thunk expected)
       (let ((errno (catch 'system-error (lambda () (thunk) #f)
                      (lambda args (system-error-errno args)))))
         (unless (memv errno expected)
           (error "unexpected access outcome" label errno))
         errno))
     (define (workbench path)
       ;; PATH names a real host-only canary, verified before and after by the
       ;; authority. Test positive access too, so a broken interpreter cannot
       ;; masquerade as confinement. No external network endpoint is contacted.
       (unless (positive? (string-length
                           (call-with-input-file "/book/program.scm" get-string-all)))
         (error "source read failed"))
       (denied 'host-canary (lambda () (open-input-file path)) (list ENOENT))
       (call-with-output-file "/scratch/probe"
         (lambda (port) (display "scratch-ok" port)))
       (unless (equal? (call-with-input-file "/scratch/probe" get-string-all) "scratch-ok")
         (error "scratch is not usable"))
       ;; Gofer checks DAC before CheckBeginWrite, for existing-file opens and
       ;; file creation alike. These paths are not DAC-writable by UID 65534.
       ;; Report exact denials, without claiming isolated read-only enforcement.
       (let ((source (denied 'source-write (lambda () (open-file "/book/program.scm" "a"))
                             (list EACCES EROFS)))
             (root (denied 'root-write (lambda () (open-file "/unexpected-write" "w"))
                           (list EACCES EROFS))))
         (string-append (if (= source EROFS) "EROFS" "EACCES") "/"
                        (if (= root EROFS) "EROFS" "EACCES")))))))

(define memory-source
  (source
   '((use-modules (rnrs bytevectors))
     (define (workbench text)
       ;; Retain and touch 384 MiB, exceeding memory.max=256 MiB. A small pause
       ;; between 8 MiB chunks gives the trusted observer a chance to sample.
       ;; The wall deadline remains the backstop; timeout is not an OOM pass.
       (let loop ((chunks '()) (remaining 48))
         (if (zero? remaining)
             (number->string (apply + (map bytevector-length chunks)))
             (let ((chunk (make-bytevector 8388608 73)))
               (usleep 20000)
               (loop (cons chunk chunks) (- remaining 1)))))))))

(define tasks-source
  (source
   '((define (workbench text)
       ;; Every signal targets an unreaped direct child. This probe is bounded
       ;; even if neither the guest NPROC nor the host task limit is enforced.
       (let ((children '()) (refused? #f))
         (dynamic-wind
           (lambda () #t)
           (lambda ()
             (let loop ((remaining 48))
               (when (and (positive? remaining) (not refused?))
                 (catch 'system-error
                   (lambda ()
                     (let ((pid (primitive-fork)))
                       (if (zero? pid)
                           (begin (sleep 10) (primitive-exit 0))
                           (set! children (cons pid children)))))
                   (lambda args
                     (if (= (system-error-errno args) EAGAIN)
                         (set! refused? #t)
                         (apply throw args))))
                 (loop (- remaining 1))))
             (unless (and refused? (pair? children))
               (error "no bounded task refusal after successful fork")))
           (lambda ()
             (for-each (lambda (pid) (kill pid SIGKILL)) children)
             (for-each (lambda (pid) (waitpid pid)) children)))
         "task-eagain-after-fork")))))

(define recovery-source "(define (workbench text) (string-append \"recovered: \" text))")

(define (counter sample file key)
  (let ((text (assoc-ref (or (assoc-ref sample 'files) '()) file)))
    (and (string? text)
         (let ((rows (filter (lambda (row) (and (pair? row) (string=? (car row) key)))
                             (map string-tokenize (string-split text #\newline)))))
           (and (= (length rows) 1) (= (length (car rows)) 2)
                (let ((value (cadar rows)))
                  (and (positive? (string-length value))
                       (every (lambda (char) (char<=? #\0 char #\9)) (string->list value))
                       (string->number value))))))))

(define (run-resource-scenario! preview canary-path canary-unchanged?)
  (let ((checks 0))
    (define (check label condition)
      (unless condition (throw 'workbench-resource-failed label))
      (set! checks (+ checks 1))
      (format #t "BOOK_WORKBENCH_RESOURCE: check=~a status=pass~%" label)
      (force-output))
    (define (execute program input)
      (let ((result (preview program input)))
        (check 'action-delivered (eq? (assoc-ref result 'execution-started?) #t))
        (check 'execution-cleaned (eq? (assoc-ref result 'cleanup-complete?) #t))
        result))
    (define (ok? result text)
      (and (eq? (assoc-ref result 'status) 'ok) (equal? (assoc-ref result 'text) text)))
    (define (recover!)
      (check 'runtime-reusable (ok? (execute recovery-source "resource-probe")
                                   "recovered: resource-probe")))
    (check 'host-canary-exists (canary-unchanged?))
    (let* ((result (execute access-source canary-path))
           (text (assoc-ref result 'text)))
      (check 'filesystem-access
             (and (eq? (assoc-ref result 'status) 'ok)
                  (member text '("EACCES/EACCES" "EACCES/EROFS" "EROFS/EACCES" "EROFS/EROFS"))))
      ;; Emit only a whitelisted enum, never arbitrary authored output.
      (format #t "BOOK_WORKBENCH_ACCESS: source/root-write-errno=~a~%" text)
      (force-output))
    (check 'host-canary-preserved (canary-unchanged?))
    (recover!)
    (let* ((result (execute tasks-source "tasks"))
           (observations (or (assoc-ref result 'resource-observations) '()))
           (before (or (assoc-ref observations 'dispatch) '()))
           (after (or (assoc-ref observations 'last) '()))
           (start (counter before "pids.events" "max"))
           (end (counter after "pids.events" "max"))
           (guest-refused? (ok? result "task-eagain-after-fork"))
           (host-hit? (and (eq? (assoc-ref result 'status) 'failed)
                           (eq? (assoc-ref before 'controls-match?) #t)
                           (eq? (assoc-ref after 'controls-match?) #t)
                           start end (zero? start) (> end start))))
      ;; Host task exhaustion may terminate Sentry before it can reply. Count
      ;; only a kernel limit event after the dispatch baseline, never generic
      ;; runtime failure. This is containment, not graceful guest refusal or
      ;; exclusive attribution of the runtime's exit to that event.
      (check 'task-pressure-contained (or guest-refused? host-hit?))
      (format #t "BOOK_WORKBENCH_TASKS: outcome=~a~%"
              (if guest-refused? "guest-eagain" "host-pids-limit-hit"))
      (force-output))
    (recover!)
    (let* ((result (execute memory-source "memory"))
           (observations (or (assoc-ref result 'resource-observations) '()))
           (first (or (assoc-ref observations 'dispatch) '()))
           (last (or (assoc-ref observations 'last) '()))
           (increments?
            (every (lambda (key)
                     (let ((before (counter first "memory.events" key))
                           (after (counter last "memory.events" key)))
                       (and before after (zero? before) (> after before))))
                   '("max" "oom" "oom_kill"))))
      ;; A generic failure, allocation exception, SIGKILL or wall timeout is not
      ;; memory evidence. oom_kill alone includes global OOM; require max/oom
      ;; events too. A later cleanup RPC cannot create those kernel events.
      ;; Runsc can remove the cgroup before the observer reads terminal counters;
      ;; missing evidence is inconclusive, never proof that limits were absent.
      ;; These samples establish limit pressure and an OOM kill in this group,
      ;; not exclusive attribution of the kill or complete support accounting.
      (check 'memory-limit-evidence-complete
             (and (eq? (assoc-ref result 'status) 'failed)
                  (eq? (assoc-ref first 'controls-match?) #t)
                  (eq? (assoc-ref last 'controls-match?) #t)
                  increments?)))
    (recover!)
    `((status . pass) (checks . ,checks))))
