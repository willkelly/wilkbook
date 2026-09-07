;;; Trusted host backend for one bounded durable BookInstance text value.
(define-module (book-state)
  #:use-module (gcrypt random)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (sqlite3)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-9)
  #:export (book-state-storage-schema-version
            book-state-max-text-bytes
            book-state-max-operation-id-bytes
            book-state-operation-id?
            book-state-max-identity-bytes
            book-state-max-namespaces
            book-state-max-live-grants
            book-state-max-grant-generation
            book-state-max-receipts-per-namespace
            book-state-page-size
            book-state-max-database-pages
            book-state-max-database-bytes

            open-book-state-store
            book-state-store?
            book-state-store-phase
            close-book-state-store!

            open-book-instance!
            book-state-namespace?

            issue-book-state-grant!
            book-state-grant?
            book-state-grant-handle
            book-state-grant-generation
            book-state-grant-access
            book-state-grant-state
            revoke-book-state-grant!

            read-book-state
            book-state-absent?
            book-state-absent-state-version
            book-state-value?
            book-state-value-state-version
            book-state-value-text

            commit-book-state!
            book-state-receipt?
            book-state-receipt-operation-id
            book-state-receipt-expected-state-version
            book-state-receipt-state-version
            book-state-receipt-text-bytes

            book-state-rejection?
            book-state-rejection-code
            book-state-rejection-current-state-version))

(define book-state-storage-schema-version 1)
(define book-state-max-text-bytes 4096)
(define book-state-max-operation-id-bytes 128)
(define book-state-max-identity-bytes 256)
(define book-state-max-namespaces 32)
(define book-state-max-live-grants 32)
(define book-state-max-grant-generation 1000000)
(define book-state-max-receipts-per-namespace 64)
(define book-state-page-size 4096)
(define book-state-max-database-pages 4096)
(define book-state-max-database-bytes
  (* book-state-page-size book-state-max-database-pages))
(define book-state-busy-timeout-milliseconds 5000)
(define database-name "book-state-v1.sqlite")
(define known-schema-table-names
  '("metadata" "book_instances" "commit_receipts"))
(define known-schema-index-names
  '("sqlite_autoindex_metadata_1"
    "sqlite_autoindex_book_instances_1"
    "sqlite_autoindex_commit_receipts_1"))

(define-record-type <book-state-store>
  (%make-book-state-store root database mutex phase grants next-generation
                          schema-manifest)
  book-state-store?
  (root %book-state-store-root)
  (database %book-state-store-database set-book-state-store-database!)
  (mutex %book-state-store-mutex)
  (phase book-state-store-phase set-book-state-store-phase!)
  (grants %book-state-store-grants set-book-state-store-grants!)
  (next-generation %book-state-store-next-generation
                   set-book-state-store-next-generation!)
  (schema-manifest %book-state-store-schema-manifest))

(define-record-type <book-state-schema-manifest>
  (%make-book-state-schema-manifest user-version objects metadata-rows
                                    table-list table-columns table-indexes
                                    index-columns foreign-keys)
  book-state-schema-manifest?
  (user-version %schema-manifest-user-version)
  (objects %schema-manifest-objects)
  (metadata-rows %schema-manifest-metadata-rows)
  (table-list %schema-manifest-table-list)
  (table-columns %schema-manifest-table-columns)
  (table-indexes %schema-manifest-table-indexes)
  (index-columns %schema-manifest-index-columns)
  (foreign-keys %schema-manifest-foreign-keys))

(define-record-type <book-state-namespace>
  (%make-book-state-namespace store row-id)
  book-state-namespace?
  (store %book-state-namespace-store)
  (row-id %book-state-namespace-row-id))

(define-record-type <book-state-grant>
  (%make-book-state-grant handle generation owner namespace access state)
  book-state-grant?
  (handle %book-state-grant-handle)
  (generation book-state-grant-generation)
  (owner %book-state-grant-owner)
  (namespace %book-state-grant-namespace)
  (access book-state-grant-access)
  (state book-state-grant-state set-book-state-grant-state!))

