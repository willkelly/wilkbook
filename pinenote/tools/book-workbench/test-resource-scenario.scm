;;; Oracle tests only: none of the hostile programs runs on the native host.
(use-modules (resource-scenario) (srfi srfi-64) (srfi srfi-1) (system base compile))
(test-begin "workbench-resource-oracle")
(define (sample count)
  `((controls-match? . #t)
    (files . (("memory.events" . ,(format #f "max ~a\noom ~a\noom_kill ~a\n" count count count))))))
(define memory-result
  `((status . failed) (text . "") (execution-started? . #t) (cleanup-complete? . #t)
    (resource-observations . ((dispatch . ,(sample 0)) (last . ,(sample 1))
                              (runtime-owner . ((controls . ()) (forced? . #f)))))))
(define (success text)
  `((status . ok) (text . ,text) (execution-started? . #t) (cleanup-complete? . #t)))
(define* (run results #:optional (canary-check (lambda () #t)))
  (parameterize ((current-output-port (open-output-string)))
    (catch 'workbench-resource-failed
      (lambda ()
        (let ((result (run-resource-scenario!
                       (lambda (_source _text)
                         (when (null? results) (error "unexpected extra callback"))
                         (let ((result (car results))) (set! results (cdr results)) result))
                       "/private/canary" canary-check)))
          (unless (null? results) (error "missing scenario callback"))
          (assoc-ref result 'status)))
      (lambda (_key label) label))))
(define (with-memory result)
  (list (success "EACCES/EACCES") (success "recovered: resource-probe")
        (success "task-eagain-after-fork") (success "recovered: resource-probe") result
        (success "recovered: resource-probe")))
(define (replace values key value)
  (acons key value (filter (lambda (entry) (not (eq? (car entry) key))) values)))
(define (changed-observation key value)
  (replace memory-result 'resource-observations
           (replace (assoc-ref memory-result 'resource-observations) key value)))
(test-eq "full exact evidence passes" 'pass (run (with-memory memory-result)))
(for-each
 (lambda (entry)
   (test-eq (car entry) 'memory-limit-evidence-complete (run (with-memory (cdr entry)))))
 (list
  (cons "generic failure is not enforcement" (replace memory-result 'resource-observations '()))
  (cons "missing counter is not zero"
        (changed-observation 'last (sample "bogus")))
  (cons "existing OOM is not this execution"
        (changed-observation 'dispatch (sample 1)))
  (cons "unchanged zero counters are inconclusive" (changed-observation 'last (sample 0)))
  (cons "mismatched controls refuse"
        (changed-observation 'last (replace (sample 1) 'controls-match? #f)))
  (cons "mismatched first controls refuse"
        (changed-observation 'dispatch (replace (sample 0) 'controls-match? #f)))
  (cons "only oom_kill may be global OOM"
        (changed-observation 'last
                             '((controls-match? . #t)
                               (files . (("memory.events" . "max 0\noom 0\noom_kill 1\n"))))))))
(test-eq "cleanup RPC does not erase independently observed OOM" 'pass
         (run (with-memory (changed-observation 'runtime-owner
                                               '((controls . (("kill" 0))) (forced? . #f))))))
(test-eq "initial canary check refuses" 'host-canary-exists
         (run '() (lambda () #f)))
(let ((calls 0))
  (test-eq "changed canary refuses" 'host-canary-preserved
           (run (list (success "EACCES/EACCES"))
                (lambda () (set! calls (+ calls 1)) (= calls 1)))))
(test-eq "pre-action failure refuses" 'action-delivered
         (run (list (replace (success "EACCES/EACCES") 'execution-started? #f))))
(test-eq "cleanup failure refuses" 'execution-cleaned
         (run (list (replace (success "EACCES/EACCES") 'cleanup-complete? #f))))
(test-eq "wrong access receipt refuses" 'filesystem-access (run (list (success "forged"))))
(test-eq "failed recovery refuses" 'runtime-reusable
         (run (list (success "EACCES/EACCES") (success "wrong-recovery"))))
(define (task-sample count)
  `((controls-match? . #t) (files . (("pids.events" . ,(format #f "max ~a" count))))))
(define task-result
  `((status . failed) (execution-started? . #t) (cleanup-complete? . #t)
    (resource-observations . ((dispatch . ,(task-sample 0)) (last . ,(task-sample 1))))))
(define (with-task result)
  (let ((results (with-memory memory-result)))
    (append (take results 2) (list result) (drop results 3))))
(test-eq "host PID-limit event plus recovery qualifies separately" 'pass (run (with-task task-result)))
(test-eq "generic task failure does not qualify" 'task-pressure-contained
         (run (with-task (replace task-result 'resource-observations '()))))
(test-eq "task event before dispatch does not qualify" 'task-pressure-contained
         (run (with-task (replace task-result 'resource-observations
                                  `((dispatch . ,(task-sample 1)) (last . ,(task-sample 2)))))))
(test-eq "task pressure still requires cleanup" 'execution-cleaned
         (run (with-task (replace task-result 'cleanup-complete? #f))))
(test-eq "task event with mismatched controls refuses" 'task-pressure-contained
         (run (with-task (replace task-result 'resource-observations
                                  `((dispatch . ,(task-sample 0))
                                    (last . ,(replace (task-sample 1) 'controls-match? #f)))))))
;; Read the emitted programs as data. This catches generation syntax mistakes
;; without evaluating resource probes in the explicitly unsandboxed host suite.
(for-each
 (lambda (name)
   (let ((text (module-ref (resolve-module '(resource-scenario)) name)))
     (test-assert (symbol->string name)
       (and (< (string-length text) 8192)
            (call-with-input-string text
              (lambda (port)
                (let loop ((forms '()))
                  (let ((form (read port)))
                    (if (eof-object? form)
                        (and (pair? forms)
                             ;; Compile but never call the resulting program.
                             (compile (cons 'begin (reverse forms))
                                      #:env (make-fresh-user-module) #:to 'bytecode))
                        (loop (cons form forms)))))))))))
 '(access-source memory-source tasks-source))
(let ((failed (test-runner-fail-count (test-runner-current))))
  (test-end "workbench-resource-oracle")
  (exit (if (zero? failed) 0 1)))
