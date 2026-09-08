;;; Blocking port adapter for the pure Book Protocol frame codec.
(define-module (book-protocol blocking-io)
  #:use-module (book-protocol)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:export (read-frame write-frame))

(define (read-exactly port count allow-clean-eof?)
  (let ((buffer (make-bytevector count)))
    (let loop ((offset 0))
      (if (= offset count)
          buffer
          (let ((read (get-bytevector-n! port buffer offset (- count offset))))
            (cond
             ((eof-object? read)
              (if (and allow-clean-eof? (zero? offset))
                  read
                  (protocol-error "EOF truncated a Book Protocol frame")))
             ((zero? read) (loop offset))
             (else (loop (+ offset read)))))))))

(define (read-frame port)
  "Read one frame from PORT, blocking as needed; return EOF at a frame boundary."
  (let ((header (read-exactly port 4 #t)))
    (if (eof-object? header)
        header
        (decode-payload
         (read-exactly port (frame-payload-length header) #f)))))

(define (write-frame port message)
  "Encode and write one complete frame to PORT, then flush the blocking port."
  (put-bytevector port (encode-frame message))
  (force-output port))
