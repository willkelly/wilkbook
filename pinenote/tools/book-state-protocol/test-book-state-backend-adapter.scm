;;; Real-backend host tests for the additive trusted adapter candidate.
(use-modules (book-state)
             (book-state-backend-adapter)
             (book-state-operation-id)
             (book-state-protocol)
             (ice-9 ftw)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-64))

(define roots '())
(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define (make-test-root label)
  (let ((root
         (mkdtemp
          (string-append
           "/tmp/opencode/book-state-adapter-" label ".XXXXXX"))))
    (chmod root #o700)
    (set! roots (cons root roots))
    root))

(define (cleanup-root root)
  (for-each
   (lambda (name)
     (unless (member name
                     '("book-state-v1.sqlite"
                       "book-state-v1.sqlite-journal"
                       "book-state-v1.sqlite-wal"
                       "book-state-v1.sqlite-shm"))
       (error "unexpected adapter test artifact" root name))
     (delete-file (string-append root "/" name)))
   (scandir root (lambda (name) (not (member name '("." ".."))))))
  (rmdir root))

(define (cleanup-roots!)
  (for-each cleanup-root roots)
  (set! roots '()))

(define (protocol-error-kind thunk)
  (catch 'book-state-protocol-error
    (lambda () (thunk) #f)
    (lambda (_key kind _message) kind)))

(define (adapter-error-code thunk)
  (catch 'book-state-backend-adapter-error
    (lambda () (thunk) #f)
    (lambda (_key code _message) code)))

(define make-raw-state-endpoint-binding
  (@@ (book-state-protocol) %make-state-endpoint-binding))

(define (backend-rejection-code result)
  (and (book-state-rejection? result)
       (book-state-rejection-code result)))

(define (typed-rejection-code result)
  (and (state-backend-rejection? result)
       (state-backend-rejection-code result)))

(define (make-context store namespace label access)
  (let* ((owner (list 'trusted-endpoint-owner label))
         (grant (issue-book-state-grant! store namespace owner access))
         (binding
          (make-state-endpoint-binding
           owner grant (book-state-grant-handle grant)
           (book-state-grant-generation grant)
           (book-state-grant-access grant))))
    (values owner grant binding (make-state-session binding))))

(define (read-message grant)
  (make-state-read-message
   (book-state-grant-handle grant)
   (book-state-grant-generation grant)))

(define (commit-message grant operation-id expected-version text)
  (make-state-commit-message
   (book-state-grant-handle grant)
   (book-state-grant-generation grant)
   operation-id expected-version text))

(define (run-read! store session grant)
  (let* ((operation
          (state-session-receive! session (read-message grant)))
         (result (run-state-backend-operation store operation)))
    (values operation result
            (state-session-apply-backend-result! session result))))

(define (run-commit! store session message)
  (unless (eq? (state-session-receive! session message) 'staged)
    (error "commit did not enter the staged state"))
  (let* ((operation (state-session-dispatch-commit! session))
         (result (run-state-backend-operation store operation)))
    (values operation result)))

(define allowed-operation-id-characters
  (string-append
   "abcdefghijklmnopqrstuvwxyz"
   "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
   "0123456789_-"))

(define (predicates-agree? value)
  (eq? (not (not (book-state-wire-operation-id? value)))
       (not (not (book-state-operation-id? value)))))

(test-begin "book-state-backend-adapter")

(test-assert "all three operation-ID byte limits are 128 and aligned"
  (and (= book-state-wire-max-operation-id-bytes 128)
       (= book-state-max-operation-id-bytes 128)
       (= max-state-operation-id-bytes 128)
       (book-state-operation-id-contract-aligned?)))

(test-assert "SQLite-free and backend predicates agree for all ASCII pairs"
  (every
   (lambda (left)
     (every
      (lambda (right)
        (predicates-agree? (string (integer->char left)
                                   (integer->char right))))
      (iota 128)))
   (iota 128)))

(test-assert "the complete allowed alphabet cross-product is accepted"
  (every
   (lambda (left)
     (every
      (lambda (right)
        (let ((value (string left right)))
          (and (book-state-wire-operation-id? value)
               (book-state-operation-id? value))))
      (string->list allowed-operation-id-characters)))
   (string->list allowed-operation-id-characters)))

(test-assert "predicate boundaries and Unicode counterexamples agree"
  (every predicates-agree?
         (list "" "a" (make-string 127 #\a) (make-string 128 #\a)
               (make-string 129 #\a) "has.dot" "has:colon" "has space"
               "unicode-é" "京東" "line\nbreak")))

(let* ((root (make-test-root "save-reopen"))
       (store (open-book-state-store root))
       (namespace
        (open-book-instance! store "book@persistent-note-v1" "reader-1"))
       (saved-text "Persistent λ note — 京東"))
  (call-with-values
      (lambda () (make-context store namespace 'first-open 'read-write))
    (lambda (owner grant binding session)
      (test-assert "state-ready uses the backend-issued handle and generation"
        (let ((ready (state-session-ready-message session)))
          (and (string=? (state-ready-message-grant-handle ready)
                         (book-state-grant-handle grant))
               (= (state-ready-message-grant-generation ready)
                  (book-state-grant-generation grant)))))
      (call-with-values
          (lambda () (run-read! store session grant))
        (lambda (operation backend-result wire-result)
          (test-assert "real backend absent maps to typed state-value"
            (and (state-read-result? backend-result)
                 (state-value-message? wire-result)
                 (not (state-value-message-present? wire-result))
                 (= (state-value-message-state-version wire-result) 0)))))
      (let ((message (commit-message grant "Save_001" 0 saved-text)))
        (call-with-values
            (lambda () (run-commit! store session message))
          (lambda (operation backend-result)
            (test-assert "real durable receipt maps to the exact typed operation"
              (and (state-commit-receipt? backend-result)
                   (eq? operation
                        (state-commit-receipt-operation backend-result))
                   (= (state-commit-receipt-state-version backend-result) 1)
                   (= (state-commit-receipt-text-bytes backend-result)
                      (bytevector-length (string->utf8 saved-text)))))
            (test-equal "backend committed before protocol acknowledgement"
              saved-text
              (book-state-value-text
               (read-book-state store owner grant
                                (book-state-grant-generation grant))))
            (let ((ack
                   (state-session-apply-backend-result!
                    session backend-result)))
              (test-assert "storage receipt separately creates state-committed"
                (and (state-committed-message? ack)
                     (string=?
                      (state-committed-message-operation-id ack) "Save_001")
                     (= (state-committed-message-state-version ack) 1)))
              (test-assert "lost wire ack retries the cached receipt"
                (state-committed-message?
                 (state-session-receive! session message)))
              (state-session-note-commit-ack-sent! session)))))
      (test-equal "local close then backend revocation succeeds" 'revoked
        (close-state-session-and-revoke!
         store session binding 'book-close))))
  (close-book-state-store! store)

  (let* ((reopened (open-book-state-store root))
         (reopened-namespace
          (open-book-instance! reopened
                               "book@persistent-note-v1" "reader-1")))
    (call-with-values
        (lambda ()
          (make-context reopened reopened-namespace
                        'second-open 'read-write))
      (lambda (owner grant binding session)
        (call-with-values
            (lambda () (run-read! reopened session grant))
          (lambda (operation backend-result wire-result)
            (test-equal "close/restart/reopen loads the real stored text"
              (list #t 1 saved-text)
              (list (state-value-message-present? wire-result)
                    (state-value-message-state-version wire-result)
                    (state-value-message-text wire-result)))))
        (let ((retry (commit-message grant "Save_001" 0 saved-text)))
          (call-with-values
              (lambda () (run-commit! reopened session retry))
            (lambda (operation backend-result)
              (test-equal "backend restart exact retry returns original receipt"
                '(1 1)
                (list (state-commit-receipt-state-version backend-result)
                      (state-session-current-version session)))
              (state-session-apply-backend-result! session backend-result)
              (test-equal "old receipt does not roll the loaded view backward"
                (list 1 saved-text)
                (list (state-session-current-version session)
                      (state-session-current-text session)))
              (state-session-note-commit-ack-sent! session))))
        (close-state-session-and-revoke!
         reopened session binding 'retry-complete)))

    (call-with-values
        (lambda ()
          (make-context reopened reopened-namespace
                        'stale-open 'read-write))
      (lambda (owner grant binding session)
        (run-read! reopened session grant)
        (call-with-values
            (lambda ()
              (run-commit!
               reopened session
               (commit-message grant "Save_Stale" 0 "must-not-write")))
          (lambda (operation backend-result)
            (test-equal "real stale CAS maps without overwrite" 'stale-version
              (typed-rejection-code backend-result))
            (let ((conflict
                   (state-session-apply-backend-result!
                    session backend-result)))
              (test-assert "stale CAS becomes the finite conflict message"
                (and (state-conflict-message? conflict)
                     (= (state-conflict-message-current-state-version
                         conflict) 1))))))
        (test-equal "stale candidate did not change real storage" saved-text
          (book-state-value-text
           (read-book-state reopened owner grant
                            (book-state-grant-generation grant))))
        (close-state-session-and-revoke!
         reopened session binding 'stale-complete)))

    (call-with-values
        (lambda ()
          (make-context reopened reopened-namespace
                        'changed-retry-open 'read-write))
      (lambda (owner grant binding session)
        (run-read! reopened session grant)
        (call-with-values
            (lambda ()
              (run-commit!
               reopened session
               (commit-message grant "Save_001" 0 "changed-payload")))
          (lambda (operation backend-result)
            (test-equal "real changed retry maps operation-conflict"
              'operation-conflict (typed-rejection-code backend-result))
            (test-equal "operation conflict closes the typed model" 'backend
              (protocol-error-kind
               (lambda ()
                 (state-session-apply-backend-result!
                  session backend-result))))))
        (test-equal "changed retry wrote nothing" saved-text
          (book-state-value-text
           (read-book-state reopened owner grant
                            (book-state-grant-generation grant))))
        (test-equal "closed model still revokes its backend grant" 'revoked
          (revoke-state-backend-binding! reopened binding))))
    (close-book-state-store! reopened)))

(let* ((root (make-test-root "grammar-counterexample"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@grammar" "reader-1")))
  (call-with-values
      (lambda () (make-context store namespace 'grammar 'read-write))
    (lambda (owner grant binding session)
      (run-read! store session grant)
      (test-equal "v2 protocol constructor rejects the former dot counterexample"
        'schema
        (protocol-error-kind
         (lambda ()
           (commit-message grant "formerly.valid" 0 "no-write"))))
      (test-assert "SQLite-free client predicate rejects the dot"
        (not (book-state-wire-operation-id? "formerly.valid")))
      (test-equal "backend predicate rejects the same dot" 'invalid-operation-id
        (backend-rejection-code
         (commit-book-state!
          store owner grant (book-state-grant-generation grant)
          "formerly.valid" 0 "no-write")))
      (test-assert "invalid ID left the real namespace absent"
        (book-state-absent?
         (read-book-state store owner grant
                          (book-state-grant-generation grant))))
      (revoke-state-backend-binding! store binding)))
  (close-book-state-store! store))

(let* ((root (make-test-root "linearization"))
       (store (open-book-state-store root))
       (before-namespace
        (open-book-instance! store "book@linearization" "revoke-first"))
       (after-namespace
        (open-book-instance! store "book@linearization" "commit-first")))
  (call-with-values
      (lambda () (make-context store before-namespace 'revoke-first 'read-write))
    (lambda (owner grant binding session)
      (run-read! store session grant)
      (state-session-receive!
       session (commit-message grant "RevokeFirst" 0 "must-not-write"))
      (let ((operation (state-session-dispatch-commit! session)))
        (test-equal "revoke-first ordering revokes under backend mutex" 'revoked
          (close-state-session-and-revoke!
           store session binding 'owner-close))
        (let ((late-result (run-state-backend-operation store operation)))
          (test-equal "operation reaching backend after revoke is rejected"
            'revoked (typed-rejection-code late-result))
          (test-equal "closed model rejects revoke-first late result" 'state
            (protocol-error-kind
             (lambda ()
               (state-session-apply-backend-result!
                session late-result)))))))
    )
  (call-with-values
      (lambda () (make-context store before-namespace 'revoke-first-check
                               'read-only))
    (lambda (owner grant binding session)
      (call-with-values
          (lambda () (run-read! store session grant))
        (lambda (operation result wire-result)
          (test-assert "revoke-first ordering leaves storage absent"
            (not (state-value-message-present? wire-result)))))
      (close-state-session-and-revoke!
       store session binding 'check-complete)))

  (call-with-values
      (lambda () (make-context store after-namespace 'commit-first 'read-write))
    (lambda (owner grant binding session)
      (run-read! store session grant)
      (call-with-values
          (lambda ()
            (run-commit!
             store session
             (commit-message grant "CommitFirst" 0 "durable-before-close")))
        (lambda (operation durable-result)
          (test-assert "commit-first reached a durable backend receipt"
            (state-commit-receipt? durable-result))
          (test-equal "close revokes after already-linearized commit" 'revoked
            (close-state-session-and-revoke!
             store session binding 'owner-close))
          (test-equal "closed model rejects commit-first late receipt" 'state
            (protocol-error-kind
             (lambda ()
               (state-session-apply-backend-result!
                session durable-result))))))))
  (call-with-values
      (lambda () (make-context store after-namespace 'commit-first-check
                               'read-only))
    (lambda (owner grant binding session)
      (call-with-values
          (lambda () (run-read! store session grant))
        (lambda (operation result wire-result)
          (test-equal "commit-first value persists but was not accepted late"
            '(1 "durable-before-close")
            (list (state-value-message-state-version wire-result)
                  (state-value-message-text wire-result)))))
      (close-state-session-and-revoke!
       store session binding 'check-complete)))
  (close-book-state-store! store))

(let* ((root (make-test-root "lifecycle-pairing"))
       (store (open-book-state-store root))
       (namespace-a
        (open-book-instance! store "book@pairing" "endpoint-a"))
       (namespace-b
        (open-book-instance! store "book@pairing" "endpoint-b")))
  (call-with-values
      (lambda () (make-context store namespace-a 'pair-a 'read-write))
    (lambda (owner-a grant-a binding-a session-a)
      (call-with-values
          (lambda () (make-context store namespace-b 'pair-b 'read-write))
        (lambda (owner-b grant-b binding-b session-b)
          (run-read! store session-a grant-a)
          (run-read! store session-b grant-b)
          (state-session-receive!
           session-a
           (commit-message grant-a "Pair_A_Captured" 0
                           "must-not-write-after-close"))
          (let ((captured-a (state-session-dispatch-commit! session-a)))
            (test-equal "mismatched session/binding pair fails explicitly"
              'session-binding-mismatch
              (adapter-error-code
               (lambda ()
                 (close-state-session-and-revoke!
                  store session-a binding-b 'wrong-pair))))
            (test-equal "pair mismatch mutates neither local state session"
              '(commit-pending clean)
              (list (state-session-phase session-a)
                    (state-session-phase session-b)))
            (test-assert "pair mismatch revokes neither backend grant"
              (and (book-state-absent?
                    (read-book-state
                     store owner-a grant-a
                     (book-state-grant-generation grant-a)))
                   (book-state-absent?
                    (read-book-state
                     store owner-b grant-b
                     (book-state-grant-generation grant-b)))))
            (test-equal "proper A close revokes only A" 'revoked
              (close-state-session-and-revoke!
               store session-a binding-a 'proper-a-close))
            (let ((late-a
                   (run-state-backend-operation store captured-a)))
              (test-equal "captured A operation reaching backend after close rejects"
                'revoked (typed-rejection-code late-a))
              (test-equal "closed A model rejects the late typed result" 'state
                (protocol-error-kind
                 (lambda ()
                   (state-session-apply-backend-result!
                    session-a late-a)))))
            (test-assert "proper A close wrote nothing and left B active"
              (and (book-state-absent?
                    (read-book-state
                     store owner-b grant-b
                     (book-state-grant-generation grant-b)))
                   (book-state-rejection?
                    (read-book-state
                     store owner-a grant-a
                     (book-state-grant-generation grant-a)))))
            (close-state-session-and-revoke!
             store session-b binding-b 'proper-b-close))))))

  (let* ((owner (list 'trusted-endpoint-owner 'malformed))
         (grant (issue-book-state-grant!
                 store namespace-a owner 'read-write))
         (malformed-binding
          (make-raw-state-endpoint-binding
           owner grant "metadata-does-not-match-grant"
           (book-state-grant-generation grant)
           (book-state-grant-access grant) 'available))
         (malformed-session (make-state-session malformed-binding)))
    (test-equal "malformed retained binding fails before local close"
      'binding-grant-mismatch
      (adapter-error-code
       (lambda ()
         (close-state-session-and-revoke!
          store malformed-session malformed-binding 'malformed))))
    (test-equal "malformed metadata leaves local session and grant active"
      '(ready absent)
      (list
       (state-session-phase malformed-session)
       (if (book-state-absent?
            (read-book-state
             store owner grant (book-state-grant-generation grant)))
           'absent 'not-active)))
    ;; Test-only cleanup cannot use the deliberately rejected malformed
    ;; binding helper.
    (state-session-close! malformed-session 'test-cleanup)
    (revoke-book-state-grant! store owner grant))
  (close-book-state-store! store))

(test-end "book-state-backend-adapter")
(cleanup-roots!)
(unless (zero? (test-runner-fail-count runner))
  (exit 1))
