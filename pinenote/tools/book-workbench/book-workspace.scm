;;; Durable source storage for one Workbench, separate from per-book state.
;;;
;;; This trusted backend stores bytes; it never reads Scheme forms or executes
;;; source.  The authority owns preview authorization: before seal/activate it
;;; must require a successful preview bound to this store, source digest,
;;; workspace version AND activation generation, and serialize that decision
;;; with its editor operations.  A sealed revision is not proof of a preview.
;;;
;;; Versions start at zero.  Every save increments workspace-version (even an
;;; identical save); every activation/rollback increments activation-generation
;;; (even an already-active target).  Seal does neither and is content-idempotent
;;; after checking the expected workspace version.  Rollback activates previous,
;;; or seed when there is no previous; it never edits the durable draft.  To
;;; recover seed explicitly, activate snapshot's seed-revision with a fresh CAS.
;;; There is no pruning: all 128 revision slots, including seed, are permanent.
;;;
;;; Failures throw (workspace-error CODE [DETAIL ...]); stale CAS includes the
;;; current counter.  Expected errors include stale-workspace-version,
;;; stale-activation-generation, revision-quota-exhausted, unknown-revision,
;;; source-too-large, invalid-source, environment-mismatch and store-busy.
;;; Storage/identity/schema failures require inspection and possibly reopening;
;;; callers must not present them as successful saves or activations.
(define-module (book-workspace)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (sqlite3)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (workspace-storage-schema-version
            workspace-source-format
            workspace-max-source-bytes
            workspace-max-revisions
            workspace-max-export-bytes
            workspace-store?
            open-workspace-store
            close-workspace-store!
            workspace-snapshot
            workspace-save!
            workspace-seal!
            workspace-activate!
            workspace-activate-draft!
            workspace-rollback!
            workspace-revision-source
            workspace-export))

(define workspace-storage-schema-version 1)
(define workspace-source-format "guile-source-v1")
(define workspace-max-source-bytes 8192)
(define workspace-max-revisions 128)
;; JSON escaping costs at most six bytes per source byte; headers fit in 1024.
(define workspace-max-export-bytes (+ (* 6 workspace-max-source-bytes) 1024))
;; The persistent and private-UI contracts share this bound. A last legal
;; expected version must never commit a successor the UI cannot address.
(define max-counter 2147483647)
(define application-id 1463965489)       ; ASCII WBW1
(define database-name "book-workspace-v1.sqlite")
(define page-size 4096)
(define max-pages 2048)                 ; 8 MiB, including SQLite overhead
(define busy-timeout-milliseconds 5000)

(define-record-type <workspace-store>
  (%make-store root root-identity file-identity database mutex environment
               schema phase)
  workspace-store?
  (root store-root)
  (root-identity store-root-identity)
  (file-identity store-file-identity)
  (database store-database set-store-database!)
  (mutex store-mutex)
  (environment store-environment)
  (schema store-schema)
  (phase store-phase set-store-phase!))

