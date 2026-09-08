(use-modules (book-state-qemu qemu-graph)
             (book-state-qemu state-volume)
             (guix build syscalls)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             (ice-9 threads)
             (srfi srfi-1)
             (srfi srfi-64))

(define arguments (command-line))
(unless (= (length arguments) 3)
  (format (current-error-port)
          "usage: guile -L DIR test-book-state-qemu.scm MKE2FS E2FSCK~%")
  (exit 2))
(define mke2fs (list-ref arguments 1))
(define e2fsck (list-ref arguments 2))

(define (volume-error-code thunk)
  (catch 'book-state-qemu-volume-error
    (lambda () (thunk) #f)
    (lambda (_key code _message) code)))

(define (graph-error? thunk)
  (catch 'book-state-qemu-graph-error
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (write-byte port character)
  (write-char character port)
  (force-output port))

(define (wait-exit-code pid)
  (let ((status (cdr (waitpid pid))))
    (or (status:exit-val status)
        (let ((signal-number (status:term-sig status)))
          (and signal-number (+ 128 signal-number))))))

(define (descriptor-count)
  (length
   (scandir "/proc/self/fd"
            (lambda (name) (not (member name '("." "..")))))))

(define (remove-test-tree path)
  ;; Test-only failure cleanup.  PATH is below the freshly-created top-level
  ;; test root; lstat means this never follows a symlink from mutation cases.
  (let ((info (false-if-exception (lstat path))))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name) (remove-test-tree (string-append path "/" name)))
             (scandir path (lambda (name) (not (member name '("." ".."))))))
            (rmdir path))
          (delete-file path)))))

(define (write-exclusive path contents)
  (let* ((fd (open-fdes path
                        (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                        #o600))
         (port (fdopen fd "w")))
    (display contents port)
    (force-output port)
    (close-port port)))

(define (create-replacement-file path size)
  (let ((fd (open-fdes path
                       (logior O_RDWR O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       #o600)))
    (truncate-file fd size)
    (close-fdes fd)))

(define (make-fresh-run-root run-base)
  (let* ((fd (open-fdes run-base
                        (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
         (created
          (mkdtemp
           (string-append (format #f "/proc/self/fd/~a" fd)
                          "/fake-boot.XXXXXX")))
         (actual (string-append run-base "/" (basename created))))
    (close-fdes fd)
    (chmod actual #o700)
    actual))

(define (lock-attempt-in-child reference expected-code)
  (force-output)
  (force-output (current-error-port))
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (primitive-exit
         (if (eq? (volume-error-code
                   (lambda ()
                     (call-with-state-volume-lease reference (lambda (_) #t))))
                  expected-code)
             0
             1))
        (zero? (wait-exit-code pid)))))

(define (fake-boot lease number run-roots)
  (call-with-state-volume-writer-window
   lease
   (lambda (_writer)
     (let ((image (state-volume-image-path lease)))
     (let* ((run-root (make-fresh-run-root (state-volume-run-base lease)))
             (marker (string-append run-root "/identity")))
        (set! run-roots (cons run-root run-roots))
        (write-exclusive marker
                         (format #f "fake-boot=~a image-inode=~a\n"
                                 number
                                 (assq-ref (state-volume-image-identity lease)
                                           'inode)))
        (force-output)
        (force-output (current-error-port))
        (let* ((ready-pipe (pipe O_CLOEXEC))
               (release-pipe (pipe O_CLOEXEC))
               (ready-in (car ready-pipe))
               (ready-out (cdr ready-pipe))
               (release-in (car release-pipe))
               (release-out (cdr release-pipe))
               (pid (primitive-fork)))
          (if (zero? pid)
              (begin
                (close-port ready-in)
                (close-port release-out)
                ;; This models only an open child writer lifetime.  It does not
                ;; alter ext4 and is not semantic state persistence evidence.
                (let ((image-fd
                       (open-fdes image (logior O_RDWR O_NOFOLLOW O_CLOEXEC))))
                  (write-byte ready-out #\R)
                  (read-char release-in)
                  (close-fdes image-fd)
                  (primitive-exit 0)))
              (begin
                (close-port ready-out)
                (close-port release-in)
                (test-equal (format #f "fake boot ~a writer opened image" number)
                  #\R (read-char ready-in))
                (test-assert
                    (format #f "campaign parent retains lease during fake boot ~a"
                            number)
                  (lock-attempt-in-child (state-volume-reference lease)
                                         'already-leased))
                (write-byte release-out #\X)
                (test-equal (format #f "fake boot ~a writer closes cleanly" number)
                  0 (wait-exit-code pid))
                (close-port ready-in)
                (close-port release-out)
                (delete-file marker)
                (rmdir run-root)
                run-roots))))))))

(define (wait-until predicate timeout-seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout-seconds internal-time-units-per-second))))
    (let loop ()
      (cond
       ((predicate) #t)
       ((>= (get-internal-real-time) deadline) #f)
       (else (usleep 1000) (loop))))))

(define (concurrent-window-result lease)
  ;; Deterministic baton: thread 1 holds the writer callback until thread 2 has
  ;; either returned writer-active or exceeded the one-second bound.
  (let ((gate (make-mutex))
        (first-entered? #f)
        (release-first? #f)
        (active 0)
        (maximum 0)
        (entered 0)
        (first-result #f)
        (second-result #f))
    (define (record-enter!)
      (lock-mutex gate)
      (set! active (+ active 1))
      (set! entered (+ entered 1))
      (set! maximum (max maximum active))
      (unlock-mutex gate))
    (define (record-leave!)
      (lock-mutex gate)
      (set! active (- active 1))
      (unlock-mutex gate))
    (let ((first
           (call-with-new-thread
            (lambda ()
              (set! first-result
                    (catch 'book-state-qemu-volume-error
                      (lambda ()
                        (call-with-state-volume-writer-window
                         lease
                         (lambda (_writer)
                           (record-enter!)
                           (lock-mutex gate)
                           (set! first-entered? #t)
                           (unlock-mutex gate)
                           (wait-until
                            (lambda ()
                              (lock-mutex gate)
                              (let ((value release-first?))
                                (unlock-mutex gate)
                                value))
                            2)
                           (record-leave!)
                           'entered)))
                      (lambda (_ code _message) code)))))))
      (unless (wait-until
               (lambda ()
                 (lock-mutex gate)
                 (let ((value first-entered?))
                   (unlock-mutex gate)
                   value))
               1)
        (error "first writer thread did not enter within bound"))
      (let ((second
             (call-with-new-thread
              (lambda ()
                (let ((result
                       (catch 'book-state-qemu-volume-error
                         (lambda ()
                           (call-with-state-volume-writer-window
                            lease
                            (lambda (_writer)
                              (record-enter!)
                              (record-leave!)
                              'entered)))
                         (lambda (_ code _message) code))))
                  (lock-mutex gate)
                  (set! second-result result)
                  (unlock-mutex gate)
                  result)))))
        (let ((bounded-second
               (wait-until
                (lambda ()
                  (lock-mutex gate)
                  (let ((value second-result))
                    (unlock-mutex gate)
                    value))
                1)))
          (lock-mutex gate)
          (set! release-first? #t)
          (unlock-mutex gate)
          (join-thread first)
          (join-thread second)
          (list entered maximum first-result second-result bounded-second))))))

(define (read-prefix path count)
  (let ((port (open-file path "rb")))
    (let ((value (get-string-n port count)))
      (close-port port)
      value)))

(define (write-prefix! path text)
  (let ((port (open-file path "r+b")))
    (display text port)
    (force-output port)
    (close-port port)))

(define qemu
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-qemu/bin/qemu-system-aarch64")
(define reader-run-root "/tmp/opencode/book-state-reader-run.123456")
(define kernel (string-append reader-run-root "/boot/Image"))
(define initrd (string-append reader-run-root "/boot/initrd.cpio.gz"))
(define overlay (string-append reader-run-root "/disk-overlay.qcow2"))
(define append-line "root=PNGuixRoot console=ttyAMA0")
(define expected-console
  (string-append "socket,id=console0,path=" reader-run-root
                 "/console.sock,server=on,wait=off,logfile=" reader-run-root
                 "/console.log,logappend=off"))
(define expected-ui
  (string-append "socket,id=bookui0,path=" reader-run-root
                 "/book-ui.sock,server=on,wait=off"))
(define expected-reader-arguments
  (list qemu
        "-no-user-config" "-nodefaults"
        "-M" "virt" "-accel" "tcg,thread=multi" "-cpu" "max"
        "-smp" "4" "-m" "2048" "-display" "none" "-no-reboot"
        "-nic" "none" "-monitor" "none"
        "-chardev" expected-console "-serial" "chardev:console0"
        "-chardev" expected-ui
        "-device" "virtio-serial-pci,id=book-ui-serial"
        "-device"
        "virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction"
        "-kernel" kernel "-initrd" initrd "-append" append-line
        "-blockdev"
        (string-append
         "{\"driver\":\"file\",\"filename\":\"" overlay
         "\",\"node-name\":\"rootfs-overlay-file\",\"read-only\":false}")
        "-blockdev"
        "{\"driver\":\"qcow2\",\"file\":\"rootfs-overlay-file\",\"node-name\":\"rootfs-overlay\",\"read-only\":false}"
        "-device" "virtio-blk-pci,drive=rootfs-overlay"))

(define top (mkdtemp "/tmp/opencode/book-state-qemu-test.XXXXXX"))
(chmod top #o700)
(define top-identity (lstat top))
(define campaign-base (string-append top "/campaigns"))
(define run-base (string-append top "/runs"))
(mkdir campaign-base #o700)
(mkdir run-base #o700)
;; Initialize Guile's thread runtime before any focused fork checks.
(join-thread (call-with-new-thread (lambda () #t)))
(let ((pid (primitive-fork)))
  (if (zero? pid) (primitive-exit 0) (wait-exit-code pid)))
(define baseline-descriptor-count (descriptor-count))

(dynamic-wind
  (lambda () #t)
  (lambda ()
    (test-begin "book-state-qemu")

    (test-equal "fixed volume label" "WBBookStateV1" state-volume-label)
    (test-equal "fixed 64 MiB image" (* 64 1024 1024) state-volume-size)
    (test-equal "fixed trusted mount"
      "/var/lib/wilkbook-book-state-demo" state-volume-mount-point)
    (test-equal "fixed database path"
      "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite"
      state-volume-database-path)
    (test-equal "mandatory trusted-only ext4 mount contract"
      '("ext4" "noatime,nodev,nosuid,noexec" #f trusted-guest-guile #f)
      (map (lambda (key) (assq-ref state-volume-mount-contract key))
           '(type options mount-may-fail? owner sandbox-visible?)))

    (test-equal "overlapping campaign/run bases are refused"
      'overlapping-bases
      (volume-error-code
       (lambda ()
         (call-with-new-state-volume-lease
          campaign-base campaign-base mke2fs e2fsck (lambda (_) #t)))))

    (let ((safe-path? (@@ (book-state-qemu state-volume)
                          safe-absolute-path?)))
      (test-assert "all U+0000 through U+001F path controls are rejected"
        (every
         (lambda (codepoint)
           (not (safe-path?
                 (string-append "/tmp/opencode/control-"
                                (string (integer->char codepoint))))))
         (iota #x20))))

    (let ((tab-base (string-append top "/campaigns\tcontrol")))
      (mkdir tab-base #o700)
      (test-equal "TAB base is rejected before campaign mutation"
        'invalid-path
        (volume-error-code
         (lambda ()
           (call-with-new-state-volume-lease
            tab-base run-base mke2fs e2fsck (lambda (_) #t)))))
      (test-assert "rejected TAB base remains empty"
        (null? (scandir tab-base
                        (lambda (name) (not (member name '("." "..")))))))
      (rmdir tab-base))

    (let ((validate-collisions
           (@@ (book-state-qemu qemu-graph) validate-no-state-collisions)))
      (test-assert "valid alternate JSON whitespace remains accepted"
        (validate-collisions
         '("-blockdev"
           "{ \"driver\" : \"null-co\", \"node-name\" : \"safe-node\" }")))
      (for-each
       (lambda (arguments label)
         (test-assert label
           (graph-error? (lambda () (validate-collisions arguments)))))
       (list
        '("-blockdev"
          "{\"driver\":\"null-co\",\"node-name\": \"book-state\"}")
        '("-blockdev"
          "{\"driver\":\"null-co\",\"node-name\":\"book\\u002dstate-file\"}")
        '("-blockdev"
          "{\"driver\":\"raw\",\"file\": \"book-state-file\",\"node-name\":\"safe\"}")
        '("-device" "virtio-blk-pci, id = book-state-disk")
        '("-device" "virtio-blk-pci, drive = book-state")
        '("-device" "virtio-blk-pci, serial = WBBOOKSTATEV1")
        '("-blockdev"
          "{\"node-name\":\"safe\",\"node-name\":\"book-state\"}")
        '("-blockdev" "{\"node-name\":\"same\"}"
          "-blockdev" "{\"node-name\" : \"same\"}"))
       '("alternate whitespace cannot hide reserved raw node"
         "Unicode escape cannot hide reserved file node"
         "alternate whitespace cannot hide reserved file reference"
         "device whitespace cannot hide reserved id"
         "device whitespace cannot hide reserved drive"
         "device whitespace cannot hide reserved serial"
         "duplicate JSON key is rejected"
         "duplicate node names are rejected structurally")))

    ;; The implementation never changes the process umask.  This isolated
    ;; regression deliberately makes creation modes unusable unless each fresh
    ;; owned object is corrected through its descriptor (or, for mkdtemp, after
    ;; capturing its new identity).
    (let ((old-umask (umask #o777)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (let ((config-probe (string-append top "/strict-config-probe")))
            ((@@ (book-state-qemu state-volume) write-exclusive-file)
             config-probe #o400 "probe\n")
            (test-equal "strict umask still yields exact temporary-config mode"
              #o400 (logand (stat:mode (lstat config-probe)) #o7777))
            (delete-file config-probe))
          (call-with-new-state-volume-lease
           campaign-base run-base mke2fs e2fsck
           (lambda (lease)
             (let* ((root (state-volume-campaign-root lease))
                    (lock (string-append root "/owner.lock"))
                    (image (state-volume-image-path lease)))
               (test-equal "strict umask still yields exact root/lock/image modes"
                 (list #o700 #o600 #o600)
                 (map (lambda (path)
                        (logand (stat:mode (lstat path)) #o7777))
                      (list root lock image)))
               (test-assert "strict-umask image validates"
                 (validate-state-volume-filesystem! lease e2fsck))
               (test-assert "strict-umask campaign cleans normally"
                 (cleanup-state-volume-campaign! lease))))))
        (lambda () (umask old-umask))))

    (let ((first-reference #f)
          (initial-identity #f)
          (run-roots '()))
      (call-with-new-state-volume-lease
       campaign-base run-base mke2fs e2fsck
       (lambda (lease)
         (set! first-reference (state-volume-reference lease))
         (set! initial-identity (state-volume-image-identity lease))
         (test-equal "same-process duplicate lease is refused before F_SETLK"
           'already-leased
           (volume-error-code
            (lambda ()
              (call-with-state-volume-lease first-reference (lambda (_) #t)))))
         (test-equal "new image has exact size"
           state-volume-size
           (stat:size (lstat (state-volume-image-path lease))))
         (test-equal "new image is caller-owned mode 0600 and single-linked"
           (list (getuid) #o600 1 'regular)
           (let ((info (lstat (state-volume-image-path lease))))
             (list (stat:uid info)
                   (logand (stat:mode info) #o7777)
                   (stat:nlink info)
                   (stat:type info))))
         (test-assert "fresh ext4 passes explicit e2fsck"
           (validate-state-volume-filesystem! lease e2fsck))

         (call-with-state-volume-writer-window
          lease
          (lambda (writer)
            (test-equal "nested writer window is refused"
              'writer-active
              (volume-error-code
               (lambda ()
                 (call-with-state-volume-writer-window lease (lambda (_) #t)))))
            (call-with-state-volume-qemu-handoff
             writer
             (lambda (handoff)
               (let* ((file-name
                       (state-volume-qemu-handoff-file-name handoff))
                      (expected-file
                       (string-append
                        "{\"driver\":\"file\",\"filename\":\"" file-name
                        "\",\"node-name\":\"book-state-file\",\"read-only\":false,\"locking\":\"on\"}"))
                      (expected-file-locking-off
                       (string-append
                        "{\"driver\":\"file\",\"filename\":\"" file-name
                        "\",\"node-name\":\"book-state-file\",\"read-only\":false,\"locking\":\"off\"}"))
                      (expected-raw
                       "{\"driver\":\"raw\",\"file\":\"book-state-file\",\"node-name\":\"book-state\",\"read-only\":false}")
                      (expected-device
                       "virtio-blk-pci,drive=book-state,id=book-state-disk,serial=WBBOOKSTATEV1")
                      (expected
                       (append expected-reader-arguments
                               (list "-blockdev" expected-file
                                     "-blockdev" expected-raw
                                     "-device" expected-device)))
                      (actual
                       (leased-state-volume-qemu-arguments
                        qemu reader-run-root kernel initrd append-line overlay
                        handoff)))
                 (test-assert "graph uses only inherited descriptor filename"
                   (and (string-prefix? "/proc/self/fd/" file-name)
                        (not (string-contains expected-file
                                              (state-volume-campaign-root lease)))))
                 (test-equal "exact accepted reader oracle plus three-pair delta"
                   expected actual)
                 (test-assert "exact descriptor-bound full graph self-validates"
                   (assert-leased-state-volume-qemu-arguments
                    actual qemu reader-run-root kernel initrd append-line overlay
                    handoff))
                 (test-equal "state device follows accepted root device"
                   (list "virtio-blk-pci,drive=rootfs-overlay" "-blockdev")
                   (take (drop actual
                               (- (length expected-reader-arguments) 1))
                         2))
                 (for-each
                  (lambda (mutation label)
                    (test-assert label
                      (graph-error?
                       (lambda ()
                         (assert-leased-state-volume-qemu-arguments
                          mutation qemu reader-run-root kernel initrd append-line
                          overlay handoff)))))
                  (list (delete expected-file actual)
                        (map (lambda (item)
                               (if (string=? item expected-file)
                                   expected-file-locking-off
                                   item))
                             actual)
                        (append actual '("-virtfs" "local,path=/tmp"))
                        (map (lambda (item)
                               (if (string=? item "none") "user" item))
                             actual))
                  '("missing file node fails exact checker"
                    "disabled image locking fails exact checker"
                    "extra host share fails exact checker"
                    "network mutation fails independent oracle"))

                 (let* ((path (state-volume-image-path lease))
                        (saved (string-append top "/graph-saved-image.ext4")))
                   (dynamic-wind
                     (lambda ()
                       (rename-file path saved)
                       (create-replacement-file path state-volume-size))
                     (lambda ()
                       (test-equal
                           "graph mint rejects same-name image replacement"
                         'identity-changed
                         (volume-error-code
                          (lambda ()
                            (leased-state-volume-qemu-arguments
                             qemu reader-run-root kernel initrd append-line
                             overlay handoff))))
                       (test-equal
                           "checker rejects replacement after graph was minted"
                         'identity-changed
                         (volume-error-code
                          (lambda ()
                            (assert-leased-state-volume-qemu-arguments
                             actual qemu reader-run-root kernel initrd append-line
                             overlay handoff))))
                       (test-assert "retained and replacement image both survive"
                         (and (file-exists? path) (file-exists? saved))))
                     (lambda ()
                       (delete-file path)
                       (rename-file saved path))))

                 (let* ((root (state-volume-campaign-root lease))
                        (lock (string-append root "/owner.lock"))
                        (saved (string-append top "/graph-saved-owner.lock")))
                   (dynamic-wind
                     (lambda ()
                       (rename-file lock saved)
                       (create-replacement-file lock 0))
                     (lambda ()
                       (test-equal "graph mint rejects owner-lock replacement"
                         'identity-changed
                         (volume-error-code
                          (lambda ()
                            (leased-state-volume-qemu-arguments
                             qemu reader-run-root kernel initrd append-line
                             overlay handoff))))
                       (test-assert "both owner-lock inodes survive refusal"
                         (and (file-exists? lock) (file-exists? saved))))
                      (lambda ()
                        (delete-file lock)
                        (rename-file saved lock))))

                 (let* ((root (state-volume-campaign-root lease))
                        (saved (string-append top "/graph-saved-root"))
                        (marker (string-append root "/foreign-root-bytes")))
                   (dynamic-wind
                     (lambda ()
                       (rename-file root saved)
                       (mkdir root #o700)
                       (write-exclusive marker "foreign root\n"))
                     (lambda ()
                       (test-equal "graph mint rejects campaign-root replacement"
                         'identity-changed
                         (volume-error-code
                          (lambda ()
                            (leased-state-volume-qemu-arguments
                             qemu reader-run-root kernel initrd append-line
                             overlay handoff))))
                       (test-assert "retained and replacement roots both survive"
                         (and (file-exists? marker) (file-exists? saved))))
                     (lambda ()
                       (delete-file marker)
                       (rmdir root)
                       (rename-file saved root)))))))))

         (let ((thread-result (concurrent-window-result lease)))
           (test-equal "two-thread writer baton admits exactly one callback"
             1 (list-ref thread-result 0))
           (test-equal "two-thread writer baton maximum active count is one"
             1 (list-ref thread-result 1))
           (test-equal "winner enters and loser gets bounded writer-active"
             '(entered writer-active)
             (list (list-ref thread-result 2) (list-ref thread-result 3)))
           (test-equal "loser returned within one-second join bound"
             #t (list-ref thread-result 4)))

         (set! run-roots (fake-boot lease 1 run-roots))
         (test-assert "first fake run root was removed"
           (not (file-exists? (car run-roots))))
         (set! run-roots (fake-boot lease 2 run-roots))
         (test-assert "second fake run root was removed"
           (not (file-exists? (car run-roots))))
         (test-assert "fake boots used distinct fresh run roots"
           (not (string=? (car run-roots) (cadr run-roots))))
         (test-equal "same image identity retained across fake lifetimes"
           initial-identity (state-volume-image-identity lease))
         (test-assert "retained ext4 still passes explicit e2fsck"
           (validate-state-volume-filesystem! lease e2fsck))

         (call-with-state-volume-writer-window
          lease
          (lambda (_)
            (test-equal "cleanup is refused during writer window"
              'writer-active
              (volume-error-code
               (lambda () (cleanup-state-volume-campaign! lease))))))

         (let ((unexpected
                (string-append (state-volume-campaign-root lease) "/foreign")))
           (write-exclusive unexpected "preserve me\n")
           (test-equal "unknown entry makes cleanup fail before unlink"
             'unexpected-entry
             (volume-error-code
              (lambda () (cleanup-state-volume-campaign! lease))))
           (test-assert "unknown entry and state image are preserved"
             (and (file-exists? unexpected)
                  (file-exists? (state-volume-image-path lease))))
           (delete-file unexpected))
         (test-assert "exact owned campaign cleans under lease"
           (cleanup-state-volume-campaign! lease))))
      (test-assert "cleaned campaign root is absent"
        (not (file-exists? (state-volume-campaign-root first-reference))))
      (test-equal "cleaned reference cannot be reopened"
        'identity-changed
        (volume-error-code
         (lambda ()
           (call-with-state-volume-lease first-reference (lambda (_) #t))))))

    ;; A second campaign is retained deliberately to exercise owner crash and
    ;; conservative refusal without allocating more than one extra 64 MiB image.
    (let ((reference #f))
      (call-with-new-state-volume-lease
       campaign-base run-base mke2fs e2fsck
       (lambda (lease)
         (set! reference (state-volume-reference lease))))
      (let* ((ready (pipe O_CLOEXEC))
             (release (pipe O_CLOEXEC))
             (ready-in (car ready))
             (ready-out (cdr ready))
             (release-in (car release))
             (release-out (cdr release))
             (pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (close-port ready-in)
              (close-port release-out)
              (call-with-state-volume-lease
               reference
               (lambda (_lease)
                 (write-byte ready-out #\R)
                 (read-char release-in)
                 ;; Simulate abrupt owner loss: no Scheme finalizer runs.
                 (kill (getpid) SIGKILL)
                 (primitive-exit 99)))
              (primitive-exit 98))
            (begin
              (close-port ready-out)
              (close-port release-in)
              (test-equal "crash-owner child acquired lease"
                #\R (read-char ready-in))
              (test-equal "second owner is refused while crash-owner lives"
                'already-leased
                (volume-error-code
                 (lambda ()
                   (call-with-state-volume-lease reference (lambda (_) #t)))))
              (write-byte release-out #\X)
              (test-equal "owner exits by deliberate SIGKILL"
                (+ 128 SIGKILL) (wait-exit-code pid))
              (close-port ready-in)
              (close-port release-out))))
      (test-assert "kernel releases lease after owner crash; no stale PID gate"
        (call-with-state-volume-lease reference (lambda (_) #t)))
      (test-equal "owner lock contains no stale PID data"
        0
        (stat:size
         (lstat (string-append (state-volume-campaign-root reference)
                               "/owner.lock"))))

      (let* ((image (state-volume-image-path reference))
             (saved (string-append top "/saved-original.ext4")))
        (rename-file image saved)
        (create-replacement-file image state-volume-size)
        (test-equal "same-name replacement image is rejected despite free lock"
          'identity-changed
          (volume-error-code
           (lambda ()
             (call-with-state-volume-lease reference (lambda (_) #t)))))
        (test-assert "replacement and original are both preserved"
          (and (file-exists? image) (file-exists? saved)))
        (delete-file image)
        (rename-file saved image))

      (let* ((image (state-volume-image-path reference))
             (saved (string-append top "/saved-symlink-target.ext4")))
        (rename-file image saved)
        (symlink saved image)
        (test-equal "symlink image is rejected"
          'identity-changed
          (volume-error-code
           (lambda ()
             (call-with-state-volume-lease reference (lambda (_) #t)))))
        (test-assert "symlink and its target are preserved"
          (and (eq? (stat:type (lstat image)) 'symlink)
               (file-exists? saved)))
        (delete-file image)
        (rename-file saved image))

      (let* ((image (state-volume-image-path reference))
             (alias (string-append top "/hard-link-alias.ext4")))
        (link image alias)
        (test-equal "hard-link alias invalidates single-link identity"
          'identity-changed
          (volume-error-code
           (lambda ()
             (call-with-state-volume-lease reference (lambda (_) #t)))))
        (test-assert "hard-link refusal preserves image and alias"
          (and (file-exists? image) (file-exists? alias)))
        (delete-file alias))

      (let* ((root (state-volume-campaign-root reference))
             (saved (string-append campaign-base "/saved-campaign-root"))
             (marker (string-append root "/foreign-marker")))
        (rename-file root saved)
        (mkdir root #o700)
        (write-exclusive marker "foreign replacement\n")
        (test-equal "same-name replacement campaign root is rejected"
          'identity-changed
          (volume-error-code
           (lambda ()
             (call-with-state-volume-lease reference (lambda (_) #t)))))
        (test-assert "replacement root contents and original root are preserved"
          (and (file-exists? marker) (file-exists? saved)))
        (delete-file marker)
        (rmdir root)
        (rename-file saved root))

      (let* ((root (state-volume-campaign-root reference))
             (saved (string-append campaign-base "/saved-campaign-symlink")))
        (rename-file root saved)
        (symlink saved root)
        (test-equal "symlink campaign root is rejected"
          'identity-changed
          (volume-error-code
           (lambda ()
             (call-with-state-volume-lease reference (lambda (_) #t)))))
        (test-assert "root symlink and original directory are preserved"
          (and (eq? (stat:type (lstat root)) 'symlink)
               (file-exists? saved)))
        (delete-file root)
        (rename-file saved root))

      (call-with-state-volume-lease
       reference
       (lambda (lease)
         (let* ((root (state-volume-campaign-root lease))
                (image (state-volume-image-path lease))
                (saved (string-append top "/cleanup-race-original.ext4"))
                (foreign-text "FOREIGN-BYTES-MUST-SURVIVE")
                (cleanup-hook
                 (@@ (book-state-qemu state-volume)
                     cleanup-before-quarantine-hook)))
           (test-equal
               "quarantine detects post-validation substitution and rolls back"
             'cleanup-race
             (parameterize
                 ((cleanup-hook
                   (lambda ()
                     (rename-file image saved)
                     (create-replacement-file image state-volume-size)
                     (write-prefix! image foreign-text))))
               (volume-error-code
                (lambda () (cleanup-state-volume-campaign! lease)))))
           (test-equal "cleanup race preserves exact foreign bytes at source name"
             foreign-text (read-prefix image (string-length foreign-text)))
           (test-assert "cleanup race preserves original retained image too"
             (file-exists? saved))
           (let ((quarantines
                  (filter
                   (lambda (name)
                     (string-prefix? "book-state-quarantine." name))
                   (scandir campaign-base
                            (lambda (name)
                              (not (member name '("." ".."))))))))
             (test-equal "failed quarantine remains for diagnosis" 1
               (length quarantines))
             (delete-file image)
             (rename-file saved image)
             ;; This is exact test-owned diagnostic cleanup, not the production
             ;; helper's conservative failure path.
             (remove-test-tree
              (string-append campaign-base "/" (car quarantines)))))))

      (call-with-state-volume-lease
       reference
       (lambda (lease)
         (test-assert "restored exact identities validate after refusal cases"
           (validate-state-volume-filesystem! lease e2fsck))
         (test-assert "restored campaign cleans exactly"
           (cleanup-state-volume-campaign! lease)))))

    (test-assert "campaign base is empty after exact cleanups"
      (null? (scandir campaign-base
                      (lambda (name) (not (member name '("." "..")))))))
    (test-assert "ephemeral run base is empty after fake boots"
      (null? (scandir run-base
                      (lambda (name) (not (member name '("." "..")))))))
    (test-equal "all lease, writer, handoff, tool, and test descriptors close"
      baseline-descriptor-count (descriptor-count))

    (test-end "book-state-qemu"))
  (lambda ()
    (when (and (false-if-exception (lstat top))
               (= (stat:dev top-identity) (stat:dev (lstat top)))
               (= (stat:ino top-identity) (stat:ino (lstat top)))
               (string-prefix? "/tmp/opencode/book-state-qemu-test." top))
      (remove-test-tree top))))