(define-record-type <book-state-absent>
  (%make-book-state-absent state-version)
  book-state-absent?
  (state-version book-state-absent-state-version))

(define-record-type <book-state-value>
  (%make-book-state-value state-version text)
  book-state-value?
  (state-version book-state-value-state-version)
  (text %book-state-value-text))

(define-record-type <book-state-receipt>
  (%make-book-state-receipt operation-id expected-state-version state-version
                            text-bytes)
  book-state-receipt?
  (operation-id %book-state-receipt-operation-id)
  (expected-state-version book-state-receipt-expected-state-version)
  (state-version book-state-receipt-state-version)
  (text-bytes book-state-receipt-text-bytes))

(define-record-type <book-state-rejection>
  (%make-book-state-rejection code current-state-version)
  book-state-rejection?
  (code book-state-rejection-code)
  (current-state-version book-state-rejection-current-state-version))

(define (book-state-grant-handle grant)
  (string-copy (%book-state-grant-handle grant)))

(define (book-state-value-text value)
  (string-copy (%book-state-value-text value)))

(define (book-state-receipt-operation-id receipt)
  (string-copy (%book-state-receipt-operation-id receipt)))

(define (reject code . current-version)
  (%make-book-state-rejection code
                              (if (null? current-version)
                                  #f
                                  (car current-version))))

(define (byte-length value)
  (bytevector-length (string->utf8 value)))

