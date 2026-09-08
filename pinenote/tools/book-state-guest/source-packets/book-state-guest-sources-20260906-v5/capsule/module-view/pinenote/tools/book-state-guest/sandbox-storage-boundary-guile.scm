;;; Fixed in-sandbox storage-boundary probe for the Guile Book fixture.
;;;
;;; This is loaded by Guile inside runsc immediately before the unchanged
;;; reader-join v2 book.  It knows the public authority paths, but receives no
;;; authority descriptor, storage grant, credential, or private UI channel.
(use-modules (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define state-root "/var/lib/wilkbook-book-state-demo")
(define state-sentinel
  "/var/lib/wilkbook-book-state-demo/.sandbox-boundary-sentinel-v1")
(define state-database
  "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite")
(define private-ui-device
  "/dev/virtio-ports/org.wilkbook.book-interaction")
(define denied-errnos (list ENOENT EACCES EPERM))

(define (fail message . values)
  (apply error (string-append "sandbox storage boundary: " message) values))

(define (require-denied-errno label arguments)
  (let ((value (system-error-errno arguments)))
    (unless (memv value denied-errnos)
      (apply throw 'system-error arguments))
    value))

(define (require-open-denied label path flags)
  (catch 'system-error
    (lambda ()
      (let ((descriptor (open-fdes path flags)))
        (close-fdes descriptor)
        (fail "forbidden path opened" label path)))
    (lambda arguments
      (require-denied-errno label arguments))))

(define (require-stat-denied label path)
  (catch 'system-error
    (lambda ()
      (stat path)
      (fail "forbidden path was visible" label path))
    (lambda arguments
      (require-denied-errno label arguments))))

(define (live-fd-record name)
  (let ((descriptor (string->number name 10)))
    (and descriptor
         (catch 'system-error
           (lambda ()
             (let ((flags (fcntl descriptor F_GETFD))
                   (info (stat descriptor))
                   (target
                    (readlink (string-append "/proc/self/fd/" name))))
               (list descriptor flags info target)))
           (lambda arguments
             (if (= (system-error-errno arguments) EBADF)
                 #f
                 (apply throw 'system-error arguments)))))))

(require-stat-denied "state-root-stat" state-root)
(require-stat-denied "state-sentinel-stat" state-sentinel)
(for-each
 (lambda (entry)
   (require-open-denied (string-append (car entry) "-read")
                        (cdr entry) O_RDONLY)
   (require-open-denied (string-append (car entry) "-write")
                        (cdr entry) O_WRONLY))
 `(("state-sentinel" . ,state-sentinel)
   ("state-database" . ,state-database)
   ("private-ui-device" . ,private-ui-device)))

(let ((mountinfo
       (call-with-input-file "/proc/self/mountinfo" get-string-all)))
  (for-each
   (lambda (path)
     (when (string-contains mountinfo path)
       (fail "forbidden authority path entered sandbox mountinfo" path)))
   (list state-root private-ui-device)))

(let ((records
       (sort (filter-map live-fd-record (scandir "/proc/self/fd"))
             (lambda (left right) (< (car left) (car right))))))
  ;; Guile legitimately keeps its currently loaded source and internal wakeup
  ;; pipes open with FD_CLOEXEC.  The accepted adapter already proved the exact
  ;; pre-exec 0/1/2/3 roster.  At this later point reject only capabilities an
  ;; interpreter could have inherited: another socket or character device, a
  ;; non-CLOEXEC FD, or an FD naming either authority path.
  (unless (every (lambda (descriptor)
                   (find (lambda (record) (= (car record) descriptor)) records))
                 '(0 1 2 3))
    (fail "one required standard/Book-Session descriptor is absent" records))
  (unless (and (eq? (stat:type (stat 3)) 'socket)
               (zero? (logand (fcntl 3 F_GETFD) FD_CLOEXEC))
               (every (lambda (descriptor)
                        (not (eq? (stat:type (stat descriptor)) 'socket)))
                      '(0 1 2)))
    (fail "FD 3 is not the sole inherited socket capability"))
  (for-each
   (lambda (record)
     (let ((descriptor (list-ref record 0))
           (flags (list-ref record 1))
           (info (list-ref record 2))
           (target (list-ref record 3)))
       (when (> descriptor 3)
          (unless (and (positive? (logand flags FD_CLOEXEC))
                      (not (eq? (stat:type info) 'socket))
                      (not (eq? (stat:type info) 'char-special))
                      (not (string-contains target state-root))
                      (not (string-contains target private-ui-device)))
           (fail "interpreter-owned FD exposes another capability" record)))))
   records))

(format #t
        "BOOK_STATE_SANDBOX_BOUNDARY: language=guile result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3~%")
(force-output)
