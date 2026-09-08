;;; Fixed child-side adapter for starting runsc with a donated Book Session FD.
;;; Guile's spawn helper starts this process safely after the state delegate's
;;; worker thread exists.  The adapter stops before runsc executes, allowing the
;;; authority to record the exact PID/start-time/process-group, then exposes
;;; only non-socket stdio and the connected Book Session socket at FD 3.
(use-modules (ice-9 ftw)
             (rnrs io ports)
             (srfi srfi-1))

(define linux-f-dupfd-cloexec 1030)
(define first-temporary-fd 4)
(define fixed-book-fd 3)

(define (fail message . details) (error message details))

(define (fd-open? fd)
  (catch 'system-error
    (lambda () (fcntl fd F_GETFD) #t)
    (lambda arguments #f)))

(define (fd-stat fd)
  (catch 'system-error
    (lambda () (stat fd))
    (lambda arguments #f)))

(define (fd-identity fd)
  (let ((info (fd-stat fd)))
    (and info
         (list (stat:type info) (stat:dev info) (stat:ino info)
               (stat:rdev info)))))

(define (same-fd-identity? left right)
  (let ((left-identity (fd-identity left))
        (right-identity (fd-identity right)))
    (and left-identity right-identity
         (equal? left-identity right-identity))))

(define (socket-fd? fd)
  (let ((info (fd-stat fd)))
    (and info (eq? (stat:type info) 'socket))))

(define (close-fd-quietly! fd)
  (catch 'system-error
    (lambda () (close-fdes fd))
    (lambda arguments #f)))

(define (open-fds)
  (sort
   (filter-map
    (lambda (entry)
      (let ((fd (string->number entry 10)))
        (and fd (fd-open? fd) fd)))
    (scandir "/proc/self/fd"
             (lambda (entry)
               (and (not (member entry '("." "..")))
                    (string->number entry 10)))))
   <))

(define (close-unrelated-fds!)
  (for-each
   (lambda (fd)
     (when (> fd fixed-book-fd) (close-fd-quietly! fd)))
   (open-fds)))

(define (retire-closed-standard-port! fd)
  ;; If a caller deliberately closed a standard descriptor, retire Guile's
  ;; still-owned port object before that descriptor number can be recycled.
  ;; This prevents a later port finalizer from closing a newly installed FD.
  (unless (fd-open? fd)
    (let ((port (case fd
                  ((0) (current-input-port))
                  ((1) (current-output-port))
                  ((2) (current-error-port))
                  (else #f))))
      (when (port? port)
        (catch #t
          (lambda () (close-port port))
          (lambda arguments #f))))))

(define (duplicate-to-fixed-fd! source target)
  ;; dup2(SOURCE, SOURCE) is a no-op, but spelling out that case also prevents
  ;; callers from closing an integer descriptor that they did not create.
  (unless (= source target) (dup2 source target))
  (fcntl target F_SETFD 0)
  target)

(define (move-temporary-above-fixed-fds! fd)
  (if (>= fd first-temporary-fd)
      fd
      (let ((moved (fcntl fd linux-f-dupfd-cloexec first-temporary-fd)))
        (close-fdes fd)
        moved)))

(define (open-stable-null flags)
  ;; Use an integer descriptor, not a Scheme port with a delayed finalizer.
  ;; If a standard descriptor was initially absent, move the temporary above
  ;; FD 3 before installing any replacement stdio descriptor.
  (move-temporary-above-fixed-fds!
   (open-fdes "/dev/null" (logior flags O_CLOEXEC))))

(define (call-with-owned-fd fd procedure)
  (dynamic-wind
    (lambda () #t)
    (lambda () (procedure fd))
    (lambda ()
      (when (fd-open? fd) (close-fd-quietly! fd)))))

(define (select-book-source-fd)
  ;; Production donation arrives as stdin.  Accepting an already-normalized FD
  ;; 3 as the source makes the remap total for the finite native edge tests and
  ;; keeps duplicate-to-fixed-fd! safe when SOURCE equals TARGET.
  (cond ((socket-fd? 0) 0)
        ((socket-fd? fixed-book-fd) fixed-book-fd)
        (else (fail "Book Session donation is not a socket on FD 0 or FD 3"))))

(define (normalize-descriptors!)
  (for-each retire-closed-standard-port! '(0 1 2))
  (let* ((source (select-book-source-fd))
         (book-identity (fd-identity source)))
    ;; Reserve FD 3 before opening /dev/null.  This is the BSG-1 ordering
    ;; invariant: /dev/null can never occupy and then lose the destination.
    (duplicate-to-fixed-fd! source fixed-book-fd)
    (unless (equal? (fd-identity fixed-book-fd) book-identity)
      (fail "FD 3 does not retain the donated Book Session identity"))
    (call-with-owned-fd
     (open-stable-null O_RDONLY)
     (lambda (null-input)
       (duplicate-to-fixed-fd! null-input 0)))
    ;; Preserve the authority's bounded stdout/stderr pipes.  If either output
    ;; was absent, or was itself an inherited socket capability, replace it
    ;; with write-only /dev/null rather than carrying the capability to exec.
    (let ((replace
           (filter (lambda (fd)
                     (or (not (fd-open? fd))
                         (socket-fd? fd)
                         (same-fd-identity? fd fixed-book-fd)))
                   '(1 2))))
      (when (pair? replace)
        (call-with-owned-fd
         (open-stable-null O_WRONLY)
         (lambda (null-output)
           (for-each
            (lambda (fd) (duplicate-to-fixed-fd! null-output fd))
            replace)))))
    (close-unrelated-fds!)
    (for-each (lambda (fd) (fcntl fd F_SETFD 0)) '(0 1 2 3))
    (let ((null-identity
           (let ((info (stat "/dev/null")))
             (list (stat:type info) (stat:dev info) (stat:ino info)
                   (stat:rdev info)))))
      (unless
          (and (equal? (open-fds) '(0 1 2 3))
               (equal? (fd-identity fixed-book-fd) book-identity)
               (eq? (stat:type (stat fixed-book-fd)) 'socket)
               (zero? (logand (fcntl fixed-book-fd F_GETFD) FD_CLOEXEC))
               (equal? (fd-identity 0) null-identity)
               (every (lambda (fd)
                        (and (fd-open? fd)
                             (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
                             (not (socket-fd? fd))
                             (not (same-fd-identity?
                                   fd fixed-book-fd))))
                      '(0 1 2)))
        (fail "runsc adapter descriptor roster/identity check failed")))))

(define (runsc-fd3-exec-main arguments)
  (unless (and (>= (length arguments) 4)
               (string=? (car arguments) "--directory")
               (string-prefix? "/" (cadr arguments))
               (string=? (caddr arguments) "--"))
    (fail "fixed runsc FD adapter requires --directory DIR -- COMMAND"))
  (let ((directory (cadr arguments))
        (command (cdddr arguments)))
    ;; No project or runtime code has run.  Publish a stable process identity
    ;; before descriptor rearrangement and the final exec.
    (setpgid 0 0)
    (kill (getpid) SIGSTOP)
    (normalize-descriptors!)
    (chdir directory)
    (apply execl (car command) command)))

(define %adapter-source-file (current-filename))
(define (invoked-as-script?)
  (and %adapter-source-file
       (pair? (command-line))
       (catch 'system-error
         (lambda ()
           (string=? (canonicalize-path (car (command-line)))
                     (canonicalize-path %adapter-source-file)))
         (lambda arguments #f))))

;; Loading this exact source with `guile -l` exposes the real normalizer to the
;; native descriptor matrix without executing it prematurely.  The production
;; `guile FILE ...` form still enters exactly once here.
(when (invoked-as-script?)
  (runsc-fd3-exec-main (cdr (command-line))))
