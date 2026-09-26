;;; Opt-in host preparation integration test; accepts run-qemu.sh's production
;;; arguments EXCEPT --run-base and --workspace-output (always private/fresh).
;;; Requires explicitly staged immutable boot/image inputs and cached tools.
;;; No image build or kernel/QEMU execution. Only the final QEMU run-owned-process
;;; call is replaced; every preceding helper and both guardian layers are real.
;;; Invoke with the cached Guile used by run-qemu.sh and its ordinary arguments.
(use-modules (ice-9 ftw) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13)
             ((rnrs io ports) #:select (get-bytevector-n)) (rnrs bytevectors))

(define tool (dirname (canonicalize-path (car (command-line)))))
(add-to-load-path (canonicalize-path (string-append tool "/../book-execution-spike")))
(define arguments (cdr (command-line)))
(when (or (null? arguments) (member "--help" arguments))
  (display "usage: guile --no-auto-compile test-real-qemu-preparation.scm [run-qemu.sh options except --run-base/--workspace-output]\n")
  (exit (if (null? arguments) 2 0)))
(when (any (lambda (argument)
             (or (member argument '("--run-base" "--workspace-output"))
                 (string-prefix? "--run-base=" argument)
                 (string-prefix? "--workspace-output=" argument)))
           arguments)
  (error "test owns a fresh run base and output; omit --run-base/--workspace-output"))

;; Load current production adapter definitions, excluding only its CLI call.
(define adapter (make-module))
(module-use! adapter (resolve-interface '(guile)))
(let* ((text (call-with-input-file (string-append tool "/run-qemu.sh") get-string-all))
       (delimiter "<<'SCHEME'\n")
       (start (string-contains text delimiter))
       (end (string-contains text "\nSCHEME\n")))
  (unless (and start end (< start end)) (error "adapter heredoc changed"))
  (call-with-input-string (substring text (+ start (string-length delimiter)) end)
    (lambda (port)
      (let loop ()
        (let ((form (read port)))
          (cond
           ((eof-object? form) (error "adapter CLI boundary missing"))
           ((equal? form '(exit (run-workbench-qemu (command-line))))
            (unless (eof-object? (read port)) (error "unexpected form after adapter CLI")))
           ((and (pair? form) (memq (car form) '(define use-modules)))
            (eval form adapter) (loop))
           (else (error "unexpected adapter top-level form" form))))))))
(define (a name) (module-ref adapter name))
(define outer (a 'outer))
(define (o name) (module-ref outer name))
(define argv (cons "host-preparation-fixture" arguments))
(define qemu ((a 'store-program) ((a 'required) argv "--qemu")))
(unless (equal? (basename qemu) "qemu-system-aarch64")
  (error "test requires an explicitly selected qemu-system-aarch64 executable"))
(define real-tools
  (map (lambda (name) ((a 'store-program) ((a 'required) argv name)))
       '("--cp" "--sha256sum" "--qemu-img" "--mke2fs")))
(define required-real-tools
  ;; A supplied workspace exercises authenticated copying instead of mkfs.
  (if ((a 'option) argv "--workspace-input") (drop-right real-tools 1) real-tools))
(define real-run (o 'run-owned-process))
(define checks 0)
(define (check name value)
  (unless value (error "real host preparation check failed" name))
  (set! checks (+ checks 1)))
(define root #f)
(define root-identity #f)
(define inner-root #f)
(define liveness #f)
(define commands '())
(define fake-launches 0)
(define completed? #f)
(define captured-output (open-output-string))
(define captured-error (open-output-string))
(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))
(define (prefix-bytes path count)
  (call-with-input-file path (lambda (port) (get-bytevector-n port count))))

(define (intercept-final-qemu command environment directory stdout stderr timeout grace root-port)
  (if (equal? (car command) qemu)
      (begin
        (set! fake-launches (+ fake-launches 1))
        (check 'one-final-qemu-call (= fake-launches 1))
        (check 'final-shares-real-root-port (and (port? root-port) (eq? root-port liveness)))
        (check 'real-root-port-still-open (not (port-closed? root-port)))
        (check 'all-real-preparation-tools-exercised
               (every (lambda (program) (member program commands)) required-real-tools))
        (check 'bounded-qemu-arguments
               (and (equal? ((a 'option) command "-m") "512")
                    (equal? ((a 'option) command "-smp") "2")
                    (equal? ((a 'option) command "-nic") "none")
                    (= timeout 360) (= grace 5)))
        (check 'real-qcow2-overlay
               (bytevector=? (prefix-bytes (string-append directory "/disk-overlay.qcow2") 4)
                             #vu8(81 70 73 251)))
        ;; Independent ext4 superblock inspection proves actual mkfs happened.
        (let ((header (prefix-bytes (string-append directory "/workspace.raw") 2048)))
          (check 'real-ext4-magic (= (bytevector-u16-ref header #x438 'little) #xef53))
          (check 'real-ext4-journal
                 (not (zero? (logand (bytevector-u32-ref header #x45c 'little) 4))))
          (check 'real-ext4-extents
                 (not (zero? (logand (bytevector-u32-ref header #x460 'little) #x40)))))
        (write-file stdout "") (write-file stderr "")
        (write-file (string-append directory "/console.log")
                    "HOST_PREPARATION_FIXTURE: synthetic console; NO KERNEL EXECUTED\nBOOK_WORKBENCH_GUEST: status=pass\n[ 0.0] reboot: Power down\n")
        (cons 0 #f))
      (begin
        (check 'only-declared-real-helper-executables (member (car command) real-tools))
        (set! commands (cons (car command) commands))
        (unless inner-root (set! inner-root directory))
        (unless liveness (set! liveness root-port))
        ;; Delegate unchanged, including the actual supplied root port. The old
        ;; adapter's #f reaches the real guardian and reproduces port-closed?.
        (let ((result (real-run command environment directory stdout stderr timeout grace root-port)))
          (check 'real-helper-completed (and (zero? (car result)) (not (cdr result))))
          (check 'helpers-share-one-root (equal? directory inner-root))
          (check 'helpers-share-live-root-port
                 (and (port? root-port) (eq? liveness root-port) (not (port-closed? root-port))))
          result))))

(umask #o077)
(set! root (mkdtemp "/tmp/opencode/workbench-real-preparation.XXXXXX"))
(chmod root #o700)
(set! root-identity (lstat root))
(dynamic-wind
  (lambda () (module-set! outer 'run-owned-process intercept-final-qemu))
  (lambda ()
    (let* ((output (string-append root "/synthetic-workspace.raw"))
           (status
            (parameterize ((current-output-port captured-output) (current-error-port captured-error))
              ((a 'run-workbench-qemu)
               (append argv (list "--run-base" root "--workspace-output" output))))))
      (unless (zero? status)
        (write-file (string-append root "/runner.stdout") (get-output-string captured-output))
        (write-file (string-append root "/runner.stderr") (get-output-string captured-error)))
      (check 'adapter-completed-with-real-preparation (zero? status))
      (check 'final-launch-was-substituted (= fake-launches 1))
      (check 'inner-guardian-cleaned-root (and inner-root (not (file-exists? inner-root))))
      (check 'root-guardian-liveness-closed (and (port? liveness) (port-closed? liveness)))
      (check 'synthetic-workspace-published
             (and (= (stat:size (lstat output)) (* 64 1024 1024))
                  (= (logand (stat:mode (lstat output)) #o777) #o400)))
      (check 'no-helper-or-guardian-child-remains
             (catch 'system-error (lambda () (waitpid -1 WNOHANG) #f)
               (lambda args (= (system-error-errno args) ECHILD))))
      (set! completed? #t)
      (format #t "HOST_PREPARATION: pass; checks=~a; real-helper-calls=~a; final-QEMU=substituted; ARM-execution=none~%"
              checks (length commands))))
  (lambda ()
    (module-set! outer 'run-owned-process real-run)
    (if completed?
        (when ((o 'same-identity?) root-identity (lstat root)) ((o 'delete-created-tree) root))
        (format (current-error-port) "Failed host-preparation fixture retained: ~a~%" root))))
