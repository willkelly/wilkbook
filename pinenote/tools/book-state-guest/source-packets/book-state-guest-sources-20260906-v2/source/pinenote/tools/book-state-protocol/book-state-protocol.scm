;;; Typed JSON projection and finite authority model for one persistent text.
(define-module (book-state-protocol)
  #:use-module (book-protocol)
  #:use-module (book-state-operation-id)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-9)
  #:re-export (book-state-wire-max-operation-id-bytes
               book-state-wire-operation-id?)
  #:export (state-protocol-version
            max-state-text-bytes
            max-state-operation-id-bytes
            max-state-grant-handle-bytes
            make-state-ready-message
            state-ready-message?
            state-ready-message-grant-handle
            state-ready-message-grant-generation
            state-ready-message-access
            make-state-read-message
            state-read-message?
            state-read-message-grant-handle
            state-read-message-grant-generation
            make-state-commit-message
            state-commit-message?
            state-commit-message-grant-handle
            state-commit-message-grant-generation
            state-commit-message-operation-id
            state-commit-message-expected-state-version
            state-commit-message-text
            make-state-value-message
            state-value-message?
            state-value-message-present?
            state-value-message-state-version
            state-value-message-text
            make-state-committed-message
            state-committed-message?
            state-committed-message-operation-id
            state-committed-message-state-version
            state-committed-message-text-bytes
            make-state-conflict-message
            state-conflict-message?
            state-conflict-message-operation-id
            state-conflict-message-current-state-version
            make-state-commit-failed-message
            state-commit-failed-message?
            state-commit-failed-message-operation-id
            state-commit-failed-message-code
            encode-state-message
            decode-state-frame
            decode-state-payload
            make-state-endpoint-binding
            state-endpoint-binding?
            state-endpoint-binding-owner
            state-endpoint-binding-backend-grant
            state-endpoint-binding-grant-handle
            state-endpoint-binding-grant-generation
            state-endpoint-binding-access
            state-endpoint-binding-phase
            make-state-session
            state-session?
            state-session-phase
            state-session-current-present?
            state-session-current-version
            state-session-current-text
            state-session-draft-text
            state-session-conflict-version
            state-session-close-reason
             state-session-bound-to?
            state-session-ready-message
            state-session-receive!
            state-session-dispatch-commit!
            state-session-apply-backend-result!
            state-session-note-commit-ack-sent!
            state-session-discard-edit!
            state-session-close!
            state-session-eof!
            state-session-revoke!
            state-read-operation?
            state-read-operation-owner
            state-read-operation-backend-grant
            state-read-operation-grant-generation
            state-read-operation-resume-dirty?
            state-commit-operation?
            state-commit-operation-owner
            state-commit-operation-backend-grant
            state-commit-operation-grant-generation
            state-commit-operation-operation-id
            state-commit-operation-expected-state-version
            state-commit-operation-text
            make-state-read-result
            state-read-result?
            state-read-result-operation
            state-read-result-present?
            state-read-result-state-version
            state-read-result-text
            make-state-commit-receipt
            state-commit-receipt?
            state-commit-receipt-operation
            state-commit-receipt-state-version
            state-commit-receipt-text-bytes
            make-state-backend-rejection
            state-backend-rejection?
            state-backend-rejection-operation
            state-backend-rejection-code
            state-backend-rejection-current-state-version))

(define state-protocol-version 1)
(define max-state-text-bytes 4096)
(define max-state-operation-id-bytes book-state-wire-max-operation-id-bytes)
(define max-state-grant-handle-bytes 128)

