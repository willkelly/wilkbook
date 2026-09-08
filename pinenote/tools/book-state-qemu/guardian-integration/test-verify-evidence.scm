#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Finite mutation tests for the actual-QEMU evidence checker only.
(use-modules (ice-9 ftw)
             (ice-9 match)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 8)
  (format (current-error-port)
          "usage: ~a GUILE CHECKER EVIDENCE INTEGRATION-ROOT CANDIDATE-DIR OUTER-DIR VOLUME-ROOT~%"
          (car arguments))
  (exit 2))

(define guile (list-ref arguments 1))
(define checker (list-ref arguments 2))
(define evidence (list-ref arguments 3))
(define integration-root (list-ref arguments 4))
(define candidate-directory (list-ref arguments 5))
(define outer-directory (list-ref arguments 6))
(define volume-root (list-ref arguments 7))
(define expected-tests 16)
(define tests 0)
(define test-root #f)
(define refusal-prefix
  "FAIL: root guardian refuses replaced run directory: ")
(define before-refusal
  "ok 23 - SIGKILL process guardian exits after reaping its QEMU")
(define after-refusal
  "ok 24 - SIGKILL run-root guardian exits after identity refusal")

(define (test-error message . values)
  (throw 'book-state-qemu-checker-test-error
         (apply format #f message values)))

(define (check label value)
  (set! tests (+ tests 1))
  (unless value (test-error "test ~a failed: ~a" tests label))
  (format #t "ok ~a - ~a~%" tests label)
  #t)

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda values
      (if (= ENOENT (system-error-errno values))
          #f
          (apply throw 'system-error values)))))

(define (remove-owned-tree path)
  (let ((info (lstat-or-false path)))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name) (remove-owned-tree (string-append path "/" name)))
             (scandir path (lambda (name) (not (member name '("." ".."))))))
            (rmdir path))
          (delete-file path)))))

(define (copy-private-tree source destination)
  (let ((info (lstat source)))
    (case (stat:type info)
      ((directory)
       (mkdir destination #o700)
       (chmod destination #o700)
       (for-each
        (lambda (name)
          (copy-private-tree (string-append source "/" name)
                             (string-append destination "/" name)))
        (scandir source (lambda (name) (not (member name '("." "..")))))))
      ((regular)
       (copy-file source destination)
       (chmod destination #o600))
      (else (test-error "unexpected evidence entry type: ~a" source)))))

(define (read-text path)
  (call-with-input-file path get-string-all))

(define (write-text! path text)
  (call-with-output-file path
    (lambda (port) (display text port)))
  (chmod path #o600))

(define (read-datum path)
  (call-with-input-file path read))

(define (write-datum! path value)
  (call-with-output-file path
    (lambda (port) (write value port) (newline port)))
  (chmod path #o600))

(define (replace-once text old new)
  (let ((first (string-contains text old)))
    (unless first (test-error "mutation source text was absent: ~s" old))
    (when (string-contains text old (+ first (string-length old)))
      (test-error "mutation source text was not unique: ~s" old))
    (string-append (substring text 0 first)
                   new
                   (substring text (+ first (string-length old))))))

(define (record-path root scenario suffix)
  (string-append root "/records/" scenario "." suffix ".scm"))

(define (foreign-root-path root)
  (string-append root "/owner-sigkill.foreign-root.scm"))

(define (expected-refusal-line root)
  (let ((record (read-datum (record-path root "owner-sigkill" "root"))))
    (string-append refusal-prefix (assoc-ref record 'run-root))))

(define (runtime-path root) (string-append root "/runtime.log"))

(define (mutate-runtime! root procedure)
  (let ((path (runtime-path root)))
    (write-text! path (procedure (read-text path)))))

(define (alist-replace value key replacement)
  (unless (assq key value) (test-error "datum lacks key: ~a" key))
  (map (lambda (entry)
         (if (eq? (car entry) key) (cons key replacement) entry))
       value))

(define (mutate-datum! path procedure)
  (write-datum! path (procedure (read-datum path))))

(define (wait-specific-child child)
  (let loop ()
    (let ((result
           (catch 'system-error
             (lambda () (waitpid child))
             (lambda values
               (if (= EINTR (system-error-errno values))
                   #f
                   (apply throw 'system-error values))))))
      (if result (cdr result) (loop)))))

(define (run-checker root log-path)
  (force-output)
  (let ((child (primitive-fork)))
    (if (zero? child)
        (catch #t
          (lambda ()
            (let ((fd (open-fdes log-path
                                 (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC)
                                 #o600)))
              (dup2 fd 1)
              (dup2 fd 2)
              (when (> fd 2) (close-fdes fd)))
            (let ((argv
                   (list guile "--no-auto-compile"
                         "-L" integration-root
                         "-L" candidate-directory
                         "-L" outer-directory
                         "-L" volume-root
                         checker root)))
              (apply execl guile argv)))
          (lambda _ (primitive-exit 125)))
        (let ((status (wait-specific-child child)))
          (or (status:exit-val status)
              (and (status:term-sig status)
                   (+ 128 (status:term-sig status))))))))

(define (case-log label)
  (string-append test-root "/" label ".log"))

(define (expect-result label root expected-exit)
  (let ((result (run-checker root (case-log label))))
    (unless (= result expected-exit)
      (format (current-error-port) "checker log for ~a:~%~a"
              label (read-text (case-log label))))
    (check label (= result expected-exit))))

(define (mutation-case label mutation)
  (let ((root (string-append test-root "/" label)))
    (copy-private-tree evidence root)
    (mutation root)
    (expect-result label root 1)))

(define (run-tests)
  (expect-result "unchanged-frozen-evidence-passes" evidence 0)
  (mutation-case
   "extra-unrelated-fail-line-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text)
          (replace-once text expected
                        (string-append "FAIL: unrelated failure\n" expected)))))))
  (mutation-case
   "other-path-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text)
          (replace-once text expected
                        (string-append refusal-prefix
                                       "/unrelated/not-the-recorded-root")))))))
  (mutation-case
   "arbitrary-suffix-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text)
          (replace-once text expected
                        (string-append expected " ARBITRARY-FAILURE-TEXT")))))))
  (mutation-case
   "trailing-whitespace-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text) (replace-once text expected
                                     (string-append expected " \t")))))))
  (mutation-case
   "duplicate-exact-refusal-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text)
          (replace-once text expected (string-append expected "\n" expected)))))))
  (mutation-case
   "leading-prefix-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text) (replace-once text expected
                                     (string-append "PREFIX " expected)))))))
  (mutation-case
   "deleted-refusal-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text) (replace-once text (string-append expected "\n") ""))))))
  (mutation-case
   "wrong-phase-order-rejected"
   (lambda (root)
     (let* ((expected (expected-refusal-line root))
            (ordered (string-append before-refusal "\n" expected "\n"
                                    after-refusal))
            (reordered (string-append expected "\n" before-refusal "\n"
                                      after-refusal)))
       (mutate-runtime!
        root (lambda (text) (replace-once text ordered reordered))))))
  (mutation-case
   "missing-final-lf-rejected"
   (lambda (root)
     (mutate-runtime!
      root
      (lambda (text) (substring text 0 (- (string-length text) 1))))))
  (mutation-case
   "extra-final-lf-rejected"
   (lambda (root)
     (mutate-runtime! root (lambda (text) (string-append text "\n")))))
  (mutation-case
   "crlf-refusal-rejected"
   (lambda (root)
     (let ((expected (expected-refusal-line root)))
       (mutate-runtime!
        root
        (lambda (text) (replace-once text (string-append expected "\n")
                                     (string-append expected "\r\n")))))))
  (mutation-case
   "lock-diagnostic-mutation-rejected"
   (lambda (root)
     (let ((path (string-append root
                                "/normal-lock-contender.qemu.stderr.raw")))
       (write-text!
        path
        (replace-once (read-text path) "Failed to get \"write\" lock"
                      "MUTATED LOCK DIAGNOSTIC")))))
  (mutation-case
   "foreign-record-path-contradiction-rejected"
   (lambda (root)
     (mutate-datum!
      (foreign-root-path root)
      (lambda (value)
        (alist-replace value 'replacement-path "/unrelated/foreign-root")))))
  (mutation-case
   "coordinated-untrusted-path-rejected"
   (lambda (root)
     (let* ((root-path (record-path root "owner-sigkill" "root"))
            (old-expected (expected-refusal-line root))
            (untrusted "/tmp/opencode/not-an-owned-run-root")
            (new-expected (string-append refusal-prefix untrusted)))
       (mutate-datum!
        root-path
        (lambda (value) (alist-replace value 'run-root untrusted)))
       (mutate-datum!
        (foreign-root-path root)
        (lambda (value) (alist-replace value 'replacement-path untrusted)))
       (mutate-runtime!
        root
        (lambda (text) (replace-once text old-expected new-expected))))))
  (mutation-case
   "original-root-inode-contradiction-rejected"
   (lambda (root)
     (mutate-datum!
      (foreign-root-path root)
      (lambda (value)
        (alist-replace value 'held-original-inode
                       (+ 1 (assoc-ref value 'held-original-inode)))))))
  (unless (= tests expected-tests)
    (test-error "finite test count mismatch: ~a instead of ~a"
                tests expected-tests))
  (format #t "PASS: ~a/~a checker-only tests~%" tests expected-tests)
  0)

(exit
 (catch #t
   (lambda ()
     (set! test-root
           (mkdtemp "/tmp/opencode/book-state-qemu-checker-tests.XXXXXX"))
     (chmod test-root #o700)
     (dynamic-wind
       (lambda () #t)
       run-tests
       (lambda () (remove-owned-tree test-root))))
   (lambda (key . exception-arguments)
     (when (and test-root (lstat-or-false test-root))
       (false-if-exception (remove-owned-tree test-root)))
     (format (current-error-port) "FAIL: ~s ~s~%" key exception-arguments)
     1)))
