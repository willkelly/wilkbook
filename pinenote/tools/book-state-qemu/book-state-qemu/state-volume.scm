;;; Private persistent ext4 image ownership for the two-boot Book State test.
(define-module (book-state-qemu state-volume)
  #:use-module (guix build syscalls)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:export (state-volume-label
            state-volume-size
            state-volume-image-name
            state-volume-mount-point
            state-volume-database-path
            state-volume-mount-options
            state-volume-mount-contract
            state-volume-reference?
            state-volume-lease?
            state-volume-writer?
            state-volume-qemu-handoff?
            state-volume-reference
            state-volume-campaign-root
            state-volume-run-base
            state-volume-image-path
            state-volume-image-identity
            state-volume-writer-active?
            call-with-new-state-volume-lease
            call-with-state-volume-lease
            call-with-state-volume-writer-window
            call-with-state-volume-qemu-handoff
            state-volume-qemu-handoff-file-name
            validate-state-volume-filesystem!
            cleanup-state-volume-campaign!))

(define state-volume-label "WBBookStateV1")
(define state-volume-size (* 64 1024 1024))
(define state-volume-image-name "book-state.ext4")
(define state-volume-mount-point "/var/lib/wilkbook-book-state-demo")
(define state-volume-database-path
  (string-append state-volume-mount-point "/book-state-v1.sqlite"))
(define state-volume-mount-options "noatime,nodev,nosuid,noexec")

