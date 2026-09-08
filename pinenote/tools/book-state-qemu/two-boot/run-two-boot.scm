#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Authenticated-capsule entry for one explicit two-fresh-boot campaign.
(use-modules (book-state-qemu state-volume)
             (disposable-qemu)
             (gcrypt base16)
             (gcrypt hash)
             (ice-9 ftw)
             (ice-9 getopt-long)
             (ice-9 match)
             (ice-9 rdelim)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)
              (two-boot bundle)
             (two-boot fd-handoff)
              (two-boot graph)
              (two-boot sequential)
              (two-boot source-gate)
              (two-boot timeout-contract))

(define one-boot-owner-seconds
  (exact->inexact one-boot-owner-hard-deadline-seconds))
(define term-grace-seconds
  (exact->inexact owned-process-term-grace-seconds))
(define cleanup-observation-seconds
  (exact->inexact post-owner-cleanup-observation-seconds))
(define max-log-bytes (* 4 1024 1024))
(define pinned-gcrypt
  "/gnu/store/yj7cgbs9d4qc93v93h63kpmdq0vm5k2i-guile-gcrypt-0.5.0")
(define pinned-guix-modules
  "/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules")

(define (fail message . arguments)
  (throw 'book-state-two-boot-campaign-error
         (apply format #f message arguments)))

(define (file-hash path)
  (bytevector->base16-string (file-sha256 path)))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (same-object? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (directory-empty? path)
  (null? (scandir path (lambda (name) (not (member name '("." "..")))))))

(define (read-one-datum path)
  (call-with-input-file path
    (lambda (port)
      (let ((value (read port)) (tail (read port)))
        (unless (eof-object? tail) (fail "record has trailing data: ~a" path))
        value))))

(define (write-exclusive-text! path text mode)
  (let ((fd (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       mode))
        (port #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chmod fd mode)
        (set! port (fdopen fd "w"))
        (display text port)
        (force-output port)
        (fsync fd))
      (lambda () (if port (close-port port) (close-fdes fd))))))

(define (mkdir-private path)
  (when (lstat-or-false path) (fail "refusing pre-existing path: ~a" path))
  (mkdir path #o700)
  (chmod path #o700)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "new directory is not private: ~a" path)))
  path)

(define (make-private-root base prefix)
  (let* ((base-info (lstat base))
         (base-fd (open-fdes base
                             (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
         (created #f)
         (root #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (same-object? base-info (stat base-fd))
          (fail "private base changed before mkdtemp: ~a" base))
        (set! created
              (mkdtemp (format #f "/proc/self/fd/~a/~aXXXXXX" base-fd prefix)))
        (chmod created #o700)
        (set! root (string-append base "/" (basename created)))
        (unless (same-object? (lstat created) (lstat root))
          (fail "private root changed during creation"))
        (values root (lstat root)))
      (lambda () (close-fdes base-fd)))))

(define (copy-bounded! source destination)
  (let ((info (lstat source)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:nlink info) 1)
                 (<= (stat:size info) max-log-bytes))
      (fail "partial evidence is not a bounded regular file: ~a" source)))
  (copy-file source destination)
  (chmod destination #o400))

(define state-copy-identity-fields '(device inode uid mode links size))

(define (state-copy-identity value)
  ;; state-volume-image-identity predates the fd-handoff record and exposes the
  ;; same six fields in a different order.  Keep both inherited interfaces
  ;; unchanged; canonicalize the trusted record before exact structural
  ;; equality with capture-state-fd-identity.
  (unless (and (list? value) (= (length value) 6))
    (fail "state image identity is not the exact six-field record"))
  (map (lambda (field)
         (let ((matches (filter (lambda (entry)
                                  (and (pair? entry) (eq? (car entry) field)))
                                value)))
           (unless (= (length matches) 1)
             (fail "state image identity lacks one exact ~a field" field))
           (car matches)))
       state-copy-identity-fields))

(define (copy-state-artifact! source expected-identity destination)
  ;; This path intentionally has no RLIMIT_FSIZE.  It copies the quiescent
  ;; 64-MiB review artifact by descriptors and never mounts it.
  (let ((input-fd (open-fdes source (logior O_RDONLY O_NOFOLLOW O_CLOEXEC)))
        (output-fd #f)
        (input #f)
        (output #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (equal? (capture-state-fd-identity input-fd) expected-identity)
          (fail "state image changed before final artifact copy"))
        (set! output-fd
              (open-fdes destination
                         (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                         #o600))
        (chmod output-fd #o600)
        (set! input (fdopen input-fd "rb"))
        (set! input-fd #f)
        (set! output (fdopen output-fd "wb"))
        (set! output-fd #f)
        (let loop ()
          (let ((chunk (get-bytevector-n input (* 1024 1024))))
            (unless (eof-object? chunk)
              (put-bytevector output chunk)
              (loop))))
        (force-output output)
        (fsync (fileno output))
        (chmod (fileno output) #o400))
      (lambda ()
        (when input (close-port input))
        (when output (close-port output))
        (when input-fd (close-fdes input-fd))
        (when output-fd (close-fdes output-fd))))))

(define (random-boot-id)
  (let ((port (open-file "/dev/urandom" "rb")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((bytes (get-bytevector-n port 16)))
          (unless (and (bytevector? bytes) (= (bytevector-length bytes) 16))
            (fail "could not obtain a host-only boot evidence ID"))
          (bytevector->base16-string bytes)))
      (lambda () (close-port port)))))

(define (process-gone-within? record seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (let loop ()
      (if (not (process-instance-live? (assoc-ref record 'pid)
                                       (assoc-ref record 'start-time)))
          #t
          (if (>= (get-internal-real-time) deadline)
              #f
              (begin (usleep 20000) (loop)))))))

(define (require-process-record-gone! path)
  (unless (lstat-or-false path)
    (fail "required process record was never published: ~a" path))
  (let ((record (read-process-identity path)))
    (unless (process-gone-within? record cleanup-observation-seconds)
      (fail "recorded process may remain after cleanup: ~a" path))
    record))

(define (process-fields prefix record)
  (list (cons (string-append prefix "-pid") (assoc-ref record 'pid))
        (cons (string-append prefix "-start-time")
              (assoc-ref record 'start-time))))

(define (record-lines fields)
  (string-concatenate
   (map (lambda (entry) (format #f "~a=~a~%" (car entry) (cdr entry))) fields)))

(define (run-scm-field record field)
  (let ((entry (assq field record)))
    (and entry (cdr entry))))

(define (trusted-guile-environment root guile source-root)
  (for-each
   (lambda (name)
     (let ((path (string-append root "/" name)))
       (mkdir path #o700)
       (chmod path #o700)))
   '("xdg-data" "xdg-state"))
  (append
   (supervisor-environment root guile)
   (list
    "GUILE_AUTO_COMPILE=0"
    (string-append "GUILE_LOAD_PATH=" source-root "/modules:"
                   pinned-gcrypt "/share/guile/site/3.0:"
                   pinned-guix-modules "/share/guile/site/3.0")
    (string-append "GUILE_LOAD_COMPILED_PATH="
                   pinned-gcrypt "/lib/guile/3.0/site-ccache:"
                   pinned-guix-modules "/lib/guile/3.0/site-ccache")
    "GUILE_EXTENSIONS_PATH="
    (string-append "XDG_DATA_HOME=" root "/xdg-data")
    (string-append "XDG_STATE_HOME=" root "/xdg-state"))))

(define (start-launch-context run-base evidence-dir guile source-root)
  (call-with-values
      (lambda () (make-private-root run-base "book-state-two-boot-launch."))
    (lambda (root identity)
      (let ((guardian
              (start-run-root-guardian root identity term-grace-seconds)))
        ((make-process-record-observer
          (string-append evidence-dir "/launch-root-guardian.scm")
          'boot-launch-root-guardian)
         (car guardian))
        `((root . ,root) (identity . ,identity) (guardian . ,guardian)
          (environment . ,(trusted-guile-environment
                           root guile source-root)))))))

(define (finish-launch-context! context evidence-dir)
  (let* ((root (assoc-ref context 'root))
         (identity (assoc-ref context 'identity))
         (guardian (assoc-ref context 'guardian))
         (cleanup-completed? #f)
         (failure #f))
    (define (retain-failure key arguments)
      (unless failure (set! failure (cons key arguments))))
    (catch #t
      (lambda ()
        (for-each
         (lambda (name)
           (let ((source (string-append root "/" name)))
             (when (lstat-or-false source)
               (copy-bounded! source
                              (string-append evidence-dir "/" name)))))
         '("one-boot.stdout" "one-boot.stderr")))
      retain-failure)
    (catch #t
      (lambda ()
        (let ((current (lstat-or-false root)))
          (unless (and current (same-object? current identity))
            (fail "boot launch root was replaced; replacement preserved: ~a"
                  root))
          (delete-created-tree root)
          (set! cleanup-completed? #t)))
      retain-failure)
    (catch #t
      (lambda ()
        (stop-run-root-guardian guardian cleanup-completed?))
      retain-failure)
    (when (and cleanup-completed? (lstat-or-false root))
      (retain-failure
       'book-state-two-boot-campaign-error
       (list (format #f "boot launch root survived exact cleanup: ~a" root))))
    (when failure (apply throw failure))))

(define (inner-process-record-name? name)
  (and (string-prefix? "inner-" name)
       (or (string-suffix? "-guardian.scm" name)
           (string-suffix? "-child.scm" name))))

(define (await-boot-owned-cleanup! evidence-dir run-base)
  ;; The accepted one-boot guardian publishes each accepted inner guardian and
  ;; direct child before release.  On owner SIGKILL, the inherited liveness EOF
  ;; still drives those exact guardians.  Wait for those identities and the
  ;; dedicated run base; never scan, signal, or reap an unrecorded PID.
  (let* ((record-names
          (filter inner-process-record-name? (scandir evidence-dir)))
         (records
          (map (lambda (name)
                 (read-process-identity
                  (string-append evidence-dir "/" name)))
               record-names))
         (deadline (+ (get-internal-real-time)
                      (* cleanup-observation-seconds
                         internal-time-units-per-second))))
    (let loop ()
      (let ((all-gone?
             (every (lambda (record)
                      (not (process-instance-live?
                            (assoc-ref record 'pid)
                            (assoc-ref record 'start-time))))
                    records))
            (runs-gone? (directory-empty? run-base)))
        (cond
         ((and all-gone? runs-gone?) #t)
         ((>= (get-internal-real-time) deadline)
          (fail
           "owned inner process or guarded run root survived cleanup; preserved"))
         (else (usleep 20000) (loop)))))))

(define (one-boot-argv bundle source-root source-manifest evidence-dir
                       state-proc-file run-base)
  (let ((entry (string-append source-root "/one-boot.scm")))
    (bind-mandatory-outer-timeout-arguments
     (list
      (bundle-guile bundle) "--no-auto-compile"
      "-L" (string-append source-root "/modules") entry
      "--source-root" source-root
      "--source-manifest-sha256" source-manifest
      "--evidence-dir" evidence-dir
      "--state-proc-file" state-proc-file
      "--koreader-package" (bundle-koreader-output bundle)
      "--guile" (bundle-guile bundle)
      "--boot-bundle" (string-append (bundle-root bundle) "/boot-bundle")
      "--baseline" (bundle-baseline bundle)
      "--kernel-sha256" (bundle-kernel-sha256 bundle)
      "--initrd-sha256" (bundle-initrd-sha256 bundle)
      "--config-sha256" (bundle-config-sha256 bundle)
      "--baseline-sha256" (bundle-baseline-sha256 bundle)
      "--dedicated-baseline"
      "--qemu" (bundle-qemu bundle)
      "--qemu-img" (bundle-qemu-img bundle)
      "--cp" (bundle-cp bundle)
      "--sha256sum" (bundle-sha256sum bundle)
      "--run-base" run-base))))

(define (run-one-boot! index lease bundle source-root source-manifest
                       evidence-root state-hash-before)
  (let* ((evidence-dir (string-append evidence-root "/boot" (number->string index)))
         (_ (mkdir-private evidence-dir))
         (boot-id (random-boot-id))
         (result #f)
         (owner-timed-out? #f)
         (state-identity (state-volume-image-identity lease)))
    (call-with-state-volume-writer-window
     lease
     (lambda (writer)
       (call-with-state-volume-qemu-handoff
        writer
        (lambda (handoff)
          (let* ((state-proc-file
                  (state-volume-qemu-handoff-file-name handoff))
                 (state-fd (state-proc-file->fd state-proc-file))
                  (context (start-launch-context
                            (state-volume-run-base lease) evidence-dir
                            (bundle-guile bundle) source-root))
                 (root (assoc-ref context 'root))
                 (identity (assoc-ref context 'identity))
                 (guardian (assoc-ref context 'guardian)))
            (call-with-state-fd-anchor
             state-fd
             (lambda (anchor expected)
               ;; Keep the CLOEXEC anchor until the owner and every recorded
               ;; inner writer/guardian have been reaped and their run roots
               ;; have disappeared.  This includes owner-SIGKILL cleanup.
               (dynamic-wind
                 (lambda () #t)
                 (lambda ()
                   (set! result
                          (run-owned-process
                          (one-boot-argv
                           bundle source-root source-manifest evidence-dir
                           state-proc-file (state-volume-run-base lease))
                          (assoc-ref context 'environment) root
                          (string-append root "/one-boot.stdout")
                          (string-append root "/one-boot.stderr")
                          one-boot-owner-seconds term-grace-seconds
                          (cadr guardian)
                          #:exec-extension
                          (make-state-fd-exec-extension
                           state-fd anchor expected
                           (string-append evidence-dir "/owner-exec.scm")
                           'one-boot-owner-exec root identity)
                          #:guardian-observer
                          (make-process-record-observer
                           (string-append evidence-dir "/owner-guardian.scm")
                           'one-boot-owner-guardian)
                          #:child-observer
                          (make-process-record-observer
                           (string-append evidence-dir "/owner-child.scm")
                           'one-boot-owner-child)))
                   (set! owner-timed-out? (and result (cdr result))))
                 (lambda ()
                   (let ((failure #f))
                     (catch #t
                       (lambda () (finish-launch-context! context evidence-dir))
                       (lambda (key . arguments)
                         (set! failure (cons key arguments))))
                     (catch #t
                       (lambda ()
                         (await-boot-owned-cleanup!
                          evidence-dir (state-volume-run-base lease)))
                       (lambda (key . arguments)
                         (unless failure
                           (set! failure (cons key arguments)))))
                     (when failure (apply throw failure))))))))))))
    ;; The state writer and handoff have both unwound before any semantic join.
    (let* ((state-hash-after (file-hash (state-volume-image-path lease)))
           (partial-run-path (string-append evidence-dir "/run.scm"))
           (partial-run
            (and (lstat-or-false partial-run-path)
                 (false-if-exception (read-one-datum partial-run-path))))
           (hard-vm-timed-out
            (if (and partial-run
                     (eq? (run-scm-field
                           partial-run 'hard-vm-owner-result-observed)
                          #t))
                (let ((value (run-scm-field
                              partial-run 'hard-vm-owner-timed-out)))
                  (cond ((eq? value #t) "true")
                        ((eq? value #f) "false")
                        (else "unknown")))
                "unknown"))
           (any-timed-out?
            (or owner-timed-out? (string=? hard-vm-timed-out "true"))))
      (when (or any-timed-out? (not result) (not (zero? (car result))))
           (write-exclusive-text!
            (string-append evidence-dir "/boot.record")
         (record-lines
          `((schema . 1) (boot-index . ,index) (boot-id . ,boot-id)
             (status . failed)
             (timed-out . ,(if any-timed-out? "true" "false"))
             (hard-vm-timed-out . ,hard-vm-timed-out)
             (owner-timed-out
              . ,(if owner-timed-out? "true" "false"))
              (guest-source-manifest-sha256
               . ,(bundle-guest-source-manifest-sha256 bundle))
              (guest-source-snapshot-manifest-sha256
               . ,(bundle-guest-source-snapshot-manifest-sha256 bundle))
              (guest-capsule-roster-sha256
               . ,(bundle-guest-capsule-roster-sha256 bundle))
              (guest-authority-source-sha256
               . ,(bundle-guest-authority-source-sha256 bundle))
             (guest-contract-sha256 . ,(bundle-guest-contract-sha256 bundle))
             (two-boot-timeout-contract-sha256
              . ,(file-hash (string-append source-root
                                           "/TIMEOUT-CONTRACT.scm")))
             (guest-cooperative-budget-seconds . 300)
             (hard-vm-deadline-seconds . 360)
             (term-grace-seconds . 5)
             (one-boot-owner-hard-deadline-seconds . 420)
            (state-hash-before . ,state-hash-before)
            (state-hash-after . ,state-hash-after)))
         #o400)
        (cond
         (owner-timed-out?
          (fail "boot ~a exceeded its independent 420-second owner ceiling"
                index))
         ((string=? hard-vm-timed-out "true")
          (fail "boot ~a reached its independent 360-second hard VM deadline"
                index))
         (else
          (fail "boot ~a failed before semantic acceptance: ~s" index result))))
      (let* ((owner (require-process-record-gone!
                     (string-append evidence-dir "/owner-child.scm")))
             (owner-guardian (require-process-record-gone!
                              (string-append evidence-dir
                                             "/owner-guardian.scm")))
             (launch-root-guardian
              (require-process-record-gone!
               (string-append evidence-dir "/launch-root-guardian.scm")))
             (coordinator (require-process-record-gone!
                           (string-append evidence-dir
                                          "/coordinator-child.scm")))
             (coordinator-guardian
              (require-process-record-gone!
               (string-append evidence-dir "/coordinator-guardian.scm")))
             (ephemeral-root-guardian
              (require-process-record-gone!
               (string-append evidence-dir "/run-root-guardian.scm")))
             (run-record (read-one-datum
                          (string-append evidence-dir "/run.scm")))
             (coordinator-record
              (read-one-datum
               (string-append evidence-dir
                              "/run/reader-ui/coordinator-result.scm")))
             (run-root (run-scm-field run-record 'run-root)))
        (unless (and (eq? (run-scm-field run-record 'disposition)
                          'semantic-success)
                     (run-scm-field run-record 'unpaused)
                      (= (run-scm-field run-record 'hard-vm-deadline-seconds) 360)
                      (= (run-scm-field run-record 'term-grace-seconds) 5)
                      (eq? (run-scm-field run-record
                                          'hard-vm-owner-result-observed)
                           #t)
                      (= (run-scm-field run-record 'hard-vm-owner-status) 0)
                      (eq? (run-scm-field run-record
                                          'hard-vm-owner-timed-out)
                           #f)
                     (not (lstat-or-false run-root))
                      (run-scm-field coordinator-record 'children-zero)
                      (= (run-scm-field coordinator-record 'coordinator-pid)
                         (assoc-ref coordinator 'pid))
                      (= (run-scm-field coordinator-record
                                        'coordinator-process-group)
                         (assoc-ref coordinator 'pid))
                      (= (run-scm-field coordinator-record
                                        'qemu-process-group)
                         (assoc-ref coordinator 'pid))
                      (= (run-scm-field coordinator-record
                                        'reader-process-group)
                         (assoc-ref coordinator 'pid))
                      (equal? (run-scm-field coordinator-record 'qemu-status)
                             '(exit . 0))
                     (equal? (run-scm-field coordinator-record 'reader-status)
                             '(exit . 0)))
          (fail "boot ~a cleanup record is incomplete or contradictory" index))
        (let ((qemu
               `((role . qemu)
                 (pid . ,(run-scm-field coordinator-record 'qemu-pid))
                 (start-time
                  . ,(run-scm-field coordinator-record 'qemu-start-time))))
              (reader
               `((role . koreader)
                 (pid . ,(run-scm-field coordinator-record 'reader-pid))
                 (start-time
                  . ,(run-scm-field coordinator-record 'reader-start-time)))))
          (unless (and (process-gone-within? qemu cleanup-observation-seconds)
                       (process-gone-within? reader cleanup-observation-seconds))
            (fail "boot ~a QEMU or KOReader may remain" index))
          (write-exclusive-text!
           (string-append evidence-dir "/boot.record")
           (record-lines
            (append
             `((schema . 1) (boot-index . ,index) (boot-id . ,boot-id)
                (status . pass) (timed-out . false)
                (hard-vm-timed-out . false)
                (owner-timed-out . false)
                 (guest-source-manifest-sha256
                  . ,(bundle-guest-source-manifest-sha256 bundle))
                 (guest-source-snapshot-manifest-sha256
                  . ,(bundle-guest-source-snapshot-manifest-sha256 bundle))
                 (guest-capsule-roster-sha256
                  . ,(bundle-guest-capsule-roster-sha256 bundle))
                 (guest-authority-source-sha256
                  . ,(bundle-guest-authority-source-sha256 bundle))
                (guest-contract-sha256
                 . ,(bundle-guest-contract-sha256 bundle))
                (two-boot-timeout-contract-sha256
                 . ,(file-hash (string-append source-root
                                              "/TIMEOUT-CONTRACT.scm")))
                (guest-cooperative-budget-seconds . 300)
                (hard-vm-deadline-seconds . 360)
                (term-grace-seconds . 5)
                (one-boot-owner-hard-deadline-seconds . 420)
               (root-filesystem-label . PNGuixRoot)
               (state-filesystem-label . WBBookStateV1)
               (source-manifest-sha256 . ,source-manifest)
               (bundle-manifest-sha256
                . ,(bundle-manifest-sha256 bundle))
               (kernel-sha256 . ,(bundle-kernel-sha256 bundle))
               (initrd-sha256 . ,(bundle-initrd-sha256 bundle))
               (config-sha256 . ,(bundle-config-sha256 bundle))
               (baseline-sha256 . ,(bundle-baseline-sha256 bundle))
               (qemu-graph-sha256
                . ,(file-hash
                    (string-append evidence-dir "/qemu-graph.scm")))
               (run-root . ,run-root)
               (run-root-device
                . ,(run-scm-field run-record 'run-root-device))
               (run-root-inode
                . ,(run-scm-field run-record 'run-root-inode))
               (overlay-device
                . ,(run-scm-field run-record 'overlay-device))
               (overlay-inode
                . ,(run-scm-field run-record 'overlay-inode))
               (state-device . ,(assoc-ref state-identity 'device))
               (state-inode . ,(assoc-ref state-identity 'inode))
               (state-size . ,(assoc-ref state-identity 'size))
               (state-hash-before . ,state-hash-before)
               (state-hash-after . ,state-hash-after))
             (process-fields "owner" owner)
             (process-fields "owner-guardian" owner-guardian)
             (process-fields "launch-root-guardian" launch-root-guardian)
             (process-fields "coordinator" coordinator)
             (process-fields "coordinator-guardian" coordinator-guardian)
             (process-fields "ephemeral-root-guardian"
                             ephemeral-root-guardian)
             (process-fields "qemu" qemu)
              (process-fields "reader" reader)))
            #o400)
           (run-single-boot-checker!
            bundle source-root evidence-root evidence-dir index
            (state-volume-run-base lease))
           state-hash-after)))))

(define (evidence-files root)
  (let ((files '()))
    (define (walk relative)
      (let* ((path (if (string-null? relative) root
                       (string-append root "/" relative)))
             (info (lstat path)))
        (cond
         ((eq? (stat:type info) 'directory)
          (for-each
           (lambda (name)
             (unless (member name '("." ".."))
               (walk (if (string-null? relative) name
                         (string-append relative "/" name)))))
           (sort (scandir path) string<?)))
         ((eq? (stat:type info) 'regular)
          (unless (string=? relative "EVIDENCE.sha256")
            (set! files (cons relative files))))
         (else (fail "evidence contains a symlink or special file: ~a" relative)))))
    (walk "")
    (sort files string<?)))

(define (seal-evidence! root)
  (let ((text
         (string-concatenate
          (map (lambda (relative)
                 (format #f "~a  ~a~%"
                         (file-hash (string-append root "/" relative)) relative))
               (evidence-files root)))))
    (write-exclusive-text! (string-append root "/EVIDENCE.sha256") text #o400)
    (file-hash (string-append root "/EVIDENCE.sha256"))))

(define (seal-payload! root)
  (let ((text
         (string-concatenate
          (map (lambda (relative)
                 (format #f "~a  ~a~%"
                         (file-hash (string-append root "/" relative)) relative))
               (evidence-files root)))))
    (write-exclusive-text! (string-append root "/PAYLOAD.sha256") text #o400)
    (file-hash (string-append root "/PAYLOAD.sha256"))))

(define (start-checker-context run-base python)
  (call-with-values
      (lambda () (make-private-root run-base "book-state-two-boot-checker."))
    (lambda (root identity)
      (let ((guardian
              (start-run-root-guardian root identity term-grace-seconds)))
        ((make-process-record-observer
          (string-append root "/checker-root-guardian.scm")
          'evidence-checker-root-guardian)
         (car guardian))
        `((root . ,root) (identity . ,identity) (guardian . ,guardian)
          (environment . ,(supervisor-environment root python)))))))

(define (finish-checker-context! context evidence-root)
  (let* ((root (assoc-ref context 'root))
         (identity (assoc-ref context 'identity))
         (guardian (assoc-ref context 'guardian))
         (cleanup-completed? #f)
         (failure #f))
    (define (retain-failure key arguments)
      (unless failure (set! failure (cons key arguments))))
    (catch #t
      (lambda ()
        (for-each
         (lambda (pair)
           (copy-bounded! (string-append root "/" (car pair))
                          (string-append evidence-root "/" (cdr pair))))
         '(("checker.stdout" . "CHECKER.txt")
           ("checker.stderr" . "CHECKER.stderr")
           ("checker-root-guardian.scm" . "checker-root-guardian.scm")
           ("checker-guardian.scm" . "checker-guardian.scm")
           ("checker-child.scm" . "checker-child.scm"))))
      retain-failure)
    (catch #t
      (lambda ()
        (let ((current (lstat-or-false root)))
          (unless (and current (same-object? current identity))
            (fail "checker root was replaced; replacement preserved: ~a" root))
          (delete-created-tree root)
          (set! cleanup-completed? #t)))
      retain-failure)
    (catch #t
      (lambda ()
        (stop-run-root-guardian guardian cleanup-completed?))
      retain-failure)
    (when failure (apply throw failure))))

(define (run-evidence-checker! bundle source-root evidence-root payload-sha256
                                run-base)
  (let* ((python (bundle-python bundle))
         (checker (string-append source-root "/check-evidence.py"))
          (context (start-checker-context run-base python))
         (root (assoc-ref context 'root))
         (guardian (assoc-ref context 'guardian))
         (result #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! result
              (run-owned-process
               (list python "-B" "-I" "-S" checker
                     "--evidence" evidence-root
                     "--payload-manifest-sha256" payload-sha256)
               (assoc-ref context 'environment) root
               (string-append root "/checker.stdout")
               (string-append root "/checker.stderr")
               60.0 term-grace-seconds (cadr guardian)
               #:guardian-observer
               (make-process-record-observer
                 (string-append root "/checker-guardian.scm")
                 'evidence-checker-process-guardian)
               #:child-observer
               (make-process-record-observer
                 (string-append root "/checker-child.scm")
                 'evidence-checker-direct-child))))
      (lambda () (finish-checker-context! context evidence-root)))
    (when (or (not result) (cdr result) (not (zero? (car result))))
      (fail "strict evidence checker failed or timed out: ~s" result))
    (for-each
     require-process-record-gone!
     (map (lambda (name) (string-append evidence-root "/" name))
          '("checker-root-guardian.scm" "checker-guardian.scm"
            "checker-child.scm")))
    (unless (and (directory-empty? run-base)
                 (string=?
                  (call-with-input-file
                      (string-append evidence-root "/CHECKER.txt")
                    get-string-all)
                  "PASS: exact two-fresh-boot Book State evidence and cleanup join\n")
                 (zero? (stat:size
                         (lstat (string-append evidence-root
                                               "/CHECKER.stderr")))))
      (fail "strict checker output or cleanup disposition differs"))
    #t))

(define (single-checker-name index suffix)
  (format #f "boot~a-checker-~a.scm" index suffix))

(define (start-single-checker-context run-base evidence-root index python)
  (call-with-values
      (lambda () (make-private-root run-base "book-state-single-boot-checker."))
    (lambda (root identity)
      (let ((guardian
              (start-run-root-guardian root identity term-grace-seconds)))
        ((make-process-record-observer
          (string-append evidence-root "/"
                         (single-checker-name index "root-guardian"))
          'boot-evidence-checker-root-guardian)
         (car guardian))
        `((root . ,root) (identity . ,identity) (guardian . ,guardian)
          (environment . ,(supervisor-environment root python)))))))

(define (finish-single-checker-context! context evidence-root index)
  (let* ((root (assoc-ref context 'root))
         (identity (assoc-ref context 'identity))
         (guardian (assoc-ref context 'guardian))
         (cleanup-completed? #f)
         (failure #f))
    (define (retain-failure key arguments)
      (unless failure (set! failure (cons key arguments))))
    (catch #t
      (lambda ()
        (copy-bounded! (string-append root "/checker.stdout")
                       (format #f "~a/BOOT~a-CHECKER.txt"
                               evidence-root index))
        (copy-bounded! (string-append root "/checker.stderr")
                       (format #f "~a/BOOT~a-CHECKER.stderr"
                               evidence-root index)))
      retain-failure)
    (catch #t
      (lambda ()
        (let ((current (lstat-or-false root)))
          (unless (and current (same-object? current identity))
            (fail "single-boot checker root was replaced; preserved: ~a" root))
          (delete-created-tree root)
          (set! cleanup-completed? #t)))
      retain-failure)
    (catch #t
      (lambda ()
        (stop-run-root-guardian guardian cleanup-completed?))
      retain-failure)
    (when failure (apply throw failure))))

(define (run-single-boot-checker! bundle source-root evidence-root evidence-dir
                                  index run-base)
  ;; This checkpoint runs after the state writer/OFD window has unwound.  Its
  ;; success is required before the sequential seam can invoke the next boot.
  (let* ((python (bundle-python bundle))
         (checker (string-append source-root "/check-evidence.py"))
         (context
          (start-single-checker-context run-base evidence-root index python))
         (root (assoc-ref context 'root))
         (guardian (assoc-ref context 'guardian))
         (result #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! result
              (run-owned-process
               (list python "-B" "-I" "-S" checker
                     "--single-boot-evidence" evidence-dir
                     "--boot-index" (number->string index))
               (assoc-ref context 'environment) root
               (string-append root "/checker.stdout")
               (string-append root "/checker.stderr")
               60.0 term-grace-seconds (cadr guardian)
               #:guardian-observer
               (make-process-record-observer
                (string-append evidence-root "/"
                               (single-checker-name index "guardian"))
                'boot-evidence-checker-process-guardian)
               #:child-observer
               (make-process-record-observer
                (string-append evidence-root "/"
                               (single-checker-name index "child"))
                'boot-evidence-checker-direct-child))))
      (lambda ()
        (finish-single-checker-context! context evidence-root index)))
    (when (or (not result) (cdr result) (not (zero? (car result))))
      (fail "strict boot-~a evidence checker failed or timed out: ~s"
            index result))
    (for-each
     require-process-record-gone!
     (map (lambda (suffix)
            (string-append evidence-root "/"
                           (single-checker-name index suffix)))
          '("root-guardian" "guardian" "child")))
    (unless (and
             (directory-empty? run-base)
             (string=?
              (call-with-input-file
                  (format #f "~a/BOOT~a-CHECKER.txt" evidence-root index)
                get-string-all)
              (format #f
                      "PASS: exact fresh boot ~a Book State evidence and cleanup join~%"
                      index))
             (zero? (stat:size
                     (lstat (format #f "~a/BOOT~a-CHECKER.stderr"
                                    evidence-root index)))))
      (fail "strict boot-~a checker output or cleanup differs" index))
    #t))

(define (start-cross-checker-context run-base evidence-root python)
  (call-with-values
      (lambda () (make-private-root run-base "book-state-cross-boot-checker."))
    (lambda (root identity)
      (let ((guardian
              (start-run-root-guardian root identity term-grace-seconds)))
        ((make-process-record-observer
          (string-append evidence-root "/cross-checker-root-guardian.scm")
          'cross-evidence-checker-root-guardian)
         (car guardian))
        `((root . ,root) (identity . ,identity) (guardian . ,guardian)
          (environment . ,(supervisor-environment root python)))))))

(define (finish-cross-checker-context! context evidence-root)
  (let* ((root (assoc-ref context 'root))
         (identity (assoc-ref context 'identity))
         (guardian (assoc-ref context 'guardian))
         (cleanup-completed? #f)
         (failure #f))
    (define (retain-failure key arguments)
      (unless failure (set! failure (cons key arguments))))
    (catch #t
      (lambda ()
        (copy-bounded! (string-append root "/checker.stdout")
                       (string-append evidence-root "/CROSS-CHECKER.txt"))
        (copy-bounded! (string-append root "/checker.stderr")
                       (string-append evidence-root "/CROSS-CHECKER.stderr")))
      retain-failure)
    (catch #t
      (lambda ()
        (let ((current (lstat-or-false root)))
          (unless (and current (same-object? current identity))
            (fail "cross-boot checker root was replaced; preserved: ~a" root))
          (delete-created-tree root)
          (set! cleanup-completed? #t)))
      retain-failure)
    (catch #t
      (lambda ()
        (stop-run-root-guardian guardian cleanup-completed?))
      retain-failure)
    (when failure (apply throw failure))))

(define (run-cross-boot-checker! bundle source-root evidence-root run-base)
  ;; This aggregate join runs while the validated campaign state still exists.
  ;; Any cross-lifetime contradiction therefore preserves the campaign.
  (let* ((python (bundle-python bundle))
         (checker (string-append source-root "/check-evidence.py"))
         (context (start-cross-checker-context
                   run-base evidence-root python))
         (root (assoc-ref context 'root))
         (guardian (assoc-ref context 'guardian))
         (result #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! result
              (run-owned-process
               (list python "-B" "-I" "-S" checker
                     "--cross-boot-evidence" evidence-root)
               (assoc-ref context 'environment) root
               (string-append root "/checker.stdout")
               (string-append root "/checker.stderr")
               60.0 term-grace-seconds (cadr guardian)
               #:guardian-observer
               (make-process-record-observer
                (string-append evidence-root "/cross-checker-guardian.scm")
                'cross-evidence-checker-process-guardian)
               #:child-observer
               (make-process-record-observer
                (string-append evidence-root "/cross-checker-child.scm")
                'cross-evidence-checker-direct-child))))
      (lambda () (finish-cross-checker-context! context evidence-root)))
    (when (or (not result) (cdr result) (not (zero? (car result))))
      (fail "strict pre-cleanup cross-boot checker failed or timed out: ~s"
            result))
    (for-each
     require-process-record-gone!
     (map (lambda (name) (string-append evidence-root "/" name))
          '("cross-checker-root-guardian.scm" "cross-checker-guardian.scm"
            "cross-checker-child.scm")))
    (unless (and
             (directory-empty? run-base)
             (string=?
              (call-with-input-file
                  (string-append evidence-root "/CROSS-CHECKER.txt")
                get-string-all)
              "PASS: exact pre-cleanup two-boot cross-lifetime join\n")
             (zero? (stat:size
                     (lstat (string-append evidence-root
                                           "/CROSS-CHECKER.stderr")))))
      (fail "strict pre-cleanup cross-boot checker output or cleanup differs"))
    #t))

(define (freeze-evidence! root)
  (let walk ((path root))
    (let ((info (lstat path)))
      (cond
       ((eq? (stat:type info) 'directory)
        (for-each
         (lambda (name)
           (unless (member name '("." ".."))
             (walk (string-append path "/" name))))
         (scandir path))
        (chmod path #o500))
       ((eq? (stat:type info) 'regular) (chmod path #o400))
       (else (fail "refusing to freeze a special evidence entry: ~a" path))))))

(define (run-campaign bundle source-root source-manifest
                      campaign-base run-base evidence-base)
  (let ()
    (unless (and (directory-empty? campaign-base)
                 (directory-empty? run-base))
      (fail "dedicated campaign and run bases must begin empty"))
    (call-with-values
        (lambda () (make-private-root evidence-base "book-state-two-boot-evidence."))
      (lambda (evidence-root evidence-identity)
        (let ((campaign-root #f) (campaign-identity #f) (completed? #f))
          (catch #t
            (lambda ()
              (call-with-new-state-volume-lease
               campaign-base run-base (bundle-mke2fs bundle)
               (bundle-e2fsck bundle)
               (lambda (lease)
                 (set! campaign-root (state-volume-campaign-root lease))
                 (set! campaign-identity (lstat campaign-root))
                 (let* ((state-identity (state-volume-image-identity lease))
                        (initial (file-hash (state-volume-image-path lease))))
                   (call-with-values
                       (lambda ()
                         (call-with-two-sequential-boots
                          initial
                          (lambda (index prior)
                            (run-one-boot!
                             index lease bundle source-root source-manifest
                             evidence-root prior))))
                     (lambda (post1 post2)
                    (unless (and (not (string=? initial post1))
                                 (not (string=? post1 post2)))
                     (fail "state image hashes did not change across both saves"))
                    (run-cross-boot-checker!
                     bundle source-root evidence-root run-base)
                    (validate-state-volume-filesystem! lease (bundle-e2fsck bundle))
                   (let ((artifact (string-append evidence-root
                                                  "/book-state.ext4")))
                      (copy-state-artifact!
                       (state-volume-image-path lease)
                       (state-copy-identity state-identity) artifact)
                     (unless (and (= (stat:size (lstat artifact)) state-volume-size)
                                  (= (logand (stat:mode (lstat artifact)) #o7777)
                                     #o400)
                                  (string=? (file-hash artifact) post2))
                       (fail "final read-only state artifact differs from post-boot-2")))
                   (cleanup-state-volume-campaign! lease)
                   (when (lstat-or-false campaign-root)
                     (fail "campaign root survived accepted identity-safe cleanup"))
                   (unless (directory-empty? run-base)
                     (fail "ephemeral run base is not empty after both boots"))
                    (write-exclusive-text!
                       (string-append evidence-root "/campaign.record")
                      (record-lines
                         `((schema . 2) (status . pass)
                          (bundle-id . ,(bundle-id bundle))
                         (bundle-manifest-sha256
                          . ,(bundle-manifest-sha256 bundle))
                         (source-manifest-sha256 . ,source-manifest)
                           (guest-source-manifest-sha256
                            . ,(bundle-guest-source-manifest-sha256 bundle))
                           (guest-source-snapshot-manifest-sha256
                            . ,(bundle-guest-source-snapshot-manifest-sha256
                                bundle))
                           (guest-capsule-roster-sha256
                            . ,(bundle-guest-capsule-roster-sha256 bundle))
                           (guest-authority-source-sha256
                            . ,(bundle-guest-authority-source-sha256 bundle))
                          (guest-contract-sha256
                           . ,(bundle-guest-contract-sha256 bundle))
                          (guest-cooperative-budget-seconds . 300)
                          (hard-vm-deadline-seconds . 360)
                          (term-grace-seconds . 5)
                          (one-boot-owner-hard-deadline-seconds . 420)
                          (timeout-contract-sha256
                          . ,(file-hash
                              (string-append source-root
                                             "/TIMEOUT-CONTRACT.scm")))
                         (campaign-root . ,campaign-root)
                         (campaign-root-device . ,(stat:dev campaign-identity))
                         (campaign-root-inode . ,(stat:ino campaign-identity))
                         (campaign-root-removed . true)
                         (run-base-empty . true)
                         (state-filesystem-label . WBBookStateV1)
                         (state-filesystem-size . ,state-volume-size)
                         (writers-released-before-inspection . true)
                         (e2fsck-read-only . pass)
                         (initial-state-sha256 . ,initial)
                         (post-boot1-state-sha256 . ,post1)
                         (post-boot2-state-sha256 . ,post2)
                         (final-artifact-sha256 . ,post2)
                          (final-artifact-mode . "0400")
                         (boot1-record-sha256
                          . ,(file-hash
                              (string-append evidence-root
                                             "/boot1/boot.record")))
                         (boot2-record-sha256
                          . ,(file-hash
                              (string-append evidence-root
                                             "/boot2/boot.record")))))
                       #o400)
                   (let ((payload (seal-payload! evidence-root)))
                     (run-evidence-checker!
                      bundle source-root evidence-root payload run-base)
                     (let ((manifest (seal-evidence! evidence-root)))
                       (freeze-evidence! evidence-root)
                     (set! completed? #t)
                     (format #t
                             "BOOK_STATE_TWO_BOOT: status=pass; evidence=~a; manifest-sha256=~a; state-artifact=read-only~%"
                             evidence-root manifest)
                       0))))))))
            (lambda (key . arguments)
              ;; Never clean an uncertain campaign.  The accepted active-boot
              ;; guardians have already been joined by each synchronous call;
              ;; any uncertainty is reported and the private roots remain.
              (false-if-exception
               (write-exclusive-text!
                (string-append evidence-root "/CAMPAIGN-FAILURE.txt")
                (format #f "status=failed\nkey=~s\ndetails=~s\ncampaign-preserved=~a\n"
                        key arguments (if campaign-root "true" "not-created"))
                #o400))
              (format (current-error-port)
                      "BOOK_STATE_TWO_BOOT_ERROR: ~s ~s; private evidence=~a; campaign=~a~%"
                      key arguments evidence-root
                      (or campaign-root "not-created"))
              (force-output (current-error-port))
              1)))))))

(define cli-options
  '((bundle (value #t))
    (campaign-base (value #t))
    (run-base (value #t))
    (evidence-base (value #t))
    (help (single-char #\h))))

(define (required-cli options name)
  (or (option-ref options name #f)
      (fail "missing required --~a" name)))

(define (private-empty-base path label)
  (unless (and (string? path) (string-prefix? "/tmp/opencode/" path)
               (string=? path (canonicalize-path path)))
    (fail "~a must be a canonical /tmp/opencode directory" label))
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "~a must be caller-owned mode 0700" label)))
  path)

(define (assert-distinct-bases! paths)
  (unless (= (length paths) (length (delete-duplicates paths string=?)))
    (fail "campaign, run, and evidence bases must differ"))
  (for-each
   (lambda (left)
     (for-each
      (lambda (right)
        (when (and (not (string=? left right))
                   (string-prefix? (string-append left "/") right))
          (fail "campaign, run, and evidence bases must not contain each other")))
      paths))
   paths))

(define (run-two-boot-main/internal argv authenticated-source-root
                                    authenticated-source-manifest)
  (when (zero? (getuid))
    (fail "the two-boot campaign refuses root"))
  (let ((options (getopt-long argv cli-options)))
    (when (option-ref options 'help #f)
      (format #t
              "usage: ~a --bundle DIR --campaign-base DIR --run-base DIR --evidence-base DIR~%"
              (car argv))
      (exit 0))
    ;; This is intentionally the first path-consuming gate.  Only the exact
    ;; source-pinned production manifest and closed metadata can pass; caller
    ;; review claims or expected hashes cannot reach QEMU/process launch.
    (let* ((bundle-root (required-cli options 'bundle))
           (bundle (authenticate-production-two-boot-bundle bundle-root))
           (source-root authenticated-source-root)
           (source-manifest-path
            (string-append source-root "/SOURCE-MANIFEST.sha256"))
           (source-manifest authenticated-source-manifest)
           (timeout-path (string-append source-root "/TIMEOUT-CONTRACT.scm"))
           (campaign-base
            (private-empty-base (required-cli options 'campaign-base)
                                "campaign base"))
           (run-base (private-empty-base (required-cli options 'run-base)
                                         "run base"))
           (evidence-base
            (private-empty-base (required-cli options 'evidence-base)
                                "evidence base")))
      (unless (and (string=? (dirname (canonicalize-path (car argv))) source-root)
                   (string=? (file-hash source-manifest-path) source-manifest))
        (fail "campaign entry differs from its retained authenticated capsule"))
      (verify-two-boot-source-root! source-root source-manifest
                                    #:guarded-private? #t)
      (unless (equal? (read-one-datum timeout-path) two-boot-timeout-contract)
        (fail "source timeout contract differs from executable constants"))
      (assert-distinct-bases! (list campaign-base run-base evidence-base))
      (run-campaign bundle source-root source-manifest
                    campaign-base run-base evidence-base))))

(define (run-two-boot-main argv authenticated-source-root
                           authenticated-source-manifest)
  (sigaction SIGPIPE SIG_IGN)
  (umask #o077)
 (catch #t
   (lambda ()
     (run-two-boot-main/internal
      argv authenticated-source-root authenticated-source-manifest))
   (lambda (key . arguments)
     (format (current-error-port) "BOOK_STATE_TWO_BOOT_ERROR: ~s ~s~%"
             key arguments)
     (force-output (current-error-port))
     1)))
