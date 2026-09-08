;;; QEMU-only trusted guest authority for the two-boot persistent-note proof.
;;;
;;; The accepted guest Book Protocol adapter owns runsc/cgroup/diagnostic
;;; cleanup.  The frozen reader-join v2 bridge owns all Book State and UI
;;; correlation.  This successor supplies only fixed guest orchestration:
;;; two compile-fixed language identities, one mandatory ext4 root, and the
;;; accepted private virtio channel.  Books receive only their connected FD 3.
;;; Its clocks are cooperative; the mandatory outer QEMU owner is the only hard
;;; containment boundary for a blocked storage/revoke/join callback.
(define-module (book-state-guest-authority)
  #:use-module (book-protocol)
  #:use-module (book-session)
  #:use-module (book-state)
  #:use-module (book-state-protocol)
  #:use-module (book-state-reader-bridge)
  #:use-module (book-state-session-delegate)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (guest-virtio-book-ui)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module (sqlite3)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (book-state-guest-main
            classify-loaded-state
            validate-storage-root!
            inspect-closed-database!))

(define cooperative-run-budget-seconds 300.0)
(define operation-timeout-seconds 3.0)
(define ui-phase-timeout-seconds 25.0)
(define scheduler-sleep-microseconds 5000)
(define child-stop-poll-microseconds 5000)
(define child-best-effort-reap-seconds 1.0)
(define state-root "/var/lib/wilkbook-book-state-demo")
(define state-database
  "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite")