(define (state-error kind message)
  (throw 'book-state-protocol-error kind message))

(define (copy-string value)
  (and value (string-copy value)))

(define (utf8-size value)
  (bytevector-length (string->utf8 value)))

(define* (bounded-string! name value maximum #:optional (empty? #f))
  (unless (string? value)
    (state-error 'schema (string-append name " must be a string")))
  (when (and (not empty?) (zero? (string-length value)))
    (state-error 'schema (string-append name " must not be empty")))
  (when (or (> (string-length value) maximum)
            (> (utf8-size value) maximum))
    (state-error 'schema (string-append name " exceeds its UTF-8 byte limit")))
  value)

(define (operation-id! value)
  (unless (book-state-wire-operation-id? value)
    (state-error
     'schema
     "operation_id must match [A-Za-z0-9_-]{1,128}"))
  value)

(define (boolean! name value)
  (unless (boolean? value)
    (state-error 'schema (string-append name " must be a JSON boolean")))
  value)

(define* (integer-shape! name value #:optional (kind 'schema))
  (unless (and (number? value) (exact? value) (integer? value))
    (state-error kind
                 (string-append name " must be a lexical JSON integer")))
  value)

(define (bounded-integer! name value minimum maximum evidence)
  (integer-shape! name value)
  (unless (eq? (assoc-ref evidence name) 'integer)
    (state-error 'schema
                 (string-append name " must be a lexical JSON integer")))
  (unless (<= minimum value maximum)
    (state-error 'schema (string-append name " is outside its field range")))
  value)

(define* (bounded-integer-value! name value minimum maximum
                                 #:optional (kind 'schema))
  (integer-shape! name value kind)
  (unless (<= minimum value maximum)
    (state-error kind (string-append name " is outside its field range")))
  value)

(define (snapshot-shape! present? version text kind)
  (boolean! "present" present?)
  (bounded-integer-value! "state_version" version 0 max-safe-integer kind)
  (bounded-string! "text" text max-state-text-bytes #t)
  (if present?
      (when (zero? version)
        (state-error kind "a present value must have a positive state version"))
      (unless (and (zero? version) (string-null? text))
        (state-error kind
                     "absent state must be version zero with empty text"))))

(define-record-type <state-ready-message>
  (%make-state-ready-message grant-handle grant-generation access)
  state-ready-message?
  (grant-handle %state-ready-message-grant-handle)
  (grant-generation state-ready-message-grant-generation)
  (access state-ready-message-access))

(define (state-ready-message-grant-handle message)
  (copy-string (%state-ready-message-grant-handle message)))

(define (make-state-ready-message grant-handle grant-generation access)
  (bounded-string! "grant_handle" grant-handle max-state-grant-handle-bytes)
  (bounded-integer-value! "grant_generation" grant-generation
                          1 max-safe-integer)
  (unless (memq access '(read-only read-write))
    (state-error 'schema "access must be read-only or read-write"))
  (%make-state-ready-message (copy-string grant-handle)
                             grant-generation access))

(define-record-type <state-read-message>
  (%make-state-read-message grant-handle grant-generation)
  state-read-message?
  (grant-handle %state-read-message-grant-handle)
  (grant-generation state-read-message-grant-generation))

(define (state-read-message-grant-handle message)
  (copy-string (%state-read-message-grant-handle message)))

(define (make-state-read-message grant-handle grant-generation)
  (bounded-string! "grant_handle" grant-handle max-state-grant-handle-bytes)
  (bounded-integer-value! "grant_generation" grant-generation
                          1 max-safe-integer)
  (%make-state-read-message (copy-string grant-handle) grant-generation))

(define-record-type <state-commit-message>
  (%make-state-commit-message grant-handle grant-generation operation-id
                              expected-state-version text)
  state-commit-message?
  (grant-handle %state-commit-message-grant-handle)
  (grant-generation state-commit-message-grant-generation)
  (operation-id %state-commit-message-operation-id)
  (expected-state-version state-commit-message-expected-state-version)
  (text %state-commit-message-text))

(define (state-commit-message-grant-handle message)
  (copy-string (%state-commit-message-grant-handle message)))
(define (state-commit-message-operation-id message)
  (copy-string (%state-commit-message-operation-id message)))
(define (state-commit-message-text message)
  (copy-string (%state-commit-message-text message)))

(define (make-state-commit-message grant-handle grant-generation operation-id
                                   expected-state-version text)
  (bounded-string! "grant_handle" grant-handle max-state-grant-handle-bytes)
  (bounded-integer-value! "grant_generation" grant-generation
                          1 max-safe-integer)
  (operation-id! operation-id)
  (bounded-integer-value! "expected_state_version" expected-state-version
                          0 max-safe-integer)
  (bounded-string! "text" text max-state-text-bytes #t)
  (%make-state-commit-message (copy-string grant-handle) grant-generation
                              (copy-string operation-id)
                              expected-state-version (copy-string text)))

(define-record-type <state-value-message>
  (%make-state-value-message present? state-version text)
  state-value-message?
  (present? state-value-message-present?)
  (state-version state-value-message-state-version)
  (text %state-value-message-text))

(define (state-value-message-text message)
  (copy-string (%state-value-message-text message)))

(define (make-state-value-message present? state-version text)
  (snapshot-shape! present? state-version text 'schema)
  (%make-state-value-message present? state-version (copy-string text)))

(define-record-type <state-committed-message>
  (%make-state-committed-message operation-id state-version text-bytes)
  state-committed-message?
  (operation-id %state-committed-message-operation-id)
  (state-version state-committed-message-state-version)
  (text-bytes state-committed-message-text-bytes))

(define (state-committed-message-operation-id message)
  (copy-string (%state-committed-message-operation-id message)))

(define (make-state-committed-message operation-id state-version text-bytes)
  (operation-id! operation-id)
  (bounded-integer-value! "state_version" state-version 1 max-safe-integer)
  (bounded-integer-value! "text_bytes" text-bytes 0 max-state-text-bytes)
  (%make-state-committed-message (copy-string operation-id)
                                 state-version text-bytes))

(define-record-type <state-conflict-message>
  (%make-state-conflict-message operation-id current-state-version)
  state-conflict-message?
  (operation-id %state-conflict-message-operation-id)
  (current-state-version state-conflict-message-current-state-version))

(define (state-conflict-message-operation-id message)
  (copy-string (%state-conflict-message-operation-id message)))

(define (make-state-conflict-message operation-id current-state-version)
  (operation-id! operation-id)
  (bounded-integer-value! "current_state_version" current-state-version
                          0 max-safe-integer)
  (%make-state-conflict-message (copy-string operation-id)
                                current-state-version))

(define commit-failure-codes
  '(receipt-quota-exhausted read-only storage-failure))

(define-record-type <state-commit-failed-message>
  (%make-state-commit-failed-message operation-id code)
  state-commit-failed-message?
  (operation-id %state-commit-failed-message-operation-id)
  (code state-commit-failed-message-code))

(define (state-commit-failed-message-operation-id message)
  (copy-string (%state-commit-failed-message-operation-id message)))

(define (make-state-commit-failed-message operation-id code)
  (operation-id! operation-id)
  (unless (memq code commit-failure-codes)
    (state-error 'schema "unknown state commit failure code"))
  (%make-state-commit-failed-message (copy-string operation-id) code))

(define (access->wire access)
  (case access
    ((read-only) "read-only")
    ((read-write) "read-write")
    (else (state-error 'schema "unknown state access value"))))

(define (wire->access access)
  (cond
   ((and (string? access) (string=? access "read-only")) 'read-only)
   ((and (string? access) (string=? access "read-write")) 'read-write)
   (else (state-error 'schema "unknown state access value"))))

(define (failure-code->wire code)
  (case code
    ((receipt-quota-exhausted) "receipt-quota-exhausted")
    ((read-only) "read-only")
    ((storage-failure) "storage-failure")
    (else (state-error 'schema "unknown state commit failure code"))))

(define (wire->failure-code code)
  (cond
   ((and (string? code) (string=? code "receipt-quota-exhausted"))
    'receipt-quota-exhausted)
   ((and (string? code) (string=? code "read-only")) 'read-only)
   ((and (string? code) (string=? code "storage-failure")) 'storage-failure)
   (else (state-error 'schema "unknown state commit failure code"))))

(define (state-message->object message)
  (cond
   ((state-ready-message? message)
    `(("type" . "state-ready")
      ("protocol_version" . ,state-protocol-version)
      ("grant_handle" . ,(state-ready-message-grant-handle message))
      ("grant_generation" . ,(state-ready-message-grant-generation message))
      ("access" . ,(access->wire (state-ready-message-access message)))))
   ((state-read-message? message)
    `(("type" . "state-read")
      ("protocol_version" . ,state-protocol-version)
      ("grant_handle" . ,(state-read-message-grant-handle message))
      ("grant_generation" . ,(state-read-message-grant-generation message))))
   ((state-commit-message? message)
    `(("type" . "state-commit")
      ("protocol_version" . ,state-protocol-version)
      ("grant_handle" . ,(state-commit-message-grant-handle message))
      ("grant_generation" . ,(state-commit-message-grant-generation message))
      ("operation_id" . ,(state-commit-message-operation-id message))
      ("expected_state_version" .
       ,(state-commit-message-expected-state-version message))
      ("text" . ,(state-commit-message-text message))))
   ((state-value-message? message)
    `(("type" . "state-value")
      ("protocol_version" . ,state-protocol-version)
      ("present" . ,(state-value-message-present? message))
      ("state_version" . ,(state-value-message-state-version message))
      ("text" . ,(state-value-message-text message))))
   ((state-committed-message? message)
    `(("type" . "state-committed")
      ("protocol_version" . ,state-protocol-version)
      ("operation_id" . ,(state-committed-message-operation-id message))
      ("state_version" . ,(state-committed-message-state-version message))
      ("text_bytes" . ,(state-committed-message-text-bytes message))))
   ((state-conflict-message? message)
    `(("type" . "state-conflict")
      ("protocol_version" . ,state-protocol-version)
      ("operation_id" . ,(state-conflict-message-operation-id message))
      ("current_state_version" .
       ,(state-conflict-message-current-state-version message))))
   ((state-commit-failed-message? message)
    `(("type" . "state-commit-failed")
      ("protocol_version" . ,state-protocol-version)
      ("operation_id" . ,(state-commit-failed-message-operation-id message))
      ("code" . ,(failure-code->wire
                    (state-commit-failed-message-code message)))))
   (else (state-error 'schema "typed state message record required"))))

(define (encode-state-message message)
  (encode-frame (state-message->object message)))

;; decode-payload/decode-frame have already accepted the JSON. This small pass
;; records only whether each top-level scalar number used integer lexical form;
;; it neither parses JSON values nor changes the accepted codec.
(define (json-whitespace? character)
  (memv character '(#\space #\tab #\newline #\return)))

(define (skip-json-whitespace text start)
  (let ((length (string-length text)))
    (let loop ((index start))
      (if (and (< index length) (json-whitespace? (string-ref text index)))
          (loop (+ index 1))
          index))))

(define (scan-string-end text start)
  (let ((length (string-length text)))
    (let loop ((index start) (escaped? #f))
      (when (= index length)
        (state-error 'schema "string endpoint missing after JSON validation"))
      (let ((character (string-ref text index)))
        (cond
         (escaped? (loop (+ index 1) #f))
         ((char=? character #\\) (loop (+ index 1) #t))
         ((char=? character #\") (+ index 1))
         (else (loop (+ index 1) #f)))))))

(define (scan-scalar-end text start)
  (let ((length (string-length text)))
    (let loop ((index start))
      (if (or (= index length)
              (json-whitespace? (string-ref text index))
              (memv (string-ref text index) '(#\, #\})))
          index
          (loop (+ index 1))))))

(define (lexical-integer-token? text start end)
  (let loop ((index start))
    (or (= index end)
        (and (not (memv (string-ref text index) '(#\. #\e #\E)))
             (loop (+ index 1))))))

(define (scalar-token-evidence text entries)
  (let* ((length (string-length text))
         (object-start (skip-json-whitespace text 0)))
    (unless (and (< object-start length)
                 (char=? (string-ref text object-start) #\{))
      (state-error 'schema "state message is not a JSON object"))
    (let loop ((index (+ object-start 1))
               (remaining entries)
               (evidence '()))
      (if (null? remaining)
          (let ((end (skip-json-whitespace text index)))
            (unless (= end length)
              (state-error 'schema "trailing scalar evidence data"))
            (reverse evidence))
          (let* ((key-start (skip-json-whitespace text index))
                 (key-end (scan-string-end text (+ key-start 1)))
                 (colon (skip-json-whitespace text key-end))
                 (value-start (skip-json-whitespace text (+ colon 1)))
                 (decoded-value (cdar remaining)))
            (unless (and (< key-start length)
                         (char=? (string-ref text key-start) #\")
                         (< colon length)
                         (char=? (string-ref text colon) #\:))
              (state-error 'schema "scalar evidence disagrees with object"))
            (let* ((string-value? (string? decoded-value))
                   (value-end
                    (if string-value?
                        (begin
                          (unless (and (< value-start length)
                                       (char=? (string-ref text value-start) #\"))
                            (state-error
                             'schema "string evidence disagrees with value"))
                          (scan-string-end text (+ value-start 1)))
                        (scan-scalar-end text value-start)))
                   (kind
                    (cond
                     (string-value? 'string)
                     ((and (number? decoded-value)
                           (lexical-integer-token? text value-start value-end))
                      'integer)
                     ((number? decoded-value) 'number)
                     ((boolean? decoded-value) 'boolean)
                     (else 'other)))
                   (delimiter (skip-json-whitespace text value-end))
                   (last? (null? (cdr remaining))))
              (unless (and (< delimiter length)
                           (char=? (string-ref text delimiter)
                                   (if last? #\} #\,)))
                (state-error 'schema "scalar evidence order mismatch"))
              (loop (+ delimiter 1) (cdr remaining)
                    (cons (cons (caar remaining) kind) evidence))))))))

(define (exact-fields! message expected)
  (unless (= (length message) (length expected))
    (state-error 'schema "state message fields do not match exact schema"))
  (for-each
   (lambda (entry)
     (unless (and (pair? entry) (string? (car entry))
                  (member (car entry) expected string=?))
       (state-error 'schema "unknown state message field")))
   message)
  (for-each
   (lambda (name)
     (unless (assoc name message)
       (state-error 'schema "state message is missing a required field")))
   expected))

(define (field message name)
  (cdr (assoc name message)))

(define (protocol-version! message evidence)
  (bounded-integer! "protocol_version" (field message "protocol_version")
                    state-protocol-version state-protocol-version evidence))

(define (decode-state-object message text direction)
  (unless (memq direction '(book-to-authority authority-to-book))
    (state-error 'schema "state message direction is invalid"))
  (let ((type-entry (assoc "type" message)))
    (unless (and type-entry (string? (cdr type-entry)))
      (state-error 'schema "state message type must be a string"))
    (let ((type (cdr type-entry)))
      (cond
       ((string=? type "state-ready")
        (unless (eq? direction 'authority-to-book)
          (state-error 'schema "state-ready has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "grant_handle"
                         "grant_generation" "access"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (bounded-integer! "grant_generation" (field message "grant_generation")
                            1 max-safe-integer evidence)
          (make-state-ready-message
           (bounded-string! "grant_handle" (field message "grant_handle")
                            max-state-grant-handle-bytes)
           (field message "grant_generation")
           (wire->access (field message "access")))))
       ((string=? type "state-read")
        (unless (eq? direction 'book-to-authority)
          (state-error 'schema "state-read has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "grant_handle"
                         "grant_generation"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (bounded-integer! "grant_generation" (field message "grant_generation")
                            1 max-safe-integer evidence)
          (make-state-read-message
           (bounded-string! "grant_handle" (field message "grant_handle")
                            max-state-grant-handle-bytes)
           (field message "grant_generation"))))
       ((string=? type "state-commit")
        (unless (eq? direction 'book-to-authority)
          (state-error 'schema "state-commit has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "grant_handle"
                         "grant_generation" "operation_id"
                         "expected_state_version" "text"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (bounded-integer! "grant_generation" (field message "grant_generation")
                            1 max-safe-integer evidence)
          (bounded-integer! "expected_state_version"
                            (field message "expected_state_version")
                            0 max-safe-integer evidence)
          (make-state-commit-message
           (bounded-string! "grant_handle" (field message "grant_handle")
                            max-state-grant-handle-bytes)
           (field message "grant_generation")
           (operation-id! (field message "operation_id"))
           (field message "expected_state_version")
           (bounded-string! "text" (field message "text")
                            max-state-text-bytes #t))))
       ((string=? type "state-value")
        (unless (eq? direction 'authority-to-book)
          (state-error 'schema "state-value has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "present"
                         "state_version" "text"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (boolean! "present" (field message "present"))
          (bounded-integer! "state_version" (field message "state_version")
                            0 max-safe-integer evidence)
          (make-state-value-message
           (field message "present") (field message "state_version")
           (bounded-string! "text" (field message "text")
                            max-state-text-bytes #t))))
       ((string=? type "state-committed")
        (unless (eq? direction 'authority-to-book)
          (state-error 'schema "state-committed has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "operation_id"
                         "state_version" "text_bytes"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (bounded-integer! "state_version" (field message "state_version")
                            1 max-safe-integer evidence)
          (bounded-integer! "text_bytes" (field message "text_bytes")
                            0 max-state-text-bytes evidence)
          (make-state-committed-message
           (operation-id! (field message "operation_id"))
           (field message "state_version") (field message "text_bytes"))))
       ((string=? type "state-conflict")
        (unless (eq? direction 'authority-to-book)
          (state-error 'schema "state-conflict has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "operation_id"
                         "current_state_version"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (bounded-integer! "current_state_version"
                            (field message "current_state_version")
                            0 max-safe-integer evidence)
          (make-state-conflict-message
           (operation-id! (field message "operation_id"))
           (field message "current_state_version"))))
       ((string=? type "state-commit-failed")
        (unless (eq? direction 'authority-to-book)
          (state-error 'schema "state-commit-failed has the wrong direction"))
        (exact-fields! message
                       '("type" "protocol_version" "operation_id" "code"))
        (let ((evidence (scalar-token-evidence text message)))
          (protocol-version! message evidence)
          (make-state-commit-failed-message
           (operation-id! (field message "operation_id"))
           (wire->failure-code (field message "code")))))
       (else (state-error 'schema "unknown persistent-state message type"))))))

(define (bytevector-slice source start end)
  (let ((result (make-bytevector (- end start))))
    (bytevector-copy! source start result 0 (- end start))
    result))

(define (decode-state-payload payload direction)
  (let ((message (decode-payload payload)))
    (decode-state-object message (utf8->string payload) direction)))

(define (decode-state-frame frame direction)
  ;; decode-frame remains the sole framing/JSON decoder. The payload copy is
  ;; inspected only for integer token spelling after that accepted decode.
  (let ((message (decode-frame frame)))
    (decode-state-object
     message
     (utf8->string (bytevector-slice frame 4 (bytevector-length frame)))
     direction)))

;;; Trusted endpoint binding. OWNER and BACKEND-GRANT are never serialized.
(define-record-type <state-endpoint-binding>
  (%make-state-endpoint-binding owner backend-grant grant-handle
                                grant-generation access phase)
  state-endpoint-binding?
  (owner state-endpoint-binding-owner)
  (backend-grant state-endpoint-binding-backend-grant)
  (grant-handle %state-endpoint-binding-grant-handle)
  (grant-generation state-endpoint-binding-grant-generation)
  (access state-endpoint-binding-access)
  (phase state-endpoint-binding-phase set-state-endpoint-binding-phase!))

(define (state-endpoint-binding-grant-handle binding)
  (copy-string (%state-endpoint-binding-grant-handle binding)))

(define (make-state-endpoint-binding owner backend-grant grant-handle
                                     grant-generation access)
  (unless owner (state-error 'binding "endpoint owner must be an object"))
  (unless backend-grant
    (state-error 'binding "backend grant must be an opaque record"))
  (bounded-string! "grant_handle" grant-handle max-state-grant-handle-bytes)
  (bounded-integer-value! "grant_generation" grant-generation
                          1 max-safe-integer 'binding)
  (unless (memq access '(read-only read-write))
    (state-error 'binding "binding access must be read-only or read-write"))
  (%make-state-endpoint-binding owner backend-grant (copy-string grant-handle)
                                grant-generation access 'available))

(define-record-type <state-read-operation>
  (%make-state-read-operation owner backend-grant grant-generation
                              resume-dirty?)
  state-read-operation?
  (owner state-read-operation-owner)
  (backend-grant state-read-operation-backend-grant)
  (grant-generation state-read-operation-grant-generation)
  (resume-dirty? state-read-operation-resume-dirty?))

(define-record-type <state-commit-operation>
  (%make-state-commit-operation owner backend-grant grant-generation
                                operation-id expected-state-version text)
  state-commit-operation?
  (owner state-commit-operation-owner)
  (backend-grant state-commit-operation-backend-grant)
  (grant-generation state-commit-operation-grant-generation)
  (operation-id %state-commit-operation-operation-id)
  (expected-state-version state-commit-operation-expected-state-version)
  (text %state-commit-operation-text))

(define (state-commit-operation-operation-id operation)
  (copy-string (%state-commit-operation-operation-id operation)))
(define (state-commit-operation-text operation)
  (copy-string (%state-commit-operation-text operation)))

(define-record-type <state-read-result>
  (%make-state-read-result operation present? state-version text)
  state-read-result?
  (operation state-read-result-operation)
  (present? state-read-result-present?)
  (state-version state-read-result-state-version)
  (text %state-read-result-text))

(define (state-read-result-text result)
  (copy-string (%state-read-result-text result)))

(define (make-state-read-result operation present? state-version text)
  (unless (state-read-operation? operation)
    (state-error 'backend "read result requires its exact read operation"))
  (snapshot-shape! present? state-version text 'backend)
  (%make-state-read-result operation present? state-version (copy-string text)))

(define-record-type <state-commit-receipt>
  (%make-state-commit-receipt operation state-version text-bytes)
  state-commit-receipt?
  (operation state-commit-receipt-operation)
  (state-version state-commit-receipt-state-version)
  (text-bytes state-commit-receipt-text-bytes))

(define (make-state-commit-receipt operation state-version text-bytes)
  (unless (state-commit-operation? operation)
    (state-error 'backend "commit receipt requires its exact commit operation"))
  (bounded-integer-value! "state_version" state-version
                          1 max-safe-integer 'backend)
  (bounded-integer-value! "text_bytes" text-bytes
                          0 max-state-text-bytes 'backend)
  (%make-state-commit-receipt operation state-version text-bytes))

(define backend-rejection-codes
  '(stale-version operation-conflict receipt-quota-exhausted read-only
    revoked stale-generation owner-mismatch invalid-grant invalid-namespace
    store-closed text-too-large invalid-text invalid-operation-id
    invalid-expected-version storage-failure))

(define-record-type <state-backend-rejection>
  (%make-state-backend-rejection operation code current-state-version)
  state-backend-rejection?
  (operation state-backend-rejection-operation)
  (code state-backend-rejection-code)
  (current-state-version state-backend-rejection-current-state-version))

(define (make-state-backend-rejection operation code current-state-version)
  (unless (or (state-read-operation? operation)
              (state-commit-operation? operation))
    (state-error 'backend "backend rejection requires its exact operation"))
  (unless (memq code backend-rejection-codes)
    (state-error 'backend "unknown backend rejection code"))
  (when current-state-version
    (bounded-integer-value! "current_state_version" current-state-version
                            0 max-safe-integer 'backend))
  (%make-state-backend-rejection operation code current-state-version))

(define-record-type <state-session>
  (%make-state-session binding phase pending current-present? current-version
                       current-text draft-text conflict-version last-commit
                       last-response close-reason)
  state-session?
  (binding state-session-binding)
  (phase state-session-phase set-state-session-phase!)
  (pending state-session-pending set-state-session-pending!)
  (current-present? state-session-current-present?
                    set-state-session-current-present?!)
  (current-version state-session-current-version
                   set-state-session-current-version!)
  (current-text %state-session-current-text set-state-session-current-text!)
  (draft-text %state-session-draft-text set-state-session-draft-text!)
  (conflict-version state-session-conflict-version
                    set-state-session-conflict-version!)
  (last-commit state-session-last-commit set-state-session-last-commit!)
  (last-response state-session-last-response set-state-session-last-response!)
  (close-reason state-session-close-reason set-state-session-close-reason!))

(define (state-session-current-text session)
  (copy-string (%state-session-current-text session)))
(define (state-session-draft-text session)
  (copy-string (%state-session-draft-text session)))

(define (state-session-bound-to? session binding)
  "Return true only when BINDING is the exact opaque record retained by SESSION."
  (and (state-session? session)
       (state-endpoint-binding? binding)
       (eq? binding (state-session-binding session))))

(define (make-state-session binding)
  (unless (state-endpoint-binding? binding)
    (state-error 'binding "state session requires an endpoint binding"))
  (unless (eq? (state-endpoint-binding-phase binding) 'available)
    (state-error 'binding "state endpoint binding is already claimed or revoked"))
  (let ((session
         (%make-state-session binding 'ready #f #f 0 "" #f #f #f #f #f)))
    (set-state-endpoint-binding-phase! binding 'active)
    session))

(define (state-session-ready-message session)
  (unless (state-session? session)
    (state-error 'state "state session record required"))
  (unless (eq? (state-session-phase session) 'ready)
    (state-error 'state "state-ready is permitted only in the ready phase"))
  (let ((binding (state-session-binding session)))
    (make-state-ready-message
     (state-endpoint-binding-grant-handle binding)
     (state-endpoint-binding-grant-generation binding)
     (state-endpoint-binding-access binding))))

(define (assert-live-session! session)
  (unless (state-session? session)
    (state-error 'state "state session record required"))
  (when (eq? (state-session-phase session) 'closing)
    (state-error 'state "persistent-state session is closing"))
  (unless (eq? (state-endpoint-binding-phase
                (state-session-binding session)) 'active)
    (state-error 'binding "persistent-state endpoint grant is not active")))

(define (assert-message-binding! session handle generation)
  (let ((binding (state-session-binding session)))
    (unless (and (string=? handle
                           (state-endpoint-binding-grant-handle binding))
                 (= generation
                    (state-endpoint-binding-grant-generation binding)))
      (state-session-close! session 'grant-mismatch)
      (state-error 'binding
                   "wire grant does not match the endpoint-retained grant"))))

(define (same-commit? left right)
  (and (state-commit-message? left) (state-commit-message? right)
       (string=? (state-commit-message-grant-handle left)
                 (state-commit-message-grant-handle right))
       (= (state-commit-message-grant-generation left)
          (state-commit-message-grant-generation right))
       (string=? (state-commit-message-operation-id left)
                 (state-commit-message-operation-id right))
       (= (state-commit-message-expected-state-version left)
          (state-commit-message-expected-state-version right))
       (string=? (state-commit-message-text left)
                 (state-commit-message-text right))))

(define (same-operation-id? left right)
  (and left (state-commit-message? left) (state-commit-message? right)
       (string=? (state-commit-message-operation-id left)
                 (state-commit-message-operation-id right))))

(define (cached-commit-result session message)
  (let ((last (state-session-last-commit session)))
    (and (same-operation-id? last message)
         (if (same-commit? last message)
             (or (state-session-last-response session)
                 (case (state-session-phase session)
                   ((edit-dirty) 'staged)
                   ((commit-pending) 'pending)
                   (else #f)))
             (begin
               (state-session-close! session 'operation-id-reused)
               (state-error 'state
                            "operation ID was reused with changed payload"))))))

(define (state-session-receive! session message)
  (assert-live-session! session)
  (cond
   ((state-read-message? message)
    (assert-message-binding! session
                             (state-read-message-grant-handle message)
                             (state-read-message-grant-generation message))
    (unless (memq (state-session-phase session) '(ready clean edit-dirty))
      (state-error 'state "state read is not permitted in the current phase"))
    (when (state-session-pending session)
      (state-error 'state "a staged state operation is already pending"))
    (let* ((binding (state-session-binding session))
           (resume-dirty? (eq? (state-session-phase session) 'edit-dirty))
           (operation
            (%make-state-read-operation
             (state-endpoint-binding-owner binding)
             (state-endpoint-binding-backend-grant binding)
             (state-endpoint-binding-grant-generation binding)
             resume-dirty?)))
      (set-state-session-pending! session operation)
      (set-state-session-phase! session 'read-pending)
      operation))
   ((state-commit-message? message)
    (assert-message-binding! session
                             (state-commit-message-grant-handle message)
                             (state-commit-message-grant-generation message))
    (let ((cached (cached-commit-result session message)))
      (if cached
          cached
          (begin
            (unless (memq (state-session-phase session) '(clean edit-dirty))
              (state-error
               'state "state commit is not permitted in the current phase"))
            (when (state-session-pending session)
              (state-error 'state "a staged state operation is already pending"))
            (unless (eq? (state-endpoint-binding-access
                          (state-session-binding session)) 'read-write)
              (state-error 'binding "read-only state grant cannot commit"))
            (set-state-session-draft-text!
             session (state-commit-message-text message))
            (set-state-session-last-commit! session message)
            (set-state-session-last-response! session #f)
            (set-state-session-pending! session message)
            (set-state-session-phase! session 'edit-dirty)
            'staged))))
   (else (state-error 'schema "book may send only state-read or state-commit"))))

(define (state-session-dispatch-commit! session)
  (assert-live-session! session)
  (unless (and (eq? (state-session-phase session) 'edit-dirty)
               (state-commit-message? (state-session-pending session)))
    (state-error 'state "no staged state commit is ready for dispatch"))
  (let* ((message (state-session-pending session))
         (binding (state-session-binding session))
         (operation
          (%make-state-commit-operation
           (state-endpoint-binding-owner binding)
           (state-endpoint-binding-backend-grant binding)
           (state-endpoint-binding-grant-generation binding)
           (state-commit-message-operation-id message)
           (state-commit-message-expected-state-version message)
           (state-commit-message-text message))))
    (set-state-session-pending! session operation)
    (set-state-session-phase! session 'commit-pending)
    operation))

(define (assert-exact-pending-operation! session operation expected-phase)
  (unless (and (eq? (state-session-phase session) expected-phase)
               (eq? operation (state-session-pending session)))
    (state-error 'backend
                 "backend result does not name the exact pending operation"))
  (let ((operation-generation
         (cond
          ((state-read-operation? operation)
           (state-read-operation-grant-generation operation))
          ((state-commit-operation? operation)
           (state-commit-operation-grant-generation operation))
          (else #f))))
    (unless (and operation-generation
                 (= operation-generation
                    (state-endpoint-binding-grant-generation
                     (state-session-binding session))))
      (state-session-close! session 'inconsistent-operation-generation)
      (state-error
       'backend
       "pending operation generation disagrees with its endpoint binding"))))

(define (set-current-snapshot! session present? version text)
  (snapshot-shape! present? version text 'backend)
  (let ((owned-text (copy-string text)))
    (set-state-session-current-present?! session present?)
    (set-state-session-current-version! session version)
    (set-state-session-current-text! session owned-text)))

(define (close-for-backend-rejection! session code)
  (state-session-close! session code)
  (state-error 'backend "backend rejected endpoint authority or operation identity"))

(define (read-result-consistent? session result)
  (let ((known-version (state-session-current-version session))
        (result-version (state-read-result-state-version result)))
    (cond
     ((< result-version known-version) #f)
     ((> result-version known-version) #t)
     (else
      (and (eq? (state-read-result-present? result)
                (state-session-current-present? session))
           (string=? (state-read-result-text result)
                     (state-session-current-text session)))))))

(define (apply-read-result! session result)
  (let ((operation (state-read-result-operation result)))
    (assert-exact-pending-operation! session operation 'read-pending)
    (unless (read-result-consistent? session result)
      ;; Preserve the known baseline. Closing clears pending identity and any
      ;; retained dirty draft before this impossible completion is reported.
      (state-session-close! session 'inconsistent-backend-read)
      (state-error
       'backend
       "backend read result regresses or rewrites the known snapshot"))
    (let* ((text (state-read-result-text result))
           (response
            (make-state-value-message
             (state-read-result-present? result)
             (state-read-result-state-version result) text)))
      (set-current-snapshot! session
                             (state-read-result-present? result)
                             (state-read-result-state-version result) text)
      (set-state-session-pending! session #f)
      (set-state-session-conflict-version! session #f)
      (set-state-session-phase!
       session (if (state-read-operation-resume-dirty? operation)
                   'edit-dirty 'clean))
      response)))

(define (apply-commit-receipt! session receipt)
  (let* ((operation (state-commit-receipt-operation receipt))
         (expected (state-commit-operation-expected-state-version operation))
         (result-version (state-commit-receipt-state-version receipt))
         (text (state-commit-operation-text operation))
         (text-bytes (state-commit-receipt-text-bytes receipt))
         (response
          (make-state-committed-message
           (state-commit-operation-operation-id operation)
           result-version text-bytes)))
    (assert-exact-pending-operation! session operation 'commit-pending)
    (unless (and (= result-version (+ expected 1))
                 (= text-bytes (utf8-size text)))
      (state-session-close! session 'invalid-backend-receipt)
      (state-error 'backend "backend receipt disagrees with committed request"))
    ;; An old exact retry can return an earlier durable receipt after this
    ;; session has observed a newer value. Never roll that local view backward.
    (cond
     ((> result-version (state-session-current-version session))
      (set-current-snapshot! session #t result-version text))
     ((= result-version (state-session-current-version session))
      (unless (and (state-session-current-present? session)
                   (string=? (state-session-current-text session) text))
        (state-session-close! session 'inconsistent-backend-receipt)
        (state-error 'backend "receipt conflicts with the known state value"))))
    (set-state-session-pending! session #f)
    (set-state-session-draft-text! session #f)
    (set-state-session-conflict-version! session #f)
    (set-state-session-last-response! session response)
    (set-state-session-phase! session 'commit-ack)
    response))

(define (apply-backend-rejection! session rejection)
  (let* ((operation (state-backend-rejection-operation rejection))
         (phase (if (state-read-operation? operation)
                    'read-pending 'commit-pending))
         (code (state-backend-rejection-code rejection))
         (current (state-backend-rejection-current-state-version rejection)))
    (assert-exact-pending-operation! session operation phase)
    (cond
     ((and (state-commit-operation? operation) (eq? code 'stale-version))
      (unless (and current
                   (>= current (state-session-current-version session))
                   (not (= current
                           (state-commit-operation-expected-state-version
                            operation))))
        (state-session-close! session 'invalid-backend-rejection)
        (state-error
         'backend
         "stale-version rejection has impossible current-version metadata"))
      (let ((response
             (make-state-conflict-message
              (state-commit-operation-operation-id operation) current)))
        (set-state-session-pending! session #f)
        (set-state-session-conflict-version! session current)
        (set-state-session-last-response! session response)
        (set-state-session-phase! session 'edit-dirty)
        response))
     ((and (state-commit-operation? operation)
           (memq code '(receipt-quota-exhausted read-only storage-failure)))
      (let ((response
             (make-state-commit-failed-message
              (state-commit-operation-operation-id operation) code)))
        (set-state-session-pending! session #f)
        (set-state-session-last-response! session response)
        (if (eq? code 'storage-failure)
            (begin
              (set-state-session-phase! session 'closing)
              (set-state-session-close-reason! session 'storage-failure)
              (set-state-endpoint-binding-phase!
               (state-session-binding session) 'revoked))
            (set-state-session-phase! session 'edit-dirty))
        response))
     (else (close-for-backend-rejection! session code)))))

(define (state-session-apply-backend-result! session result)
  (assert-live-session! session)
  (cond
   ((state-read-result? result) (apply-read-result! session result))
   ((state-commit-receipt? result) (apply-commit-receipt! session result))
   ((state-backend-rejection? result)
    (apply-backend-rejection! session result))
   (else (state-error 'backend "unknown typed backend result"))))

(define (state-session-note-commit-ack-sent! session)
  (assert-live-session! session)
  (unless (eq? (state-session-phase session) 'commit-ack)
    (state-error 'state "no durable commit acknowledgement is ready"))
  (set-state-session-phase! session 'clean)
  'clean)

(define (state-session-discard-edit! session)
  (assert-live-session! session)
  (unless (and (eq? (state-session-phase session) 'edit-dirty)
               (not (state-session-pending session)))
    (state-error 'state "no completed dirty edit is available to discard"))
  (set-state-session-draft-text! session #f)
  (set-state-session-conflict-version! session #f)
  (set-state-session-phase! session 'clean)
  'clean)

(define (state-session-close! session reason)
  (unless (state-session? session)
    (state-error 'state "state session record required"))
  (unless (eq? (state-session-phase session) 'closing)
    (set-state-session-pending! session #f)
    (set-state-session-draft-text! session #f)
    (set-state-session-phase! session 'closing)
    (set-state-session-close-reason! session reason)
    (set-state-endpoint-binding-phase! (state-session-binding session) 'revoked))
  'closing)

(define (state-session-eof! session)
  (state-session-close! session 'eof))

(define (state-session-revoke! session)
  (state-session-close! session 'revoked))
