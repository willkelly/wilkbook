(use-modules (book-protocol)
             (book-state-protocol)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-9)
             (srfi srfi-64))

(define (put-length! bytevector length)
  (bytevector-u8-set! bytevector 0 (logand (ash length -24) #xff))
  (bytevector-u8-set! bytevector 1 (logand (ash length -16) #xff))
  (bytevector-u8-set! bytevector 2 (logand (ash length -8) #xff))
  (bytevector-u8-set! bytevector 3 (logand length #xff)))

(define (raw-frame text)
  (let* ((payload (string->utf8 text))
         (frame (make-bytevector (+ 4 (bytevector-length payload)))))
    (put-length! frame (bytevector-length payload))
    (bytevector-copy! payload 0 frame 4 (bytevector-length payload))
    frame))

(define (frame-payload frame)
  (let* ((length (- (bytevector-length frame) 4))
         (payload (make-bytevector length)))
    (bytevector-copy! frame 4 payload 0 length)
    payload))

(define (state-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (any-protocol-error? thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda (key . rest)
      (or (eq? key 'book-state-protocol-error)
          (eq? key 'book-protocol-error)))))

(define (field object name)
  (assoc-ref object name))

(define state-session-pending-for-test
  (@@ (book-state-protocol) state-session-pending))

(define-record-type <fake-backend>
  (make-fake-backend present? version text receipts receipt-limit)
  fake-backend?
  (present? fake-backend-present? set-fake-backend-present?!)
  (version fake-backend-version set-fake-backend-version!)
  (text fake-backend-text set-fake-backend-text!)
  (receipts fake-backend-receipts set-fake-backend-receipts!)
  (receipt-limit fake-backend-receipt-limit))

(define (fake-receipt backend operation)
  (find (lambda (entry)
          (string=? (car entry)
                    (state-commit-operation-operation-id operation)))
        (fake-backend-receipts backend)))

(define (fake-run backend operation)
  (cond
   ((state-read-operation? operation)
    (make-state-read-result operation
                            (fake-backend-present? backend)
                            (fake-backend-version backend)
                            (fake-backend-text backend)))
   ((state-commit-operation? operation)
    (let ((prior (fake-receipt backend operation)))
      (cond
       (prior
        (if (and (= (cadr prior)
                    (state-commit-operation-expected-state-version operation))
                 (string=? (caddr prior)
                           (state-commit-operation-text operation)))
            (make-state-commit-receipt operation (cadddr prior)
                                       (car (cddddr prior)))
            (make-state-backend-rejection
             operation 'operation-conflict (fake-backend-version backend))))
       ((>= (length (fake-backend-receipts backend))
            (fake-backend-receipt-limit backend))
        (make-state-backend-rejection
         operation 'receipt-quota-exhausted (fake-backend-version backend)))
       ((not (= (state-commit-operation-expected-state-version operation)
                (fake-backend-version backend)))
        (make-state-backend-rejection
         operation 'stale-version (fake-backend-version backend)))
       (else
        (let* ((text (state-commit-operation-text operation))
               (next (+ (fake-backend-version backend) 1))
               (entry
                (list (state-commit-operation-operation-id operation)
                      (state-commit-operation-expected-state-version operation)
                      text next (bytevector-length (string->utf8 text)))))
          (set-fake-backend-present?! backend #t)
          (set-fake-backend-version! backend next)
          (set-fake-backend-text! backend text)
          (set-fake-backend-receipts!
           backend (cons entry (fake-backend-receipts backend)))
          (make-state-commit-receipt operation next
                                     (bytevector-length (string->utf8 text))))))))
   (else (error "fake backend received an unknown typed operation"))))

(define (fake-external-write! backend text)
  (set-fake-backend-present?! backend #t)
  (set-fake-backend-version! backend (+ (fake-backend-version backend) 1))
  (set-fake-backend-text! backend text))

(define (make-fixture name backend)
  (let* ((owner (cons 'endpoint-owner name))
         (grant (cons 'backend-grant name))
         (binding
          (make-state-endpoint-binding owner grant
                                       (string-append "state_" name)
                                       1 'read-write)))
    (values binding (make-state-session binding) backend owner grant)))

(define (read-message name)
  (make-state-read-message (string-append "state_" name) 1))

(define (commit-message name operation-id expected text)
  (make-state-commit-message (string-append "state_" name) 1
                             operation-id expected text))

(define (load! session backend message)
  (let ((operation (state-session-receive! session message)))
    (state-session-apply-backend-result! session
                                         (fake-run backend operation))))

(define (commit! session backend message)
  (unless (eq? (state-session-receive! session message) 'staged)
    (error "commit fixture did not stage"))
  (let ((operation (state-session-dispatch-commit! session)))
    (state-session-apply-backend-result! session
                                         (fake-run backend operation))))

(define (safety-snapshot session binding)
  (list (state-session-phase session)
        (state-endpoint-binding-phase binding)
        (state-session-current-present? session)
        (state-session-current-version session)
        (state-session-current-text session)
        (state-session-draft-text session)
        (state-session-pending-for-test session)))

(test-begin "book-state-protocol")

(let* ((messages
        (list
         (cons (make-state-ready-message "state_grant" 7 'read-write)
               'authority-to-book)
         (cons (make-state-read-message "state_grant" 7)
               'book-to-authority)
         (cons (make-state-commit-message "state_grant" 7 "op-1" 0 "")
               'book-to-authority)
         (cons (make-state-value-message #f 0 "") 'authority-to-book)
         (cons (make-state-value-message #t 1 "") 'authority-to-book)
         (cons (make-state-committed-message "op-1" 1 0)
               'authority-to-book)
         (cons (make-state-conflict-message "op-2" 3)
               'authority-to-book)
         (cons (make-state-commit-failed-message
                "op-3" 'receipt-quota-exhausted)
               'authority-to-book))))
  (for-each
   (lambda (entry)
     (let* ((message (car entry))
            (direction (cdr entry))
            (frame (encode-state-message message))
            (decoded (decode-state-frame frame direction)))
       (test-assert "typed message survives an actual accepted frame"
         (eq? (record-type-descriptor message)
              (record-type-descriptor decoded)))))
   messages))

(test-assert "payload decoder also delegates to the accepted JSON codec"
  (state-read-message?
   (decode-state-payload
    (frame-payload
     (encode-state-message (make-state-read-message "state_payload" 2)))
    'book-to-authority)))

(let* ((frame (encode-state-message
               (make-state-ready-message "state_private" 4 'read-only)))
       (wire (decode-frame frame)))
  (test-equal "ready envelope has five exact fields" 5 (length wire))
  (test-equal "ready envelope exposes only handle generation and access"
    '(#f #f #f #f)
    (map (lambda (name) (assoc name wire))
         '("book" "instance" "namespace" "path")))
  (test-equal "ready access is explicit" "read-only" (field wire "access")))

(for-each
 (lambda (case)
   (test-equal (string-append "lexical integer rejects " (car case)) 'schema
     (state-error-kind
      (lambda ()
        (decode-state-frame (raw-frame (caddr case)) (cadr case))))))
 `(("protocol version 1.0" book-to-authority
    "{\"type\":\"state-read\",\"protocol_version\":1.0,\"grant_handle\":\"g\",\"grant_generation\":1}")
   ("grant generation 1e0" book-to-authority
    "{\"type\":\"state-read\",\"protocol_version\":1,\"grant_handle\":\"g\",\"grant_generation\":1e0}")
   ("expected version 0.0" book-to-authority
    "{\"type\":\"state-commit\",\"protocol_version\":1,\"grant_handle\":\"g\",\"grant_generation\":1,\"operation_id\":\"op\",\"expected_state_version\":0.0,\"text\":\"x\"}")
   ("value state version 1.0" authority-to-book
    "{\"type\":\"state-value\",\"protocol_version\":1,\"present\":true,\"state_version\":1.0,\"text\":\"x\"}")
   ("receipt state version 1e0" authority-to-book
    "{\"type\":\"state-committed\",\"protocol_version\":1,\"operation_id\":\"op\",\"state_version\":1e0,\"text_bytes\":1}")
   ("receipt text bytes 1.0" authority-to-book
    "{\"type\":\"state-committed\",\"protocol_version\":1,\"operation_id\":\"op\",\"state_version\":1,\"text_bytes\":1.0}")
   ("current version 2e0" authority-to-book
    "{\"type\":\"state-conflict\",\"protocol_version\":1,\"operation_id\":\"op\",\"current_state_version\":2e0}")))

(test-equal "escaped reordered key retains lexical integer evidence" 3
  (state-read-message-grant-generation
   (decode-state-frame
    (raw-frame
     "{\"grant_generation\":3,\"grant_handle\":\"g\",\"protocol_\\u0076ersion\":1,\"type\":\"state-read\"}")
    'book-to-authority)))

(for-each
 (lambda (text)
   (test-assert "unknown duplicate or missing fields reject"
     (any-protocol-error?
      (lambda ()
        (decode-state-frame (raw-frame text) 'book-to-authority)))))
 '("{\"type\":\"state-read\",\"protocol_version\":1,\"grant_handle\":\"g\",\"grant_generation\":1,\"path\":\"/tmp/x\"}"
   "{\"type\":\"state-read\",\"protocol_version\":1,\"grant_handle\":\"g\",\"grant_generation\":1,\"grant_generation\":1}"
   "{\"type\":\"state-read\",\"protocol_version\":1,\"grant_handle\":\"g\"}"))

(test-equal "request is rejected in response direction" 'schema
  (state-error-kind
   (lambda ()
     (decode-state-frame
      (encode-state-message (make-state-read-message "g" 1))
      'authority-to-book))))
(test-equal "response is rejected in request direction" 'schema
  (state-error-kind
   (lambda ()
     (decode-state-frame
      (encode-state-message (make-state-value-message #f 0 ""))
      'book-to-authority))))

(test-assert "absent and explicit empty values are distinct records"
  (let ((absent (make-state-value-message #f 0 ""))
        (empty (make-state-value-message #t 1 "")))
    (and (not (state-value-message-present? absent))
         (state-value-message-present? empty)
         (= (state-value-message-state-version absent) 0)
         (= (state-value-message-state-version empty) 1))))
(test-equal "absent cannot carry a present version" 'schema
  (state-error-kind (lambda () (make-state-value-message #f 1 ""))))
(test-equal "absent cannot hide text" 'schema
  (state-error-kind (lambda () (make-state-value-message #f 0 "x"))))

(let ((maximum (make-string 2048 #\λ)))
  (test-equal "4096-byte UTF-8 text is accepted" maximum
    (state-commit-message-text
     (make-state-commit-message "g" 1 "op" 0 maximum)))
  (test-equal "4098-byte UTF-8 text is rejected" 'schema
    (state-error-kind
     (lambda ()
       (make-state-commit-message "g" 1 "op" 0
                                  (string-append maximum "λ"))))))

(define (ascii-operation-id-character-for-test? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (and (char>=? character #\0) (char<=? character #\9))
      (memv character '(#\_ #\-))))

(define (expected-operation-id-for-test? value)
  (and (string? value)
       (<= 1 (string-length value) 128)
       (every ascii-operation-id-character-for-test? (string->list value))))

(test-assert "wire operation-ID predicate matches all ASCII pairs"
  (every
   (lambda (left)
     (every
      (lambda (right)
        (let ((value (string (integer->char left) (integer->char right))))
          (eq? (not (not (book-state-wire-operation-id? value)))
               (not (not (expected-operation-id-for-test? value))))))
      (iota 128)))
   (iota 128)))

(let ((valid-maximum (make-string 128 #\A))
      (invalid-values
       (list "" (make-string 129 #\A) "dot.id" "colon:id" "white space"
             "line\nbreak" (string #\nul) "é" "京東")))
  (test-assert "operation-ID predicate accepts exact positive boundaries"
    (and (book-state-wire-operation-id? "A")
         (book-state-wire-operation-id? valid-maximum)))
  (for-each
   (lambda (value)
     (test-assert "operation-ID predicate rejects a closed-domain counterexample"
       (not (book-state-wire-operation-id? value)))
     (for-each
      (lambda (constructor)
        (test-equal "every operation-ID message constructor rejects it" 'schema
          (state-error-kind (lambda () (constructor value)))))
      (list
       (lambda (id) (make-state-commit-message "g" 1 id 0 "text"))
       (lambda (id) (make-state-committed-message id 1 4))
       (lambda (id) (make-state-conflict-message id 1))
       (lambda (id)
         (make-state-commit-failed-message id 'storage-failure)))))
   invalid-values)
  (for-each
   (lambda (value)
     (test-assert "all four valid operation-ID records encode and decode"
       (every
        (lambda (entry)
          (let ((message (car entry)) (direction (cdr entry)))
            (decode-state-frame (encode-state-message message) direction)
            #t))
        (list
         (cons (make-state-commit-message "g" 1 value 0 "text")
               'book-to-authority)
         (cons (make-state-committed-message value 1 4)
               'authority-to-book)
         (cons (make-state-conflict-message value 1)
               'authority-to-book)
         (cons (make-state-commit-failed-message value 'storage-failure)
               'authority-to-book)))))
   (list "A" valid-maximum))
  (for-each
   (lambda (case)
     (test-equal "all four wire decoders reject invalid operation IDs" 'schema
       (state-error-kind
        (lambda ()
          (decode-state-frame (raw-frame (car case)) (cdr case))))))
   (list
    (cons
     "{\"type\":\"state-commit\",\"protocol_version\":1,\"grant_handle\":\"g\",\"grant_generation\":1,\"operation_id\":\"dot.id\",\"expected_state_version\":0,\"text\":\"x\"}"
     'book-to-authority)
    (cons
     "{\"type\":\"state-committed\",\"protocol_version\":1,\"operation_id\":\"colon:id\",\"state_version\":1,\"text_bytes\":1}"
     'authority-to-book)
    (cons
     "{\"type\":\"state-conflict\",\"protocol_version\":1,\"operation_id\":\"white space\",\"current_state_version\":1}"
     'authority-to-book)
    (cons
     "{\"type\":\"state-commit-failed\",\"protocol_version\":1,\"operation_id\":\"\\u00e9\",\"code\":\"storage-failure\"}"
     'authority-to-book))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "basic" backend))
    (lambda (binding session ignored owner grant)
      (test-equal "new session is ready" 'ready (state-session-phase session))
      (let ((ready (state-session-ready-message session)))
        (test-equal "ready uses endpoint-retained handle" "state_basic"
          (state-ready-message-grant-handle ready)))
      (let ((operation (state-session-receive! session (read-message "basic"))))
        (test-assert "read operation carries exact trusted owner and grant"
          (and (eq? owner (state-read-operation-owner operation))
               (eq? grant (state-read-operation-backend-grant operation))))
        (test-equal "read enters one pending phase" 'read-pending
          (state-session-phase session))
        (let ((value
               (state-session-apply-backend-result!
                session (fake-run backend operation))))
          (test-assert "first read is explicitly absent"
            (and (state-value-message? value)
                 (not (state-value-message-present? value))
                 (= (state-value-message-state-version value) 0)))
          (test-equal "absent read becomes clean" 'clean
            (state-session-phase session))
          (test-equal "state-ready cannot be reannounced after initial read"
            'state
            (state-error-kind
             (lambda () (state-session-ready-message session))))))
      (let* ((commit (commit-message "basic" "save-empty" 0 ""))
             (staged (state-session-receive! session commit)))
        (test-equal "commit first records a dirty edit" '(staged edit-dirty)
          (list staged (state-session-phase session)))
        (let ((operation (state-session-dispatch-commit! session)))
          (test-equal "dispatch enters commit-pending" 'commit-pending
            (state-session-phase session))
          (let ((ack
                 (state-session-apply-backend-result!
                  session (fake-run backend operation))))
            (test-assert "durable receipt creates commit acknowledgement"
              (and (state-committed-message? ack)
                   (= (state-committed-message-state-version ack) 1)
                   (= (state-committed-message-text-bytes ack) 0)))
            (test-equal "receipt precedes commit-ack state" 'commit-ack
              (state-session-phase session))
            (test-assert "empty text is now present rather than absent"
              (and (state-session-current-present? session)
                   (= (state-session-current-version session) 1)
                   (string-null? (state-session-current-text session))))
            (test-equal "lost ack retry returns the same typed receipt"
              '("save-empty" 1)
              (let ((retry (state-session-receive! session commit)))
                (list (state-committed-message-operation-id retry)
                      (state-committed-message-state-version retry))))
            (test-equal "ack send returns to clean" 'clean
              (state-session-note-commit-ack-sent! session))
            (test-assert "retry remains cached after send"
              (state-committed-message?
               (state-session-receive! session commit))))))
      (state-session-close! session 'restart)
      (test-equal "old binding is revoked on close" 'revoked
        (state-endpoint-binding-phase binding))
      (test-equal "one binding cannot open two sessions" 'binding
        (state-error-kind (lambda () (make-state-session binding))))))
  (call-with-values
      (lambda () (make-fixture "reopened" backend))
    (lambda (binding session ignored owner grant)
      (let ((value (load! session backend (read-message "reopened"))))
        (test-assert "new grant reopens the persisted explicit empty value"
          (and (state-value-message-present? value)
               (= (state-value-message-state-version value) 1)
               (string-null? (state-value-message-text value))))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "reuse" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "reuse"))
      (let ((first (commit-message "reuse" "stable-id" 0 "alpha")))
        (commit! session backend first)
        (state-session-note-commit-ack-sent! session)
        (let ((second (commit-message "reuse" "other-id" 1 "beta")))
          (commit! session backend second)
          (state-session-note-commit-ack-sent! session))
        (let ((ack (commit! session backend first)))
          (test-equal "durable old retry returns its original receipt" 1
            (state-committed-message-state-version ack))
          (test-equal "old receipt never rolls current state backward" '(2 "beta")
            (list (state-session-current-version session)
                  (state-session-current-text session)))
          (state-session-note-commit-ack-sent! session))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "changed" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "changed"))
      (let ((original (commit-message "changed" "same-id" 0 "one")))
        (commit! session backend original)
        (state-session-note-commit-ack-sent! session)
        (commit! session backend (commit-message "changed" "second" 1 "two"))
        (state-session-note-commit-ack-sent! session)
        (let ((changed (commit-message "changed" "same-id" 0 "different")))
          (test-equal "changed old operation ID reaches backend conflict" 'backend
            (state-error-kind
             (lambda ()
               (state-session-receive! session changed)
               (let ((operation (state-session-dispatch-commit! session)))
                 (state-session-apply-backend-result!
                  session (fake-run backend operation))))))
          (test-equal "operation conflict closes the protocol grant" 'closing
            (state-session-phase session))
          (test-equal "changed operation ID writes nothing" '(2 "two")
            (list (fake-backend-version backend)
                  (fake-backend-text backend))))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "immediate-reuse" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "immediate-reuse"))
      (state-session-receive!
       session (commit-message "immediate-reuse" "same" 0 "one"))
      (test-equal "staged commit rejects a different operation" 'state
        (state-error-kind
         (lambda ()
           (state-session-receive!
            session (commit-message "immediate-reuse" "different" 0 "one")))))
      (test-equal "staged commit rejects a read that would replace it" 'state
        (state-error-kind
         (lambda ()
           (state-session-receive! session
                                   (read-message "immediate-reuse")))))
      (test-equal "same pending operation ID with changed text is rejected" 'state
        (state-error-kind
         (lambda ()
           (state-session-receive!
            session (commit-message "immediate-reuse" "same" 0 "two")))))
      (test-equal "immediate operation ID misuse closes without a write"
        '(closing 0)
        (list (state-session-phase session)
              (fake-backend-version backend))))))

(let ((backend (make-fake-backend #t 1 "base" '() 64)))
  (call-with-values
      (lambda () (make-fixture "conflict" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "conflict"))
      (fake-external-write! backend "other")
      (let* ((message (commit-message "conflict" "stale" 1 "draft"))
             (response (commit! session backend message)))
        (test-assert "stale CAS returns conflict without overwrite"
          (and (state-conflict-message? response)
               (= (state-conflict-message-current-state-version response) 2)
               (= (fake-backend-version backend) 2)
               (string=? (fake-backend-text backend) "other")))
        (test-equal "conflict retains dirty draft" '(edit-dirty "draft" 2)
          (list (state-session-phase session)
                (state-session-draft-text session)
                (state-session-conflict-version session)))
        (let ((current (load! session backend (read-message "conflict"))))
          (test-equal "read after conflict refreshes base and retains draft"
            '(edit-dirty 2 "other" "draft")
            (list (state-session-phase session)
                  (state-value-message-state-version current)
                  (state-value-message-text current)
                  (state-session-draft-text session))))
        (let ((ack (commit! session backend
                            (commit-message "conflict" "merged" 2 "merged"))))
          (test-equal "new operation commits reconciled text" '(3 "merged")
             (list (state-committed-message-state-version ack)
                   (fake-backend-text backend))))))))

;; Focused v2 read-result consistency: impossible typed completions close,
;; clear pending/draft authority, and never replace the known baseline.
(let ((backend (make-fake-backend #t 5 "new" '() 64)))
  (call-with-values
      (lambda () (make-fixture "read-rollback" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "read-rollback"))
      (let* ((operation
              (state-session-receive! session
                                      (read-message "read-rollback")))
             (result (make-state-read-result operation #t 4 "old")))
        (test-equal "lower typed read result fails closed" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "lower read preserves baseline and clears authority state"
          '(closing revoked #t 5 "new" #f #f)
          (safety-snapshot session binding))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "read-rewrite" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "read-rewrite"))
      (let* ((operation
              (state-session-receive! session
                                      (read-message "read-rewrite")))
             (result (make-state-read-result operation #t 5 "changed")))
        (test-equal "same-version changed text fails closed" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "same-version rewrite leaves exact known text intact"
          '(closing revoked #t 5 "known" #f #f)
          (safety-snapshot session binding))))))

(let ((backend (make-fake-backend #t 1 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "empty-to-absent" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "empty-to-absent"))
      (let* ((operation
              (state-session-receive! session
                                      (read-message "empty-to-absent")))
             (result (make-state-read-result operation #f 0 "")))
        (test-equal "known present empty text cannot regress to absent" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "empty-versus-absent failure preserves present empty"
          '(closing revoked #t 1 "" #f #f)
          (safety-snapshot session binding))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "read-monotonic" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "read-monotonic"))
      (let* ((same-operation
              (state-session-receive! session
                                      (read-message "read-monotonic")))
             (same
              (state-session-apply-backend-result!
               session
               (make-state-read-result same-operation #t 5 "known"))))
        (test-equal "identical same-version read remains legal"
          '(clean 5 "known")
          (list (state-session-phase session)
                (state-value-message-state-version same)
                (state-value-message-text same))))
      (let* ((fresh-operation
              (state-session-receive! session
                                      (read-message "read-monotonic")))
             (fresh
              (state-session-apply-backend-result!
               session
               (make-state-read-result fresh-operation #t 6 "fresh"))))
        (test-equal "higher fresh positive read remains legal"
          '(clean #t 6 "fresh")
          (list (state-session-phase session)
                (state-session-current-present? session)
                (state-value-message-state-version fresh)
                (state-value-message-text fresh)))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "dirty-read-rewrite" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "dirty-read-rewrite"))
      (let ((commit-operation
             (begin
               (state-session-receive!
                session
                (commit-message "dirty-read-rewrite" "DirtyRead" 5 "draft"))
               (state-session-dispatch-commit! session))))
        (state-session-apply-backend-result!
         session
         (make-state-backend-rejection
          commit-operation 'stale-version 6)))
      (let* ((read-operation
              (state-session-receive!
               session (read-message "dirty-read-rewrite")))
             (result
              (make-state-read-result read-operation #t 5 "fabricated")))
        (test-equal "conflict-refresh same-version rewrite fails closed" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "dirty read failure preserves baseline and clears draft"
          '(closing revoked #t 5 "known" #f #f)
          (safety-snapshot session binding))))))

;; Focused v2 stale metadata checks. Current may be below a peer's future
;; expected version, but cannot regress below known state or equal expected.
(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "stale-equal" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "stale-equal"))
      (state-session-receive!
       session (commit-message "stale-equal" "StaleEqual" 5 "draft"))
      (let* ((operation (state-session-dispatch-commit! session))
             (result
              (make-state-backend-rejection
               operation 'stale-version 5)))
        (test-equal "stale current equal to expected fails closed" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "equal stale metadata publishes no conflict or mutation"
          '(closing revoked #t 5 "known" #f #f)
          (safety-snapshot session binding))
        (test-equal "equal stale metadata records no conflict version" #f
          (state-session-conflict-version session))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "stale-below" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "stale-below"))
      (state-session-receive!
       session (commit-message "stale-below" "StaleBelow" 3 "draft"))
      (let* ((operation (state-session-dispatch-commit! session))
             (result
              (make-state-backend-rejection
               operation 'stale-version 4)))
        (test-equal "stale current below known version fails closed" 'backend
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result! session result))))
        (test-equal "regressed stale metadata preserves known baseline"
          '(closing revoked #t 5 "known" #f #f)
          (safety-snapshot session binding))
        (test-equal "regressed stale metadata records no conflict version" #f
          (state-session-conflict-version session))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "stale-greater" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "stale-greater"))
      (state-session-receive!
       session (commit-message "stale-greater" "StaleGreater" 5 "draft"))
      (let* ((operation (state-session-dispatch-commit! session))
             (conflict
              (state-session-apply-backend-result!
               session
               (make-state-backend-rejection
                operation 'stale-version 6))))
        (test-assert "known-lte-current and current-ne-expected is valid"
          (and (state-conflict-message? conflict)
               (= (state-conflict-message-current-state-version conflict) 6)
               (eq? (state-session-phase session) 'edit-dirty)))))))

(let ((backend (make-fake-backend #t 5 "known" '() 64)))
  (call-with-values
      (lambda () (make-fixture "stale-future-expected" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "stale-future-expected"))
      (state-session-receive!
       session
       (commit-message "stale-future-expected" "FutureExpected" 7 "draft"))
      (let* ((operation (state-session-dispatch-commit! session))
             (conflict
              (state-session-apply-backend-result!
               session
               (make-state-backend-rejection
                operation 'stale-version 5))))
        (test-assert "current below future expected remains a legal conflict"
          (and (state-conflict-message? conflict)
               (= (state-conflict-message-current-state-version conflict) 5)
               (eq? (state-session-phase session) 'edit-dirty)))))))

(let ((backend (make-fake-backend #f 0 "" '() 0)))
  (call-with-values
      (lambda () (make-fixture "quota" backend))
    (lambda (binding session ignored owner grant)
      (load! session backend (read-message "quota"))
      (let ((failure
             (commit! session backend
                      (commit-message "quota" "new-id" 0 "unsaved"))))
        (test-assert "receipt quota is an explicit commit failure"
          (and (state-commit-failed-message? failure)
               (eq? (state-commit-failed-message-code failure)
                    'receipt-quota-exhausted)))
        (test-equal "quota failure retains edit and writes nothing"
          '(edit-dirty "unsaved" 0)
          (list (state-session-phase session)
                (state-session-draft-text session)
                (fake-backend-version backend)))
        (test-equal "operator may explicitly discard failed edit" 'clean
          (state-session-discard-edit! session))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "lifecycle" backend))
    (lambda (binding session ignored owner grant)
      (let ((operation
             (state-session-receive! session (read-message "lifecycle"))))
        (test-equal "second operation is rejected while read is pending" 'state
          (state-error-kind
           (lambda ()
             (state-session-receive! session (read-message "lifecycle")))))
        (test-equal "EOF moves directly to closing" 'closing
          (state-session-eof! session))
        (test-equal "late backend completion after EOF is rejected" 'state
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result!
              session (fake-run backend operation)))))
        (test-equal "late wire operation after EOF is rejected" 'state
          (state-error-kind
           (lambda ()
             (state-session-receive! session
                                     (read-message "lifecycle")))))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "exact-a" backend))
    (lambda (binding-a session-a ignored-a owner-a grant-a)
      (call-with-values
          (lambda () (make-fixture "exact-b" backend))
        (lambda (binding-b session-b ignored-b owner-b grant-b)
          (let ((operation-a
                 (state-session-receive! session-a (read-message "exact-a")))
                (operation-b
                 (state-session-receive! session-b (read-message "exact-b"))))
            (test-equal "backend result must name exact pending operation" 'backend
              (state-error-kind
               (lambda ()
                 (state-session-apply-backend-result!
                  session-a (fake-run backend operation-b)))))
            (test-equal "wrong backend result leaves pending read unchanged"
              'read-pending (state-session-phase session-a))
            (state-session-close! session-a 'test-complete)
            (state-session-close! session-b 'test-complete)))))))

(let ((backend (make-fake-backend #f 0 "" '() 64)))
  (call-with-values
      (lambda () (make-fixture "revoked" backend))
    (lambda (binding session ignored owner grant)
      (let ((operation
             (state-session-receive! session (read-message "revoked"))))
        (test-equal "revocation moves the state model to closing" 'closing
          (state-session-revoke! session))
        (test-equal "revoked model rejects a late backend read" 'state
          (state-error-kind
           (lambda ()
             (state-session-apply-backend-result!
              session (fake-run backend operation)))))))))

(let* ((owner (cons 'owner 'read-only))
       (grant (cons 'grant 'read-only))
       (binding (make-state-endpoint-binding owner grant "state_ro" 9 'read-only))
       (session (make-state-session binding))
       (read (make-state-read-message "state_ro" 9))
       (read-operation (state-session-receive! session read)))
  (state-session-apply-backend-result!
   session (make-state-read-result read-operation #f 0 ""))
  (let ((message (make-state-commit-message "state_ro" 9 "op" 0 "text")))
    (test-equal "read-only endpoint rejects commit before backend dispatch" 'binding
      (state-error-kind (lambda () (state-session-receive! session message))))
    (test-equal "read-only rejection leaves clean state unchanged" 'clean
      (state-session-phase session))))

(let* ((owner (cons 'owner 'mismatch))
       (grant (cons 'grant 'mismatch))
       (binding (make-state-endpoint-binding owner grant "state_right" 2
                                             'read-write))
       (session (make-state-session binding)))
  (test-equal "book cannot select another endpoint grant" 'binding
    (state-error-kind
     (lambda ()
       (state-session-receive! session
                               (make-state-read-message "state_wrong" 2)))))
  (test-equal "grant mismatch revokes the model" 'closing
    (state-session-phase session)))

(test-end "book-state-protocol")
