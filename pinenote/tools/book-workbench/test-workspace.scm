;;; Host-only durable workspace tests.  All artifacts stay in /tmp/opencode.
(use-modules (book-workspace)
             (gcrypt hash)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (ice-9 threads)
             (json)
             (rnrs bytevectors)
             (sqlite3)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(define db-of (@@ (book-workspace) store-database))
(define scalar (@@ (book-workspace) scalar))
(define write-bound! (@@ (book-workspace) write-bound!))
(define commit-fault-hook (@@ (book-workspace) commit-fault-hook))
(define roots '())
(define stores '())
(define runner (test-runner-simple))
(test-runner-current runner)
(set! test-log-to-file #f)

(define (new-root label)
  (let ((root (mkdtemp (string-append "/tmp/opencode/workspace-" label ".XXXXXX"))))
    (chmod root #o700)
    (set! roots (cons root roots))
    root))

(define (open-test-store root source . options)
  (let ((store (apply open-workspace-store root source options)))
    (set! stores (cons store stores))
    store))

(define (db-path root) (string-append root "/book-workspace-v1.sqlite"))
(define (bytes text) (bytevector-length (string->utf8 text)))
(define (field store name) (assq-ref (workspace-snapshot store) name))
(define (revision-count store) (scalar (db-of store) "SELECT count(*) FROM revisions"))

(define (attempt thunk)
  (catch 'workspace-error thunk (lambda (_key . arguments) arguments)))

(define (throws? key thunk)
  (catch key (lambda () (thunk) #f) (lambda _ #t)))

(define (external-db root procedure)
  (let ((db (sqlite-open (db-path root))))
    (dynamic-wind (lambda () #t) (lambda () (procedure db))
                  (lambda () (sqlite-close db)))))

(define (initialized-root label)
  (let* ((root (new-root label)) (store (open-test-store root "seed")))
    (close-workspace-store! store)
    root))

(define (remove-tree path)
  ;; Never follow aliases created by the identity tests.
  (if (eq? (stat:type (lstat path)) 'directory)
      (begin
        (for-each (lambda (name) (remove-tree (string-append path "/" name)))
                  (scandir path (lambda (name) (not (member name '("." ".."))))))
        (rmdir path))
      (delete-file path)))

(define (race thunk-a thunk-b)
  (let ((gate (make-mutex)) (condition (make-condition-variable))
        (ready 0) (go? #f))
    (define (worker thunk)
      (call-with-new-thread
       (lambda ()
         (with-mutex gate
           (set! ready (+ ready 1))
           (broadcast-condition-variable condition)
           (let wait ()
             (unless go? (wait-condition-variable condition gate) (wait))))
         (attempt thunk))))
    (let ((a (worker thunk-a)) (b (worker thunk-b)))
      (with-mutex gate
        (let wait ()
          (unless (= ready 2) (wait-condition-variable condition gate) (wait)))
        (set! go? #t)
        (broadcast-condition-variable condition))
      (list (join-thread a) (join-thread b)))))

(test-begin "book-workspace")

(let* ((root (new-root "semantics"))
       (store (open-test-store root "seed"))
       (initial (workspace-snapshot store))
       (seed (assq-ref initial 'seed-revision)))
  (test-equal "seed starts active, sealed, with independent zero counters"
    (list 0 "seed" seed seed #f 0 seed "guile-source-v1" "guile-3.0-v1")
    (map cdr initial))
  (test-equal "sealing seed is idempotent" seed (workspace-seal! store 0))
  (test-equal "duplicate seed seal consumes no revision" 1 (revision-count store))
  (test-equal "draft save is durable source, not activation" 1
    (assq-ref (workspace-save! store 0 "source A") 'workspace-version))
  (let ((a (workspace-seal! store 1)))
    (test-equal "seal returns stable content address" a (workspace-seal! store 1))
    (test-equal "seal does not activate" seed (field store 'active-revision))
    (test-equal "save unrelated draft before activation" "unfinished ("
      (assq-ref (workspace-save! store 1 "unfinished (") 'source))
    (let ((before (workspace-snapshot store)))
      (test-equal "stale draft save carries current version" '(stale-workspace-version 2)
        (attempt (lambda () (workspace-save! store 1 "stale write"))))
      (test-equal "stale seal rejects even a previously sealed version"
        '(stale-workspace-version 2) (attempt (lambda () (workspace-seal! store 1))))
      (test-equal "stale operations mutate no snapshot field" before (workspace-snapshot store))
      (test-equal "stale seal inserts nothing" 2 (revision-count store)))
    (let ((activated (workspace-activate! store a 0)))
      (test-equal "activation keeps independent draft and counters"
        (list a seed "unfinished (" 2 1)
        (map (lambda (key) (assq-ref activated key))
             '(active-revision previous-revision source workspace-version activation-generation))))
    (workspace-activate! store seed 1)
    (test-equal "ABA returns to original program with a new activation epoch" 2
      (field store 'activation-generation))
    (let ((before (workspace-snapshot store)))
      (test-equal "pre-ABA activation CAS is stale despite identical active source"
        '(stale-activation-generation 2)
        (attempt (lambda () (workspace-activate! store a 0))))
      (test-equal "stale rollback is atomic" '(stale-activation-generation 2)
        (attempt (lambda () (workspace-rollback! store 1))))
      (test-equal "failed activations change nothing" before (workspace-snapshot store)))
    (workspace-activate! store a 2)
    (test-equal "rollback recovers seed" seed
      (assq-ref (workspace-rollback! store 3) 'active-revision))
    (test-equal "previous revision remains usable after rollback" a
      (assq-ref (workspace-rollback! store 4) 'active-revision))
    (workspace-activate! store seed 5)
    (test-equal "explicit seed recovery preserves unfinished draft" "unfinished ("
      (field store 'source))
    (test-equal "old revision source is immutable after later saves" "source A"
      (workspace-revision-source store a))
    (workspace-activate! store seed 6)
    (test-equal "same-active activation also invalidates earlier CAS" 7
      (field store 'activation-generation))
    (test-equal "same-active activation retains useful previous" a
      (field store 'previous-revision)))
  (let ((expected (workspace-snapshot store)))
    (close-workspace-store! store)
    (test-assert "close is idempotent" (close-workspace-store! store))
    (test-equal "closed handle cannot operate" '(store-closed)
      (attempt (lambda () (workspace-snapshot store))))
    (let ((reopened (open-test-store root "replacement bootstrap ignored")))
      (test-equal "all durable draft and activation fields survive reopen"
        expected (workspace-snapshot reopened))
      (test-equal "original seed survives changed bootstrap input" "seed"
        (workspace-revision-source reopened seed)))))

(let* ((root (new-root "seed-rollback")) (store (open-test-store root "seed")))
  (workspace-save! store 0 "draft which is not active")
  (let ((after (workspace-rollback! store 0)))
    (test-equal "rollback with no history recovers seed and keeps draft"
      (list (assq-ref after 'seed-revision) #f "draft which is not active" 1)
      (map (lambda (key) (assq-ref after key))
           '(active-revision previous-revision source activation-generation)))))

(let* ((root (new-root "bounds")) (store (open-test-store root ""))
       (two-byte (make-string 4096 #\é))
       (four-byte (make-string 2048 (integer->char #x1f642))))
  (test-equal "8192 UTF-8 bytes accepted (4096 characters)" two-byte
    (assq-ref (workspace-save! store 0 two-byte) 'source))
  (test-equal "8193 UTF-8 bytes rejected" '(source-too-large)
    (attempt (lambda () (workspace-save! store 1 (string-append two-byte "!")))))
  (test-equal "8192 UTF-8 bytes accepted (2048 astral characters)" four-byte
    (assq-ref (workspace-save! store 1 four-byte) 'source))
  (test-equal "four-byte overrun is byte-bounded" '(source-too-large)
    (attempt (lambda () (workspace-save! store 2 (string-append four-byte "é")))))
  (for-each
   (lambda (bad)
     (test-equal "NUL and non-string source rejected" '(invalid-source)
       (attempt (lambda () (workspace-save! store 2 bad)))))
   (list #f 123 (string #\nul) (string-append "a" (string #\nul) "b")))
  (for-each
   (lambda (bad)
     (test-equal "invalid counter rejected before SQLite" '(invalid-workspace-version)
       (attempt (lambda () (workspace-save! store bad "")))))
   '(#f -1 1.0 9007199254740992 "2"))
  (test-equal "invalid-source failures did not advance counter" 2
    (field store 'workspace-version))
  (let ((digest (field store 'source-digest)))
    (test-equal "identical save increments version against draft ABA" 3
      (assq-ref (workspace-save! store 2 four-byte) 'workspace-version))
    (test-equal "identical bytes keep content identity" digest (field store 'source-digest)))
  (test-equal "unsealed digest cannot be activated" '(unknown-revision)
    (attempt (lambda () (workspace-activate! store (field store 'source-digest) 0))))
  (test-equal "revision is not a path selector" '(invalid-revision)
    (attempt (lambda () (workspace-revision-source store "../../outside"))))
  (let ((before (workspace-snapshot store)))
    (string-set! (assq-ref before 'source) 0 #\X)
    (string-set! (assq-ref before 'environment) 0 #\X)
    (test-equal "returned strings do not alias authority data" four-byte (field store 'source))
    (test-equal "snapshot environment is a defensive copy" "guile-3.0-v1"
      (field store 'environment))))

(let* ((source "(display \"雪🙂\")\n")
       (root (new-root "identity")) (store (open-test-store root source))
       (id (field store 'source-digest))
       (other (open-test-store (new-root "other-environment") source
                               #:environment "guile-3.0-v2")))
  ;; Independent hashlib vector over the documented byte format, not a call
  ;; back through the backend's private hashing implementation.
  (test-equal "domain/format/environment/UTF-8 identity has a pinned vector"
    "46d958541ab1b0e87fbb9aaf33c0a88f596f3cdbfc419f62877c6b21902b4979" id)
  (test-assert "different pinned environments separate identical source"
    (not (string=? id (field other 'source-digest))))
  (test-equal "reopen cannot silently change pinned environment" '(environment-mismatch)
    (attempt (lambda () (open-test-store root source #:environment "guile-3.0-v2"))))
  (for-each
   (lambda (bad)
     (test-equal "invalid environment is not a namespace/path selector" '(invalid-environment)
       (attempt (lambda () (open-test-store root source #:environment bad)))))
   (list "" "../guile" "space here" "λ" (make-string 129 #\a))))

(let* ((root (new-root "transactions")) (store (open-test-store root "seed"))
       (before (workspace-snapshot store)))
  (define (fail-commit) (throw 'injected-before-commit))
  (test-assert "failure after save write rolls back"
    (throws? 'injected-before-commit
      (lambda () (parameterize ((commit-fault-hook fail-commit))
                   (workspace-save! store 0 "must not persist")))))
  (test-equal "rollback undoes source and digest together" before (workspace-snapshot store))
  (workspace-save! store 0 "sealable")
  (test-assert "failure after inserting revision rolls back"
    (throws? 'injected-before-commit
      (lambda () (parameterize ((commit-fault-hook fail-commit)) (workspace-seal! store 1)))))
  (test-equal "failed seal consumes no quota" 1 (revision-count store))
  (let* ((revision (workspace-seal! store 1)) (saved (workspace-snapshot store)))
    (test-assert "failure after activation write rolls back"
      (throws? 'injected-before-commit
        (lambda () (parameterize ((commit-fault-hook fail-commit))
                     (workspace-activate! store revision 0)))))
    (close-workspace-store! store)
    (test-equal "reopen confirms failed activation has no partial pointers/counter"
      saved (workspace-snapshot (open-test-store root "seed")))))

(let* ((root (new-root "two-connections"))
       (a (open-test-store root "seed")) (b (open-test-store root "seed")))
  (test-equal "two connected writers have exactly one CAS winner and one stale loser" 1
    (count (lambda (result) (equal? result '(stale-workspace-version 1)))
           (race (lambda () (workspace-save! a 0 "writer A"))
                 (lambda () (workspace-save! b 0 "writer B")))))
  (test-equal "two connections observe the same committed snapshot"
    (workspace-snapshot a) (workspace-snapshot b))
  (let ((sealed (race (lambda () (workspace-seal! a 1))
                      (lambda () (workspace-seal! b 1)))))
    (test-assert "contended seal is idempotent"
      (and (string? (car sealed)) (equal? (car sealed) (cadr sealed)))))
  (test-equal "two seals insert one immutable revision" 2 (revision-count a))
  (let ((id (workspace-seal! a 1)))
    (test-equal "contended activation has one winner and one stale loser" 1
      (count (lambda (result) (equal? result '(stale-activation-generation 1)))
             (race (lambda () (workspace-activate! a id 0))
                   (lambda () (workspace-activate! b id 0))))))
  (test-equal "contended rollback also CASes activation epoch" 1
    (count (lambda (result) (equal? result '(stale-activation-generation 2)))
           (race (lambda () (workspace-rollback! a 1))
                 (lambda () (workspace-rollback! b 1)))))
  (let ((before (workspace-snapshot b)))
    (sqlite-exec (db-of a) "BEGIN IMMEDIATE")
    (sqlite-busy-timeout (db-of b) 25)
    (test-equal "busy writer fails explicitly with bounded wait" '(store-busy)
      (attempt (lambda () (workspace-save! b 1 "blocked"))))
    (sqlite-exec (db-of a) "ROLLBACK")
    (test-equal "busy failure mutates no state and leaves handle usable"
      before (workspace-snapshot b))))

(let* ((root (new-root "quota")) (store (open-test-store root "seed"))
       (seed (field store 'seed-revision)))
  ;; Fill every slot with a maximum-size distinct source.  This also checks
  ;; that the SQLite page budget is sufficient for the advertised logical quota.
  (do ((index 1 (+ index 1))) ((= index workspace-max-revisions))
    (let* ((prefix (number->string index))
           (source (string-append prefix
                                  (make-string (- workspace-max-source-bytes
                                                  (string-length prefix)) #\x))))
      (workspace-save! store (- index 1) source)
      (workspace-seal! store index)))
  (test-equal "quota includes permanently retained seed" 128 (revision-count store))
  (workspace-save! store 127 "draft over seal quota")
  (let ((before (workspace-snapshot store)))
    (test-equal "new seal at full quota fails explicitly" '(revision-quota-exhausted)
      (attempt (lambda () (workspace-seal! store 128))))
    (test-equal "quota failure preserves draft, active and counters"
      before (workspace-snapshot store))
    (test-equal "quota failure has no partial revision" 128 (revision-count store))
    (close-workspace-store! store)
    (set! store (open-test-store root "seed"))
    (test-equal "quota failure durability checked by reopen" before (workspace-snapshot store)))
  (workspace-save! store 128 "seed")
  (test-equal "duplicate seal remains possible at full quota" seed (workspace-seal! store 129))
  (test-equal "full quota still permits seed recovery" seed
    (assq-ref (workspace-activate! store seed 0) 'active-revision))
  (test-equal "SQLite enforces quota on bypass insert too" #t
    (throws? 'sqlite-error
      (lambda () (write-bound! (db-of store)
                               "INSERT INTO revisions VALUES (?, ?)"
                               (make-string 64 #\0) "bypass")))))

(let* ((root (new-root "sqlite-full")) (store (open-test-store root "seed"))
       (before (workspace-snapshot store))
       (page-count (scalar (db-of store) "PRAGMA page_count")))
  (sqlite-exec (db-of store) (format #f "PRAGMA max_page_count = ~a" page-count))
  (test-equal "real SQLite exhaustion is a storage failure" '(storage-failure)
    (attempt (lambda () (workspace-save! store 0 (make-string 8192 #\x)))))
  (test-equal "confirmed SQLite rollback leaves the handle's snapshot intact" before
    (workspace-snapshot store))
  (test-equal "fresh connection proves SQLITE_FULL left no partial source/digest"
    before (workspace-snapshot (open-test-store root "seed"))))

(let* ((root (new-root "sql-constraints")) (store (open-test-store root "seed"))
       (db (db-of store))
       (source "'); DROP TABLE revisions; --\n(throw 'must-not-run)"))
  (workspace-save! store 0 source)
  (test-equal "SQL-looking and broken Scheme source is stored only" source
    (workspace-revision-source store (workspace-seal! store 1)))
  (for-each
   (lambda (sql)
     (test-assert "schema enforces immutability and transition constraints"
       (throws? 'sqlite-error (lambda () (sqlite-exec db sql)))))
   '("UPDATE revisions SET source = 'changed'"
     "DELETE FROM revisions"
     "UPDATE metadata SET environment = 'other'"
     "DELETE FROM metadata"
     "DELETE FROM workspace"
     "UPDATE workspace SET workspace_version = workspace_version - 1"
     "UPDATE workspace SET activation_generation = activation_generation + 2"
     "INSERT INTO workspace SELECT 2, workspace_version, source, source_digest, active_revision, previous_revision, activation_generation FROM workspace"
     "UPDATE workspace SET source = 'bad' || char(0), workspace_version = workspace_version + 1"
     "UPDATE workspace SET source_digest = printf('%064d', 0) || char(0), workspace_version = workspace_version + 1"
     "UPDATE workspace SET source = printf('%09000d', 0), workspace_version = workspace_version + 1"))
  (test-equal "FULL synchronous durability is configured" 2 (scalar db "PRAGMA synchronous"))
  (test-equal "DELETE journal is configured" "delete" (scalar db "PRAGMA journal_mode"))
  (test-equal "foreign keys are on" 1 (scalar db "PRAGMA foreign_keys"))
  (test-equal "trusted schema is off" 0 (scalar db "PRAGMA trusted_schema"))
  (test-equal "temporary tables are memory-only" 2 (scalar db "PRAGMA temp_store"))
  (test-equal "physical database growth is bounded" 2048 (scalar db "PRAGMA max_page_count")))

(let* ((root (new-root "counter-exhaustion")) (store (open-test-store root "seed"))
       (db (db-of store)))
  ;; Construct the far-future state without billions of writes.  Restore the
  ;; exact schema before asking the API to operate on it.
  (let ((trigger (scalar db "SELECT sql FROM sqlite_schema WHERE name = 'workspace_transition'")))
     (sqlite-exec db "DROP TRIGGER workspace_transition; UPDATE workspace SET workspace_version = 2147483647, activation_generation = 2147483647")
    (sqlite-exec db trigger))
  (let ((before (workspace-snapshot store)))
    (test-equal "workspace counter never overflows or wraps" '(workspace-version-exhausted)
       (attempt (lambda () (workspace-save! store 2147483647 "no"))))
    (test-equal "activation epoch never overflows or wraps" '(activation-generation-exhausted)
       (attempt (lambda () (workspace-rollback! store 2147483647))))
    (test-equal "counter exhaustion leaves snapshot unchanged" before (workspace-snapshot store))))

;; Fresh header-only SQLite databases and foreign application schemas are both
;; rejected, without adopting or changing their durable content.
(for-each
 (lambda (sql)
   (let ((root (new-root "foreign")))
     (external-db root (lambda (db) (sqlite-exec db sql)))
     (chmod (db-path root) #o600)
     (let ((digest (file-sha256 (db-path root))))
       (test-equal "foreign SQLite database is rejected" '(unsupported-schema)
         (attempt (lambda () (open-test-store root "seed"))))
       (test-assert "rejection leaves foreign database bytes unchanged"
         (bytevector=? digest (file-sha256 (db-path root)))))))
 '("VACUUM"
   "CREATE TABLE foreign_state (note TEXT); INSERT INTO foreign_state VALUES ('keep me'); PRAGMA user_version = 1; PRAGMA application_id = 1463965489"))

(for-each
 (lambda (sql)
   (let ((root (initialized-root "schema")))
     (external-db root (lambda (db) (sqlite-exec db sql)))
     (test-equal "strict version/object/layout verification rejects schema drift"
       '(unsupported-schema) (attempt (lambda () (open-test-store root "seed"))))))
 '("PRAGMA user_version = 2"
   "PRAGMA application_id = 1"
   "CREATE TABLE extra (value TEXT)"
   "CREATE INDEX surprise ON workspace(source)"
   "CREATE VIEW surprise AS SELECT source FROM revisions"
   "CREATE TRIGGER surprise AFTER UPDATE ON workspace BEGIN SELECT 1; END"
   "DROP TRIGGER revisions_no_delete"
   "ALTER TABLE workspace ADD COLUMN extra TEXT"))

(let ((root (initialized-root "corrupt-content")))
  (external-db
   root
   (lambda (db)
     (let ((trigger (scalar db "SELECT sql FROM sqlite_schema WHERE name = 'revisions_no_update'")))
       (sqlite-exec db "DROP TRIGGER revisions_no_update; UPDATE revisions SET source = 'hash mismatch'")
       (sqlite-exec db trigger))))
  (test-equal "valid schema with corrupt content address is rejected at open"
    '(corrupt-store) (attempt (lambda () (open-test-store root "seed")))))

(let* ((root (new-root "live-schema")) (store (open-test-store root "seed")))
  (external-db root (lambda (db) (sqlite-exec db "CREATE TABLE drift (value TEXT)")))
  (test-equal "live handle rechecks schema in transaction" '(unsupported-schema)
    (attempt (lambda () (workspace-save! store 0 "must not commit"))))
  (test-equal "invalidated handle is retired" '(store-failed)
    (attempt (lambda () (workspace-snapshot store))))
  (external-db root (lambda (db)
                      (test-equal "schema rejection made no draft mutation" "seed"
                        (scalar db "SELECT source FROM workspace")))))

(let* ((root (new-root "private-root")) (alias (string-append root "/alias")))
  (chmod root #o755)
  (test-equal "non-private directory is rejected" '(invalid-root)
    (attempt (lambda () (open-test-store root "seed"))))
  (test-assert "root rejection occurs before DB creation" (not (file-exists? (db-path root))))
  (chmod root #o700)
  (symlink root alias)
  (for-each
   (lambda (path)
     (test-equal "noncanonical or invalid root rejected" '(invalid-root)
       (attempt (lambda () (open-test-store path "seed")))))
   (list alias (string-append root "/.") (string-append root "/") #f "relative")))

(for-each
 (lambda (kind)
   (let* ((root (new-root "database-identity"))
          (target (string-append root "/target")) (path (db-path root)))
     (call-with-output-file target (lambda (port) (display "untouched" port)))
     (chmod target #o600)
     (case kind
       ((symlink) (symlink target path))
       ((hardlink) (link target path))
       ((directory) (mkdir path #o700))
       ((fifo) (mknod path 'fifo #o600 0))
       ((permissions) (call-with-output-file path (lambda _ #t)) (chmod path #o644)))
     (test-equal "invalid DB file identity rejected before SQLite" '(invalid-database)
       (attempt (lambda () (open-test-store root "seed"))))
     (test-equal "aliased target was not written" "untouched"
       (call-with-input-file target get-string-all))))
 '(symlink hardlink directory fifo permissions))

(for-each
 (lambda (suffix)
   (for-each
    (lambda (kind)
      (let* ((root (initialized-root "sidecar-identity"))
             (path (string-append (db-path root) suffix))
             (target (string-append root "/target")))
        (call-with-output-file target (lambda (port) (display "untouched" port)))
        (chmod target #o600)
        (case kind
          ((symlink) (symlink target path))
          ((hardlink) (link target path))
          ((permissions) (call-with-output-file path (lambda _ #t)) (chmod path #o644)))
        (test-equal "unsafe journal/WAL/SHM rejected before SQLite recovery"
          '(invalid-database) (attempt (lambda () (open-test-store root "seed"))))
        (test-equal "sidecar target remains unchanged" "untouched"
          (call-with-input-file target get-string-all))))
    '(symlink hardlink permissions)))
 '("-journal" "-wal" "-shm"))

(let* ((root (new-root "inode-replacement")) (store (open-test-store root "seed"))
       (path (db-path root)) (retired (string-append root "/retired.sqlite")))
  (rename-file path retired)
  (call-with-output-file path (lambda _ #t))
  (chmod path #o600)
  (test-equal "open handle rejects database inode replacement" '(invalid-database)
    (attempt (lambda () (workspace-save! store 0 "wrong inode"))))
  (test-equal "inode mismatch retires handle" '(store-failed)
    (attempt (lambda () (workspace-snapshot store)))))

(let* ((root (new-root "live-sidecar")) (store (open-test-store root "seed"))
       (target (string-append root "/target")))
  (call-with-output-file target (lambda (port) (display "untouched" port)))
  (chmod target #o600)
  (symlink target (string-append (db-path root) "-journal"))
  (test-equal "live handle checks sidecar identity before each transaction" '(invalid-database)
    (attempt (lambda () (workspace-save! store 0 "must not write"))))
  (test-equal "live sidecar rejection does not touch target" "untouched"
    (call-with-input-file target get-string-all)))

(let ((root (new-root "oversized-database")))
  (call-with-output-file (db-path root) (lambda (port) (truncate-file port (+ (* 8 1024 1024) 1))))
  (chmod (db-path root) #o600)
  (test-equal "oversized database refused before integrity scan" '(database-quota-exhausted)
    (attempt (lambda () (open-test-store root "seed")))))

(let* ((root (new-root "separate-state"))
       (path (string-append root "/book-state-v1.sqlite")))
  (call-with-output-file path (lambda (port) (display "private per-book state" port)))
  (let ((store (open-test-store root "seed")))
    (workspace-save! store 0 "changed source")
    (workspace-seal! store 1)
    (test-equal "workspace code store never touches book-state v1" "private per-book state"
      (call-with-input-file path get-string-all))))

(let* ((source (string-append "quotes: \" backslash: \\ 雪🙂\n\r\t"
                               (list->string (map integer->char (iota 31 1)))))
       (root (new-root "export")) (store (open-test-store root source))
       (seed (field store 'seed-revision))
       (artifact (workspace-export store seed))
       (decoded (json-string->scm artifact)))
  (test-equal "export has only immutable source metadata"
    '("environment" "format" "revision" "source" "source-format")
    (sort (map car decoded) string<?))
  (test-assert "export fields have deterministic serialized order"
    (apply < (map (lambda (key) (string-contains artifact (string-append "\"" key "\":")))
                  '("format" "source-format" "environment" "revision" "source"))))
  (test-equal "export JSON escaping round-trips every non-NUL control" source
    (assoc-ref decoded "source"))
  (test-assert "export keeps non-ASCII UTF-8 literal" (string-contains artifact "雪🙂"))
  (test-assert "controls use JSON escapes" (string-contains artifact "\\u0001"))
  (workspace-save! store 0 "draft excluded from export")
  (workspace-activate! store (workspace-seal! store 1) 0)
  (test-equal "export is independent of current draft and active program"
    artifact (workspace-export store seed))
  (close-workspace-store! store)
  (test-equal "export deterministic across reopen" artifact
    (workspace-export (open-test-store root "ignored") seed)))

(let* ((root (new-root "export-bound"))
       (source (make-string workspace-max-source-bytes (integer->char 1)))
       (store (open-test-store root source #:environment (make-string 128 #\e)))
       (artifact (workspace-export store (field store 'seed-revision)))
       ;; The authority sends export separately, avoiding a second copy of the
       ;; source in its snapshot.  Outer framing introduces another escape layer.
       (frame (scm->json-string `(("ok" . #t) ("artifact" . ,artifact)) #:unicode #f)))
  (test-assert "worst-case artifact respects byte bound"
    (<= (bytes artifact) workspace-max-export-bytes))
  (test-assert "worst-case JSON-framed artifact fits in 60 KiB"
    (< (bytes frame) (* 60 1024)))
  (test-equal "doubly escaped maximum source round-trips" source
    (assoc-ref (json-string->scm (assoc-ref (json-string->scm frame) "artifact")) "source")))

(test-end "book-workspace")
(for-each close-workspace-store! stores)
(for-each remove-tree roots)
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
