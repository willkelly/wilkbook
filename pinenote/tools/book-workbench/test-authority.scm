(use-modules (book-workspace) (workbench-authority)
             (rnrs bytevectors) (srfi srfi-64) (srfi srfi-1) (srfi srfi-13)
             (sqlite3))

(define root (getenv "BOOK_WORKBENCH_TEST_ROOT"))
(unless root (error "BOOK_WORKBENCH_TEST_ROOT must be a private test directory"))
(mkdir (string-append root "/authority") #o700)
(define store (open-workspace-store (string-append root "/authority")
                                   "(define (workbench text) text)\n"))
(define runs '())
(define fail-preview? #f)
(define during-preview (lambda () #t))
(define (preview source input)
  (set! runs (cons (list source input) runs))
  (during-preview)
  (if fail-preview? '((status . failed) (diagnostic . "invalid program"))
      `((status . ok) (text . ,(string-append "result: " input)))))
(define authority (make-workbench-authority store preview))
(define (call op . args)
  (workbench-request! authority (cons (cons "op" op) args)))
(define (snap) (workspace-snapshot store))
(define (version) (assoc-ref (snap) 'workspace-version))
(define (epoch) (assoc-ref (snap) 'activation-generation))
(define (active) (assoc-ref (snap) 'active-revision))
(define (preview!) (call "preview" (cons "expected_version" (version))
                        '("text" . "hello")))
(define (activate!) (call "activate" (cons "expected_version" (version))
                         (cons "expected_activation" (epoch))))
(define (saved source)
  (call "save" (cons "expected_version" (version)) (cons "source" source)))
(define (ok? result) (eq? #t (assoc-ref result "ok")))
(define seed (active))

(test-begin "workbench-authority")
(define runner (test-runner-current))
(test-assert "open yields source snapshot" (ok? (call "open")))
(test-assert "activation needs endpoint-local preview" (not (ok? (activate!))))
(test-assert "unknown fields cannot choose paths"
  (not (ok? (call "open" '("path" . "/etc/shadow")))))
(test-assert "duplicate fields reject"
  (not (ok? (call "open" '("op" . "open")))))
(test-assert "inexact version rejects"
  (not (ok? (call "save" '("expected_version" . 1.0) '("source" . "x")))))
(test-equal "invalid requests never execute" '() runs)

(do ((i 0 (+ i 1))) ((= i 7))
  (test-assert "repeated source saves remain usable"
    (ok? (saved (string-append "; successor " (number->string i)
                               "\n(define (workbench text) (string-upcase text))\n")))))
(define changed-source (assoc-ref (snap) 'source))
(test-equal "saving does not activate" seed (active))
(test-assert "preview succeeds" (ok? (preview!)))
(test-equal "preview ran the draft" changed-source (caar runs))
(test-equal "preview leaves active alone" seed (active))
(test-assert "reopening the editor reads its snapshot" (ok? (call "open")))
(test-assert "reopening requires a fresh preview" (not (ok? (activate!))))
(test-assert "preview after reopen succeeds" (ok? (preview!)))
(define foreign (make-workbench-authority store preview))
(test-assert "another endpoint cannot reuse preview authorization"
  (not (ok? (workbench-request! foreign
               `(("op" . "activate") ("expected_version" . ,(version))
                 ("expected_activation" . ,(epoch)))))))
(test-assert "activate exact preview" (ok? (activate!)))
(define successor (active))
(test-assert "successor differs" (not (string=? seed successor)))
(test-assert "activation consumes preview authorization" (not (ok? (activate!))))

(test-assert "installed program can run" (ok? (call "run" '("text" . "input"))))
(test-equal "run selects sealed source" changed-source (caar runs))
(test-assert "an unpreviewed draft saves" (ok? (saved "broken-source")))
(set! fail-preview? #t)
(test-assert "failed preview reports recoverable error" (not (ok? (preview!))))
(test-equal "failed preview retains draft" "broken-source" (assoc-ref (snap) 'source))
(test-equal "failed preview keeps installed revision" successor (active))
(test-assert "failed preview cannot activate" (not (ok? (activate!))))
(set! fail-preview? #f)
(test-assert "run still selects active, not draft" (ok? (call "run" '("text" . "x"))))
(test-equal "active source remained sealed" changed-source (caar runs))

(define stale-epoch (epoch))
(test-assert "rollback works despite broken draft"
  (ok? (call "rollback" (cons "expected_activation" (epoch)))))
(test-equal "rollback recovered seed" seed (active))
(test-equal "rollback preserves draft" "broken-source" (assoc-ref (snap) 'source))
(test-assert "rollback rejects stale activation epoch"
  (not (ok? (call "rollback" (cons "expected_activation" stale-epoch)))))
(test-assert "export succeeds from active revision" (ok? (call "export")))
(test-assert "export omits repeated snapshot"
  (not (assoc "snapshot" (call "export"))))
(test-assert "export excludes unsealed draft"
  (not (string-contains (assoc-ref (call "export") "artifact") "broken-source")))

(saved "(define (workbench text) text)\n; preview race\n")
(set! during-preview
      (lambda () (workspace-save! store (version) "; external writer\n")))
(test-assert "concurrent edit invalidates preview result"
  (not (ok? (preview!))))
(set! during-preview (lambda () #t))
(test-assert "old preview cannot authorize new source" (not (ok? (activate!))))

;; Interleave a real competing write at the boundary between sealing and
;; installation. Checking the draft before sealing is not enough: activation's
;; transaction must still compare it after the immutable revision was created.
(saved "(define (workbench text) text)\n; activation race\n")
(preview!)
(define before-install (snap))
(define seal-variable
  (module-variable (resolve-interface '(book-workspace)) 'workspace-seal!))
(define original-seal (variable-ref seal-variable))
(define raced-install
  (dynamic-wind
    (lambda ()
      (variable-set! seal-variable
        (lambda (target expected)
          (let ((revision (original-seal target expected)))
            (workspace-save! target expected "; competing draft after seal\n")
            revision))))
    activate!
    (lambda () (variable-set! seal-variable original-seal))))
(test-assert "a write between seal and install rejects activation"
  (not (ok? raced-install)))
(test-equal "raced installation leaves active source selected"
  (assoc-ref before-install 'active-revision) (active))
(test-equal "raced installation preserves competing saved source"
  "; competing draft after seal\n" (assoc-ref (snap) 'source))

(define at-quota
  (catch 'workspace-error
    (lambda ()
      (let loop ((i 0))
        (workspace-save! store (version)
                         (string-append "; quota fixture " (number->string i) "\n"))
        (workspace-seal! store (version))
        (loop (+ i 1))))
    (lambda (key code . details) code)))
(test-equal "the real catalog reaches its finite limit"
  'revision-quota-exhausted at-quota)
(define quota-active (active))
(preview!)
(test-equal "quota failure is specific at the UI boundary"
  "revision-quota-exhausted" (assoc-ref (activate!) "error"))
(test-equal "quota failure preserves installation" quota-active (active))
(test-assert "export still works at quota" (ok? (call "export")))
(test-assert "running installed source still works at quota"
  (ok? (call "run" '("text" . "quota"))))
(test-assert "saving a draft still works at quota" (ok? (saved "; retained draft\n")))
(test-assert "rollback still works at quota"
  (ok? (call "rollback" (cons "expected_activation" (epoch)))))

(mkdir (string-append root "/counter-bound") #o700)
(let* ((bounded-store (open-workspace-store (string-append root "/counter-bound") "seed"))
       (bounded-authority (make-workbench-authority bounded-store preview))
       (db ((@@ (book-workspace) store-database) bounded-store))
       (trigger ((@@ (book-workspace) scalar)
                 db "SELECT sql FROM sqlite_schema WHERE name = 'workspace_transition'")))
  ;; Move to the last two values rather than doing billions of saves; restore
  ;; the exact trigger before calling the real authority and transaction code.
  (sqlite-exec db "DROP TRIGGER workspace_transition; UPDATE workspace SET workspace_version = 2147483646, activation_generation = 2147483646")
  (sqlite-exec db trigger)
  (define (request value) (workbench-request! bounded-authority value))
  (let ((last-save (request '(("op" . "save") ("expected_version" . 2147483646)
                             ("source" . "successor")))))
    (test-assert "last representable source save succeeds" (ok? last-save))
    (test-equal "successful save returns a wire-addressable version" 2147483647
      (assoc-ref (assoc-ref last-save "snapshot") "workspace_version")))
  (request '(("op" . "preview") ("expected_version" . 2147483647) ("text" . "boundary")))
  (let ((last-install (request '(("op" . "activate") ("expected_version" . 2147483647)
                                ("expected_activation" . 2147483646)))))
    (test-assert "last representable installation succeeds" (ok? last-install))
    (test-equal "installation returns a wire-addressable epoch" 2147483647
      (assoc-ref (assoc-ref last-install "snapshot") "activation_generation")))
  (let ((before (workspace-snapshot bounded-store)))
    (test-equal "save refuses before exceeding the wire bound" "workspace-version-exhausted"
      (assoc-ref (request '(("op" . "save") ("expected_version" . 2147483647)
                           ("source" . "beyond"))) "error"))
    (test-equal "rollback refuses before exceeding the wire bound" "activation-generation-exhausted"
      (assoc-ref (request '(("op" . "rollback") ("expected_activation" . 2147483647))) "error"))
    (test-equal "wire exhaustion leaves durable state intact" before
      (workspace-snapshot bounded-store)))
  (close-workspace-store! bounded-store))

(define (without-newline bytes)
  (let ((result (make-bytevector (- (bytevector-length bytes) 1))))
    (bytevector-copy! bytes 0 result 0 (bytevector-length result)) result))
(define (rejected? thunk)
  (catch #t (lambda () (thunk) #f) (lambda args #t)))
(define message '(("op" . "save") ("expected_version" . 1)
                  ("source" . "λ\n\"\\")))
(test-equal "Unicode private-control round trip" (list 17 message)
  (decode-workbench-line
   (without-newline (encode-workbench-line "command" 17 message)) "command"))
(for-each
 (lambda (bad)
   (test-assert "malformed private control rejects"
     (rejected? (lambda () (decode-workbench-line (string->utf8 bad) "command")))))
 '("command|01|7b7d" "command|0|7b7d" "reply|1|7b7d"
   "command|1|7B7D" "command|1|f" "command|1|7b7d|extra"
   "command|2147483648|7b7d"
   "command|1|7b226f70223a226f70656e222c226f70223a22636c6f7365227d"))
(test-assert "maximum source survives conservative codec"
  (let* ((source (make-string 8192 #\x01))
         (request `(("op" . "save") ("expected_version" . 1) ("source" . ,source)))
         (line (encode-workbench-line "command" 1 request)))
    (equal? request (cadr (decode-workbench-line (without-newline line) "command")))))

(test-assert "close succeeds" (ok? (call "close")))
(test-assert "closed endpoint cannot run" (not (ok? (call "run" '("text" . "late")))))
(close-workspace-store! store)
(test-end "workbench-authority")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