;; This value is deliberately data, not a Guix file-system declaration.  The
;; future non-shipping system module must translate it literally and require
;; file-system-/var/lib/wilkbook-book-state-demo before starting trusted Guile.
(define state-volume-mount-contract
  `((label . ,state-volume-label)
    (mount-point . ,state-volume-mount-point)
    (type . "ext4")
    (options . ,state-volume-mount-options)
    (mount-may-fail? . #f)
    (database-path . ,state-volume-database-path)
    (owner . trusted-guest-guile)
    (sandbox-visible? . #f)))

(define approved-root "/tmp/opencode")
(define campaign-prefix "book-state-campaign.")
(define lock-name "owner.lock")
(define mke2fs-config-name "mke2fs.conf")
(define quarantine-prefix "book-state-quarantine.")
(define quarantine-held-name "held-campaign")
(define RENAME_EXCHANGE 2)

(define libc (dynamic-link))
(define c-renameat2
  (pointer->procedure int (dynamic-func "renameat2" libc)
                      (list int '* int '* unsigned-int)
                      #:return-errno? #t))
(define c-syscall
  (pointer->procedure long (dynamic-func "syscall" libc)
                      (list long long long long unsigned-long unsigned-long)
                      #:return-errno? #t))

;; Linux UAPI constants verified against the matching architecture headers.
;; Keep this finite: an unknown host must fail closed rather than silently
;; treating inode equality as open-file-description equality.
(define kcmp-file 0)
(define kcmp-syscall-number
  (match (utsname:machine (uname))
    ("x86_64" 312)
    ("aarch64" 272)
    (_ #f)))

;; A private deterministic test seam.  Production leaves this as a no-op.
;; The focused test uses it to substitute a same-name image after validation
;; and before the no-overwrite exchange, proving rollback preserves its bytes.
(define cleanup-before-quarantine-hook (make-parameter (lambda () #t)))
;; Retained only as the frozen adversarial probe's private fork baton.  Registry
;; authority no longer acquires this (or any) mutex.
(define process-lease-registry-mutex (make-mutex))
(define process-lease-registry-state
  (make-atomic-box (cons (getpid) '())))

(define-record-type <file-identity>
  (make-file-identity device inode uid mode links size type)
  file-identity?
  (device identity-device)
  (inode identity-inode)
  (uid identity-uid)
  (mode identity-mode)
  (links identity-links)
  (size identity-size)
  (type identity-type))

(define-record-type <state-volume-reference>
  (%make-state-volume-reference campaign-base campaign-base-identity
                                run-base run-base-identity
                                campaign-root root-identity
                                lock-identity image-identity)
  state-volume-reference?
  (campaign-base reference-campaign-base)
  (campaign-base-identity reference-campaign-base-identity)
  (run-base reference-run-base)
  (run-base-identity reference-run-base-identity)
  (campaign-root reference-campaign-root)
  (root-identity reference-root-identity)
  (lock-identity reference-lock-identity)
  (image-identity reference-image-identity))

(define-record-type <state-volume-lease>
  (%make-state-volume-lease reference lock-port active? operation cleaned? mutex)
  state-volume-lease?
  (reference lease-reference)
  (lock-port lease-lock-port)
  (active? lease-active? set-lease-active!)
  (operation lease-operation set-lease-operation!)
  (cleaned? lease-cleaned? set-lease-cleaned!)
  (mutex lease-mutex))

(define-record-type <state-volume-writer>
  (%make-state-volume-writer lease operation owner image-fd active?
                             handoff-active?)
  state-volume-writer?
  (lease writer-lease)
  (operation writer-operation)
  (owner writer-owner)
  (image-fd writer-image-fd)
  (active? writer-active? set-writer-active!)
  (handoff-active? writer-handoff-active? set-writer-handoff-active!))

(define-record-type <state-volume-qemu-handoff>
  (%make-state-volume-qemu-handoff writer fd active?)
  state-volume-qemu-handoff?
  (writer handoff-writer)
  (fd handoff-fd)
  (active? handoff-active? set-handoff-active!))

(define (volume-error code message . arguments)
  (throw 'book-state-qemu-volume-error code (apply format #f message arguments)))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (capture-identity info)
  (make-file-identity (stat:dev info)
                      (stat:ino info)
                      (stat:uid info)
                      (logand (stat:mode info) #o7777)
                      (stat:nlink info)
                      (stat:size info)
                      (stat:type info)))

(define (same-object-metadata? expected info)
  (and (= (identity-device expected) (stat:dev info))
       (= (identity-inode expected) (stat:ino info))
       (= (identity-uid expected) (stat:uid info))
       (= (identity-mode expected) (logand (stat:mode info) #o7777))
       (eq? (identity-type expected) (stat:type info))))

(define (same-identity? expected info)
  (and (same-object-metadata? expected info)
       (= (identity-links expected) (stat:nlink info))
       (= (identity-size expected) (stat:size info))))

(define (same-object? first second)
  (and (= (stat:dev first) (stat:dev second))
       (= (stat:ino first) (stat:ino second))))

(define (safe-absolute-path? value)
  (and (string? value)
       (string-prefix? "/" value)
       (not (any (lambda (character)
                   (< (char->integer character) #x20))
                 (string->list value)))))

(define (under-approved-root? path)
  (string-prefix? (string-append approved-root "/") path))

(define (canonical-existing path label)
  (unless (safe-absolute-path? path)
    (volume-error 'invalid-path "~a must be an absolute path without controls" label))
  (let ((canonical
         (catch 'system-error
           (lambda () (canonicalize-path path))
           (lambda _
             (volume-error 'invalid-path "~a does not resolve: ~a" label path)))))
    (unless (string=? canonical path)
      (volume-error 'invalid-path "~a must contain no symlink or alias: ~a"
                    label path))
    canonical))

(define (require-private-base path label)
  (let* ((canonical (canonical-existing path label))
         (info (lstat canonical)))
    (unless (under-approved-root? canonical)
      (volume-error 'invalid-base "~a must be below ~a" label approved-root))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (volume-error 'invalid-base
                    "~a must be a caller-owned real mode-0700 directory: ~a"
                    label canonical))
    (values canonical (capture-identity info))))

(define (path-contains? parent child)
  (string-prefix? (string-append parent "/") child))

(define (require-separate-bases campaign-base run-base)
  (when (or (string=? campaign-base run-base)
            (path-contains? campaign-base run-base)
            (path-contains? run-base campaign-base))
    (volume-error 'overlapping-bases
                  "campaign and ephemeral-run bases must be separate siblings")))

(define (require-executable path label)
  (let* ((canonical (canonical-existing path label))
         (info (lstat canonical)))
    (unless (and (eq? (stat:type info) 'regular)
                 (access? canonical X_OK))
      (volume-error 'invalid-tool "~a is not an executable regular file: ~a"
                    label canonical))
    canonical))

(define (require-reference value)
  (unless (state-volume-reference? value)
    (volume-error 'invalid-reference "not a state-volume reference"))
  value)

(define (require-live-lease lease)
  (unless (and (state-volume-lease? lease)
               (lease-active? lease)
               (not (lease-cleaned? lease)))
    (volume-error 'invalid-lease "state-volume lease is not live"))
  lease)

(define (call-with-lease-mutex lease proc)
  (let ((mutex (lease-mutex lease)))
    (lock-mutex mutex)
    (dynamic-wind
      (lambda () #t)
      proc
      (lambda () (unlock-mutex mutex)))))

(define (claim-lease-operation! lease operation conflict-code)
  (call-with-lease-mutex
   lease
   (lambda ()
     (unless (and (lease-active? lease) (not (lease-cleaned? lease)))
       (volume-error 'invalid-lease "state-volume lease is not live"))
     (unless (eq? (lease-operation lease) 'idle)
       (volume-error conflict-code "state-volume operation is already active"))
     (set-lease-operation! lease operation))))

(define (release-lease-operation! lease operation)
  (call-with-lease-mutex
   lease
   (lambda ()
     (when (eq? (lease-operation lease) operation)
       (set-lease-operation! lease 'idle)))))

(define (state-volume-writer-active? lease)
  (unless (state-volume-lease? lease)
    (volume-error 'invalid-lease "not a state-volume lease"))
  (call-with-lease-mutex
   lease
   (lambda ()
     (let ((operation (lease-operation lease)))
       (and (pair? operation) (eq? (car operation) 'writer))))))

(define (creation-system-call label proc)
  (catch 'system-error
    proc
    (lambda arguments
      (volume-error 'creation-failed "~a failed: ~a"
                    label
                    (strerror (system-error-errno arguments))))))

(define (set-new-regular-file-mode! fd mode label)
  (creation-system-call
   (string-append "setting " label " mode")
   (lambda () (chmod fd mode)))
  (let ((info (stat fd)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (= (logand (stat:mode info) #o7777) mode))
      (volume-error 'creation-failed
                    "new ~a is not caller-owned mode ~4,'0o single-link regular file"
                    label mode))))

(define (state-volume-reference lease)
  (lease-reference (require-live-lease lease)))

(define (state-volume-campaign-root value)
  (reference-campaign-root
   (if (state-volume-reference? value)
       value
       (lease-reference (require-live-lease value)))))

(define (state-volume-run-base value)
  (reference-run-base
   (if (state-volume-reference? value)
       value
       (lease-reference (require-live-lease value)))))

(define (state-volume-image-path value)
  (string-append (state-volume-campaign-root value)
                 "/" state-volume-image-name))

(define (state-volume-image-identity value)
  (let* ((reference (if (state-volume-reference? value)
                        value
                        (lease-reference (require-live-lease value))))
         (identity (reference-image-identity reference)))
    ;; Return inert scalar data, never the mutable private record.
    `((device . ,(identity-device identity))
      (inode . ,(identity-inode identity))
      (size . ,(identity-size identity))
      (uid . ,(identity-uid identity))
      (mode . ,(identity-mode identity))
      (links . ,(identity-links identity)))))

