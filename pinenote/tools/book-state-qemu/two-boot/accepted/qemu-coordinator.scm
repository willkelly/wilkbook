;;; Trusted host lifetime coordinator for the native-reader/QEMU seam fixture.
;;; It owns processes and one private connection.  It never parses UI or Book
;;; Protocol traffic and relies on the existing outer process-group guardian.
(use-modules (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-9)
             (system foreign))

(define socket-connect-timeout-seconds 30.0)
(define child-term-grace-seconds 5.0)
(define reader-log-limit (* 128 1024))
(define qemu-log-limit (* 4 1024 1024))
(define max-unix-path-bytes 107)
(define expected-revision "v2026.03")
(define fixture-tool-dir
  (dirname (canonicalize-path (car (command-line)))))
(define libc (dynamic-link))
(define c-connect
  (pointer->procedure int (dynamic-func "connect" libc)
                      (list int '* uint32) #:return-errno? #t))

(define-record-type <owned-child>
  (make-owned-child name pid start-time process-group record-path captures
                    status)
  owned-child?
  (name child-name)
  (pid child-pid)
  (start-time child-start-time)
  (process-group child-process-group)
  (record-path child-record-path)
  (captures child-captures)
  (status child-status set-child-status!))

(define-record-type <bounded-capture>
  (make-bounded-capture input writer observed retained overflow? eof?)
  bounded-capture?
  (input capture-input)
  (writer capture-writer)
  (observed capture-observed set-capture-observed!)
  (retained capture-retained set-capture-retained!)
  (overflow? capture-overflow? set-capture-overflow?!)
  (eof? capture-eof? set-capture-eof?!))

(define interrupted-signal #f)

(define (note-signal signal-number)
  (set! interrupted-signal signal-number))

(define (fail message . arguments)
  (throw 'book-interaction-qemu-coordinator-error
         (apply format #f message arguments)))

(define (marker text)
  (format #t "BOOK_INTERACTION_QEMU_COORDINATOR: ~a~%" text)
  (force-output))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda _ #f))))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (same-identity? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (lexical-absolute value label)
  (unless (and (string? value) (string-prefix? "/" value))
    (fail "~a must be absolute" label))
  (when (or (string-index value #\nul)
            (string-index value #\newline)
            (string-index value #\return))
    (fail "~a contains a forbidden control character" label))
  (when (any (lambda (part) (member part '("" "." "..")))
             (cdr (string-split value #\/)))
    (fail "~a must not contain //, . or .. components" label))
  value)

(define* (canonical-existing value label #:key (allow-symlink? #f))
  (let* ((path (lexical-absolute value label))
         (canonical
          (catch 'system-error
            (lambda () (canonicalize-path path))
            (lambda _ (fail "~a does not resolve" label)))))
    (when (and (not allow-symlink?) (not (string=? path canonical)))
      (fail "~a must not contain a symlink" label))
    canonical))

(define (canonical-run-root value)
  (let* ((path (canonical-existing value "run root"))
         (info (lstat path)))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "run root must be a caller-owned mode-0700 real directory"))
    (when (string-index path #\,)
      (fail "run root contains QEMU's comma delimiter"))
    (values path info)))

(define (canonical-executable value label)
  (let* ((path (canonical-existing value label #:allow-symlink? #t))
         (info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular) (access? path X_OK))
      (fail "~a is not an executable regular file" label))
    path))

(define (single-line path label)
  (let ((text (call-with-input-file path get-string-all)))
    (unless (and (string-suffix? "\n" text)
                 (not (string-contains (substring text 0
                                                  (- (string-length text) 1))
                                       "\n")))
      (fail "~a is not exactly one newline-terminated line" label))
    (substring text 0 (- (string-length text) 1))))

(define (validate-koreader-package value)
  (let* ((package (canonical-existing value "KOReader package"))
         (info (lstat package))
         (directory (string-append package "/lib/koreader"))
         (revision (string-append directory "/git-rev"))
         (reader (string-append directory "/reader.lua"))
         (luajit (string-append directory "/luajit")))
    (unless (and (eq? (stat:type info) 'directory)
                 (string-suffix? "-koreader-bin-2026.03" package))
      (fail "KOReader package is not the v2026.03 package output"))
    (for-each
     (lambda (path label executable?)
       (let ((entry (lstat path)))
         (unless (and (eq? (stat:type entry) 'regular)
                      (or (not executable?) (access? path X_OK)))
           (fail "KOReader ~a is invalid" label))))
     (list revision reader luajit)
     '(revision reader luajit)
     '(#f #f #t))
    (unless (string=? (single-line revision "KOReader git-rev")
                      expected-revision)
      (fail "KOReader git-rev is not ~a" expected-revision))
    (list package directory luajit)))

(define option-names '("--run-root" "--socket" "--koreader-package" "--qemu"))

(define (parse-command-line arguments)
  (let loop ((rest arguments) (options '()))
    (match rest
      (("--" qemu-arguments ...)
       (unless (= (length options) (length option-names))
         (fail "all four coordinator options are required exactly once"))
       (when (null? qemu-arguments)
         (fail "QEMU argument vector is empty"))
       (values options qemu-arguments))
      ((name value tail ...)
       (unless (member name option-names string=?)
         (fail "unknown coordinator option: ~s" name))
       (when (assoc name options)
         (fail "duplicate coordinator option: ~a" name))
       (loop tail (acons name value options)))
      (_ (fail "coordinator arguments require four pairs and one --")))))

(define (required-option options name)
  (or (assoc-ref options name)
      (fail "missing coordinator option: ~a" name)))

(define (json-quote value)
  (call-with-output-string
    (lambda (port)
      (write-char #\" port)
      (string-for-each
       (lambda (character)
         (cond
          ((char=? character #\") (display "\\\"" port))
          ((char=? character #\\) (display "\\\\" port))
          (else (write-char character port))))
       value)
      (write-char #\" port))))

(define (values-after token arguments)
  (let loop ((rest arguments) (values '()))
    (match rest
      (() (reverse values))
      ((head) (if (string=? head token)
                  (fail "QEMU option ~a lacks a value" token)
                  (reverse values)))
      ((head value tail ...)
       (loop (if (string=? head token) tail (cdr rest))
             (if (string=? head token) (cons value values) values))))))

(define (validate-qemu-arguments arguments run-root socket-path)
  (unless (every string? arguments)
    (fail "QEMU arguments must all be strings"))
  (let ((append-values (values-after "-append" arguments)))
    (unless (= (length append-values) 1)
      (fail "QEMU vector must contain exactly one -append"))
    (let* ((append-line (car append-values))
           (console-socket (string-append run-root "/console.sock"))
           (console-log (string-append run-root "/console.log"))
           (kernel (string-append run-root "/boot/Image"))
           (initrd (string-append run-root "/boot/initrd.cpio.gz"))
           (overlay (string-append run-root "/disk-overlay.qcow2"))
           (console
            (string-append "socket,id=console0,path=" console-socket
                           ",server=on,wait=off,logfile=" console-log
                           ",logappend=off"))
           (ui
            (string-append "socket,id=bookui0,path=" socket-path
                           ",server=on,wait=off"))
           (overlay-file
            (string-append
             "{\"driver\":\"file\",\"filename\":" (json-quote overlay)
             ",\"node-name\":\"rootfs-overlay-file\",\"read-only\":false}"))
           (overlay-format
            "{\"driver\":\"qcow2\",\"file\":\"rootfs-overlay-file\",\"node-name\":\"rootfs-overlay\",\"read-only\":false}")
           (expected
            (list
             "-no-user-config"
             "-nodefaults"
             "-M" "virt"
             "-accel" "tcg,thread=multi"
             "-cpu" "max"
             "-smp" "4"
             "-m" "2048"
             "-display" "none"
             "-no-reboot"
             "-nic" "none"
             "-monitor" "none"
             "-chardev" console
             "-serial" "chardev:console0"
             "-chardev" ui
             "-device" "virtio-serial-pci,id=book-ui-serial"
             "-device"
             "virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction"
             "-kernel" kernel
             "-initrd" initrd
             "-append" append-line
             "-blockdev" overlay-file
             "-blockdev" overlay-format
             "-device" "virtio-blk-pci,drive=rootfs-overlay")))
      (when (or (string-null? append-line)
                (string-index append-line #\nul)
                (string-index append-line #\newline)
                (string-index append-line #\return))
        (fail "QEMU append value is empty or contains a control character"))
      (unless (equal? arguments expected)
        (fail "QEMU argument vector does not match the fixed reader shape")))))

(define (validate-socket-path value run-root)
  (let ((path (lexical-absolute value "private QEMU socket"))
        (expected (string-append run-root "/book-ui.sock")))
    (unless (string=? path expected)
      (fail "private QEMU socket must be exactly RUN_ROOT/book-ui.sock"))
    (when (> (bytevector-length (string->utf8 path)) max-unix-path-bytes)
      (fail "private QEMU socket exceeds sockaddr_un.sun_path"))
    (when (lstat-or-false path)
      (fail "private QEMU socket already exists"))
    path))

(define (mkdir-exact path mode)
  (when (lstat-or-false path)
    (fail "refusing pre-existing coordinator path: ~a" path))
  (mkdir path mode)
  (chmod path mode))

(define (write-fixed-file path text mode)
  (let ((port (fdopen (open-fdes path
                                 (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC)
                                 mode)
                      "w")))
    (dynamic-wind
      (lambda () #t)
      (lambda () (display text port) (force-output port))
      (lambda () (close-port-quietly! port))))
  (chmod path mode))

(define (prepare-reader-tree run-root)
  (let* ((root (string-append run-root "/reader-ui"))
         (home (string-append root "/home"))
         (ko-home (string-append root "/ko"))
         (tmp (string-append root "/tmp"))
         (plugins (string-append ko-home "/plugins"))
         (plugin (string-append plugins "/bookinteractionprobe.koplugin"))
         (source (string-append fixture-tool-dir
                                "/fixture/bookinteractionprobe.koplugin")))
    (mkdir-exact root #o700)
    (for-each (lambda (path) (mkdir-exact path #o700))
              (list home ko-home tmp))
    (for-each
     (lambda (relative)
       (mkdir-exact (string-append home "/" relative) #o700))
     '(".config" ".cache" ".local"))
    (mkdir-exact (string-append home "/.local/share") #o700)
    (mkdir-exact plugins #o700)
    (mkdir-exact plugin #o700)
    (for-each
     (lambda (name)
       (let ((from (string-append source "/" name))
             (to (string-append plugin "/" name)))
         (unless (eq? (stat:type (lstat from)) 'regular)
           (fail "fixture source is not regular: ~a" name))
         (copy-file from to)
         (chmod to #o400)))
     '("_meta.lua" "main.lua" "private_channel.lua" "ui_audit.lua"))
    (write-fixed-file
     (string-append root "/fixture-book.txt")
     (string-append
      "Book interaction QEMU seam fixture\n\n"
      "This inert document only opens pinned KOReader ReaderUI.\n")
     #o400)
    root))

(define (read-process-details pid)
  (let ((path (format #f "/proc/~a/stat" pid)))
    (and (file-exists? path)
         (catch 'system-error
           (lambda ()
             (let* ((text (call-with-input-file path get-string-all))
                    (close (string-rindex text #\)))
                    (fields (and close
                                 (string-tokenize
                                  (substring text (+ close 2))))))
               ;; Suffix starts at field 3: pgrp is field 5 and start is 22.
               (and fields (>= (length fields) 20)
                    (list (list-ref fields 2) (list-ref fields 19)))))
           (lambda _ #f)))))

(define (await-process-details pid)
  (let loop ((attempt 0))
    (let ((details (read-process-details pid)))
      (cond
       (details details)
       ((>= attempt 200) (fail "could not identify child ~a" pid))
       (else (usleep 1000) (loop (+ attempt 1)))))))

(define (write-process-record! path pid start-time)
  (let ((temporary (string-append path ".new")))
    (write-fixed-file
     temporary
     ;; Keep the established two-field PID/start-time record format so the
     ;; outer exact-identity cleanup helper can consume these records directly.
     (format #f "~a ~a~%" pid start-time)
     #o600)
    (rename-file temporary path)))

(define (open-output-port path)
  (fdopen (open-fdes path
                     (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC)
                     #o600)
          "wb"))

(define (open-bounded-capture path)
  (let* ((ports (pipe O_CLOEXEC))
         (input (car ports))
         (output (cdr ports))
         (writer (open-output-port path)))
    (values (make-bounded-capture input writer 0 0 #f #f) output)))

(define (pump-one-capture! capture)
  (unless (capture-eof? capture)
    (let ((value (get-bytevector-some (capture-input capture))))
      (if (eof-object? value)
          (set-capture-eof?! capture #t)
          (let* ((count (bytevector-length value))
                 (retained (capture-retained capture))
                 (remaining (max 0 (- qemu-log-limit retained)))
                 (keep (min count remaining)))
            (when (positive? keep)
              (put-bytevector (capture-writer capture) value 0 keep))
            (set-capture-observed! capture (+ (capture-observed capture) count))
            (set-capture-retained! capture (+ retained keep))
            (when (> count remaining)
              (set-capture-overflow?! capture #t)))))))

(define (pump-captures! captures microseconds)
  (let ((live (filter (lambda (capture) (not (capture-eof? capture)))
                      captures)))
    (if (null? live)
        (when (positive? microseconds) (usleep microseconds))
        (match (select (map capture-input live) '() '() 0 microseconds)
          ((readable () ())
           (for-each
            (lambda (capture)
              (when (memq (capture-input capture) readable)
                (pump-one-capture! capture)))
            live))))))

(define (close-captures! captures)
  (for-each
   (lambda (capture)
     (close-port-quietly! (capture-input capture))
     (when (and (port? (capture-writer capture))
                (not (port-closed? (capture-writer capture))))
       (force-output (capture-writer capture)))
     (close-port-quietly! (capture-writer capture)))
   captures))

(define (finalize-captures! captures)
  (let ((deadline (+ (now-seconds) child-term-grace-seconds)))
    (let loop ()
      (unless (every capture-eof? captures)
        (when (>= (now-seconds) deadline)
          (close-captures! captures)
          (fail "QEMU capture pipe remained open after child reap"))
        (pump-captures! captures 20000)
        (loop))))
  (when (any capture-overflow? captures)
    (close-captures! captures)
    (fail "QEMU stdout or stderr exceeded the bounded capture"))
  (close-captures! captures))

(define (clear-close-on-exec! fd)
  (let ((flags (fcntl fd F_GETFD)))
    (when (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logand flags (lognot FD_CLOEXEC))))
    (when (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
      (fail "donated FD 3 remained close-on-exec"))))

(define (mark-unrelated-close-on-exec! maximum)
  (for-each
   (lambda (name)
     (let ((fd (string->number name 10)))
       (when (and fd (> fd maximum))
         (catch 'system-error
           (lambda ()
             (let ((flags (fcntl fd F_GETFD)))
               (fcntl fd F_SETFD (logior flags FD_CLOEXEC))))
           (lambda _ #f)))))
   (scandir "/proc/self/fd"
            (lambda (name)
              (and (not (member name '("." "..")))
                   (string->number name 10))))))

(define (open-fds)
  (sort
   (filter-map
    (lambda (name)
      (let ((fd (string->number name 10)))
        (and fd
             (catch 'system-error
               (lambda () (fcntl fd F_GETFD) fd)
               (lambda _ #f)))))
    (scandir "/proc/self/fd"
             (lambda (name)
               (and (not (member name '("." "..")))
                    (string->number name 10)))))
   <))

(define (validate-exec-fds! maximum)
  (let* ((observed (open-fds))
         (required (iota (+ maximum 1)))
         (low (filter (lambda (fd) (<= fd maximum)) observed))
         (leaked
          (filter
           (lambda (fd)
             (and (> fd maximum)
                  (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC))))
           observed)))
    (unless (and (equal? low required) (null? leaked))
      (format (current-error-port)
              "BOOK_INTERACTION_QEMU_SPAWN: invalid-exec-fds:low=~s:leaked=~s~%"
              low leaked)
      (force-output (current-error-port))
      (primitive-exit 125))))

(define (child-exec! name release-input donation executable arguments
                     environment directory stdout-target stderr-target
                     log-limit)
  (let ((released (read-char release-input)))
    (close-port-quietly! release-input)
    (unless (and (char? released) (char=? released #\R))
      (primitive-exit 126)))
  (for-each (lambda (signal-number) (sigaction signal-number SIG_DFL))
            (list SIGINT SIGHUP SIGTERM SIGPIPE SIGCHLD))
  (when log-limit (setrlimit 'fsize log-limit log-limit))
  (let ((stdin-fd (open-fdes "/dev/null" (logior O_RDONLY O_CLOEXEC)))
        (stdout-fd (fileno stdout-target))
        (stderr-fd (fileno stderr-target)))
    (dup2 stdin-fd 0)
    (dup2 stdout-fd 1)
    (dup2 stderr-fd 2)
    (close-fdes stdin-fd)
    ;; Close the Guile port objects, rather than leaving live objects around
    ;; raw descriptors that close-unrelated-fds! is about to retire.  This
    ;; prevents a later port finalizer from acting on a reused descriptor.
    (when (> stdout-fd 2) (close-port-quietly! stdout-target))
    (when (and (not (eq? stderr-target stdout-target)) (> stderr-fd 2))
      (close-port-quietly! stderr-target)))
  (if donation
      (begin
        (let ((donation-fd (fileno donation)))
          (dup2 donation-fd 3)
          (when (> donation-fd 3) (close-port-quietly! donation)))
        (clear-close-on-exec! 3)
        (mark-unrelated-close-on-exec! 3)
        (validate-exec-fds! 3)
        (format #t
                "BOOK_INTERACTION_QEMU_SPAWN: ~a:exec-fd-hygiene:stdio-and-donated-only~%"
                name))
      (begin
        ;; Preserve disposable-qemu.scm's reviewed rule: QEMU gets no inherited
        ;; protocol descriptor, and every descriptor above stderr is CLOEXEC.
        (mark-unrelated-close-on-exec! 2)
        (validate-exec-fds! 2)
        (format #t
                "BOOK_INTERACTION_QEMU_SPAWN: ~a:exec-fd-hygiene:stdio-only~%"
                name)))
  (force-output)
  (chdir directory)
  (environ environment)
  (apply execl executable (cons executable arguments)))

(define (waitpid-blocking! pid)
  (catch 'system-error
    (lambda () (waitpid pid))
    (lambda arguments
      (if (= EINTR (system-error-errno arguments))
          (waitpid-blocking! pid)
          (apply throw 'system-error arguments)))))

(define (spawn-owned-child/ports
         name record-path donation executable arguments environment directory
         stdout-target stderr-target parent-close-targets captures log-limit
         expected-process-group)
  (let* ((release (pipe O_CLOEXEC))
         (release-input (car release))
         (release-output (cdr release))
         (pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (close-port-quietly! release-output)
          (catch #t
            (lambda ()
              (child-exec! name release-input donation executable arguments
                           environment directory stdout-target stderr-target
                           log-limit)
              (primitive-exit 127))
            (lambda _ (primitive-exit 127))))
        (begin
          (close-port-quietly! release-input)
          (for-each close-port-quietly! parent-close-targets)
          (let ((released? #f))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let* ((details (await-process-details pid))
                       (process-group (string->number (car details) 10))
                       (start-time (cadr details)))
                  (unless (= process-group expected-process-group)
                    (fail "~a child escaped the outer-owned process group"
                          name))
                  (write-process-record! record-path pid start-time)
                  ;; No unrecorded child is allowed to exec QEMU, KOReader, or
                  ;; a test helper. Publication and release are one guarded
                  ;; operation; every exceptional path kills this direct child
                  ;; while it is still behind the CLOEXEC gate.
                  (write-char #\R release-output)
                  (force-output release-output)
                  (close-port-quietly! release-output)
                  (set! released? #t)
                  (make-owned-child name pid start-time process-group
                                    record-path captures #f)))
              (lambda ()
                (unless released?
                  (close-port-quietly! release-output)
                  (catch 'system-error
                    (lambda () (kill pid SIGKILL))
                    (lambda arguments
                      (unless (= ESRCH (system-error-errno arguments))
                        (apply throw 'system-error arguments))))
                  (waitpid-blocking! pid)
                  (when (lstat-or-false record-path)
                    (delete-file record-path))
                  (close-captures! captures)))))))))

(define (spawn-owned-child name record-path donation executable arguments
                           environment directory stdout-path stderr-path
                           log-limit expected-process-group)
  (let* ((same-output? (string=? stdout-path stderr-path))
         (stdout-target (open-output-port stdout-path))
         (stderr-target
          (if same-output? stdout-target (open-output-port stderr-path))))
    (spawn-owned-child/ports
     name record-path donation executable arguments environment directory
     stdout-target stderr-target
     (if same-output? (list stdout-target)
         (list stdout-target stderr-target))
     '() log-limit expected-process-group)))

(define (spawn-owned-captured-child name record-path executable arguments
                                    environment directory stdout-path
                                    stderr-path expected-process-group)
  (call-with-values
      (lambda () (open-bounded-capture stdout-path))
    (lambda (stdout-capture stdout-target)
      (call-with-values
          (lambda () (open-bounded-capture stderr-path))
        (lambda (stderr-capture stderr-target)
          (spawn-owned-child/ports
           name record-path #f executable arguments environment directory
           stdout-target stderr-target (list stdout-target stderr-target)
           (list stdout-capture stderr-capture) #f
           expected-process-group))))))

(define (decode-child-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   (else (cons 'unknown status))))

(define (reap-child! child)
  (when (and child (not (child-status child)))
    (let ((result
           (catch 'system-error
             (lambda () (waitpid (child-pid child) WNOHANG))
             (lambda arguments
               (if (= EINTR (system-error-errno arguments))
                   '(0 . #f)
                   (if (= ECHILD (system-error-errno arguments))
                       #f
                       (apply throw 'system-error arguments)))))))
      (when (and result (not (zero? (car result))))
        (set-child-status! child (decode-child-status (cdr result))))))
  (and child (child-status child)))

(define (child-current? child)
  (let ((details (and child (read-process-details (child-pid child)))))
    (and details (string=? (cadr details) (child-start-time child)))))

(define (wait-children-for! children seconds)
  (let ((deadline (+ (now-seconds) seconds)))
    (let loop ()
      (for-each
       (lambda (child)
         (pump-captures! (child-captures child) 0)
         (reap-child! child))
       children)
      (cond
       ((every child-status children) #t)
       ((>= (now-seconds) deadline) #f)
       (else (usleep 20000) (loop))))))

(define (signal-current-child! child signal-number)
  (reap-child! child)
  (when (and (not (child-status child)) (child-current? child))
    (catch 'system-error
      (lambda () (kill (child-pid child) signal-number))
      (lambda arguments
        (unless (= ESRCH (system-error-errno arguments))
          (apply throw 'system-error arguments))))))

(define (terminate-owned-set! children)
  (let ((owned (filter (lambda (child) child) children)))
    ;; Signal the whole exact direct-child set before waiting for either one.
    ;; This keeps owner-loss teardown inside one shared five-second TERM grace,
    ;; followed by one shared five-second KILL/reap grace.
    (for-each (lambda (child) (signal-current-child! child SIGTERM)) owned)
    (unless (wait-children-for! owned child-term-grace-seconds)
      (for-each (lambda (child) (signal-current-child! child SIGKILL)) owned)
      (unless (wait-children-for! owned child-term-grace-seconds)
        (fail "an exact child survived SIGKILL: ~s"
              (map child-name
                   (filter (lambda (child) (not (child-status child)))
                           owned)))))))

(define (make-unix-address path)
  (let* ((path-bytes (string->utf8 path))
         (path-length (bytevector-length path-bytes))
         ;; Linux sockaddr_un is a two-byte sa_family_t followed by sun_path.
         ;; Include the pathname's terminating NUL in the connect length.
         (address (make-bytevector (+ 3 path-length) 0)))
    (bytevector-u16-set! address 0 AF_UNIX (native-endianness))
    (bytevector-copy! path-bytes 0 address 2 path-length)
    address))

(define (connect-attempt client address)
  (call-with-values
      (lambda ()
        (c-connect (fileno client) (bytevector->pointer address)
                   (bytevector-length address)))
    cons))

(define (socket-pending-error client retry-interrupted!)
  (let loop ()
    (match
        (catch 'system-error
          (lambda () (list 'value (getsockopt client SOL_SOCKET SO_ERROR)))
          (lambda arguments
            (if (= EINTR (system-error-errno arguments))
                '(interrupted)
                (apply throw 'system-error arguments))))
      (('value value) value)
      (('interrupted)
       (retry-interrupted!)
       (loop)))))

(define (fetch-unix-peer client retry-interrupted!)
  ;; Keep EINTR retry inside the raw syscall fetch.  Its caller always receives
  ;; an address vector or the intentional ENOTCONN result, never a predicate's
  ;; boolean result.  Every retry returns through the original deadline turn.
  (let loop ()
    (match
        (catch 'system-error
          (lambda () (list 'peer (getpeername client)))
          (lambda arguments
            (cond
             ((= EINTR (system-error-errno arguments)) '(interrupted))
             ((= ENOTCONN (system-error-errno arguments)) '(not-connected))
             (else (apply throw 'system-error arguments)))))
      (('peer peer) peer)
      (('not-connected) #f)
      (('interrupted)
       (retry-interrupted!)
       (loop)))))

(define (connected-unix-peer? client path retry-interrupted!)
  (let ((peer (fetch-unix-peer client retry-interrupted!)))
    (and peer
         (begin
           (unless (and (vector? peer)
                        (>= (vector-length peer) 2)
                        (= (vector-ref peer 0) AF_UNIX)
                        (string? (vector-ref peer 1)))
             (fail "connected private QEMU peer has an invalid address"))
           (let* ((reported (vector-ref peer 1))
                  (terminator (string-index reported #\nul))
                  (peer-path
                   (if terminator (substring reported 0 terminator) reported)))
             (unless (string=? peer-path path)
               (fail "connected private QEMU peer has the wrong pathname")))
           #t))))

(define (open-nonblocking-client)
  (let ((client
         (socket AF_UNIX
                 (logior SOCK_STREAM SOCK_CLOEXEC SOCK_NONBLOCK) 0))
        (return-client? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (and (positive? (logand (fcntl (fileno client) F_GETFD)
                                        FD_CLOEXEC))
                     (positive? (logand (fcntl (fileno client) F_GETFL)
                                        O_NONBLOCK)))
          (fail "private QEMU client lacked CLOEXEC or NONBLOCK before connect"))
        (set! return-client? #t)
        client)
      (lambda ()
        (unless return-client?
          (close-port-quietly! client))))))

(define (connect-private-socket! path expected-identity qemu-child)
  (let ((deadline (+ (now-seconds) socket-connect-timeout-seconds))
        (address (make-unix-address path))
        (socket-identity #f)
        (client #f)
        (return-client? #f))
    (define (check-progress!)
      (when interrupted-signal
        (fail "received signal ~a while connecting" interrupted-signal))
      (pump-captures! (child-captures qemu-child) 0)
      (reap-child! qemu-child)
      (when (child-status qemu-child)
        (fail "QEMU exited before private UI connection: ~s"
              (child-status qemu-child)))
      (when (>= (now-seconds) deadline)
        (fail "private QEMU socket connection did not complete before its deadline"))
      (unless (same-identity? expected-identity (lstat (dirname path)))
        (fail "run root identity changed during socket connection")))
    (define (wait-one-turn!)
      ;; Never poll writability as proof of an AF_UNIX connection: Linux reports
      ;; a full-listen-backlog EAGAIN socket writable with SO_ERROR still zero.
      ;; Drain QEMU's bounded pipes and reap every turn, then impose a short
      ;; sleep so that either a quiet or continuously-logging child stays fair.
      (check-progress!)
      (let ((remaining (- deadline (now-seconds))))
        (when (<= remaining 0)
          (fail "private QEMU socket connection did not complete before its deadline"))
        (usleep (max 1 (min 10000
                            (inexact->exact
                             (floor (* remaining 1000000))))))))
    (define (finish-connection!)
      ;; SO_ERROR=0 is insufficient after Linux AF_UNIX EAGAIN.  A successful
      ;; getpeername for this exact pathname is the donation boundary.
      (unless (connected-unix-peer? client path wait-one-turn!)
        (fail "private QEMU socket reported success without a connected peer"))
      (check-progress!)
      (let ((current (lstat-or-false path)))
        (unless (and current (same-identity? socket-identity current))
          (fail "private QEMU socket identity changed during connect")))
      (setvbuf client 'none)
      (set! return-client? #t)
      client)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let loop ()
          (check-progress!)
          (let ((info (lstat-or-false path)))
            (cond
             ((not info)
              (when client
                (fail "private QEMU socket disappeared during connect"))
              (wait-one-turn!)
              (loop))
             ((not (eq? (stat:type info) 'socket))
              (fail "private QEMU path became a non-socket"))
             (else
              (if socket-identity
                  (unless (same-identity? socket-identity info)
                    (fail "private QEMU socket identity changed during connect"))
                  (begin
                    (set! socket-identity info)
                    (set! client (open-nonblocking-client))))
              (let* ((attempt (connect-attempt client address))
                     (result (car attempt))
                     (error-number (cdr attempt)))
                (cond
                 ((zero? result)
                  (finish-connection!))
                 ((connected-unix-peer? client path wait-one-turn!)
                  ;; EINTR or EISCONN can race with completion.  The peer state,
                  ;; never the errno alone, decides whether donation is valid.
                  (finish-connection!))
                 ((memv error-number
                        (list EINTR EINPROGRESS EALREADY EAGAIN EWOULDBLOCK))
                  (let ((pending-error
                         (socket-pending-error client wait-one-turn!)))
                    (unless (zero? pending-error)
                      (fail "private QEMU socket connect failed: ~a"
                            pending-error)))
                  (wait-one-turn!)
                  (loop))
                 ((= error-number EISCONN)
                  (fail "private QEMU socket claimed EISCONN without a peer"))
                 (else
                  (fail "private QEMU socket connect failed: ~a"
                        error-number)))))))))
      (lambda ()
        (unless return-client?
          (close-port-quietly! client))))))

(define (fixed-qemu-environment run-root)
  (let ((path (or (getenv "PATH") "")))
    (when (or (string-index path #\nul)
              (string-index path #\newline)
              (string-index path #\return))
      (fail "PATH contains a forbidden control character"))
    (list (string-append "HOME=" run-root "/home")
          "LANG=C"
          "LC_ALL=C"
          (string-append "PATH=" path)
          (string-append "TMPDIR=" run-root "/tmp")
          (string-append "XDG_CACHE_HOME=" run-root "/xdg-cache")
          (string-append "XDG_CONFIG_HOME=" run-root "/xdg-config")
          (string-append "XDG_RUNTIME_DIR=" run-root "/xdg-runtime"))))

(define (fixed-reader-environment reader-root)
  (let ((path (or (getenv "PATH") "")))
    (list (string-append "HOME=" reader-root "/home")
          (string-append "KO_HOME=" reader-root "/ko")
          (string-append "XDG_CONFIG_HOME=" reader-root "/home/.config")
          (string-append "XDG_CACHE_HOME=" reader-root "/home/.cache")
          (string-append "XDG_DATA_HOME=" reader-root "/home/.local/share")
          (string-append "TMPDIR=" reader-root "/tmp")
          (string-append "PATH=" path)
          "LC_ALL=C"
          (string-append "BOOK_INTERACTION_ROOT=" reader-root)
          "BOOK_INTERACTION_TRUSTED_NATIVE_FIXTURE=1"
          "BOOK_INTERACTION_QEMU_MODE=1"
          "BOOK_INTERACTION_CONTROL_FD=3"
          "SDL_VIDEODRIVER=offscreen"
          "SDL_AUDIODRIVER=dummy")))

(define (count-exact-line text expected)
  (count (lambda (line) (string=? line expected))
         (string-split text #\newline)))

(define (count-line-prefix text prefix)
  (count (lambda (line) (string-prefix? prefix line))
         (string-split text #\newline)))

(define (validate-qemu-log! path)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (< (stat:size info) qemu-log-limit))
      (fail "QEMU stdout is invalid or reached its bound")))
  (let ((text (call-with-input-file path get-string-all)))
    (unless (= (count-exact-line
                text
                "BOOK_INTERACTION_QEMU_SPAWN: qemu:exec-fd-hygiene:stdio-only")
               1)
      (fail "QEMU exec descriptor gate did not run exactly once"))))

(define (validate-reader-log! path)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (< (stat:size info) reader-log-limit))
      (fail "reader log is invalid or reached its bound")))
  (let ((text (call-with-input-file path get-string-all)))
    (when (or (string-contains text "BOOK_INTERACTION_READER: FAIL:")
              (string-contains text "Saving failed."))
      (fail "native reader reported a fixture failure"))
    (for-each
     (lambda (line)
       (unless (= (count-exact-line text line) 1)
         (fail "reader log lacks exactly one ~s" line)))
     (list
      (string-append " [*] Version: " expected-revision)
      "BOOK_INTERACTION_QEMU_SPAWN: koreader:exec-fd-hygiene:stdio-and-donated-only"
      "BOOK_INTERACTION_READER: plugin-init:trusted-qemu-ui-fixture"
      "BOOK_INTERACTION_READER: private-source-registered"
      "BOOK_INTERACTION_READER: selection-action:registered"
      "BOOK_INTERACTION_READER: selection-action:invoked-by-fixture"
      "BOOK_INTERACTION_READER: dialog-shown"
      "BOOK_INTERACTION_READER: startup-overlays-dismissed:2"
      "BOOK_INTERACTION_READER: dialog-topmost"
      "BOOK_INTERACTION_READER: cleanup-audit:before-quit"
      "BOOK_INTERACTION_UI_AUDIT: cleanup:dialog-source-counts-closed-fd-no-callback:ok"
      "BOOK_INTERACTION_UI_AUDIT: cleanup:selection-action-counts-registry:ok"
      "BOOK_INTERACTION_READER: cleanup-audit:dialog-source-channel-fd-callback:clean"
      "BOOK_INTERACTION_READER: selection-action:removed"
      "BOOK_INTERACTION_READER: qemu-presentations-painted:4"
      "BOOK_INTERACTION_READER: result:ok"))
    (for-each
     (lambda (prefix)
       (unless (= (count-line-prefix text prefix) 4)
         (fail "reader log does not contain four ~s observations" prefix)))
     '("BOOK_INTERACTION_READER: dialog-input:qemu-"
       "BOOK_INTERACTION_READER: submit:qemu-"
       "BOOK_INTERACTION_READER: ui-wait-task:qemu-"
       "BOOK_INTERACTION_READER: present-painted-exact:"
       "BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:"))))

(define (run options qemu-arguments)
  (call-with-values
      (lambda () (canonical-run-root (required-option options "--run-root")))
    (lambda (run-root run-identity)
      (let* ((socket-path
              (validate-socket-path
               (required-option options "--socket") run-root))
             (koreader
              (validate-koreader-package
               (required-option options "--koreader-package")))
             (koreader-directory (cadr koreader))
             (luajit (caddr koreader))
             (qemu
              (canonical-executable (required-option options "--qemu")
                                    "QEMU executable"))
             (reader-root (prepare-reader-tree run-root))
             (book (string-append reader-root "/fixture-book.txt"))
             (qemu-stdout (string-append reader-root "/qemu.stdout"))
             (qemu-stderr (string-append reader-root "/qemu.stderr"))
             (reader-log (string-append reader-root "/reader.log"))
             (qemu-record (string-append reader-root "/qemu.pid"))
             (reader-record (string-append reader-root "/reader.pid"))
             (owned-process-group (getpgrp))
             (qemu-child #f)
             (reader-child #f)
             (connection #f)
             (reader-log-validated? #f)
             (completed? #f))
        (validate-qemu-arguments qemu-arguments run-root socket-path)
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (set! qemu-child
                  (spawn-owned-captured-child
                   "qemu" qemu-record qemu qemu-arguments
                   (fixed-qemu-environment run-root) run-root
                   qemu-stdout qemu-stderr owned-process-group))
            (set! connection
                  (connect-private-socket!
                   socket-path run-identity qemu-child))
            (set! reader-child
                  (spawn-owned-child
                   "koreader" reader-record connection luajit
                   (list "reader.lua" book)
                   (fixed-reader-environment reader-root)
                   koreader-directory reader-log reader-log reader-log-limit
                   owned-process-group))
            (close-port-quietly! connection)
            (set! connection #f)
            (let loop ()
              (when interrupted-signal
                (fail "received signal ~a" interrupted-signal))
              (pump-captures! (child-captures qemu-child) 0)
              (reap-child! qemu-child)
              (reap-child! reader-child)
              (when (and (child-status qemu-child)
                         (not (equal? (child-status qemu-child) '(exit . 0))))
                (fail "QEMU child failed: ~s" (child-status qemu-child)))
              (when (and (child-status reader-child)
                         (not (equal? (child-status reader-child) '(exit . 0))))
                (fail "KOReader child failed: ~s" (child-status reader-child)))
              ;; A zero reader status is not normal completion unless its exact
              ;; lifecycle is already present.  This distinguishes an early
              ;; clean exit from the expected reader-first shutdown and lets us
              ;; terminate QEMU immediately on unexpected UI loss.
              (when (and (equal? (child-status reader-child) '(exit . 0))
                         (not reader-log-validated?))
                (validate-reader-log! reader-log)
                (set! reader-log-validated? #t))
              (if (and (child-status qemu-child)
                       (child-status reader-child))
                  (begin
                    (finalize-captures! (child-captures qemu-child))
                    (validate-qemu-log! qemu-stdout)
                    (unless (same-identity? run-identity (lstat run-root))
                      (fail "run root identity changed before log validation"))
                    (unless reader-log-validated?
                      (fail "reader lifecycle was not validated"))
                    (marker "children=zero; reader-lifecycle=pass")
                    (set! completed? #t))
                  (begin (usleep 10000) (loop)))))
          (lambda ()
            (close-port-quietly! connection)
            (unless completed?
              (terminate-owned-set! (list reader-child qemu-child))
              (when qemu-child
                (catch #t
                  (lambda ()
                    (pump-captures! (child-captures qemu-child) 0)
                    (close-captures! (child-captures qemu-child)))
                  (lambda _ #f))))))
        (unless completed?
          (fail "coordinator did not complete"))
        0))))

(for-each
 (lambda (signal-number)
   (sigaction signal-number
              (lambda (_signal) (note-signal signal-number))))
 (list SIGINT SIGHUP SIGTERM))
(sigaction SIGPIPE SIG_IGN)
(umask #o077)

(exit
 (catch #t
   (lambda ()
     (call-with-values
         (lambda () (parse-command-line (cdr (command-line))))
       run))
   (lambda (key . arguments)
     (if (eq? key 'book-interaction-qemu-coordinator-error)
         (format (current-error-port)
                 "BOOK_INTERACTION_QEMU_COORDINATOR: FAIL:~a~%"
                 (car arguments))
         (format (current-error-port)
                 "BOOK_INTERACTION_QEMU_COORDINATOR: FAIL:~s ~s~%"
                 key arguments))
     (force-output (current-error-port))
     1)))
