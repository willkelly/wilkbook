;;; Trusted bridge from one fixed BookInstance to the completion-observing
;;; Book Session host used by the persistent-note reader UI.
(define-module (book-state-reader-bridge)
  #:use-module (book-protocol)
  #:use-module (book-session)
  #:use-module (book-state)
  #:use-module (book-state-backend-adapter)
  #:use-module (book-state-protocol)
  #:use-module (book-state-session-delegate)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (open-reader-state-runtime
            reader-state-runtime?
            close-reader-state-runtime!
            open-reader-book-host!
            open-reader-book-host-for-read-only-observer-test!
            reader-book-host?
            reader-book-session-host
            make-reader-load-owner
            reader-load-owner?
            reader-load-completion->value
            make-reader-pending-save
            reader-pending-save?
            reader-pending-save-ui-generation
            reader-pending-save-text
            reader-save-completion->decision))

(define (bridge-error kind message . details)
  (apply throw 'book-state-reader-bridge-error kind message details))

(define-record-type <reader-state-runtime>
  (%make-reader-state-runtime store phase)
  reader-state-runtime?
  (store runtime-store)
  (phase runtime-phase set-runtime-phase!))

(define-record-type <reader-book-host>
  (%make-reader-book-host runtime session-host)
  reader-book-host?
  (runtime book-host-runtime)
  (session-host reader-book-session-host))

;; UI generation and Book Session generation are deliberately separate fields.
;; A caller must never infer that equal-looking integers have equal authority.
(define-record-type <reader-load-owner>
  (%make-reader-load-owner session-id surface-generation grant-generation)
  reader-load-owner?
  (session-id load-owner-session-id)
  (surface-generation load-owner-surface-generation)
  (grant-generation load-owner-grant-generation))

(define-record-type <reader-pending-save>
  (%make-reader-pending-save ui-generation text expected-state-version
                              session-id surface-handle surface-generation
                              grant-generation request-id action-id sequence
                              operation-id)
  reader-pending-save?
  (ui-generation reader-pending-save-ui-generation)
  (text %reader-pending-save-text)
  (expected-state-version pending-save-expected-state-version)
  (session-id pending-save-session-id)
  (surface-handle pending-save-surface-handle)
  (surface-generation pending-save-surface-generation)
  (grant-generation pending-save-grant-generation)
  (request-id pending-save-request-id)
  (action-id pending-save-action-id)
  (sequence pending-save-sequence)
  (operation-id pending-save-operation-id))

(define (reader-pending-save-text pending)
  (string-copy (%reader-pending-save-text pending)))

(define (require-runtime-open runtime)
  (unless (reader-state-runtime? runtime)
    (bridge-error 'runtime "typed reader state runtime required"))
  (unless (eq? (runtime-phase runtime) 'open)
    (bridge-error 'closed "reader state runtime is closed"))
  (let ((store (runtime-store runtime)))
    (unless (eq? (book-state-store-phase store) 'open)
      (bridge-error 'store "Book State store is not open"))
    store))

(define (open-reader-state-runtime root)
  "Open the accepted durable backend at trusted absolute ROOT."
  (%make-reader-state-runtime (open-book-state-store root) 'open))

(define (backend-result! context result)
  (if (book-state-rejection? result)
      (bridge-error 'backend-rejection context
                    (book-state-rejection-code result)
                    (book-state-rejection-current-state-version result))
      result))

(define (make-instance-factory store namespace backend-access binding-access
                               test-access-mismatch?)
  ;; STORE, NAMESPACE, and both access declarations are captured before any
  ;; endpoint or peer message exists.  Normal production construction requires
  ;; exact access agreement.  The separately named test constructor retains a
  ;; real read-only backend grant while exposing read-write to the protocol FSM,
  ;; solely so the real backend rejection can traverse the typed observer.
  (define (open-binding owner)
    (let ((grant
           (backend-result!
            "could not issue endpoint grant"
            (issue-book-state-grant!
             store namespace owner backend-access))))
      (make-state-endpoint-binding
       owner grant (book-state-grant-handle grant)
       (book-state-grant-generation grant) binding-access)))
  (define (run-operation operation)
    (run-state-backend-operation store operation))
  (define (revoke-binding binding)
    (if test-access-mismatch?
        ;; The accepted adapter intentionally rejects access metadata that does
        ;; not equal the backend grant.  This test-only binding mismatch is
        ;; therefore revoked directly through the accepted backend API.
        (backend-result!
         "could not revoke read-only observer test grant"
         (revoke-book-state-grant!
          store
          (state-endpoint-binding-owner binding)
          (state-endpoint-binding-backend-grant binding)))
        (revoke-state-backend-binding! store binding)))
  (make-book-state-delegate-factory open-binding run-operation revoke-binding))

(define (open-fixed-reader-book-host! runtime book-revision instance-id
                                      backend-access binding-access test?)
  (let* ((store (require-runtime-open runtime))
         (namespace
          (backend-result!
           "could not open trusted BookInstance"
           (open-book-instance! store book-revision instance-id)))
         (factory
          (make-instance-factory store namespace backend-access binding-access
                                 test?)))
    (%make-reader-book-host
     runtime (make-book-session-host-with-state-text-observer factory))))

(define* (open-reader-book-host! runtime book-revision instance-id
                                 #:optional (access 'read-write))
  "Create a completion-observing host for a trusted fixed BookInstance."
  (unless (memq access '(read-only read-write))
    (bridge-error 'access "access must be read-only or read-write"))
  (open-fixed-reader-book-host!
   runtime book-revision instance-id access access #f))

(define (open-reader-book-host-for-read-only-observer-test!
         runtime book-revision instance-id)
  "TEST ONLY: retain a real read-only grant but permit one commit through the
pure FSM so the accepted adapter/backend typed read-only rejection is observed."
  (open-fixed-reader-book-host!
   runtime book-revision instance-id 'read-only 'read-write #t))

(define (close-reader-state-runtime! runtime)
  (unless (reader-state-runtime? runtime)
    (bridge-error 'runtime "typed reader state runtime required"))
  (case (runtime-phase runtime)
    ((closed) 'already-closed)
    ((open)
     (set-runtime-phase! runtime 'closing)
     (close-book-state-store! (runtime-store runtime))
     (set-runtime-phase! runtime 'closed)
     'closed)
    (else (bridge-error 'state "reader state runtime is closing"))))

(define (bounded-owned-string name value maximum empty?)
  (unless (string? value)
    (bridge-error 'schema (string-append name " must be a string")))
  (when (and (not empty?) (string-null? value))
    (bridge-error 'schema (string-append name " must not be empty")))
  (when (> (bytevector-length (string->utf8 value)) maximum)
    (bridge-error 'schema (string-append name " exceeds its byte bound")))
  (string-copy value))

(define (canonical-positive-integer name value maximum)
  (unless (and (integer? value) (exact? value) (<= 1 value maximum))
    (bridge-error 'schema (string-append name " is outside its bound")))
  value)

(define (canonical-nonnegative-integer name value maximum)
  (unless (and (integer? value) (exact? value) (<= 0 value maximum))
    (bridge-error 'schema (string-append name " is outside its bound")))
  value)

(define (action-field action name)
  (let ((entry (and (list? action) (assoc name action))))
    (and entry (cdr entry))))

(define action-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "text"))

(define (exact-action? action)
  (and (list? action)
       (= (length action) (length action-fields))
       (every (lambda (entry)
                (and (pair? entry) (string? (car entry))
                     (member (car entry) action-fields string=?)))
              action)
       (every (lambda (name) (assoc name action)) action-fields)
       (string=? (action-field action "type") "action")))

(define (make-reader-load-owner session-id surface-generation grant-generation)
  (%make-reader-load-owner
   (bounded-owned-string "session_id" session-id max-opaque-id-bytes #f)
   (canonical-positive-integer
    "surface_generation" surface-generation max-surface-generation)
   (canonical-positive-integer
    "grant_generation" grant-generation 1000000)))

(define (completion-owned-by-load? completion owner)
  (and (book-state-completion? completion)
       (reader-load-owner? owner)
       (eq? (book-state-completion-operation-kind completion) 'read)
       (not (book-state-completion-operation-id completion))
       (not (book-state-completion-expected-state-version completion))
       (not (book-state-completion-text completion))
       (string=? (book-state-completion-session-id completion)
                 (load-owner-session-id owner))
       (= (book-state-completion-surface-generation completion)
          (load-owner-surface-generation owner))
       (= (book-state-completion-grant-generation completion)
          (load-owner-grant-generation owner))))

(define (reader-load-completion->value completion owner)
  "Validate one exact typed read observation and return
  (absent VERSION TEXT) or (value VERSION TEXT)."
  (unless (completion-owned-by-load? completion owner)
    (bridge-error 'authority "read completion names another UI lifetime"))
  (let ((response (book-state-completion-response completion)))
    (unless (state-value-message? response)
      (bridge-error 'state "read completion is not a typed state-value"))
    (let ((present? (state-value-message-present? response))
          (version (state-value-message-state-version response))
          (text (state-value-message-text response)))
      (list (if present? 'value 'absent) version (string-copy text)))))

(define (make-reader-pending-save ui-generation submitted-text
                                  expected-state-version load-owner
                                  surface-handle action)
  "Bind one UI submission to the exact trusted host-action result."
  (unless (reader-load-owner? load-owner)
    (bridge-error 'authority "typed load owner required"))
  (unless (exact-action? action)
    (bridge-error 'schema "host action does not have its exact schema"))
  (let ((text
         (bounded-owned-string
           "submitted text" submitted-text max-state-text-bytes #t))
        (action-text (action-field action "text"))
        (action-id (action-field action "action_id"))
        (action-handle (action-field action "surface_handle"))
        (action-generation (action-field action "surface_generation")))
    (unless (and (string? action-text) (string=? text action-text))
      (bridge-error 'authority "host action text differs from UI submission"))
    (unless (and (string? action-id)
                 (member action-id '("save-note" "retry-save-note") string=?))
      (bridge-error 'authority "host action is not a fixed save operation"))
    (unless (and (string? action-handle)
                 (string=? action-handle surface-handle))
      (bridge-error 'authority "host action names another surface handle"))
    (unless (= action-generation (load-owner-surface-generation load-owner))
      (bridge-error 'authority "host action names another surface generation"))
    (%make-reader-pending-save
     (canonical-positive-integer
      "ui_generation" ui-generation max-surface-generation)
     text
     (canonical-nonnegative-integer
       "expected_state_version" expected-state-version max-safe-integer)
     (string-copy (load-owner-session-id load-owner))
     (string-copy surface-handle)
     action-generation
     (load-owner-grant-generation load-owner)
     (bounded-owned-string
      "request_id" (action-field action "request_id") max-opaque-id-bytes #f)
      (string-copy action-id)
      (canonical-positive-integer
       "sequence" (action-field action "sequence") max-sequence)
       ;; The fixed note books derive this book-owned ID from the CSPRNG-backed
       ;; surface handle plus exact action metadata.  Retaining it closes the
       ;; action/sequence-to-receipt join without allowing the UI or outer
       ;; caller to choose an ID, and remains fresh across authority restarts.
       (let ((operation-id
              (format #f "note_~a_s~a_q~a"
                      action-handle action-generation
                      (action-field action "sequence"))))
        (unless (book-state-wire-operation-id? operation-id)
          (bridge-error 'authority "derived operation ID is outside schema"))
        operation-id))))

(define (completion-owned-by-save? completion pending)
  (and (book-state-completion? completion)
       (reader-pending-save? pending)
       (eq? (book-state-completion-operation-kind completion) 'commit)
       (string=? (book-state-completion-session-id completion)
                 (pending-save-session-id pending))
       (= (book-state-completion-surface-generation completion)
          (pending-save-surface-generation pending))
       (= (book-state-completion-grant-generation completion)
          (pending-save-grant-generation pending))
        (= (book-state-completion-expected-state-version completion)
           (pending-save-expected-state-version pending))
        (string=? (book-state-completion-operation-id completion)
                  (pending-save-operation-id pending))
        (string=? (book-state-completion-text completion)
                 (%reader-pending-save-text pending))))

(define (reader-save-completion->decision completion pending)
  "Validate one exact commit observation against one pending UI save.

Return (committed OPERATION-ID VERSION TEXT),
       (conflict OPERATION-ID CURRENT-VERSION TEXT), or
       (failed OPERATION-ID CODE TEXT)."
  (unless (completion-owned-by-save? completion pending)
    (bridge-error 'authority
                  "commit completion does not name the pending UI action"))
  (let* ((operation-id (book-state-completion-operation-id completion))
         (text (book-state-completion-text completion))
         (response (book-state-completion-response completion)))
    (cond
     ((state-committed-message? response)
       (unless (string=? operation-id
                         (state-committed-message-operation-id response))
         (bridge-error 'authority "committed response changed operation ID"))
       (unless (= (state-committed-message-state-version response)
                  (+ (pending-save-expected-state-version pending) 1))
         (bridge-error 'authority "committed response changed state version"))
       (unless (= (state-committed-message-text-bytes response)
                  (bytevector-length (string->utf8 text)))
         (bridge-error 'authority "committed response changed text byte count"))
       (list 'committed operation-id
            (state-committed-message-state-version response) text))
     ((state-conflict-message? response)
      (unless (string=? operation-id
                        (state-conflict-message-operation-id response))
        (bridge-error 'authority "conflict response changed operation ID"))
      (list 'conflict operation-id
            (state-conflict-message-current-state-version response) text))
     ((state-commit-failed-message? response)
      (unless (string=? operation-id
                        (state-commit-failed-message-operation-id response))
        (bridge-error 'authority "failure response changed operation ID"))
      (list 'failed operation-id
            (state-commit-failed-message-code response) text))
     (else (bridge-error 'state "commit completion has no typed commit result")))))
