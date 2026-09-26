#!/bin/sh
# Trusted developer bootstrap; arguments are explicit operator inputs. The
# existing Guile engine authenticates private boot/disk snapshots by SHA256.
# No builds, device access, networking, or native authored-code fallback.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
execution=$tool/../book-execution-spike
core=/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1
guile=/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile
cd "$execution"
"$core/bin/sha256sum" -c - <<'HASHES'
0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca  disposable-qemu.scm
fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908  guest-console-assertions.scm
HASHES
# Feed only this trusted adapter through stdin. With no inherited load/cache
# settings Guile resolves the authenticated engine and its standard library.
exec "$core/bin/env" -i HOME=/nonexistent XDG_CACHE_HOME=/nonexistent \
    LANG=C LC_ALL=C GUILE_AUTO_COMPILE=0 PATH="$core/bin" \
    "$guile" --no-auto-compile -L "$execution" -s /dev/stdin "$@" <<'SCHEME'
(use-modules (disposable-qemu) (ice-9 match) (ice-9 textual-ports)
             ((rnrs io ports) #:select (get-bytevector-n put-bytevector))
             (rnrs bytevectors)
             (srfi srfi-1) (srfi srfi-13))
(define outer (resolve-module '(disposable-qemu)))
(define (private name) (module-ref outer name))
(define (fail message) ((private 'runner-error) message))
(define state-size (* 64 1024 1024))
(define pass-marker "BOOK_WORKBENCH_GUEST: status=pass")
(define (store-program path)
  (let ((resolved ((private 'resolve-executable) path "explicit host tool")))
    (unless (string-prefix? "/gnu/store/" resolved)
      (fail "host executable must resolve into the immutable Guix store"))
    resolved))

(define (split-options argv)
  (let loop ((rest (cdr argv)) (base (list (car argv))) (extra '()))
    (match rest
      (() (values (reverse base) extra))
      ((name value tail ...)
       (if (member name '("--workspace-input" "--workspace-sha256"
                          "--workspace-output" "--mke2fs"))
           (begin
             (when (assoc name extra) (fail "duplicate Workbench option"))
             (loop tail base (acons name value extra)))
           (loop (cdr rest) (cons name base) extra)))
      ((name) (loop '() (cons name base) extra)))))

(define (option argv name)
  (let ((tail (member name argv))) (and tail (pair? (cdr tail)) (cadr tail))))
(define (required argv name)
  (or (option argv name) (fail (string-append "missing " name))))
(define (replace-value args name value)
  (let loop ((rest args))
    (cond ((null? rest) '())
          ((string=? (car rest) name) (cons name (cons value (cddr rest))))
          (else (cons (car rest) (loop (cdr rest)))))))

;; Private fault-injection seams; CLI/configuration never selects these. Tests
;; exercise failures against the same acquisition and publication code.
(define snapshot-open-port (make-parameter fdopen))
(define snapshot-read (make-parameter get-bytevector-n))
(define snapshot-write (make-parameter put-bytevector))
(define snapshot-sync (make-parameter fsync))
(define snapshot-mode (make-parameter chmod))
(define snapshot-close (make-parameter close-port))

(define (publish-workspace! workspace output)
  ;; An exclusive mode-0600 file is provisional until copy, fsync, chmod and
  ;; close all succeed. On any failure remove only that file's retained inode;
  ;; a replaced path belongs to somebody else and must be preserved.
  (let* ((fd (open-fdes output
                        (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                        #o600))
         (identity (stat fd))
         (port #f)
         (complete? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! port ((snapshot-open-port) fd "wb"))
        (call-with-input-file workspace
          (lambda (input-port)
            (unless (= (stat:size (stat input-port)) state-size)
              (fail "workspace snapshot must be exactly 64 MiB"))
            (let loop ((remaining state-size))
              (unless (zero? remaining)
                (let ((bytes ((snapshot-read) input-port (min remaining 65536))))
                  (when (eof-object? bytes) (fail "short workspace snapshot"))
                  ((snapshot-write) port bytes)
                  (loop (- remaining (bytevector-length bytes))))))))
        (force-output port)
        ((snapshot-sync) fd)
        ((snapshot-mode) port #o400)
        ((snapshot-close) port)
        (set! fd #f)
        (unless (and ((private 'lstat-or-false) output)
                     ((private 'same-identity?) identity (lstat output)))
          (fail "workspace output was replaced during publication"))
        (set! complete? #t))
      (lambda ()
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (if port
                (unless (port-closed? port) (close-port port))
                (when fd (close-fdes fd))))
          (lambda ()
            (unless complete?
              (let ((current ((private 'lstat-or-false) output)))
                (when (and current ((private 'same-identity?) identity current))
                  (delete-file output))))))))))

(define (main argv)
  (when (member "--help" argv)
    (display "Usage: run-qemu.sh --boot-bundle DIR --baseline RAW --kernel-sha256 SHA --initrd-sha256 SHA --config-sha256 SHA --baseline-sha256 SHA --run-base PRIVATE-DIR --dedicated-baseline --qemu STORE-EXE --qemu-img STORE-EXE --cp STORE-EXE --sha256sum STORE-EXE --mke2fs STORE-EXE [--workspace-input PRIVATE-READONLY-64MiB-RAW --workspace-sha256 SHA] [--workspace-output NEW-PRIVATE-PATH]\n")
    (display "Fixed limits: 512 MiB RAM, 2 vCPUs, 360 s QEMU deadline, 5 s TERM grace. Retained workspace is read-only, exported only after clean guest pass.\n")
    (exit 0))
  (call-with-values
      (lambda () (split-options argv))
    (lambda (base extra)
      (when (or (option base "--timeout-seconds") (option base "--term-grace-seconds"))
        (fail "Workbench fixes the outer deadline at 360+5 seconds"))
      ;; Forward the validated immutable targets, not aliases the outer would
      ;; resolve again. replace-value preserves repeated options for its parser.
      (for-each (lambda (name)
                  (set! base (replace-value base name
                                            (store-program (required base name)))))
                '("--qemu" "--qemu-img" "--cp" "--sha256sum"))
      (let* ((mkfs (store-program (or (assoc-ref extra "--mke2fs")
                                     (fail "missing --mke2fs"))))
             (mkfs-config (string-append (dirname (dirname mkfs)) "/etc/mke2fs.conf"))
             (input (assoc-ref extra "--workspace-input"))
             (input-hash (assoc-ref extra "--workspace-sha256"))
             (output (assoc-ref extra "--workspace-output"))
             (old-argv (private 'qemu-argv))
             (old-check (private 'validate-completed-guest-console))
             (old-environment (private 'supervisor-environment))
             (old-preparation (private 'run-checked-preparation))
             (root-liveness-port #f)
             (environment #f)
             (environment-root #f)
             (environment-root-identity #f)
             (environment-qemu #f)
             (observed-root #f)
             (workspace #f))
        (unless (and (file-exists? mkfs-config)
                     (eq? (stat:type (stat mkfs-config)) 'regular))
          (fail "mke2fs must carry its immutable package configuration"))
        (unless (eq? (not input) (not input-hash))
          (fail "workspace input and hash must be supplied together"))
        (when input
          ((private 'validate-baseline) input)
          ((private 'validate-sha256) input-hash "workspace")
          (let ((info (lstat input)))
            (unless (and (= (stat:uid info) (getuid))
                         (= (stat:nlink info) 1) (= (stat:size info) state-size)
                         (= (logand (stat:mode info) #o777) #o400))
              (fail "workspace input must be a private single-link read-only 64 MiB file"))))
        (when output
          (unless (and (string-prefix? "/" output)
                       (not (member (basename output) '("." "..")))
                       (not ((private 'lstat-or-false) output)))
            (fail "workspace output must be a new absolute path"))
          ((private 'validate-run-base) (dirname output)))
        (dynamic-wind
          (lambda ()
            ;; The real outer creates HOME/TMP/XDG directories through this
            ;; side-effecting factory before private snapshots and qemu-argv.
            ;; Capture that one result; calling the factory again is EEXIST.
            (module-set!
             outer 'supervisor-environment
             (lambda (root qemu)
               (when environment (fail "outer environment requested twice"))
               (set! environment (old-environment root qemu))
               (set! environment-root root)
               (set! environment-root-identity (lstat root))
               (set! environment-qemu qemu)
               environment))
            ;; The outer's first copy carries its real root-guardian write end.
            ;; Borrow it for workspace helpers too: each process guardian must
            ;; close that inherited end. #f is not an optional-port sentinel.
            ;; Ownership and eventual close remain entirely with the outer.
            (module-set!
             outer 'run-checked-preparation
             (lambda (argv env root stem grace port)
               (unless (and environment (equal? root environment-root)
                            ((private 'same-identity?) environment-root-identity (lstat root))
                            (port? port) (output-port? port) (not (port-closed? port))
                            (or (not root-liveness-port) (eq? port root-liveness-port)))
                 (fail "preparation lacks the matching live root-guardian port"))
               (set! root-liveness-port port)
               (old-preparation argv env root stem grace port)))
            (module-set!
             outer 'qemu-argv
              (lambda (qemu root kernel initrd append-line overlay)
                (when observed-root (fail "QEMU graph requested twice"))
                 (unless (and environment
                              (port? root-liveness-port) (not (port-closed? root-liveness-port))
                             (equal? root environment-root)
                             (equal? qemu environment-qemu)
                             ((private 'same-identity?) environment-root-identity (lstat root)))
                  (fail "QEMU graph lacks the matching prepared outer environment"))
               (set! observed-root root)
               (set! workspace (string-append root "/workspace.raw"))
               (if input
                     ((private 'private-snapshot)
                      input workspace input-hash "workspace"
                      (required base "--cp") (required base "--sha256sum")
                       environment root 5 root-liveness-port)
                     (begin
                       (let ((fd (open-fdes workspace
                                            (logior O_CREAT O_EXCL O_WRONLY O_CLOEXEC)
                                            #o600)))
                         (truncate-file fd state-size)
                         (close-fdes fd))
                       ((private 'run-checked-preparation)
                        (list mkfs "-q" "-t" "ext4" "-F" "-b" "4096" "-L" "WBWorkbenchV1"
                              "-U" "46f9a200-9863-4bba-b721-a28ad561f8c3" workspace)
                        (cons (string-append "MKE2FS_CONFIG=" mkfs-config) environment)
                          root "workspace-mkfs" 5 root-liveness-port)))
               (chmod workspace #o600)
               (append
                (replace-value
                 (replace-value (old-argv qemu root kernel initrd append-line overlay)
                                "-smp" "2") "-m" "512")
                (list "-blockdev"
                      (string-append "{\"driver\":\"file\",\"filename\":"
                                     ((private 'json-quote) workspace)
                                     ",\"node-name\":\"workspace-file\"}")
                      "-blockdev" "{\"driver\":\"raw\",\"file\":\"workspace-file\",\"node-name\":\"workspace\"}"
                      "-device" "virtio-blk-pci,drive=workspace"))))
            (module-set!
             outer 'validate-completed-guest-console
             (lambda (path root stderr)
               (catch #t
                 (lambda ()
                   ((private 'assert-console-retainable) path)
                   (let* ((text (call-with-input-file path get-string-all))
                          (lines (map (lambda (line) (string-trim-right line #\return))
                                      (string-split text #\newline)))
                          (marker (list-index (lambda (line) (string=? line pass-marker)) lines))
                          (power (list-index (lambda (line) (string-contains line "reboot: Power down")) lines)))
                     (unless (and (= 1 (count (lambda (line) (string=? line pass-marker)) lines))
                                  marker power (< marker power)
                                  (not (any (lambda (bad) (string-contains text bad))
                                            '("BOOK_WORKBENCH_GUEST: status=fail"
                                              "Kernel panic" "BUG:" "Oops:"))))
                       (fail "Workbench guest markers or clean power-down missing"))
                     (display text))
                    ;; Never give QEMU the caller's retained file. Publish from
                    ;; the private copy only after exit, checks and power-down.
                    (when output
                      (publish-workspace! workspace output)))
                 (lambda (key . args)
                   ((private 'emit-qemu-failure-diagnostics) root stderr)
                   (apply throw key args))))))
          (lambda ()
            (let ((status (disposable-qemu-main
                           (append base '("--timeout-seconds" "360"
                                          "--term-grace-seconds" "5")))))
              (when (and observed-root ((private 'lstat-or-false) observed-root))
                (fail "owned QEMU root remains after guardian cleanup"))
              status))
          (lambda ()
            (module-set! outer 'qemu-argv old-argv)
            (module-set! outer 'validate-completed-guest-console old-check)
            (module-set! outer 'supervisor-environment old-environment)
            (module-set! outer 'run-checked-preparation old-preparation)))))))

(define (run-workbench-qemu argv)
  (umask #o077)
  (sigaction SIGCHLD SIG_DFL)
  (for-each (lambda (signal)
              (sigaction signal (lambda (received) (note-disposable-qemu-signal received))))
            (list SIGINT SIGTERM SIGHUP))
  (catch #t (lambda () (main argv))
        (lambda (key . args)
          (when (eq? key 'quit) (apply throw key args))
          (format (current-error-port) "BOOK_WORKBENCH_QEMU: fail ~s ~s~%" key args)
          1)))
(exit (run-workbench-qemu (command-line)))
SCHEME
