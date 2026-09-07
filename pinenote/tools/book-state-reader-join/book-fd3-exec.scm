;;; Minimal child-side descriptor adapter for Guile's accepted spawn helper.
;;; The selected input socket arrives as FD 0 and is moved to sole application
;;; FD 3 before the fixed book executable starts.
(use-modules (ice-9 ftw)
             (rnrs io ports)
             (srfi srfi-1))

(define (fail message . details) (error message details))

(define (close-unrelated-fds!)
  (for-each
   (lambda (entry)
     (let ((fd (string->number entry 10)))
       (when (and fd (> fd 3))
         (catch 'system-error
           (lambda () (close-fdes fd))
           (lambda arguments #f)))))
   (scandir "/proc/self/fd"
            (lambda (entry)
              (and (not (member entry '("." "..")))
                   (string->number entry 10))))))

(let ((arguments (cdr (command-line))))
  (unless (>= (length arguments) 1)
    (fail "FD adapter requires an exact executable"))
  ;; The parent records this stopped process before it can execute project book
  ;; code.  PID/start-time survive the later exec.
  (setpgid 0 0)
  (kill (getpid) SIGSTOP)
  (let ((null-input (open-file "/dev/null" "r")))
    (setrlimit 'fsize (* 128 1024) (* 128 1024))
    (dup2 0 3)
    (fcntl 3 F_SETFD 0)
    (dup2 (fileno null-input) 0)
    (close-unrelated-fds!)
    (unless (and (zero? (logand (fcntl 3 F_GETFD) FD_CLOEXEC))
                 (eq? (stat:type (stat 3)) 'socket))
      (fail "FD adapter did not create donated socket FD 3"))
    (format #t "BOOK_STATE_READER_JOIN_SPAWN: book:fd-hygiene:only-stdio-and-donated~%")
    (force-output)
    (apply execl (car arguments) (car arguments) (cdr arguments))))