(define (reject code . details)
  (apply throw 'workspace-error code details))

(define (byte-length text)
  (bytevector-length (string->utf8 text)))

(define (scalar-character? character)
  (let ((n (char->integer character)))
    (and (> n 0) (<= n #x10ffff) (not (<= #xd800 n #xdfff)))))

(define (own-source source)
  (unless (string? source) (reject 'invalid-source))
  ;; Check character count before copying/encoding an arbitrarily large input.
  (when (> (string-length source) workspace-max-source-bytes)
    (reject 'source-too-large))
  (let ((owned (string-copy source)))
    (unless (string-every scalar-character? owned) (reject 'invalid-source))
    (when (> (byte-length owned) workspace-max-source-bytes)
      (reject 'source-too-large))
    owned))

(define (own-environment environment)
  (unless (and (string? environment)
               (<= 1 (string-length environment) 128)
               (string-every
                (lambda (c)
                  (or (char<=? #\a c #\z) (char<=? #\A c #\Z)
                      (char<=? #\0 c #\9) (memv c '(#\. #\_ #\+ #\-))))
                environment))
    (reject 'invalid-environment))
  (string-copy environment))

(define (own-revision revision)
  (unless (and (string? revision) (= (string-length revision) 64)
               (string-every
                (lambda (c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f)))
                revision))
    (reject 'invalid-revision))
  (string-copy revision))

(define (require-counter value code)
  (unless (and (exact-integer? value) (<= 0 value max-counter)) (reject code)))

(define (source-digest environment source)
  ;; Identity is SHA256(UTF8(domain NUL format NUL environment NUL source)).
  ;; The domain and format are versioned; environment and source reject NUL,
  ;; so field boundaries are unambiguous.  No Unicode/newline normalization.
  (bytevector->base16-string
   (sha256 (string->utf8
            (string-append "wilkbook-workbench-revision-v1" (string #\nul)
                           workspace-source-format (string #\nul)
                           environment (string #\nul) source)))))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments)) #f
          (apply throw 'system-error arguments)))))

(define (same-file? a b)
  (and a b (= (stat:dev a) (stat:dev b)) (= (stat:ino a) (stat:ino b))))

(define (require-private-root path)
  (unless (and (string? path) (string-prefix? "/" path)
               (not (string-any (lambda (c) (char<? c #\space)) path)))
    (reject 'invalid-root))
  (catch 'system-error
    (lambda ()
      (unless (string=? (canonicalize-path path) path) (reject 'invalid-root))
      (let ((info (lstat path)))
        (unless (and (eq? (stat:type info) 'directory)
                     (= (stat:uid info) (getuid))
                     (= (logand (stat:mode info) #o7777) #o700))
          (reject 'invalid-root))
        info))
    (lambda _ (reject 'invalid-root))))

(define (require-private-file path optional?)
  (let ((info (lstat-or-false path)))
    (unless (or (and optional? (not info))
                (and info (eq? (stat:type info) 'regular)
                     (= (stat:uid info) (getuid)) (= (stat:nlink info) 1)
                     (= (logand (stat:mode info) #o7777) #o600)))
      (reject 'invalid-database))
    info))

(define (check-sidecars! path)
  ;; Check before SQLite can open or recover any sidecar, not merely after it
  ;; has removed a journal.  A private caller-owned directory is the trust
  ;; boundary; these checks do not isolate mutually hostile same-UID processes.
  (for-each (lambda (suffix)
              (require-private-file (string-append path suffix) #t))
            '("-journal" "-wal" "-shm")))

(define (create-database-file! path)
  (catch 'system-error
    (lambda ()
      (let ((fd (open-fdes path
                           (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                           #o600)))
        (dynamic-wind
          (lambda () #t)
          (lambda () (chmod fd #o600))
          (lambda () (close-fdes fd)))))
    (lambda arguments
      ;; Another legitimate opener may have created it; validate it below.
      (unless (= EEXIST (system-error-errno arguments))
        (apply throw 'system-error arguments)))))

(define (sync-directory! root)
  (let ((fd (open-fdes root (logior O_RDONLY O_DIRECTORY O_CLOEXEC))))
    (dynamic-wind (lambda () #t) (lambda () (fsync fd))
                  (lambda () (close-fdes fd)))))

(define (check-files! store)
  (unless (same-file? (store-root-identity store)
                      (require-private-root (store-root store)))
    (reject 'invalid-root))
  (let ((path (string-append (store-root store) "/" database-name)))
    (unless (same-file? (store-file-identity store)
                        (require-private-file path #f))
      (reject 'invalid-database))
    (check-sidecars! path)))

(define (with-statement db sql arguments procedure)
  (let ((statement (sqlite-prepare db sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (apply sqlite-bind-arguments statement arguments)
        (procedure statement))
      (lambda () (sqlite-finalize statement)))))

(define (rows db sql . arguments)
  (with-statement db sql arguments
    (lambda (statement) (sqlite-map identity statement))))

(define (one db sql . arguments)
  (let ((result (apply rows db sql arguments)))
    (and (pair? result) (car result))))

(define (scalar db sql . arguments)
  (let ((row (apply one db sql arguments)))
    (and row (vector-ref row 0))))

(define (write-bound! db sql . arguments)
  (with-statement db sql arguments
    (lambda (statement)
      (when (sqlite-step statement) (error "unexpected SQLite write row")))))

(define (schema-objects db)
  (rows db "SELECT type, name, tbl_name, sql FROM main.sqlite_schema ORDER BY type, name, tbl_name, sql"))

(define (schema-layout db)
  ;; Compare actual parsed layout as well as SQL, including every implicit
  ;; index.  The baseline is built from the trusted schema in the same SQLite.
  (list
   (rows db "SELECT schema, name, type, ncol, wr, \"strict\" FROM pragma_table_list WHERE schema = 'main' ORDER BY name")
   (map (lambda (table)
          (list (rows db "SELECT * FROM pragma_table_xinfo(?) ORDER BY cid" table)
                (rows db "SELECT * FROM pragma_foreign_key_list(?) ORDER BY id, seq" table)
                (rows db "SELECT * FROM pragma_index_list(?) ORDER BY seq" table)))
        '("metadata" "revisions" "workspace"))
   (rows db "SELECT * FROM pragma_index_xinfo('sqlite_autoindex_revisions_1') ORDER BY seqno")))

(define (trusted-schema)
  (let ((path (search-path %load-path "schema-workspace-v1.sql")))
    (unless path (reject 'missing-schema))
    (let ((sql (call-with-input-file path get-string-all))
          (db (sqlite-open ":memory:")))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (sqlite-exec db sql)
          (list sql (schema-objects db) (schema-layout db)))
        (lambda () (sqlite-close db))))))

(define (validate-schema! db schema full?)
  (unless (and (= (scalar db "PRAGMA user_version") workspace-storage-schema-version)
               (= (scalar db "PRAGMA application_id") application-id)
               (equal? (schema-objects db) (cadr schema))
               (or (not full?) (equal? (schema-layout db) (caddr schema))))
    (reject 'unsupported-schema)))

(define (configure-connection! db)
  (sqlite-busy-timeout db busy-timeout-milliseconds)
  (sqlite-exec db "PRAGMA foreign_keys = ON; PRAGMA trusted_schema = OFF; PRAGMA temp_store = MEMORY; PRAGMA synchronous = FULL")
  (unless (and (= (scalar db "PRAGMA foreign_keys") 1)
               (= (scalar db "PRAGMA trusted_schema") 0)
               (= (scalar db "PRAGMA temp_store") 2)
               (= (scalar db "PRAGMA synchronous") 2))
    (reject 'pragma-mismatch)))

(define (configure-storage! db)
  (sqlite-exec db "PRAGMA journal_mode = DELETE")
  (unless (and (string-ci=? (scalar db "PRAGMA journal_mode") "delete")
               (= (scalar db "PRAGMA page_size") page-size)
               (= (scalar db "PRAGMA max_page_count = 2048") max-pages))
    (reject 'pragma-mismatch)))

(define (rollback-quietly! db)
  (catch #t (lambda () (sqlite-exec db "ROLLBACK") #t) (lambda _ #f)))

(define (storage-errors thunk)
  (catch 'sqlite-error thunk
    (lambda (_key _who code _message)
      (reject (if (and (integer? code) (memv (logand code 255) '(5 6)))
                  'store-busy 'storage-failure)))))

(define (snapshot db environment)
  (let ((row (one db "SELECT workspace_version, source, source_digest, active_revision, previous_revision, activation_generation FROM workspace WHERE singleton = 1"))
        (seed (scalar db "SELECT seed_revision FROM metadata WHERE singleton = 1")))
    (unless (and row seed
                 (string=? (vector-ref row 2)
                           (source-digest environment (own-source (vector-ref row 1)))))
      (reject 'corrupt-store))
    `((workspace-version . ,(vector-ref row 0))
      (source . ,(vector-ref row 1))
      (source-digest . ,(vector-ref row 2))
      (active-revision . ,(vector-ref row 3))
      (previous-revision . ,(vector-ref row 4))
      (activation-generation . ,(vector-ref row 5))
      (seed-revision . ,seed)
      (source-format . ,(string-copy workspace-source-format))
      (environment . ,(string-copy environment)))))

(define (revision-source db environment revision)
  (let ((source (scalar db "SELECT source FROM revisions WHERE revision_id = ?" revision)))
    (unless source (reject 'unknown-revision))
    (unless (string=? revision (source-digest environment (own-source source)))
      (reject 'corrupt-store))
    source))

(define (validate-data! db environment)
  (let ((meta (one db "SELECT storage_schema_version, source_format, environment FROM metadata WHERE singleton = 1")))
    (unless (and meta (= (scalar db "SELECT count(*) FROM metadata") 1)
                 (= (vector-ref meta 0) workspace-storage-schema-version)
                 (string=? (vector-ref meta 1) workspace-source-format)
                 (= (scalar db "SELECT count(*) FROM workspace") 1)
                 (<= 1 (scalar db "SELECT count(*) FROM revisions") workspace-max-revisions))
      (reject 'corrupt-store))
    (unless (string=? (vector-ref meta 2) environment) (reject 'environment-mismatch)))
  (unless (and (equal? (rows db "PRAGMA quick_check") '(#("ok")))
               (null? (rows db "PRAGMA foreign_key_check")))
    (reject 'corrupt-store))
  (snapshot db environment)
  ;; At most one MiB: verify every retained content address once at open, and
  ;; again when a particular revision is read.  No scan of all sources on save.
  (for-each
   (lambda (row)
     (unless (string=? (vector-ref row 0)
                       (source-digest environment (own-source (vector-ref row 1))))
       (reject 'corrupt-store)))
   (rows db "SELECT revision_id, source FROM revisions")))

(define* (open-workspace-store directory seed-source #:key (environment "guile-3.0-v1"))
  "Open the fixed workspace in caller-owned canonical mode-0700 DIRECTORY.
SEED-SOURCE bootstraps a new/zero-byte store only; reopening never replaces the
original seed or draft.  ENVIRONMENT is a trusted pinned runtime identity and
must match on reopen.  Changing runtime identity requires a separate store."
  (let* ((seed (own-source seed-source))
         (env (own-environment environment))
         (root-info (require-private-root directory))
         (root (string-copy directory))
         (path (string-append root "/" database-name))
         (schema (trusted-schema))
         (db #f))
    (check-sidecars! path)
    (unless (lstat-or-false path) (create-database-file! path))
    (let ((file-info (require-private-file path #f)))
      ;; Bound open-time integrity work before trusting any SQLite contents.
      (when (> (stat:size file-info) (* page-size max-pages))
        (reject 'database-quota-exhausted))
      (storage-errors
       (lambda ()
         (catch #t
           (lambda ()
             ;; SQLITE_OPEN_NOFOLLOW (0x01000000) is not exported by guile-sqlite3.
             (set! db (sqlite-open path (logior SQLITE_OPEN_READWRITE
                                               SQLITE_OPEN_FULLMUTEX
                                               SQLITE_OPEN_PRIVATECACHE #x01000000)))
             (configure-connection! db)
             (when (zero? (stat:size file-info))
               (sqlite-exec db "PRAGMA page_size = 4096"))
             (let ((store (%make-store root root-info file-info db (make-mutex)
                                       env schema 'open)))
               (check-files! store)
               (sqlite-exec db "BEGIN IMMEDIATE")
               (catch #t
                 (lambda ()
                   (let ((empty? (and (zero? (scalar db "PRAGMA user_version"))
                                      (zero? (scalar db "PRAGMA application_id"))
                                      (null? (schema-objects db)))))
                     ;; An existing unrelated SQLite database, even an empty
                     ;; one with a header, is not a workspace awaiting migration.
                     (when empty?
                       (unless (zero? (stat:size file-info)) (reject 'unsupported-schema))
                       (sqlite-exec db (car schema))
                       (let ((id (source-digest env seed)))
                         (write-bound! db "INSERT INTO revisions (revision_id, source) VALUES (?, ?)" id seed)
                         (write-bound! db "INSERT INTO metadata VALUES (1, 1, ?, ?, ?)" workspace-source-format env id)
                         (write-bound! db "INSERT INTO workspace VALUES (1, 0, ?, ?, ?, NULL, 0)" seed id id)))
                     (validate-schema! db schema #t)
                     (validate-data! db env)
                     (sqlite-exec db (if empty? "COMMIT" "ROLLBACK"))
                     (when empty? (sync-directory! root))))
                 (lambda (key . arguments)
                   (rollback-quietly! db)
                   (apply throw key arguments)))
               ;; Delay persistent pragmas until foreign schemas are rejected.
               (configure-storage! db)
               (check-files! store)
               store))
           (lambda (key . arguments)
             (when db (catch #t (lambda () (sqlite-close db)) (lambda _ #f)))
             ;; Retain a failed initialization for diagnosis/recovery.
             (apply throw key arguments))))))))

(define (with-store-lock store thunk)
  (unless (workspace-store? store) (reject 'invalid-store))
  (with-mutex (store-mutex store) (thunk)))

(define (close-workspace-store! store)
  (with-store-lock
   store
   (lambda ()
     (when (store-database store)
       (sqlite-close (store-database store))
       (set-store-database! store #f))
     (set-store-phase! store 'closed)
     #t)))

(define (fail-store! store)
  (set-store-phase! store 'failed)
  (catch #t (lambda () (sqlite-close (store-database store))) (lambda _ #f))
  (set-store-database! store #f))

;; Private deterministic fault injection, like book-state's transaction tests.
(define commit-fault-hook (make-parameter (lambda () #t)))

(define (transact store write? procedure)
  (with-store-lock
   store
   (lambda ()
     (unless (eq? (store-phase store) 'open)
       (reject (if (eq? (store-phase store) 'failed) 'store-failed 'store-closed)))
     (storage-errors
      (lambda ()
        (let ((db (store-database store)) (begun? #f))
          (catch #t
            (lambda ()
              (check-files! store)
              (sqlite-exec db (if write? "BEGIN IMMEDIATE" "BEGIN"))
              (set! begun? #t)
              ;; One transaction binds schema validation, the CAS read and write.
              (validate-schema! db (store-schema store) #f)
              (let ((result (procedure db (store-environment store))))
                (when write? ((commit-fault-hook)))
                (sqlite-exec db (if write? "COMMIT" "ROLLBACK"))
                (set! begun? #f)
                result))
            (lambda (key . arguments)
              (when (or (and begun? (not (rollback-quietly! db)))
                        (and (eq? key 'workspace-error)
                             (memq (car arguments)
                                   '(unsupported-schema corrupt-store invalid-root invalid-database))))
                (fail-store! store))
              (apply throw key arguments)))))))))

(define (workspace-snapshot store)
  (transact store #f snapshot))

(define (check-cas snapshot key expected stale-code)
  (let ((current (assq-ref snapshot key)))
    (unless (= current expected) (reject stale-code current))))

(define (workspace-save! store expected-workspace-version source)
  (require-counter expected-workspace-version 'invalid-workspace-version)
  (let ((owned (own-source source)))
    (transact
     store #t
     (lambda (db env)
       (let ((before (snapshot db env)))
         (check-cas before 'workspace-version expected-workspace-version 'stale-workspace-version)
         (when (= expected-workspace-version max-counter) (reject 'workspace-version-exhausted))
         (write-bound! db "UPDATE workspace SET workspace_version = workspace_version + 1, source = ?, source_digest = ? WHERE singleton = 1"
                       owned (source-digest env owned))
         (snapshot db env))))))

(define (workspace-seal! store expected-workspace-version)
  (require-counter expected-workspace-version 'invalid-workspace-version)
  (transact
   store #t
   (lambda (db env)
     (let* ((current (snapshot db env))
            (id (assq-ref current 'source-digest))
            (source (assq-ref current 'source)))
       (check-cas current 'workspace-version expected-workspace-version 'stale-workspace-version)
       (let ((prior (scalar db "SELECT source FROM revisions WHERE revision_id = ?" id)))
         (cond
          (prior (unless (string=? prior source) (reject 'corrupt-store)))
          ((>= (scalar db "SELECT count(*) FROM revisions") workspace-max-revisions)
           (reject 'revision-quota-exhausted))
          (else (write-bound! db "INSERT INTO revisions (revision_id, source) VALUES (?, ?)" id source))))
       id))))

(define (activate! db env before revision expected-generation)
  (check-cas before 'activation-generation expected-generation 'stale-activation-generation)
  (when (= expected-generation max-counter) (reject 'activation-generation-exhausted))
  (revision-source db env revision)
  (write-bound! db "UPDATE workspace SET previous_revision = CASE WHEN active_revision = ? THEN previous_revision ELSE active_revision END, active_revision = ?, activation_generation = activation_generation + 1 WHERE singleton = 1"
                revision revision)
  (snapshot db env))

(define (workspace-activate! store revision expected-activation-generation)
  (require-counter expected-activation-generation 'invalid-activation-generation)
  (let ((id (own-revision revision)))
    (transact store #t
              (lambda (db env)
                 (activate! db env (snapshot db env) id expected-activation-generation)))))

(define (workspace-activate-draft! store revision expected-workspace-version
                                   expected-activation-generation)
  ;; A preview authorizes the saved draft, not merely an earlier sealed source.
  ;; Another connection may save between seal and activate. Check both counters
  ;; and the exact source identity under the lock that changes the installation.
  (require-counter expected-workspace-version 'invalid-workspace-version)
  (require-counter expected-activation-generation 'invalid-activation-generation)
  (let ((id (own-revision revision)))
    (transact
     store #t
     (lambda (db env)
       (let ((before (snapshot db env)))
         (check-cas before 'workspace-version expected-workspace-version
                    'stale-workspace-version)
         (unless (string=? id (assq-ref before 'source-digest))
           (reject 'draft-revision-mismatch))
         (activate! db env before id expected-activation-generation))))))

(define (workspace-rollback! store expected-activation-generation)
  (require-counter expected-activation-generation 'invalid-activation-generation)
  (transact
   store #t
   (lambda (db env)
     (let ((before (snapshot db env)))
       (activate! db env before
                  (or (assq-ref before 'previous-revision) (assq-ref before 'seed-revision))
                  expected-activation-generation)))))

(define (workspace-revision-source store revision)
  (let ((id (own-revision revision)))
    (transact store #f (lambda (db env) (revision-source db env id)))))

(define (json-string text)
  (call-with-output-string
    (lambda (port)
      (write-char #\" port)
      (string-for-each
       (lambda (c)
         (case c
           ((#\") (display "\\\"" port))
           ((#\\) (display "\\\\" port))
           (else
            (if (< (char->integer c) 32)
                (format port "\\u~4,'0x" (char->integer c))
                (write-char c port)))))
       text)
      (write-char #\" port))))

(define (workspace-export store revision)
  "Return canonical UTF-8 JSON plus LF: format, source-format, environment,
revision, source (in that order).  Strings escape quote, backslash and U+0001
through U+001F; all other scalars are literal.  No paths, timestamps, draft,
activation metadata, preview grants or live/per-book state are exported."
  (let ((id (own-revision revision)))
    (transact
     store #f
     (lambda (db env)
       (let ((artifact
              (string-append
               "{\"format\":\"wilkbook-workbench-export-v1\",\"source-format\":"
               (json-string workspace-source-format) ",\"environment\":"
               (json-string env) ",\"revision\":" (json-string id)
               ",\"source\":" (json-string (revision-source db env id)) "}\n")))
         (when (> (byte-length artifact) workspace-max-export-bytes)
           (reject 'export-too-large))
         artifact)))))
