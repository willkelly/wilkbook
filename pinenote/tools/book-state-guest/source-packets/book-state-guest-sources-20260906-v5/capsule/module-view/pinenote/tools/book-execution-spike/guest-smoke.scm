;;; In-guest compatibility assertions for the non-shipping execution spike.
;;; This is a fixed test fixture, not a Book Protocol broker or production
;;; session supervisor.  It emits control-plane markers only to /dev/console.
;;; Each sandbox payload emits one exact captured diagnostic sentinel; stdout
;;; is not a general result channel or the future Book Protocol transport.
(define-module (guest-smoke)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (assert-mount-boundaries
            emit-bounded-file-diagnostic
            emit-runsc-debug-diagnostics
            forbidden-host-mount?
            guile-process-arguments
            guest-smoke-main
            network-interface-set-safe?))

(define expected-gvisor-release "release-20260831.0")
(define execution-profile "isolation-userns")
(define process-timeout-seconds 180.0)
(define process-term-grace-seconds 3.0)
(define max-capture-bytes (* 4 1024 1024))
(define max-mount-diagnostic-bytes 2048)
(define diagnostic-head-bytes (* 8 1024))
(define diagnostic-tail-bytes (* 8 1024))
;; This historical name is consumed by the outer console-budget check.  It is
;; the total selected debug plus panic file count, not one directory's quota.
(define max-debug-log-files 12)
(define max-direct-debug-log-files 10)
(define max-panic-log-files 2)
(define debug-store-bytes (* 4 1024 1024))
(define panic-store-bytes (* 1 1024 1024))
(define mount-program "/run/current-system/profile/bin/mount")
(define umount-program "/run/current-system/profile/bin/umount")
(define console-port #f)

;; Architecture decision: pinned runsc rejects --debug-log-fd and
;; --panic-log-fd on its public "run" command.  It opens distinct per-command
;; paths and donates those regular-file FDs to internal helpers.  Preserve that
;; file separation on two root-owned tmpfs mounts rather than merging concurrent
;; writers into a FIFO.  The debug and panic mounts have independent byte and
;; inode quotas, so debug exhaustion cannot consume the late-panic reserve.

(define-record-type <diagnostic-store>
  (make-diagnostic-store label path source capacity-bytes max-files identity)
  diagnostic-store?
  (label diagnostic-store-label)
  (path diagnostic-store-path)
  (source diagnostic-store-source)
  (capacity-bytes diagnostic-store-capacity-bytes)
  (max-files diagnostic-store-max-files)
  (identity diagnostic-store-identity))

(define-record-type <diagnostic-store-observation>
  (make-diagnostic-store-observation store entries source-bytes allocated-bytes
                                     invalid-entry? byte-exhausted?
                                     inode-exhausted?)
  diagnostic-store-observation?
  (store diagnostic-store-observation-store)
  (entries diagnostic-store-observation-entries)
  (source-bytes diagnostic-store-observation-source-bytes)
  (allocated-bytes diagnostic-store-observation-allocated-bytes)
  (invalid-entry? diagnostic-store-observation-invalid-entry?)
  (byte-exhausted? diagnostic-store-observation-byte-exhausted?)
  (inode-exhausted? diagnostic-store-observation-inode-exhausted?))

(define-record-type <bounded-capture>
  (make-bounded-capture stream input output observed-bytes retained-bytes
                        overflow? eof?)
  bounded-capture?
  (stream bounded-capture-stream)
  (input bounded-capture-input)
  (output bounded-capture-output)
  (observed-bytes bounded-capture-observed-bytes
                  set-bounded-capture-observed-bytes!)
  (retained-bytes bounded-capture-retained-bytes
                  set-bounded-capture-retained-bytes!)
  (overflow? bounded-capture-overflow? set-bounded-capture-overflow?!)
  (eof? bounded-capture-eof? set-bounded-capture-eof?!))

(define-record-type <command-result>
  (make-command-result status stdout-observed-bytes stderr-observed-bytes
                       stdout-overflow? stderr-overflow?)
  command-result?
  (status command-result-status)
  (stdout-observed-bytes command-result-stdout-observed-bytes)
  (stderr-observed-bytes command-result-stderr-observed-bytes)
  (stdout-overflow? command-result-stdout-overflow?)
  (stderr-overflow? command-result-stderr-overflow?))

(define guile-smoke
  "(use-modules (ice-9 binary-ports) (rnrs bytevectors))\n(define data (call-with-input-file \"/book/input\" get-bytevector-all))\n(call-with-output-file \"/scratch/book-size\" (lambda (port) (display (bytevector-length data) port)))\n(let ((sock (socket AF_INET SOCK_STREAM 0)))\n  (dynamic-wind\n    (lambda () #t)\n    (lambda ()\n      (catch 'system-error\n        (lambda ()\n          (connect sock AF_INET (inet-pton AF_INET \"192.0.2.1\") 9)\n          (error \"external network unexpectedly reachable\"))\n        (lambda arguments #t)))\n    (lambda () (close-port sock))))\n(format #t \"BOOKEXEC-PAYLOAD-GUILE book-bytes=~a~%\" (bytevector-length data))\n(force-output)\n")

(define (guile-process-arguments)
  (vector "/profile/bin/guile" "--no-auto-compile" "-c" guile-smoke))

(define (fail message)
  (throw 'book-execution-guest-smoke-error message))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (read-all path)
  (call-with-input-file path get-string-all))

(define (read-first-line path)
  (call-with-input-file path read-line))

(define (emit marker)
  (unless console-port
    (set! console-port (open-file "/dev/console" "w")))
  (display marker console-port)
  (newline console-port)
  (force-output console-port))

(define (close-port-if-open port)
  (unless (port-closed? port) (close-port port)))

(define (read-byte-range path start count)
  (if (zero? count)
      (make-bytevector 0)
      (let ((port (open-file path "rb")))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (seek port start SEEK_SET)
            (let ((value (get-bytevector-n port count)))
              (if (eof-object? value) (make-bytevector 0) value)))
          (lambda () (close-port-if-open port))))))

(define (write-escaped-bytevector value port)
  ;; Keep every source newline escaped and prefix every rendered line.  A
  ;; captured child log therefore cannot forge an exact serial PASS marker or
  ;; inject a terminal control sequence.  Worst-case expansion is five bytes
  ;; per source byte and the source ranges are fixed below.
  (display "| " port)
  (let ((length (bytevector-length value)))
    (let loop ((index 0))
      (when (< index length)
        (let ((byte (bytevector-u8-ref value index)))
          (cond
           ((= byte 10)
            (display "\\n" port)
            (when (< (+ index 1) length)
              (newline port)
              (display "| " port)))
           ((= byte 13) (display "\\r" port))
           ((= byte 9) (display "\\t" port))
           ((= byte 92) (display "\\\\" port))
           ((and (>= byte 32) (<= byte 126))
            (write-char (integer->char byte) port))
           (else
            (let ((hex "0123456789abcdef"))
              (display "\\x" port)
              (write-char (string-ref hex (quotient byte 16)) port)
              (write-char (string-ref hex (modulo byte 16)) port))))
          (loop (+ index 1)))))
    (newline port)))

