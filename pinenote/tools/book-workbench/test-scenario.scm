;;; Run exactly the guest's durable-authoring assertions with the explicit
;;; trusted-native callback before spending an ARM/QEMU boot on them.
(use-modules (sandbox-scenario) (workbench-preview)
             (ice-9 ftw) (srfi srfi-64))

(test-begin "workbench-shared-scenario")
(for-each
 (lambda (entry)
   (let* ((root (mkdtemp "/tmp/opencode/workbench-scenario-oracle.XXXXXX"))
          (failure
           (catch 'workbench-scenario-failed
             (lambda ()
               (run-workbench-scenario! root "oracle-test"
                 (lambda (_source _text)
                   `((status . failed) (text . "") (diagnostic . "injected")
                     (execution-started? . ,(cadr entry))
                     (cleanup-complete? . ,(caddr entry)))))
               'incorrectly-passed)
             (lambda (_key label) label))))
     (test-eq (symbol->string (car entry)) (car entry) failure)
     ((@@ (workbench-preview) remove-owned-tree) root)))
 '((execution-started #f #t) (execution-cleaned #t #f)))
(let* ((guile (or (getenv "BOOK_WORKBENCH_GUILE") (error "missing test Guile")))
       (tool (dirname (canonicalize-path (car (command-line)))))
       (root (mkdtemp "/tmp/opencode/workbench-scenario.XXXXXX")))
  (chmod root #o700)
  (let ((result
         (run-workbench-scenario!
          root (basename (dirname (dirname guile)))
          (lambda (source text)
            (preview-native source text #:guile guile
                            #:runner (string-append tool "/workbench-runner.scm")
                            #:protocol-directory (string-append tool "/../book-protocol")
                            #:timeout-seconds 3)))))
    (test-eq "durable authoring scenario completed" 'pass (assoc-ref result 'status))
    (test-assert "authoring and failure checks executed" (>= (assoc-ref result 'checks) 40)))
  ;; Retain failed runs just like the other native suites.
  (when (zero? (test-runner-fail-count (test-runner-current)))
    (for-each (lambda (name) (delete-file (string-append root "/" name)))
              (scandir root (lambda (name) (not (member name '("." ".."))))))
    (rmdir root)))
(let ((failed (test-runner-fail-count (test-runner-current))))
  (test-end "workbench-shared-scenario")
  (exit (if (zero? failed) 0 1)))
