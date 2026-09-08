;;; Explicit host-test peer. Protocol bytes use BOOK_PROTOCOL_FD, never stdio.
(use-modules (book-protocol)
             (book-protocol blocking-io)
             (ice-9 format)
             (rnrs bytevectors))

(define protocol-fd
  (let ((text (getenv "BOOK_PROTOCOL_FD")))
    (or (and text (string->number text))
        (begin
          (format (current-error-port) "BOOK_PROTOCOL_FD is required~%")
          (exit 64)))))

(define protocol-port (fdopen protocol-fd "r+b"))

(define (all-c0-controls)
  (list->string
   (let loop ((codepoint 0) (characters '()))
     (if (= codepoint 32)
         (reverse characters)
         (loop (+ codepoint 1)
               (cons (integer->char codepoint) characters))))))

(define (c0-key/value-object)
  (let loop ((codepoint 0) (entries '()))
    (if (= codepoint 32)
        (reverse entries)
        (let ((control (string (integer->char codepoint))))
          (loop (+ codepoint 1) (cons (cons control control) entries))))))

(define (maximum-escaped-control-object)
  (let* ((overhead (- (bytevector-length (encode-frame '(("s" . "")))) 4))
         (available (- max-frame-size overhead))
         (control-count (quotient available 6))
         (padding-count (modulo available 6)))
    (list
     (cons "s"
           (string-append
            (make-string control-count (integer->char 0))
            (make-string padding-count #\x))))))

;; The Python test asserts that this diagnostic does not contaminate the
;; dedicated protocol socket.
(display "Guile conformance fixture diagnostic on stdout\n")
(force-output (current-output-port))

(catch 'book-protocol-error
  (lambda ()
    (when (getenv "BOOK_PROTOCOL_ORIGINATE_FIXTURES")
      (write-frame
       protocol-port
       (list (cons "origin" "guile")
             (cons "controls" (all-c0-controls))
             (cons "control-object" (c0-key/value-object))
             (cons "supplementary" "😀")
             (cons "negative-zero" -0.0)))
      (write-frame protocol-port (maximum-escaped-control-object)))
    (let loop ()
      (let ((message (read-frame protocol-port)))
        (unless (eof-object? message)
          (write-frame
           protocol-port
           (list (cons "from" "guile")
                 (cons "message" message)))
          (loop))))
    (close-port protocol-port))
  (lambda (_ message)
    (format (current-error-port) "Book Protocol error: ~a~%" message)
    (close-port protocol-port)
    (exit 2)))
