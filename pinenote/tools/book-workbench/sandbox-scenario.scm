;;; The same trusted authoring assertions can run against a native fixture or
;;; the sandbox supervisor. Only the supplied execution callback differs.
(define-module (sandbox-scenario)
  #:use-module (book-workspace)
  #:use-module (workbench-authority)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:export (run-workbench-scenario!))

(define seed
  "(define (workbench text) (string-append \"seed: \" text))\n")
(define successor
  "(define (workbench text) (string-append \"revised: \" (string-upcase text)))\n")

(define (run-workbench-scenario! directory environment preview)
  ;; A test must never repurpose an operator's existing workspace.
  (unless (equal? (scandir directory) '("." ".."))
    (error "Workbench scenario requires an empty private workspace"))
  (let ((store #f) (authority #f) (checks 0) (execution #f))
    (define (check label predicate)
      (unless predicate (throw 'workbench-scenario-failed label))
      (set! checks (+ checks 1))
      ;; Labels are fixed trusted symbols, never authored text or child stdout.
      (format #t "BOOK_WORKBENCH_SCENARIO: check=~a status=pass~%" label)
      (force-output))
    (define (request op . fields)
      (set! execution #f)
      (let ((reply (workbench-request! authority (cons (cons "op" op) fields))))
        ;; Every execution request here is valid. A pre-launch rejection or
        ;; incomplete cleanup must not pass as an expected broken-program test.
        ;; These fields are observations of the trusted execution callback.
        (when (member op '("run" "preview"))
          (check 'execution-started
                 (and execution (eq? (assoc-ref execution 'execution-started?) #t)))
          (check 'execution-cleaned
                 (and execution (eq? (assoc-ref execution 'cleanup-complete?) #t))))
        reply))
    (define (refused label code op . fields)
      (let ((reply (apply request op fields)))
        (check label
               (and (assoc "ok" reply) (eq? (assoc-ref reply "ok") #f)
                    (equal? (assoc-ref reply "op") op)
                    (equal? (assoc-ref reply "error") code)))))
    (define (successful label op . fields)
      (let ((reply (apply request op fields)))
        (unless (eq? (assoc-ref reply "ok") #t)
          (format (current-error-port) "Workbench scenario request failed: ~s ~s~%"
                  label reply))
        (check label (eq? (assoc-ref reply "ok") #t))
        reply))
    (define (snapshot)
      (assoc-ref (successful 'read-snapshot "open") "snapshot"))
    (define (open!)
      (set! store (open-workspace-store directory seed #:environment environment))
      (set! authority
            (make-workbench-authority
             store (lambda (source text)
                     (let ((value (preview source text)))
                       (set! execution value)
                       value)))))
    (define (close!)
      (when authority
        (successful 'close-authority "close")
        (set! authority #f))
      (when store
        (close-workspace-store! store)
        (set! store #f)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (open!)
        (let* ((initial (snapshot))
               (seed-revision (assoc-ref initial "active_revision"))
               (saved #f) (active #f) (successor-revision #f))
          (check 'fresh-workspace (zero? (assoc-ref initial "workspace_version")))
          (check 'run-seed
                 (equal? (assoc-ref (successful 'seed-result "run" '("text" . "alpha"))
                                    "text") "seed: alpha"))
          (set! saved
                (assoc-ref
                 (successful 'save-successor "save"
                             (cons "expected_version" (assoc-ref initial "workspace_version"))
                             (cons "source" successor)) "snapshot"))
          (check 'draft-is-not-installed
                 (equal? (assoc-ref (successful 'draft-run "run" '("text" . "alpha"))
                                    "text") "seed: alpha"))
          (refused 'activation-needs-preview "preview-required-for-this-draft" "activate"
                   (cons "expected_version" (assoc-ref saved "workspace_version"))
                   (cons "expected_activation" (assoc-ref saved "activation_generation")))
          (successful 'preview-before-close "preview"
                      (cons "expected_version" (assoc-ref saved "workspace_version"))
                      '("text" . "before-close"))
          (close!)
          (open!)
          ;; Attempt before "open", which independently invalidates a ticket.
          (refused 'closed-preview-ticket-retired "preview-required-for-this-draft" "activate"
                   (cons "expected_version" (assoc-ref saved "workspace_version"))
                   (cons "expected_activation" (assoc-ref saved "activation_generation")))
          (set! saved (snapshot))
          (check 'unactivated-draft-durable (equal? (assoc-ref saved "source") successor))
          (check 'draft-reopen-keeps-installed-seed
                 (equal? (assoc-ref saved "active_revision") seed-revision))
          (check 'preview-successor
                 (equal? (assoc-ref
                          (successful 'successor-preview-result "preview"
                                      (cons "expected_version" (assoc-ref saved "workspace_version"))
                                      '("text" . "alpha")) "text") "revised: ALPHA"))
          (set! active
                (assoc-ref
                 (successful 'activate-successor "activate"
                             (cons "expected_version" (assoc-ref saved "workspace_version"))
                             (cons "expected_activation" (assoc-ref saved "activation_generation")))
                 "snapshot"))
          (set! successor-revision (assoc-ref active "active_revision"))
          (check 'new-revision (not (equal? seed-revision successor-revision)))
          (check 'installed-successor
                 (equal? (assoc-ref (successful 'installed-result "run" '("text" . "beta"))
                                    "text") "revised: BETA"))
          (check 'export-installed
                 (equal? (assoc-ref (successful 'export-result "export") "artifact")
                         (workspace-export store successor-revision)))
          (close!)
          ;; Discard both authority state and the SQLite connection, then check
          ;; the durable installed source independently of the previous objects.
          (open!)
          (set! saved (snapshot))
          (check 'reopen-durable-source (equal? (assoc-ref saved "source") successor))
          (check 'reopen-durable-revision
                 (equal? (assoc-ref saved "active_revision") successor-revision))
          (check 'reopen-behavior
                 (equal? (assoc-ref (successful 'reopened-result "run" '("text" . "gamma"))
                                    "text") "revised: GAMMA"))
          (for-each
           (lambda (entry)
             (let ((label (car entry)) (broken (cdr entry)))
               (set! saved
                     (assoc-ref
                      (successful 'save-broken-draft "save"
                                  (cons "expected_version" (assoc-ref saved "workspace_version"))
                                  (cons "source" broken)) "snapshot"))
               (refused label "preview-failed" "preview"
                        (cons "expected_version" (assoc-ref saved "workspace_version"))
                        '("text" . "test"))
               (refused 'failed-preview-cannot-activate "preview-required-for-this-draft" "activate"
                        (cons "expected_version" (assoc-ref saved "workspace_version"))
                        (cons "expected_activation" (assoc-ref saved "activation_generation")))
               (let ((after (snapshot)))
                 (check 'failed-preview-keeps-draft (equal? (assoc-ref after "source") broken))
                 (check 'failed-preview-keeps-installed
                        (equal? (assoc-ref after "active_revision") successor-revision)))
               ;; Availability after failure is separate from the cleanup
               ;; observation checked on every callback result above.
               (check 'runtime-reusable-after-failure
                      (equal? (assoc-ref (successful 'recovery-result "run" '("text" . "again"))
                                         "text") "revised: AGAIN"))))
           '((syntax-failure . "(define (workbench text)")
             (exception-failure . "(define (workbench text) (error \"broken\"))")
             (nontermination-failure . "(define (workbench text) (let loop () (loop)))")))
          (let ((rolled
                 (assoc-ref
                  (successful 'rollback "rollback"
                              (cons "expected_activation" (assoc-ref saved "activation_generation")))
                  "snapshot")))
            (check 'rollback-preserves-draft (equal? (assoc-ref rolled "source") (assoc-ref saved "source")))
            (check 'rollback-restores-seed (equal? (assoc-ref rolled "active_revision") seed-revision))
            (check 'rollback-behavior
                   (equal? (assoc-ref (successful 'rollback-result "run" '("text" . "delta"))
                                      "text") "seed: delta")))
          (close!)
          (open!)
          (let ((recovered (snapshot)))
            (check 'rollback-pointer-durable (equal? (assoc-ref recovered "active_revision") seed-revision))
            (check 'rollback-draft-durable (equal? (assoc-ref recovered "source") (assoc-ref saved "source")))
            (check 'rollback-reopen-behavior
                   (equal? (assoc-ref (successful 'rollback-reopen-result "run" '("text" . "epsilon"))
                                      "text") "seed: epsilon")))
          (close!)
          `((status . pass) (checks . ,checks))))
      (lambda ()
        ;; Failure cleanup does not replace the original failed assertion with
        ;; another protocol request. The composition root owns runtime teardown.
        (when store (close-workspace-store! store))))))
