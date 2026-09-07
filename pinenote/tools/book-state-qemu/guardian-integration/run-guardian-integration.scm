#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Bounded actual-QEMU host integration for the accepted Book State v3 seam.
(use-modules (book-state-qemu qemu-graph)
             (book-state-qemu state-volume)
             (disposable-qemu)
             (gcrypt base16)
             (gcrypt hash)
             (guardian-integration qmp-probe)
             (guardian-integration successor-reader-graph)
             (guardian-integration successor-state-guardian)
             (ice-9 binary-ports)
             (ice-9 format)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

(define %outer-module (resolve-module '(disposable-qemu)))
(define (outer-private name) (module-ref %outer-module name))

(define exact-qemu
  "/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1/bin/qemu-system-aarch64")
(define exact-qemu-img
  "/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1/bin/qemu-img")
(define exact-mke2fs
  "/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2/sbin/mke2fs")
(define exact-e2fsck
  "/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2/sbin/e2fsck")
(define exact-kernel
  "/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote/Image")
(define artifact-root
  (string-append
   (getcwd)
   "/pinenote/tools/book-execution-spike/build/artifacts/"
   "pinenote-book-execution-reader-interaction-20260906-v1"))
(define exact-bundle-kernel
  (string-append artifact-root "/boot-bundle/extlinux/Image"))
(define exact-initrd
  (string-append artifact-root "/boot-bundle/extlinux/initrd.cpio.gz"))
(define exact-config
  (string-append artifact-root "/boot-bundle/extlinux/extlinux.conf"))
(define exact-baseline (string-append artifact-root "/baseline.raw"))

(define fixed-inputs
  `((,exact-qemu
     . "364cea5b2ea702806fdeab1e2ee48a6d265daba7100156d3ab828c29a9c00e20")
    (,exact-qemu-img
     . "39dfabf97783e8a1d4825713566b71b10eeaac4d9cba2404baec942ab90bf859")
    (,exact-mke2fs
     . "c0c9fc4b1e4a236fcaa299f1e620783906480d5d0028ae7da7144d81a2f3972f")
    (,exact-e2fsck
     . "3b5db06b3a7966fda5cac55e959651569fc715dc4ec5dc9765011c46c0f05a3c")
    (,exact-kernel
     . "f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223")
    (,exact-bundle-kernel
     . "f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223")
    (,exact-initrd
     . "d28c4c95ad1a234895e2556524971538aa0dfc10f237fa018917252ae89a2507")
    (,exact-config
     . "aeea33940e8c1ba9d6cf97aa41f19d02a9eb7a1faa162efeecd079e4b8a5f284")
    (,exact-baseline
     . "34eef74f68630a55fa1aa89e7cd4906575b9045cfca54057a788c7c844ee4a1e")
    (,(string-append
       (getcwd) "/pinenote/tools/book-execution-spike/disposable-qemu.scm")
     . "0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca")
    (,(string-append
       (getcwd) "/pinenote/tools/book-execution-spike/reader-qemu-graph.scm")
     . "16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002")
    (,(string-append
       (getcwd) "/pinenote/tools/book-execution-spike/guest-console-assertions.scm")
     . "fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908")
    (,(string-append artifact-root "/manifest.txt")
     . "24201e22625ffb3a89dc6d40de0557a73e10c78bb1c32074a680139415d2c1e5")
    (,(string-append
       (getcwd) "/pinenote/tools/book-state-qemu/book-state-qemu/state-volume.scm")
     . "79324bbb80ba8eb9e57c4d8285b0d6f4f76020bfb1016d0e8c22fe8526b42d29")
    (,(string-append
       (getcwd) "/pinenote/tools/book-state-qemu/book-state-qemu/qemu-graph.scm")
     . "708ccca8fe367a20ef886168bed524704a5cdd0a97acf5f0609eecd822ad977c")))

(define qemu-timeout-seconds 30.0)
(define qemu-term-grace-seconds 5.0)
(define contender-timeout-seconds 4.0)
(define max-log-bytes (* 1024 1024))
(define expected-check-count 38)
(define checks 0)
(define work-root #f)
(define work-root-identity #f)
(define campaign-reference #f)
(define campaign-root #f)
(define run-base #f)
(define records #f)
(define evidence #f)
(define active-identities '())

(define (fail message . arguments)
  (throw 'book-state-qemu-guardian-integration-error
         (apply format #f message arguments)))

(define (check label value)
  (set! checks (+ checks 1))
  (unless value (fail "check ~a failed: ~a" checks label))
  (format #t "ok ~a - ~a~%" checks label)
  (force-output)
  #t)

(define (now)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (same-object? first second)
  (and (= (stat:dev first) (stat:dev second))
       (= (stat:ino first) (stat:ino second))))

(define (remove-owned-tree path)
  (let ((info (lstat-or-false path)))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name)
               (remove-owned-tree (string-append path "/" name)))
             (scandir path (lambda (name) (not (member name '("." ".."))))))
            (rmdir path))
          (delete-file path)))))

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
      (lambda ()
        (if port (close-port port) (close-fdes fd))))))

(define (write-exclusive-text! path text)
  (let ((fd (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       #o600))
        (port #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chmod fd #o600)
        (set! port (fdopen fd "w"))
        (display text port)
        (force-output port)
        (fsync fd))
      (lambda ()
        (if port (close-port port) (close-fdes fd))))))

(define (read-datum path)
  (call-with-input-file path read))

(define (wait-for-path path seconds)
  (let ((deadline (+ (now) seconds)))
    (let loop ()
      (cond
       ((lstat-or-false path) #t)
       ((>= (now) deadline) #f)
       (else (usleep 10000) (loop))))))

(define (wait-process-gone identity seconds)
  (let ((deadline (+ (now) seconds))
        (pid (assoc-ref identity 'pid))
        (start-time (assoc-ref identity 'start-time)))
    (let loop ()
      (cond
       ((not (process-instance-live? pid start-time)) #t)
       ((>= (now) deadline) #f)
       (else (usleep 10000) (loop))))))

(define (track! identity)
  (set! active-identities (cons identity active-identities))
  identity)

(define (untrack! identity)
  (set! active-identities (delete identity active-identities eq?)))

(define (hash-file path)
  (bytevector->base16-string (file-sha256 path)))

(define (validate-fixed-inputs!)
  (let ((observed '()))
    (for-each
     (match-lambda
       ((path . expected)
        (let ((before (lstat path)))
          (unless (eq? (stat:type before) 'regular)
            (fail "fixed input is not regular: ~a" path))
          (let ((actual (hash-file path))
                (after (lstat path)))
            (unless (and (same-object? before after)
                         (= (stat:size before) (stat:size after))
                         (string=? actual expected))
              (fail "fixed input hash/identity mismatch: ~a" path))
            (set! observed
                  (cons `((path . ,path) (sha256 . ,actual)
                          (size . ,(stat:size after)))
                        observed))))))
     fixed-inputs)
    (write-exclusive-datum!
     (string-append evidence "/fixed-inputs.scm")
     `((schema . 1) (inputs . ,(reverse observed))))))

(define (require-private-empty-directory path)
  (let* ((canonical (canonicalize-path path))
         (info (lstat canonical))
         (inventory
          (scandir canonical (lambda (name) (not (member name '("." "..")))))))
    (unless (and (string=? canonical path)
                 (string-prefix? "/tmp/opencode/" canonical)
                 (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700)
                 (null? inventory))
      (fail "evidence directory must be canonical, private, empty, and below /tmp/opencode"))
    canonical))

(define (record-path scenario suffix)
  (string-append records "/" scenario "." suffix ".scm"))

(define (evidence-path scenario suffix)
  (string-append evidence "/" scenario "." suffix))

(define (event! scenario sequence name fields)
  (write-exclusive-datum!
   (record-path scenario (format #f "event-~2,'0d-~a" sequence name))
   `((schema . 1) (scenario . ,scenario) (sequence . ,sequence)
     (event . ,name) (pid . ,(getpid)) ,@fields)))

