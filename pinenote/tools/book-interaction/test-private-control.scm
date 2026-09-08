(use-modules (private-control)
             (rnrs bytevectors)
             (srfi srfi-64))

(define (control-error? thunk)
  (catch 'book-interaction-control-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(test-begin "book-interaction-private-control")

(let* ((value "Input λ line\nsecond line")
       (encoded
        (encode-control-line 'input-update 7 value reader-command-kinds))
       (line (bytevector-slice encoded 0 (- (bytevector-length encoded) 1))))
  (test-equal "private command round trips exact UTF-8"
    `(input-update 7 ,value)
    (decode-control-line line reader-command-kinds)))

(test-equal "private event round trips an empty value"
  '(ready 1 "")
  (let* ((encoded (encode-control-line 'ready 1 "" reader-event-kinds))
         (line (bytevector-slice encoded 0 (- (bytevector-length encoded) 1))))
    (decode-control-line line reader-event-kinds)))

(test-assert "command cannot cross into event direction"
  (control-error?
   (lambda ()
     (encode-control-line 'finish 1 "" reader-event-kinds))))

(test-assert "event cannot cross into command direction"
  (control-error?
   (lambda ()
     (decode-control-line (string->utf8 "ready|1|")
                          reader-command-kinds))))

(for-each
 (lambda (line)
   (test-assert (string-append "reject malformed line: " line)
     (control-error?
      (lambda ()
        (decode-control-line (string->utf8 line) reader-event-kinds)))))
 '("ready|0|"
   "ready|01|"
   "ready|1.0|"
   "ready|1000001|"
   "ready|١|"
   "ready|1|0"
   "ready|1|gg"
   "ready|1|00|"
   "READY|1|"))

(test-assert "reject invalid UTF-8 after hex decoding"
  (control-error?
   (lambda ()
     (decode-control-line (string->utf8 "ready|1|ff")
                          reader-event-kinds))))

(test-assert "encoded values retain the 4096-byte bound"
  (= (bytevector-length
      (encode-control-line 'present 1 (make-string 4096 #\x)
                           reader-command-kinds))
     8203))

(test-assert "encoded values reject byte 4097"
  (control-error?
   (lambda ()
     (encode-control-line 'present 1 (make-string 4097 #\x)
                          reader-command-kinds))))

(test-end "book-interaction-private-control")
