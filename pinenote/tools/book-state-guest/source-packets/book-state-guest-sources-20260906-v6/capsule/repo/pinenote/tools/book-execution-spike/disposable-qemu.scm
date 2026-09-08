;;; Trusted Guile outer-QEMU supervisor for the non-shipping execution spike.
;;; Process style follows pinned Guix f250e74dd (direct command vectors,
;;; explicit waitpid, child primitive-exit) and GNU Shepherd 1.0.9 (constructed
;;; environments, CLOEXEC inheritance discipline, process-group TERM/KILL).
;;; This standalone bounded runner deliberately does not import Shepherd/Fibers.
(define-module (disposable-qemu)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (rnrs bytevectors)
  #:use-module (system foreign)
  #:use-module (guest-console-assertions)
  #:export (disposable-qemu-main
            note-disposable-qemu-signal))

(define default-timeout-seconds 600.0)
(define default-term-grace-seconds 5.0)
(define max-timeout-seconds 1800.0)
(define max-term-grace-seconds 30.0)
(define preparation-timeout-seconds 60.0)
(define guardian-setup-timeout-seconds 5.0)
(define diagnostic-head-bytes (* 32 1024))
(define diagnostic-tail-bytes (* 32 1024))

;; Keep the whole serial record that can contain the v5 failure packet.  These
;; values mirror the actual fixed emitters in guest-smoke.scm: runsc stdout and
;; support stderr (2), up to 12 debug/panic files, and dmesg stdout/stderr (2).
;; Every selected file contributes at most an 8 KiB head plus 8 KiB tail, whose
;; guest escaping expands by at most 5x.  The 12 generated ext4 filenames are
;; at most 255 bytes and use the same escaping.  That makes the selected data
;; channels at most 1,326,020 serial bytes.  A further 2 MiB retains their fixed
;; framing plus boot, Shepherd, canary, failure, and shutdown output (the v4
;; pre-diagnostic serial record was 21,338 bytes).  Overflow is explicit and
;; can never pass the completed-console check below.
(define guest-diagnostic-head-bytes (* 8 1024))
(define guest-diagnostic-tail-bytes (* 8 1024))
(define guest-debug-log-file-limit 12)
(define guest-fixed-diagnostic-file-count 4)
(define guest-diagnostic-escape-expansion 5)
(define guest-debug-filename-max-bytes 255)
(define max-guest-diagnostic-data-bytes
  (+ (* (+ guest-fixed-diagnostic-file-count guest-debug-log-file-limit)
        (+ guest-diagnostic-head-bytes guest-diagnostic-tail-bytes)
        guest-diagnostic-escape-expansion)
     (* guest-debug-log-file-limit guest-debug-filename-max-bytes
        guest-diagnostic-escape-expansion)))
(define console-framing-and-boot-headroom (* 2 1024 1024))
(define max-retained-console-bytes
  (+ max-guest-diagnostic-data-bytes console-framing-and-boot-headroom))
(define max-retained-console-escaped-content-bytes
  (* max-retained-console-bytes guest-diagnostic-escape-expansion))
(define store-system-regexp
  ;; Guix normally names this output HASH-system, with no extra name segment.
  ;; Also accept named system outputs used by the host fixtures.
  (make-regexp "^/gnu/store/[0-9a-z]{32}-([0-9A-Za-z+._-]+-)?system$"))