(define (archive-bounded! source destination)
  (let ((info (lstat-or-false source)))
    (if (not info)
        (write-exclusive-datum! destination '((state . missing)))
        (begin
          (unless (and (eq? (stat:type info) 'regular)
                       (<= (stat:size info) max-log-bytes))
            (fail "run log is not a bounded regular file: ~a" source))
          (let ((bytes (call-with-input-file source get-bytevector-all))
                (after (lstat source)))
            (unless (and (same-object? info after)
                         (= (bytevector-length bytes) (stat:size info)))
              (fail "run log changed while archiving: ~a" source))
            (let ((fd (open-fdes destination
                                 (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW
                                         O_CLOEXEC)
                                 #o600))
                  (port #f))
              (dynamic-wind
                (lambda () #t)
                (lambda ()
                  (chmod fd #o600)
                  (set! port (fdopen fd "wb"))
                  (put-bytevector port bytes)
                  (force-output port)
                  (fsync fd))
                (lambda ()
                  (if port (close-port port) (close-fdes fd))))))))))

(define (archive-run-logs! scenario root)
  (for-each
   (match-lambda
     ((source . destination)
      (archive-bounded! (string-append root "/" source)
                        (evidence-path scenario destination))))
   '(("console.log" . "console.raw")
     ("qemu.stdout" . "qemu.stdout.raw")
     ("qemu.stderr" . "qemu.stderr.raw")
     ("qemu-img.stdout" . "qemu-img.stdout.raw")
     ("qemu-img.stderr" . "qemu-img.stderr.raw"))))

(define (snapshot-records!)
  (when (and records evidence (lstat-or-false records))
    (let ((destination (string-append evidence "/records")))
      (unless (lstat-or-false destination)
        (mkdir destination #o700)
        (chmod destination #o700))
      (for-each
       (lambda (name)
         (let ((target (string-append destination "/" name)))
           (unless (lstat-or-false target)
             (archive-bounded! (string-append records "/" name) target))))
       (scandir records
                (lambda (name) (not (member name '("." "..")))))))))

(define (make-run-context scenario)
  (let* ((base-fd
          (open-fdes run-base
                     (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
         (base-info (stat base-fd))
         (created
          (mkdtemp
           (string-append (format #f "/proc/self/fd/~a" base-fd)
                          "/book-state-guardian." scenario ".XXXXXX")))
         (root (string-append run-base "/" (basename created)))
         (identity #f)
         (root-guardian #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (same-object? base-info (lstat run-base))
          (fail "run base identity changed during private root creation"))
        (chmod created #o700)
        (set! identity (lstat root))
        (unless (and (eq? (stat:type identity) 'directory)
                     (= (stat:uid identity) (getuid))
                     (= (logand (stat:mode identity) #o7777) #o700))
          (fail "new run root is not caller-owned mode 0700"))
        (set! root-guardian
              ((outer-private 'start-run-root-guardian)
               root identity qemu-term-grace-seconds))
        (let* ((guardian-pid (car root-guardian))
               (guardian-start
                (let loop ((deadline (+ (now) 1.0)))
                  (let ((candidate
                         (and (lstat-or-false
                               (format #f "/proc/~a/stat" guardian-pid))
                              (let ((line
                                     (call-with-input-file
                                         (format #f "/proc/~a/stat" guardian-pid)
                                       read-line)))
                                (let* ((close (string-rindex line #\)))
                                       (tail (and close
                                                  (string-tokenize
                                                   (substring line (+ close 1))))))
                                  (and tail (> (length tail) 19)
                                       (list-ref tail 19)))))))
                    (cond
                     (candidate candidate)
                     ((>= (now) deadline)
                      (fail "root guardian lacked a stable start time"))
                     (else (usleep 10000) (loop deadline)))))))
          (write-exclusive-datum!
           (record-path scenario "root")
           `((schema . 1) (scenario . ,scenario)
             (run-root . ,root)
             (run-root-device . ,(stat:dev identity))
             (run-root-inode . ,(stat:ino identity))
             (qmp-path . ,(string-append root "/qmp.sock"))
             (root-guardian-pid . ,guardian-pid)
             (root-guardian-start-time . ,guardian-start))))
        `((root . ,root)
          (identity . ,identity)
          (guardian . ,root-guardian)
          (environment . ,((outer-private 'supervisor-environment)
                            root exact-qemu))))
      (lambda () (close-fdes base-fd)))))

(define (prepare-overlay! context)
  (let* ((root (assoc-ref context 'root))
         (environment (assoc-ref context 'environment))
         (guardian (assoc-ref context 'guardian))
         (overlay (string-append root "/disk-overlay.qcow2"))
         (result
          ((outer-private 'run-owned-process)
           ((outer-private 'qemu-img-argv) exact-qemu-img exact-baseline overlay)
           environment root
           (string-append root "/qemu-img.stdout")
           (string-append root "/qemu-img.stderr")
           qemu-timeout-seconds qemu-term-grace-seconds
           (cadr guardian))))
    (unless (and (zero? (car result)) (not (cdr result))
                 (let ((info (lstat-or-false overlay)))
                   (and info (eq? (stat:type info) 'regular))))
      (fail "private qemu-img overlay creation failed: ~s" result))
    (chmod overlay #o600)
    overlay))

(define (cleanup-normal-context! scenario context)
  (let* ((root (assoc-ref context 'root))
         (identity (assoc-ref context 'identity))
         (guardian (assoc-ref context 'guardian))
         (archive-error #f))
    (catch #t
      (lambda () (archive-run-logs! scenario root))
      (lambda arguments (set! archive-error arguments)))
    (let ((current (lstat-or-false root)))
      (unless (and current (same-object? current identity))
        (fail "normal run root changed before cleanup: ~a" root))
      ((outer-private 'delete-created-tree) root))
    ((outer-private 'stop-run-root-guardian) guardian #t)
    (when archive-error (apply throw archive-error))))

(define (recorded-identity scenario kind)
  (let ((path (record-path scenario kind)))
    (unless (wait-for-path path 5.0)
      (fail "timed out waiting for ~a ~a record" scenario kind))
    (track! (read-process-identity path))))

(define (assert-finished-context-gone! scenario)
  (let* ((guardian
          (read-process-identity
           (record-path scenario "process-guardian")))
         (child
          (read-process-identity
           (record-path scenario "qemu-child")))
         (root-record (read-datum (record-path scenario "root")))
         (root-guardian
          `((pid . ,(assoc-ref root-record 'root-guardian-pid))
            (start-time . ,(assoc-ref root-record
                                       'root-guardian-start-time)))))
    (unless (and (wait-process-gone child 1.0)
                 (wait-process-gone guardian 1.0)
                 (wait-process-gone root-guardian 1.0)
                 (not (lstat-or-false (assoc-ref root-record 'run-root))))
      (fail "finished context retained a child, guardian, or run root: ~a"
            scenario))))

(define (qemu-exec-record scenario)
  (let ((path (record-path scenario "qemu-exec")))
    (unless (wait-for-path path 5.0)
      (fail "timed out waiting for ~a QEMU exec record" scenario))
    (read-datum path)))

(define (run-positive-owner scenario reference)
  (module-set! %outer-module 'interrupted-signal #f)
  (sigaction SIGCHLD SIG_DFL)
  (for-each
   (lambda (signal-number)
     (sigaction signal-number
                (lambda (received)
                  ((outer-private 'note-disposable-qemu-signal) received))))
   (list SIGINT SIGTERM SIGHUP))
  (let ((context #f)
        (result #f)
        (exit-code 0))
    (catch #t
      (lambda ()
        (set! context (make-run-context scenario))
        (let* ((root (assoc-ref context 'root))
               (run-identity (assoc-ref context 'identity))
               (root-guardian (assoc-ref context 'guardian))
               (environment (assoc-ref context 'environment))
               (overlay #f))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (set! overlay (prepare-overlay! context))
              (call-with-state-volume-lease
               reference
               (lambda (lease)
                 (event! scenario 10 'lease-acquired '())
                 (call-with-state-volume-writer-window
                  lease
                  (lambda (writer)
                    (event! scenario 20 'writer-entered '())
                    (dynamic-wind
                      (lambda () #t)
                      (lambda ()
                        (call-with-state-volume-qemu-handoff
                         writer
                         (lambda (handoff)
                           (event! scenario 30 'handoff-entered '())
                           (let* ((qmp-path (string-append root "/qmp.sock"))
                                  (argv
                                   (paused-state-reader-qemu-arguments
                                    exact-qemu root exact-kernel exact-initrd
                                    ((outer-private 'read-fixed-append) exact-config)
                                    overlay handoff)))
                             (assert-paused-state-reader-qemu-arguments
                              argv exact-qemu root exact-kernel exact-initrd
                              ((outer-private 'read-fixed-append) exact-config)
                              overlay handoff)
                             (write-exclusive-datum!
                              (record-path scenario "argv") argv)
                             (dynamic-wind
                               (lambda () #t)
                               (lambda ()
                                 (set! result
                                       (run-owned-process-with-state-handoff
                                        argv environment root
                                        (string-append root "/qemu.stdout")
                                        (string-append root "/qemu.stderr")
                                        qemu-timeout-seconds
                                        qemu-term-grace-seconds
                                        (cadr root-guardian) handoff
                                        (state-volume-image-identity lease)
                                        root run-identity qmp-path
                                        (record-path scenario "process-guardian")
                                        (record-path scenario "qemu-child")
                                        (record-path scenario "qemu-exec")))
                                 (unless (equal? result '(0 . #f))
                                   (fail "paused reader QEMU returned unexpectedly: ~s"
                                         result)))
                               (lambda ()
                                 (let ((guardian
                                        (and (lstat-or-false
                                              (record-path scenario
                                                           "process-guardian"))
                                             (read-process-identity
                                              (record-path scenario
                                                           "process-guardian"))))
                                       (child
                                        (and (lstat-or-false
                                              (record-path scenario "qemu-child"))
                                             (read-process-identity
                                              (record-path scenario
                                                           "qemu-child")))))
                                   (let ((gone?
                                          (and guardian child
                                               (wait-process-gone guardian 7.0)
                                               (wait-process-gone child 1.0))))
                                     ;; Do not mask a more specific guarded-run
                                     ;; exception while unwinding; a successful
                                     ;; return must nevertheless prove the join.
                                     (when (and result (not gone?))
                                       (fail "guardian returned before exact QEMU group was gone"))
                                     (event! scenario 40 'process-guardian-joined
                                             `((qemu-gone . ,(and gone? #t))
                                               (guardian-gone . ,(and gone? #t))))))))))))
                      (lambda ()
                        (event! scenario 50 'handoff-left '())))))
                 (event! scenario 60 'writer-left '())))
              (event! scenario 70 'lease-left `((result . ,result))))
            (lambda ()
              (cleanup-normal-context! scenario context)
              (event! scenario 80 'run-root-cleaned '())))))
      (lambda (key . arguments)
        (set! exit-code
              (if (eq? key 'book-execution-qemu-signal)
                  (+ 128 (car arguments))
                  1))
        (false-if-exception
         (write-exclusive-datum!
          (record-path scenario "owner-error")
          `((key . ,key) (arguments . ,arguments) (exit-code . ,exit-code))))
        (false-if-exception
         (write-exclusive-datum!
          (evidence-path scenario "owner-error.scm")
          `((key . ,key) (arguments . ,arguments) (exit-code . ,exit-code))))))
    (false-if-exception (snapshot-records!))
    (false-if-exception
     (write-exclusive-datum!
      (record-path scenario "owner-result")
      `((schema . 1) (scenario . ,scenario) (exit-code . ,exit-code)
        (qemu-result . ,result))))
    (false-if-exception
     (write-exclusive-datum!
      (evidence-path scenario "owner-result.scm")
      `((schema . 1) (scenario . ,scenario) (exit-code . ,exit-code)
        (qemu-result . ,result))))
    (primitive-exit exit-code)))

(define (publish-owner-identity-and-run scenario reference)
  ;; This wrapper is entered only in the forked child.
  (let* ((pid (getpid))
         (stat-line
          (call-with-input-file (format #f "/proc/~a/stat" pid) read-line))
         (close (string-rindex stat-line #\)))
         (tail (string-tokenize (substring stat-line (+ close 1))))
         (identity
          `((schema . 1) (role . scenario-owner) (pid . ,pid)
            (start-time . ,(list-ref tail 19)))))
    (write-exclusive-datum! (record-path scenario "owner") identity)
    (run-positive-owner scenario reference)))

(define (spawn-positive-owner scenario reference)
  (force-output)
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (publish-owner-identity-and-run scenario reference)
        (let ((path (record-path scenario "owner")))
          (unless (wait-for-path path 1.0)
            (fail "positive owner did not publish its identity"))
          (let ((identity (read-process-identity path)))
            (unless (= pid (assoc-ref identity 'pid))
              (fail "forked owner PID differs from its identity record"))
            (track! identity)
            identity)))))

(define (wait-owner! identity)
  (let loop ()
    (let ((result
           (catch 'system-error
             (lambda () (waitpid (assoc-ref identity 'pid)))
             (lambda arguments
               (if (= EINTR (system-error-errno arguments))
                   #f
                   (apply throw 'system-error arguments))))))
      (if result
          (begin (untrack! identity) (cdr result))
          (loop)))))

(define (status-exit-code status)
  (or (status:exit-val status)
      (and (status:term-sig status) (+ 128 (status:term-sig status)))))

(define (kill-exact! identity signal-number)
  (unless (process-instance-live? (assoc-ref identity 'pid)
                                  (assoc-ref identity 'start-time))
    (fail "refusing to signal a changed/dead process identity"))
  (kill (assoc-ref identity 'pid) signal-number))

(define (scenario-root-record scenario)
  (let ((path (record-path scenario "root")))
    (unless (wait-for-path path 5.0)
      (fail "scenario ~a did not publish its run root" scenario))
    (read-datum path)))

(define (probe-scenario! scenario state-identity lock-info campaign-info)
  (let* ((root-record (scenario-root-record scenario))
         (root (assoc-ref root-record 'run-root))
         (exec-record (qemu-exec-record scenario))
         (child-record (recorded-identity scenario "qemu-child"))
         (guardian-record (recorded-identity scenario "process-guardian"))
         (argv
          (let ((path (format #f "/proc/~a/cmdline"
                              (assoc-ref exec-record 'pid))))
            ;; qmp-probe independently requires exact equality; reconstruct the
            ;; expected vector from the child record's immutable proc-file by
            ;; reading QEMU's current vector here only as transport is forbidden.
            ;; The expected vector is instead retained by the owner below.
            (read-datum (record-path scenario "argv")))))
    (unless (and (= (assoc-ref exec-record 'pid)
                    (assoc-ref child-record 'pid))
                 (string=? (assoc-ref exec-record 'start-time)
                           (assoc-ref child-record 'start-time))
                 (= (assoc-ref exec-record 'process-group)
                    (assoc-ref exec-record 'pid)))
      (fail "exec-child identity does not match the guardian's direct child"))
    (probe-paused-qemu!
     (assoc-ref root-record 'qmp-path) root exec-record argv state-identity
     lock-info campaign-info (evidence-path scenario "qmp-proc.scm"))
    `((root-record . ,root-record)
      (exec-record . ,exec-record)
      (child-record . ,child-record)
      (guardian-record . ,guardian-record))))

(define (safe-json-path path)
  (unless (and (string? path)
               (not (any (lambda (character)
                           (or (< (char->integer character) #x20)
                               (member character '(#\" #\\ #\,))))
                         (string->list path))))
    (fail "test-owned path is not safe for fixed QEMU JSON"))
  path)

(define (path-contender-argv state-path)
  (list exact-qemu
        "-no-user-config" "-nodefaults" "-M" "virt"
        "-accel" "tcg,thread=multi" "-cpu" "max"
        "-smp" "1" "-m" "128" "-S"
        "-display" "none" "-monitor" "none" "-nic" "none"
        "-blockdev"
        (string-append
         "{\"driver\":\"file\",\"filename\":\""
         (safe-json-path state-path)
         "\",\"node-name\":\"contender-file\","
         "\"read-only\":false,\"locking\":\"on\"}")
        "-blockdev"
        "{\"driver\":\"raw\",\"file\":\"contender-file\",\"node-name\":\"contender-state\",\"read-only\":false}"
        "-device"
        "virtio-blk-pci,drive=contender-state,id=contender-state-disk"))

(define (locking-error? path)
  (let ((text (call-with-input-file path get-string-all)))
    (and (<= (string-length text) max-log-bytes)
         (or (string-contains text "Failed to get \"write\" lock")
             (string-contains text "Failed to get shared \"write\" lock")
             (string-contains text "Is another process using the image")))))

(define (run-path-contender! scenario state-path)
  (let ((context (make-run-context scenario))
        (result #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((root (assoc-ref context 'root))
               (guardian (assoc-ref context 'guardian))
               (environment (assoc-ref context 'environment)))
          (set! result
                ((outer-private 'run-owned-process)
                 (path-contender-argv state-path) environment root
                 (string-append root "/qemu.stdout")
                 (string-append root "/qemu.stderr")
                 contender-timeout-seconds qemu-term-grace-seconds
                 (cadr guardian)
                 #:guardian-observer
                 (make-process-record-observer
                  (record-path scenario "process-guardian")
                  'process-guardian)
                 #:child-observer
                 (make-process-record-observer
                  (record-path scenario "qemu-child")
                  'qemu-direct-child)))
          (unless (and (= (car result) 1) (not (cdr result))
                       (locking-error? (string-append root "/qemu.stderr")))
            (fail "actual QEMU path contender did not fail on locking=on: ~s"
                  result))))
      (lambda () (cleanup-normal-context! scenario context)))
    (assert-finished-context-gone! scenario)
    result))

(define (state-only-contender-argv handoff)
  (let ((file-name (state-volume-qemu-handoff-file-name handoff)))
    (list exact-qemu
          "-no-user-config" "-nodefaults" "-M" "virt"
          "-accel" "tcg,thread=multi" "-cpu" "max"
          "-smp" "1" "-m" "128" "-S"
          "-display" "none" "-monitor" "none" "-nic" "none"
          "-blockdev"
          (string-append
           "{\"driver\":\"file\",\"filename\":\"" file-name
           "\",\"node-name\":\"contender-file\","
           "\"read-only\":false,\"locking\":\"on\"}")
          "-blockdev"
          "{\"driver\":\"raw\",\"file\":\"contender-file\",\"node-name\":\"contender-state\",\"read-only\":false}"
          "-device"
          "virtio-blk-pci,drive=contender-state,id=contender-state-disk")))

(define (run-handoff-contender! scenario lease handoff)
  (let ((context (make-run-context scenario))
        (result #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((root (assoc-ref context 'root))
               (identity (assoc-ref context 'identity))
               (guardian (assoc-ref context 'guardian))
               (environment (assoc-ref context 'environment))
               (qmp-path (string-append root "/qmp.sock")))
          (set! result
                (run-owned-process-with-state-handoff
                 (state-only-contender-argv handoff) environment root
                 (string-append root "/qemu.stdout")
                 (string-append root "/qemu.stderr")
                 contender-timeout-seconds qemu-term-grace-seconds
                 (cadr guardian) handoff (state-volume-image-identity lease)
                 root identity qmp-path
                 (record-path scenario "process-guardian")
                 (record-path scenario "qemu-child")
                 (record-path scenario "qemu-exec")))
          (unless (and (= (car result) 1) (not (cdr result))
                       (locking-error? (string-append root "/qemu.stderr")))
            (fail "actual QEMU inherited-FD contender did not fail locking=on: ~s"
                  result))))
      (lambda () (cleanup-normal-context! scenario context)))
    (assert-finished-context-gone! scenario)
    result))

(define (read-marker path)
  (call-with-input-file path get-string-all))

(define (directory-empty? path)
  (null? (scandir path (lambda (name) (not (member name '("." "..")))))))

(define (cleanup-active-processes!)
  (for-each
   (lambda (identity)
     (when (process-instance-live? (assoc-ref identity 'pid)
                                   (assoc-ref identity 'start-time))
       (false-if-exception (kill (assoc-ref identity 'pid) SIGKILL))))
   active-identities)
  (usleep 200000))

(define (run-campaign!)
  (let* ((state-path (state-volume-image-path campaign-reference))
         (state-identity (state-volume-image-identity campaign-reference))
         (lock-info (lstat (string-append campaign-root "/owner.lock")))
         (campaign-info (lstat campaign-root)))
    (check "state image is one retained 64 MiB regular file"
           (let ((info (lstat state-path)))
             (and (eq? (stat:type info) 'regular)
                  (= (stat:size info) state-volume-size)
                  (= (stat:ino info) (assoc-ref state-identity 'inode)))))

    ;; Normal close plus a concurrently rejected fresh-path QEMU.
    (let* ((owner (spawn-positive-owner "normal" campaign-reference))
           (probe (probe-scenario! "normal" state-identity lock-info campaign-info))
           (root (assoc-ref (assoc-ref probe 'root-record) 'run-root)))
      (check "normal paused QEMU is the exact recorded process"
             (process-instance-live? (assoc-ref (assoc-ref probe 'exec-record) 'pid)
                                     (assoc-ref (assoc-ref probe 'exec-record)
                                                'start-time)))
      (check "fresh-path actual QEMU is refused while the reader QEMU lives"
             (equal? (run-path-contender! "normal-lock-contender" state-path)
                     '(1 . #f)))
      (qmp-quit! (string-append root "/qmp.sock") root
                 (evidence-path "normal" "qmp-quit.scm"))
      (let ((status (wait-owner! owner)))
        (check "normal owner and guarded QEMU exit zero"
               (= (status-exit-code status) 0)))
      (check "normal process guardian was joined before owner completion"
             (wait-process-gone (assoc-ref probe 'guardian-record) 1.0))
      (check "normal QEMU was reaped before owner completion"
             (wait-process-gone (assoc-ref probe 'child-record) 1.0))
      (check "normal run root was identity-safely removed"
             (not (lstat-or-false root)))
      (check "normal ordering records reach cleanup after guardian join"
             (every (lambda (suffix) (lstat-or-false (record-path "normal" suffix)))
                    '("event-40-process-guardian-joined"
                      "event-50-handoff-left" "event-60-writer-left"
                      "event-70-lease-left" "event-80-run-root-cleaned"))))

    ;; Catchable owner TERM: normal dynamic unwinding still joins both guardians.
    (let* ((owner (spawn-positive-owner "owner-term" campaign-reference))
           (probe
            (probe-scenario! "owner-term" state-identity lock-info campaign-info))
           (root-record (assoc-ref probe 'root-record))
           (root (assoc-ref root-record 'run-root))
           (root-guardian
            `((pid . ,(assoc-ref root-record 'root-guardian-pid))
              (start-time . ,(assoc-ref root-record
                                         'root-guardian-start-time)))))
      (kill-exact! owner SIGTERM)
      (let ((status (wait-owner! owner)))
        (check "TERM owner reports signal-derived status 143"
               (= (status-exit-code status) 143)))
      (check "TERM path reaped exact QEMU before lease unwind"
             (and (wait-process-gone (assoc-ref probe 'child-record) 1.0)
                  (lstat-or-false
                   (record-path "owner-term"
                                "event-40-process-guardian-joined"))))
      (check "TERM path joined process guardian"
             (wait-process-gone (assoc-ref probe 'guardian-record) 1.0))
      (check "TERM path joined run-root guardian"
             (wait-process-gone root-guardian 1.0))
      (check "TERM path removed only its exact run root"
             (not (lstat-or-false root)))
      (check "TERM path records handoff unwind before exact root cleanup"
             (every (lambda (suffix)
                      (lstat-or-false (record-path "owner-term" suffix)))
                    '("event-50-handoff-left" "event-80-run-root-cleaned"
                      "owner-result"))))

    ;; Uncatchable owner death: stop QEMU to hold its own image lock across the
    ;; owner.lock release, replace the watched run-root name, and prove both
    ;; independent lock exclusion and conservative root disposition.
    (let* ((owner (spawn-positive-owner "owner-sigkill" campaign-reference))
           (probe
            (probe-scenario! "owner-sigkill" state-identity lock-info
                             campaign-info))
           (root-record (assoc-ref probe 'root-record))
           (root (assoc-ref root-record 'run-root))
           (root-info (lstat root))
           (held (string-append run-base "/held-owner-sigkill"))
           (marker (string-append root "/foreign.marker"))
           (qemu-identity (assoc-ref probe 'child-record))
           (root-guardian
            `((pid . ,(assoc-ref root-record 'root-guardian-pid))
              (start-time . ,(assoc-ref root-record
                                         'root-guardian-start-time)))))
      (kill-exact! qemu-identity SIGSTOP)
      (check "SIGKILL fixture stops only its exact QEMU instance"
             (process-instance-live? (assoc-ref qemu-identity 'pid)
                                     (assoc-ref qemu-identity 'start-time)))
      (rename-file root held)
      (mkdir root #o700)
      (chmod root #o700)
      (write-exclusive-text! marker "foreign-root-preserved\n")
      (let ((replacement-info (lstat root)))
        (check "foreign replacement has a different run-root inode"
               (not (same-object? root-info replacement-info))))
      (kill-exact! owner SIGKILL)
      (let ((status (wait-owner! owner)))
        (check "uncatchable owner death is the exact SIGKILL status"
               (and (status:term-sig status) (= (status:term-sig status) SIGKILL))))
      (check "owner.lock is reacquirable while stopped QEMU remains alive"
             (and (process-instance-live? (assoc-ref qemu-identity 'pid)
                                          (assoc-ref qemu-identity 'start-time))
                  (call-with-state-volume-lease
                   campaign-reference
                   (lambda (lease)
                     (call-with-state-volume-writer-window
                      lease
                      (lambda (writer)
                        (call-with-state-volume-qemu-handoff
                         writer
                         (lambda (handoff)
                           (let ((rejected?
                                  (equal?
                                   (run-handoff-contender!
                                    "sigkill-lock-contender" lease handoff)
                                   '(1 . #f))))
                             (and rejected?
                                  (process-instance-live?
                                   (assoc-ref qemu-identity 'pid)
                                   (assoc-ref qemu-identity
                                              'start-time))))))))))))
      (check "SIGKILL process guardian reaps the stopped actual QEMU boundedly"
             (wait-process-gone qemu-identity 10.0))
      (check "SIGKILL process guardian exits after reaping its QEMU"
             (wait-process-gone (assoc-ref probe 'guardian-record) 2.0))
      (check "SIGKILL run-root guardian exits after identity refusal"
             (wait-process-gone root-guardian 10.0))
      (check "foreign replacement and unknown marker survive guardian refusal"
             (and (lstat-or-false root)
                  (string=? (read-marker marker) "foreign-root-preserved\n")))
      (check "renamed original run-root inode is not confused with replacement"
             (and (lstat-or-false held)
                  (same-object? root-info (lstat held))))
      (archive-run-logs! "owner-sigkill" held)
      (write-exclusive-datum!
       (evidence-path "owner-sigkill" "foreign-root.scm")
       `((replacement-path . ,root)
         (replacement-device . ,(stat:dev (lstat root)))
         (replacement-inode . ,(stat:ino (lstat root)))
         (marker . ,(read-marker marker))
         (held-original-path . ,held)
         (held-original-device . ,(stat:dev (lstat held)))
         (held-original-inode . ,(stat:ino (lstat held)))))
      (remove-owned-tree held)
      (remove-owned-tree root)
      (check "test owner removes both verified roots after evidence retention"
             (and (not (lstat-or-false held)) (not (lstat-or-false root)))))

    ;; A fresh owner and actual reader QEMU can acquire the retained image only
    ;; after the SIGKILL guardian has reaped the old writer.
    (let* ((owner (spawn-positive-owner "post-reap" campaign-reference))
           (probe
            (probe-scenario! "post-reap" state-identity lock-info campaign-info))
           (root (assoc-ref (assoc-ref probe 'root-record) 'run-root)))
      (check "post-reap fresh QEMU opens the same retained state inode"
             (= (assoc-ref (assoc-ref probe 'exec-record) 'state-inode)
                (assoc-ref state-identity 'inode)))
      (qmp-quit! (string-append root "/qmp.sock") root
                 (evidence-path "post-reap" "qmp-quit.scm"))
      (let ((status (wait-owner! owner)))
        (check "post-reap owner and actual QEMU exit zero"
               (= (status-exit-code status) 0)))
      (check "post-reap QEMU and process guardian are gone"
             (and (wait-process-gone (assoc-ref probe 'child-record) 1.0)
                  (wait-process-gone (assoc-ref probe 'guardian-record) 1.0)))
      (check "post-reap run root is absent"
             (not (lstat-or-false root))))

    (call-with-state-volume-lease
     campaign-reference
     (lambda (lease)
       (check "retained state filesystem passes explicit final e2fsck"
              (validate-state-volume-filesystem! lease exact-e2fsck))
       (check "campaign cleanup succeeds only with no writer active"
              (cleanup-state-volume-campaign! lease))))
    (check "campaign root is absent after conservative cleanup"
           (not (lstat-or-false campaign-root)))
    (check "ephemeral run base is empty after every guardian disposition"
           (directory-empty? run-base))
    (check "campaign base is empty after exact campaign cleanup"
           (directory-empty? (string-append work-root "/campaigns")))
    (check "all tracked owner/QEMU/guardian process instances are gone"
           (every (lambda (identity)
                    (not (process-instance-live?
                          (assoc-ref identity 'pid)
                          (assoc-ref identity 'start-time))))
                  active-identities))))

(define (main arguments)
  (unless (= (length arguments) 2)
    (format (current-error-port)
            "usage: ~a PRIVATE-EMPTY-EVIDENCE-DIRECTORY~%" (car arguments))
    (exit 2))
  (when (zero? (getuid))
    (fail "root execution is forbidden"))
  (umask #o077)
  (set! evidence (require-private-empty-directory (cadr arguments)))
  (set! work-root (mkdtemp "/tmp/opencode/book-state-guardian-run.XXXXXX"))
  (chmod work-root #o700)
  (set! work-root-identity (lstat work-root))
  (set! run-base (string-append work-root "/runs"))
  (set! records (string-append work-root "/records"))
  (let ((campaign-base (string-append work-root "/campaigns")))
    (for-each (lambda (path) (mkdir path #o700) (chmod path #o700))
              (list campaign-base run-base records))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (validate-fixed-inputs!)
        (check "all exact immutable runtime inputs match SHA-256" #t)
        (check "historical kernel path explicitly selects AArch64 QEMU"
               (and (string-suffix? "/qemu-system-aarch64" exact-qemu)
                    (string=? (hash-file exact-kernel)
                              "f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223")))
        (call-with-new-state-volume-lease
         campaign-base run-base exact-mke2fs exact-e2fsck
         (lambda (lease)
           (set! campaign-reference (state-volume-reference lease))
           (set! campaign-root (state-volume-campaign-root lease))))
        (check "fresh state volume lease returns one retained campaign"
               (and campaign-reference (lstat-or-false campaign-root)))
        (run-campaign!)
        (check "finite check plan executed exactly"
               (= (+ checks 1) expected-check-count))
        (snapshot-records!)
        (write-exclusive-datum!
         (string-append evidence "/RESULT.scm")
         `((schema . 1)
           (verdict . pass)
           (checks . ,checks)
           (scope . paused-host-qemu-fd-lock-guardian-only)
           (guest-instructions-executed . #f)
           (semantic-persistence . unproven)))
        (format #t "PASS: ~a/~a finite guardian-integration checks~%"
                checks expected-check-count))
      (lambda ()
        (cleanup-active-processes!)
        (false-if-exception (snapshot-records!))
        (when (and campaign-reference campaign-root
                   (lstat-or-false campaign-root))
          (false-if-exception
           (call-with-state-volume-lease
            campaign-reference
            (lambda (lease) (cleanup-state-volume-campaign! lease)))))
        (when (and work-root work-root-identity
                   (let ((current (lstat-or-false work-root)))
                     (and current (same-object? current work-root-identity))))
          (false-if-exception (remove-owned-tree work-root))))))
  (unless (= checks expected-check-count)
    (fail "finite check count mismatch: ~a instead of ~a"
          checks expected-check-count))
  0)

(exit
 (catch #t
   (lambda () (main (command-line)))
   (lambda (key . arguments)
     (if (eq? key 'quit)
         (apply throw key arguments)
         (begin
           (cleanup-active-processes!)
           (format (current-error-port) "FAIL: ~s ~s~%" key arguments)
           (force-output (current-error-port))
           1)))))
