;;; Host-only adapter tests. Invoke with cached Guile, for example:
;;; /gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile \
;;;   --no-auto-compile pinenote/tools/book-workbench/test-qemu-adapter.scm
;;; All writes are beneath one fresh private temporary directory. The fake
;;; outer process exercises the actual adapter; it does not execute QEMU,
;;; mkfs, runsc, authored source, builds, or any hardware operation.
(use-modules (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13)
             ((rnrs io ports) #:select (get-bytevector-n put-bytevector)))

(define tool (dirname (canonicalize-path (car (command-line)))))
(add-to-load-path (canonicalize-path (string-append tool "/../book-execution-spike")))
(define adapter (make-module))
(module-use! adapter (resolve-interface '(guile)))

;; Read the live heredoc, then evaluate every definition and import in a private
;; module. Exclude only the exact terminal CLI call, rather than retaining a
;; copied adapter implementation or weakening its production input validation.
(define forms
  (let* ((text (call-with-input-file (string-append tool "/run-qemu.sh") get-string-all))
         (delimiter "<<'SCHEME'\n")
         (start (string-contains text delimiter))
         (end (string-contains text "\nSCHEME\n")))
    (unless (and start end (< start end)) (error "adapter heredoc changed"))
    (call-with-input-string
        (substring text (+ start (string-length delimiter)) end)
      (lambda (port)
        (let loop ((forms '()))
          (let ((form (read port)))
            (if (eof-object? form) (reverse forms) (loop (cons form forms)))))))))
(unless (equal? (last forms) '(exit (run-workbench-qemu (command-line))))
  (error "adapter CLI boundary changed"))
(for-each
 (lambda (form)
   (unless (and (pair? form) (memq (car form) '(use-modules define)))
     (error "unexpected executable adapter top-level form" form))
   (eval form adapter))
 (drop-right forms 1))

(define (a name) (module-ref adapter name))
(define outer (a 'outer))
(define (outer-ref name) (module-ref outer name))
(define core "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/")
(define e2fs "/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2")
(define base
  (list "fixture" "--qemu" (string-append core "true")
        "--qemu-img" (string-append core "false")
        "--cp" (string-append core "cp")
        "--sha256sum" (string-append core "sha256sum")
        "--mke2fs" (string-append e2fs "/sbin/mke2fs")))
(for-each
 (lambda (file) (unless (file-exists? file) (error "cached test input missing" file)))
 (list (string-append core "true") (string-append core "false")
       (string-append core "cp") (string-append core "sha256sum")
       (string-append e2fs "/sbin/mke2fs") (string-append e2fs "/etc/mke2fs.conf")))

(define checks 0)
(define (check label condition)
  (unless condition (error "QEMU adapter test failed" label))
  (set! checks (+ checks 1))
  (format #t "PASS: ~a~%" label))
(define (silently thunk)
  (parameterize ((current-output-port (open-output-string))
                 (current-error-port (open-output-string)))
    (thunk)))
(define (throws? thunk)
  (catch #t (lambda () (silently thunk) #f) (lambda _ #t)))
(define (rejects args) (throws? (lambda () ((a 'main) args))))
(define (option args name) ((a 'option) args name))
(define (with-binding module name value thunk)
  (let* ((local (module-local-variable module name))
         (old (and local (variable-ref local))))
    (dynamic-wind
      (lambda () (module-define! module name value))
      thunk
      (lambda ()
        (if local (module-define! module name old) (module-remove! module name))))))
(define (with-snapshot-hook name value thunk)
  (parameterize (((a name) value)) (thunk)))

;; Exercise the guest's actual mount/controller preflight definitions with
;; synthetic kernel files. Do not load its sandbox/scenario imports or execute
;; their runtime. All kernel I/O is parameterized before calling the preflight.
(define guest (make-module))
(module-use! guest (resolve-interface '(guile)))
(eval '(use-modules (ice-9 textual-ports) (rnrs bytevectors) (srfi srfi-1) (srfi srfi-13)) guest)
(call-with-input-file (string-append tool "/guest-entry.scm")
  (lambda (port)
    (let ((header (read port)))
      (unless (and (eq? (car header) 'define-module)
                   (equal? (cadr header) '(book-workbench-guest)))
        (error "guest module boundary changed")))
    (let loop ()
      (let ((form (read port)))
        (unless (eof-object? form)
          (unless (and (pair? form) (eq? (car form) 'define))
            (error "unexpected executable guest top-level form" form))
          (eval form guest)
          (loop))))))
(define (g name) (module-ref guest name))
(define workspace-mount
  "35 24 252:16 / /var/lib/wilkbook-book-workbench rw,nosuid,nodev,noexec,noatime - ext4 /dev/vdb rw\n")
(define cgroup-mount "36 24 0:27 / /sys/fs/cgroup rw,nosuid,nodev,noexec - cgroup2 cgroup2 rw\n")
(define (with-kernel mounts available previous behavior thunk)
  (let ((enabled previous) (writes '()))
    (parameterize
        (((g 'kernel-read)
          (lambda (path)
            (cond ((equal? path "/proc/self/mountinfo") mounts)
                  ((equal? path "/sys/fs/cgroup/cgroup.controllers") available)
                  ((equal? path "/sys/fs/cgroup/cgroup.subtree_control") enabled)
                  (else (error "unexpected kernel read" path)))))
         ((g 'kernel-write)
          (lambda (path text)
            (unless (equal? path "/sys/fs/cgroup/cgroup.subtree_control")
              (error "unexpected kernel write" path))
            (set! writes (append writes (list text)))
            (case behavior
              ((refuse) (error "synthetic cgroup controller refusal"))
              ((ignore) #t)
              (else
               (let ((added (map (lambda (token)
                                   (unless (string-prefix? "+" token)
                                     (error "controller write resets existing controllers"))
                                   (substring token 1))
                                 (string-tokenize text))))
                 (set! enabled
                       (string-join
                        (append (if (eq? behavior 'drop-previous) '()
                                    (string-tokenize enabled)) added) " "))))))))
      (thunk (lambda () writes)))))
(define (guest-preflight-tests)
  (with-kernel (string-append workspace-mount cgroup-mount) "cpu memory pids io" "io" 'apply
    (lambda (writes)
      ((g 'require-workspace-mount!) "/var/lib/wilkbook-book-workbench")
      ((g 'prepare-cgroup-controllers!))
      (check 'enable-only-missing-controllers
             (equal? (writes) '("+cpu +memory +pids\n")))))
  (with-kernel cgroup-mount "cpu memory pids io" "cpu io" 'apply
    (lambda (writes)
      ((g 'prepare-cgroup-controllers!))
      (check 'preserve-enabled-controllers (equal? (writes) '("+memory +pids\n")))))
  (with-kernel cgroup-mount "cpu memory pids io" "cpu memory pids io" 'apply
    (lambda (writes)
      ((g 'prepare-cgroup-controllers!))
      (check 'already-enabled-is-noop (null? (writes)))))
  (for-each
   (lambda (mounts)
     (with-kernel mounts "cpu memory pids" "" 'apply
       (lambda (writes)
         (check 'invalid-cgroup-mount-refused (throws? (g 'prepare-cgroup-controllers!)))
         (check 'invalid-mount-never-written (null? (writes))))))
   (list "" "malformed mount record\n"
         "36 24 0:27 / /sys/fs/cgroup rw - tmpfs tmpfs rw\n"
         "36 24 0:27 / /sys/fs/cgroup ro - cgroup2 cgroup2 rw\n"))
  (for-each
   (lambda (available)
     (with-kernel cgroup-mount available "" 'apply
       (lambda (writes)
         (check 'missing-controller-refused (throws? (g 'prepare-cgroup-controllers!)))
         (check 'missing-controller-never-written (null? (writes))))))
   '("cpu memory" "memory pids" "cpu pids"))
  (for-each
   (lambda (behavior)
     (with-kernel cgroup-mount "cpu memory pids io" "io" behavior
       (lambda (writes)
         (check 'controller-write-or-readback-failure
                (throws? (g 'prepare-cgroup-controllers!))))))
   '(refuse ignore drop-previous))
  (for-each
   (lambda (mounts)
     (with-kernel mounts "cpu memory pids" "" 'apply
       (lambda (writes)
         (check 'mandatory-workspace-mount-refused
                (throws? (lambda () ((g 'require-workspace-mount!) "/var/lib/wilkbook-book-workbench")))))))
   (list cgroup-mount
         "35 24 252:16 / /var/lib/wilkbook-book-workbench ro,nosuid,nodev,noexec,noatime - ext4 /dev/vdb rw\n"
         "35 24 252:16 / /var/lib/wilkbook-book-workbench rw,nosuid,nodev,noatime - ext4 /dev/vdb rw\n"))
  (with-kernel cgroup-mount "cpu memory pids" "" 'apply
    (lambda (writes)
      (check 'workspace-precedes-controller-mutation
             (eq? #f (silently
                      (lambda () ((g 'guest-main)
                                  '((workspace-root . "/var/lib/wilkbook-book-workbench")
                                    (runtime-parent . "/must-not-be-created")))))))
      (check 'invalid-workspace-never-enables-controllers (null? (writes))))))

(define (guest-observation-tests)
  (let* ((sample
          `((controls-match? . #t)
            (files . (("memory.max" . "268435456")
                      ("cpu.stat" . "usage_usec 42\nnr_throttled 2\n")
                      ("memory.events" . ,(make-string 8192 #\x))))
            (members . (((runsc-command . "boot") (comm . "do-not-log-member-name"))
                        ((runsc-command . "gofer")) ((runsc-command . "unclassified"))))))
         (resources `((evidence . host-cgroup-samples) (first . ,sample) (last . ,sample)
                      (adopted-children-reaped . 1)
                      (enforcement-proven? . #f) (complete-support-accounting-proven? . #f)))
         (result `((status . ok) (execution-started? . #t) (cleanup-complete? . #t)
                   (resource-observations . ,resources)
                    (text . "do-not-log-child-output") (diagnostic . "do-not-log-child-stderr")
                    (stderr-evidence . ((text . "do-not-log-extra-stderr")))))
         (callback ((g 'observed-preview) (lambda (source text) result)))
         (returned #f)
         (log (with-output-to-string
                (lambda ()
                  (set! returned (callback "do-not-log-source" "do-not-log-input"))
                  (callback "do-not-log-source" "do-not-log-input"))))
         (lines (filter (lambda (line) (not (string-null? line))) (string-split log #\newline)))
         (prefix "BOOK_WORKBENCH_PREVIEW: ")
         (records (map (lambda (line)
                         (unless (string-prefix? prefix line) (error "unexpected preview log line"))
                         (call-with-input-string (substring line (string-length prefix)) read))
                       lines))
         (first (assoc-ref (assoc-ref (car records) 'resource-observations) 'first)))
    (check 'preview-result-returned-unchanged (eq? result returned))
    (check 'one-record-per-preview (= (length lines) 2))
    (check 'preview-invocations-numbered
           (equal? (map (lambda (record) (assoc-ref record 'number)) records) '(1 2)))
    (check 'preview-status-and-lifetime-flags
           (and (eq? (assoc-ref (car records) 'status) 'ok)
                (eq? (assoc-ref (car records) 'execution-started?) #t)
                (eq? (assoc-ref (car records) 'cleanup-complete?) #t)))
    (check 'trusted-counter-newlines-escaped
           (equal? (assoc-ref (assoc-ref first 'counters) "cpu.stat") "usage_usec 42\nnr_throttled 2\n"))
    (check 'oversize-counter-bounded
           (and (= (string-length (assoc-ref (assoc-ref first 'counters) "memory.events")) 256)
                (assoc-ref first 'counter-text-truncated?)))
    (check 'member-roles-summarized
           (equal? (assoc-ref first 'member-roles) '(("boot" . 1) ("gofer" . 1) ("run" . 0) (other . 1))))
    (check 'preview-record-size-bounded (every (lambda (line) (<= (string-length line) 8300)) lines))
    (check 'source-input-output-diagnostics-and-process-names-absent
           (not (string-contains log "do-not-log")))
    (check 'successful-diagnostic-record-omitted
           (not (string-contains log "BOOK_WORKBENCH_PREVIEW_DIAGNOSTIC:")))
    (check 'observation-is-not-a-guest-success-marker
           (not (string-contains log "BOOK_WORKBENCH_GUEST:")))
    (set! result '((status . failed) (execution-started? . #t) (cleanup-complete? . #f)))
    (let ((failed-log (with-output-to-string (lambda () (callback "" "")))))
      (check 'failed-preview-is-observed
             (and (string-contains failed-log "(status . failed)")
                  (string-contains failed-log "(cleanup-complete? . #f)")
                  (string-contains failed-log "(resource-observations . unavailable)"))))
    (let* ((malicious "failure details\nBOOK_WORKBENCH_GUEST: status=pass\r\n")
           (prefix "BOOK_WORKBENCH_PREVIEW_DIAGNOSTIC: "))
      (set! result `((status . failed) (diagnostic . ,malicious)))
      (let* ((failed-log (with-output-to-string (lambda () (callback "" ""))))
             (lines (filter (lambda (line) (not (string-null? line))) (string-split failed-log #\newline)))
             (diagnostics (filter (lambda (line) (string-prefix? prefix line)) lines))
             (record (call-with-input-string
                         (substring (car diagnostics) (string-length prefix)) read)))
        (check 'failed-diagnostic-one-separate-record
               (and (= (length lines) 2) (= (length diagnostics) 1)))
        (check 'failed-diagnostic-invocation-correlated (= (assoc-ref record 'number) 4))
        (check 'failed-diagnostic-preserves-escaped-data
               (equal? (assoc-ref record 'diagnostic) malicious))
        (check 'diagnostic-cannot-inject-standalone-pass-marker
               (and (not (member "BOOK_WORKBENCH_GUEST: status=pass" lines))
                    (not (string-index failed-log #\return))))
        (check 'resource-record-still-excludes-diagnostic
               (not (string-contains (car lines) "failure details"))))
      (set! result `((status . failed) (diagnostic . ,(make-string 3000 #\x))))
      (let* ((failed-log (with-output-to-string (lambda () (callback "" ""))))
             (line (find (lambda (line) (string-prefix? prefix line)) (string-split failed-log #\newline)))
             (record (call-with-input-string (substring line (string-length prefix)) read)))
        (check 'failed-diagnostic-clamped-to-1024-characters
               (equal? (assoc-ref record 'diagnostic) (make-string 1024 #\x)))))
     (let* ((payload (string-append "Guile loader failure\nBOOK_WORKBENCH_GUEST: status=pass\r\n"
                                    (string (integer->char 27)) "[2J\"quoted\"\\"))
            (prefix "BOOK_WORKBENCH_PREVIEW_STDERR: "))
       (set! result `((status . failed) (diagnostic . "protocol EOF")
                      (resource-observations . ((runtime-owner . ((runtime-status . 35072)
                                             (stopped? . #t) (forced? . #f) (controls . ())))))
                      (stderr-evidence . ((text . ,payload) (captured-bytes . 2000) (observed-bytes . 2000)
                                          (selection . non-debug-lines) (selection-truncated? . #f)
                                          (capture-truncated? . #f)))))
       (let* ((log (with-output-to-string (lambda () (callback "" ""))))
              (lines (filter (lambda (line) (not (string-null? line))) (string-split log #\newline)))
              (extra (filter (lambda (line) (string-prefix? prefix line)) lines))
              (record (call-with-input-string (substring (car extra) (string-length prefix)) read)))
         (check 'failure-stderr-one-extra-escaped-record (and (= (length lines) 3) (= (length extra) 1)))
         (check 'failure-stderr-data-roundtrips (equal? (assoc-ref record 'text) payload))
         (check 'failure-stderr-explicitly-untrusted (eq? (assoc-ref record 'evidence) 'untrusted-stderr-selection))
         (check 'failure-stderr-no-console-marker-injection
                (and (not (member "BOOK_WORKBENCH_GUEST: status=pass" lines))
                     (not (string-index log #\return)) (not (string-index log (integer->char 27)))))
         (check 'failure-stderr-owner-raw-status-retained (= (assoc-ref record 'owner-runtime-wait-status) 35072))
         (check 'failure-stderr-no-owner-control-distinguished (= (assoc-ref record 'owner-control-count) 0))
         (check 'failure-stderr-correlated (= (assoc-ref record 'number) 6)))
       (for-each
        (lambda (payload)
          (set! result `((status . failed) (stderr-evidence . ((text . ,payload)))))
          (let* ((log (with-output-to-string (lambda () (callback "" ""))))
                 (line (find (lambda (line) (string-prefix? prefix line)) (string-split log #\newline)))
                 (body (substring line (string-length prefix)))
                 (record (call-with-input-string body read)))
            (check 'extra-stderr-character-bound (<= (string-length (assoc-ref record 'text)) 8192))
            (check 'extra-stderr-escaped-record-byte-bound
                   (<= ((module-ref guest 'bytevector-length) ((module-ref guest 'string->utf8) body)) 32768))
            (check 'extra-stderr-truncation-explicit (assoc-ref record 'selection-truncated?))))
        (list (make-string 20000 #\x) (make-string 8192 #\nul) (make-string 8192 (integer->char #x1f600)))))
     (let* ((exception-callback ((g 'observed-preview) (lambda _ (throw 'fixture-failure))))
           (rethrown? #f)
           (exception-log
            (with-output-to-string
              (lambda ()
                (catch 'fixture-failure
                  (lambda () (exception-callback "" ""))
                  (lambda _ (set! rethrown? #t)))))))
      (check 'exception-recorded-and-rethrown
             (and rethrown? (string-contains exception-log "(status . exception)")
                  (string-contains exception-log "(cleanup-complete? . unknown)"))))))

(umask #o077)
(define root (mkdtemp "/tmp/opencode/workbench-qemu-adapter.XXXXXX"))
(chmod root #o700)
(define run-root (string-append root "/run"))
(define output (string-append root "/retained.raw"))
(define input (string-append root "/input.raw"))
(define mock-hash (make-string 64 #\a))
(define input-options (list "--workspace-input" input "--workspace-sha256" mock-hash))
(define pass-console "BOOK_WORKBENCH_GUEST: status=pass\n[ 23.4] reboot: Power down\n")
(define console-text pass-console)
(define before-console (lambda () #t))
(define outer-calls 0)
(define expected-environment (make-parameter #f))
(define expected-liveness (make-parameter #f))
(define (exists? path) ((outer-ref 'lstat-or-false) path))
(define (sparse-file path size mode)
  (let ((fd (open-fdes path (logior O_CREAT O_EXCL O_WRONLY O_CLOEXEC) mode)))
    (truncate-file fd size)
    (close-fdes fd)))
(define (text-file path text)
  (call-with-output-file path (lambda (port) (display text port))))
(define (mock-preparation args env directory label grace liveness)
  (check 'preparation-borrows-live-outer-port
         (and (port? liveness) (eq? liveness (expected-liveness)) (not (port-closed? liveness))))
  (unless (equal? label "qemu-img")
  (check 'mkfs-label (member "WBWorkbenchV1" args))
  (check 'mkfs-fixed-block-size (equal? (option args "-b") "4096"))
  (check 'mkfs-immutable-config
          (member (string-append "MKE2FS_CONFIG=" e2fs "/etc/mke2fs.conf") env))
  (check 'mkfs-reuses-exact-outer-environment (eq? (cdr env) (expected-environment))))
  #t)
(define (mock-snapshot source destination hash label cp sha env directory grace liveness)
  ;; This tests hash forwarding and refusal propagation, not hash verification
  ;; itself. The unchanged disposable-QEMU engine owns authentication tests.
  (unless (equal? hash mock-hash) (error "mock snapshot authentication refused"))
  (check 'snapshot-private-destination (string-prefix? (string-append run-root "/") destination))
  (check 'snapshot-distinct-input (not (equal? source destination)))
  (check 'snapshot-reuses-exact-outer-environment (eq? env (expected-environment)))
  (check 'snapshot-borrows-live-outer-port
         (and (port? liveness) (eq? liveness (expected-liveness)) (not (port-closed? liveness))))
  (copy-file source destination)
  (chmod destination #o400))
(define (mock-outer args)
  (set! outer-calls (+ outer-calls 1))
  (check 'fixed-deadline (equal? (option args "--timeout-seconds") "360"))
  (check 'fixed-grace (equal? (option args "--term-grace-seconds") "5"))
  (mkdir run-root #o700)
  (let ((liveness-pipe (pipe)))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      ;; Match the real outer's order: this factory performs exclusive mkdirs,
      ;; so calling it again inside qemu-argv must fail EEXIST on the old code.
      ;; Retain the actual factory's environment and directory identities.
      (let* ((environment ((outer-ref 'supervisor-environment) run-root (string-append core "true")))
             (directories (map (lambda (name) (cons name (lstat (string-append run-root "/" name))))
                               '("home" "tmp" "xdg-cache" "xdg-config" "xdg-runtime")))
             (args (parameterize ((expected-environment environment)
                                  (expected-liveness (cdr liveness-pipe)))
                     ;; The real outer's preceding copy/qemu-img preparation
                     ;; supplies the port before invoking the adapter's argv.
                     ((outer-ref 'run-checked-preparation)
                      '("fixture-preparation") environment run-root "qemu-img" 5 (cdr liveness-pipe))
                     ((outer-ref 'qemu-argv) (string-append core "true") run-root
                      "/kernel" "/initrd" "fixed append" "/overlay"))))
        (check 'real-environment-directories-created-once
               (every (lambda (entry)
                        (let ((current (lstat (string-append run-root "/" (car entry)))))
                          (and ((outer-ref 'same-identity?) (cdr entry) current)
                               (= (logand (stat:mode current) #o777) #o700))))
                      directories))
        (check 'memory-cap (equal? (option args "-m") "512"))
        (check 'cpu-cap (equal? (option args "-smp") "2"))
        (check 'no-network (equal? (option args "-nic") "none"))
        (check 'workspace-device (member "virtio-blk-pci,drive=workspace" args))
        (check 'private-disk-writable
               (= (logand (stat:mode (lstat (string-append run-root "/workspace.raw"))) #o777) #o600)))
      (before-console)
      (let ((log (string-append run-root "/console.log")))
        (text-file log console-text)
        ((outer-ref 'validate-completed-guest-console) log run-root "/absent"))
      0)
    (lambda ()
      (close-port (car liveness-pipe)) (close-port (cdr liveness-pipe))
      ((outer-ref 'delete-created-tree) run-root)))))

(define (tests)
  (define original-argv (outer-ref 'qemu-argv))
  (define original-validator (outer-ref 'validate-completed-guest-console))
  (define original-environment (outer-ref 'supervisor-environment))
  (define original-preparation (outer-ref 'run-checked-preparation))
  (check 'missing-tools (rejects '("fixture")))
  (check 'caller-deadline-refused (rejects (append base '("--timeout-seconds" "1"))))
  (check 'caller-grace-refused (rejects (append base '("--term-grace-seconds" "1"))))
  (check 'input-needs-hash (rejects (append base '("--workspace-input" "/absent"))))
  (check 'hash-needs-input (rejects (append base (list "--workspace-sha256" mock-hash))))
  (check 'duplicate-option (rejects (append base '("--mke2fs" "/absent"))))
  (check 'relative-output (rejects (append base '("--workspace-output" "relative"))))
  ;; Retarget real private aliases after adapter validation, in the existing
  ;; output-parent check immediately before dispatch. The outer receives the
  ;; previously resolved store paths, not names it would resolve a second time.
  (let* ((names '("--qemu" "--qemu-img" "--cp" "--sha256sum"))
         (targets (map (lambda (name) (canonicalize-path (option base name))) names))
         (aliases (map (lambda (name) (string-append root "/alias-" (substring name 2))) names))
         (arguments
          (fold (lambda (entry args) ((a 'replace-value) args (car entry) (cdr entry)))
                base (map cons names aliases)))
         (validate-parent (outer-ref 'validate-run-base))
         (retargeted? #f)
         (forwarded #f))
    (for-each symlink targets aliases)
    (with-binding outer 'validate-run-base
      (lambda (parent)
        (let ((result (validate-parent parent)))
          (for-each
           (lambda (alias target)
             (delete-file alias)
             (symlink (string-append core (if (equal? target (string-append core "false")) "true" "false")) alias))
           aliases targets)
          (set! retargeted? #t)
          result))
      (lambda ()
        (with-binding outer 'disposable-qemu-main
          (lambda (args) (set! forwarded args) 0)
          (lambda ()
            (check 'alias-validation-dispatch-completes
                   (= 0 ((a 'main) (append arguments
                                          (list "--workspace-output" (string-append root "/alias-output.raw"))))))))))
    (check 'aliases-retargeted-before-outer-dispatch retargeted?)
    (for-each
     (lambda (name alias target)
       (check (string-append name " alias actually changed")
              (not (equal? (canonicalize-path alias) target)))
       (check (string-append name " forwarded as validated immutable target")
              (equal? (option forwarded name) target)))
     names aliases targets))
  ;; Canonicalization must not silently deduplicate arguments: the outer parser
  ;; remains responsible for repeated-option handling and its existing errors.
  (let ((forwarded #f) (duplicate "/unresolved-duplicate-for-outer-validation"))
    (with-binding outer 'disposable-qemu-main
      (lambda (args) (set! forwarded args) 0)
      (lambda () ((a 'main) (append base (list "--cp" duplicate)))))
    (check 'duplicate-options-remain-visible-to-outer
           (and (= 2 (count (lambda (arg) (equal? arg "--cp")) forwarded))
                (member duplicate forwarded))))
  (check 'clean-pass
         (= 0 (silently (lambda () ((a 'main) (append base (list "--workspace-output" output)))))))
  (check 'retained-state-size (= (stat:size (lstat output)) (* 64 1024 1024)))
  (check 'retained-state-private-readonly (= (logand (stat:mode (lstat output)) #o777) #o400))
  (check 'no-owned-root (not (exists? run-root)))
  (check 'environment-factory-restored-after-success
         (eq? original-environment (outer-ref 'supervisor-environment)))
  (check 'preparation-binding-restored-after-success
         (eq? original-preparation (outer-ref 'run-checked-preparation)))
  (let ((identity (lstat output)) (calls outer-calls))
    (check 'existing-output-refused (rejects (append base (list "--workspace-output" output))))
    (check 'existing-output-unmodified (equal? identity (lstat output)))
    (check 'preflight-does-not-launch (= calls outer-calls)))
  (let ((link (string-append root "/output-link"))
        (dangling (string-append root "/dangling-output"))
        (directory (string-append root "/existing-directory")))
    (symlink output link)
    (symlink (string-append root "/absent") dangling)
    (mkdir directory #o700)
    (for-each
     (lambda (path)
       (check 'existing-object-refused (rejects (append base (list "--workspace-output" path))))
       (check 'existing-object-preserved (exists? path)))
     (list link dangling directory)))
  (let ((public (string-append root "/nonprivate")))
    (mkdir public #o700) (chmod public #o755)
    (check 'output-parent-must-be-private
           (rejects (append base (list "--workspace-output" (string-append public "/new"))))))

  (sparse-file input (* 64 1024 1024) #o600)
  (check 'writable-input-refused (rejects (append base input-options)))
  (chmod input #o400)
  (let ((info (lstat input)))
    (check 'readonly-input-accepted (= 0 (silently (lambda () ((a 'main) (append base input-options))))))
    (check 'input-identity-size-mode-preserved
           (and ((outer-ref 'same-identity?) info (lstat input))
                (= (stat:size (lstat input)) (* 64 1024 1024))
                (= (logand (stat:mode (lstat input)) #o777) #o400))))
  (let ((symlink-path (string-append root "/input-link"))
        (alias (string-append root "/input-hardlink")))
    (symlink input symlink-path)
    (check 'linked-input-refused
           (rejects (append base (list "--workspace-input" symlink-path "--workspace-sha256" mock-hash))))
    (link input alias)
    (check 'hardlinked-input-refused (rejects (append base input-options)))
    (delete-file alias))
  (check 'snapshot-authentication-failure
         (rejects (append base (list "--workspace-input" input "--workspace-sha256" (make-string 64 #\b)))))
  (check 'snapshot-failure-cleaned-run (not (exists? run-root)))
  (chmod input #o600) (truncate-file input 1024) (chmod input #o400)
  (check 'short-input-refused (rejects (append base input-options)))

  (for-each
   (lambda (entry)
     (set! console-text (cdr entry))
     (let ((failed-output (string-append root "/failed-marker-output")))
       (check (car entry) (rejects (append base (list "--workspace-output" failed-output))))
       (check 'failed-console-cannot-publish (not (exists? failed-output))))
     (check 'failed-console-cleaned-run (not (exists? run-root))))
   '((missing-pass . "reboot: Power down\n")
     (missing-powerdown . "BOOK_WORKBENCH_GUEST: status=pass\n")
     (duplicate-pass . "BOOK_WORKBENCH_GUEST: status=pass\nBOOK_WORKBENCH_GUEST: status=pass\nreboot: Power down\n")
     (explicit-failure . "BOOK_WORKBENCH_GUEST: status=pass\nBOOK_WORKBENCH_GUEST: status=fail\nreboot: Power down\n")
     (kernel-bug . "BOOK_WORKBENCH_GUEST: status=pass\nBUG: fixture\nreboot: Power down\n")
     (kernel-panic . "BOOK_WORKBENCH_GUEST: status=pass\nKernel panic\nreboot: Power down\n")
     (kernel-oops . "BOOK_WORKBENCH_GUEST: status=pass\nOops: fixture\nreboot: Power down\n")
     (powerdown-order . "reboot: Power down\nBOOK_WORKBENCH_GUEST: status=pass\n")))
  (set! console-text pass-console)
  (check 'argv-restored-after-failure (eq? original-argv (outer-ref 'qemu-argv)))
  (check 'validator-restored-after-failure
         (eq? original-validator (outer-ref 'validate-completed-guest-console)))
  (check 'environment-factory-restored-after-failure
         (eq? original-environment (outer-ref 'supervisor-environment)))
  (check 'preparation-binding-restored-after-failure
         (eq? original-preparation (outer-ref 'run-checked-preparation)))
  (for-each
   (lambda (mode)
     (let ((refusal #f))
       (with-binding outer 'disposable-qemu-main
         (lambda (args)
           (mkdir run-root #o700)
           (let ((liveness-pipe (pipe)))
             (dynamic-wind
              (lambda () #t)
              (lambda ()
              (unless (eq? mode 'unprepared)
                (let ((environment
                       ((outer-ref 'supervisor-environment) run-root (string-append core "true"))))
                  ;; Establish every shared precondition before changing only
                  ;; the root or executable passed to qemu-argv. Otherwise the
                  ;; missing borrowed port masks both correlation checks.
                  (when (memq mode '(different-root different-qemu))
                    (parameterize ((expected-environment environment)
                                   (expected-liveness (cdr liveness-pipe)))
                      ((outer-ref 'run-checked-preparation)
                       '("fixture-preparation") environment run-root "qemu-img" 5
                       (cdr liveness-pipe))))))
              (catch 'book-execution-qemu-error
                (lambda ()
                  (if (eq? mode 'repeated-factory)
                      ((outer-ref 'supervisor-environment) run-root (string-append core "true"))
                      ((outer-ref 'qemu-argv)
                       (string-append core (if (eq? mode 'different-qemu) "false" "true"))
                       (if (eq? mode 'different-root) root run-root)
                       "/kernel" "/initrd" "fixed append" "/overlay")))
                (lambda (key message)
                  (set! refusal message)
                  (throw key message))))
              (lambda ()
                (close-port (car liveness-pipe)) (close-port (cdr liveness-pipe))
                ((outer-ref 'delete-created-tree) run-root)))))
         (lambda () (check mode (rejects base))))
       (check 'intended-precondition-refusal
              (equal? refusal
                      (if (eq? mode 'repeated-factory)
                          "outer environment requested twice"
                          "QEMU graph lacks the matching prepared outer environment")))
       (check 'environment-mismatch-does-not-create-workspace
              (not (exists? (string-append root "/workspace.raw"))))
       (check 'environment-factory-restored-after-precondition-refusal
              (eq? original-environment (outer-ref 'supervisor-environment)))))
   '(unprepared different-root different-qemu repeated-factory))

  ;; Publication failures exercise the real helper, including failures after
  ;; chmod(0400). Fault injection is local to this adapter's private module.
  (let ((source (string-append root "/publication-source"))
        (destination (string-append root "/publication-output")))
    (sparse-file source (* 64 1024 1024) #o600)
    (let ((port (open-file source "r+")))
      (display "head" port)
      (seek port (- (* 64 1024 1024) 4) SEEK_SET)
      (display "tail" port)
      (close-port port))
    ((a 'publish-workspace!) source destination)
    (call-with-input-file destination
      (lambda (port)
        (check 'snapshot-preserves-head (equal? (get-string-n port 4) "head"))
        (seek port (- (* 64 1024 1024) 4) SEEK_SET)
        (check 'snapshot-preserves-tail (equal? (get-string-n port 4) "tail"))))
    (delete-file destination)
    (for-each
     (lambda (name)
       (with-snapshot-hook name (lambda args (error "injected publication failure" name))
         (lambda ()
           (check name (throws? (lambda () ((a 'publish-workspace!) source destination))))))
       (check 'failed-publication-absent (not (exists? destination))))
     '(snapshot-open-port snapshot-write snapshot-sync snapshot-mode))
    (let ((original-close (a 'close-port)) (seen #f))
      (with-snapshot-hook 'snapshot-close
        (lambda (port)
          (original-close port)
          (unless seen (set! seen #t) (error "injected close failure after chmod")))
        (lambda ()
          (check 'close-failure-after-readonly
                 (throws? (lambda () ((a 'publish-workspace!) source destination)))))))
    (check 'readonly-failed-publication-absent (not (exists? destination)))
    (let ((original-write (a 'put-bytevector)) (writes 0))
      (with-snapshot-hook 'snapshot-write
        (lambda (port bytes)
          (set! writes (+ writes 1))
          (if (= writes 2) (error "injected partial copy failure") (original-write port bytes)))
        (lambda ()
          (check 'partial-copy-failure
                 (throws? (lambda () ((a 'publish-workspace!) source destination)))))))
    (check 'partial-copy-not-published (not (exists? destination)))
    (let ((original-read (a 'get-bytevector-n)) (reads 0))
      (with-snapshot-hook 'snapshot-read
        (lambda (port count)
          (set! reads (+ reads 1))
          (when (= reads 2) (truncate-file source 65536))
          (original-read port count))
        (lambda ()
          (check 'shrinking-source-refused
                 (throws? (lambda () ((a 'publish-workspace!) source destination)))))))
    (check 'short-copy-not-published (not (exists? destination)))
    (truncate-file source (* 64 1024 1024))
    (let ((owned (string-append root "/moved-provisional")))
      (with-snapshot-hook 'snapshot-sync
        (lambda (fd)
          (rename-file destination owned)
          (text-file destination "replacement must survive\n")
          (error "injected replacement during publication"))
        (lambda ()
          (check 'replacement-failure
                 (throws? (lambda () ((a 'publish-workspace!) source destination))))))
      (check 'replacement-preserved
             (equal? (call-with-input-file destination get-string-all) "replacement must survive\n"))
      (check 'moved-provisional-is-not-readonly
             (= (logand (stat:mode (lstat owned)) #o777) #o600))
      (delete-file destination))
    (set! before-console (lambda () (text-file destination "created after preflight\n")))
    (check 'output-created-after-preflight-refused
           (rejects (append base (list "--workspace-output" destination))))
    (check 'raced-output-preserved
           (equal? (call-with-input-file destination get-string-all) "created after preflight\n"))
    (delete-file destination)
    ;; Run through the adapter's console/publication integration as well.
    (set! before-console
          (lambda () (truncate-file (string-append run-root "/workspace.raw") 1024)))
    (check 'integrated-publication-failure
           (rejects (append base (list "--workspace-output" destination))))
    (check 'integrated-failure-no-output (not (exists? destination)))
    (check 'integrated-failure-cleaned-run (not (exists? run-root)))))

(dynamic-wind
  (lambda () #t)
  (lambda ()
    (guest-preflight-tests)
    (guest-observation-tests)
    (with-binding outer 'run-checked-preparation mock-preparation
      (lambda ()
        (with-binding outer 'private-snapshot mock-snapshot
          (lambda ()
            (with-binding outer 'disposable-qemu-main mock-outer tests)))))
    (format #t "PASS: ~a QEMU adapter checks; actual adapter, fake outer process, no QEMU/ARM execution~%" checks))
  (lambda () ((outer-ref 'delete-created-tree) root)))