(define sha256-regexp (make-regexp "^[0-9a-f]{64}$"))
(define interrupted-signal #f)
(define child-default-signals (list SIGINT SIGHUP SIGTERM SIGPIPE))
(define pr-set-child-subreaper 36)
(define prctl
  (pointer->procedure int
                      (dynamic-func "prctl" (dynamic-link))
                      (list int unsigned-long unsigned-long
                            unsigned-long unsigned-long)))

(define (note-disposable-qemu-signal signal-number)
  (set! interrupted-signal signal-number))

(define (mark-inherited-fds-close-on-exec)
  ;; Guix's shepherd boot gexp and Shepherd 1.0.9 'mark-as-close-on-exec' do
  ;; this before daemon exec.  There is no approved inherited protocol FD in
  ;; this outer runner, so every open descriptor above stderr is CLOEXEC.
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

(define (mark-fd-close-on-exec fd)
  (let ((flags (fcntl fd F_GETFD)))
    (unless (positive? (logand flags FD_CLOEXEC))
      (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))

(define (cloexec-pipe)
  (let ((ports (pipe)))
    (mark-fd-close-on-exec (fileno (car ports)))
    (mark-fd-close-on-exec (fileno (cdr ports)))
    ports))

(define (close-port-if-open port)
  (unless (port-closed? port)
    (close-port port)))

(define (runner-error message)
  (throw 'book-execution-qemu-error message))

(define (lexical-absolute raw label)
  (unless (and (string? raw) (string-prefix? "/" raw))
    (runner-error (format #f "~a must be absolute: ~s" label raw)))
  (when (or (string-index raw #\nul)
            (string-index raw #\newline)
            (string-index raw #\return))
    (runner-error (format #f "~a contains a forbidden control character" label)))
  (when (any (lambda (part) (member part '("" "." "..")))
             (cdr (string-split raw #\/)))
    (runner-error
     (format #f
             "~a must be lexical and traversal-free (no //, . or ..): ~s"
             label raw)))
  raw)

(define* (canonical-existing raw label #:key (allow-symlink? #f))
  (let* ((path (lexical-absolute raw label))
         (resolved
          (catch 'system-error
            (lambda () (canonicalize-path path))
            (lambda arguments
              (runner-error
               (format #f "~a cannot be resolved safely: ~a" label raw))))))
    (when (and (not allow-symlink?) (not (string=? path resolved)))
      (runner-error (format #f "~a must not contain a symlink: ~a" label raw)))
    resolved))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (same-identity? first second)
  (and (= (stat:dev first) (stat:dev second))
       (= (stat:ino first) (stat:ino second))))

(define (same-stable-file? first second)
  (and (same-identity? first second)
       (= (stat:size first) (stat:size second))
       (= (stat:mtime first) (stat:mtime second))
       (= (stat:ctime first) (stat:ctime second))))

(define (require-real-directory path label)
  (let ((info (lstat path)))
    (unless (eq? (stat:type info) 'directory)
      (runner-error (format #f "~a is not a real directory: ~a" label path)))
    info))

(define (require-fixed-file path label)
  (let ((info (lstat path)))
    (unless (eq? (stat:type info) 'regular)
      (runner-error (format #f "~a is not a regular file: ~a" label path)))
    (unless (zero? (logand (stat:mode info) #o222))
      (runner-error
       (format #f "~a must have all write bits removed before use: ~a"
               label path)))
    (unless (= (stat:nlink info) 1)
      (runner-error (format #f "~a must not have hard-link aliases: ~a"
                            label path)))
    info))

(define (read-fixed-append config)
  (when (> (stat:size (stat config)) (* 1024 1024))
    (runner-error "extlinux.conf exceeds the 1 MiB preparation limit"))
  (let ((lines
         (call-with-input-file config
           (lambda (port)
             (let loop ((matches '()))
               (let ((line (read-line port)))
                 (if (eof-object? line)
                     (reverse matches)
                     (let ((match (string-match "^[[:space:]]*APPEND[[:space:]]+(.+[^[:space:]])[[:space:]]*$"
                                                line)))
                       (loop (if match
                                 (cons (match:substring match 1) matches)
                                 matches))))))))))
    (unless (= (length lines) 1)
      (runner-error "extlinux.conf must contain exactly one APPEND line"))
    (let* ((tokens (string-tokenize (car lines)))
           (systems (filter-map
                     (lambda (token)
                       (and (string-prefix? "gnu.system=" token)
                            (substring token (string-length "gnu.system="))))
                     tokens))
           (loads (filter-map
                   (lambda (token)
                     (and (string-prefix? "gnu.load=" token)
                          (substring token (string-length "gnu.load="))))
                   tokens)))
      (unless (equal? (filter (lambda (token) (string-prefix? "root=" token))
                              tokens)
                      '("root=PNGuixRoot"))
        (runner-error "APPEND must contain exactly one root=PNGuixRoot"))
      (unless (and (= (length systems) 1)
                   (regexp-exec store-system-regexp (car systems)))
        (runner-error "APPEND must contain one canonical Guix gnu.system path"))
      (unless (equal? loads (list (string-append (car systems) "/boot")))
        (runner-error "APPEND gnu.load must be the selected gnu.system /boot"))
      (unless (= (count
                  (lambda (token)
                    (string=? token "console=ttyS2,1500000n8"))
                  tokens)
                 1)
        (runner-error "APPEND must contain the PineNote hardware console once"))
      (when (member "console=ttyAMA0" tokens)
        (runner-error "APPEND already contains the QEMU console"))
      (string-join
       (filter-map
        (lambda (token)
          (cond
           ((string=? token "console=tty0") #f)
           ((string=? token "console=ttyS2,1500000n8") "console=ttyAMA0")
           (else token)))
        tokens)
       " "))))

(define (validate-boot-bundle raw)
  (let* ((bundle (canonical-existing raw "boot bundle"))
         (extlinux (string-append bundle "/extlinux"))
         (kernel (string-append extlinux "/Image"))
         (initrd (string-append extlinux "/initrd.cpio.gz"))
         (config (string-append extlinux "/extlinux.conf")))
    (require-real-directory bundle "boot bundle")
    (unless (string=? extlinux (canonical-existing extlinux "boot bundle extlinux"))
      (runner-error (format #f "boot bundle extlinux path contains a symlink: ~a"
                            extlinux)))
    (require-real-directory extlinux "boot bundle extlinux directory")
    (for-each
     (lambda (entry)
       (match entry
         ((label . path)
          (unless (string=? path (canonical-existing path label))
            (runner-error (format #f "~a contains a symlink: ~a" label path)))
          (require-fixed-file path label))))
     `(("boot bundle kernel" . ,kernel)
       ("boot bundle initrd" . ,initrd)
       ("boot bundle config" . ,config)))
    (list bundle kernel initrd config (read-fixed-append config))))

(define (validate-sha256 value label)
  (unless (regexp-exec sha256-regexp value)
    (runner-error
     (format #f "~a must be 64 lowercase hexadecimal digits" label)))
  value)

(define (validate-baseline raw)
  (let ((baseline (canonical-existing raw "baseline")))
    (let ((info (require-fixed-file baseline "baseline")))
      (when (zero? (stat:size info))
        (runner-error "baseline must not be empty")))
    baseline))

(define (find-on-path name)
  (let loop ((directories (string-split (or (getenv "PATH") "") #\:)))
    (and (pair? directories)
         (let ((candidate (string-append (car directories) "/" name)))
           (if (and (lstat-or-false candidate) (access? candidate X_OK))
               candidate
               (loop (cdr directories)))))))

(define (resolve-executable raw name)
  (let ((candidate (or raw (find-on-path name))))
    (unless candidate
      (runner-error
       (format #f "~a not found; enter a cached 'guix shell qemu --' environment"
               name)))
    (let ((executable
           (canonical-existing candidate name #:allow-symlink? #t)))
      (unless (and (eq? (stat:type (lstat executable)) 'regular)
                   (access? executable X_OK))
        (runner-error (format #f "~a target is not executable: ~a"
                              name executable)))
      executable)))

(define (validate-run-base raw)
  (let* ((run-base (canonical-existing raw "run base"))
         (info (require-real-directory run-base "run base")))
    (unless (and (= (stat:uid info) (getuid))
                 (zero? (logand (stat:mode info) #o077)))
      (runner-error
       (format #f "run base must be owned by the caller and mode 0700: ~a"
               run-base)))
    (when (string-index run-base #\,)
      (runner-error "run base must not contain ',' (QEMU chardev delimiter)"))
    run-base))

(define (monotonic-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (group-exists? process-group)
  (catch 'system-error
    (lambda () (kill (- process-group) 0) #t)
    (lambda arguments
      (if (= ESRCH (system-error-errno arguments))
          #f
          #t))))

(define (wait-group-gone process-group seconds)
  (let ((deadline (+ (monotonic-seconds) seconds)))
    (let loop ()
      (cond
       ((not (group-exists? process-group)) #t)
       ((>= (monotonic-seconds) deadline) #f)
       (else (usleep 20000) (loop))))))

(define (reap-available-children)
  ;; A process guardian is a child subreaper, so WAIT_ANY covers both the
  ;; direct exec child and descendants orphaned during group teardown.
  (let loop ()
    (let ((result
           (catch 'system-error
             (lambda () (waitpid WAIT_ANY WNOHANG))
             (lambda arguments
               (if (member (system-error-errno arguments) (list ECHILD EINTR))
                   '(0 . #f)
                   (apply throw 'system-error arguments))))))
      (unless (zero? (car result))
        (loop)))))

(define (wait-group-gone/reaping process-group seconds)
  (let ((deadline (+ (monotonic-seconds) seconds)))
    (let loop ()
      (reap-available-children)
      (cond
       ((not (group-exists? process-group))
        (reap-available-children)
        #t)
       ((>= (monotonic-seconds) deadline) #f)
       (else (usleep 20000) (loop))))))

(define (signal-group process-group signal-number)
  (catch 'system-error
    (lambda () (kill (- process-group) signal-number))
    (lambda arguments
      (unless (= ESRCH (system-error-errno arguments))
        (apply throw 'system-error arguments)))))

(define (terminate-owned-group process-group grace)
  (when (group-exists? process-group)
    (signal-group process-group SIGTERM)
    (wait-group-gone process-group grace))
  (when (group-exists? process-group)
    (signal-group process-group SIGKILL))
  (unless (wait-group-gone process-group (max grace 1.0))
    (runner-error
     (format #f "owned process group ~a survived SIGKILL" process-group))))

(define (terminate-owned-group/reaping process-group grace)
  (when (group-exists? process-group)
    (signal-group process-group SIGTERM)
    (wait-group-gone/reaping process-group grace))
  (when (group-exists? process-group)
    (signal-group process-group SIGKILL))
  (unless (wait-group-gone/reaping process-group (max grace 1.0))
    (runner-error
     (format #f "owned process group ~a survived SIGKILL" process-group))))

(define (status->exit-code status)
  (or (status:exit-val status)
      (let ((signal-number (status:term-sig status)))
        (if signal-number (logior #x80 signal-number) 1))))

(define (open-output path)
  (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC) #o600))

(define (exec-owned-child argv environment cwd stdout-path stderr-path
                          inherited-ports)
  (unless (and (every string? argv) (every string? environment))
    (runner-error "process argv and environment must be lists of strings"))
  (let ((stdout-fd (open-output stdout-path))
        (stderr-fd (open-output stderr-path)))
    (catch #t
      (lambda ()
        ;; Shepherd resets inherited daemon handlers before child setup.  The
        ;; liveness/report/setup ports are closed, not merely marked CLOEXEC:
        ;; an exec child must never retain a writer that can hide owner EOF.
        (for-each close-port-if-open inherited-ports)
        (for-each (lambda (signal-number)
                    (sigaction signal-number SIG_DFL))
                  child-default-signals)
        (sigaction SIGCHLD SIG_DFL)
        (chdir cwd)
        (let ((null-fd (open-fdes "/dev/null" (logior O_RDONLY O_CLOEXEC))))
          (dup2 null-fd 0)
          (close-fdes null-fd))
        (dup2 stdout-fd 1)
        (dup2 stderr-fd 2)
        (close-fdes stdout-fd)
        (close-fdes stderr-fd)
        (mark-inherited-fds-close-on-exec)
        (environ environment)
        (apply execl (car argv) argv))
      (lambda arguments
        (format (current-error-port) "exec failed: ~s~%" arguments)
        (force-output (current-error-port))
        (primitive-exit 127)))))

(define (liveness-closed? port)
  (match (select (list port) '() '() 0 0)
    ((() () ()) #f)
    ((_ () ()) (eof-object? (peek-char port)))))

(define (write-guardian-message port value)
  (write value port)
  (newline port)
  (force-output port))

(define (wait-for-child-setup child-ready owner-liveness deadline)
  (let loop ()
    (let ((remaining (- deadline (monotonic-seconds))))
      (cond
       ((<= remaining 0) 'setup-timeout)
       (else
        (match (select (list child-ready owner-liveness) '() '()
                       0 (inexact->exact
                          (round (* 1000000 (min remaining 0.02)))))
          ((readable () ())
           (cond
            ((and (member owner-liveness readable)
                  (eof-object? (peek-char owner-liveness)))
             'owner-dead)
            ((member child-ready readable)
             (let ((value (read-char child-ready)))
               (if (and (char? value) (char=? value #\R))
                   'ready
                   'setup-failed)))
            (else (loop))))))))))

(define (wait-guarded-child child owner-liveness timeout)
  (let ((deadline (+ (monotonic-seconds) timeout))
        (direct-status #f))
    (define (reap-and-record)
      (let loop ()
        (let ((result
               (catch 'system-error
                 (lambda () (waitpid WAIT_ANY WNOHANG))
                 (lambda arguments
                   (if (member (system-error-errno arguments)
                               (list ECHILD EINTR))
                       '(0 . #f)
                       (apply throw 'system-error arguments))))))
          (unless (zero? (car result))
            (when (= (car result) child)
              (set! direct-status (cdr result)))
            (loop)))))
    (let loop ()
      (reap-and-record)
      (cond
       ((liveness-closed? owner-liveness) '(owner-dead))
       (direct-status
        (list 'result (status->exit-code direct-status) #f))
       ((>= (monotonic-seconds) deadline) '(result 124 #t))
       (else
        (select (list owner-liveness) '() '() 0 20000)
        (loop))))))

(define (kill-unestablished-child child)
  (catch 'system-error
    (lambda () (kill child SIGKILL))
    (lambda arguments
      (unless (= ESRCH (system-error-errno arguments))
        (apply throw 'system-error arguments))))
  (let loop ()
    (catch 'system-error
      (lambda () (waitpid child) #t)
      (lambda arguments
        (cond
         ((= EINTR (system-error-errno arguments)) (loop))
         ((= ECHILD (system-error-errno arguments)) #t)
         (else (apply throw 'system-error arguments)))))))

(define (process-guardian-main argv environment cwd stdout-path stderr-path
                               timeout grace owner-liveness report
                               root-liveness-port)
  ;; This process is both the exec child's parent and a Linux child subreaper.
  ;; Thus TERM/KILL of its exact owned PGID can be followed by bounded reaping
  ;; of a TERM-resistant descendant rather than leaving that work to PID 1.
  (setpgid 0 0)
  (for-each (lambda (signal-number) (sigaction signal-number SIG_IGN))
            child-default-signals)
  (sigaction SIGCHLD SIG_DFL)
  (close-port-if-open root-liveness-port)
  (unless (zero? (prctl pr-set-child-subreaper 1 0 0 0))
    (runner-error "guardian could not become a Linux child subreaper"))
  (let* ((child-ready-pipe (cloexec-pipe))
         (child-ready-read (car child-ready-pipe))
         (child-ready-write (cdr child-ready-pipe))
         (release-pipe (cloexec-pipe))
         (release-read (car release-pipe))
         (release-write (cdr release-pipe))
         (child #f)
         (group-established? #f)
         (outcome #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! child (primitive-fork))
        (if (zero? child)
            (begin
              (close-port-if-open child-ready-read)
              (close-port-if-open release-write)
              (catch #t
                (lambda ()
                  (setpgid 0 0)
                  (write-char #\R child-ready-write)
                  (force-output child-ready-write)
                  (close-port-if-open child-ready-write)
                  (let ((release (read-char release-read)))
                    (close-port-if-open release-read)
                    (unless (and (char? release) (char=? release #\R))
                      (primitive-exit 126)))
                  (exec-owned-child
                   argv environment cwd stdout-path stderr-path
                   (list owner-liveness report)))
                (lambda arguments
                  (format (current-error-port)
                          "child process-group setup failed: ~s~%" arguments)
                  (force-output (current-error-port))
                  (primitive-exit 127))))
            (begin
              (close-port-if-open child-ready-write)
              (close-port-if-open release-read)
              ;; The child also calls setpgid before acknowledging.  Holding it
              ;; behind release-read means this parent-side call cannot lose a
              ;; race to exec; READY is not reported until both have completed.
              (setpgid child child)
              (match (wait-for-child-setup
                      child-ready-read owner-liveness
                      (+ (monotonic-seconds) guardian-setup-timeout-seconds))
                ('ready
                 (set! group-established? #t)
                 (write-guardian-message report (list 'ready child))
                 (write-char #\R release-write)
                 (force-output release-write)
                 (close-port-if-open release-write)
                 (set! outcome
                       (wait-guarded-child child owner-liveness timeout)))
                ('owner-dead (set! outcome '(owner-dead)))
                ('setup-timeout
                 (set! outcome '(error "guardian child setup timed out")))
                ('setup-failed
                 (set! outcome '(error "guardian child setup failed")))))))
      (lambda ()
        (close-port-if-open child-ready-read)
        (close-port-if-open child-ready-write)
        (close-port-if-open release-read)
        (close-port-if-open release-write)
        (when child
          (if group-established?
              (terminate-owned-group/reaping child grace)
              (kill-unestablished-child child)))))
    (unless (eq? (car outcome) 'owner-dead)
      (write-guardian-message report outcome))))

(define (wait-guardian-message port deadline)
  (let loop ()
    (when interrupted-signal
      (throw 'book-execution-qemu-signal interrupted-signal))
    (let ((remaining (- deadline (monotonic-seconds))))
      (when (<= remaining 0)
        (runner-error "process guardian did not report within its bound"))
      (match (select (list port) '() '() 0 0)
        ((() () ())
         ;; Keep the owner at Guile safe points so its catchable-signal
         ;; handlers can unwind promptly; the guardian, not this poll, owns
         ;; the child timeout.
         (usleep (inexact->exact
                  (round (* 1000000 (min remaining 0.02)))))
        (loop))
        ((_ () ())
         ;; One guardian message is one flushed line.  Do not use 'read'
         ;; directly on the pipe: its port buffer can retain only the previous
         ;; line's whitespace, make a later 'select' look ready, and then block
         ;; inside 'read' where Guile cannot dispatch the owner's signal thunk.
         (let ((line (read-line port)))
           (when (eof-object? line)
             (runner-error "process guardian exited without a result"))
           (call-with-input-string line read)))))))

(define (wait-specific-child/bounded pid seconds)
  (let ((deadline (+ (monotonic-seconds) seconds)))
    (let loop ()
      (let ((result
             (catch 'system-error
               (lambda () (waitpid pid WNOHANG))
               (lambda arguments
                 (if (= ECHILD (system-error-errno arguments))
                     (cons pid 'already-reaped)
                     (if (= EINTR (system-error-errno arguments))
                         '(0 . #f)
                         (apply throw 'system-error arguments)))))))
        (cond
         ((not (zero? (car result))) (cons 'done (cdr result)))
         ((>= (monotonic-seconds) deadline) #f)
         (else (usleep 20000) (loop)))))))

(define (run-owned-process argv environment cwd stdout-path stderr-path
                           timeout grace root-liveness-port)
  (let* ((liveness-pipe (cloexec-pipe))
         (liveness-read (car liveness-pipe))
         (liveness-write (cdr liveness-pipe))
         (report-pipe (cloexec-pipe))
         (report-read (car report-pipe))
         (report-write (cdr report-pipe))
         (guardian (primitive-fork))
         (owned-group #f))
    (if (zero? guardian)
        (begin
          (close-port-if-open liveness-write)
          (close-port-if-open report-read)
          (catch #t
            (lambda ()
              (process-guardian-main
               argv environment cwd stdout-path stderr-path timeout grace
               liveness-read report-write root-liveness-port)
              (primitive-exit 0))
            (lambda (key . arguments)
              (catch #t
                (lambda ()
                  (write-guardian-message
                   report-write
                   (list 'error (format #f "~s ~s" key arguments))))
                (lambda _ #f))
              (primitive-exit 125))))
        (begin
          (close-port-if-open liveness-read)
          (close-port-if-open report-write)
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (let ((ready
                     (wait-guardian-message
                      report-read
                      (+ (monotonic-seconds)
                         guardian-setup-timeout-seconds))))
                (match ready
                  (('ready pid) (set! owned-group pid))
                  (('error message) (runner-error message))
                  (_ (runner-error
                      (format #f "invalid process guardian setup message: ~s"
                              ready)))))
              (let ((outcome
                     (wait-guardian-message
                      report-read
                      (+ (monotonic-seconds) timeout grace
                         (max grace 1.0) 1.0))))
                (match outcome
                  (('result status timed-out?) (cons status timed-out?))
                  (('error message) (runner-error message))
                  (_ (runner-error
                      (format #f "invalid process guardian result: ~s"
                              outcome))))))
            (lambda ()
              ;; EOF is the guardian's authority on owner death, including
              ;; uncatchable SIGKILL.  No exec child has this write end.
              (close-port-if-open liveness-write)
              (close-port-if-open report-read)
              (unless (wait-specific-child/bounded
                       guardian (+ grace (max grace 1.0) 1.0))
                ;; The normal fallback remains exact: one known guardian PID
                ;; and one known owned PGID, never a PID/name scan.
                (when owned-group
                  (terminate-owned-group owned-group grace))
                (catch 'system-error
                  (lambda () (kill guardian SIGKILL))
                  (lambda arguments
                    (unless (= ESRCH (system-error-errno arguments))
                      (apply throw 'system-error arguments))))
                (wait-specific-child/bounded guardian 1.0))))))))

(define (supervisor-environment run-root qemu)
  (let ((environment
         (list
          (string-append "HOME=" run-root "/home")
          "LANG=C"
          "LC_ALL=C"
          (string-append "PATH=" (dirname qemu))
          (string-append "TMPDIR=" run-root "/tmp")
          (string-append "XDG_CACHE_HOME=" run-root "/xdg-cache")
          (string-append "XDG_CONFIG_HOME=" run-root "/xdg-config")
          (string-append "XDG_RUNTIME_DIR=" run-root "/xdg-runtime"))))
    (for-each
     (lambda (name)
       (let ((path (string-append run-root "/" name)))
         (mkdir path #o700)
         (chmod path #o700)))
     '("home" "tmp" "xdg-cache" "xdg-config" "xdg-runtime"))
    environment))

(define (read-bounded-failure path)
  (catch 'system-error
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (let ((value (get-string-n port 4096)))
            (if (eof-object? value) "" value)))))
    (lambda _ "")))

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
  ;; Prefix every rendered line and escape every source control byte.  Thus an
  ;; untrusted guest cannot inject terminal escapes or forge an unprefixed
  ;; runner diagnostic.  Output expansion is at most five bytes per input byte.
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

(define (read-bytevector/bounded path limit)
  ;; Read the actual bytes, not a claimed stat length.  LIMIT+1 makes overflow
  ;; visible while keeping memory finite and preserving the simple full export.
  (let ((port (open-file path "rb")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((value (get-bytevector-n port (+ limit 1))))
          (if (eof-object? value) (make-bytevector 0) value)))
      (lambda () (close-port-if-open port)))))

(define (emit-bounded-file-diagnostic label path)
  ;; QEMU and every owned descendant have been reaped before this is called.
  ;; Read bytes rather than decoding guest-controlled text, and retain no file
  ;; after the existing run-root cleanup.
  (let ((error-port (current-error-port)))
    (catch #t
      (lambda ()
        (let ((info (lstat-or-false path)))
          (cond
           ((not info)
            (format error-port
                    "BOOKEXEC-QEMU-DIAGNOSTIC label=~a state=missing~%"
                    label))
           ((not (eq? (stat:type info) 'regular))
            (format error-port
                    "BOOKEXEC-QEMU-DIAGNOSTIC label=~a state=non-regular~%"
                    label))
           (else
            (let ((size (stat:size info)))
              (format error-port
                      "BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=~a source-bytes=~a~%"
                      label size)
              (if (<= size (+ diagnostic-head-bytes diagnostic-tail-bytes))
                  (let ((content (read-byte-range path 0 size)))
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-CONTENT bytes=~a~%"
                            (bytevector-length content))
                    (write-escaped-bytevector content error-port))
                  (let ((head (read-byte-range path 0 diagnostic-head-bytes))
                        (tail (read-byte-range
                               path (- size diagnostic-tail-bytes)
                               diagnostic-tail-bytes)))
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-HEAD bytes=~a~%"
                            (bytevector-length head))
                    (write-escaped-bytevector head error-port)
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-ELIDED bytes=~a~%"
                            (- size (bytevector-length head)
                               (bytevector-length tail)))
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-TAIL bytes=~a~%"
                            (bytevector-length tail))
                    (write-escaped-bytevector tail error-port)))
              (format error-port
                      "BOOKEXEC-QEMU-DIAGNOSTIC-END label=~a~%" label))))))
      (lambda (key . arguments)
        ;; Diagnostic failure must not replace the QEMU/parser failure that
        ;; selected this path.
        (format error-port
                "BOOKEXEC-QEMU-DIAGNOSTIC label=~a state=unavailable error=~s ~s~%"
                label key arguments)))
    (force-output error-port)))

(define (emit-full-console-diagnostic path)
  ;; QEMU and its descendants have been reaped and PATH is the one generated
  ;; private console path.  Read at most the fixed limit plus one byte, then
  ;; render that bounded bytevector without constructing an escaped string.
  (let ((error-port (current-error-port))
        (label "console.log"))
    (catch #t
      (lambda ()
        (let ((before (lstat-or-false path)))
          (cond
           ((not before)
            (format error-port
                    "BOOKEXEC-QEMU-DIAGNOSTIC label=~a state=missing~%"
                    label))
           ((not (eq? (stat:type before) 'regular))
            (format error-port
                    "BOOKEXEC-QEMU-DIAGNOSTIC label=~a state=non-regular~%"
                    label))
           (else
            (let* ((content
                    (read-bytevector/bounded
                     path max-retained-console-bytes))
                   (observed (bytevector-length content)))
              (if (> observed max-retained-console-bytes)
                  (format error-port
                          "BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE label=~a state=overflow observed-bytes-at-least=~a limit-bytes=~a~%"
                          label observed max-retained-console-bytes)
                  (begin
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=~a source-bytes=~a retention=full~%"
                            label observed)
                    (format error-port
                            "BOOKEXEC-QEMU-DIAGNOSTIC-CONTENT bytes=~a~%"
                            observed)
                    (write-escaped-bytevector content error-port)
                    (let ((after (lstat-or-false path)))
                      (if (and after (same-stable-file? before after))
                          (format error-port
                                  "BOOKEXEC-QEMU-DIAGNOSTIC-END label=~a retention=full~%"
                                  label)
                          (format error-port
                                  "BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE label=~a state=changed exported-bytes=~a limit-bytes=~a~%"
                                  label observed
                                  max-retained-console-bytes))))))))))
      (lambda (key . arguments)
        (format error-port
                "BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE label=~a state=unavailable error=~s ~s~%"
                label key arguments)))
    (force-output error-port)))

(define (assert-console-retainable path)
  ;; A completed guest cannot succeed if its console could not be exported in
  ;; full on a parser failure.  Use the same bounded read as the exporter.
  (let ((info (lstat-or-false path)))
    (unless info
      (runner-error "guest console is missing before retention check"))
    (unless (eq? (stat:type info) 'regular)
      (runner-error "guest console is not regular before retention check"))
    (let* ((content
            (read-bytevector/bounded path max-retained-console-bytes))
           (observed (bytevector-length content)))
      (when (> observed max-retained-console-bytes)
        (runner-error
         (format #f
                 "guest console exceeds the ~a-byte full-retention bound (observed at least ~a); diagnostic evidence would be incomplete"
                 max-retained-console-bytes observed))))))

(define (emit-qemu-failure-diagnostics run-root stderr-path)
  (emit-full-console-diagnostic (string-append run-root "/console.log"))
  (emit-bounded-file-diagnostic "qemu.stderr" stderr-path))

(define (validate-completed-guest-console path run-root stderr-path)
  ;; QEMU is already reaped when this runs.  Keep the completed log private and
  ;; consume it inside the existing dynamic-wind scope so success/failure both
  ;; flow through the identity-checked run-root cleanup below.
  (catch #t
    (lambda ()
      (assert-console-retainable path)
      (assert-guest-console-file path))
    (lambda (key . arguments)
      (emit-qemu-failure-diagnostics run-root stderr-path)
      (runner-error
       (format #f "guest console assertions failed: ~s ~s" key arguments)))))

(define (run-checked-preparation argv environment run-root stem grace
                                 root-liveness-port)
  (let* ((stdout-path (string-append run-root "/" stem ".stdout"))
         (stderr-path (string-append run-root "/" stem ".stderr"))
         (result
          (run-owned-process argv environment run-root stdout-path stderr-path
                             preparation-timeout-seconds grace
                             root-liveness-port)))
    (when (cdr result)
      (runner-error
       (format #f "~a exceeded its 60 second preparation timeout" stem)))
               (unless (zero? (car result))
                 (runner-error
       (format #f "~a failed with status ~a: ~a"
               stem (car result) (string-trim-both (read-bounded-failure stderr-path)))))
    stdout-path))

(define (private-snapshot source destination expected-sha256 label
                           cp sha256sum environment run-root grace
                           root-liveness-port)
  (let ((before (lstat source)))
    (run-checked-preparation
     (list cp "--reflink=auto" "--sparse=always" "--" source destination)
      environment run-root (string-append "copy-" label) grace
      root-liveness-port)
    (let ((after (lstat source)))
      (unless (same-stable-file? before after)
        (runner-error (format #f "source changed while making private snapshot: ~a"
                              source))))
    (chmod destination #o400)
    (let* ((hash-output
            (run-checked-preparation
              (list sha256sum "--" destination)
              environment run-root (string-append "hash-" label) grace
              root-liveness-port))
           (line (call-with-input-file hash-output read-line))
           (observed (and (string? line)
                          (let ((space (string-index line #\space)))
                            (and space (substring line 0 space))))))
      (unless (and observed (regexp-exec sha256-regexp observed))
        (runner-error (format #f "sha256sum returned malformed output for ~a" label)))
      (unless (string=? observed expected-sha256)
        (runner-error
         (format #f "private ~a SHA-256 mismatch: expected ~a, got ~a"
                 label expected-sha256 observed))))))

(define (json-quote value)
  ;; QEMU's blockdev JSON only receives generated paths.  The lexical input
  ;; checks forbid controls; escape the two JSON metacharacters here.
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

(define (qemu-img-argv qemu-img baseline overlay)
  (list qemu-img "create" "-q" "-f" "qcow2" "-F" "raw" "-b"
        baseline overlay))

(define (qemu-argv qemu run-root kernel initrd append overlay)
  (let ((console-socket (string-append run-root "/console.sock"))
        (console-log (string-append run-root "/console.log"))
        (overlay-file
         (string-append
          "{\"driver\":\"file\",\"filename\":" (json-quote overlay)
          ",\"node-name\":\"rootfs-overlay-file\",\"read-only\":false}"))
        (overlay-format
         "{\"driver\":\"qcow2\",\"file\":\"rootfs-overlay-file\",\"node-name\":\"rootfs-overlay\",\"read-only\":false}"))
    (list qemu
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
          "-chardev"
          (string-append "socket,id=console0,path=" console-socket
                         ",server=on,wait=off,logfile=" console-log
                         ",logappend=off")
          "-serial" "chardev:console0"
          "-kernel" kernel
          "-initrd" initrd
          "-append" append
          "-blockdev" overlay-file
          "-blockdev" overlay-format
          "-device" "virtio-blk-pci,drive=rootfs-overlay")))

(define (delete-created-tree path)
  (let ((info (lstat-or-false path)))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name)
               (unless (member name '("." ".."))
                 (delete-created-tree (string-append path "/" name))))
             (scandir path))
            (rmdir path))
          (delete-file path)))))

(define (sleep-until deadline)
  (let loop ()
    (let ((remaining (- deadline (monotonic-seconds))))
      (when (> remaining 0)
        (usleep (inexact->exact
                 (round (* 1000000 (min remaining 0.05)))))
        (loop)))))

(define (run-root-guardian-main owner-liveness ready run-root run-identity
                                cleanup-delay)
  ;; This guardian has one job, not a daemon protocol: keep the exact private
  ;; tree covered for the whole owner lifetime.  Process guardians independently
  ;; own and reap each exec group; the delay lets their bounded escalation finish
  ;; before pathname cleanup after an owner SIGKILL.
  (setpgid 0 0)
  (for-each (lambda (signal-number) (sigaction signal-number SIG_IGN))
            child-default-signals)
  (sigaction SIGCHLD SIG_DFL)
  (write-guardian-message ready '(ready))
  (close-port-if-open ready)
  (let ((message (read-char owner-liveness)))
    (unless (and (char? message) (char=? message #\C))
      (sleep-until (+ (monotonic-seconds) cleanup-delay))
      (let ((current (lstat-or-false run-root)))
        (cond
         ((and current (same-identity? current run-identity))
          (delete-created-tree run-root))
         (current
          (format (current-error-port)
                  "FAIL: root guardian refuses replaced run directory: ~a~%"
                  run-root)))))))

(define (start-run-root-guardian run-root run-identity grace)
  (let* ((liveness-pipe (cloexec-pipe))
         (liveness-read (car liveness-pipe))
         (liveness-write (cdr liveness-pipe))
         (ready-pipe (cloexec-pipe))
         (ready-read (car ready-pipe))
         (ready-write (cdr ready-pipe))
         (cleanup-delay (+ grace (max grace 1.0) 0.5))
         (guardian (primitive-fork)))
    (if (zero? guardian)
        (begin
          (close-port-if-open liveness-write)
          (close-port-if-open ready-read)
          (catch #t
            (lambda ()
              (run-root-guardian-main
               liveness-read ready-write run-root run-identity cleanup-delay)
              (primitive-exit 0))
            (lambda (key . arguments)
              (format (current-error-port)
                      "FAIL: run-root guardian: ~s ~s~%" key arguments)
              (force-output (current-error-port))
              (primitive-exit 125))))
        (begin
          (close-port-if-open liveness-read)
          (close-port-if-open ready-write)
          (let ((message
                 (catch #t
                   (lambda ()
                     (wait-guardian-message
                      ready-read
                      (+ (monotonic-seconds)
                         guardian-setup-timeout-seconds)))
                   (lambda (key . arguments)
                     (close-port-if-open liveness-write)
                     (close-port-if-open ready-read)
                     (catch 'system-error
                       (lambda () (kill guardian SIGKILL))
                       (lambda _ #f))
                     (wait-specific-child/bounded guardian 1.0)
                     (apply throw key arguments)))))
            (close-port-if-open ready-read)
            (unless (equal? message '(ready))
              (close-port-if-open liveness-write)
              (catch 'system-error
                (lambda () (kill guardian SIGKILL))
                (lambda _ #f))
              (wait-specific-child/bounded guardian 1.0)
              (runner-error
               (format #f "invalid run-root guardian message: ~s" message)))
            (list guardian liveness-write cleanup-delay))))))

(define (stop-run-root-guardian guardian-state cleanup-completed?)
  (match guardian-state
    ((guardian liveness-write cleanup-delay)
     (when cleanup-completed?
       (write-char #\C liveness-write)
       (force-output liveness-write))
     (close-port-if-open liveness-write)
     (unless (wait-specific-child/bounded guardian (+ cleanup-delay 1.0))
       (catch 'system-error
         (lambda () (kill guardian SIGKILL))
         (lambda arguments
           (unless (= ESRCH (system-error-errno arguments))
             (apply throw 'system-error arguments))))
       (wait-specific-child/bounded guardian 1.0)
       (runner-error "run-root guardian exceeded its cleanup bound")))))

(define (validate-limit raw label maximum)
  (let ((value (string->number raw)))
    (unless (and value (real? value) (finite? value) (> value 0) (<= value maximum))
      (runner-error
       (format #f "~a must be > 0 and <= ~a seconds" label maximum)))
    (exact->inexact value)))

(define (run options)
  (let* ((boot (validate-boot-bundle (option-ref options 'boot-bundle #f)))
         (bundle (list-ref boot 0))
         (kernel (list-ref boot 1))
         (initrd (list-ref boot 2))
         (config (list-ref boot 3))
         (append-line (list-ref boot 4))
         (baseline (validate-baseline (option-ref options 'baseline #f)))
         (kernel-sha256
          (validate-sha256 (option-ref options 'kernel-sha256 #f)
                           "kernel SHA-256"))
         (initrd-sha256
          (validate-sha256 (option-ref options 'initrd-sha256 #f)
                           "initrd SHA-256"))
         (config-sha256
          (validate-sha256 (option-ref options 'config-sha256 #f)
                           "config SHA-256"))
         (baseline-sha256
          (validate-sha256 (option-ref options 'baseline-sha256 #f)
                           "baseline SHA-256"))
         (run-base (validate-run-base (option-ref options 'run-base #f)))
         (qemu (resolve-executable (option-ref options 'qemu #f)
                                   "qemu-system-aarch64"))
         (qemu-img (resolve-executable (option-ref options 'qemu-img #f)
                                       "qemu-img"))
         (cp (resolve-executable (option-ref options 'cp #f) "cp"))
         (sha256sum (resolve-executable (option-ref options 'sha256sum #f)
                                        "sha256sum"))
         (timeout (validate-limit
                   (option-ref options 'timeout-seconds
                               (number->string default-timeout-seconds))
                   "timeout" max-timeout-seconds))
         (grace (validate-limit
                 (option-ref options 'term-grace-seconds
                             (number->string default-term-grace-seconds))
                 "TERM grace" max-term-grace-seconds)))
    (unless (option-ref options 'dedicated-baseline #f)
      (runner-error
       "--dedicated-baseline is required for a fresh spike-only baseline"))
    (when (string=? qemu qemu-img)
      (runner-error "qemu-system-aarch64 and qemu-img must be distinct executables"))
    (let* ((base-fd (open-fdes run-base
                               (logior O_RDONLY O_DIRECTORY O_NOFOLLOW O_CLOEXEC)))
            (base-info (stat base-fd))
            (run-root #f)
            (run-identity #f)
            (root-guardian #f))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (unless (same-identity? base-info (lstat run-base))
            (runner-error "run base identity changed before mkdtemp"))
          (let* ((fd-parent (format #f "/proc/self/fd/~a" base-fd))
                 (created
                  (mkdtemp (string-append fd-parent
                                         "/book-execution-qemu.XXXXXX")))
                 (name (basename created)))
            (set! run-root (string-append run-base "/" name))
            (chmod created #o700)
            (set! run-identity (lstat created))
            (unless (and (same-identity? run-identity (lstat run-root))
                         (= (stat:uid run-identity) (getuid))
                         (zero? (logand (stat:mode run-identity) #o077)))
              (runner-error "private run directory identity/mode check failed"))
            (set! root-guardian
                  (start-run-root-guardian run-root run-identity grace)))

          (let* ((environment (supervisor-environment run-root qemu))
                  (root-liveness-port (list-ref root-guardian 1))
                  (private-boot (string-append run-root "/boot"))
                 (private-kernel (string-append private-boot "/Image"))
                 (private-initrd (string-append private-boot "/initrd.cpio.gz"))
                 (private-config (string-append private-boot "/extlinux.conf"))
                 (private-baseline (string-append run-root "/baseline.raw"))
                 (overlay (string-append run-root "/disk-overlay.qcow2")))
            (mkdir private-boot #o700)
            (chmod private-boot #o700)
            (private-snapshot kernel private-kernel kernel-sha256 "kernel"
                               cp sha256sum environment run-root grace
                               root-liveness-port)
            (private-snapshot initrd private-initrd initrd-sha256 "initrd"
                               cp sha256sum environment run-root grace
                               root-liveness-port)
            (private-snapshot config private-config config-sha256 "config"
                               cp sha256sum environment run-root grace
                               root-liveness-port)
            (unless (string=? append-line (read-fixed-append private-config))
              (runner-error "boot configuration changed while making private copy"))
            (private-snapshot baseline private-baseline baseline-sha256 "baseline"
                               cp sha256sum environment run-root grace
                               root-liveness-port)

            (run-checked-preparation
             (qemu-img-argv qemu-img private-baseline overlay)
             environment run-root "qemu-img" grace root-liveness-port)
            (unless (and (lstat-or-false overlay)
                         (eq? (stat:type (lstat overlay)) 'regular))
              (runner-error "qemu-img did not create a regular private overlay"))
            (chmod overlay #o600)
            (unless (same-identity? run-identity (lstat run-root))
              (runner-error "private run directory identity changed before QEMU"))

            (let* ((stdout-path (string-append run-root "/qemu.stdout"))
                   (stderr-path (string-append run-root "/qemu.stderr"))
                   (result
                    (run-owned-process
                      (qemu-argv qemu run-root private-kernel private-initrd
                                 append-line overlay)
                      environment run-root stdout-path stderr-path timeout grace
                      root-liveness-port)))
              (when (cdr result)
                (emit-qemu-failure-diagnostics run-root stderr-path)
                (runner-error
                 (format #f
                         "QEMU reached the ~a second outer timeout; guest status was not assessed"
                         timeout)))
              (unless (zero? (car result))
                (emit-qemu-failure-diagnostics run-root stderr-path)
                (runner-error
                  (format #f
                          "QEMU exited with status ~a; guest status was not assessed"
                           (car result))))
               (validate-completed-guest-console
                (string-append run-root "/console.log") run-root stderr-path)
               (display
                "OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS\n")
                0)))
        (lambda ()
          (let ((cleanup-completed? #f)
                (cleanup-exception #f))
            (catch #t
              (lambda ()
                (when (and run-root run-identity)
                  (let ((current (lstat-or-false run-root)))
                    (if (and current (same-identity? current run-identity))
                        (delete-created-tree run-root)
                        (when current
                          (format
                           (current-error-port)
                           "FAIL: refusing to clean replaced run directory: ~a~%"
                           run-root)))))
                (set! cleanup-completed? #t))
              (lambda arguments
                (set! cleanup-exception arguments)))
            ;; The normal acknowledgement is sent only after identity-checked
            ;; cleanup.  EOF without it (including owner SIGKILL) authorizes the
            ;; independent guardian to retry only this private tree.
            (when root-guardian
              (stop-run-root-guardian root-guardian cleanup-completed?))
            (close-fdes base-fd)
            (when cleanup-exception
              (apply throw cleanup-exception))))))))

(define cli-options
  '((boot-bundle (value #t))
    (baseline (value #t))
    (kernel-sha256 (value #t))
    (initrd-sha256 (value #t))
    (config-sha256 (value #t))
    (baseline-sha256 (value #t))
    (dedicated-baseline)
    (qemu (value #t))
    (qemu-img (value #t))
    (cp (value #t))
    (sha256sum (value #t))
    (run-base (value #t))
    (timeout-seconds (value #t))
    (term-grace-seconds (value #t))
    (help (single-char #\h))))

(define required-options
  '(boot-bundle baseline kernel-sha256 initrd-sha256 config-sha256
                baseline-sha256 run-base))

(define (usage port program)
  (format port
          "usage: ~a --boot-bundle DIR --baseline RAW --kernel-sha256 HASH --initrd-sha256 HASH --config-sha256 HASH --baseline-sha256 HASH --run-base PRIVATE-DIR --dedicated-baseline [OPTIONS]\n"
          program))

(define (disposable-qemu-main argv)
  ;; Unlike Shepherd's long-lived process monitor, these bounded guardians
  ;; exist only for one synchronous invocation and one exec group at a time.
  (sigaction SIGCHLD SIG_DFL)
  (let ((program (car argv)))
    (catch #t
      (lambda ()
        (let ((options (getopt-long argv cli-options)))
          (when (option-ref options 'help #f)
            (usage (current-output-port) program)
            (exit 0))
          (for-each
           (lambda (name)
             (unless (option-ref options name #f)
               (usage (current-error-port) program)
               (runner-error (format #f "missing required --~a" name))))
           required-options)
          (run options)))
      (lambda (key . arguments)
        (cond
         ((eq? key 'book-execution-qemu-signal)
          (let ((signal-number (car arguments)))
            (format (current-error-port)
                    "FAIL: received signal ~a; owned QEMU group cleaned~%"
                    signal-number)
            (+ 128 signal-number)))
         ((eq? key 'book-execution-qemu-error)
          (format (current-error-port) "FAIL: ~a~%" (car arguments))
          1)
         (else
          (format (current-error-port) "FAIL: ~s ~s~%" key arguments)
          1))))))
