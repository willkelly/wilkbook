;;; Pure host codec/schema checks, including literal wire integer spellings.
(use-modules (workspace-protocol) (book-protocol) (rnrs bytevectors)
             (srfi srfi-1) (srfi srfi-64))
(set! test-log-to-file #f)
(define runner (test-runner-simple))
(test-runner-current runner)
(define (refuses? thunk)
  (catch #t (lambda () (thunk) #f) (lambda _ #t)))
(define (object type . extra)
  (append `(("type" . ,type) ("protocol_version" . 1)
            ("grant_handle" . "grant") ("grant_generation" . 1)
            ("operation_sequence" . 1)) extra))
(define (decode text) (decode-workspace-payload (string->utf8 text)))
(define (raw-save version)
  (string-append "{\"source\":\"a\\\"b\\n雪\",\"expected_vers\\u0069on\":" version
    ",\"operation_sequence\":1,\"grant_generation\":1,\"grant_handle\":\"grant\","
    "\"protocol_version\":1,\"type\":\"workspace-save\"}"))
(test-begin "workspace-protocol")
(for-each
 (lambda (value)
   (let* ((request (make-workspace-request value))
          (decoded (decode-workspace-frame (encode-workspace-request request))))
     (test-equal "typed framed request preserves type" (assoc-ref value "type")
       (workspace-request-type decoded))
     (test-equal "typed framed request preserves sequence" 1
       (workspace-request-sequence decoded))))
 (list (object "workspace-read")
       (object "workspace-save" '("expected_version" . 0) '("source" . ""))
       (object "workspace-preview" '("expected_version" . 0))
       (object "workspace-install-propose" '("expected_version" . 0) '("expected_activation" . 0))
       (object "workspace-export")))
(test-equal "escaped/reordered key evidence matches decoded source" "a\"b\n雪"
  (workspace-request-field (decode (raw-save "0")) "source"))
(for-each
 (lambda (token)
   (test-assert (string-append "literal CAS alias rejected: " token)
     (refuses? (lambda () (decode (raw-save token))))))
 '("0.0" "0e0" "-0.0" "0e1000" "0.99999999999999999" "1.0" "1e0"
   "true" "false" "null" "-1" "2147483648" "9007199254740992" "\"0\""))
(for-each
 (lambda (token)
   (test-assert (string-append "integer CAS accepted: " token)
     (workspace-request? (decode (raw-save token)))))
 '("0" "-0" "2147483647"))
(for-each
 (lambda (key)
   (for-each
    (lambda (token)
      (let* ((base (object "workspace-read"))
             (members
              (map (lambda (entry)
                     (if (string=? (car entry) key)
                         (string-append "\"" key "\":" token)
                         (if (string? (cdr entry))
                             (string-append "\"" (car entry) "\":\"" (cdr entry) "\"")
                             (string-append "\"" (car entry) "\":" (number->string (cdr entry)))))) base))
             (text (string-append "{" (string-join members ",") "}")))
        (test-assert "all identity numbers reject lexical aliases"
          (refuses? (lambda () (decode text))))))
    '("1.0" "1e0" "true" "0.99999999999999999")))
 '("protocol_version" "grant_generation" "operation_sequence"))
(for-each
 (lambda (value)
   (test-assert "exact schema rejects extra/missing/duplicate/selector/direction"
     (refuses? (lambda () (decode-workspace-frame (encode-frame value))))))
 (list (object "workspace-activate") (object "workspace-rollback")
       (object "workspace-ready") (object "workspace-install-confirm")
       (object "workspace-read" '("owner" . "grant"))
       (object "workspace-read" '("path" . "/tmp/file"))
       (object "workspace-read" '("source" . "wrong"))
       (cdr (object "workspace-read"))
       (object "workspace-save" '("expected_version" . 0) '("source" . #("nested")))))
(test-assert "raw duplicate escaped key rejected by codec"
  (refuses? (lambda () (decode "{\"type\":\"workspace-read\",\"t\\u0079pe\":\"workspace-read\"}"))))
(let* ((source (make-string 2048 (integer->char #x1f642)))
       (value (object "workspace-save" '("expected_version" . 0) (cons "source" source)))
       (request (make-workspace-request value)))
  (string-set! source 0 #\X)
  (test-equal "constructor owns source bytes" (integer->char #x1f642)
    (string-ref (workspace-request-field request "source") 0))
  (let ((returned (workspace-request-field request "source")))
    (string-set! returned 0 #\Y)
    (test-equal "accessor is defensive" (integer->char #x1f642)
      (string-ref (workspace-request-field request "source") 0)))
  (test-equal "8192 UTF-8 bytes round-trip"
    (workspace-request-field request "source")
    (workspace-request-field (decode-workspace-frame (encode-workspace-request request)) "source")))
(for-each
 (lambda (source)
   (test-assert "source bounds/NUL/scalar type checked"
     (refuses? (lambda () (make-workspace-request
                          (object "workspace-save" '("expected_version" . 0)
                                  (cons "source" source)))))))
 (list (make-string 8193 #\a) (string #\nul) #f 12))
(let ((frame (encode-workspace-request (make-workspace-request (object "workspace-read")))))
  (bytevector-u8-set! frame 3 (+ 1 (bytevector-u8-ref frame 3)))
  (test-assert "exact frame length checked" (refuses? (lambda () (decode-workspace-frame frame)))))
(test-end "workspace-protocol")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
