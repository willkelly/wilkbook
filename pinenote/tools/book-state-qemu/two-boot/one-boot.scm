#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; One fresh semantic boot, derived from disposable-reader-qemu.scm.
;;; The private disposable-QEMU successor remains the only process/run-root
;;; guardian.  This wrapper supplies one explicit closed integration record and
;;; archives bounded evidence before that guardian removes the ephemeral root.
(use-modules (disposable-qemu)
             (gcrypt base16)
             (gcrypt hash)
             (ice-9 format)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 rdelim)
             (ice-9 regex)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)
              (two-boot fd-handoff)
              (two-boot graph)
              (two-boot source-gate)
              (two-boot timeout-contract))

(define max-log-bytes (* 4 1024 1024))
(define outer-success
  "OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS\n")
(define coordinator-success
  "BOOK_STATE_QEMU_COORDINATOR: qemu-and-reader=reaped; reader-lifecycle=pass; ui-transcript=complete\n")
(define own-option-names
  '("--source-root" "--source-manifest-sha256" "--evidence-dir"
    "--state-proc-file" "--koreader-package" "--guile"))

(define (fail message . arguments)
  (runner-error (apply format #f message arguments)))

(define (file-hash path)
  (bytevector->base16-string (file-sha256 path)))

(define (extract-options argv)
  (let loop ((rest (cdr argv)) (base (list (car argv))) (options '()))
    (match rest
      (() (values (reverse base) options))
      ((name value tail ...)
       (if (member name own-option-names string=?)
           (begin
             (when (assoc name options) (fail "duplicate one-boot option: ~a" name))
             (loop tail base (acons name value options)))
           (loop (cdr rest) (cons name base) options)))
      ((name)
       (if (member name own-option-names string=?)
           (fail "one-boot option lacks a value: ~a" name)
           (loop '() (cons name base) options))))))

(define (required options name)
  (or (assoc-ref options name) (fail "missing one-boot option: ~a" name)))

(define (require-private-directory path label)
  (unless (and (string? path) (string-prefix? "/tmp/opencode/" path)
               (string=? path (canonicalize-path path)))
    (fail "~a must be an absolute canonical /tmp/opencode directory" label))
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "~a must be caller-owned mode 0700" label)))
  path)

(define (mkdir-private path)
  (when (lstat-or-false path) (fail "refusing pre-existing path: ~a" path))
  (mkdir path #o700)
  (chmod path #o700))

(define (write-exclusive-datum! path value)
  (let ((fd (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       #o600))
        (port #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chmod fd #o600)
        (set! port (fdopen fd "w"))
        (write value port)
        (newline port)
        (force-output port)
        (fsync fd))
      (lambda () (if port (close-port port) (close-fdes fd))))))

(define (copy-bounded-file! source destination)
  (let ((info (lstat-or-false source)))
    (when info
      (unless (and (eq? (stat:type info) 'regular)
                   (= (stat:nlink info) 1)
                   (<= (stat:size info) max-log-bytes))
        (fail "retained evidence file is invalid or exceeds 4 MiB: ~a" source))
      (let ((input #f) (output #f) (output-fd #f))
        (dynamic-wind
          (lambda ()
            (set! input (open-file source "rb"))
            (set! output-fd
                  (open-fdes destination
                             (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW
                                     O_CLOEXEC)
                             #o600))
            (set! output (fdopen output-fd "wb"))
            (set! output-fd #f))
          (lambda ()
            (let loop ()
              (let ((chunk (get-bytevector-n input (* 64 1024))))
                (unless (eof-object? chunk)
                  (put-bytevector output chunk)
                  (loop))))
            (force-output output)
            (fsync (fileno output)))
          (lambda ()
            (when input (close-port input))
            (if output
                (close-port output)
                (when output-fd (close-fdes output-fd))))))
      (chmod destination #o400))))

(define archive-roster
  '("console.log"
    "qemu.stdout"
    "qemu.stderr"
    "reader-ui/qemu.stdout"
    "reader-ui/qemu.stderr"
    "reader-ui/reader.log"
    "reader-ui/qemu.pid"
    "reader-ui/reader.pid"
    "reader-ui/ui-guest-to-reader.bin"
    "reader-ui/ui-reader-to-guest.bin"
    "reader-ui/ui-proxy.scm"
    "reader-ui/coordinator-result.scm"))

(define (copy-relative! root archive relative)
  (let ((source (string-append root "/" relative))
        (destination (string-append archive "/" relative)))
    (when (lstat-or-false source)
      (let ((parent (dirname destination)))
        (unless (lstat-or-false parent) (mkdir-private parent)))
      (copy-bounded-file! source destination))))

(define (console-lines path)
  (if (lstat-or-false path)
      (call-with-input-file path
        (lambda (port)
          (let loop ((result '()))
            (let ((line (read-line port)))
              (if (eof-object? line) (reverse result)
                  (loop (cons (string-trim-right line #\return) result)))))))
      '()))

(define (count-line lines wanted)
  (count (lambda (line) (string=? line wanted)) lines))

(define (power-down-line? line)
  (or (string=? line "reboot: Power down")
      (and (string-prefix? "[" line)
           (string-suffix? "] reboot: Power down" line))))

(define plain-failure-line-rx (make-regexp "^[ \\t]*FAIL:"))
(define timestamped-failure-line-rx
  (make-regexp "^\\[[ \\t]*[0-9]+(\\.[0-9]+)?\\] [ \\t]*FAIL:"))

(define (failure-record-line? line)
  (or (regexp-exec plain-failure-line-rx line)
      (regexp-exec timestamped-failure-line-rx line)
      (string-prefix? "BOOK-STATE-GUEST result=fail" line)
      (string-prefix? "BOOKEXEC-SMOKE-FAIL" line)))

(define (validate-console-minimum! path)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (> (stat:size info) 0) (< (stat:size info) max-log-bytes))
      (fail "console log is absent, empty, or reached 4 MiB")))
  (let* ((text (call-with-input-file path get-string-all))
         (lines (console-lines path)))
    (for-each
     (lambda (fragment)
       (when (string-contains text fragment)
         (fail "console contains forbidden failure fragment: ~a" fragment)))
     '("BOOK-STATE-GUEST result=fail" "BOOKEXEC-SMOKE-FAIL"
       "Kernel panic" "BUG:" "Oops:"))
    (when (any failure-record-line? lines)
      (fail "console contains a framed generic failure production"))
    (unless (and (= (count-line
                     lines
                     "BOOKEXEC-KERNEL-IDENTITY-PASS") 1)
                 (= (count-line
                     lines
                     "BOOKEXEC-NETWORK-ABSENT-PASS") 1)
                 (= (count-line
                     lines
                     "BOOKEXEC-FORBIDDEN-MOUNTS-PASS") 1)
                 (= (count-line
                     lines
                     "BOOKEXEC-RUNSC-VERSION-PASS") 1)
                 (= (count (lambda (line)
                             (string-prefix? "BOOK-STATE-GUEST result=pass " line))
                           lines)
                    1)
                 (= (count (lambda (line)
                             (string-prefix?
                              "BOOK-STATE-GUEST inspector-path=/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite namespaces=2 receipts="
                              line))
                           lines)
                    1)
                 (= (count power-down-line? lines) 1))
      (fail "console lacks the unique minimum semantic/cleanup marker chain"))))

(define (manifest-file-hash source-root relative)
  (let ((matches
         (filter-map
          (lambda (line)
            (and (>= (string-length line) 67)
                 (string=? (substring line 66) relative)
                 (substring line 0 64)))
          (console-lines (string-append source-root
                                        "/SOURCE-MANIFEST.sha256")))))
    (unless (= (length matches) 1)
      (fail "source manifest does not name staged input exactly once: ~a"
            relative))
    (car matches)))

(define (stage-one! source-root destination-root relative target)
  (let ((source (string-append source-root "/" relative))
        (destination (string-append destination-root "/" target))
        (expected (manifest-file-hash source-root relative)))
    (let ((before (lstat source)))
      (unless (and (eq? (stat:type before) 'regular)
                   (= (stat:nlink before) 1)
                   (zero? (logand (stat:mode before) #o222))
                   (string=? (file-hash source) expected))
        (fail "staged coordinator input failed source authentication: ~a"
              relative))
      (copy-file source destination)
      (chmod destination #o400)
      (let ((after (lstat source)) (copied (lstat destination)))
        (unless (and (same-stable-file? before after)
                     (eq? (stat:type copied) 'regular)
                     (= (stat:nlink copied) 1)
                     (= (logand (stat:mode copied) #o7777) #o400)
                     (string=? (file-hash destination) expected))
          (fail "staged coordinator source changed during snapshot: ~a"
                relative))))
    (unless (eq? (stat:type (lstat destination)) 'regular)
      (fail "staged coordinator input is not regular: ~a" relative))
    destination))

(define coordinator-sources
  '("candidate/qemu-state-coordinator.scm"
    "modules/disposable-qemu.scm"
    "modules/guest-console-assertions.scm"
    "modules/reader-qemu-graph.scm"
    "modules/two-boot/graph.scm"
    "modules/two-boot/ui-proxy.scm"
    "accepted/state-reader/fixture/bookstatereader.koplugin/_meta.lua"
    "accepted/state-reader/fixture/bookstatereader.koplugin/main.lua"
    "accepted/state-reader/fixture/bookstatereader.koplugin/state_channel.lua"
    "accepted/state-reader/fixture/bookstatereader.koplugin/ui_audit.lua"))

(define (stage-coordinator! source-root run-root)
  (let ((destination (string-append run-root "/reader-coordinator")))
    (mkdir-private destination)
    (for-each
     (lambda (relative) (mkdir-private (string-append destination "/" relative)))
     '("two-boot" "fixture" "fixture/bookstatereader.koplugin"))
    (for-each
     (lambda (relative)
       (let ((target
              (cond
               ((string-prefix? "candidate/" relative)
                "qemu-state-coordinator.scm")
               ((string-prefix? "modules/" relative)
                (substring relative (string-length "modules/")))
               ((string-prefix? "accepted/state-reader/fixture/" relative)
                (string-append
                 "fixture/"
                 (substring relative
                            (string-length "accepted/state-reader/fixture/"))))
               (else (fail "unknown coordinator source mapping")))))
         (stage-one! source-root destination relative target)))
     coordinator-sources)
    (string-append destination "/qemu-state-coordinator.scm")))

(define (coordinator-argv guile coordinator koreader qemu run-root kernel initrd
                           append-line overlay state-proc-file)
  (let ((qemu-argv
         (two-boot-qemu-arguments
          qemu run-root kernel initrd append-line overlay state-proc-file)))
    (assert-two-boot-qemu-arguments
     qemu-argv qemu run-root kernel initrd append-line overlay state-proc-file)
    (append
     (list guile "--no-auto-compile" "-L" (dirname coordinator)
           coordinator
           "--run-root" run-root
           "--socket" (string-append run-root "/book-ui.sock")
           "--koreader-package" koreader
           "--qemu" qemu
           "--")
     (cdr qemu-argv))))

(define (record-qemu-graph! path arguments state-identity)
  (write-exclusive-datum!
   path
   `((schema . 1)
     (unpaused . #t)
     (vcpus . 2)
     (memory-mib . 512)
     (state-device . ,(assoc-ref state-identity 'device))
     (state-inode . ,(assoc-ref state-identity 'inode))
     (state-size . ,(assoc-ref state-identity 'size))
     (arguments . ,arguments))))

(define (run-one-boot argv)
  (call-with-values
      (lambda () (extract-options argv))
    (lambda (base-argv options)
      (unless (= (length options) (length own-option-names))
        (fail "all six one-boot options are required exactly once"))
      (assert-mandatory-outer-timeout-arguments base-argv)
      (let* ((source-root (required options "--source-root"))
             (source-manifest (required options "--source-manifest-sha256"))
             (evidence-dir
              (require-private-directory
               (required options "--evidence-dir") "boot evidence directory"))
             (state-proc-file (required options "--state-proc-file"))
             (state-fd (state-proc-file->fd state-proc-file))
             (koreader (required options "--koreader-package"))
             (guile (required options "--guile"))
              (inner-process-sequence 0)
             (observed-root #f)
             (observed-root-identity #f)
             (observed-overlay-identity #f)
              (qemu-graph-requested? #f)
              (coordinator-path #f)
              (hard-vm-owner-result #f)
              (archive-created? #f)
             (captured (open-output-string))
             (status #f))
        (verify-two-boot-source-root! source-root source-manifest
                                      #:guarded-private? #t)
        (unless state-fd (fail "state argument is not /proc/self/fd/N"))
        (call-with-state-fd-anchor
         state-fd
         (lambda (anchor state-identity)
           (define (archive! disposition)
             (unless archive-created?
               (set! archive-created? #t)
               (let ((archive (string-append evidence-dir "/run")))
                 (mkdir-private archive)
                 (for-each
                  (lambda (relative)
                    (copy-relative! observed-root archive relative))
                  archive-roster)
                 (write-exclusive-datum!
                  (string-append evidence-dir "/run.scm")
                  `((schema . 1)
                    (disposition . ,disposition)
                    (unpaused . #t)
                    (vcpus . 2)
                    (memory-mib . 512)
                    (hard-vm-deadline-seconds . 360)
                    (term-grace-seconds . 5)
                    (run-root . ,observed-root)
                    (run-root-device . ,(and observed-root-identity
                                             (stat:dev observed-root-identity)))
                    (run-root-inode . ,(and observed-root-identity
                                            (stat:ino observed-root-identity)))
                    (overlay-device . ,(and observed-overlay-identity
                                            (stat:dev observed-overlay-identity)))
                    (overlay-inode . ,(and observed-overlay-identity
                                           (stat:ino observed-overlay-identity)))
                     (state-device . ,(assoc-ref state-identity 'device))
                     (state-inode . ,(assoc-ref state-identity 'inode))
                     (state-size . ,(assoc-ref state-identity 'size))
                     (hard-vm-owner-result-observed
                      . ,(and hard-vm-owner-result #t))
                     (hard-vm-owner-status
                      . ,(and hard-vm-owner-result
                              (car hard-vm-owner-result)))
                     (hard-vm-owner-timed-out
                      . ,(and hard-vm-owner-result
                              (cdr hard-vm-owner-result))))))))
            (letrec
                ((integration
                  (make-book-state-qemu-integration
                   (lambda (run-root run-identity)
                     (when observed-root
                       (fail "one boot created more than one ephemeral run root"))
                     (set! observed-root run-root)
                     (set! observed-root-identity run-identity))
                   (lambda (pid)
                     ((make-process-record-observer
                       (string-append evidence-dir "/run-root-guardian.scm")
                       'ephemeral-run-root-guardian)
                      pid))
                   (lambda (qemu run-root kernel initrd append-line overlay)
                     (when qemu-graph-requested?
                       (fail "one boot requested two QEMU graphs"))
                     (set! qemu-graph-requested? #t)
                     (unless (and observed-root (string=? observed-root run-root)
                                  (same-identity? observed-root-identity
                                                  (lstat run-root)))
                       (fail "QEMU graph run root differs from guarded run root"))
                     (set! observed-overlay-identity (lstat overlay))
                     (set! coordinator-path
                           (stage-coordinator! source-root run-root))
                     (let ((arguments
                            (coordinator-argv
                             guile coordinator-path koreader qemu run-root kernel
                             initrd append-line overlay state-proc-file)))
                       (record-qemu-graph!
                        (string-append evidence-dir "/qemu-graph.scm")
                        (let ((separator (member "--" arguments string=?)))
                          (unless separator
                            (fail "coordinator vector lacks the QEMU separator"))
                          (cons qemu (cdr separator)))
                        state-identity)
                       arguments))
                   (lambda (role child-argv environment cwd stdout-path
                                 stderr-path timeout grace)
                     (set! inner-process-sequence (+ inner-process-sequence 1))
                     (let* ((prefix
                             (format #f "~a/inner-~3,'0d"
                                     evidence-dir inner-process-sequence))
                            (record-guardian
                             (make-process-record-observer
                              (string-append prefix "-guardian.scm")
                              'accepted-inner-process-guardian))
                            (record-child
                             (make-process-record-observer
                              (string-append prefix "-child.scm")
                              'accepted-inner-direct-child))
                            (coordinator? (eq? role 'qemu))
                            (effective-extension
                             (and coordinator?
                                  (make-state-fd-exec-extension
                                   state-fd anchor state-identity
                                   (string-append evidence-dir
                                                  "/coordinator-exec.scm")
                                   'coordinator-exec-child cwd (lstat cwd))))
                            (observe-guardian
                             (lambda (pid)
                               (record-guardian pid)
                               (when coordinator?
                                 ((make-process-record-observer
                                   (string-append evidence-dir
                                                  "/coordinator-guardian.scm")
                                   'coordinator-process-guardian)
                                  pid))))
                            (observe-child
                             (lambda (pid)
                               (record-child pid)
                               (when coordinator?
                                 ((make-process-record-observer
                                   (string-append evidence-dir
                                                  "/coordinator-child.scm")
                                   'coordinator-direct-child)
                                  pid))))
                            (complete
                             (lambda (completed-role owned-result)
                               (unless (eq? role completed-role)
                                 (fail "typed process role changed at completion"))
                               (when coordinator?
                                 (set! hard-vm-owner-result owned-result)))))
                       ;; Assert every argument delivered by the fixed outer seam;
                       ;; callbacks cannot silently select another invocation.
                       (unless (and (list? child-argv) (list? environment)
                                    (string? stdout-path) (string? stderr-path)
                                    (number? timeout) (number? grace))
                         (fail "typed process hook context is malformed"))
                       (make-book-state-process-hooks
                        effective-extension observe-guardian observe-child
                        complete)))
                   (lambda (console run-root stderr-path)
                     (validate-console-minimum! console)
                     (let ((coordinator-output
                            (string-append run-root "/qemu.stdout")))
                       (unless (and
                                (<= (stat:size (lstat coordinator-output)) 4096)
                                (string=?
                                 (call-with-input-file coordinator-output
                                   get-string-all)
                                 coordinator-success))
                         (emit-qemu-failure-diagnostics run-root stderr-path)
                         (fail "coordinator did not report exact cleaned success")))
                     (archive! 'semantic-success))
                   (lambda (path identity)
                     (unless (and observed-root
                                  (string=? path observed-root)
                                  (same-identity? identity observed-root-identity))
                       (fail "typed cleanup callback names another run root"))
                     (unless archive-created?
                       (archive! 'partial-before-cleanup))))))
              (parameterize ((current-output-port captured))
                (set! status (disposable-qemu-main base-argv integration))))
           (when observed-root
             (let ((current (lstat-or-false observed-root)))
               (when current
                 (if (same-identity? observed-root-identity current)
                     (fail "ephemeral run root survived accepted cleanup: ~a"
                           observed-root)
                     (fail "ephemeral run root was replaced; preserved: ~a"
                           observed-root)))))
           (when (zero? status)
             (unless (and archive-created?
                          (string=? (get-output-string captured) outer-success))
               (fail "accepted outer success disposition changed"))
             (display
              "BOOK_STATE_ONE_BOOT: status=pass; semantic=archived; processes=zero; run-root=removed\n"))
           status))))))

(for-each
 (lambda (signal-number)
   (sigaction signal-number
               (lambda (received)
                 (note-disposable-qemu-signal received))))
 (list SIGINT SIGHUP SIGTERM))
(sigaction SIGPIPE SIG_IGN)
(umask #o077)

(exit
 (catch #t
   (lambda () (run-one-boot (command-line)))
   (lambda (key . arguments)
     (format (current-error-port) "BOOK_STATE_ONE_BOOT_ERROR: ~s ~s~%"
             key arguments)
     (force-output (current-error-port))
     1)))
