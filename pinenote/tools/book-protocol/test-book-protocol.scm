(use-modules (book-protocol)
             (book-protocol blocking-io)
             (json)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-64))

(define duplicate-probe-hook-for-test
  (@@ (book-protocol) duplicate-probe-hook))
(define json-encoder-for-test
  (@@ (book-protocol) json-encoder))

(define (put-length! bytevector length)
  (bytevector-u8-set! bytevector 0 (logand (ash length -24) #xff))
  (bytevector-u8-set! bytevector 1 (logand (ash length -16) #xff))
  (bytevector-u8-set! bytevector 2 (logand (ash length -8) #xff))
  (bytevector-u8-set! bytevector 3 (logand length #xff)))

(define (raw-frame-bytevector payload)
  (let* ((length (bytevector-length payload))
         (frame (make-bytevector (+ length 4))))
    (put-length! frame length)
    (bytevector-copy! payload 0 frame 4 length)
    frame))

(define (raw-frame text)
  (raw-frame-bytevector (string->utf8 text)))

(define (bytevector-prefix source length)
  (let ((result (make-bytevector length)))
    (bytevector-copy! source 0 result 0 length)
    result))

(define (frame-payload frame)
  (let* ((length (- (bytevector-length frame) 4))
         (payload (make-bytevector length)))
    (bytevector-copy! frame 4 payload 0 length)
    payload))

(define (raises-protocol-error? thunk)
  (catch 'book-protocol-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (nested-object depth)
  (let loop ((remaining depth) (value 0))
    (if (zero? remaining)
        value
        (loop (- remaining 1) (list (cons "child" value))))))

(define (nested-json depth)
  (let loop ((remaining depth) (text "0"))
    (if (zero? remaining)
        text
        (loop (- remaining 1)
              (string-append "{\"child\":" text "}")))))

(define malformed-object-vectors
  (json-string->scm
   (call-with-input-file "malformed-object-vectors.json" get-string-all)
   #:ordered #t))

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

(define (payload-has-raw-control? payload)
  (let loop ((index 0))
    (and (< index (bytevector-length payload))
         (or (< (bytevector-u8-ref payload index) 32)
             (loop (+ index 1))))))

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

(define (numbered-entries count)
  (let loop ((number 0) (entries '()))
    (if (= number count)
        (reverse entries)
        (loop (+ number 1)
              (cons (cons (number->string number) 0) entries)))))

(test-begin "book-protocol-guile")

(let* ((message (list (cons "type" "open")
                      (cons "title" "Café 📖")
                      (cons "flags" (vector #t #f 'null))))
       (frame (encode-frame message)))
  (test-equal "four-byte big-endian length"
    (- (bytevector-length frame) 4)
    (frame-payload-length
     (u8-list->bytevector
      (list (bytevector-u8-ref frame 0)
            (bytevector-u8-ref frame 1)
            (bytevector-u8-ref frame 2)
            (bytevector-u8-ref frame 3)))))
  (test-equal "round trip" message (decode-frame frame)))

(test-equal "smallest object"
  (u8-list->bytevector '(0 0 0 2 123 125))
  (encode-frame '()))

(let* ((overhead (- (bytevector-length (encode-frame '(("s" . "")))) 4))
       (message (list (cons "s" (make-string (- max-frame-size overhead) #\x))))
       (frame (encode-frame message)))
  (test-equal "exact 64 KiB payload" (+ max-frame-size 4)
    (bytevector-length frame))
  (test-equal "exact 64 KiB round trip" message (decode-frame frame))
  (test-assert "one byte over 64 KiB is rejected"
    (raises-protocol-error?
     (lambda ()
       (encode-frame
        (list (cons "s" (make-string (+ 1 (- max-frame-size overhead)) #\x))))))))

(test-assert "zero frame length is rejected"
  (raises-protocol-error?
   (lambda () (decode-frame (u8-list->bytevector '(0 0 0 0))))))

(test-assert "oversize frame length is rejected before payload"
  (raises-protocol-error?
   (lambda () (decode-frame (u8-list->bytevector '(0 1 0 1))))))

(let loop ((index 0))
  (when (< index (vector-length malformed-object-vectors))
    (let* ((vector (vector-ref malformed-object-vectors index))
           (name (assoc-ref vector "name"))
           (payload (assoc-ref vector "payload")))
      (test-assert (string-append "structural grammar rejects " name)
        (raises-protocol-error? (lambda () (decode-frame (raw-frame payload))))))
    (loop (+ index 1))))

(test-equal "guile-json ordered mode retains duplicate pairs"
  2
  (length (json-string->scm "{\"same\":1,\"same\":2}" #:ordered #t)))

(test-assert "duplicate keys retained by guile-json are rejected by wrapper"
  (raises-protocol-error?
   (lambda () (decode-frame (raw-frame "{\"same\":1,\"same\":2}")))))

(test-assert "escaped and direct duplicate keys compare after decoding"
  (raises-protocol-error?
   (lambda ()
     (decode-frame (raw-frame "{\"😀\":1,\"\\ud83d\\ude00\":2}")))))

(test-equal "valid escaped surrogate pair"
  '(("text" . "😀"))
  (decode-frame (raw-frame "{\"text\":\"\\ud83d\\ude00\"}")))

(let* ((controls (all-c0-controls))
       (message (list (cons "controls" controls)
                      (cons "control-object" (c0-key/value-object))
                      (cons "supplementary" "😀")))
       (frame (encode-frame message))
       (payload (frame-payload frame)))
  (test-assert "Guile encoder emits no raw C0 bytes"
    (not (payload-has-raw-control? payload)))
  (test-assert "Guile encoder deliberately escapes supplementary Unicode"
    (string-contains (utf8->string payload) "\\ud83d\\ude00"))
  (test-equal "all C0 controls round trip in keys and values"
    message
    (decode-frame frame)))

(let* ((message (maximum-escaped-control-object))
       (frame (encode-frame message)))
  (test-equal "escaped-control payload reaches exact 64 KiB"
    (+ max-frame-size 4)
    (bytevector-length frame))
  (test-equal "exact escaped-control frame round trips"
    message
    (decode-frame frame)))

(test-assert "lone surrogate is rejected"
  (raises-protocol-error?
   (lambda () (decode-frame (raw-frame "{\"text\":\"\\ud800\"}")))))

(let ((malformed
       (raw-frame-bytevector
        (u8-list->bytevector '(123 34 116 101 120 116 34 58 34 255 34 125)))))
  (test-assert "malformed UTF-8 is rejected"
    (raises-protocol-error? (lambda () (decode-frame malformed)))))

(test-equal "depth 16 is accepted"
  (nested-object max-nesting)
  (decode-frame (raw-frame (nested-json max-nesting))))

(test-assert "depth 17 is rejected by the pre-parser scan"
  (raises-protocol-error?
   (lambda () (decode-frame (raw-frame (nested-json (+ max-nesting 1)))))))

(test-equal "brackets and escaped quotes in strings do not count as depth"
  '(("text" . "[{ escaped quote: \" and } ]"))
  (decode-frame
   (raw-frame "{\"text\":\"[{ escaped quote: \\\" and } ]\"}")))

(test-equal "safe integer boundaries"
  (list (cons "low" (- max-safe-integer))
        (cons "high" max-safe-integer))
  (decode-frame
   (raw-frame
    "{\"low\":-9007199254740991,\"high\":9007199254740991}")))

(for-each
 (lambda (text)
   (test-assert (string-append "numeric policy rejects " text)
     (raises-protocol-error? (lambda () (decode-frame (raw-frame text))))))
 '("{\"n\":9007199254740992}"
   "{\"n\":9.007199254740992e15}"
   "{\"n\":1e400}"
   "{\"n\":1e-4000}"
   "{\"n\":0e1001}"))

(test-equal "zero at exponent limit and finite fraction"
  '(("zero" . 0) ("fraction" . 0.125))
  (decode-frame (raw-frame "{\"zero\":0e1000,\"fraction\":0.125}")))

(let* ((entries (numbered-entries 7404))
       (base (append entries '(("pad" . ""))))
       (base-size (- (bytevector-length (encode-frame base)) 4))
       (message
        (append entries
                (list (cons "pad"
                            (make-string (- max-frame-size base-size) #\x)))))
       (frame (encode-frame message))
       (probes 0))
  (test-equal "maximum-width unique object is exactly 64 KiB"
    (+ max-frame-size 4)
    (bytevector-length frame))
  (parameterize
      ((duplicate-probe-hook-for-test
        (lambda (key) (set! probes (+ probes 1)))))
    (decode-frame frame))
  (test-equal "hash duplicate detector performs one probe per member"
    (length message)
    probes))

(let ((serializer-called? #f))
  (parameterize
      ((json-encoder-for-test
        (lambda (message)
          (set! serializer-called? #t)
          (throw 'serializer-called))))
    (test-assert "one-MiB string rejects before Guile JSON serializer"
      (raises-protocol-error?
       (lambda () (encode-frame `(("s" . ,(make-string (* 1024 1024) #\x))))))))
  (test-assert "oversized string did not invoke Guile JSON serializer"
    (not serializer-called?)))

(let ((serializer-called? #f))
  (parameterize
      ((json-encoder-for-test
        (lambda (message)
          (set! serializer-called? #t)
          (throw 'serializer-called))))
    (test-assert "impossibly wide vector rejects before Guile JSON serializer"
      (raises-protocol-error?
       (lambda ()
         (encode-frame
          (list (cons "items" (make-vector 40000 'null))))))))
  (test-assert "oversized vector did not invoke Guile JSON serializer"
    (not serializer-called?)))

(for-each
 (lambda (text)
   (test-assert (string-append "non-object top level rejects " text)
     (raises-protocol-error? (lambda () (decode-frame (raw-frame text))))))
 '("[]" "17" "true" "null" "\"string\""))

(let* ((message '(("blocking" . #t)))
       (port (open-bytevector-input-port (encode-frame message))))
  (test-equal "blocking reader reads one frame" message (read-frame port))
  (test-assert "blocking reader returns clean EOF" (eof-object? (read-frame port))))

(let ((port (open-bytevector-input-port (u8-list->bytevector '(0 0)))))
  (test-assert "blocking reader rejects truncated header"
    (raises-protocol-error? (lambda () (read-frame port)))))

(let* ((frame (encode-frame '(("incomplete" . #t))))
       (partial (bytevector-prefix frame (- (bytevector-length frame) 1)))
       (port (open-bytevector-input-port partial)))
  (test-assert "blocking reader rejects truncated payload"
    (raises-protocol-error? (lambda () (read-frame port)))))

(call-with-values open-bytevector-output-port
  (lambda (port get-bytevector)
    (let ((message '(("blocking-write" . #t))))
      (write-frame port message)
      (test-equal "blocking writer emits codec frame"
        (encode-frame message)
        (get-bytevector)))))

(test-end "book-protocol-guile")