(define (diagnostic-console-port)
  (unless console-port
    (set! console-port (open-file "/dev/console" "w")))
  console-port)

(define (emit-bounded-file-diagnostic label path)
  ;; Diagnostics are emitted only after runsc's writers have stopped and before
  ;; the Shepherd-owned fixture requests shutdown.  The source file can be up
  ;; to max-capture-bytes, but serial output includes only fixed head/tail
  ;; ranges.
  (let ((port (diagnostic-console-port)))
    (catch #t
      (lambda ()
        (let ((info (lstat-or-false path)))
          (cond
           ((not info)
            (format port
                    "BOOKEXEC-DIAGNOSTIC label=~a state=missing~%" label))
           ((not (eq? (stat:type info) 'regular))
            (format port
                    "BOOKEXEC-DIAGNOSTIC label=~a state=non-regular~%" label))
           (else
            (let ((size (stat:size info)))
              (format port
                      "BOOKEXEC-DIAGNOSTIC-BEGIN label=~a source-bytes=~a~%"
                      label size)
              (if (<= size (+ diagnostic-head-bytes diagnostic-tail-bytes))
                  (let ((content (read-byte-range path 0 size)))
                    (format port
                            "BOOKEXEC-DIAGNOSTIC-CONTENT bytes=~a~%"
                            (bytevector-length content))
                    (write-escaped-bytevector content port))
                  (let ((head (read-byte-range path 0 diagnostic-head-bytes))
                        (tail (read-byte-range
                               path (- size diagnostic-tail-bytes)
                               diagnostic-tail-bytes)))
                    (format port "BOOKEXEC-DIAGNOSTIC-HEAD bytes=~a~%"
                            (bytevector-length head))
                    (write-escaped-bytevector head port)
                    (format port "BOOKEXEC-DIAGNOSTIC-ELIDED bytes=~a~%"
                            (- size (bytevector-length head)
                               (bytevector-length tail)))
                    (format port "BOOKEXEC-DIAGNOSTIC-TAIL bytes=~a~%"
                            (bytevector-length tail))
                    (write-escaped-bytevector tail port)))
              (format port "BOOKEXEC-DIAGNOSTIC-END label=~a~%" label))))))
      (lambda (key . arguments)
        ;; Instrumentation must never replace the original runsc failure.
        (format port
                "BOOKEXEC-DIAGNOSTIC label=~a state=unavailable error=~s ~s~%"
                label key arguments)))
    (force-output port)))

(define (emit-runsc-log-directory-diagnostics directory directory-label
                                               file-label max-files)
  (let ((port (diagnostic-console-port)))
    (catch #t
      (lambda ()
        (let ((info (lstat-or-false directory)))
          (cond
           ((not info)
             (format port
                     "BOOKEXEC-DIAGNOSTIC-DIRECTORY label=~a state=missing~%"
                     directory-label))
            ((not (eq? (stat:type info) 'directory))
             (format port
                     "BOOKEXEC-DIAGNOSTIC-DIRECTORY label=~a state=non-directory~%"
                     directory-label))
            (else
             (let* ((names (sort
                           (filter (lambda (name)
                                     (not (member name '("." ".."))))
                                    (scandir directory))
                            string<?))
                    (selected (take names (min (length names)
                                               max-files))))
               (format port
                       "BOOKEXEC-DIAGNOSTIC-DIRECTORY label=~a entries=~a emitted=~a limit=~a~%"
                       directory-label (length names) (length selected)
                       max-files)
               (for-each
                (lambda (name index)
                 ;; The directory is trusted root-owned fixture state, but keep
                 ;; its generated filename in the escaped data channel too.
                 (let ((name-bytes (string->utf8 name)))
                   (format port
                           "BOOKEXEC-DIAGNOSTIC-FILENAME index=~a source-bytes=~a~%"
                           index (bytevector-length name-bytes))
                   (write-escaped-bytevector name-bytes port))
                  (emit-bounded-file-diagnostic
                   (format #f "~a-~a" file-label index)
                   (string-append directory "/" name)))
                selected
               (iota (length selected))))))))
      (lambda (key . arguments)
        (format port
                "BOOKEXEC-DIAGNOSTIC-DIRECTORY label=~a state=unavailable error=~s ~s~%"
                directory-label key arguments)))
    (force-output port)))

(define (emit-runsc-debug-diagnostics directory)
  (emit-runsc-log-directory-diagnostics
   directory "runsc-debug" "runsc-debug" max-direct-debug-log-files))

(define (emit-runsc-panic-diagnostics directory)
  (emit-runsc-log-directory-diagnostics
   directory "runsc-panic" "runsc-panic" max-panic-log-files))

(define (network-interface-set-safe? names)
  (equal? (sort (delete-duplicates names) string<? ) '("lo")))

(define (network-interfaces)
  (filter (lambda (name) (not (member name '("." ".."))))
          (scandir "/sys/class/net")))

(define (ipv4-default-route? text)
  (any
   (lambda (line)
     (let ((fields (string-tokenize line)))
       (and (>= (length fields) 8)
            (string=? (list-ref fields 1) "00000000")
            (string=? (list-ref fields 7) "00000000"))))
   (string-split text #\newline)))

(define-record-type <mountinfo>
  (make-mountinfo line device root point options type source super-options)
  mountinfo?
  (line mountinfo-line)
  (device mountinfo-device)
  (root mountinfo-root)
  (point mountinfo-point)
  (options mountinfo-options)
  (type mountinfo-type)
  (source mountinfo-source)
  (super-options mountinfo-super-options))

(define (decimal-string? value)
  (and (not (string-null? value))
       (every char-numeric? (string->list value))))

(define (device-token? value)
  (match (string-split value #\:)
    ((major minor) (and (decimal-string? major) (decimal-string? minor)))
    (_ #f)))

(define (mountinfo-unescape value)
  (define (octal-digit? character)
    (and (char>=? character #\0) (char<=? character #\7)))
  (let loop ((characters (string->list value)) (result '()))
    (match characters
      (() (list->string (reverse result)))
      ((#\\ (? octal-digit? a) (? octal-digit? b) (? octal-digit? c) . rest)
       (loop rest
             (cons (integer->char
                    (string->number (list->string (list a b c)) 8))
                   result)))
      ((head . rest) (loop rest (cons head result))))))

(define (parse-mountinfo-line line)
  ;; Linux mountinfo has six fixed fields, zero or more optional fields, one
  ;; separator, then exactly filesystem type, source, and superblock options.
  (let* ((fields (string-tokenize line))
         (separator (list-index (lambda (field) (string=? field "-")) fields)))
    (and separator
         (>= separator 6)
         (= (- (length fields) separator 1) 3)
         (decimal-string? (list-ref fields 0))
         (decimal-string? (list-ref fields 1))
         (device-token? (list-ref fields 2))
         (make-mountinfo
          line
          (list-ref fields 2)
          (mountinfo-unescape (list-ref fields 3))
          (mountinfo-unescape (list-ref fields 4))
          (string-split (list-ref fields 5) #\,)
          (list-ref fields (+ separator 1))
          (mountinfo-unescape (list-ref fields (+ separator 2)))
          (string-split (list-ref fields (+ separator 3)) #\,)))))

(define (path-at-or-under? path parent)
  (or (string=? path parent)
      (string-prefix? (string-append parent "/") path)))

(define (guix-store-self-bind? mount root)
  ;; %immutable-store in the pinned Guix binds /gnu/store onto itself with
  ;; MS_RDONLY.  A bind mount keeps the root filesystem's superblock identity;
  ;; require all of that evidence rather than broadly allowing this mountpoint.
  (and (string=? (mountinfo-point mount) "/gnu/store")
       (string=? (mountinfo-root mount) "/gnu/store")
       (member "ro" (mountinfo-options mount))
       (not (member "rw" (mountinfo-options mount)))
       (string=? (mountinfo-device mount) (mountinfo-device root))
       (string=? (mountinfo-type mount) (mountinfo-type root))
       (string=? (mountinfo-source mount) (mountinfo-source root))))

(define (mountinfo-entry-violation mount root)
  (cond
   ;; Reject host-sharing filesystem classes wherever they are mounted; their
   ;; mountpoint names are not a security boundary.
   ((member (mountinfo-type mount) '("9p" "virtiofs" "nfs" "nfs4"))
    'host-share-filesystem)
   ((path-at-or-under? (mountinfo-point mount) "/data") 'data-mount)
   ((path-at-or-under? (mountinfo-point mount) "/gnu/store")
    (and (not (guix-store-self-bind? mount root)) 'non-guix-store-mount))
   (else #f)))

(define (mountinfo-lines-violation lines)
  ;; Return (REASON OFFENDING-LINE ROOT), or #f.  Malformed input fails closed
  ;; and is still carried into the bounded diagnostic below.
  (let* ((lines (filter (lambda (line) (not (string-null? line))) lines))
         (parsed (map (lambda (line) (cons line (parse-mountinfo-line line)))
                      lines))
         (malformed (find (lambda (entry) (not (cdr entry))) parsed)))
    (cond
     (malformed (list 'malformed-mountinfo (car malformed) #f))
     (else
      (let ((roots (filter (lambda (entry)
                             (string=? (mountinfo-point (cdr entry)) "/"))
                           parsed)))
        (if (not (= (length roots) 1))
            (list 'ambiguous-root-mount
                  (if (null? roots) "<no root mount>" (caar roots))
                  (and (pair? roots) (cdar roots)))
            (let* ((root (cdar roots))
                   (bad (any
                         (lambda (entry)
                           (let ((reason
                                  (mountinfo-entry-violation (cdr entry) root)))
                             (and reason (list reason (car entry) root))))
                         parsed)))
              bad)))))))

(define (bounded-escaped-line line)
  (let* ((bytes (string->utf8 line))
         (source-length (bytevector-length bytes))
         (length (min source-length max-mount-diagnostic-bytes))
         (hex "0123456789abcdef"))
    (call-with-output-string
      (lambda (port)
        (let loop ((index 0))
          (when (< index length)
            (let ((byte (bytevector-u8-ref bytes index)))
              (cond
               ((= byte 92) (display "\\\\" port))
               ((and (>= byte 32) (<= byte 126))
                (write-char (integer->char byte) port))
               (else
                (display "\\x" port)
                (write-char (string-ref hex (quotient byte 16)) port)
                (write-char (string-ref hex (modulo byte 16)) port)))
              (loop (+ index 1)))))
        (when (< length source-length)
          (format port "...[truncated source-bytes=~a]" source-length))))))

(define (forbidden-host-mount? line root-line)
  ;; Small public predicate for host fixtures.  Parsing failures and a supplied
  ;; non-root reference fail closed.
  (let ((mount (parse-mountinfo-line line))
        (root (parse-mountinfo-line root-line)))
    (or (not mount)
        (not root)
        (not (string=? (mountinfo-point root) "/"))
        (and (mountinfo-entry-violation mount root) #t))))

(define (assert-mount-boundaries text)
  (let ((violation
         (mountinfo-lines-violation (string-split text #\newline))))
    (when violation
      (match violation
        ((reason line root)
         (fail
          (format #f
                  "guest exposes a forbidden host/share mount: reason=~a root-device=~a root-type=~a line=~a"
                  reason
                  (if root (mountinfo-device root) "unknown")
                  (if root (mountinfo-type root) "unknown")
                  (bounded-escaped-line line))))))))

(define (assert-host-boundaries)
  (unless (network-interface-set-safe? (network-interfaces))
    (fail (format #f "unexpected network interfaces: ~s" (network-interfaces))))
  (when (ipv4-default-route? (read-all "/proc/net/route"))
    (fail "guest has an IPv4 default route"))
  (emit "BOOKEXEC-NETWORK-ABSENT-PASS")
  (assert-mount-boundaries (read-all "/proc/self/mountinfo"))
  (for-each
   (lambda (path)
     (when (lstat-or-false path)
       (fail (string-append "guest exposes forbidden path: " path))))
   '("/dev/kvm"
     "/var/guix/daemon-socket/socket"
     "/run/guix/daemon-socket/socket"))
  (emit "BOOKEXEC-FORBIDDEN-MOUNTS-PASS"))

(define (monotonic-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (status->exit-code status)
  (or (status:exit-val status)
      (let ((signal-number (status:term-sig status)))
        (if signal-number (logior #x80 signal-number) 1))))

(define (group-exists? process-group)
  (catch 'system-error
    (lambda () (kill (- process-group) 0) #t)
    (lambda arguments
      (not (= ESRCH (system-error-errno arguments))))))

(define (signal-group process-group signal-number)
  (catch 'system-error
    (lambda () (kill (- process-group) signal-number))
    (lambda arguments
      (unless (= ESRCH (system-error-errno arguments))
        (apply throw 'system-error arguments)))))

(define (wait-group-gone process-group seconds)
  (let ((deadline (+ (monotonic-seconds) seconds)))
    (let loop ()
      (catch 'system-error
        (lambda () (waitpid process-group WNOHANG) #t)
        (lambda arguments
          (unless (member (system-error-errno arguments) (list ECHILD EINTR))
            (apply throw 'system-error arguments))))
      (cond
       ((not (group-exists? process-group)) #t)
       ((>= (monotonic-seconds) deadline) #f)
       (else (usleep 20000) (loop))))))

(define (terminate-group process-group)
  (when (group-exists? process-group)
    (signal-group process-group SIGTERM)
    (wait-group-gone process-group process-term-grace-seconds))
  (when (group-exists? process-group)
    (signal-group process-group SIGKILL))
  (unless (wait-group-gone process-group process-term-grace-seconds)
    (fail (format #f "owned process group ~a survived SIGKILL" process-group))))

(define (open-capture path)
  (fdopen
   (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC) #o600)
   "wb"))

(define (mark-fd-close-on-exec fd)
  (let ((flags (fcntl fd F_GETFD)))
    (unless (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))

(define (cloexec-pipe)
  (let ((ports (pipe)))
    (mark-fd-close-on-exec (fileno (car ports)))
    (mark-fd-close-on-exec (fileno (cdr ports)))
    ports))

(define (mark-inherited-fds-close-on-exec)
  ;; No Book Protocol descriptor exists in this compatibility fixture.  Keep
  ;; every unrelated descriptor above stderr out of runsc and its payloads.
  (for-each
   (lambda (name)
     (let ((fd (string->number name)))
       (when (and fd (> fd 2))
         (catch 'system-error
           (lambda ()
             (let ((flags (fcntl fd F_GETFD)))
               (unless (positive? (logand flags FD_CLOEXEC))
                 (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))
           (lambda arguments
             (unless (= EBADF (system-error-errno arguments))
               (apply throw 'system-error arguments)))))))
   (scandir "/proc/self/fd"
            (lambda (name) (and (string->number name) #t)))))

(define (spawn-command argv environment directory stdout-path stderr-path)
  ;; Keep output limits in this Guile supervisor.  A process-wide RLIMIT_FSIZE
  ;; would also constrain unrelated files opened later by runsc and Sentry.
  (let* ((stdout-pipe (cloexec-pipe))
         (stderr-pipe (cloexec-pipe))
         (stdout-input (car stdout-pipe))
         (stdout-output (cdr stdout-pipe))
         (stderr-input (car stderr-pipe))
         (stderr-output (cdr stderr-pipe))
         (stdout-file (open-capture stdout-path))
         (stderr-file (open-capture stderr-path))
         (stdout-capture
          (make-bounded-capture 'stdout stdout-input stdout-file 0 0 #f #f))
         (stderr-capture
          (make-bounded-capture 'stderr stderr-input stderr-file 0 0 #f #f)))
    (let ((pid (primitive-fork)))
      (if (zero? pid)
          (catch #t
            (lambda ()
              (for-each (lambda (signal-number)
                          (sigaction signal-number SIG_DFL))
                        (list SIGINT SIGHUP SIGTERM SIGPIPE SIGCHLD))
              (setpgid 0 0)
              (chdir directory)
              (let ((null-fd (open-fdes "/dev/null"
                                        (logior O_RDONLY O_CLOEXEC))))
                (dup2 null-fd 0)
                (close-fdes null-fd))
              (close-port-if-open stdout-input)
              (close-port-if-open stderr-input)
              (close-port-if-open stdout-file)
              (close-port-if-open stderr-file)
              (dup2 (fileno stdout-output) 1)
              (dup2 (fileno stderr-output) 2)
              (close-port-if-open stdout-output)
              (close-port-if-open stderr-output)
              (mark-inherited-fds-close-on-exec)
              (environ environment)
              (apply execl (car argv) argv))
            (lambda arguments
              (primitive-exit 127)))
          (begin
            (close-port-if-open stdout-output)
            (close-port-if-open stderr-output)
            (catch 'system-error
              (lambda () (setpgid pid pid))
              (lambda arguments
                (unless (member (system-error-errno arguments)
                                (list EACCES ESRCH))
                  (apply throw 'system-error arguments))))
            (list pid stdout-capture stderr-capture))))))

(define (capture-readable! capture)
  (let ((value (get-bytevector-some (bounded-capture-input capture))))
    (if (eof-object? value)
        (set-bounded-capture-eof?! capture #t)
        (let* ((count (bytevector-length value))
               (retained (bounded-capture-retained-bytes capture))
               (remaining (max 0 (- max-capture-bytes retained)))
               (keep (min count remaining)))
          (when (positive? keep)
            (put-bytevector (bounded-capture-output capture) value 0 keep))
          (set-bounded-capture-observed-bytes!
           capture (+ (bounded-capture-observed-bytes capture) count))
          (set-bounded-capture-retained-bytes! capture (+ retained keep))
          (when (> count remaining)
            (set-bounded-capture-overflow?! capture #t))))))

(define (pump-captures captures microseconds)
  (let ((live (filter (lambda (capture)
                        (not (bounded-capture-eof? capture)))
                      captures)))
    (if (null? live)
        (usleep microseconds)
        (match (select (map bounded-capture-input live) '() '()
                       0 microseconds)
          ((readable () ())
           (for-each
            (lambda (capture)
              (when (memq (bounded-capture-input capture) readable)
                (capture-readable! capture)))
            live))))))

(define (finalize-captures! captures)
  ;; The owned process group is gone before this runs, so every pipe should
  ;; reach EOF.  Keep this phase bounded in case a future child leaks a writer
  ;; outside that group; close locally and fail rather than hanging shutdown.
  (let ((deadline (+ (monotonic-seconds) process-term-grace-seconds)))
    (let loop ()
      (unless (every bounded-capture-eof? captures)
        (when (>= (monotonic-seconds) deadline)
          (for-each
           (lambda (capture)
             (close-port-if-open (bounded-capture-input capture))
             (close-port-if-open (bounded-capture-output capture)))
           captures)
          (fail "capture pipe remained open after owned process-group cleanup"))
        (pump-captures captures 20000)
        (loop))))
  (for-each
   (lambda (capture)
     (force-output (bounded-capture-output capture))
     (close-port-if-open (bounded-capture-input capture))
     (close-port-if-open (bounded-capture-output capture)))
   captures))

(define (wait-command pid captures)
  (let ((deadline (+ (monotonic-seconds) process-timeout-seconds)))
    (let loop ()
      (let ((result
             (catch 'system-error
               (lambda () (waitpid pid WNOHANG))
               (lambda arguments
                 (if (= EINTR (system-error-errno arguments))
                     '(0 . 0)
                     (apply throw 'system-error arguments))))))
        (cond
         ((not (zero? (car result))) (status->exit-code (cdr result)))
         ((>= (monotonic-seconds) deadline)
          (terminate-group pid)
          (fail (format #f "guest command exceeded ~a second timeout"
                        process-timeout-seconds)))
         (else (pump-captures captures 20000) (loop)))))))

(define (run-command argv environment directory stdout-path stderr-path)
  (match (spawn-command argv environment directory stdout-path stderr-path)
    ((pid stdout-capture stderr-capture)
     (let ((captures (list stdout-capture stderr-capture))
           (status #f))
       (dynamic-wind
         (lambda () #t)
         (lambda ()
           (set! status (wait-command pid captures)))
         (lambda ()
           (terminate-group pid)
           (catch 'system-error
             (lambda () (waitpid pid WNOHANG) #t)
             (lambda arguments
               (unless (member (system-error-errno arguments)
                               (list ECHILD EINTR))
                 (apply throw 'system-error arguments))))
           (finalize-captures! captures)))
       (make-command-result
         status
         (bounded-capture-observed-bytes stdout-capture)
         (bounded-capture-observed-bytes stderr-capture)
         (bounded-capture-overflow? stdout-capture)
         (bounded-capture-overflow? stderr-capture))))))

(define (command-result-capture-overflow? result)
  (or (command-result-stdout-overflow? result)
      (command-result-stderr-overflow? result)))

(define (capture-overflow-summary result)
  (string-join
   (filter-map
    (lambda (stream observed overflow?)
      (and overflow?
           (format #f "~a observed-bytes=~a retained-bytes=~a limit-bytes=~a"
                   stream observed max-capture-bytes max-capture-bytes)))
    '(stdout stderr)
    (list (command-result-stdout-observed-bytes result)
          (command-result-stderr-observed-bytes result))
    (list (command-result-stdout-overflow? result)
          (command-result-stderr-overflow? result)))
   "; "))

(define (command-result-observation result)
  ;; Narrow host-test view; callers cannot mutate the supervision result.
  `(("status" . ,(command-result-status result))
    ("stdout_observed" . ,(command-result-stdout-observed-bytes result))
    ("stderr_observed" . ,(command-result-stderr-observed-bytes result))
    ("stdout_overflow" . ,(command-result-stdout-overflow? result))
    ("stderr_overflow" . ,(command-result-stderr-overflow? result))
    ("summary" . ,(capture-overflow-summary result))))

(define (emit-capture-overflow-diagnostics result)
  (for-each
   (lambda (stream observed overflow?)
     (when overflow?
       (emit
        (format #f
                "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW stream=~a observed-bytes=~a retained-bytes=~a limit-bytes=~a"
                stream observed max-capture-bytes max-capture-bytes))))
   '(stdout stderr)
   (list (command-result-stdout-observed-bytes result)
         (command-result-stderr-observed-bytes result))
   (list (command-result-stdout-overflow? result)
         (command-result-stderr-overflow? result))))

(define (assert-command-captures-complete label result)
  (when (command-result-capture-overflow? result)
    (fail (format #f "~a capture overflow: ~a"
                  label (capture-overflow-summary result)))))

(define (bounded-output path)
  (let ((info (lstat path)))
    (when (> (stat:size info) max-capture-bytes)
      (fail (string-append "capture exceeds fixed bound: " path)))
    (read-all path)))

(define (directory-entry-names path)
  (filter (lambda (name) (not (member name '("." ".."))))
          (scandir path)))

(define (same-file-identity? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (assert-private-empty-diagnostic-directory path)
  (let ((info (lstat-or-false path)))
    (unless (and info
                 (eq? (stat:type info) 'directory)
                 (= (logand (stat:mode info) #o7777) #o700)
                 (zero? (stat:uid info))
                 (zero? (stat:gid info))
                 (null? (directory-entry-names path)))
      (fail (string-append
             "diagnostic store mountpoint must be an empty root-owned mode-0700 directory: "
             path)))
    info))

(define (diagnostic-stores bundle)
  (unless (and (positive? debug-store-bytes)
               (positive? panic-store-bytes)
               (zero? (modulo debug-store-bytes 1024))
               (zero? (modulo panic-store-bytes 1024))
               (positive? max-direct-debug-log-files)
               (positive? max-panic-log-files)
               (<= (+ max-direct-debug-log-files max-panic-log-files)
                   max-debug-log-files))
    (fail "invalid fixed diagnostic store quotas"))
  (for-each
   (lambda (path)
     (when (pair? (mountinfo-at path))
       (fail (string-append "refusing pre-mounted diagnostic store: " path))))
   (list (string-append bundle "/runsc-debug")
         (string-append bundle "/runsc-panic")))
  (list
   (make-diagnostic-store
    'runsc-debug (string-append bundle "/runsc-debug")
    "wilkbook-runsc-debug" debug-store-bytes max-direct-debug-log-files
    (assert-private-empty-diagnostic-directory
     (string-append bundle "/runsc-debug")))
   (make-diagnostic-store
    'runsc-panic (string-append bundle "/runsc-panic")
    "wilkbook-runsc-panic" panic-store-bytes max-panic-log-files
    (assert-private-empty-diagnostic-directory
     (string-append bundle "/runsc-panic")))))

(define (mountinfo-at path)
  (filter-map
   (lambda (line)
     (let ((entry (parse-mountinfo-line line)))
       (and entry (string=? (mountinfo-point entry) path) entry)))
   (string-split (read-all "/proc/self/mountinfo") #\newline)))

(define (diagnostic-store-mounted? store)
  (match (mountinfo-at (diagnostic-store-path store))
    ((entry)
     (let ((expected-size
            (format #f "size=~ak"
                    (quotient (diagnostic-store-capacity-bytes store) 1024)))
           (expected-inodes
            (format #f "nr_inodes=~a"
                    (+ 1 (diagnostic-store-max-files store)))))
       (and (string=? (mountinfo-type entry) "tmpfs")
            (string=? (mountinfo-source entry)
                      (diagnostic-store-source store))
            (every (lambda (option) (member option (mountinfo-options entry)))
                   '("rw" "nosuid" "nodev" "noexec"))
            (member expected-size (mountinfo-super-options entry))
            (member expected-inodes (mountinfo-super-options entry)))))
    (_ #f)))

(define (run-fixed-utility label argv bundle)
  (let* ((stdout (string-append bundle "/." label ".stdout"))
         (stderr (string-append bundle "/." label ".stderr"))
         (result
          (run-command argv
                       '("HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                         "PATH=/run/current-system/profile/bin")
                       bundle stdout stderr)))
    (assert-command-captures-complete label result)
    (unless (zero? (command-result-status result))
      (fail
       (format #f "~a failed with status ~a: ~a"
               label (command-result-status result) (bounded-output stderr))))))

(define (mount-diagnostic-store! store bundle)
  (let ((options
         (format #f
                 "rw,nosuid,nodev,noexec,size=~a,nr_inodes=~a,mode=0700,uid=0,gid=0"
                 (diagnostic-store-capacity-bytes store)
                 (+ 1 (diagnostic-store-max-files store)))))
    (run-fixed-utility
     (string-append "mount-" (symbol->string (diagnostic-store-label store)))
     (list mount-program "-n" "-t" "tmpfs" "-o" options
           (diagnostic-store-source store) (diagnostic-store-path store))
     bundle)
    (unless (diagnostic-store-mounted? store)
      (fail
       (format #f "diagnostic store mount verification failed: ~a"
               (diagnostic-store-label store))))
    (let ((info (lstat (diagnostic-store-path store))))
      (unless (and (eq? (stat:type info) 'directory)
                   (= (logand (stat:mode info) #o7777) #o700)
                   (zero? (stat:uid info))
                   (zero? (stat:gid info)))
        (fail
         (format #f "diagnostic store mount is not private: ~a"
                 (diagnostic-store-label store)))))))

(define (unmount-diagnostic-store! store bundle)
  (when (pair? (mountinfo-at (diagnostic-store-path store)))
    (run-fixed-utility
     (string-append "unmount-" (symbol->string (diagnostic-store-label store)))
     (list umount-program "-n" (diagnostic-store-path store))
     bundle))
  (when (pair? (mountinfo-at (diagnostic-store-path store)))
    (fail
     (format #f "diagnostic store remained mounted: ~a"
             (diagnostic-store-label store))))
  (let ((info (lstat-or-false (diagnostic-store-path store))))
    (unless (and info
                 (same-file-identity? info (diagnostic-store-identity store))
                 (null? (directory-entry-names (diagnostic-store-path store))))
      (fail
       (format #f "diagnostic store mountpoint identity/contents changed: ~a"
               (diagnostic-store-label store))))
    (rmdir (diagnostic-store-path store))))

(define (cleanup-diagnostic-stores! stores bundle)
  (let ((errors '()))
    (for-each
     (lambda (store)
       (catch #t
         (lambda () (unmount-diagnostic-store! store bundle))
         (lambda arguments
           (set! errors
                 (cons (format #f "~a: ~s"
                               (diagnostic-store-label store) arguments)
                       errors)))))
     (reverse stores))
    (unless (null? errors)
      (fail (string-append "diagnostic store cleanup failed: "
                           (string-join (reverse errors) "; "))))))

(define (mount-diagnostic-stores! bundle)
  (let ((stores (diagnostic-stores bundle)))
    (catch #t
      (lambda ()
        (for-each (lambda (store) (mount-diagnostic-store! store bundle))
                  stores)
        stores)
      (lambda arguments
        ;; Inspect every intended mountpoint: a helper failure after mount(2)
        ;; must not strand that mount, and untouched empty mountpoints are
        ;; identity-checked and removed too.
        (cleanup-diagnostic-stores! stores bundle)
        (apply throw arguments)))))

(define diagnostic-store-setup! mount-diagnostic-stores!)
(define diagnostic-store-cleanup! cleanup-diagnostic-stores!)

(define (call-with-diagnostic-stores bundle thunk)
  (let ((stores #f))
    (dynamic-wind
      (lambda () (set! stores (diagnostic-store-setup! bundle)))
      (lambda () (thunk stores))
      (lambda ()
        (when stores (diagnostic-store-cleanup! stores bundle))))))

(define (observe-diagnostic-store store)
  (unless (diagnostic-store-mounted? store)
    (fail
     (format #f "diagnostic store disappeared during run: ~a"
             (diagnostic-store-label store))))
  (let* ((names (directory-entry-names (diagnostic-store-path store)))
         (infos
          (map (lambda (name)
                 (lstat (string-append (diagnostic-store-path store) "/" name)))
               names))
         (regular (filter (lambda (info) (eq? (stat:type info) 'regular))
                          infos))
         (source-bytes (fold + 0 (map stat:size regular)))
         (allocated-bytes
          (fold + 0 (map (lambda (info) (* 512 (stat:blocks info))) regular)))
         (entries (length names))
         (capacity (diagnostic-store-capacity-bytes store))
         (max-files (diagnostic-store-max-files store)))
    (make-diagnostic-store-observation
     store entries source-bytes allocated-bytes
     (not (= (length regular) entries))
     (or (> source-bytes capacity) (>= allocated-bytes capacity))
     (>= entries max-files))))

(define (diagnostic-store-observation-overflow? observation)
  (or (diagnostic-store-observation-invalid-entry? observation)
      (diagnostic-store-observation-byte-exhausted? observation)
      (diagnostic-store-observation-inode-exhausted? observation)))

(define (emit-diagnostic-store-observation observation)
  (let* ((store (diagnostic-store-observation-store observation))
         (overflow? (diagnostic-store-observation-overflow? observation)))
    (emit
     (format #f
             "BOOKEXEC-DIAGNOSTIC-STORE label=~a entries=~a file-limit=~a source-bytes=~a allocated-bytes=~a capacity-bytes=~a invalid-entry=~a byte-exhausted=~a inode-exhausted=~a overflow=~a"
             (diagnostic-store-label store)
             (diagnostic-store-observation-entries observation)
             (diagnostic-store-max-files store)
             (diagnostic-store-observation-source-bytes observation)
             (diagnostic-store-observation-allocated-bytes observation)
             (diagnostic-store-capacity-bytes store)
             (diagnostic-store-observation-invalid-entry? observation)
             (diagnostic-store-observation-byte-exhausted? observation)
             (diagnostic-store-observation-inode-exhausted? observation)
             overflow?))
    (when overflow?
      (emit
       (format #f
               "BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW label=~a"
               (diagnostic-store-label store))))))

(define (observe-diagnostic-stores stores)
  (map observe-diagnostic-store stores))

(define (diagnostic-stores-overflow? observations)
  (any diagnostic-store-observation-overflow? observations))

(define (call-secondary-diagnostic label thunk)
  ;; Diagnostics must not replace the command failure being diagnosed.  Keep a
  ;; secondary diagnostic error bounded and escaped as well; a broken console
  ;; is allowed to suppress only this subordinate report.
  (catch #t
    thunk
    (lambda (key . arguments)
      (catch #t
        (lambda ()
          (emit
           (format #f
                   "BOOKEXEC-DIAGNOSTIC-STORE state=unavailable scope=~a error=~a"
                   label
                   (bounded-escaped-line
                    (format #f "~s ~s" key arguments)))))
        (lambda _ #f)))))

(define (emit-diagnostic-store-evidence bundle stores observations
                                        include-files?)
  ;; On an execution exception OBSERVATIONS may not have been computed yet.
  ;; Inspect each still-mounted store independently so one secondary failure
  ;; cannot suppress the other store, then render each bounded file channel.
  (if observations
      (for-each
       (lambda (observation)
         (call-secondary-diagnostic
          (diagnostic-store-label
           (diagnostic-store-observation-store observation))
          (lambda () (emit-diagnostic-store-observation observation))))
       observations)
      (for-each
       (lambda (store)
         (call-secondary-diagnostic
          (diagnostic-store-label store)
          (lambda ()
            (emit-diagnostic-store-observation
             (observe-diagnostic-store store)))))
       stores))
  (when include-files?
    (call-secondary-diagnostic
     'runsc-debug-files
     (lambda ()
       (emit-runsc-debug-diagnostics (string-append bundle "/runsc-debug"))))
    (call-secondary-diagnostic
     'runsc-panic-files
     (lambda ()
       (emit-runsc-panic-diagnostics (string-append bundle "/runsc-panic"))))))

(define (expected-payload-output language expected-book-bytes)
  (unless (and (integer? expected-book-bytes) (>= expected-book-bytes 0))
    (fail "expected book byte count is invalid"))
  (string-append
   (case language
     ((python) "BOOKEXEC-PAYLOAD-PYTHON book-bytes=")
     ((guile) "BOOKEXEC-PAYLOAD-GUILE book-bytes=")
     (else (fail "unknown fixed payload language")))
   (number->string expected-book-bytes)
   "\n"))

(define (assert-payload-output language expected-book-bytes observed)
  (let ((expected (expected-payload-output language expected-book-bytes)))
    (unless (string=? observed expected)
      (fail
       (format #f "~a payload output mismatch: expected ~s, got ~s"
               language expected observed)))))

(define (alist-replace alist key value)
  (map (lambda (entry)
         (if (string=? (car entry) key) (cons key value) entry))
       alist))

(define (write-json path value)
  (call-with-output-file path
    (lambda (port)
      (scm->json value port
                 #:unicode #t
                 #:null 'null
                 #:validate #t
                 #:pretty #t)
      (newline port)))
  (chmod path #o600))

(define (select-guile-process bundle)
  (let* ((path (string-append bundle "/config.json"))
         (config (call-with-input-file path
                   (lambda (port) (json->scm port #:ordered #t))))
         (process (assoc-ref config "process"))
         (guile-environment
          #( "HOME=/scratch" "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
             "PATH=/profile/bin" "GUILE_AUTO_COMPILE=0"
             "TMPDIR=/scratch"))
         (updated-process
          (alist-replace
           (alist-replace process "args" (guile-process-arguments))
           "env" guile-environment)))
    (write-json path (alist-replace config "process" updated-process))))

(define (read-closure path)
  (let ((value (call-with-input-file path read)))
    (unless (and (list? value) (every string? value))
      (fail "language closure manifest is not a list of strings"))
    value))

(define (assert-kernel expected-release)
  (let ((observed (read-first-line "/proc/sys/kernel/osrelease")))
    (unless (string=? observed expected-release)
      (fail (format #f "kernel release mismatch: expected ~a, got ~a"
                    expected-release observed))))
  (emit "BOOKEXEC-KERNEL-IDENTITY-PASS"))

(define (assert-sidecar-layout)
  (let* ((bin "/run/current-system/profile/bin")
         (runsc-target (canonicalize-path (string-append bin "/runsc")))
         (package-bin (dirname runsc-target)))
    (for-each
     (lambda (relative)
       (let* ((path (string-append bin "/" relative))
              (target
               (catch 'system-error
                 (lambda () (canonicalize-path path))
                 (lambda arguments #f)))
              (info (and target (lstat-or-false target))))
         (unless (and info
                      (eq? (stat:type info) 'regular)
                      (positive? (logand (stat:mode info) #o111))
                      (string-prefix? (string-append package-bin "/") target))
           (fail (string-append "missing fixed gVisor executable: " path)))
         (emit
          (format #f
                  "BOOKEXEC-DIAGNOSTIC-GVISOR-EXECUTABLE name=~a target=~a mode-octal=~o"
                  relative target (logand (stat:mode info) #o7777)))))
     '("runsc"
       "containerd-shim-runsc-v1"
       "gvisor-bin/checkpointgofer"
       "gvisor-bin/gvisor-sentry-prewarmer"
       "gvisor-bin/gvisor_sentry"
       "gvisor-bin/runsc-metric-server"))))

(define (run-version work-root)
  (let* ((stdout (string-append work-root "/runsc-version.stdout"))
         (stderr (string-append work-root "/runsc-version.stderr"))
         (result
           (run-command
            '("/run/current-system/profile/bin/runsc" "--version")
            '("HOME=/nonexistent" "LANG=C" "LC_ALL=C"
              "PATH=/run/current-system/profile/bin")
            work-root stdout stderr))
         (status (command-result-status result)))
    (assert-command-captures-complete "runsc --version" result)
    (unless (zero? status)
      (fail (format #f "runsc --version failed with status ~a: ~a"
                    status (bounded-output stderr))))
    (let ((version (bounded-output stdout)))
      (unless (string-contains version expected-gvisor-release)
        (fail (string-append "runsc version does not match pinned release: "
                             version)))
      (emit
       (string-append "BOOKEXEC-DIAGNOSTIC-RUNSC-VERSION value="
                      (bounded-escaped-line version))))
    (emit "BOOKEXEC-RUNSC-VERSION-PASS")))

(define (path-present-state path)
  (catch 'system-error
    (lambda () (if (lstat path) "present" "absent"))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          "absent"
          "unavailable"))))

(define (capture-kernel-dmesg work-root)
  (let ((stdout (string-append work-root "/failure-dmesg.stdout"))
        (stderr (string-append work-root "/failure-dmesg.stderr")))
    (catch #t
      (lambda ()
         (let* ((result
                (run-command
                 '("/run/current-system/profile/bin/dmesg")
                 '("HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                   "PATH=/run/current-system/profile/bin")
                 work-root stdout stderr))
                (status (command-result-status result)))
           (emit (format #f
                         "BOOKEXEC-DIAGNOSTIC-DMESG-EXIT status=~a"
                         status))
           (emit-capture-overflow-diagnostics result)
           (emit-bounded-file-diagnostic "kernel-dmesg" stdout)
          (unless (zero? status)
            (emit-bounded-file-diagnostic "kernel-dmesg-stderr" stderr))))
      (lambda (key . arguments)
        (emit
         (format #f
                 "BOOKEXEC-DIAGNOSTIC-DMESG state=unavailable error=~s ~s"
                 key arguments))))))

(define (emit-runtime-failure-diagnostics bundle container-id result
                                           stdout stderr)
  ;; run-command has reaped or killed its owned process group by this point.
  ;; Preserve bounded evidence before the enclosing Shepherd process flushes,
  ;; syncs, and requests shutdown.  None of these diagnostics is a PASS marker.
  (catch #t
    (lambda ()
      (emit
       (format #f
               "BOOKEXEC-DIAGNOSTIC-RUNSC-EXIT container=~a status=~a cgroup=~a runtime-state=~a"
               container-id (command-result-status result)
               (path-present-state
                (string-append "/sys/fs/cgroup/wilkbook-execution-"
                               container-id))
                (path-present-state (string-append bundle "/runsc-state"))))
      (emit-capture-overflow-diagnostics result)
      (emit-bounded-file-diagnostic "runsc-stdout" stdout)
      (emit-bounded-file-diagnostic "runsc-support-stderr" stderr)
      (capture-kernel-dmesg (dirname bundle)))
    (lambda (key . arguments)
      (emit
       (format #f
               "BOOKEXEC-DIAGNOSTIC-RUNSC state=unavailable error=~s ~s"
               key arguments)))))

(define (run-bundle bundle container-id language expected-book-bytes marker)
  (call-with-diagnostic-stores
   bundle
   (lambda (stores)
     (let ((stdout (string-append bundle "/runsc.stdout"))
           (stderr (string-append bundle "/runsc.stderr"))
           (observations #f)
           (store-evidence-emitted? #f))
       (define (emit-store-evidence-once! include-files?)
         (unless store-evidence-emitted?
           ;; Set the guard first: even a secondary diagnostic exception must
           ;; not cause a duplicate report while the primary failure unwinds.
           (set! store-evidence-emitted? #t)
           (emit-diagnostic-store-evidence
            bundle stores observations include-files?)))
       (catch #t
         (lambda ()
           (let* ((result
                   (run-command
                    (list (string-append bundle "/run.sh"))
                    '("HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                      "PATH=/run/current-system/profile/bin")
                    bundle stdout stderr))
                  (status (command-result-status result)))
             ;; run-command has stopped/reaped its owned writers on every
             ;; return.  Keep the stores mounted through policy checks so any
             ;; exception can serialize their bounded evidence before cleanup.
             (set! observations (observe-diagnostic-stores stores))
             (let ((store-overflow?
                    (diagnostic-stores-overflow? observations)))
               (when (or (not (zero? status))
                         (command-result-capture-overflow? result)
                         store-overflow?)
                 (emit-store-evidence-once! #t)
                 (emit-runtime-failure-diagnostics
                  bundle container-id result stdout stderr)
                 (fail
                  (cond
                   (store-overflow?
                    (format #f
                            "~a exhausted a bounded diagnostic store with status ~a; bounded diagnostics emitted"
                            container-id status))
                   ((command-result-capture-overflow? result)
                    (format #f
                            "~a failed capture policy with status ~a: ~a; bounded diagnostics emitted"
                            container-id status
                            (capture-overflow-summary result)))
                   (else
                    (format #f
                            "~a failed with status ~a; bounded diagnostics emitted"
                            container-id status)))))
               (assert-payload-output language expected-book-bytes
                                      (bounded-output stdout))
               (when (lstat-or-false
                      (string-append
                       "/sys/fs/cgroup/wilkbook-execution-" container-id))
                 (fail (string-append "runtime left stale cgroup: "
                                      container-id)))
               (emit-store-evidence-once! #f))))
         (lambda (key . arguments)
           ;; run-command has completed its TERM/KILL, reap, and bounded pipe
           ;; finalization before propagating timeout/EOF errors.  Serialize
           ;; direct evidence now, while both finite stores are still mounted;
           ;; dynamic-wind unmounts them after this exact exception is rethrown.
           (emit-store-evidence-once! #t)
           (apply throw key arguments))))))
  ;; Cleanup, including both verified unmounts, completes before payload PASS.
  (emit marker))

(define (run-smoke arguments)
  (match arguments
    ((oci-source profile closure-file book expected-kernel-release)
     (define work-root "/run/wilkbook-book-execution-smoke")
     (define python-bundle (string-append work-root "/python"))
     (define guile-bundle (string-append work-root "/guile"))
     (define expected-book-bytes (stat:size (stat book)))
     (when (lstat-or-false work-root)
       (fail (string-append "refusing stale guest work root: " work-root)))
     (mkdir work-root #o700)
     (chmod work-root #o700)
     (assert-kernel expected-kernel-release)
     (assert-host-boundaries)
     (assert-sidecar-layout)
     (run-version work-root)
     (primitive-load oci-source)
     (let ((generate-bundle
            (module-ref (resolve-module '(oci-bundle)) 'generate-bundle))
           (closure (read-closure closure-file)))
       (generate-bundle
        #:profile-input profile
        #:book-input book
        #:bundle-input python-bundle
        #:container-id "wilkbook-python-smoke"
        #:execution-profile execution-profile
        #:requisites-runner (lambda (_profile) closure))
        (run-bundle python-bundle "wilkbook-python-smoke" 'python
                    expected-book-bytes
                    "BOOKEXEC-PYTHON-SYSTRAP-PASS")
       (generate-bundle
        #:profile-input profile
        #:book-input book
        #:bundle-input guile-bundle
        #:container-id "wilkbook-guile-smoke"
        #:execution-profile execution-profile
        #:requisites-runner (lambda (_profile) closure))
       (select-guile-process guile-bundle)
        (run-bundle guile-bundle "wilkbook-guile-smoke" 'guile
                    expected-book-bytes
                    "BOOKEXEC-GUILE-SYSTRAP-PASS"))
     (emit "BOOKEXEC-CGROUP-TEARDOWN-PASS")
     (emit "BOOKEXEC-SMOKE-PASS")
     0)
    (_
     (fail "expected OCI-SOURCE PROFILE CLOSURE-FILE BOOK KERNEL-RELEASE"))))

(define (guest-smoke-main argv)
  (catch #t
    (lambda () (run-smoke (cdr argv)))
    (lambda (key . arguments)
      (catch #t
        (lambda ()
          (emit
           (format #f "BOOKEXEC-SMOKE-FAIL ~a ~s" key arguments)))
        (lambda _ #f))
      1)))