(define (validate-state-volume-writer! writer)
  (unless (state-volume-writer? writer)
    (volume-error 'invalid-writer "not a state-volume writer token"))
  (let* ((lease (writer-lease writer))
         (reference (lease-reference lease))
         (expected (reference-image-identity reference)))
    (call-with-lease-mutex
     lease
     (lambda ()
       (unless (and (lease-active? lease)
                    (not (lease-cleaned? lease))
                    (writer-active? writer)
                    (eq? (lease-operation lease) (writer-operation writer))
                    (eq? (current-thread) (writer-owner writer)))
         (volume-error 'invalid-writer
                       "writer token is expired or belongs to another thread"))))
    (let ((handle-info
           (catch 'system-error
             (lambda () (stat (writer-image-fd writer)))
             (lambda _
               (volume-error 'invalid-writer "writer image handle is closed")))))
      (unless (same-identity? expected handle-info)
        (volume-error 'identity-changed "writer image handle identity changed")))
    ;; This catches substitutions made before graph minting.  Later QEMU opens
    ;; the inherited /proc/self/fd handle, not this mutable pathname.
    (validate-reference! reference)
    writer))

(define (same-open-file-description? first-fd second-fd)
  (unless kcmp-syscall-number
    (volume-error 'ofd-comparison-unavailable
                  "KCMP_FILE is unsupported on host architecture ~a"
                  (utsname:machine (uname))))
  (call-with-values
      (lambda ()
        (c-syscall kcmp-syscall-number
                   (getpid) (getpid) kcmp-file first-fd second-fd))
    (lambda (result errno)
      (cond
       ((zero? result) #t)
       ((positive? result) #f)
       (else
        (volume-error 'ofd-comparison-unavailable
                      "KCMP_FILE comparison failed: ~a" (strerror errno)))))))

(define (validate-state-volume-handoff! handoff)
  (unless (and (state-volume-qemu-handoff? handoff)
               (handoff-active? handoff))
    (volume-error 'invalid-handoff "QEMU handoff token is not active"))
  (let* ((writer (validate-state-volume-writer! (handoff-writer handoff)))
         (reference (lease-reference (writer-lease writer)))
         (expected (reference-image-identity reference))
         (info
          (catch 'system-error
            (lambda () (stat (handoff-fd handoff)))
            (lambda _
              (volume-error 'invalid-handoff "QEMU handoff descriptor is closed")))))
    (unless (and (same-identity? expected info)
                 (zero? (logand (fcntl (handoff-fd handoff) F_GETFD)
                                FD_CLOEXEC))
                 (same-open-file-description? (writer-image-fd writer)
                                              (handoff-fd handoff)))
      (volume-error 'invalid-handoff
                    "QEMU handoff descriptor is not the exact inheritable duplicate"))
    handoff))

(define (state-volume-qemu-handoff-file-name handoff)
  (validate-state-volume-handoff! handoff)
  (format #f "/proc/self/fd/~a" (handoff-fd handoff)))

(define (expected-inventory)
  (sort (list lock-name state-volume-image-name) string<?))

(define (actual-inventory root)
  (sort (scandir root (lambda (name) (not (member name '("." "..")))))
        string<?))

(define (require-base-identity path expected label)
  (let ((info (lstat-or-false path)))
    (unless (and info
                 (eq? (stat:type info) 'directory)
                 ;; Directory size and link count legitimately change as this
                 ;; owner creates/removes children.  The stable guard is the
                 ;; directory object plus owner, exact mode, and type.
                 (same-object-metadata? expected info)
                 (string=? path (canonicalize-path path)))
      (volume-error 'identity-changed "~a identity changed: ~a" label path))))

(define (validate-campaign-root! reference root)
  (let* ((root root)
         (root-info (lstat-or-false root)))
    (unless (and root-info
                 (eq? (stat:type root-info) 'directory)
                 (same-object-metadata? (reference-root-identity reference)
                                        root-info)
                 (string=? root (canonicalize-path root)))
      (volume-error 'identity-changed "campaign root identity changed: ~a" root))
    (unless (equal? (actual-inventory root) (expected-inventory))
      (volume-error 'unexpected-entry
                    "campaign root inventory is not exactly owner.lock plus the state image"))
    (let* ((lock-path (string-append root "/" lock-name))
           (image-path (string-append root "/" state-volume-image-name))
           (lock-info (lstat-or-false lock-path))
           (image-info (lstat-or-false image-path)))
      (unless (and lock-info
                   (eq? (stat:type lock-info) 'regular)
                   (same-identity? (reference-lock-identity reference) lock-info))
        (volume-error 'identity-changed "owner lock identity changed"))
      (unless (and image-info
                   (eq? (stat:type image-info) 'regular)
                   (same-identity? (reference-image-identity reference) image-info)
                   (= (stat:size image-info) state-volume-size))
        (volume-error 'identity-changed "state image identity changed")))
  #t))

(define (validate-reference! reference)
  (require-reference reference)
  (require-base-identity (reference-campaign-base reference)
                         (reference-campaign-base-identity reference)
                         "campaign base")
  (require-base-identity (reference-run-base reference)
                         (reference-run-base-identity reference)
                         "ephemeral-run base")
  (unless (string-prefix? campaign-prefix
                          (basename (reference-campaign-root reference)))
    (volume-error 'identity-changed "campaign root name changed"))
  (validate-campaign-root! reference (reference-campaign-root reference)))

(define (open-exact-lock reference)
  (validate-reference! reference)
  (let* ((path (string-append (reference-campaign-root reference) "/" lock-name))
         (fd (open-fdes path (logior O_RDWR O_NOFOLLOW O_CLOEXEC)))
         (info (stat fd)))
    (unless (same-identity? (reference-lock-identity reference) info)
      (close-fdes fd)
      (volume-error 'identity-changed "owner lock changed while opening"))
    (catch 'flock-error
      (lambda ()
        (fcntl-flock fd 'write-lock #:wait? #f)
        ;; Lock first, then repeat every path and identity check.  The lock file
        ;; contains no PID; kernel lock ownership is the only lease authority.
        (validate-reference! reference)
        (validate-ext4-header!
         (string-append (reference-campaign-root reference)
                        "/" state-volume-image-name)
         (reference-image-identity reference))
        fd)
      (lambda arguments
        (close-fdes fd)
        (volume-error 'already-leased "state-volume campaign is already leased")))))

(define (unlock-and-close fd)
  (when (and (integer? fd) (>= fd 0))
    (false-if-exception (fcntl-flock fd 'unlock))
    (false-if-exception (close-fdes fd))))

(define (reference-lock-key reference)
  (let ((identity (reference-lock-identity reference)))
    (cons (identity-device identity) (identity-inode identity))))

(define (current-process-lease-registry-state)
  ;; The atomic box has no inherited owner that can vanish at fork.  A child
  ;; replaces its private PID-mismatched snapshot before considering any key;
  ;; the parent's address space and kernel lease remain unchanged.
  (let loop ()
    (let* ((old (atomic-box-ref process-lease-registry-state))
           (pid (getpid)))
      (if (= (car old) pid)
          old
          (let ((new (cons pid '())))
            (if (eq? (atomic-box-compare-and-swap!
                      process-lease-registry-state old new)
                     old)
                new
                (loop)))))))

(define (claim-process-lease! reference)
  (let ((key (reference-lock-key reference)))
    (let loop ()
      (let* ((old (current-process-lease-registry-state))
             (registry (cdr old)))
        (when (member key registry)
          (volume-error 'already-leased
                        "state-volume campaign is already leased in this process"))
        (let ((new (cons (car old) (cons key registry))))
          (if (eq? (atomic-box-compare-and-swap!
                    process-lease-registry-state old new)
                   old)
              key
              (loop)))))))

(define (release-process-lease! key)
  (let loop ()
    (let* ((old (current-process-lease-registry-state))
           (new (cons (car old) (delete key (cdr old)))))
      (unless (eq? (atomic-box-compare-and-swap!
                    process-lease-registry-state old new)
                   old)
        (loop)))))

(define (status->exit-code status)
  (or (status:exit-val status)
      (let ((signal-number (status:term-sig status)))
        (if signal-number (+ 128 signal-number) 1))))

(define (waitpid/retry pid)
  (catch 'system-error
    (lambda () (waitpid pid))
    (lambda arguments
      (if (= EINTR (system-error-errno arguments))
          (waitpid/retry pid)
          (apply throw 'system-error arguments)))))

(define (run-tool-on-open-file tool arguments target-fd environment)
  ;; The destructive operand is /proc/self/fd/N, not a pathname lookup.  Only
  ;; this child has CLOEXEC cleared on that descriptor.  The campaign lease and
  ;; every directory descriptor remain CLOEXEC and cannot become tool inputs.
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (catch #t
          (lambda ()
            (fcntl target-fd F_SETFD 0)
            (for-each (match-lambda
                        ((name . value) (setenv name value)))
                      environment)
            (let ((argv (append (list tool) arguments)))
              (apply execl tool argv)))
          (lambda _ (primitive-exit 127)))
        (let ((code (status->exit-code (cdr (waitpid/retry pid)))))
          (unless (zero? code)
            (volume-error 'tool-failed "filesystem tool failed with exit ~a: ~a"
                          code tool))))))

(define mke2fs-config
  "[defaults]\n\
base_features = sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr\n\
default_mntopts = acl,user_xattr\n\
enable_periodic_fsck = 0\n\
blocksize = 4096\n\
inode_size = 256\n\
inode_ratio = 16384\n\
[fs_types]\n\
small = {\n\
inode_ratio = 4096\n\
}\n\
ext4 = {\n\
features = has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize\n\
}\n")

(define (write-exclusive-file path mode contents)
  (let ((fd
         (creation-system-call
          "creating private configuration"
          (lambda ()
            (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       mode))))
        (port #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set-new-regular-file-mode! fd mode "private configuration")
        (set! port (fdopen fd "w"))
        (display contents port)
        (force-output port)
        (fsync fd))
      (lambda ()
        (if port
            (close-port port)
            (close-fdes fd))))))

(define (create-filesystem! root image-fd mke2fs e2fsck)
  (let ((config-path (string-append root "/" mke2fs-config-name)))
    (write-exclusive-file config-path #o400 mke2fs-config)
    (let* ((config-fd (open-fdes config-path
                                 (logior O_RDONLY O_NOFOLLOW O_CLOEXEC)))
           (target (format #f "/proc/self/fd/~a" image-fd))
           (config (format #f "/proc/self/fd/~a" config-fd)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          ;; The child must also retain the config descriptor across exec.
          (let ((pid (primitive-fork)))
            (if (zero? pid)
                (catch #t
                  (lambda ()
                    (fcntl image-fd F_SETFD 0)
                    (fcntl config-fd F_SETFD 0)
                    (setenv "MKE2FS_CONFIG" config)
                    (execl mke2fs mke2fs
                           "-q" "-F" "-t" "ext4"
                           "-L" state-volume-label
                           "-b" "4096" "-I" "256" "-m" "0"
                           "-E" "lazy_itable_init=0,lazy_journal_init=0"
                           target))
                  (lambda _ (primitive-exit 127)))
                (let ((code (status->exit-code (cdr (waitpid/retry pid)))))
                  (unless (zero? code)
                    (volume-error 'tool-failed
                                  "mke2fs failed with exit ~a" code)))))
          (fsync image-fd))
        (lambda () (close-fdes config-fd))))
    (delete-file config-path)
    (run-tool-on-open-file e2fsck (list "-f" "-n"
                                        (format #f "/proc/self/fd/~a" image-fd))
                           image-fd '())
    (fsync image-fd)))

(define (bytevector-range=? bytes offset text width)
  (let ((text-bytes (string->utf8 text)))
    (and (<= (bytevector-length text-bytes) width)
         (let loop ((index 0))
           (cond
            ((= index width) #t)
            ((< index (bytevector-length text-bytes))
             (and (= (bytevector-u8-ref bytes (+ offset index))
                     (bytevector-u8-ref text-bytes index))
                  (loop (+ index 1))))
            (else
             (and (zero? (bytevector-u8-ref bytes (+ offset index)))
                  (loop (+ index 1)))))))))

(define (validate-ext4-header! image-path expected-identity)
  (let* ((fd (open-fdes image-path (logior O_RDONLY O_NOFOLLOW O_CLOEXEC)))
         (info (stat fd))
         (port (fdopen fd "rb")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (same-identity? expected-identity info)
          (volume-error 'identity-changed "state image changed while reading header"))
        (seek port 1024 SEEK_SET)
        (let ((superblock (get-bytevector-n port 1024)))
          (unless (and (bytevector? superblock)
                       (= (bytevector-length superblock) 1024)
                       (= (bytevector-u8-ref superblock #x38) #x53)
                       (= (bytevector-u8-ref superblock #x39) #xef)
                       (bytevector-range=? superblock #x78 state-volume-label 16))
            (volume-error 'invalid-filesystem
                          "state image lacks the exact ext4 magic/label"))))
      (lambda () (close-port port)))))

(define (make-reference campaign-base campaign-base-identity
                        run-base run-base-identity root root-identity
                        lock-identity image-identity)
  (%make-state-volume-reference campaign-base campaign-base-identity
                                run-base run-base-identity root root-identity
                                lock-identity image-identity))

(define (invoke-under-lease reference lock-fd process-lease-key proc)
  (let ((lease
         (%make-state-volume-lease reference lock-fd #t 'idle #f
                                   (make-mutex))))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc lease))
      (lambda ()
        ;; A normal writer-window callback is synchronous and has already
        ;; reaped its writer.  If the supervising process dies, Linux releases
        ;; this lock; its existing outer guardian, not this helper, must kill
        ;; and reap the writer group.  There is intentionally no stale PID file.
        (call-with-lease-mutex
         lease
         (lambda ()
           (set-lease-operation! lease 'idle)
           (set-lease-active! lease #f)))
        (unlock-and-close lock-fd)
        (release-process-lease! process-lease-key)))))

(define (%call-with-new-state-volume-lease campaign-base run-base
                                           mke2fs-path e2fsck-path proc)
  (unless (procedure? proc)
    (volume-error 'invalid-callback "lease callback must be a procedure"))
  (call-with-values
      (lambda () (require-private-base campaign-base "campaign base"))
    (lambda (campaign-base campaign-base-identity)
      (call-with-values
          (lambda () (require-private-base run-base "ephemeral-run base"))
        (lambda (run-base run-base-identity)
          (require-separate-bases campaign-base run-base)
          (let ((mke2fs (require-executable mke2fs-path "mke2fs"))
                (e2fsck (require-executable e2fsck-path "e2fsck")))
            (when (string=? mke2fs e2fsck)
              (volume-error 'invalid-tool "mke2fs and e2fsck must be distinct"))
            (let* ((base-fd
                    (open-fdes campaign-base
                               (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
                   (base-info (stat base-fd))
                   (root #f)
                   (lock-fd #f))
              (dynamic-wind
                (lambda () #t)
                (lambda ()
                  (unless (same-object-metadata? campaign-base-identity base-info)
                    (volume-error 'identity-changed
                                  "campaign base changed before creation"))
                  (let* ((created
                          (creation-system-call
                           "creating campaign root"
                           (lambda ()
                             (mkdtemp
                              (string-append
                               (format #f "/proc/self/fd/~a" base-fd)
                               "/" campaign-prefix "XXXXXX")))))
                         (name (basename created))
                         (created-info (lstat created)))
                    (unless (and (eq? (stat:type created-info) 'directory)
                                 (= (stat:uid created-info) (getuid)))
                      (volume-error 'creation-failed
                                    "new campaign root identity is not owned"))
                    (creation-system-call
                     "setting campaign root mode"
                     (lambda () (chmod created #o700)))
                    (set! root (string-append campaign-base "/" name))
                    (unless (same-object? created-info (lstat root))
                      (volume-error 'identity-changed
                                    "campaign root changed while setting mode")))
                  (let ((root-info (lstat root)))
                    (unless (and (eq? (stat:type root-info) 'directory)
                                 (= (stat:uid root-info) (getuid))
                                 (= (logand (stat:mode root-info) #o7777) #o700))
                      (volume-error 'creation-failed
                                    "new campaign root is not private"))
                    (let* ((lock-path (string-append root "/" lock-name))
                           (image-path
                            (string-append root "/" state-volume-image-name)))
                      (set! lock-fd
                            (creation-system-call
                             "creating owner lock"
                             (lambda ()
                               (open-fdes
                                lock-path
                                (logior O_RDWR O_CREAT O_EXCL O_NOFOLLOW
                                        O_CLOEXEC)
                                #o600))))
                      (set-new-regular-file-mode! lock-fd #o600 "owner lock")
                      (fcntl-flock lock-fd 'write-lock #:wait? #f)
                      (let ((image-fd
                             (creation-system-call
                              "creating state image"
                              (lambda ()
                                (open-fdes
                                 image-path
                                 (logior O_RDWR O_CREAT O_EXCL O_NOFOLLOW
                                         O_CLOEXEC)
                                 #o600)))))
                        (dynamic-wind
                          (lambda () #t)
                          (lambda ()
                            (set-new-regular-file-mode! image-fd #o600
                                                        "state image")
                            (truncate-file image-fd state-volume-size)
                            (unless (= (stat:size (stat image-fd)) state-volume-size)
                              (volume-error 'creation-failed
                                            "could not size state image"))
                            (let ((created-identity
                                   (capture-identity (stat image-fd))))
                              (create-filesystem! root image-fd mke2fs e2fsck)
                              (unless (and
                                       (same-identity? created-identity
                                                       (stat image-fd))
                                       (same-identity? created-identity
                                                       (lstat image-path)))
                                (volume-error
                                 'identity-changed
                                 "state image changed during filesystem creation"))))
                          (lambda () (close-fdes image-fd))))
                      (let* ((lock-identity (capture-identity (stat lock-fd)))
                             (image-identity
                              (capture-identity (lstat image-path)))
                             (reference
                              (make-reference campaign-base campaign-base-identity
                                              run-base run-base-identity
                                              root (capture-identity root-info)
                                              lock-identity image-identity)))
                        (validate-ext4-header! image-path image-identity)
                        (validate-reference! reference)
                        ;; Ownership of LOCK-FD moves to invoke-under-lease.
                        (let ((process-lease-key
                               (claim-process-lease! reference))
                              (owned lock-fd))
                          (set! lock-fd #f)
                          (invoke-under-lease reference owned process-lease-key
                                              proc))))))
                (lambda ()
                  (when lock-fd (unlock-and-close lock-fd))
                  (close-fdes base-fd))))))))))

(define (call-with-new-state-volume-lease campaign-base run-base
                                          mke2fs-path e2fsck-path proc)
  (unless (procedure? proc)
    (volume-error 'invalid-callback "lease callback must be a procedure"))
  (let ((creating? #t))
    (catch 'system-error
      (lambda ()
        (%call-with-new-state-volume-lease
         campaign-base run-base mke2fs-path e2fsck-path
         (lambda (lease)
           (set! creating? #f)
           (proc lease))))
      (lambda arguments
        (if creating?
            (volume-error 'creation-failed "filesystem image creation failed: ~a"
                          (strerror (system-error-errno arguments)))
            (apply throw arguments))))))

(define (call-with-state-volume-lease reference proc)
  (require-reference reference)
  (unless (procedure? proc)
    (volume-error 'invalid-callback "lease callback must be a procedure"))
  ;; POSIX F_SETLK ownership is process-wide: a second thread in this process
  ;; could otherwise "succeed" and closing its descriptor could disturb the
  ;; first lease.  Claim the process registry before opening the lock inode.
  (let ((process-lease-key (claim-process-lease! reference))
        (lock-fd #f)
        (handed-off? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! lock-fd (open-exact-lock reference))
        (set! handed-off? #t)
        (invoke-under-lease reference lock-fd process-lease-key proc))
      (lambda ()
        (unless handed-off?
          (when lock-fd (unlock-and-close lock-fd))
          (release-process-lease! process-lease-key))))))

(define (open-exact-writer-image reference)
  (validate-reference! reference)
  (let* ((path (string-append (reference-campaign-root reference)
                              "/" state-volume-image-name))
         (fd
          (catch 'system-error
            (lambda ()
              (open-fdes path (logior O_RDWR O_NOFOLLOW O_CLOEXEC)))
            (lambda _
              (volume-error 'identity-changed
                            "state image could not be opened by identity"))))
         (expected (reference-image-identity reference)))
    (unless (same-identity? expected (stat fd))
      (close-fdes fd)
      (volume-error 'identity-changed
                    "state image changed while opening writer handle"))
    (catch #t
      (lambda ()
        (validate-reference! reference)
        fd)
      (lambda arguments
        (close-fdes fd)
        (apply throw arguments)))))

(define (call-with-state-volume-writer-window lease proc)
  (require-live-lease lease)
  (unless (procedure? proc)
    (volume-error 'invalid-callback "writer callback must be a procedure"))
  (let ((operation (cons 'writer (list (current-thread))))
        (image-fd #f)
        (writer #f))
    ;; Claim under the lease-private mutex before any validation.  Exactly one
    ;; thread can pass; losers receive a bounded writer-active error rather than
    ;; waiting for the QEMU-length callback.
    (claim-lease-operation! lease operation 'writer-active)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! image-fd
              (open-exact-writer-image (lease-reference lease)))
        (set! writer
              (%make-state-volume-writer lease operation (current-thread)
                                         image-fd #t #f))
        (proc writer))
      (lambda ()
        (when writer
          (set-writer-handoff-active! writer #f)
          (set-writer-active! writer #f))
        (when image-fd (false-if-exception (close-fdes image-fd)))
        (release-lease-operation! lease operation)))))

(define (call-with-state-volume-qemu-handoff writer proc)
  (unless (procedure? proc)
    (volume-error 'invalid-callback "QEMU handoff callback must be a procedure"))
  (validate-state-volume-writer! writer)
  (when (writer-handoff-active? writer)
    (volume-error 'handoff-active "QEMU handoff is already active"))
  (let ((fd #f)
        (handoff #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; dup(2) intentionally clears FD_CLOEXEC on the scoped copy.  The
        ;; retained writer descriptor remains CLOEXEC.  The future accepted
        ;; guardian must preserve this one explicit descriptor through QEMU
        ;; exec and join QEMU before returning from PROC.
        (set! fd (dup (writer-image-fd writer)))
        (unless (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
          (close-fdes fd)
          (set! fd #f)
          (volume-error 'invalid-handoff
                        "duplicated QEMU image anchor remained close-on-exec"))
        (set-writer-handoff-active! writer #t)
        (set! handoff (%make-state-volume-qemu-handoff writer fd #t))
        ;; Verify KCMP_FILE support and exact open-file-description identity
        ;; before exposing the token to its callback.
        (validate-state-volume-handoff! handoff)
        (let ((result (proc handoff)))
          ;; Recheck both the retained descriptor and its owned pathname after
          ;; the synchronous guardian joins.
          (validate-state-volume-handoff! handoff)
          result))
      (lambda ()
        (when handoff (set-handoff-active! handoff #f))
        (set-writer-handoff-active! writer #f)
        (when fd (false-if-exception (close-fdes fd)))))))

(define (validate-state-volume-filesystem! lease e2fsck-path)
  (require-live-lease lease)
  (let ((operation (cons 'validation (list (current-thread)))))
    (claim-lease-operation! lease operation 'writer-active)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((reference (lease-reference lease))
               (e2fsck (require-executable e2fsck-path "e2fsck"))
               (path (state-volume-image-path lease)))
          (validate-reference! reference)
          (let ((fd (open-fdes path (logior O_RDWR O_NOFOLLOW O_CLOEXEC))))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (unless (same-identity? (reference-image-identity reference)
                                        (stat fd))
                  (volume-error 'identity-changed
                                "state image changed while opening for e2fsck"))
                (run-tool-on-open-file
                 e2fsck
                 (list "-f" "-n" (format #f "/proc/self/fd/~a" fd))
                 fd '())
                (validate-ext4-header!
                 path (reference-image-identity reference)))
              (lambda () (close-fdes fd))))
          #t))
      (lambda () (release-lease-operation! lease operation)))))

(define (set-new-private-directory-mode! path label)
  (let ((before (lstat path)))
    (unless (and (eq? (stat:type before) 'directory)
                 (= (stat:uid before) (getuid)))
      (volume-error 'cleanup-race "new ~a is not an owned directory" label))
    (chmod path #o700)
    (let ((after (lstat path)))
      (unless (and (same-object? before after)
                   (= (stat:uid after) (getuid))
                   (= (logand (stat:mode after) #o7777) #o700))
        (volume-error 'cleanup-race "new ~a changed while setting mode" label))
      (capture-identity after))))

(define (rename-exchange-at! old-directory old-name new-directory new-name)
  (call-with-values
      (lambda ()
        (c-renameat2 old-directory (string->pointer old-name)
                     new-directory (string->pointer new-name)
                     RENAME_EXCHANGE))
    (lambda (result errno)
      (unless (zero? result)
        (volume-error 'cleanup-race "renameat2 exchange failed: ~a"
                      (strerror errno))))))

(define (cleanup-state-volume-campaign! lease)
  (require-live-lease lease)
  (let ((operation (cons 'cleanup (list (current-thread)))))
    (claim-lease-operation! lease operation 'writer-active)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((reference (lease-reference lease))
               (base (reference-campaign-base reference))
               (root (reference-campaign-root reference))
               (root-name (basename root))
               (base-fd
                (open-fdes base
                           (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
               (quarantine #f)
               (quarantine-fd #f)
               (sentinel-identity #f)
               (swapped? #f)
               (finished? #f))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              ;; Refuse ordinary unknown/replaced objects before creating the
              ;; sibling quarantine.  No owned campaign object is unlinked yet.
              (validate-reference! reference)
              (unless (same-object-metadata?
                       (reference-campaign-base-identity reference)
                       (stat base-fd))
                (volume-error 'identity-changed
                              "campaign base changed before quarantine"))
              (let* ((created
                      (mkdtemp
                       (string-append (format #f "/proc/self/fd/~a" base-fd)
                                      "/" quarantine-prefix "XXXXXX")))
                     (name (basename created)))
                (set-new-private-directory-mode! created "quarantine root")
                (set! quarantine (string-append base "/" name)))
              (set! quarantine-fd
                    (open-fdes quarantine
                               (logior O_RDONLY O_DIRECTORY O_NOFOLLOW
                                       O_CLOEXEC)))
              (let ((slot (string-append quarantine "/" quarantine-held-name)))
                (mkdir slot #o700)
                (set! sentinel-identity
                      (set-new-private-directory-mode! slot
                                                       "quarantine sentinel")))

              ;; The review hook can replace the source after validation.  The
              ;; atomic exchange never overwrites either side: a replacement is
              ;; moved into quarantine, detected, and exchanged back intact.
              ((cleanup-before-quarantine-hook))
              (rename-exchange-at! base-fd root-name
                                   quarantine-fd quarantine-held-name)
              (set! swapped? #t)
              (let* ((original-now (lstat-or-false root))
                     (held (string-append quarantine "/"
                                          quarantine-held-name))
                     (held-now (lstat-or-false held)))
                (define (rollback-and-fail)
                  (when (and original-now held-now
                             (same-identity? sentinel-identity original-now)
                             (same-object? held-now (lstat held)))
                    (rename-exchange-at! base-fd root-name
                                         quarantine-fd quarantine-held-name)
                    (set! swapped? #f))
                  (volume-error
                   'cleanup-race
                   "campaign changed at quarantine boundary; all objects preserved"))
                (unless (and original-now held-now
                             (same-identity? sentinel-identity original-now)
                             (same-object-metadata?
                              (reference-root-identity reference) held-now))
                  (rollback-and-fail))
                (catch #t
                  (lambda () (validate-campaign-root! reference held))
                  (lambda _ (rollback-and-fail)))

                ;; From here through deletion, this helper's mutex and owner
                ;; lease exclude all cooperating API users.  An uncooperative
                ;; same-UID process can still mutate this private quarantine;
                ;; that residual race is outside the ownership guarantee and is
                ;; stated explicitly in CONTRACT.md.
                (rmdir root)
                (validate-campaign-root! reference held)
                (delete-file (string-append held "/" state-volume-image-name))
                (delete-file (string-append held "/" lock-name))
                (rmdir held)
                (set! swapped? #f)
                (rmdir quarantine)
                (set! quarantine #f)
                (set! finished? #t)
                (set-lease-cleaned! lease #t)
                #t))
            (lambda ()
              ;; Before any unlink, an ordinary failure can put the intact
              ;; campaign back under its original name.  If identities no
              ;; longer make that safe, preserve both names for diagnosis.
              (when (and swapped? quarantine)
                (let* ((held (string-append quarantine "/"
                                            quarantine-held-name))
                       (original-now (lstat-or-false root))
                       (held-now (lstat-or-false held)))
                  (when (and original-now held-now
                             (same-identity? sentinel-identity original-now)
                             (same-object-metadata?
                              (reference-root-identity reference) held-now))
                    (false-if-exception
                     (rename-exchange-at! base-fd root-name
                                          quarantine-fd
                                          quarantine-held-name)))))
              (when quarantine-fd (close-fdes quarantine-fd))
              (close-fdes base-fd)
              (when (and finished? quarantine)
                (volume-error 'cleanup-race
                              "finished cleanup retained an unexpected quarantine"))))))
      (lambda () (release-lease-operation! lease operation)))))
