;;; Runs inside gVisor immediately before the fixed Guile note. The trusted
;;; database, UI socket, and every other authority descriptor must be absent;
;;; FD 3 is the sole connected application capability.
(use-modules (ice-9 ftw) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))

(define state-root "/data/wilkbook/book-state")
(define state-database "/data/wilkbook/book-state/book-state-v1.sqlite")
(define private-ui-socket "/run/wilkbook-book-state/control.sock")
(define denied-errnos (list ENOENT EACCES EPERM))

(define (fail message . values)
  (apply error (string-append "device sandbox storage boundary: " message) values))

(define (require-denied label thunk)
  (catch 'system-error
    (lambda () (thunk) (fail "forbidden authority resource was visible" label))
    (lambda arguments
      (unless (memv (system-error-errno arguments) denied-errnos)
        (apply throw 'system-error arguments)))))

(for-each
 (lambda (path)
   (require-denied path (lambda () (stat path)))
   (require-denied path
                   (lambda ()
                     (let ((fd (open-fdes path O_RDONLY)))
                       (close-fdes fd)))))
 (list state-root state-database private-ui-socket))

(let ((mountinfo (call-with-input-file "/proc/self/mountinfo" get-string-all)))
  (for-each
   (lambda (path)
     (when (string-contains mountinfo path)
       (fail "authority path entered sandbox mountinfo" path)))
   (list state-root private-ui-socket)))

(let ((records
       (filter-map
        (lambda (name)
          (let ((fd (string->number name 10)))
            (and fd
                 (catch 'system-error
                   (lambda ()
                     (list fd (fcntl fd F_GETFD) (stat fd)
                           (readlink (string-append "/proc/self/fd/" name))))
                   (lambda arguments #f)))))
        (scandir "/proc/self/fd"))))
  (unless (and (every (lambda (fd)
                        (find (lambda (record) (= (car record) fd)) records))
                      '(0 1 2 3))
               (eq? (stat:type (stat 3)) 'socket)
               (zero? (logand (fcntl 3 F_GETFD) FD_CLOEXEC))
               (every (lambda (fd) (not (eq? (stat:type (stat fd)) 'socket)))
                      '(0 1 2)))
    (fail "FD 3 is not the sole inherited socket capability"))
  (for-each
   (lambda (record)
     (let ((fd (list-ref record 0))
           (flags (list-ref record 1))
           (info (list-ref record 2))
           (target (list-ref record 3)))
       (when (> fd 3)
         (unless (and (positive? (logand flags FD_CLOEXEC))
                      (not (eq? (stat:type info) 'socket))
                      (not (eq? (stat:type info) 'char-special))
                      (not (string-contains target state-root))
                      (not (string-contains target private-ui-socket)))
           (fail "interpreter-owned FD exposes another capability" record)))))
   records))

(format #t
        "BOOK_STATE_SANDBOX_BOUNDARY: language=guile result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3~%")
(force-output)
