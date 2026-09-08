;;; Bounded byte-transparent recorder for the private guest/KOReader UI stream.
(define-module (two-boot ui-proxy)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:export (make-private-ui-proxy
            pump-private-ui-proxy!
            private-ui-proxy-complete?
            private-ui-proxy-snapshot
            close-private-ui-proxy!))

(define transfer-budget 4096)
(define queue-limit (* 64 1024))
(define transcript-limit (* 256 1024))
(define libc (dynamic-link))
(define c-read
  (pointer->procedure ssize_t (dynamic-func "read" libc)
                      (list int '* size_t) #:return-errno? #t))
(define c-write
  (pointer->procedure ssize_t (dynamic-func "write" libc)
                      (list int '* size_t) #:return-errno? #t))

(define-record-type <direction>
  (%make-direction label source destination capture pending offset observed
                   eof? shut?)
  direction?
  (label direction-label)
  (source direction-source)
  (destination direction-destination)
  (capture direction-capture)
  (pending direction-pending set-direction-pending!)
  (offset direction-offset set-direction-offset!)
  (observed direction-observed set-direction-observed!)
  (eof? direction-eof? set-direction-eof?!)
  (shut? direction-shut? set-direction-shut?!))

(define-record-type <private-ui-proxy>
  (%make-private-ui-proxy guest-to-reader reader-to-guest closed?)
  private-ui-proxy?
  (guest-to-reader proxy-guest-to-reader)
  (reader-to-guest proxy-reader-to-guest)
  (closed? proxy-closed? set-proxy-closed?!))

(define (proxy-error message . arguments)
  (throw 'book-state-two-boot-ui-proxy-error
         (apply format #f message arguments)))

(define (close-port-quietly! port)
  (when (and port (port? port) (not (port-closed? port)))
    (catch 'system-error (lambda () (close-port port)) (lambda _ #f))))

(define (set-nonblocking-cloexec! port)
  (let ((fd (fileno port)))
    (fcntl fd F_SETFL (logior (fcntl fd F_GETFL) O_NONBLOCK))
    (fcntl fd F_SETFD (logior (fcntl fd F_GETFD) FD_CLOEXEC))
    (setvbuf port 'none)
    (unless (and (positive? (logand (fcntl fd F_GETFL) O_NONBLOCK))
                 (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC)))
      (proxy-error "private UI proxy descriptor flags did not stick"))))

(define (open-capture path)
  (let ((fd (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       #o600)))
    (chmod fd #o600)
    (fdopen fd "wb0")))

(define (empty-bytes) (make-bytevector 0))

(define (bytevector-slice source start end)
  (let ((result (make-bytevector (- end start))))
    (bytevector-copy! source start result 0 (- end start))
    result))

(define (make-private-ui-proxy qemu-side reader-side
                               guest-to-reader-path reader-to-guest-path)
  ;; QEMU-SIDE and READER-SIDE are the two coordinator-owned endpoints.  The
  ;; caller separately donates the other socketpair endpoint to KOReader.
  (unless (and (port? qemu-side) (port? reader-side)
               (eq? (stat:type (stat qemu-side)) 'socket)
               (eq? (stat:type (stat reader-side)) 'socket))
    (proxy-error "private UI proxy requires two sockets"))
  (set-nonblocking-cloexec! qemu-side)
  (set-nonblocking-cloexec! reader-side)
  (%make-private-ui-proxy
   (%make-direction 'guest-to-reader qemu-side reader-side
                    (open-capture guest-to-reader-path)
                    (empty-bytes) 0 0 #f #f)
   (%make-direction 'reader-to-guest reader-side qemu-side
                    (open-capture reader-to-guest-path)
                    (empty-bytes) 0 0 #f #f)
   #f))

(define (attempt thunk)
  (call-with-values thunk cons))

(define (would-block? errno)
  (memv errno (list EAGAIN EWOULDBLOCK)))

(define (direction-pending-bytes direction)
  (- (bytevector-length (direction-pending direction))
     (direction-offset direction)))

(define (shut-destination-if-done! direction)
  (when (and (direction-eof? direction)
             (zero? (direction-pending-bytes direction))
             (not (direction-shut? direction)))
    (catch 'system-error
      (lambda () (shutdown (direction-destination direction) 1))
      (lambda arguments
        (unless (memv (system-error-errno arguments) (list ENOTCONN EPIPE))
          (apply throw 'system-error arguments))))
    (set-direction-shut?! direction #t)))

(define (pump-write! direction)
  (let ((count (direction-pending-bytes direction)))
    (when (> count 0)
      (let* ((pending (direction-pending direction))
             (offset (direction-offset direction))
             (base (bytevector->pointer pending))
             (pointer (make-pointer (+ (pointer-address base) offset)))
             (result (attempt
                      (lambda ()
                        (c-write (fileno (direction-destination direction))
                                 pointer (min count transfer-budget)))))
             (written (car result))
             (errno (cdr result)))
        (cond
         ((and (= written -1) (would-block? errno)) #f)
         ((and (= written -1) (= errno EINTR)) #f)
         ((or (<= written 0) (> written (min count transfer-budget)))
          (proxy-error "private UI ~a write failed: ~a"
                       (direction-label direction) errno))
         (else
          (let ((next (+ offset written)))
            (if (= next (bytevector-length pending))
                (begin
                  (set-direction-pending! direction (empty-bytes))
                  (set-direction-offset! direction 0))
                 (set-direction-offset! direction next)))))))))

(define (pump-read! direction)
  (when (and (not (direction-eof? direction))
             (zero? (direction-pending-bytes direction)))
    (let* ((buffer (make-bytevector transfer-budget))
           (result (attempt
                    (lambda ()
                      (c-read (fileno (direction-source direction))
                              (bytevector->pointer buffer) transfer-budget))))
           (received (car result))
           (errno (cdr result)))
      (cond
       ((and (= received -1) (would-block? errno)) #f)
       ((and (= received -1) (= errno EINTR)) #f)
       ((negative? received)
        (proxy-error "private UI ~a read failed: ~a"
                     (direction-label direction) errno))
       ((zero? received) (set-direction-eof?! direction #t))
       ((> received transfer-budget)
        (proxy-error "private UI read exceeded its fixed budget"))
       (else
        (let ((next (+ (direction-observed direction) received)))
          (when (> next transcript-limit)
            (proxy-error "private UI ~a transcript exceeded 256 KiB"
                         (direction-label direction)))
          (let ((chunk (bytevector-slice buffer 0 received)))
            (put-bytevector (direction-capture direction) chunk)
            (force-output (direction-capture direction))
            (set-direction-observed! direction next)
            (set-direction-pending! direction chunk)
            (set-direction-offset! direction 0))))))))

(define (pump-direction! direction)
  (pump-write! direction)
  (pump-read! direction)
  ;; A successful read can normally be forwarded in the same bounded turn.
  (pump-write! direction)
  (when (> (direction-pending-bytes direction) queue-limit)
    (proxy-error "private UI proxy queue exceeded its bound"))
  (shut-destination-if-done! direction))

(define (pump-private-ui-proxy! proxy)
  (unless (and (private-ui-proxy? proxy) (not (proxy-closed? proxy)))
    (proxy-error "private UI proxy is not live"))
  (pump-direction! (proxy-guest-to-reader proxy))
  (pump-direction! (proxy-reader-to-guest proxy))
  (private-ui-proxy-complete? proxy))

(define (private-ui-proxy-complete? proxy)
  (and (private-ui-proxy? proxy)
       (every (lambda (direction)
                (and (direction-eof? direction)
                     (zero? (direction-pending-bytes direction))))
              (list (proxy-guest-to-reader proxy)
                    (proxy-reader-to-guest proxy)))))

(define (private-ui-proxy-snapshot proxy)
  `((schema . 1)
    (guest-to-reader-bytes
     . ,(direction-observed (proxy-guest-to-reader proxy)))
    (reader-to-guest-bytes
     . ,(direction-observed (proxy-reader-to-guest proxy)))
    (guest-to-reader-eof . ,(direction-eof? (proxy-guest-to-reader proxy)))
    (reader-to-guest-eof . ,(direction-eof? (proxy-reader-to-guest proxy)))
    (complete . ,(private-ui-proxy-complete? proxy))))

(define (close-private-ui-proxy! proxy)
  (when (and (private-ui-proxy? proxy) (not (proxy-closed? proxy)))
    (set-proxy-closed?! proxy #t)
    (for-each
     (lambda (direction)
       (close-port-quietly! (direction-capture direction)))
     (list (proxy-guest-to-reader proxy) (proxy-reader-to-guest proxy)))
    ;; Each network endpoint appears in both directional records.  Close once.
    (close-port-quietly! (direction-source (proxy-guest-to-reader proxy)))
    (close-port-quietly! (direction-source (proxy-reader-to-guest proxy)))))