(define (trusted-identity? value)
  (and (string? value)
       (not (string-null? value))
       (<= (byte-length value) book-state-max-identity-bytes)
       (string-every (lambda (character)
                       (and (not (char=? character #\nul))
                            (or (char>=? character #\space)
                                (char=? character #\tab))))
                     value)))

(define (ascii-operation-id-character? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (and (char>=? character #\0) (char<=? character #\9))
      (memv character '(#\_ #\-))))

(define (book-state-operation-id? value)
  (and (string? value)
       (not (string-null? value))
       (<= (byte-length value) book-state-max-operation-id-bytes)
       (string-every ascii-operation-id-character? value)))

(define (database-path root)
  (string-append root "/" database-name))

(define (require-private-root path)
  (unless (and (string? path)
               (string-prefix? "/" path)
               (not (string-index path #\nul))
               (not (string-index path #\newline))
               (not (string-index path #\return)))
    (throw 'book-state-open-error 'invalid-root
           "state root must be an absolute path without controls"))
  (let ((canonical
         (catch 'system-error
           (lambda () (canonicalize-path path))
           (lambda _
             (throw 'book-state-open-error 'invalid-root
                    "state root does not exist")))))
    (unless (string=? canonical path)
      (throw 'book-state-open-error 'invalid-root
             "state root must not contain symlinks or aliases"))
    (let ((info (lstat canonical)))
      (unless (and (eq? (stat:type info) 'directory)
                   (= (stat:uid info) (getuid))
                   (= (logand (stat:mode info) #o7777) #o700))
        (throw 'book-state-open-error 'invalid-root
               "state root must be caller-owned mode 0700")))
    canonical))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (require-private-database-file path)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (= (logand (stat:mode info) #o7777) #o600))
      (throw 'book-state-open-error 'invalid-database
             "state database must be caller-owned mode 0600 and single-linked"))
    info))

(define (create-empty-private-file path)
  (let ((descriptor
         (open-fdes path (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC) #o600)))
    (close-fdes descriptor))
  (chmod path #o600))

(define (with-statement database sql arguments procedure)
  (let ((statement (sqlite-prepare database sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (apply sqlite-bind-arguments statement arguments)
        (procedure statement))
      (lambda () (sqlite-finalize statement)))))

(define (query-rows database sql . arguments)
  (with-statement database sql arguments
    (lambda (statement) (sqlite-map identity statement))))

(define (query-one database sql . arguments)
  (let ((rows (apply query-rows database sql arguments)))
    (and (pair? rows) (car rows))))

(define (execute-bound database sql . arguments)
  (with-statement database sql arguments
    (lambda (statement)
      (let ((row (sqlite-step statement)))
        (when row
          (error "write statement unexpectedly returned a row" sql))))))

(define (scalar database sql . arguments)
  (let ((row (apply query-one database sql arguments)))
    (and row (= (vector-length row) 1) (vector-ref row 0))))

(define (pragma-integer database name)
  (scalar database (string-append "PRAGMA " name)))

(define (pragma-string database name)
  (scalar database (string-append "PRAGMA " name)))

(define (schema-file)
  (or (search-path %load-path "schema-v1.sql")
      (throw 'book-state-open-error 'missing-schema
             "schema-v1.sql is absent from the trusted module load path")))

(define (schema-sql)
  (call-with-input-file (schema-file) get-string-all))

(define (query-layout database sql . arguments)
  (map vector->list (apply query-rows database sql arguments)))

(define (schema-object-inventory database)
  ;; Inventory every persistent object, including the exact known
  ;; sqlite_autoindex_* rows.  There is deliberately no sqlite_* exclusion.
  (query-layout
   database
   "SELECT type, name, tbl_name, sql FROM main.sqlite_schema ORDER BY type, name, tbl_name, sql"))

(define (table-layout database table-name)
  (query-layout
   database
   "SELECT cid, name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?) ORDER BY cid"
   table-name))

(define (table-index-layout database table-name)
  (query-layout
   database
   "SELECT seq, name, \"unique\", origin, partial FROM pragma_index_list(?) ORDER BY seq, name"
   table-name))

(define (index-column-layout database index-name)
  (query-layout
   database
   "SELECT seqno, cid, name, \"desc\", coll, key FROM pragma_index_xinfo(?) ORDER BY seqno"
   index-name))

(define (foreign-key-layout database table-name)
  (query-layout
   database
   "SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete, match FROM pragma_foreign_key_list(?) ORDER BY id, seq"
   table-name))

(define (capture-schema-manifest database)
  (%make-book-state-schema-manifest
   (pragma-integer database "user_version")
   (schema-object-inventory database)
   (query-layout
    database
    "SELECT key, integer_value FROM metadata ORDER BY key, integer_value")
   (query-layout
    database
    "SELECT schema, name, type, ncol, wr, \"strict\" FROM pragma_table_list WHERE schema = 'main' ORDER BY name, type")
   (map (lambda (name) (cons name (table-layout database name)))
        known-schema-table-names)
   (map (lambda (name) (cons name (table-index-layout database name)))
        known-schema-table-names)
   (map (lambda (name) (cons name (index-column-layout database name)))
        known-schema-index-names)
   (map (lambda (name) (cons name (foreign-key-layout database name)))
        known-schema-table-names)))

(define (schema-manifest=? left right)
  (and (= (%schema-manifest-user-version left)
          (%schema-manifest-user-version right))
       (equal? (%schema-manifest-objects left)
               (%schema-manifest-objects right))
       (equal? (%schema-manifest-metadata-rows left)
               (%schema-manifest-metadata-rows right))
       (equal? (%schema-manifest-table-list left)
               (%schema-manifest-table-list right))
       (equal? (%schema-manifest-table-columns left)
               (%schema-manifest-table-columns right))
       (equal? (%schema-manifest-table-indexes left)
               (%schema-manifest-table-indexes right))
       (equal? (%schema-manifest-index-columns left)
               (%schema-manifest-index-columns right))
       (equal? (%schema-manifest-foreign-keys left)
               (%schema-manifest-foreign-keys right))))

(define (make-known-schema-manifest sql)
  (let ((database (sqlite-open ":memory:")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (sqlite-exec database sql)
        (capture-schema-manifest database))
      (lambda () (sqlite-close database)))))

(define (throw-inconsistent-schema)
  (throw 'book-state-unsupported-schema 'inconsistent
         book-state-storage-schema-version))

(define (validate-known-schema! database expected)
  (let ((version (pragma-integer database "user_version")))
    (unless (= version book-state-storage-schema-version)
      (throw 'book-state-unsupported-schema version
             book-state-storage-schema-version)))
  (catch 'sqlite-error
    (lambda ()
      ;; Compare canonical sqlite_schema bytes first.  This rejects altered
      ;; constraints and every trigger, view, table, or index not emitted by
      ;; schema-v1.sql before querying an application table.
      (unless (equal? (schema-object-inventory database)
                      (%schema-manifest-objects expected))
        (throw-inconsistent-schema))
      (unless (schema-manifest=? (capture-schema-manifest database) expected)
        (throw-inconsistent-schema)))
    (lambda _ (throw-inconsistent-schema))))

(define (database-schema-empty? database)
  (and (= (pragma-integer database "user_version") 0)
       (null? (schema-object-inventory database))))

(define (validate-or-initialize-schema! database sql expected)
  (sqlite-exec database "BEGIN IMMEDIATE")
  (catch #t
    (lambda ()
      (let ((initialize? (database-schema-empty? database)))
        (when initialize? (sqlite-exec database sql))
        (validate-known-schema! database expected)
        (unless (string=? (or (pragma-string database "quick_check") "")
                         "ok")
          (throw 'book-state-open-error 'integrity-check-failed
                 "SQLite quick_check did not return ok"))
        (sqlite-exec database (if initialize? "COMMIT" "ROLLBACK"))))
    (lambda (key . arguments)
      (catch #t
        (lambda () (sqlite-exec database "ROLLBACK"))
        (lambda _ #f))
      (apply throw key arguments))))

(define (set-and-verify-pragmas! database)
  (sqlite-busy-timeout database book-state-busy-timeout-milliseconds)
  (sqlite-exec database
               (format #f "PRAGMA page_size = ~a" book-state-page-size))
  (sqlite-exec database "PRAGMA foreign_keys = ON")
  (sqlite-exec database "PRAGMA trusted_schema = OFF")
  (sqlite-exec database "PRAGMA temp_store = MEMORY")
  (sqlite-exec database "PRAGMA synchronous = FULL")
  (sqlite-exec database "PRAGMA journal_mode = DELETE")
  (sqlite-exec database
               (format #f "PRAGMA max_page_count = ~a"
                       book-state-max-database-pages))
  (unless (and (= (pragma-integer database "foreign_keys") 1)
               (= (pragma-integer database "trusted_schema") 0)
               (= (pragma-integer database "temp_store") 2)
               (= (pragma-integer database "synchronous") 2)
               (string-ci=? (pragma-string database "journal_mode") "delete")
               (= (pragma-integer database "page_size") book-state-page-size)
               (= (pragma-integer database "max_page_count")
                  book-state-max-database-pages))
    (throw 'book-state-open-error 'pragma-mismatch
           "SQLite durability or quota pragmas did not hold")))

(define (check-database! database sql expected)
  (set-and-verify-pragmas! database)
  (validate-or-initialize-schema! database sql expected)
  (set-and-verify-pragmas! database))

(define (open-book-state-store root)
  (let* ((trusted-root (require-private-root root))
         (path (database-path trusted-root))
         (before (lstat-or-false path))
         (sql (schema-sql))
         (expected (make-known-schema-manifest sql))
         (database #f))
    (when before (require-private-database-file path))
    (unless before (create-empty-private-file path))
    (catch #t
      (lambda ()
        (set! database
              (sqlite-open
               path
               (logior SQLITE_OPEN_READWRITE SQLITE_OPEN_CREATE
                       SQLITE_OPEN_FULLMUTEX SQLITE_OPEN_PRIVATECACHE)))
        (check-database! database sql expected)
        (require-private-database-file path)
        (%make-book-state-store trusted-root database (make-mutex) 'open '() 1
                                expected))
      (lambda (key . arguments)
        (when database
          (catch #t (lambda () (sqlite-close database)) (lambda _ #f)))
        ;; Keep a newly created failed database for diagnosis; never silently
        ;; unlink storage after initialization or schema failure.
        (apply throw key arguments)))))

(define (call-with-store-lock store procedure)
  (unless (book-state-store? store)
    (error "expected a book state store" store))
  (let ((mutex (%book-state-store-mutex store)))
    (lock-mutex mutex)
    (dynamic-wind
      (lambda () #t)
      procedure
      (lambda () (unlock-mutex mutex)))))

(define (close-book-state-store! store)
  (call-with-store-lock
   store
   (lambda ()
     (case (book-state-store-phase store)
       ((closed failed) #t)
       ((closing) #t)
       ((open)
        (set-book-state-store-phase! store 'closing)
        (for-each (lambda (grant) (set-book-state-grant-state! grant 'revoked))
                  (%book-state-store-grants store))
        (set-book-state-store-grants! store '())
        (let ((database (%book-state-store-database store)))
          (catch #t
            (lambda ()
              (when database (sqlite-close database))
              (set-book-state-store-database! store #f)
              (set-book-state-store-phase! store 'closed))
            (lambda (key . arguments)
              (set-book-state-store-phase! store 'failed)
              (apply throw key arguments)))))
       (else
        (set-book-state-store-phase! store 'failed))))))

(define (store-open? store)
  (eq? (book-state-store-phase store) 'open))

(define (store-phase-rejection store)
  (if (eq? (book-state-store-phase store) 'failed)
      (reject 'store-failed)
      (reject 'store-closed)))

(define (fail-store! store database)
  (set-book-state-store-phase! store 'failed)
  (for-each (lambda (grant) (set-book-state-grant-state! grant 'revoked))
            (%book-state-store-grants store))
  (set-book-state-store-grants! store '())
  (catch #t
    (lambda () (sqlite-close database))
    (lambda _ #f))
  (set-book-state-store-database! store #f))

(define (rollback-quietly! database)
  (catch #t
    (lambda () (sqlite-exec database "ROLLBACK") #t)
    (lambda _ #f)))

(define commit-fault-hook (make-parameter (lambda (_point) #t)))

(define (call-with-write-transaction store procedure)
  (let ((database (%book-state-store-database store)))
    (sqlite-exec database "BEGIN IMMEDIATE")
    (catch #t
      (lambda ()
        ;; BEGIN IMMEDIATE gives this exact schema inventory and the following
        ;; write one snapshot while preventing another connection from adding
        ;; DDL before COMMIT.
        (validate-known-schema!
         database (%book-state-store-schema-manifest store))
        (let ((decision (procedure database)))
          (case (car decision)
            ((commit)
             ((commit-fault-hook) 'before-commit)
             (sqlite-exec database "COMMIT")
             ((commit-fault-hook) 'after-commit-before-ack)
             (cdr decision))
            ((rollback)
             (sqlite-exec database "ROLLBACK")
             (cdr decision))
            (else
             (error "invalid book state transaction decision" decision)))))
      (lambda (key . arguments)
        (let ((rolled-back? (rollback-quietly! database)))
          (when (or (not rolled-back?)
                    (eq? key 'book-state-unsupported-schema))
            ;; An ambiguous rollback or a database that stopped matching its
            ;; claimed application schema retires this worker and every grant.
            (fail-store! store database)))
        (apply throw key arguments)))))

(define (storage-rejection current-version thunk)
  (catch 'sqlite-error
    thunk
    (lambda _ (reject 'storage-failure current-version))))

(define (open-book-instance! store book-revision instance-id)
  (if (not (and (trusted-identity? book-revision)
                (trusted-identity? instance-id)))
      (reject 'invalid-trusted-identity)
      (call-with-store-lock
       store
       (lambda ()
         (cond
          ((not (store-open? store)) (store-phase-rejection store))
          (else
           (storage-rejection
            #f
            (lambda ()
              (call-with-write-transaction
               store
               (lambda (database)
                 (let ((existing
                        (query-one
                         database
                         "SELECT namespace_id, storage_schema_version FROM book_instances WHERE book_revision = ? AND instance_id = ?"
                         book-revision instance-id)))
                   (cond
                    (existing
                     (cons
                      'rollback
                      (if (= (vector-ref existing 1)
                             book-state-storage-schema-version)
                          (%make-book-state-namespace
                           store (vector-ref existing 0))
                          (reject 'unsupported-namespace-schema))))
                    ((>= (scalar database
                                 "SELECT COUNT(*) FROM book_instances")
                         book-state-max-namespaces)
                     (cons 'rollback (reject 'namespace-quota-exhausted)))
                    (else
                     (execute-bound
                      database
                      "INSERT INTO book_instances (book_revision, instance_id, storage_schema_version) VALUES (?, ?, ?)"
                      book-revision instance-id
                      book-state-storage-schema-version)
                     (let ((row
                            (query-one
                             database
                             "SELECT namespace_id FROM book_instances WHERE book_revision = ? AND instance_id = ?"
                             book-revision instance-id)))
                       (cons 'commit
                             (%make-book-state-namespace
                              store (vector-ref row 0)))))))))))))))))

(define (valid-namespace? store namespace)
  (and (book-state-namespace? namespace)
       (eq? (%book-state-namespace-store namespace) store)))

(define (fresh-grant-handle store)
  (let retry ((attempts 8))
    (if (zero? attempts)
        #f
        (let ((candidate (string-append "state_" (random-token 18 'strong))))
          (if (any (lambda (grant)
                     (string=? candidate (%book-state-grant-handle grant)))
                   (%book-state-store-grants store))
              (retry (- attempts 1))
              candidate)))))

(define (issue-book-state-grant! store namespace owner access)
  (call-with-store-lock
   store
   (lambda ()
     (cond
      ((not (store-open? store)) (store-phase-rejection store))
      ((not (valid-namespace? store namespace)) (reject 'invalid-namespace))
      ((not (memq access '(read-only read-write))) (reject 'invalid-access))
      ((>= (length (%book-state-store-grants store))
           book-state-max-live-grants)
       (reject 'grant-quota-exhausted))
      ((> (%book-state-store-next-generation store)
          book-state-max-grant-generation)
       (reject 'grant-generation-exhausted))
      (else
       (let ((handle (fresh-grant-handle store)))
         (if (not handle)
             (reject 'grant-handle-exhausted)
             (let* ((generation (%book-state-store-next-generation store))
                    (grant
                     (%make-book-state-grant
                      handle generation owner namespace access 'active)))
               (set-book-state-store-next-generation! store (+ generation 1))
               (set-book-state-store-grants!
                store (cons grant (%book-state-store-grants store)))
               grant))))))))

(define (grant-rejection store owner grant generation write?)
  (cond
   ((not (store-open? store)) (store-phase-rejection store))
   ((or (not (book-state-grant? grant))
        (not (valid-namespace? store (%book-state-grant-namespace grant))))
    (reject 'invalid-grant))
   ((not (eq? owner (%book-state-grant-owner grant)))
    (reject 'owner-mismatch))
   ((not (and (integer? generation) (exact? generation)
              (= generation (book-state-grant-generation grant))))
    (reject 'stale-generation))
   ((not (eq? (book-state-grant-state grant) 'active))
    (reject 'revoked))
   ((and write? (not (eq? (book-state-grant-access grant) 'read-write)))
    (reject 'read-only))
   (else #f)))

(define (revoke-book-state-grant! store owner grant)
  (call-with-store-lock
   store
   (lambda ()
     (cond
      ((not (store-open? store)) (store-phase-rejection store))
      ((or (not (book-state-grant? grant))
           (not (valid-namespace? store (%book-state-grant-namespace grant))))
       (reject 'invalid-grant))
      ((not (eq? owner (%book-state-grant-owner grant)))
       (reject 'owner-mismatch))
      ((eq? (book-state-grant-state grant) 'revoked) 'already-revoked)
      (else
       (set-book-state-grant-state! grant 'revoked)
       (set-book-state-store-grants!
        store (delq grant (%book-state-store-grants store)))
       'revoked)))))

(define (read-current-row database namespace)
  (query-one
   database
   "SELECT state_version, has_value, text FROM book_instances WHERE namespace_id = ?"
   (%book-state-namespace-row-id namespace)))

(define (read-book-state store owner grant generation)
  (call-with-store-lock
   store
   (lambda ()
     (let ((rejection (grant-rejection store owner grant generation #f)))
       (if rejection
           rejection
           (storage-rejection
            #f
            (lambda ()
              (let ((row
                     (read-current-row
                      (%book-state-store-database store)
                      (%book-state-grant-namespace grant))))
                (cond
                 ((not row) (reject 'invalid-namespace))
                 ((zero? (vector-ref row 1))
                  (%make-book-state-absent (vector-ref row 0)))
                 (else
                  (%make-book-state-value (vector-ref row 0)
                                          (string-copy (vector-ref row 2)))))))))))))

(define (operation-row database namespace operation-id)
  (query-one
   database
   "SELECT expected_state_version, text, text_bytes, resulting_state_version FROM commit_receipts WHERE namespace_id = ? AND operation_id = ?"
   (%book-state-namespace-row-id namespace) operation-id))

(define (receipt operation-id expected-version state-version text-bytes)
  (%make-book-state-receipt (string-copy operation-id) expected-version
                            state-version text-bytes))

(define (commit-book-state! store owner grant generation operation-id
                            expected-version text)
  (cond
   ((not (book-state-operation-id? operation-id))
    (reject 'invalid-operation-id))
   ((not (and (integer? expected-version) (exact? expected-version)
              (>= expected-version 0)
              (<= expected-version
                  book-state-max-receipts-per-namespace)))
    (reject 'invalid-expected-version))
   ((not (string? text)) (reject 'invalid-text))
   ((> (byte-length text) book-state-max-text-bytes)
    (reject 'text-too-large))
   (else
    (let ((owned-operation-id (string-copy operation-id))
          (owned-text (string-copy text))
          (text-bytes (byte-length text)))
      (call-with-store-lock
       store
       (lambda ()
         (let ((grant-error
                (grant-rejection store owner grant generation #t)))
           (if grant-error
               grant-error
               (let ((namespace (%book-state-grant-namespace grant)))
                 (storage-rejection
                  #f
                  (lambda ()
                    (call-with-write-transaction
                     store
                     (lambda (database)
                       ;; The current version is read only after BEGIN IMMEDIATE;
                       ;; compare-and-swap never borrows a pre-transaction value.
                       (let* ((current-row
                               (read-current-row database namespace))
                              (current-version
                               (and current-row (vector-ref current-row 0)))
                              (prior
                               (and current-row
                                    (operation-row database namespace
                                                   owned-operation-id))))
                         (cond
                          ((not current-row)
                           (cons 'rollback (reject 'invalid-namespace)))
                          (prior
                           (if (and (= (vector-ref prior 0)
                                       expected-version)
                                    (string=? (vector-ref prior 1) owned-text)
                                    (= (vector-ref prior 2) text-bytes))
                               (cons
                                'rollback
                                (receipt owned-operation-id
                                         (vector-ref prior 0)
                                         (vector-ref prior 3)
                                         (vector-ref prior 2)))
                               (cons 'rollback
                                     (reject 'operation-conflict
                                             current-version))))
                          ((not (= expected-version current-version))
                           (cons 'rollback
                                 (reject 'stale-version current-version)))
                          ((>= (scalar
                                database
                                "SELECT COUNT(*) FROM commit_receipts WHERE namespace_id = ?"
                                (%book-state-namespace-row-id namespace))
                               book-state-max-receipts-per-namespace)
                           (cons 'rollback
                                 (reject 'receipt-quota-exhausted
                                         current-version)))
                          (else
                           (let ((next-version (+ current-version 1)))
                             (execute-bound
                              database
                              "UPDATE book_instances SET state_version = ?, has_value = 1, text = ? WHERE namespace_id = ?"
                              next-version owned-text
                              (%book-state-namespace-row-id namespace))
                             (execute-bound
                              database
                              "INSERT INTO commit_receipts (namespace_id, operation_id, expected_state_version, text, text_bytes, resulting_state_version) VALUES (?, ?, ?, ?, ?, ?)"
                              (%book-state-namespace-row-id namespace)
                              owned-operation-id expected-version owned-text
                              text-bytes next-version)
                             (cons 'commit
                                   (receipt owned-operation-id
                                            expected-version next-version
                                            text-bytes)))))))))))))))))))
