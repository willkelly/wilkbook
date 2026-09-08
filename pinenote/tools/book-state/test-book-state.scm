;;; Host semantic and real-SQLite tests for the first Book State slice.
(use-modules (book-state)
             (ice-9 ftw)
             (ice-9 threads)
             (sqlite3)
             (srfi srfi-1)
             (srfi srfi-64))

(define commit-fault-hook-for-test
  (@@ (book-state) commit-fault-hook))
(define store-database-for-test
  (@@ (book-state) %book-state-store-database))
(define scalar-for-test
  (@@ (book-state) scalar))
(define query-one-for-test
  (@@ (book-state) query-one))

(define roots '())
(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define (make-test-root label)
  (let ((root
         (mkdtemp
          (string-append "/tmp/opencode/book-state-" label ".XXXXXX"))))
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
       (error "unexpected Book State test artifact" root name))
     (let ((path (string-append root "/" name)))
       (when (lstat path) (delete-file path))))
   (scandir root (lambda (name) (not (member name '("." ".."))))))
  (rmdir root))

(define (rejection-code value)
  (and (book-state-rejection? value) (book-state-rejection-code value)))

(define (open-error-code thunk)
  (catch 'book-state-open-error
    (lambda ()
      (thunk)
      'unexpected-success)
    (lambda (_key code _message) code)))

(define (schema-open-result root)
  (catch 'book-state-unsupported-schema
    (lambda ()
      (let ((store (open-book-state-store root)))
        (close-book-state-store! store)
        'unexpected-success))
    (lambda (_key observed supported) (list observed supported))))

(define (with-external-database root procedure)
  (let ((database
         (sqlite-open (string-append root "/book-state-v1.sqlite"))))
    (dynamic-wind
      (lambda () #t)
      (lambda () (procedure database))
      (lambda () (sqlite-close database)))))

(define (make-initialized-schema-root label)
  (let* ((root (make-test-root label))
         (store (open-book-state-store root)))
    (unless (book-state-namespace?
             (open-book-instance! store "book@schema-test" "instance"))
      (error "failed to create schema-test namespace" label))
    (close-book-state-store! store)
    root))

(define (receipt-fields value)
  (and (book-state-receipt? value)
       (list (book-state-receipt-operation-id value)
             (book-state-receipt-expected-state-version value)
             (book-state-receipt-state-version value)
             (book-state-receipt-text-bytes value))))

(define (state-fields value)
  (cond
   ((book-state-absent? value)
    (list 'absent (book-state-absent-state-version value)))
   ((book-state-value? value)
    (list 'value (book-state-value-state-version value)
          (book-state-value-text value)))
   ((book-state-rejection? value)
    (list 'rejection (book-state-rejection-code value)
          (book-state-rejection-current-state-version value)))
   (else '(unknown))))

(test-begin "book-state")

(let ((root (make-test-root "private-root")))
  (chmod root #o755)
  (test-equal "non-private state root is rejected before database creation"
    'invalid-root
    (open-error-code (lambda () (open-book-state-store root))))
  (chmod root #o700))

(let* ((root (make-test-root "trusted-identity"))
       (store (open-book-state-store root)))
  (test-equal "trusted factory rejects empty instance identity as data"
    'invalid-trusted-identity
    (rejection-code (open-book-instance! store "book@1" "")))
  (test-equal "trusted factory rejects oversized revision identity as data"
    'invalid-trusted-identity
    (rejection-code
     (open-book-instance! store
                          (make-string (+ book-state-max-identity-bytes 1) #\b)
                          "instance")))
  (close-book-state-store! store))

(let* ((root (make-test-root "semantics"))
       (store (open-book-state-store root))
       (first (open-book-instance! store "book@revision-1" "instance-a"))
       (second (open-book-instance! store "book@revision-1" "instance-b"))
       (owner (list 'owner-a))
       (other-owner (list 'owner-b))
       (grant (issue-book-state-grant! store first owner 'read-write))
       (generation (book-state-grant-generation grant)))
  (let ((database (store-database-for-test store)))
    (test-equal "storage schema version is independent and exactly one" 1
      (scalar-for-test database "PRAGMA user_version"))
    (test-equal "rollback journal mode is DELETE" "delete"
      (scalar-for-test database "PRAGMA journal_mode"))
    (test-equal "synchronous mode is FULL" 2
      (scalar-for-test database "PRAGMA synchronous"))
    (test-equal "foreign keys are enforced" 1
      (scalar-for-test database "PRAGMA foreign_keys"))
    (test-equal "trusted schema is disabled" 0
      (scalar-for-test database "PRAGMA trusted_schema"))
    (test-equal "temporary state remains memory-only" 2
      (scalar-for-test database "PRAGMA temp_store"))
    (test-equal "page size is fixed" book-state-page-size
      (scalar-for-test database "PRAGMA page_size"))
    (test-equal "database page quota is fixed" book-state-max-database-pages
      (scalar-for-test database "PRAGMA max_page_count")))
  (test-equal "new instance is absent rather than empty" '(absent 0)
    (state-fields (read-book-state store owner grant generation)))
  (let ((empty-receipt
         (commit-book-state! store owner grant generation "empty-save" 0 "")))
    (test-equal "empty text commit returns durable typed receipt"
      '("empty-save" 0 1 0) (receipt-fields empty-receipt))
    (test-equal "present empty text remains distinguishable from absent"
      '(value 1 "")
      (state-fields (read-book-state store owner grant generation)))
    (test-equal "exact operation retry returns original receipt"
      (receipt-fields empty-receipt)
      (receipt-fields
       (commit-book-state! store owner grant generation "empty-save" 0 ""))))
  (test-equal "same operation ID with changed expected version is rejected"
    'operation-conflict
    (rejection-code
     (commit-book-state! store owner grant generation "empty-save" 1 "")))
  (test-equal "same operation ID with changed text is rejected"
    'operation-conflict
    (rejection-code
     (commit-book-state! store owner grant generation "empty-save" 0 "changed")))
  (test-equal "new stale expected version is rejected"
    '(rejection stale-version 1)
    (state-fields
     (commit-book-state! store owner grant generation "stale-save" 0 "stale")))
  (test-equal "stale and conflicting operations did not write"
    '(value 1 "")
    (state-fields (read-book-state store owner grant generation)))
  (let* ((second-grant
          (issue-book-state-grant! store second other-owner 'read-write))
         (second-generation (book-state-grant-generation second-grant)))
    (test-equal "second BookInstance starts isolated" '(absent 0)
      (state-fields
       (read-book-state store other-owner second-grant second-generation)))
    (test-assert "second BookInstance can commit independently"
      (book-state-receipt?
       (commit-book-state! store other-owner second-grant second-generation
                           "second-save" 0 "instance-b text")))
    (test-equal "first BookInstance was not changed by second"
      '(value 1 "")
      (state-fields (read-book-state store owner grant generation))))
  (let ((read-only
         (issue-book-state-grant! store first owner 'read-only)))
    (test-equal "read-only grant reads" '(value 1 "")
      (state-fields
       (read-book-state store owner read-only
                        (book-state-grant-generation read-only))))
    (test-equal "read-only grant rejects commit" 'read-only
      (rejection-code
       (commit-book-state!
        store owner read-only (book-state-grant-generation read-only)
        "read-only-save" 1 "no"))))
  (test-equal "wrong owner cannot borrow grant" 'owner-mismatch
    (rejection-code (read-book-state store other-owner grant generation)))
  (test-equal "wrong generation is stale" 'stale-generation
    (rejection-code (read-book-state store owner grant (+ generation 1))))
  (test-equal "owner revokes active grant" 'revoked
    (revoke-book-state-grant! store owner grant))
  (test-equal "revocation is idempotent" 'already-revoked
    (revoke-book-state-grant! store owner grant))
  (test-equal "revoked grant rejects reads" 'revoked
    (rejection-code (read-book-state store owner grant generation)))
  (close-book-state-store! store)
  (test-equal "closed store phase is explicit" 'closed
    (book-state-store-phase store))
  (test-equal "closed store rejects retained grant" 'store-closed
    (rejection-code (read-book-state store owner grant generation)))
  (let* ((reopened (open-book-state-store root))
         (reopened-namespace
          (open-book-instance! reopened "book@revision-1" "instance-a"))
         (reopened-owner (list 'owner-after-restart))
         (reopened-grant
          (issue-book-state-grant! reopened reopened-namespace
                                   reopened-owner 'read-only)))
    (test-equal "grant record from prior store process is not reusable"
      'invalid-grant
      (rejection-code
       (read-book-state reopened owner grant generation)))
    (test-equal "trusted namespace reopen retains present empty text"
      '(value 1 "")
      (state-fields
       (read-book-state reopened reopened-owner reopened-grant
                        (book-state-grant-generation reopened-grant))))
    (close-book-state-store! reopened)))

(let* ((root (make-test-root "bounds"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@bounds" "instance"))
       (owner (list 'bounds-owner))
       (grant (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant))
       (exact-text (make-string 2048 #\é))
       (oversized-text (make-string 2049 #\é)))
  (test-assert "exported operation-ID grammar accepts its exact ASCII alphabet"
    (book-state-operation-id?
     "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"))
  (for-each
   (lambda (invalid)
     (test-assert (format #f "operation-ID grammar rejects ~s" invalid)
       (not (book-state-operation-id? invalid))))
   '("" "has.dot" "has:colon" "has space" "unicode-é" "line\nbreak"))
  (test-assert "128-byte operation ID is valid"
    (book-state-operation-id? (make-string 128 #\a)))
  (test-equal "commit uses the exported operation-ID grammar" 'invalid-operation-id
    (rejection-code
     (commit-book-state! store owner grant generation
                         "not.valid" 0 "no")))
  (test-equal "129-byte operation ID is rejected" 'invalid-operation-id
    (rejection-code
     (commit-book-state! store owner grant generation
                         (make-string 129 #\a) 0 "no")))
  (test-equal "4096-byte UTF-8 text is accepted" '("text-limit" 0 1 4096)
    (receipt-fields
     (commit-book-state! store owner grant generation
                         "text-limit" 0 exact-text)))
  (test-equal "4098-byte UTF-8 text is rejected before SQLite" 'text-too-large
    (rejection-code
     (commit-book-state! store owner grant generation
                         "text-over-limit" 1 oversized-text)))
  (test-equal "state version above retained history is rejected" 'invalid-expected-version
    (rejection-code
     (commit-book-state! store owner grant generation "version-over-limit"
                         (+ book-state-max-receipts-per-namespace 1) "no")))
  (close-book-state-store! store))

(let* ((root (make-test-root "owned-copies"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@copies" "instance"))
       (owner (list 'copy-owner))
       (grant (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant))
       (operation-id (string-copy "copy-operation"))
       (text (string-copy "copy-text"))
       (handle-copy (book-state-grant-handle grant))
       (receipt
        (commit-book-state! store owner grant generation
                            operation-id 0 text)))
  (string-set! operation-id 0 #\X)
  (string-set! text 0 #\X)
  (string-set! handle-copy 0 #\X)
  (test-equal "commit owns operation ID before returning" "copy-operation"
    (book-state-receipt-operation-id receipt))
  (test-equal "commit owns input text before returning" '(value 1 "copy-text")
    (state-fields (read-book-state store owner grant generation)))
  (test-assert "grant accessor returns a copy rather than authority storage"
    (not (string=? handle-copy (book-state-grant-handle grant))))
  (let* ((value (read-book-state store owner grant generation))
         (text-copy (book-state-value-text value))
         (receipt-id-copy (book-state-receipt-operation-id receipt)))
    (string-set! text-copy 0 #\X)
    (string-set! receipt-id-copy 0 #\X)
    (test-equal "state accessor returns a defensive text copy"
      '(value 1 "copy-text")
      (state-fields (read-book-state store owner grant generation)))
    (test-equal "receipt accessor returns a defensive operation-ID copy"
      "copy-operation" (book-state-receipt-operation-id receipt)))
  (close-book-state-store! store))

(let* ((root (make-test-root "namespaces"))
       (store (open-book-state-store root)))
  (do ((index 0 (+ index 1)))
      ((= index book-state-max-namespaces))
    (unless
        (book-state-namespace?
         (open-book-instance! store "book@namespace-quota"
                              (format #f "instance-~a" index)))
      (error "namespace quota setup failed" index)))
  (test-equal "new instance fails when namespace quota is full"
    'namespace-quota-exhausted
    (rejection-code
     (open-book-instance! store "book@namespace-quota" "overflow")))
  (test-assert "existing trusted namespace still reopens at full quota"
    (book-state-namespace?
     (open-book-instance! store "book@namespace-quota" "instance-0")))
  (close-book-state-store! store))

(let* ((root (make-test-root "grants"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@grant-quota" "instance"))
       (owner (list 'grant-quota-owner))
       (grants
        (map (lambda (_index)
               (issue-book-state-grant! store namespace owner 'read-only))
             (iota book-state-max-live-grants))))
  (test-assert "live grant quota setup issued typed grants"
    (every book-state-grant? grants))
  (test-equal "new grant fails when live grant quota is full"
    'grant-quota-exhausted
    (rejection-code
     (issue-book-state-grant! store namespace owner 'read-only)))
  (test-equal "revocation retires one live grant slot" 'revoked
    (revoke-book-state-grant! store owner (car grants)))
  (test-assert "retired grant slot can be reissued with fresh authority"
    (book-state-grant?
     (issue-book-state-grant! store namespace owner 'read-only)))
  (close-book-state-store! store))

(let* ((root (make-test-root "receipts"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@receipts" "instance"))
       (owner (list 'receipt-owner))
       (grant (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant)))
  (do ((index 0 (+ index 1)))
      ((= index book-state-max-receipts-per-namespace))
    (let ((result
           (commit-book-state!
            store owner grant generation (format #f "receipt-~a" index)
            index (format #f "value-~a" index))))
      (unless (and (book-state-receipt? result)
                   (= (book-state-receipt-state-version result) (+ index 1)))
        (error "receipt quota setup failed" index result))))
  (test-equal "new operation fails when durable receipt quota is full"
    'receipt-quota-exhausted
    (rejection-code
     (commit-book-state! store owner grant generation "receipt-overflow"
                         book-state-max-receipts-per-namespace "overflow")))
  (test-equal "full quota still preserves exact retry history"
    '("receipt-0" 0 1 7)
    (receipt-fields
     (commit-book-state! store owner grant generation
                         "receipt-0" 0 "value-0")))
  (test-equal "stale CAS remains distinguishable when receipt quota is full"
    'stale-version
    (rejection-code
     (commit-book-state! store owner grant generation
                         "stale-at-full-quota" 0 "stale")))
  (test-equal "quota rejection did not advance state"
    book-state-max-receipts-per-namespace
    (book-state-value-state-version
     (read-book-state store owner grant generation)))
  (close-book-state-store! store))

(let* ((root (make-test-root "capacity"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@capacity" "instance"))
       (owner (list 'capacity-owner))
       (grant (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant))
       (database (store-database-for-test store))
       (page-count (scalar-for-test database "PRAGMA page_count"))
       (large (make-string book-state-max-text-bytes #\x))
       (failure #f)
       (last-version 0))
  (sqlite-exec database (format #f "PRAGMA max_page_count = ~a" page-count))
  (let loop ((index 0))
    (when (and (< index book-state-max-receipts-per-namespace) (not failure))
      (let ((result
             (commit-book-state! store owner grant generation
                                 (format #f "capacity-~a" index)
                                 last-version large)))
        (if (book-state-receipt? result)
            (begin
              (set! last-version (book-state-receipt-state-version result))
              (loop (+ index 1)))
            (set! failure result)))))
  (test-equal "real SQLite page exhaustion fails closed" 'storage-failure
    (rejection-code failure))
  (test-equal "ambiguous SQLite rollback retires the worker" 'failed
    (book-state-store-phase store))
  (test-equal "failed worker revokes its live grant" 'revoked
    (book-state-grant-state grant))
  (test-equal "failed worker rejects further operations distinctly" 'store-failed
    (rejection-code (read-book-state store owner grant generation)))
  (close-book-state-store! store)
  (let* ((reopened (open-book-state-store root))
         (reopened-namespace
          (open-book-instance! reopened "book@capacity" "instance"))
         (reopened-owner (list 'capacity-recovery-owner))
         (reopened-grant
          (issue-book-state-grant! reopened reopened-namespace
                                   reopened-owner 'read-write))
         (reopened-generation
          (book-state-grant-generation reopened-grant)))
    (test-equal "fresh worker confirms failed full transaction did not advance"
      (if (zero? last-version)
          '(absent 0)
          (list 'value last-version large))
      (state-fields
       (read-book-state reopened reopened-owner reopened-grant
                        reopened-generation)))
    (test-assert "fresh worker is usable after SQLITE_FULL recovery"
      (book-state-receipt?
       (commit-book-state! reopened reopened-owner reopened-grant
                           reopened-generation "after-capacity"
                           last-version "small")))
    (close-book-state-store! reopened)))

(let* ((root (make-test-root "revoke-race"))
       (store (open-book-state-store root))
       (namespace (open-book-instance! store "book@race" "instance"))
       (owner (list 'race-owner))
       (grant (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant))
       (gate (make-mutex))
       (condition (make-condition-variable))
       (entered? #f)
       (release? #f)
       (commit-result #f)
       (revoke-result #f))
  (define (blocked-before-commit point)
    (when (eq? point 'before-commit)
      (lock-mutex gate)
      (set! entered? #t)
      (signal-condition-variable condition)
      (let wait ()
        (unless release?
          (wait-condition-variable condition gate)
          (wait)))
      (unlock-mutex gate)))
  (let ((commit-thread
         (call-with-new-thread
          (lambda ()
            (parameterize ((commit-fault-hook-for-test blocked-before-commit))
              (set! commit-result
                    (commit-book-state! store owner grant generation
                                        "race-save" 0 "won before revoke")))))))
    (lock-mutex gate)
    (let wait ()
      (unless entered?
        (wait-condition-variable condition gate)
        (wait)))
    (let ((revoke-thread
           (call-with-new-thread
            (lambda ()
              (set! revoke-result
                    (revoke-book-state-grant! store owner grant))))))
      (set! release? #t)
      (signal-condition-variable condition)
      (unlock-mutex gate)
      (join-thread commit-thread)
      (join-thread revoke-thread)))
  (test-equal "commit that linearizes first returns durable receipt"
    '("race-save" 0 1 17) (receipt-fields commit-result))
  (test-equal "concurrent revocation linearizes after complete commit" 'revoked
    revoke-result)
  (test-equal "later commit sees revocation without check/I-O gap" 'revoked
    (rejection-code
     (commit-book-state! store owner grant generation
                         "after-revoke" 1 "no")))
  (close-book-state-store! store))

(let* ((root (make-test-root "two-handle-cas"))
       (store-a (open-book-state-store root))
       (namespace-a
        (open-book-instance! store-a "book@two-handle" "instance"))
       (store-b (open-book-state-store root))
       (namespace-b
        (open-book-instance! store-b "book@two-handle" "instance"))
       (owner-a (list 'two-handle-owner-a))
       (owner-b (list 'two-handle-owner-b))
       (grant-a
        (issue-book-state-grant! store-a namespace-a owner-a 'read-write))
       (grant-b
        (issue-book-state-grant! store-b namespace-b owner-b 'read-write))
       (gate (make-mutex))
       (condition (make-condition-variable))
       (ready 0)
       (go? #f)
       (result-a #f)
       (result-b #f))
  (define (wait-for-race-start)
    (lock-mutex gate)
    (set! ready (+ ready 1))
    (broadcast-condition-variable condition)
    (let wait ()
      (unless go?
        (wait-condition-variable condition gate)
        (wait)))
    (unlock-mutex gate))
  (let ((thread-a
         (call-with-new-thread
          (lambda ()
            (wait-for-race-start)
            (set! result-a
                  (commit-book-state!
                   store-a owner-a grant-a
                   (book-state-grant-generation grant-a)
                   "two-handle-a" 0 "writer-a")))))
        (thread-b
         (call-with-new-thread
          (lambda ()
            (wait-for-race-start)
            (set! result-b
                  (commit-book-state!
                   store-b owner-b grant-b
                   (book-state-grant-generation grant-b)
                   "two-handle-b" 0 "writer-b"))))))
    (lock-mutex gate)
    (let wait ()
      (unless (= ready 2)
        (wait-condition-variable condition gate)
        (wait)))
    (set! go? #t)
    (broadcast-condition-variable condition)
    (unlock-mutex gate)
    (join-thread thread-a)
    (join-thread thread-b))
  (let ((receipts (filter book-state-receipt? (list result-a result-b)))
        (rejections (filter book-state-rejection? (list result-a result-b))))
    (test-equal "two valid handles serialize to one successful CAS" 1
      (length receipts))
    (test-equal "two valid handles leave one stale CAS" '(stale-version)
      (map book-state-rejection-code rejections))
    (test-equal "two-handle CAS creates exactly one durable receipt" 1
      (scalar-for-test
       (store-database-for-test store-a)
       "SELECT COUNT(*) FROM commit_receipts")))
  (let ((final (book-state-value-text
               (read-book-state
                store-a owner-a grant-a
                (book-state-grant-generation grant-a)))))
    (test-assert "two-handle CAS leaves exactly one winning value"
      (member final '("writer-a" "writer-b"))))
  (close-book-state-store! store-b)
  (close-book-state-store! store-a))

(let ((root (make-initialized-schema-root "schema-trigger-open")))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec
      database
      "CREATE TRIGGER discard_receipt AFTER INSERT ON commit_receipts BEGIN DELETE FROM commit_receipts WHERE namespace_id = NEW.namespace_id AND operation_id = NEW.operation_id; END")))
  (test-equal "BS1 receipt-deleting trigger is rejected at open"
    '(inconsistent 1) (schema-open-result root))
  (with-external-database
   root
   (lambda (database)
     (test-equal "failed trigger-schema open did not advance state"
       '#(0 0 #f)
       (query-one-for-test
        database
        "SELECT state_version, has_value, text FROM book_instances"))
     (test-equal "failed trigger-schema open created no receipt" 0
       (scalar-for-test database "SELECT COUNT(*) FROM commit_receipts"))
     (test-equal "backend did not silently delete the rejected trigger" 1
       (scalar-for-test
        database
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'trigger' AND name = 'discard_receipt'")))))

(let* ((root (make-test-root "schema-trigger-midlife"))
       (store (open-book-state-store root))
       (namespace
        (open-book-instance! store "book@midlife-schema" "instance"))
       (owner (list 'midlife-schema-owner))
       (grant
        (issue-book-state-grant! store namespace owner 'read-write))
       (generation (book-state-grant-generation grant)))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec
      database
      "CREATE TRIGGER discard_receipt AFTER INSERT ON commit_receipts BEGIN DELETE FROM commit_receipts WHERE namespace_id = NEW.namespace_id AND operation_id = NEW.operation_id; END")))
  (test-equal "midlife BS1 trigger is rejected inside the write transaction"
    '(inconsistent 1)
    (catch 'book-state-unsupported-schema
      (lambda ()
        (commit-book-state! store owner grant generation
                            "midlife-trigger" 0 "must-not-commit")
        '(unexpected-success))
      (lambda (_key observed supported) (list observed supported))))
  (test-equal "midlife schema violation retires the backend" 'failed
    (book-state-store-phase store))
  (test-equal "midlife schema violation revokes its grant" 'revoked
    (book-state-grant-state grant))
  (with-external-database
   root
   (lambda (database)
     (test-equal "midlife trigger rejection changed no value"
       '#(0 0 #f)
       (query-one-for-test
        database
        "SELECT state_version, has_value, text FROM book_instances"))
     (test-equal "midlife trigger rejection persisted no receipt" 0
       (scalar-for-test database "SELECT COUNT(*) FROM commit_receipts"))))
  (close-book-state-store! store))

(let ((root (make-initialized-schema-root "schema-constraint")))
  (with-external-database
   root
   (lambda (database)
     (let ((schema-version (scalar-for-test database "PRAGMA schema_version")))
       (sqlite-exec database "PRAGMA writable_schema = ON")
       (sqlite-exec
        database
        "UPDATE sqlite_schema SET sql = replace(sql, 'CHECK (resulting_state_version = expected_state_version + 1)', 'CHECK (resulting_state_version >= 1)') WHERE type = 'table' AND name = 'commit_receipts'")
       (sqlite-exec
        database
        (format #f "PRAGMA schema_version = ~a" (+ schema-version 1)))
       (sqlite-exec database "PRAGMA writable_schema = OFF"))))
  (test-equal "weakened receipt constraint is rejected at open"
    '(inconsistent 1) (schema-open-result root))
  (with-external-database
   root
   (lambda (database)
     (test-equal "constraint alteration remained present for diagnosis" 0
       (scalar-for-test
        database
        "SELECT instr(sql, 'resulting_state_version = expected_state_version + 1') FROM sqlite_schema WHERE type = 'table' AND name = 'commit_receipts'"))
     (test-equal "constraint rejection created no receipt" 0
       (scalar-for-test database "SELECT COUNT(*) FROM commit_receipts")))))

(let ((root (make-initialized-schema-root "schema-view")))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec
      database
      "CREATE VIEW unexpected_state_view AS SELECT namespace_id FROM book_instances")))
  (test-equal "unexpected persistent view is rejected at open"
    '(inconsistent 1) (schema-open-result root)))

(let ((root (make-initialized-schema-root "schema-table")))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec database "CREATE TABLE unexpected_state_table (value TEXT)")))
  (test-equal "unexpected persistent table is rejected at open"
    '(inconsistent 1) (schema-open-result root)))

(let ((root (make-initialized-schema-root "schema-index")))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec
      database
      "CREATE INDEX unexpected_receipt_text ON commit_receipts(text)")))
  (test-equal "unexpected explicit index is rejected at open"
    '(inconsistent 1) (schema-open-result root)))

(let ((root (make-initialized-schema-root "schema-sqlite-stat")))
  (with-external-database
   root
   (lambda (database) (sqlite-exec database "ANALYZE")))
  (test-equal "unexpected SQLite-generated sqlite_stat1 is not broadly trusted"
    '(inconsistent 1) (schema-open-result root)))

(let ((root (make-initialized-schema-root "schema-metadata-row")))
  (with-external-database
   root
   (lambda (database)
     (sqlite-exec
      database
      "INSERT INTO metadata (key, integer_value) VALUES ('unexpected', 1)")))
  (test-equal "unexpected metadata row is rejected at open"
    '(inconsistent 1) (schema-open-result root)))

(let* ((root (make-test-root "schema"))
       (store (open-book-state-store root))
       (path (string-append root "/book-state-v1.sqlite")))
  (close-book-state-store! store)
  (let ((database (sqlite-open path)))
    (sqlite-exec database "PRAGMA user_version = 2")
    (sqlite-close database))
  (test-equal "newer storage schema fails clearly rather than migrating"
    '(2 1)
    (catch 'book-state-unsupported-schema
      (lambda ()
        (open-book-state-store root)
        '(unexpected-success))
      (lambda (_key observed supported) (list observed supported)))))

(test-end "book-state")

(for-each cleanup-root roots)

(exit (if (and (zero? (test-runner-fail-count runner))
               (zero? (test-runner-xpass-count runner)))
          0
          1))
