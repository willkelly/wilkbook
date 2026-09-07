(use-modules (book-state-qemu qemu-graph)
             (book-state-qemu state-volume)
             (guix build syscalls)
             (ice-9 ftw)
             (ice-9 threads)
             (srfi srfi-1)
             (srfi srfi-64)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 3)
  (format (current-error-port)
          "usage: guile -L DIR test-book-state-qemu-v3.scm MKE2FS E2FSCK~%")
  (exit 2))
(define mke2fs (cadr arguments))
(define e2fsck (caddr arguments))

(define (volume-error-code thunk)
  (catch 'book-state-qemu-volume-error
    (lambda () (thunk) #f)
    (lambda (_ code _message) code)))

(define (graph-error? thunk)
  (catch 'book-state-qemu-graph-error
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (wait-exit-code pid)
  (let ((status (cdr (waitpid pid))))
    (or (status:exit-val status)
        (and (status:term-sig status)
             (+ 128 (status:term-sig status))))))

(define (remove-test-tree path)
  (let ((info (false-if-exception (lstat path))))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name) (remove-test-tree (string-append path "/" name)))
             (scandir path (lambda (name) (not (member name '("." ".."))))))
            (rmdir path))
          (delete-file path)))))

(define (fork-with-registry-mutex-held reference)
  (let* ((registry-mutex
          (@@ (book-state-qemu state-volume) process-lease-registry-mutex))
         (gate (make-mutex))
         (condition (make-condition-variable))
         (holder-ready? #f)
         (release-holder? #f)
         (holder
          (call-with-new-thread
           (lambda ()
             (lock-mutex registry-mutex)
             (lock-mutex gate)
             (set! holder-ready? #t)
             (broadcast-condition-variable condition)
             (let wait ()
               (unless release-holder?
                 (wait-condition-variable condition gate)
                 (wait)))
             (unlock-mutex gate)
             (unlock-mutex registry-mutex))))
         (pipe-pair (pipe O_CLOEXEC))
         (input (car pipe-pair))
         (output (cdr pipe-pair)))
    (lock-mutex gate)
    (let wait ()
      (unless holder-ready?
        (wait-condition-variable condition gate)
        (wait)))
    (unlock-mutex gate)
    (force-output)
    (let ((pid (primitive-fork)))
      (if (zero? pid)
          (begin
            (close-port input)
            (let* ((entered? #f)
                   (code
                    (volume-error-code
                     (lambda ()
                       (call-with-state-volume-lease
                        reference (lambda (_) (set! entered? #t)))))))
              (write-char
               (cond (entered? #\V)
                     ((eq? code 'already-leased) #\A)
                     (else #\X))
               output)
              (force-output output)
              (primitive-exit 0)))
          (begin
            (close-port output)
            (let* ((selected (select (list input) '() '() 0 500000))
                   (bounded? (not (null? (car selected))))
                   (answer (and bounded? (read-char input))))
              (unless bounded? (kill pid SIGKILL))
              (let ((status (wait-exit-code pid)))
                (lock-mutex gate)
                (set! release-holder? #t)
                (broadcast-condition-variable condition)
                (unlock-mutex gate)
                (join-thread holder)
                (close-port input)
                (list bounded? answer status))))))))

(define (normal-child-lease-code reference)
  (force-output)
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (primitive-exit
         (if (eq? (volume-error-code
                   (lambda ()
                     (call-with-state-volume-lease reference (lambda (_) #t))))
                  'already-leased)
             0 1))
        (wait-exit-code pid))))

(define qemu
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-qemu/bin/qemu-system-aarch64")
(define reader-root "/tmp/opencode/book-state-reader-v3.123456")
(define kernel (string-append reader-root "/boot/Image"))
(define initrd (string-append reader-root "/boot/initrd.cpio.gz"))
(define overlay (string-append reader-root "/disk-overlay.qcow2"))
(define append-line "root=PNGuixRoot console=ttyAMA0")

(define (graph handoff)
  (leased-state-volume-qemu-arguments
   qemu reader-root kernel initrd append-line overlay handoff))

(define (assert-graph candidate handoff)
  (assert-leased-state-volume-qemu-arguments
   candidate qemu reader-root kernel initrd append-line overlay handoff))

(define (malform-first-blockdev candidate)
  (let loop ((rest candidate) (changed? #f) (result '()))
    (cond
     ((null? rest) (reverse result))
     ((and (not changed?)
           (string? (car rest))
           (string-prefix? "{\"driver\":\"file\"" (car rest)))
      (let ((value (car rest)))
        (loop (cdr rest) #t
              (cons (string-append
                     (substring value 0 (- (string-length value) 1)) ",}")
                    result))))
     (else (loop (cdr rest) changed? (cons (car rest) result))))))

(define top (mkdtemp "/tmp/opencode/book-state-qemu-v3-test.XXXXXX"))
(chmod top #o700)
(define top-identity (lstat top))
(define campaign-base (string-append top "/campaigns"))
(define run-base (string-append top "/runs"))
(mkdir campaign-base #o700)
(mkdir run-base #o700)

(dynamic-wind
  (lambda () #t)
  (lambda ()
    (test-begin "book-state-qemu-v3")

    (let ((validate
           (@@ (book-state-qemu qemu-graph) validate-no-state-collisions))
          (parse
           (@@ (book-state-qemu qemu-graph) parse-flat-json-object)))
      (test-equal "empty JSON object remains valid" '() (parse "{}"))
      (test-equal "empty JSON key is parsed as valid JSON"
        '(("" . "value")) (parse "{\"\":\"value\"}"))
      (test-equal "ordinary Unicode escape remains valid and decoded"
        '(("node-name" . "safe-node"))
        (parse "{ \"node-name\" : \"safe\\u002dnode\" }"))
      (test-assert "valid alternate whitespace remains accepted"
        (validate
         '("-blockdev"
           "{ \"driver\" : \"null-co\", \"node-name\" : \"safe-node\" }")))
      (for-each
       (lambda (text label)
         (test-assert label
           (graph-error? (lambda () (validate (list "-blockdev" text))))))
       '("{\"node-name\":\"safe\",}"
         "{\"node-name\":\"book-state\",}"
         "{,\"node-name\":\"safe\"}"
         "{\"node-name\":\"safe\",,\"driver\":\"raw\"}"
         "{\"node-name\":\"safe\",   }")
       '("ordinary trailing comma is rejected"
         "reserved-node payload with trailing comma is rejected as malformed"
         "leading comma is rejected"
         "doubled comma is rejected"
         "whitespace before a trailing terminator remains rejected")))

    (call-with-new-state-volume-lease
     campaign-base run-base mke2fs e2fsck
     (lambda (lease)
       (let ((reference (state-volume-reference lease)))
         ;; Finish every ordinary child process before the deliberate
         ;; multithreaded-fork regression below.  Nothing after that regression
         ;; starts another child in this focused test.
         (test-assert "v3 campaign passes explicit e2fsck"
           (validate-state-volume-filesystem! lease e2fsck))
         (test-equal "fresh child observes the parent's kernel lease"
           0 (normal-child-lease-code reference))
         (let ((fork-result (fork-with-registry-mutex-held reference)))
           (test-assert
               "child ignores locked retired mutex and resets atomic registry"
             (and (car fork-result)
                  (char? (cadr fork-result))
                  (char=? (cadr fork-result) #\A)
                  (zero? (caddr fork-result)))))
         (test-equal "parent registry claim remains live after child reset"
           'already-leased
           (volume-error-code
            (lambda ()
              (call-with-state-volume-lease reference (lambda (_) #t)))))

         (let ((old-writer #f)
               (old-handoff #f)
               (old-name #f))
           (call-with-state-volume-writer-window
            lease
            (lambda (writer)
              (set! old-writer writer)
              (let* ((module (resolve-module '(book-state-qemu state-volume)))
                     (syscall-variable
                      (module-variable module 'kcmp-syscall-number))
                     (syscall-number (variable-ref syscall-variable))
                     (callback-entered? #f))
                (dynamic-wind
                  (lambda () (variable-set! syscall-variable #f))
                  (lambda ()
                    (test-equal "unsupported KCMP_FILE fails closed"
                      'ofd-comparison-unavailable
                      (volume-error-code
                       (lambda ()
                         (call-with-state-volume-qemu-handoff
                          writer
                          (lambda (_) (set! callback-entered? #t))))))
                    (test-assert "unsupported comparison exposes no handoff callback"
                      (not callback-entered?)))
                  (lambda () (variable-set! syscall-variable syscall-number))))

              (call-with-state-volume-qemu-handoff
               writer
               (lambda (handoff)
                 (set! old-handoff handoff)
                 (set! old-name
                       (state-volume-qemu-handoff-file-name handoff))
                 (let* ((prefix "/proc/self/fd/")
                        (fd
                         (string->number
                          (substring old-name (string-length prefix))))
                        (writer-fd
                         ((@@ (book-state-qemu state-volume) writer-image-fd)
                          writer))
                        (same-ofd?
                         (@@ (book-state-qemu state-volume)
                             same-open-file-description?))
                        (candidate (graph handoff))
                        (saved-dup (dup fd)))
                   (dynamic-wind
                     (lambda ()
                       ;; This test-owned duplicate must not become another
                       ;; inheritable candidate for a future QEMU allowlist.
                       (fcntl saved-dup F_SETFD FD_CLOEXEC))
                     (lambda ()
                       (test-assert "fresh handoff graph and checker succeed"
                         (assert-graph candidate handoff))
                       (test-assert "private writer anchor remains CLOEXEC"
                         (not (zero? (logand (fcntl writer-fd F_GETFD)
                                             FD_CLOEXEC))))
                       (test-assert "handoff is the only intended inheritable copy"
                         (and (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
                              (not (zero? (logand (fcntl saved-dup F_GETFD)
                                                  FD_CLOEXEC)))))
                       (test-assert "KCMP_FILE classifies dup as the same OFD"
                         (and (same-ofd? writer-fd fd)
                              (same-ofd? writer-fd saved-dup)))

                       (let ((fresh
                              (open-fdes (state-volume-image-path lease)
                                         (logior O_RDWR O_NOFOLLOW O_CLOEXEC))))
                         (test-assert
                             "KCMP_FILE distinguishes a fresh same-inode open"
                           (not (same-ofd? writer-fd fresh)))
                         (close-fdes fresh))

                       (let ((null-fd (open-fdes "/dev/null" O_RDONLY)))
                         (dup2 null-fd fd)
                         (unless (= null-fd fd) (close-fdes null-fd)))
                       (test-equal "foreign-inode descriptor rebound rejects"
                         'invalid-handoff
                         (volume-error-code (lambda () (graph handoff))))
                       (dup2 saved-dup fd)
                       (test-assert "restoring a dup of the exact OFD succeeds"
                         (assert-graph (graph handoff) handoff))

                       (close-fdes fd)
                       (let ((fresh
                              (open-fdes (state-volume-image-path lease)
                                         (logior O_RDWR O_NOFOLLOW))))
                         (unless (= fresh fd)
                           (dup2 fresh fd)
                           (close-fdes fresh)))
                       (test-assert
                           "fresh same-inode open reuses the public handoff slot"
                         (= (stat:ino (stat fd)) (stat:ino (stat writer-fd))))
                       (test-equal
                           "same-inode fresh-OFD descriptor rebound rejects"
                         'invalid-handoff
                         (volume-error-code (lambda () (graph handoff))))
                       (dup2 saved-dup fd)
                       (test-assert "exact dup authority can be restored in scope"
                         (assert-graph (graph handoff) handoff))

                       (close-fdes fd)
                       (test-equal "closed live handoff descriptor rejects"
                         'invalid-handoff
                         (volume-error-code (lambda () (graph handoff))))
                       (dup2 saved-dup fd)
                       (test-assert "restored live handoff closes normally"
                         (assert-graph (graph handoff) handoff))
                       (test-assert "malformed candidate cannot pass checker"
                         (graph-error?
                          (lambda ()
                            (assert-graph
                             (malform-first-blockdev candidate) handoff)))))
                     (lambda () (close-fdes saved-dup))))))))

              (test-equal "handoff token is revoked at scope return"
                'invalid-handoff
                (volume-error-code (lambda () (graph old-handoff))))
              (test-assert "handoff descriptor closes at scope return"
                (not (false-if-exception (stat old-name))))

           (test-equal "writer token is revoked at writer-window return"
             'invalid-writer
             (volume-error-code
              (lambda ()
                (call-with-state-volume-qemu-handoff
                 old-writer (lambda (_) #t)))))
           (test-equal "handoff stays revoked outside writer window"
             'invalid-handoff
             (volume-error-code (lambda () (graph old-handoff))))))

         (test-assert "v3 campaign cleans normally"
           (cleanup-state-volume-campaign! lease))))

    (test-assert "v3 campaign and run bases are empty"
      (and (null? (scandir campaign-base
                           (lambda (name) (not (member name '("." ".."))))))
           (null? (scandir run-base
                           (lambda (name) (not (member name '("." ".."))))))))
    (test-assert "KCMP_FILE constants match one reviewed Linux host ABI"
      (member
       (list (utsname:machine (uname))
             (@@ (book-state-qemu state-volume) kcmp-syscall-number)
             (@@ (book-state-qemu state-volume) kcmp-file))
       '(("x86_64" 312 0) ("aarch64" 272 0))))

    (test-end "book-state-qemu-v3"))
  (lambda ()
    (when (and (false-if-exception (lstat top))
               (= (stat:dev top-identity) (stat:dev (lstat top)))
               (= (stat:ino top-identity) (stat:ino (lstat top)))
               (string-prefix? "/tmp/opencode/book-state-qemu-v3-test." top))
      (remove-test-tree top))))
