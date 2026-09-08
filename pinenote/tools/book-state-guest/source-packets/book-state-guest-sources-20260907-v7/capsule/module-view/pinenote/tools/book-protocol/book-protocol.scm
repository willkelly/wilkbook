;;; Experimental Guile implementation of the Book Protocol frame contract.
(define-module (book-protocol)
  #:use-module (ice-9 hash-table)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:export (max-frame-size
            max-nesting
            max-safe-integer
            protocol-error
            encode-frame
            decode-frame
            decode-payload
            frame-payload-length))

(define max-frame-size (* 64 1024))
(define max-nesting 16)
(define max-safe-integer (- (expt 2 53) 1))
(define max-decimal-exponent 1000)

(define (protocol-error message)
  (throw 'book-protocol-error message))

(define duplicate-probe-hook (make-parameter (lambda (key) #t)))
(define json-encoder
  (make-parameter
   (lambda (message)
     ;; Unicode mode is required for guile-json 4.7.3 to escape every C0
     ;; control. It also deliberately escapes code points above U+00FF.
     (scm->json-string message
                       #:unicode #t
                       #:null 'null
                       #:validate #t
                       #:pretty #f))))

(define (check-number! value)
  (cond
   ((and (integer? value) (exact? value))
    (when (> (abs value) max-safe-integer)
      (protocol-error "JSON integer is outside the safe-integer range")))
   ((and (real? value) (inexact? value))
    (unless (finite? value)
      (protocol-error "JSON number is not a finite binary64 value"))
    (when (and (integer? value) (> (abs value) max-safe-integer))
      (protocol-error
       "integral JSON number is outside the safe-integer range")))
   (else
    ;; Exact non-integer rationals and complex values are Guile extensions,
    ;; not values accepted by the Python reference encoder.
    (protocol-error "JSON number must be a safe integer or binary64 value"))))

(define (spend-budget remaining amount)
  (cond
   ((not remaining) #f)
   ((> amount remaining)
    (protocol-error
     "JSON object exceeds the conservative 65536-byte encoding budget"))
   (else (- remaining amount))))

(define (measure-encoded-string value remaining)
  (if (not remaining)
      #f
      (let ((left (spend-budget remaining 2)))
        (when (> (string-length value) left)
          (protocol-error
           "JSON string exceeds the conservative encoding budget"))
        (string-for-each
         (lambda (character)
           (let ((codepoint (char->integer character)))
             (set! left
                   (spend-budget
                    left
                    (cond
                     ((memv character '(#\" #\\ #\bs #\ff #\lf #\cr #\ht)) 2)
                     ((< codepoint 32) 6)
                     ((< codepoint 128) 1)
                     ((<= codepoint 255) 2)
                     ((<= codepoint #xffff) 6)
                     (else 12))))))
         value)
        left)))

(define* (validate-value! value parent-depth #:optional (remaining #f))
  (cond
   ((or (null? value) (pair? value))
    (let ((depth (+ parent-depth 1))
          (seen (make-hash-table)))
      (when (> depth max-nesting)
        (protocol-error "JSON nesting exceeds the limit of 16"))
      (let loop ((entries value)
                 (first? #t)
                 (left (spend-budget remaining 2)))
        (cond
         ((null? entries) left)
         ((not (pair? entries))
          (protocol-error "JSON objects must be proper alists"))
         (else
          (let ((entry (car entries)))
            (unless (pair? entry)
              (protocol-error "JSON objects must contain key/value pairs"))
            (let* ((key (car entry))
                   (after-comma (if first? left (spend-budget left 1))))
              (unless (string? key)
                (protocol-error "JSON object keys must be strings"))
              ((duplicate-probe-hook) key)
              (when (hash-ref seen key #f)
                (protocol-error "duplicate JSON object key"))
              (hash-set! seen key #t)
              (let* ((after-key
                      (measure-encoded-string key after-comma))
                     (after-colon (spend-budget after-key 1))
                     (after-value
                      (validate-value! (cdr entry) depth after-colon)))
                (loop (cdr entries) #f after-value)))))))))
   ((vector? value)
    (let* ((depth (+ parent-depth 1))
           (count (vector-length value))
           (minimum (if (zero? count) 2 (+ (* 2 count) 1))))
      (when (> depth max-nesting)
        (protocol-error "JSON nesting exceeds the limit of 16"))
      (when (and remaining (> minimum remaining))
        (protocol-error
         "JSON array exceeds the conservative 65536-byte encoding budget"))
      (let loop ((index 0) (left (spend-budget remaining 2)))
        (if (= index count)
            left
            (let* ((after-comma
                    (if (zero? index) left (spend-budget left 1)))
                   (after-value
                    (validate-value! (vector-ref value index)
                                     depth
                                     after-comma)))
              (loop (+ index 1) after-value))))))
   ((string? value) (measure-encoded-string value remaining))
   ((boolean? value) (spend-budget remaining (if value 4 5)))
   ((eq? value 'null) (spend-budget remaining 4))
   ((number? value)
    (check-number! value)
    (spend-budget remaining (string-length (number->string value))))
   (else
    (protocol-error
     "value is not an object, array, string, number, boolean, or null"))))

(define (json-number-character? character)
  (or (char-numeric? character)
      (memv character '(#\- #\+ #\. #\e #\E))))

(define (nonzero-significand? token)
  (let ((end (or (string-index token #\e)
                 (string-index token #\E)
                 (string-length token))))
    (let loop ((index 0))
      (and (< index end)
           (or (memv (string-ref token index)
                     '(#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9))
               (loop (+ index 1)))))))

(define (check-decimal-exponent! token)
  (let ((marker (or (string-index token #\e)
                    (string-index token #\E))))
    (when marker
      (let ((exponent (string->number (substring token (+ marker 1)))))
        ;; Invalid exponent spelling remains guile-json's responsibility.
        (when (and exponent
                   (integer? exponent)
                   (> (abs exponent) max-decimal-exponent))
          (protocol-error "JSON decimal exponent exceeds the limit of 1000"))))))

(define (check-number-token! token)
  ;; guile-json exposes no number hook.  This policy-only lexical check leaves
  ;; JSON grammar to guile-json, but catches binary64 under/overflow before its
  ;; exact/inexact conversion can erase the distinction.
  (check-decimal-exponent! token)
  (let ((nonzero? (nonzero-significand? token)))
    (catch #t
      (lambda ()
        (let ((number (string->number token)))
          (when number
            (when (and (not (finite? number)) nonzero?)
              (protocol-error "JSON number overflows binary64"))
            (when (and (zero? number) nonzero?)
              (protocol-error "JSON number underflows binary64"))
            (when (and (integer? number)
                       (> (abs number) max-safe-integer))
              (protocol-error
               "integral JSON number is outside the safe-integer range")))))
      (lambda (key . arguments)
        (if (eq? key 'book-protocol-error)
            (apply throw key arguments)
            (when nonzero?
              (protocol-error "JSON number is outside the binary64 range")))))))

(define (json-whitespace? character)
  (memv character '(#\space #\tab #\newline #\return)))

(define (token-delimiter? character)
  (or (json-whitespace? character)
      (memv character '(#\" #\{ #\} #\[ #\] #\: #\,))))

(define (scan-string-end text start)
  (let ((text-length (string-length text)))
    (let loop ((index start) (escaped? #f))
      (when (= index text-length)
        (protocol-error "unterminated JSON string"))
      (let ((character (string-ref text index)))
        (cond
         (escaped? (loop (+ index 1) #f))
         ((char=? character #\\) (loop (+ index 1) #t))
         ((char=? character #\") (+ index 1))
         (else (loop (+ index 1) #f)))))))

(define (expect-value! stack)
  (let* ((frame (car stack))
         (kind (vector-ref frame 0))
         (state (vector-ref frame 1)))
    (case kind
      ((root)
       (unless (eq? state 'value)
         (protocol-error "multiple top-level JSON values"))
       (vector-set! frame 1 'end))
      ((object)
       (unless (eq? state 'value)
         (protocol-error "JSON object value is missing a comma or colon"))
       (vector-set! frame 1 'comma-or-end))
      ((array)
       (unless (memq state '(value value-or-end))
         (protocol-error "JSON array value is missing a comma"))
       (vector-set! frame 1 'comma-or-end)))))

(define (check-before-json-parser! text)
  ;; This enforces only structural token order and bounded nesting, plus the
  ;; numeric policy hook. guile-json still parses strings, numbers, keywords,
  ;; and all resulting values.
  (let ((text-length (string-length text)))
    (let loop ((index 0) (stack (list (vector 'root 'value))))
      (if (= index text-length)
          (begin
            (unless (= (length stack) 1)
              (protocol-error "unterminated JSON container"))
            (unless (eq? (vector-ref (car stack) 1) 'end)
              (protocol-error "missing top-level JSON value")))
          (let* ((character (string-ref text index))
                 (frame (car stack))
                 (kind (vector-ref frame 0))
                 (state (vector-ref frame 1)))
            (cond
             ((json-whitespace? character) (loop (+ index 1) stack))
             ((char=? character #\")
              (let ((end (scan-string-end text (+ index 1))))
                (if (and (eq? kind 'object)
                         (memq state '(key key-or-end)))
                    (begin
                      (vector-set! frame 1 'colon)
                      (loop end stack))
                    (begin
                      (expect-value! stack)
                      (loop end stack)))))
             ((or (char=? character #\{) (char=? character #\[))
              (expect-value! stack)
              (let* ((container
                      (if (char=? character #\{)
                          (vector 'object 'key-or-end)
                          (vector 'array 'value-or-end)))
                     (next (cons container stack)))
                (when (> (- (length next) 1) max-nesting)
                  (protocol-error "JSON nesting exceeds the limit of 16"))
                (loop (+ index 1) next)))
             ((char=? character #\:)
              (unless (and (eq? kind 'object) (eq? state 'colon))
                (protocol-error "unexpected JSON colon"))
              (vector-set! frame 1 'value)
              (loop (+ index 1) stack))
             ((char=? character #\,)
              (unless (eq? state 'comma-or-end)
                (protocol-error "unexpected or leading JSON comma"))
              (case kind
                ((object) (vector-set! frame 1 'key))
                ((array) (vector-set! frame 1 'value))
                (else (protocol-error "unexpected top-level JSON comma")))
              (loop (+ index 1) stack))
             ((or (char=? character #\}) (char=? character #\]))
              (let ((expected-kind (if (char=? character #\}) 'object 'array)))
                (unless (eq? kind expected-kind)
                  (protocol-error "mismatched JSON container delimiter"))
                (unless (if (eq? kind 'object)
                            (memq state '(key-or-end comma-or-end))
                            (memq state '(value-or-end comma-or-end)))
                  (protocol-error "JSON container ends after an incomplete item"))
                (loop (+ index 1) (cdr stack))))
             ((or (char=? character #\-)
                  (char-numeric? character))
              (expect-value! stack)
              (let scan ((end (+ index 1)))
                (if (and (< end text-length)
                         (json-number-character? (string-ref text end)))
                    (scan (+ end 1))
                    (begin
                      (check-number-token! (substring text index end))
                      (loop end stack)))))
             (else
              (expect-value! stack)
              (let scan ((end (+ index 1)))
                (if (and (< end text-length)
                         (not (token-delimiter? (string-ref text end))))
                    (scan (+ end 1))
                    (loop end stack))))))))))

(define (decode-payload payload)
  (unless (bytevector? payload)
    (protocol-error "frame payload must be a bytevector"))
  (let ((length (bytevector-length payload)))
    (when (zero? length)
      (protocol-error "zero-length frames are forbidden"))
    (when (> length max-frame-size)
      (protocol-error "frame payload exceeds the 65536-byte limit")))
  (let ((text
         (catch 'decoding-error
           (lambda () (utf8->string payload))
           (lambda arguments
             (protocol-error "frame payload is not well-formed UTF-8")))))
    (check-before-json-parser! text)
    (let ((value
           (catch 'json-invalid
             (lambda ()
               (json-string->scm text #:ordered #t #:null 'null))
             (lambda arguments
               (protocol-error "malformed JSON payload")))))
      (unless (or (null? value) (pair? value))
        (protocol-error "the top-level JSON value must be an object"))
      (validate-value! value 0)
      value)))

(define (frame-payload-length header)
  (unless (and (bytevector? header) (= (bytevector-length header) 4))
    (protocol-error "frame header must be exactly four bytes"))
  (let ((length (+ (ash (bytevector-u8-ref header 0) 24)
                   (ash (bytevector-u8-ref header 1) 16)
                   (ash (bytevector-u8-ref header 2) 8)
                   (bytevector-u8-ref header 3))))
    (when (zero? length)
      (protocol-error "zero-length frames are forbidden"))
    (when (> length max-frame-size)
      (protocol-error "frame length exceeds the 65536-byte limit"))
    length))

(define (write-length-prefix! frame length)
  (bytevector-u8-set! frame 0 (logand (ash length -24) #xff))
  (bytevector-u8-set! frame 1 (logand (ash length -16) #xff))
  (bytevector-u8-set! frame 2 (logand (ash length -8) #xff))
  (bytevector-u8-set! frame 3 (logand length #xff)))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(define (encode-frame message)
  (unless (or (null? message) (pair? message))
    (protocol-error "the top-level JSON value must be an object alist"))
  (validate-value! message 0 max-frame-size)
  (let* ((text
           (catch 'json-invalid
            (lambda () ((json-encoder) message))
            (lambda arguments
              (protocol-error "cannot encode JSON object"))))
         (payload (string->utf8 text))
         (length (bytevector-length payload)))
    (when (> length max-frame-size)
      (protocol-error "frame payload exceeds the 65536-byte limit"))
    (let ((frame (make-bytevector (+ 4 length))))
      (write-length-prefix! frame length)
      (bytevector-copy! payload 0 frame 4 length)
      frame)))

(define (decode-frame frame)
  (unless (bytevector? frame)
    (protocol-error "frame must be a bytevector"))
  (when (< (bytevector-length frame) 4)
    (protocol-error "truncated frame header"))
  (let* ((header (bytevector-slice frame 0 4))
         (length (frame-payload-length header))
         (actual (- (bytevector-length frame) 4)))
    (unless (= actual length)
      (protocol-error "frame payload length does not match its prefix"))
    (decode-payload (bytevector-slice frame 4 (+ 4 length)))))
