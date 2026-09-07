(use-modules (private-control)
             (rnrs bytevectors)
             (srfi srfi-1))

(define (check condition message)
  (unless condition (error message)))

(define (raises? thunk)
  (catch 'book-state-reader-control-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (without-newline bytes)
  (let* ((length (bytevector-length bytes))
         (result (make-bytevector (- length 1))))
    (bytevector-copy! bytes 0 result 0 (- length 1))
    result))

(for-each
 (lambda (kind)
   (let* ((encoded
           (encode-control-line kind 7 "élan λ" reader-command-kinds))
          (decoded
           (decode-control-line (without-newline encoded)
                                reader-command-kinds)))
     (check (equal? decoded (list kind 7 "élan λ"))
            "command did not round trip")))
 reader-command-kinds)

(for-each
 (lambda (kind)
   (let* ((encoded (encode-control-line kind 9 "東京" reader-event-kinds))
          (decoded
           (decode-control-line (without-newline encoded) reader-event-kinds)))
     (check (equal? decoded (list kind 9 "東京"))
            "event did not round trip")))
 reader-event-kinds)

(check (not (any (lambda (kind) (memq kind reader-event-kinds))
                 reader-command-kinds))
       "command and event enumerations overlap")
(check (equal? commit-failure-codes
               '(receipt-quota-exhausted read-only storage-failure conflict))
       "commit failure code enumeration changed")
(check (equal? reader-status-values
               '(loaded-absent loaded-value dirty pending saved failed))
       "status enumeration changed")

(define exact-limit (make-string 4096 #\x))
(check (= (bytevector-length
           (encode-control-line 'load-value 1 exact-limit
                                reader-command-kinds))
          (+ 10 1 1 1 8192 1))
       "exact 4096-byte payload encoded at an unexpected size")
(check (raises?
        (lambda ()
          (encode-control-line 'load-value 1 (make-string 4097 #\x)
                               reader-command-kinds)))
       "4097-byte payload was accepted")
(check (raises?
        (lambda ()
          (encode-control-line 'load-value 1 (string #\nul)
                               reader-command-kinds)))
       "U+0000 was accepted by the ordinary widget fixture")
(check (raises?
        (lambda ()
          (encode-control-line 'ready 1 "" reader-command-kinds)))
       "wrong-direction kind was accepted")
(check (raises?
        (lambda ()
          (decode-control-line (string->utf8 "future|1|")
                               reader-command-kinds)))
       "unknown command kind was accepted")
(check (raises?
        (lambda ()
          (decode-control-line (string->utf8 "open|01|")
                               reader-command-kinds)))
       "noncanonical generation was accepted")
(check (raises?
        (lambda ()
          (decode-control-line (string->utf8 "open|1|C3A9")
                               reader-command-kinds)))
       "uppercase hex was accepted")
(check (raises?
        (lambda ()
          (decode-control-line (string->utf8 "load-value|1|c0af")
                               reader-command-kinds)))
       "malformed UTF-8 was accepted")

(display "PASS: closed state-reader control grammar, bounds, UTF-8, and NUL scope\n")
