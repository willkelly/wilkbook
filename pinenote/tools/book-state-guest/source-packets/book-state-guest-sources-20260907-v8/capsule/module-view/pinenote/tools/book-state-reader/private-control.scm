;;; Bounded private control codec for the persistent-note KOReader fixture.
;;; This is a closed successor to book-interaction/private-control.scm.  It is
;;; host-only test transport, not Book Protocol and not a generic event bus.
(define-module (private-control)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (max-control-value-bytes
            max-control-line-bytes
            max-control-queue-frames
            max-control-queue-bytes
            reader-command-kinds
            reader-event-kinds
            commit-failure-codes
            reader-status-values
            encode-control-line
            decode-control-line))

(define max-control-value-bytes 4096)
(define max-control-line-bytes 8224)
(define max-control-queue-frames 8)
(define max-control-queue-bytes
  (* max-control-queue-frames (+ max-control-line-bytes 1)))
(define max-control-generation 1000000)

(define reader-command-kinds
  '(open load-absent load-value edit save commit-ok commit-failed present
         navigate close finish))
(define reader-event-kinds
  '(channel-ready ready status submit applied ignored navigated closed done))
(define commit-failure-codes
  '(receipt-quota-exhausted read-only storage-failure conflict))
(define reader-status-values
  '(loaded-absent loaded-value dirty pending saved failed))

(define hex-digits "0123456789abcdef")

(define (control-error message)
  (throw 'book-state-reader-control-error message))

(define (canonical-generation? value)
  (and (integer? value)
       (exact? value)
       (<= 1 value max-control-generation)))

(define (kind-token kind allowed-kinds)
  (unless (and (symbol? kind) (memq kind allowed-kinds))
    (control-error "private control kind is not allowed in this direction"))
  (symbol->string kind))

(define (bytes->hex bytes)
  (let* ((length (bytevector-length bytes))
         (result (make-string (* length 2))))
    (let loop ((index 0))
      (when (< index length)
        (let ((value (bytevector-u8-ref bytes index)))
          (string-set! result (* index 2)
                       (string-ref hex-digits (ash value -4)))
          (string-set! result (+ (* index 2) 1)
                       (string-ref hex-digits (logand value #x0f)))
          (loop (+ index 1)))))
    result))

(define (hex-value character)
  (cond
   ((char<=? #\0 character #\9) (- (char->integer character) 48))
   ((char<=? #\a character #\f) (+ 10 (- (char->integer character) 97)))
   (else #f)))

(define (hex->bytes token)
  (let ((length (string-length token)))
    (unless (even? length)
      (control-error "private control value has odd-length hex"))
    (let ((result (make-bytevector (/ length 2))))
      (let loop ((index 0))
        (when (< index length)
          (let ((high (hex-value (string-ref token index)))
                (low (hex-value (string-ref token (+ index 1)))))
            (unless (and high low)
              (control-error "private control value is not lowercase hex"))
            (bytevector-u8-set! result (/ index 2) (+ (ash high 4) low))
            (loop (+ index 2)))))
      result)))

(define (split-exactly-three line)
  (let ((first (string-index line #\|)))
    (unless first
      (control-error "private control line lacks field separators"))
    (let ((second (string-index line #\| (+ first 1))))
      (unless (and second
                   (not (string-index line #\| (+ second 1))))
        (control-error "private control line must contain exactly three fields"))
      (list (substring line 0 first)
            (substring line (+ first 1) second)
            (substring line (+ second 1))))))

(define (parse-generation token)
  (unless (and (positive? (string-length token))
               (char<=? #\1 (string-ref token 0) #\9)
               (string-every
                (lambda (character) (char<=? #\0 character #\9)) token))
    (control-error "private control generation is not a canonical integer"))
  (let ((value (string->number token 10)))
    (unless (canonical-generation? value)
      (control-error "private control generation is outside its range"))
    value))

(define (validate-value value)
  (unless (string? value)
    (control-error "private control value must be a string"))
  ;; The durable state protocol supports U+0000.  This ordinary editable-widget
  ;; fixture deliberately does not claim that InputDialog can render it.
  (when (string-index value #\nul)
    (control-error "private UI control value contains U+0000"))
  (let ((value-bytes (string->utf8 value)))
    (when (> (bytevector-length value-bytes) max-control-value-bytes)
      (control-error "private control value exceeds its byte limit"))
    value-bytes))

(define (encode-control-line kind generation value allowed-kinds)
  (unless (canonical-generation? generation)
    (control-error "private control generation is outside its range"))
  (let* ((value-bytes (validate-value value))
         (line
          (string-append (kind-token kind allowed-kinds) "|"
                         (number->string generation) "|"
                         (bytes->hex value-bytes) "\n"))
         (encoded (string->utf8 line)))
    (when (> (bytevector-length encoded) (+ max-control-line-bytes 1))
      (control-error "private control line exceeds its byte limit"))
    encoded))

(define (decode-control-line bytes allowed-kinds)
  (unless (bytevector? bytes)
    (control-error "private control line must be a bytevector"))
  (when (> (bytevector-length bytes) max-control-line-bytes)
    (control-error "private control line exceeds its byte limit"))
  (let ((line
         (catch #t
           (lambda () (utf8->string bytes))
           (lambda arguments
             (control-error "private control line is not well-formed UTF-8")))))
    (let* ((parts (split-exactly-three line))
           (kind-text (car parts))
           (kind
            (find (lambda (candidate)
                    (string=? kind-text (symbol->string candidate)))
                  allowed-kinds)))
      (unless (and (positive? (string-length kind-text))
                   (string-every
                    (lambda (character)
                      (or (char<=? #\a character #\z)
                          (char=? character #\-)))
                    kind-text)
                   kind)
        (control-error "private control kind is not allowed in this direction"))
      (let* ((generation (parse-generation (cadr parts)))
             (value-bytes (hex->bytes (caddr parts))))
        (when (> (bytevector-length value-bytes) max-control-value-bytes)
          (control-error "private control value exceeds its byte limit"))
        (let ((value
               (catch #t
                 (lambda () (utf8->string value-bytes))
                 (lambda arguments
                   (control-error
                    "private control value is not well-formed UTF-8")))))
          (validate-value value)
          (list kind generation value))))))