(define expected-mount-options '("noatime" "nodev" "nosuid" "noexec"))
(define expected-reader-join-manifest
  "6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0")
(define expected-language-closure
  "48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc")
(define expected-guile-sqlite3-output
  "/gnu/store/0c81pri4sf9sm16578hjp7di823l5m7y-guile-sqlite3-0.1.3")
(define expected-sqlite-output
  "/gnu/store/jcrkzfnla7pg7g07v7xsv58hwgzlin8x-sqlite-3.53.1")

(define fixed-profiles
  `((guile
     (label . "guile")
     (book-revision . "reader-note/guile@1")
     (instance-id . "persistent-note-guile")
     (container-id . "wilkbook-guile-book-state")
     (generation . 1)
     (text-a . "Mémoire persistante A — 東京 λ\nligne deux")
     (text-b . "Mémoire persistante B — Αθήνα — café"))
    (python
     (label . "python")
     (book-revision . "reader-note/python@1")
     (instance-id . "persistent-note-python")
     (container-id . "wilkbook-python-book-state")
     (generation . 2)
     (text-a . "Примечание Python A — مرحبا — café")
     (text-b . "Примечание Python B — 東京 — λ"))))

;; The system entrypoint primitive-loads the accepted guest adapter first.
(define %base-module (resolve-module '(guest-book-protocol)))
(define (base-private name) (module-ref %base-module name))
(define %smoke-module (resolve-module '(guest-smoke)))
(define (smoke-private name) (module-ref %smoke-module name))

;; SRFI-9 bindings resolve lexically; retain callable procedures explicitly.
(define %base-record-procedures
  `((make-protocol-peer
     . ,(@@ (guest-book-protocol) make-protocol-peer))
    (protocol-peer-endpoint
     . ,(@@ (guest-book-protocol) protocol-peer-endpoint))
    (protocol-peer-donation
     . ,(@@ (guest-book-protocol) protocol-peer-donation))
    (set-protocol-peer-donation!
     . ,(@@ (guest-book-protocol) set-protocol-peer-donation!))
    (protocol-peer-child
     . ,(@@ (guest-book-protocol) protocol-peer-child))
    (set-protocol-peer-child!
     . ,(@@ (guest-book-protocol) set-protocol-peer-child!))
    (make-bounded-capture
     . ,(@@ (guest-book-protocol) make-bounded-capture))
    (make-owned-runsc
     . ,(@@ (guest-book-protocol) make-owned-runsc))
    (owned-runsc-status
     . ,(@@ (guest-book-protocol) owned-runsc-status))
    (owned-runsc-process-group
     . ,(@@ (guest-book-protocol) owned-runsc-process-group))
    (owned-runsc-finalized?
     . ,(@@ (guest-book-protocol) owned-runsc-finalized?))))

(define (base-record-procedure name)
  (let ((entry (assq name %base-record-procedures)))
    (unless entry (error "unknown accepted record procedure" name))
    (cdr entry)))
(define (peer-value peer name) ((base-record-procedure name) peer))
(define (set-peer-value! peer name value)
  ((base-record-procedure name) peer value))
(define (child-value child name) ((base-record-procedure name) child))

(define-record-type <state-world>
  (make-state-world endpoint child control generation cooperative-deadline
                    initialize ready dispatches presentations completions
                    ui-events closing?)
  state-world?
  (endpoint world-endpoint)
  (child world-child)
  (control world-control)
  (generation world-generation)
  (cooperative-deadline world-cooperative-deadline)
  (initialize world-initialize set-world-initialize!)
  (ready world-ready set-world-ready!)
  (dispatches world-dispatches set-world-dispatches!)
  (presentations world-presentations set-world-presentations!)
  (completions world-completions set-world-completions!)
  (ui-events world-ui-events set-world-ui-events!)
  (closing? world-closing? set-world-closing?!))

(define (fail message . arguments)
  (throw 'book-state-guest-error (apply format #f message arguments)))

(define (marker message . arguments)
  ((smoke-private 'emit)
   (string-append "BOOK-STATE-GUEST " (apply format #f message arguments))))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (deadline-after seconds cooperative-deadline)
  (min cooperative-deadline (+ (now-seconds) seconds)))

(define (check-deadline! deadline label)
  (when (>= (now-seconds) deadline)
    (fail "deadline expired while waiting for ~a" label)))

(define (field value name)
  (let ((entry (and (list? value) (assoc name value))))
    (and entry (cdr entry))))

(define (find-value procedure values)
  (and (pair? values)
       (or (procedure (car values))
           (find-value procedure (cdr values)))))

(define take-state-completion!
  (@ (book-session) endpoint-take-state-completion!))

(define (profile language)
  (or (assq language fixed-profiles)
      (fail "unknown fixed language profile: ~s" language)))

(define (profile-value selected name)
  (let ((entry (assq name (cdr selected))))
    (or (and entry (cdr entry))
        (fail "fixed profile lacks ~s" name))))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (file-sha256-string path)
  (bytevector->base16-string (file-sha256 path)))

(define (assert-file-sha256! label path expected)
  (unless (and (string? path)
               (string? expected)
               (= (string-length expected) 64)
               (eq? (stat:type (stat path)) 'regular)
               (string=? (file-sha256-string path) expected))
    (fail "immutable source provenance mismatch: ~a" label)))

(define (assert-source-provenance! config)
  (let ((sources (field config 'sources))
        (language-closure (field config 'language-closure)))
    (unless (and (list? sources) (not (null? sources)))
      (fail "trusted source roster is absent"))
    (unless (= (length sources)
               (length (delete-duplicates (map cadr sources) string=?)))
      (fail "trusted source roster repeats a source path"))
    (for-each
     (lambda (entry)
       (match entry
         ((label path hash) (assert-file-sha256! label path hash))
         (_ (fail "malformed trusted source roster entry"))))
     sources)
    (assert-file-sha256! "accepted 45-path language closure"
                         language-closure expected-language-closure)
    (unless (and (file-exists? expected-guile-sqlite3-output)
                 (file-exists? expected-sqlite-output)
                 (string-prefix? expected-guile-sqlite3-output
                                 (canonicalize-path
                                  (or (search-path %load-path "sqlite3.scm")
                                      (fail "trusted sqlite3 module is absent")))))
      (fail "trusted AArch64 guile-sqlite3/SQLite outputs are not exact"))
    ((base-private 'read-language-closure) language-closure)))

(define (mountinfo-fields line)
  (let* ((parts (string-tokenize line))
         (separator (list-index (lambda (part) (string=? part "-")) parts)))
    (and separator
         (>= separator 6)
         (= (- (length parts) separator 1) 3)
         parts)))

(define (state-root-mount-record)
  (find-value
   (lambda (line)
     (let ((parts (mountinfo-fields line)))
       (and parts
            (string=? (list-ref parts 4) state-root)
            (list (list-ref parts (+ (list-index
                                      (lambda (part) (string=? part "-"))
                                      parts)
                                     1))
                  (append (string-split (list-ref parts 5) #\,)
                          (string-split (last parts) #\,))))))
   (string-split
    (call-with-input-file "/proc/self/mountinfo" get-string-all)
    #\newline)))

(define* (validate-storage-root! root #:optional (require-mount? #t))
  (unless (string=? root state-root)
    (fail "state root differs from the compile-fixed mount path"))
  (unless (and (string=? (canonicalize-path root) root)
               (eq? (stat:type (lstat root)) 'directory)
               (zero? (stat:uid (lstat root)))
               (= (logand (stat:mode (lstat root)) #o7777) #o700))
    (fail "state root is not canonical root-owned mode 0700"))
  ;; mke2fs creates lost+found.  The accepted backend does not require an empty
  ;; root; when present, retain only its ordinary ext4 directory shape.
  (let ((lost-found (string-append root "/lost+found")))
    (when (file-exists? lost-found)
      (let ((info (lstat lost-found)))
        (unless (and (eq? (stat:type info) 'directory)
                     (zero? (stat:uid info))
                     (not (zero? (logand (stat:mode info) #o700))))
          (fail "ext4 lost+found has an unexpected ownership/type/mode")))))
  (when require-mount?
    (let ((record (state-root-mount-record)))
      (unless (and record
                   (string=? (car record) "ext4")
                   (every (lambda (option) (member option (cadr record)))
                          expected-mount-options))
        (fail "mandatory ext4 state mount or one hardened option is absent"))))
  state-root)

(define (classify-loaded-state language loaded)
  (let* ((selected (profile language))
         (kind (and (list? loaded) (car loaded)))
         (version (and (list? loaded) (>= (length loaded) 2) (cadr loaded)))
         (text (and (list? loaded) (>= (length loaded) 3) (caddr loaded))))
    (cond
     ((and (eq? kind 'absent) (= version 0) (string=? text "")) 'absent)
     ((and (eq? kind 'value) (= version 1)
           (string=? text (profile-value selected 'text-a))) 'a)
     ((and (eq? kind 'value) (= version 2)
           (string=? text (profile-value selected 'text-b))) 'b)
     (else
      (fail "~a namespace contains an unexpected version/text state"
            (profile-value selected 'label))))))

(define (close-port-quietly! port)
  ((base-private 'close-port-quietly!) port))

(define (wait-for-stopped-child! pid cooperative-deadline)
  (let retry ()
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid pid (logior WUNTRACED WNOHANG)))
             (lambda arguments
               (if (= (system-error-errno arguments) EINTR)
                   '(0 . #f)
                   (apply throw 'system-error arguments))))))
      (cond
       ((zero? (car waited))
        (when (>= (now-seconds) cooperative-deadline)
          (fail "cooperative deadline expired before runsc FD adapter stopped"))
        (usleep child-stop-poll-microseconds)
        (retry))
       ((and (= (car waited) pid)
             (status:stop-sig (cdr waited))
             (= (status:stop-sig (cdr waited)) SIGSTOP)) #t)
       (else
        (fail "runsc FD adapter exited or changed state before its stop"))))))

(define (kill-and-reap-child/best-effort! pid)
  ;; This closes the ordinary pre-adapter failure path without claiming that a
  ;; guest process in uninterruptible kernel I/O can be reaped by a Scheme
  ;; deadline.  The mandatory outer QEMU guardian is the hard containment owner.
  (catch 'system-error
    (lambda () (kill pid SIGKILL))
    (lambda arguments
      (unless (= (system-error-errno arguments) ESRCH)
        (apply throw 'system-error arguments))))
  (let ((deadline (+ (now-seconds) child-best-effort-reap-seconds)))
    (let retry ()
      (let ((waited
             (catch 'system-error
               (lambda () (waitpid pid WNOHANG))
               (lambda arguments
                 (let ((errno (system-error-errno arguments)))
                   (cond ((= errno EINTR) '(0 . #f))
                         ((= errno ECHILD) (cons pid 'already-reaped))
                         (else (apply throw 'system-error arguments))))))))
        (cond
         ((= (car waited) pid) #t)
         ((>= (now-seconds) deadline) #f)
         (else (usleep child-stop-poll-microseconds) (retry)))))))

(define (spawn-owned-runsc-safely label record-path donation argv environment
                                  directory stdout-path stderr-path
                                  supervisor-guile fd-adapter
                                  cooperative-deadline)
  ;; Unlike the accepted thread-free protocol gate, Book State has already
  ;; started a delegate worker.  Use Guile's accepted spawn helper rather than
  ;; primitive-fork; the fixed child adapter then performs FD 0 -> FD 3.
  (let* ((stdout-pipe ((base-private 'cloexec-pipe)))
         (stderr-pipe ((base-private 'cloexec-pipe)))
         (stdout-input (car stdout-pipe))
         (stdout-output (cdr stdout-pipe))
         (stderr-input (car stderr-pipe))
         (stderr-output (cdr stderr-pipe))
         (stdout-file ((base-private 'open-capture) stdout-path))
         (stderr-file ((base-private 'open-capture) stderr-path))
         (stdout-capture
          ((base-record-procedure 'make-bounded-capture)
           'stdout stdout-input stdout-file 0 0 #f #f))
         (stderr-capture
          ((base-record-procedure 'make-bounded-capture)
           'stderr stderr-input stderr-file 0 0 #f #f))
         (pid #f)
         (child #f)
         (published? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! pid
              (spawn supervisor-guile
                     (append (list supervisor-guile "--no-auto-compile"
                                   fd-adapter "--directory" directory "--")
                             argv)
                     #:search-path? #f
                     #:environment environment
                     #:input donation
                     #:output stdout-output
                     #:error stderr-output))
        (close-port-quietly! stdout-output)
        (close-port-quietly! stderr-output)
        (wait-for-stopped-child! pid cooperative-deadline)
        (let ((start-time ((base-private 'read-process-start-time) pid)))
          (unless start-time (fail "could not identify stopped runsc child"))
          ((base-private 'write-process-record!) record-path pid start-time pid)
          (set! child
                ((base-record-procedure 'make-owned-runsc)
                 label pid start-time pid record-path
                 (list stdout-capture stderr-capture) #f #f))
          (kill pid SIGCONT)
          (set! published? #t)
          child))
      (lambda ()
        (unless published?
          (close-port-quietly! stdout-output)
          (close-port-quietly! stderr-output)
          (if child
              ((base-private 'finalize-owned-runsc!) child)
               (when pid
                 (catch #t
                   (lambda () (kill-and-reap-child/best-effort! pid))
                   (lambda arguments #f))))
          (for-each close-port-quietly!
                    (list stdout-input stdout-file stderr-input stderr-file))
          (when ((base-private 'lstat-or-false) record-path)
            (delete-file record-path)))))))

(define (plain-initialize? value)
  (and (list? value) (string=? (or (field value "type") "") "initialize")))

(define (handle-session-value! world value)
  (cond
   ((plain-initialize? value)
    (when (world-initialize world) (fail "duplicate initialize envelope"))
    (set-world-initialize! world value)
    (endpoint-queue-message! (world-endpoint world) value))
   ((state-ready-message? value)
    (when (world-ready world) (fail "duplicate state-ready envelope"))
    (set-world-ready! world value)
    (endpoint-queue-message! (world-endpoint world) value))
   ((state-delegate-dispatch-result? value)
    (let ((status (state-delegate-dispatch-result-status value)))
      (unless (memq status '(queued cached already-pending))
        (fail "unknown state dispatch status: ~s" status))
      (set-world-dispatches!
       world (append (world-dispatches world) (list status)))))
   ((presented-text? value)
    (set-world-presentations!
     world (append (world-presentations world) (list value))))
   (else (fail "Book Session produced an unknown trusted value: ~s" value))))

(define (pump-world! world)
  (check-deadline! (world-cooperative-deadline world)
                   "cooperative guest polling budget")
  (let ((output (pump-book-ui-output! (world-control world))))
    (when (eq? output 'closed)
      (fail "private UI closed with queued output")))
  (let ((event (pump-book-ui-input! (world-control world))))
    (cond
     ((eq? event 'eof)
      (unless (world-closing? world)
        (fail "private UI reached EOF while state work was live")))
     ((eq? event 'closed)
      (unless (world-closing? world)
        (fail "private UI closed while state work was live")))
     ((list? event)
      (set-world-ui-events!
       world (append (world-ui-events world) (list event))))))
  (let ((endpoint (world-endpoint world)))
    (when (memq 'input (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-input! endpoint)))
        (case (endpoint-pump-result-status result)
          ((committed)
           (for-each (lambda (value) (handle-session-value! world value))
                     (endpoint-pump-result-values result)))
          ((would-block interrupted budget) #t)
          ((eof closed stale)
           (unless (world-closing? world)
             (fail "book endpoint closed before authority cleanup")))
          (else
           (fail "unknown Book Session input status: ~s"
                 (endpoint-pump-result-status result))))))
    (when (memq 'output (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-output! endpoint)))
        (unless (memq (endpoint-pump-result-status result)
                      '(drained budget would-block interrupted closed stale))
          (fail "unknown Book Session output status: ~s"
                (endpoint-pump-result-status result)))))
    (let ((completion (take-state-completion! endpoint)))
      (when completion
        (set-world-completions!
         world (append (world-completions world) (list completion))))))
  ((base-private 'reap-owned-runsc!) (world-child world))
  (let ((status (child-value (world-child world) 'owned-runsc-status)))
    (when (and status (not (world-closing? world)))
      (fail "sandbox book exited before endpoint release: ~s" status)))
  ((base-private 'pump-owned-captures!)
   (world-child world) scheduler-sleep-microseconds))

(define (await-world! world predicate deadline label)
  (let loop ()
    (let ((value (predicate)))
      (cond
       (value value)
       ((>= (now-seconds) deadline) (fail "timed out waiting for ~a" label))
       (else (pump-world! world) (loop))))))

(define (pop-first! getter setter world)
  (let ((values (getter world)))
    (and (pair? values)
         (begin (setter world (cdr values)) (car values)))))

(define (pop-ui! world)
  (pop-first! world-ui-events set-world-ui-events! world))
(define (pop-completion! world)
  (pop-first! world-completions set-world-completions! world))
(define (pop-presentation! world)
  (pop-first! world-presentations set-world-presentations! world))

(define (queue-ui! world kind value)
  (queue-book-ui-command! (world-control world) kind
                          (world-generation world) value))

(define (expect-ui! world kind value)
  (let ((event
         (await-world!
          world (lambda () (pop-ui! world))
           (deadline-after ui-phase-timeout-seconds
                           (world-cooperative-deadline world))
          (format #f "UI ~a" kind))))
    (unless (equal? event (list kind (world-generation world) value))
      (fail "expected exact UI event ~s, received ~s"
            (list kind (world-generation world) value) event))
    event))

(define (await-operation-completion! world label)
  (await-world!
   world (lambda () (pop-completion! world))
   (deadline-after operation-timeout-seconds
                   (world-cooperative-deadline world))
   label))

(define (wait-for-dispatch-count! world wanted)
  (await-world!
   world
   (lambda () (and (>= (length (world-dispatches world)) wanted) #t))
   (deadline-after operation-timeout-seconds
                   (world-cooperative-deadline world))
   (format #f "~a typed state dispatches" wanted)))

(define (action-comparison action endpoint)
  (cons (cons "session_id" (snapshot endpoint "session_id")) action))

(define (validate-presentation! presentation action text)
  (unless (and (presented-text? presentation)
               (string=? (presented-text-session-id presentation)
                         (field action "session_id"))
               (string=? (presented-text-request-id presentation)
                         (field action "request_id"))
               (string=? (presented-text-action-id presentation)
                         (field action "action_id"))
               (string=? (presented-text-surface-handle presentation)
                         (field action "surface_handle"))
               (= (presented-text-surface-generation presentation)
                  (field action "surface_generation"))
               (= (presented-text-sequence presentation)
                  (field action "sequence"))
               (string=? (presented-text-value presentation) text))
    (fail "book presentation differs from the exact trusted action")))

(define (save-through-ui-and-book! world load-owner state-version text)
  (queue-ui! world 'edit text)
  (expect-ui! world 'status "dirty")
  (queue-ui! world 'save "")
  (expect-ui! world 'submit text)
  (expect-ui! world 'status "pending")
  ;; New UI save intent always uses a new CSPRNG-backed Book Session surface.
  ;; The fixed book derives and owns the restart-safe operation ID.
  (let* ((endpoint (world-endpoint world))
         (action (host-action! endpoint "save-note" text))
         (pending
          (make-reader-pending-save
           (world-generation world) text state-version load-owner
           (field (world-initialize world) "surface_handle") action)))
    (endpoint-queue-message! endpoint action)
    (let* ((completion
            (await-operation-completion! world "typed commit completion"))
           (decision (reader-save-completion->decision completion pending)))
      (wait-for-dispatch-count! world 2)
      (unless (and (eq? (car decision) 'committed)
                   (= (list-ref decision 2) (+ state-version 1))
                   (string=? (list-ref decision 3) text))
        (fail "fixed save did not return an exact committed decision: ~s"
              decision))
      (queue-ui! world 'commit-ok text)
      (expect-ui! world 'status "saved")
      (unless (null? (world-presentations world))
        (fail "book presentation preceded correlated UI commit-ok"))
      (let ((presentation-action (host-action! endpoint "present-saved" text)))
        (endpoint-queue-message! endpoint presentation-action)
        (let ((presentation
               (await-world!
                world (lambda () (pop-presentation! world))
                 (deadline-after operation-timeout-seconds
                                 (world-cooperative-deadline world))
                "separate book presentation")))
          (validate-presentation!
           presentation (action-comparison presentation-action endpoint) text)
          (queue-ui! world 'present text)
          (expect-ui! world 'applied text)))
      decision)))

(define (drive-fixed-language! world language)
  (let ((selected (profile language)))
    (queue-ui! world 'open "")
    (expect-ui! world 'ready "")
    (await-world!
     world
     (lambda () (and (world-initialize world) (world-ready world)))
     (deadline-after ui-phase-timeout-seconds
                     (world-cooperative-deadline world))
     "book initialize and state-ready")
    (let* ((endpoint (world-endpoint world))
           (load-owner
            (make-reader-load-owner
             (snapshot endpoint "session_id")
             (snapshot endpoint "surface_generation")
             (state-ready-message-grant-generation (world-ready world))))
           ;; This completion can exist only after the fixed book issued its
           ;; state-read over donated FD 3 and the endpoint worker returned.
           (read-completion
            (await-operation-completion! world "typed book-issued state-read"))
           (loaded (reader-load-completion->value read-completion load-owner))
           (initial (classify-loaded-state language loaded))
           (version (cadr loaded))
           (text (caddr loaded))
           (decision #f))
      (wait-for-dispatch-count! world 1)
      (queue-ui! world (if (eq? (car loaded) 'value)
                           'load-value 'load-absent)
                 text)
      (expect-ui! world 'status
                  (if (eq? (car loaded) 'value)
                      "loaded-value" "loaded-absent"))
      (expect-ui! world 'applied text)
      (marker "language=~a read=~a version=~a bytes=~a ui-painted=true"
              (profile-value selected 'label) initial version
              (bytevector-length (string->utf8 text)))
      (case initial
        ((absent)
         (set! decision
               (save-through-ui-and-book!
                world load-owner version (profile-value selected 'text-a))))
        ((a)
         (marker "language=~a recovered=A-before-save=true"
                 (profile-value selected 'label))
         (set! decision
               (save-through-ui-and-book!
                world load-owner version (profile-value selected 'text-b))))
        ((b)
         (marker "language=~a recovered=B-no-new-save=true"
                 (profile-value selected 'label))))
      (queue-ui! world 'close "")
      (expect-ui! world 'closed "")
      (let ((final-version (if decision (list-ref decision 2) version))
            (final-text (if decision (list-ref decision 3) text))
            (operation-id (and decision (list-ref decision 1))))
        (when decision
          (marker "language=~a saved=~a version=~a operation=~a"
                  (profile-value selected 'label)
                  (if (eq? initial 'absent) "A" "B")
                  final-version operation-id))
        `((language . ,language)
          (initial . ,initial)
          (initial-version . ,version)
          (initial-text . ,text)
          (final-version . ,final-version)
          (final-text . ,final-text)
          (operation-id . ,operation-id))))))

(define (revoke-active-peer! peer)
  (when peer
    (let ((endpoint (peer-value peer 'protocol-peer-endpoint)))
      (when (eq? (snapshot endpoint "state") 'active)
        (revoke-surface! endpoint)))))

(define (run-one-sandbox-book! runtime control language bundle cooperative-deadline
                                supervisor-guile fd-adapter)
  (let* ((selected (profile language))
         (label (profile-value selected 'label))
         (container-id (profile-value selected 'container-id))
         (book-host
          (open-reader-book-host!
           runtime (profile-value selected 'book-revision)
           (profile-value selected 'instance-id) 'read-write))
         (host (reader-book-session-host book-host))
         (peer #f)
         (world #f)
         (result #f)
         (scenario #f)
         (observations #f)
         (runtime-state-owner #f)
         (runtime-cleaned? #f)
         (store-evidence-emitted? #f)
         (completed? #f))
    (define (emit-store-evidence-once! stores include-files?)
      (unless store-evidence-emitted?
        (set! store-evidence-emitted? #t)
        (when (pair? stores)
          ((smoke-private 'emit-diagnostic-store-evidence)
           bundle stores observations include-files?))))
    (define (cleanup-runtime-once!)
      (unless runtime-cleaned?
        (set! runtime-cleaned? #t)
        (if runtime-state-owner
            (begin
              ((base-private 'emit-runtime-state-diagnostics)
               bundle container-id)
              ((base-private 'cleanup-owned-runtime-state!)
               runtime-state-owner container-id))
            ((base-private 'assert-runtime-state-clean!) bundle container-id))))
    ((smoke-private 'call-with-diagnostic-stores)
     bundle
     (lambda (stores)
       (catch #t
         (lambda ()
           (set! runtime-state-owner
                 ((base-private 'prepare-owned-runtime-state!)
                  bundle container-id))
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (call-with-values
                   (lambda () (open-session-endpoint! host label))
                 (lambda (endpoint donation)
                   (set! peer
                         ((base-record-procedure 'make-protocol-peer)
                          label endpoint donation #f 'state '() 0))))
               ((base-private 'assert-cgroup2-preflight!) container-id)
               (call-with-values
                   (lambda ()
                     ((base-private 'read-launch-record)
                      bundle label container-id))
                 (lambda (argv environment)
                   (let* ((donation
                           (peer-value peer 'protocol-peer-donation))
                          (donation-identity (stat donation))
                          (child
                           (spawn-owned-runsc-safely
                             label (string-append bundle "/runsc.pid")
                             donation argv environment bundle
                             (string-append bundle "/runsc.stdout")
                             (string-append bundle "/runsc.stderr")
                             supervisor-guile fd-adapter
                             cooperative-deadline)))
                     (set-peer-value! peer 'set-protocol-peer-child! child)
                     (close-port-quietly! donation)
                     (set-peer-value!
                      peer 'set-protocol-peer-donation! #f)
                     ((base-private 'assert-parent-authority-only!)
                      peer donation-identity)
                     (set! world
                           (make-state-world
                            (peer-value peer 'protocol-peer-endpoint)
                            child control (profile-value selected 'generation)
                             cooperative-deadline
                             #f #f '() '() '() '() #f))
                     (set! scenario
                           (drive-fixed-language! world language))
                     (set-world-closing?! world #t)
                     (set! completed? #t)))))
             (lambda ()
               (unless completed? (revoke-active-peer! peer))
               ((base-private 'release-peer!) peer)))
           (set! result
                 ((base-private 'capture-result)
                  (peer-value peer 'protocol-peer-child)))
           (unless (and (equal?
                         (child-value (peer-value peer 'protocol-peer-child)
                                      'owned-runsc-status)
                         '(exit . 0))
                        (not ((base-private 'capture-overflow?) result)))
             (fail "~a runsc/capture result was not bounded success" label))
           (cleanup-runtime-once!)
           (when (pair? stores)
             (set! observations
                   ((smoke-private 'observe-diagnostic-stores) stores))
             (when ((smoke-private 'diagnostic-stores-overflow?) observations)
               (fail "~a exhausted a bounded diagnostic store" label)))
           (emit-store-evidence-once! stores #f))
         (lambda (key . arguments)
           (when (or runtime-state-owner
                     (and peer
                          (peer-value peer 'protocol-peer-child)))
             (cleanup-runtime-once!))
           (emit-store-evidence-once! stores #t)
           (when result
             ((base-private 'emit-runtime-failure-diagnostics)
              bundle container-id result))
           (apply throw key arguments)))))
    ((base-private 'assert-diagnostic-stores-unmounted!) bundle)
    scenario))

(define (query-rows database sql)
  (let ((statement (sqlite-prepare database sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (sqlite-map identity statement))
      (lambda () (sqlite-finalize statement)))))

(define (query-scalar database sql)
  (let ((rows (query-rows database sql)))
    (and (= (length rows) 1)
         (= (vector-length (car rows)) 1)
         (vector-ref (car rows) 0))))

(define (result-value result name) (field result name))

(define* (inspect-database-contents! path results expected-owner
                                     #:optional (emit-marker marker))
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) expected-owner)
                 (= (stat:nlink info) 1)
                 (= (logand (stat:mode info) #o7777) #o600))
      (fail "closed state database has the wrong ownership/type/mode")))
  (for-each
   (lambda (suffix)
     (when (file-exists? (string-append path suffix))
       (fail "closed state database retained SQLite sidecar ~a" suffix)))
   '("-journal" "-wal" "-shm"))
  (let ((database (sqlite-open path SQLITE_OPEN_READONLY)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (and (= (query-scalar database "PRAGMA user_version") 1)
                     (string=? (query-scalar database "PRAGMA quick_check")
                               "ok")
                     (null? (query-rows database "PRAGMA foreign_key_check")))
          (fail "closed SQLite database failed schema/integrity inspection"))
        (let ((namespaces
               (query-rows
                database
                "SELECT book_revision, instance_id, state_version, has_value, text FROM book_instances ORDER BY book_revision, instance_id"))
              (receipts
               (query-rows
                database
                "SELECT b.book_revision, b.instance_id, r.operation_id, r.expected_state_version, r.text, r.resulting_state_version FROM commit_receipts AS r JOIN book_instances AS b ON b.namespace_id = r.namespace_id ORDER BY b.book_revision, b.instance_id, r.resulting_state_version")))
          (unless (= (length namespaces) 2)
            (fail "inspector did not find exactly two fixed namespaces"))
          (for-each
           (lambda (result)
             (let* ((selected (profile (result-value result 'language)))
                    (row
                     (find (lambda (candidate)
                             (and (string=? (vector-ref candidate 0)
                                            (profile-value selected
                                                           'book-revision))
                                  (string=? (vector-ref candidate 1)
                                            (profile-value selected
                                                           'instance-id))))
                           namespaces)))
               (unless (and row
                            (= (vector-ref row 2)
                               (result-value result 'final-version))
                            (= (vector-ref row 3) 1)
                            (string=? (vector-ref row 4)
                                      (result-value result 'final-text)))
                 (fail "inspector row differs from typed result for ~a"
                       (profile-value selected 'label)))))
           results)
          (unless
              (and
               (= (length receipts)
                  (apply + (map (lambda (result)
                                  (result-value result 'final-version))
                                results)))
               (= (length receipts)
                  (length (delete-duplicates
                           (map (lambda (row) (vector-ref row 2)) receipts)
                           string=?)))
               (every
                (lambda (result)
                  (let* ((selected (profile (result-value result 'language)))
                         (book-revision
                          (profile-value selected 'book-revision))
                         (instance-id (profile-value selected 'instance-id))
                         (final-version
                          (result-value result 'final-version))
                         (rows
                          (filter
                           (lambda (row)
                             (and (string=? (vector-ref row 0) book-revision)
                                  (string=? (vector-ref row 1) instance-id)))
                           receipts)))
                    (and
                     (= (length rows) final-version)
                     (every
                      (lambda (row version)
                        (and
                         (book-state-operation-id? (vector-ref row 2))
                         (= (vector-ref row 3) (- version 1))
                         (= (vector-ref row 5) version)
                         (string=?
                          (vector-ref row 4)
                          (case version
                            ((1) (profile-value selected 'text-a))
                            ((2) (profile-value selected 'text-b))
                            (else "unexpected-version")))))
                      rows (iota final-version 1)))))
                results))
            (fail "inspector receipt inventory does not match fixed versions"))
          (emit-marker
           "inspector-path=~a namespaces=2 receipts=~a quick-check=ok foreign-keys=ok sidecars=none"
           path (length receipts))))
      (lambda () (sqlite-close database))))
  #t)

(define (inspect-closed-database! path results)
  (unless (string=? path state-database)
    (fail "inspector database path is not the backend database path"))
  (inspect-database-contents! path results 0))

(define (wait-for-ui-event! control generation deadline kind value label)
  (let loop ()
    (check-deadline! deadline label)
    (let ((output (pump-book-ui-output! control)))
      (when (eq? output 'closed)
        (fail "UI closed before ~a" label)))
    (let ((event (pump-book-ui-input! control)))
      (cond
       ((list? event)
        (unless (equal? event (list kind generation value))
          (fail "unexpected UI event while waiting for ~a: ~s" label event))
        event)
       ((memq event '(eof closed))
        (fail "UI transport ended before ~a" label))
       (else (usleep scheduler-sleep-microseconds) (loop))))))

(define (finish-ui! control generation cooperative-deadline)
  (let ((ticket (queue-book-ui-command! control 'finish generation "")))
    (let flush ()
      (check-deadline! cooperative-deadline "UI finish delivery")
      (pump-book-ui-output! control)
      (unless (book-ui-command-delivered? control ticket)
        (let ((event (pump-book-ui-input! control)))
          (when (or (list? event) (memq event '(eof closed)))
            (fail "UI event/EOF preceded finish delivery: ~s" event)))
        (usleep scheduler-sleep-microseconds)
        (flush))))
  (wait-for-ui-event! control generation cooperative-deadline 'done "ok"
                      "UI done acknowledgement")
  (let loop ()
    (check-deadline! cooperative-deadline "UI EOF")
    (pump-book-ui-output! control)
    (let ((event (pump-book-ui-input! control)))
      (cond
       ((eq? event 'eof) #t)
       ((or (eq? event 'closed) (list? event))
        (fail "UI did not expose clean EOF after done: ~s" event))
       (else (usleep scheduler-sleep-microseconds) (loop))))))

(define (generate-bundles! config work-root closure)
  (let* ((module (resolve-module '(oci-book-bundle)))
         (generate-guile (module-ref module 'generate-guile-protocol-bundle))
         (generate-python (module-ref module 'generate-python-protocol-bundle))
         (profile-path (field config 'language-profile))
         (guile-bundle (string-append work-root "/guile"))
         (python-bundle (string-append work-root "/python")))
    (generate-guile
     #:profile-input profile-path
     #:boundary-probe-input (field config 'guile-boundary-probe)
     #:book-entry-input (field config 'guile-book)
     #:protocol-input (field config 'guile-protocol)
     #:blocking-input (field config 'blocking-protocol)
     #:bundle-input guile-bundle
     #:container-id (profile-value (profile 'guile) 'container-id)
     #:requisites-runner (lambda (_profile) closure))
    (generate-python
     #:profile-input profile-path
     #:boundary-probe-input (field config 'python-boundary-probe)
     #:book-entry-input (field config 'python-book)
     #:protocol-input (field config 'python-protocol)
     #:bundle-input python-bundle
     #:container-id (profile-value (profile 'python) 'container-id)
     #:requisites-runner (lambda (_profile) closure))
    (values guile-bundle python-bundle)))

(define (run-guest! config)
  (define work-root "/run/wilkbook-book-state-guest")
  (define cooperative-deadline
    (+ (now-seconds) cooperative-run-budget-seconds))
  (define control #f)
  (define runtime #f)
  (define runtime-closed? #f)
  (define pass-summary #f)
  (when ((base-private 'lstat-or-false) work-root)
    (fail "refusing stale guest work root: ~a" work-root))
  (mkdir work-root #o700)
  (chmod work-root #o700)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let ((closure (assert-source-provenance! config)))
        (marker "source-provenance=pass accepted-reader-join-source-root=~a"
                expected-reader-join-manifest)
        ((smoke-private 'assert-kernel) (field config 'kernel-release))
        ((smoke-private 'assert-host-boundaries))
        ((smoke-private 'assert-sidecar-layout))
        ((smoke-private 'run-version) work-root)
        ((base-private 'run-protocol-self-tests!))
        (call-with-values
            (lambda () (generate-bundles! config work-root closure))
          (lambda (guile-bundle python-bundle)
            (validate-storage-root! state-root)
            (set! control (open-book-ui-control! cooperative-deadline))
            (wait-for-ui-event!
             control 1 cooperative-deadline
             'channel-ready "" "UI channel readiness")
            (set! runtime (open-reader-state-runtime state-root))
            (let ((results
                   (list
                    (run-one-sandbox-book!
                     runtime control 'guile guile-bundle cooperative-deadline
                     (field config 'supervisor-guile)
                     (field config 'runsc-fd3-adapter))
                    (run-one-sandbox-book!
                     runtime control 'python python-bundle cooperative-deadline
                     (field config 'supervisor-guile)
                     (field config 'runsc-fd3-adapter)))))
              (unless (apply eq? (map (lambda (result)
                                        (result-value result 'initial))
                                      results))
                (fail "fixed namespaces began in different boot stages"))
              ;; Every endpoint release above synchronously closes/revokes and
              ;; joins its typed storage worker before this database close.
              (close-reader-state-runtime! runtime)
              (set! runtime-closed? #t)
              (inspect-closed-database! state-database results)
              (finish-ui! control 2 cooperative-deadline)
              (set! pass-summary
                    (list (result-value (car results) 'initial)
                          (result-value (car results) 'final-version)
                          (result-value (cadr results) 'final-version))))))))
    (lambda ()
      (when (and runtime (not runtime-closed?))
        (catch #t
          (lambda () (close-reader-state-runtime! runtime))
          (lambda arguments #f)))
      (close-book-ui-control! control)))
  ;; Success is emitted only after all normal endpoint/runsc workers, SQLite,
  ;; the inspector, UI close, and sync have returned.  A blocked cleanup emits
  ;; no success; the mandatory outer QEMU guardian eventually terminates the VM
  ;; and reports that guest status was not assessed.
  (unless pass-summary
    (fail "guest reached post-cleanup path without a pass summary"))
  (sync)
  (marker "result=pass initial-stage=~a final-versions=~a,~a"
          (car pass-summary) (cadr pass-summary) (caddr pass-summary))
  0)

(define (book-state-guest-main config argv)
  (if (not (null? (cdr argv)))
      (begin
        (marker "result=fail reason=authority-accepts-no-arguments")
        1)
      (catch #t
        (lambda () (run-guest! config))
        (lambda (key . arguments)
          (catch #t
            (lambda ()
              (marker "result=fail key=~s details=~s" key arguments))
            (lambda ignored #f))
          1))))

(sigaction SIGPIPE SIG_IGN)
