;;; Supervised trusted authority for the opt-in PineNote Book State note.
;;; One compile-fixed book receives only its connected Book Session FD 3.  The
;;; service selects Guile; the equally fixed Python runner has no first-trial UI.
(define-module (book-state-device-authority)
  #:use-module (book-protocol)
  #:use-module (book-session)
  #:use-module (book-state)
  #:use-module (book-state-protocol)
  #:use-module (book-state-reader-bridge)
  #:use-module (book-state-session-delegate)
  #:use-module (guest-book-protocol)
  #:use-module (guest-smoke)
  #:use-module (guest-virtio-book-ui)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (oci-book-bundle)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (system foreign)
  #:export (book-state-device-main))

(define state-root "/data/wilkbook/book-state")
(define activation-file "/data/wilkbook/book-state/enabled")
(define database-path "/data/wilkbook/book-state/book-state-v1.sqlite")
(define runtime-root "/run/wilkbook-book-state")
(define socket-path "/run/wilkbook-book-state/control.sock")
(define fixed-profiles
  '((guile
     (label . "device-guile-note")
     (book-revision . "reader-note/guile@1")
     (instance-id . "persistent-note-guile")
     (container-id . "wilkbook-guile-book-state-device"))
    (python
     (label . "device-python-note")
     (book-revision . "reader-note/python@1")
     (instance-id . "persistent-note-python")
     (container-id . "wilkbook-python-book-state-device"))))
(define interaction-budget-seconds 300.0)
(define ui-phase-timeout-seconds 25.0)
(define operation-timeout-seconds 3.0)
(define scheduler-sleep-microseconds 5000)
(define child-stop-poll-microseconds 5000)
(define child-best-effort-reap-seconds 1.0)
(define expected-device-language-closure-count 46)
(define so-peercred 17)
(define stop-requested? #f)
(define active-listener-fd #f)
(define c-shutdown
  (pointer->procedure int (dynamic-func "shutdown" (dynamic-link))
                      (list int int) #:return-errno? #t))

(define %base-module (resolve-module '(guest-book-protocol)))
(define (base-private name) (module-ref %base-module name))
(define %smoke-module (resolve-module '(guest-smoke)))
(define (smoke-private name) (module-ref %smoke-module name))

;; SRFI-9 accessors in the accepted lifetime owner resolve lexically.
(define %base-record-procedures
  `((make-protocol-peer . ,(@@ (guest-book-protocol) make-protocol-peer))
    (protocol-peer-endpoint . ,(@@ (guest-book-protocol) protocol-peer-endpoint))
    (protocol-peer-donation . ,(@@ (guest-book-protocol) protocol-peer-donation))
    (set-protocol-peer-donation! . ,(@@ (guest-book-protocol) set-protocol-peer-donation!))
    (protocol-peer-child . ,(@@ (guest-book-protocol) protocol-peer-child))
    (set-protocol-peer-child! . ,(@@ (guest-book-protocol) set-protocol-peer-child!))
    (make-bounded-capture . ,(@@ (guest-book-protocol) make-bounded-capture))
    (make-owned-runsc . ,(@@ (guest-book-protocol) make-owned-runsc))
    (owned-runsc-status . ,(@@ (guest-book-protocol) owned-runsc-status))
    (owned-runsc-process-group
     . ,(@@ (guest-book-protocol) owned-runsc-process-group))
    (owned-runsc-finalized?
     . ,(@@ (guest-book-protocol) owned-runsc-finalized?))))

(define (base-record name)
  (or (assq-ref %base-record-procedures name)
      (error "unknown accepted lifetime-owner binding" name)))
(define (peer-value peer name) ((base-record name) peer))
(define (set-peer-value! peer name value) ((base-record name) peer value))
(define (child-value child name) ((base-record name) child))

(define-record-type <state-world>
  (make-state-world endpoint child control deadline initialize ready dispatches
                    presentations completions ui-events closing?)
  state-world?
  (endpoint world-endpoint)
  (child world-child)
  (control world-control)
  (deadline world-deadline)
  (initialize world-initialize set-world-initialize!)
  (ready world-ready set-world-ready!)
  (dispatches world-dispatches set-world-dispatches!)
  (presentations world-presentations set-world-presentations!)
  (completions world-completions set-world-completions!)
  (ui-events world-ui-events set-world-ui-events!)
  (closing? world-closing? set-world-closing?!))

;; Keep callable wrappers for focused native lifetime tests.  SRFI-9 record
;; names themselves are lexical syntax and cannot be recovered with module-ref.
(define (world-record name)
  (case name
    ((make)
     (lambda (endpoint child control deadline initialize ready dispatches
                       presentations completions ui-events closing?)
       (make-state-world endpoint child control deadline initialize ready
                         dispatches presentations completions ui-events
                         closing?)))
    ((ready) (lambda (world) (world-ready world)))
    ((set-closing!) (lambda (world value) (set-world-closing?! world value)))
    (else (error "unknown authority world record binding" name))))

(define (fail message . arguments)
  (throw 'book-state-device-error (apply format #f message arguments)))
(define (marker message . arguments)
  (format (current-error-port) "BOOK_STATE_DEVICE: ~a~%"
          (apply format #f message arguments))
  (force-output (current-error-port)))
(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(define (deadline-after seconds outer) (min outer (+ (now-seconds) seconds)))
(define (check-deadline! deadline label)
  (when stop-requested? (throw 'book-state-device-stop-requested label))
  (when (>= (now-seconds) deadline) (fail "timed out waiting for ~a" label)))
(define (field value name)
  (let ((entry (and (list? value) (assoc name value)))) (and entry (cdr entry))))
(define (profile language)
  (or (assq language fixed-profiles)
      (fail "unknown compile-fixed book language: ~s" language)))
(define (profile-field selected name)
  (let ((entry (assq name (cdr selected))))
    (or (and entry (cdr entry))
        (fail "compile-fixed book profile lacks ~s" name))))
(define (snapshot endpoint name) (field (host-session-snapshot endpoint) name))
(define (close-port-quietly! port) ((base-private 'close-port-quietly!) port))

(define (delete-owned-tree! path)
  ;; PATH is always a just-created per-session runtime root.  Walk by lstat so
  ;; the profile and store symlinks inside an OCI rootfs are unlinked rather
  ;; than followed.
  (let ((info ((base-private 'lstat-or-false) path)))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name)
               (delete-owned-tree! (string-append path "/" name)))
             (scandir path
                      (lambda (name) (not (member name '("." ".."))))))
            (rmdir path))
          (delete-file path)))))

(define (read-device-language-closure path)
  ;; The current-channel device profile has one more retained path than the
  ;; immutable 45-path QEMU packet.  Do not weaken the accepted helper or its
  ;; evidence pin to accommodate a later profile; validate this separate
  ;; closure with the same canonical parser and its own exact cardinality.
  (let ((closure ((smoke-private 'read-closure) path)))
    (unless (= (length closure) expected-device-language-closure-count)
      (fail "device language closure changed: expected ~a paths, got ~a"
            expected-device-language-closure-count (length closure)))
    closure))

(define (require-private-root! expected-owner)
  (unless (and (file-exists? state-root)
               (string=? (canonicalize-path state-root) state-root))
    (fail "state root is absent or non-canonical"))
  (let ((info (lstat state-root)))
    (unless (and (eq? (stat:type info) 'directory)
                  (= (stat:uid info) expected-owner)
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "state root is not a root-owned mode-0700 directory")))
  (let ((enabled (lstat activation-file)))
    (unless (and (eq? (stat:type enabled) 'regular)
                  (= (stat:uid enabled) expected-owner)
                  (= (stat:nlink enabled) 1)
                 (= (logand (stat:mode enabled) #o7777) #o600)
                 (string=? (call-with-input-file activation-file get-string-all)
                           "enabled\n"))
      (fail "activation marker is not the exact root-owned opt-in"))))

(define (wait-for-stopped-child! pid deadline)
  (let loop ()
    (check-deadline! deadline "runsc FD adapter stop")
    (let ((waited
           (catch 'system-error
             (lambda () (waitpid pid (logior WUNTRACED WNOHANG)))
             (lambda arguments
               (if (= (system-error-errno arguments) EINTR)
                   '(0 . #f)
                   (apply throw 'system-error arguments))))))
      (cond
       ((zero? (car waited)) (usleep child-stop-poll-microseconds) (loop))
       ((and (= (car waited) pid)
             (status:stop-sig (cdr waited))
             (= (status:stop-sig (cdr waited)) SIGSTOP)) #t)
       (else (fail "runsc FD adapter exited before ownership was recorded"))))))

(define (kill-and-reap-child/best-effort! pid)
  (catch 'system-error
    (lambda () (kill pid SIGKILL))
    (lambda arguments
      (unless (= (system-error-errno arguments) ESRCH)
        (apply throw 'system-error arguments))))
  (let ((deadline (+ (now-seconds) child-best-effort-reap-seconds)))
    (let loop ()
      (let ((waited
             (catch 'system-error
               (lambda () (waitpid pid WNOHANG))
               (lambda arguments
                 (case (system-error-errno arguments)
                   ((4) '(0 . #f))
                   ((10) (cons pid 'already-reaped))
                   (else (apply throw 'system-error arguments)))))))
        (cond ((= (car waited) pid) #t)
              ((>= (now-seconds) deadline) #f)
              (else (usleep child-stop-poll-microseconds) (loop)))))))

(define (spawn-owned-runsc! label record-path donation argv environment directory
                             stdout-path stderr-path supervisor-guile fd-adapter
                             deadline)
  ;; Spawn, stop, identify, and publish ownership before runsc can execute.
  (let* ((stdout-pipe ((base-private 'cloexec-pipe)))
         (stderr-pipe ((base-private 'cloexec-pipe)))
         (stdout-input (car stdout-pipe)) (stdout-output (cdr stdout-pipe))
         (stderr-input (car stderr-pipe)) (stderr-output (cdr stderr-pipe))
         (stdout-file ((base-private 'open-capture) stdout-path))
         (stderr-file ((base-private 'open-capture) stderr-path))
         (stdout-capture ((base-record 'make-bounded-capture)
                          'stdout stdout-input stdout-file 0 0 #f #f))
         (stderr-capture ((base-record 'make-bounded-capture)
                          'stderr stderr-input stderr-file 0 0 #f #f))
         (pid #f) (child #f) (published? #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! pid
              (spawn supervisor-guile
                     (append (list supervisor-guile "--no-auto-compile"
                                   fd-adapter "--directory" directory "--") argv)
                     #:search-path? #f #:environment environment #:input donation
                     #:output stdout-output #:error stderr-output))
        (close-port-quietly! stdout-output)
        (close-port-quietly! stderr-output)
        (wait-for-stopped-child! pid deadline)
        (let ((start-time ((base-private 'read-process-start-time) pid)))
          (unless start-time (fail "could not identify stopped runsc child"))
          ((base-private 'write-process-record!) record-path pid start-time pid)
          (set! child ((base-record 'make-owned-runsc)
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
              (when pid (kill-and-reap-child/best-effort! pid)))
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
    (unless (memq (state-delegate-dispatch-result-status value)
                  '(queued cached already-pending))
      (fail "unknown state dispatch result"))
    (set-world-dispatches!
     world (append (world-dispatches world)
                   (list (state-delegate-dispatch-result-status value)))))
   ((presented-text? value)
    (set-world-presentations! world (append (world-presentations world) (list value))))
   (else (fail "Book Session produced unknown trusted value: ~s" value))))

(define take-state-completion!
  (@ (book-session) endpoint-take-state-completion!))

(define (pump-world! world)
  (check-deadline! (world-deadline world) "active interaction")
  (when (eq? (pump-book-ui-output! (world-control world)) 'closed)
    (unless (world-closing? world) (fail "UI closed with queued output")))
  (let ((event (pump-book-ui-input! (world-control world))))
    (cond
     ((memq event '(eof closed))
      (unless (world-closing? world)
        (set-world-ui-events!
         world (append (world-ui-events world) (list '(closed 1 ""))))
        (set-world-closing?! world #t)))
     ((list? event)
      (set-world-ui-events! world (append (world-ui-events world) (list event)))
      (when (eq? (car event) 'closed)
        (set-world-closing?! world #t)))))
  (let ((endpoint (world-endpoint world)))
    (when (memq 'input (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-input! endpoint)))
        (case (endpoint-pump-result-status result)
          ((committed)
           (for-each (lambda (value) (handle-session-value! world value))
                     (endpoint-pump-result-values result)))
          ((would-block interrupted budget) #t)
          ((eof closed stale) (unless (world-closing? world)
                                (fail "book endpoint closed early")))
          (else (fail "unknown Book Session input status")))))
    (when (memq 'output (endpoint-ready-events endpoint))
      (let ((result (endpoint-pump-output! endpoint)))
        (unless (memq (endpoint-pump-result-status result)
                      '(drained budget would-block interrupted closed stale))
          (fail "unknown Book Session output status"))))
    (let ((completion (take-state-completion! endpoint)))
      (when completion
        (set-world-completions! world
                                (append (world-completions world) (list completion))))))
  ((base-private 'reap-owned-runsc!) (world-child world))
  (let ((status (child-value (world-child world) 'owned-runsc-status)))
    (when (and status (not (world-closing? world)))
      (fail "sandboxed book exited before UI close: ~s" status)))
  ((base-private 'pump-owned-captures!) (world-child world)
   scheduler-sleep-microseconds))

(define (pop-first! getter setter world)
  (let ((values (getter world)))
    (and (pair? values) (begin (setter world (cdr values)) (car values)))))
(define (pop-ui! world) (pop-first! world-ui-events set-world-ui-events! world))
(define (pop-completion! world)
  (pop-first! world-completions set-world-completions! world))
(define (pop-presentation! world)
  (pop-first! world-presentations set-world-presentations! world))

(define (await-world! world predicate timeout label)
  (let ((deadline (deadline-after timeout (world-deadline world))))
    (let loop ()
      (let ((value (predicate)))
        (cond (value value)
              ((world-closing? world)
               (throw 'book-state-device-ui-closed label))
              (else (check-deadline! deadline label) (pump-world! world) (loop)))))))
(define (queue-ui! world kind value)
  (queue-book-ui-command! (world-control world) kind 1 value))
(define (expect-ui! world kind value)
  (let ((event (await-world! world (lambda () (pop-ui! world))
                             ui-phase-timeout-seconds (format #f "UI ~a" kind))))
    (unless (equal? event (list kind 1 value))
      (fail "expected UI event ~s, received ~s" (list kind 1 value) event))
    event))
(define (expect-status! world allowed)
  (let ((event (await-world! world (lambda () (pop-ui! world))
                             ui-phase-timeout-seconds "UI status paint")))
    (unless (and (eq? (car event) 'status) (= (cadr event) 1)
                 (member (caddr event) allowed string=?))
      (fail "unexpected post-commit UI event: ~s" event))
    (caddr event)))
(define (wait-for-dispatch-count! world count)
  (await-world! world
                (lambda () (and (>= (length (world-dispatches world)) count) #t))
                operation-timeout-seconds "typed state dispatch"))

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
               (= (presented-text-sequence presentation) (field action "sequence"))
               (string=? (presented-text-value presentation) text))
    (fail "book presentation differs from exact trusted action")))

(define (drive-human-note! world)
  (await-world! world
                (lambda () (and (world-initialize world) (world-ready world)))
                ui-phase-timeout-seconds "book initialize and state-ready")
  (let* ((endpoint (world-endpoint world))
         (load-owner
          (make-reader-load-owner
           (snapshot endpoint "session_id")
           (snapshot endpoint "surface_generation")
           (state-ready-message-grant-generation (world-ready world))))
         (completion
          (await-world! world (lambda () (pop-completion! world))
                        operation-timeout-seconds "book-issued state read"))
         (loaded (reader-load-completion->value completion load-owner))
         (state-version (cadr loaded)))
    (wait-for-dispatch-count! world 1)
    (queue-ui! world (if (eq? (car loaded) 'value) 'load-value 'load-absent)
               (caddr loaded))
    (expect-ui! world 'status
                (if (eq? (car loaded) 'value) "loaded-value" "loaded-absent"))
    (expect-ui! world 'applied (caddr loaded))
    (marker "opened fixed-note version=~a present=~a"
            state-version (eq? (car loaded) 'value))
    (let loop ((version state-version) (dispatch-count 1))
      (let ((event
             (await-world! world (lambda () (pop-ui! world))
                           interaction-budget-seconds "human save or close")))
         (match event
           (('status 1 (or "dirty" "failed"))
            ;; Local editor feedback is not a state operation. In particular,
            ;; typing precedes submit, and client-side validation can fail
            ;; without ever asking the book/backend to commit anything.
            (loop version dispatch-count))
           (('closed 1 "")
           (set-world-closing?! world #t)
           (marker "closed fixed-note version=~a" version)
           version)
          (('submit 1 (? string? text))
           (expect-ui! world 'status "pending")
           (let* ((action (host-action! endpoint "save-note" text))
                  (pending
                   (make-reader-pending-save
                    1 text version load-owner
                    (field (world-initialize world) "surface_handle") action)))
             (endpoint-queue-message! endpoint action)
             (let* ((completion
                     (await-world! world (lambda () (pop-completion! world))
                                   operation-timeout-seconds "typed commit completion"))
                    (decision (reader-save-completion->decision completion pending)))
               (wait-for-dispatch-count! world (+ dispatch-count 1))
               (case (car decision)
                 ((committed)
                  (let ((new-version (list-ref decision 2)))
                    (queue-ui! world 'commit-ok text)
                    (let ((painted (expect-status! world '("saved" "dirty"))))
                      (when (string=? painted "saved")
                        (let ((present-action (host-action! endpoint "present-saved" text)))
                          (endpoint-queue-message! endpoint present-action)
                          (let ((presentation
                                 (await-world!
                                  world (lambda () (pop-presentation! world))
                                  operation-timeout-seconds "book presentation")))
                            (validate-presentation!
                             presentation (action-comparison present-action endpoint) text)
                            (queue-ui! world 'present text)
                            (expect-ui! world 'applied text))))
                    (marker "saved fixed-note version=~a bytes=~a"
                            new-version (bytevector-length (string->utf8 text)))
                    (loop new-version (+ dispatch-count 1)))))
                 ((conflict failed)
                  (let* ((code (if (eq? (car decision) 'conflict)
                                   'conflict (list-ref decision 2)))
                         (code-text (symbol->string code))
                         (next-version (if (eq? (car decision) 'conflict)
                                           (list-ref decision 2) version)))
                    (queue-ui! world 'commit-failed code-text)
                    (expect-ui! world 'status "failed")
                    (marker "save-rejected code=~a version=~a" code next-version)
                    (loop next-version (+ dispatch-count 1))))
                 (else (fail "unknown typed save decision: ~s" decision))))))
          (_ (fail "unexpected UI event outside a save: ~s" event)))))))

(define (revoke-active-peer! peer)
  (when peer
    (let ((endpoint (peer-value peer 'protocol-peer-endpoint)))
      (when (eq? (snapshot endpoint "state") 'active) (revoke-surface! endpoint)))))

(define (generate-fixed-bundle! language selected config bundle closure)
  (case language
    ((guile)
     (generate-guile-protocol-bundle
      #:profile-input (field config 'language-profile)
      #:boundary-probe-input (field config 'boundary-probe)
      #:book-entry-input (field config 'guile-book)
      #:protocol-input (field config 'guile-protocol)
      #:blocking-input (field config 'blocking-protocol)
      #:bundle-input bundle
      #:container-id (profile-field selected 'container-id)
      #:requisites-runner (lambda (_profile) closure)))
    ((python)
     (generate-python-protocol-bundle
      #:profile-input (field config 'language-profile)
      #:boundary-probe-input (field config 'python-boundary-probe)
      #:book-entry-input (field config 'python-book)
      #:protocol-input (field config 'python-protocol)
      #:bundle-input bundle
      #:container-id (profile-field selected 'container-id)
      #:requisites-runner (lambda (_profile) closure)))
    (else (fail "unsupported compile-fixed bundle language: ~s" language))))

(define (run-sandbox-session! runtime control config session-root deadline language)
  (let* ((selected (profile language))
         (label (profile-field selected 'label))
         (container-id (profile-field selected 'container-id))
         (bundle (string-append session-root "/" (symbol->string language)))
         (closure (read-device-language-closure
                   (field config 'language-closure)))
         (book-host
          (open-reader-book-host!
           runtime (profile-field selected 'book-revision)
           (profile-field selected 'instance-id) 'read-write))
         (host (reader-book-session-host book-host))
         (peer #f) (world #f) (result #f) (runtime-owner #f)
         (runtime-cleaned? #f) (completed? #f))
    (define (cleanup-runtime-once!)
      (unless runtime-cleaned?
        (if runtime-owner
            ((base-private 'cleanup-owned-runtime-state!) runtime-owner container-id)
            ((base-private 'assert-runtime-state-clean!) bundle container-id))
        (set! runtime-cleaned? #t)))
    (catch #t
      (lambda ()
        (generate-fixed-bundle! language selected config bundle closure)
        ((smoke-private 'call-with-diagnostic-stores)
         bundle
         (lambda (stores)
           (catch #t
             (lambda ()
               (set! runtime-owner
                     ((base-private 'prepare-owned-runtime-state!) bundle container-id))
               (dynamic-wind
                 (lambda () #t)
                 (lambda ()
                   (call-with-values
                       (lambda () (open-session-endpoint! host label))
                     (lambda (endpoint donation)
                       (set! peer ((base-record 'make-protocol-peer)
                                   label endpoint donation #f
                                   'state '() 0))))
                   ((base-private 'assert-cgroup2-preflight!) container-id)
                   (call-with-values
                       (lambda () ((base-private 'read-launch-record)
                                    bundle (symbol->string language) container-id))
                     (lambda (argv environment)
                       (let* ((donation (peer-value peer 'protocol-peer-donation))
                              (donation-identity (stat donation))
                              (ui-identity (stat (book-ui-control-fd control)))
                              (child
                                (spawn-owned-runsc!
                                 label
                                 (string-append bundle "/runsc.pid")
                                 donation argv environment bundle
                                 (string-append bundle "/runsc.stdout")
                                 (string-append bundle "/runsc.stderr")
                                 (field config 'supervisor-guile)
                                 (field config 'runsc-fd3-adapter) deadline)))
                         (when (and (= (stat:dev donation-identity)
                                       (stat:dev ui-identity))
                                    (= (stat:ino donation-identity)
                                       (stat:ino ui-identity)))
                           (fail "UI transport and Book Session donation are the same FD"))
                         (set-peer-value! peer 'set-protocol-peer-child! child)
                         (close-port-quietly! donation)
                         (set-peer-value! peer 'set-protocol-peer-donation! #f)
                         ((base-private 'assert-parent-authority-only!)
                          peer donation-identity)
                         (set! world
                               (make-state-world
                                (peer-value peer 'protocol-peer-endpoint)
                                child control deadline #f #f '() '() '() '() #f))
                         (catch 'book-state-device-ui-closed
                           (lambda () (drive-human-note! world))
                           (lambda (key label)
                             (marker "UI disconnected while waiting for ~a" label)))
                         (set-world-closing?! world #t)
                         (set! completed? #t)))))
                  (lambda ()
                    (unless completed? (revoke-active-peer! peer))
                    ((base-private 'release-peer!) peer)))
                (set! result
                      ((base-private 'capture-result)
                       (peer-value peer 'protocol-peer-child)))
               (unless (and
                        (equal?
                         (child-value (peer-value peer 'protocol-peer-child)
                                      'owned-runsc-status)
                         '(exit . 0))
                        (not ((base-private 'capture-overflow?) result)))
                  (fail "runsc/capture result was not bounded success"))
                (cleanup-runtime-once!))
               (lambda (key . arguments)
                 (marker "session-failed before runtime cleanup: key=~s details=~s"
                         key arguments)
                (when (and peer (peer-value peer 'protocol-peer-child)
                            ((base-record 'owned-runsc-finalized?)
                            (peer-value peer 'protocol-peer-child)))
                 (set! result
                       ((base-private 'capture-result)
                        (peer-value peer 'protocol-peer-child))))
                (when result
                  ((base-private 'emit-runtime-failure-diagnostics)
                   bundle container-id result))
                (cleanup-runtime-once!)
                (apply throw key arguments)))))
        ((base-private 'assert-diagnostic-stores-unmounted!) bundle)
        (delete-owned-tree! session-root))
      (lambda (key . arguments)
        ;; A service restart is allowed to leave no transient generation.  If
        ;; either runtime or diagnostic unmount cleanup cannot be proven, this
        ;; handler throws before deletion and the next start refuses the stale
        ;; /run root rather than concealing it.
        (cleanup-runtime-once!)
        ((base-private 'assert-diagnostic-stores-unmounted!) bundle)
        (when (file-exists? session-root)
          (delete-owned-tree! session-root))
        (apply throw key arguments)))))

(define (wait-for-ui-event! control deadline expected)
  (let loop ()
    (check-deadline! deadline (symbol->string expected))
    (when (eq? (pump-book-ui-output! control) 'closed)
      (fail "UI closed before ~a" expected))
    (let ((event (pump-book-ui-input! control)))
      (cond
       ((list? event)
        (unless (equal? event (list expected 1 ""))
          (fail "unexpected initial UI event: ~s" event)))
       ((memq event '(eof closed)) (fail "UI ended before ~a" expected))
       (else (usleep scheduler-sleep-microseconds) (loop))))))

(define (peer-reader-process! client expected-luajit expected-uid expected-gid)
  (unless (and (= (getsockopt client SOL_SOCKET SO_TYPE) SOCK_STREAM)
               (= (vector-ref (getsockname client) 0) AF_UNIX)
               (= (vector-ref (getpeername client) 0) AF_UNIX))
    (fail "UI client is not a connected Unix stream"))
  ;; Guile's Linux SO_PEERCRED integer result is the first struct field: pid.
  (let* ((pid (getsockopt client SOL_SOCKET so-peercred))
         (exe (catch 'system-error
                (lambda () (canonicalize-path
                            (string-append "/proc/" (number->string pid) "/exe")))
                (lambda arguments #f)))
         (status-path (string-append "/proc/" (number->string pid) "/status"))
         (status (and (file-exists? status-path)
                      (call-with-input-file status-path get-string-all))))
    (unless (and (integer? pid) (positive? pid) exe
                  (string=? exe expected-luajit) status
                  (string-contains
                   status
                   (format #f "\nUid:\t~a\t~a\t~a\t~a\n"
                           expected-uid expected-uid expected-uid expected-uid))
                  (string-contains
                   status
                   (format #f "\nGid:\t~a\t~a\t~a\t~a\n"
                           expected-gid expected-gid expected-gid expected-gid)))
      (fail "UI peer is not the exact root KOReader LuaJIT process"))
    pid))

(define (accept-one! listener expected-luajit expected-uid expected-gid)
  (let loop ()
    (when stop-requested? (throw 'book-state-device-stop-requested 'accept))
    (catch #t
      (lambda ()
        (let* ((accepted (accept listener))
               (client (car accepted)))
          (catch #t
            (lambda ()
              (let ((pid (peer-reader-process!
                          client expected-luajit expected-uid expected-gid)))
                (marker "accepted exact KOReader peer pid=~a" pid)
                (adopt-book-ui-control-port! client #:require-character? #f)))
            (lambda (key . arguments)
              (close-port-quietly! client)
              (apply throw key arguments)))))
      (lambda (key . arguments)
        (cond
         (stop-requested?
          (throw 'book-state-device-stop-requested 'accept))
         ((and (eq? key 'system-error)
               (= (system-error-errno arguments) EINTR))
          (loop))
         (else (apply throw key arguments)))))))

(define (run-authority! config)
  (let ((uid (field config 'authority-uid))
        (gid (field config 'authority-gid)))
    (unless (and (integer? uid) (exact? uid) (not (negative? uid))
                 (integer? gid) (exact? gid) (not (negative? gid)))
      (fail "trusted authority UID/GID are invalid"))
    (unless (and (= uid (getuid)) (= gid (getgid)))
      (fail "authority process does not have its compile-fixed identity"))
    (require-private-root! uid))
  (let ((language (field config 'book-language)))
    ;; This is a trusted system-construction choice, never a request field.
    (profile language))
  (when (file-exists? runtime-root)
    (fail "runtime root unexpectedly survived boot/start"))
  (mkdir runtime-root #o700)
  (chmod runtime-root #o700)
  (let ((listener #f) (runtime #f) (runtime-closed? #f) (session-number 0))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! listener (socket AF_UNIX SOCK_STREAM 0))
        (set! active-listener-fd (fileno listener))
        (fcntl (fileno listener) F_SETFD
               (logior (fcntl (fileno listener) F_GETFD) FD_CLOEXEC))
        (bind listener AF_UNIX socket-path)
        (chmod socket-path #o600)
        (listen listener 1)
        (set! runtime (open-reader-state-runtime state-root))
        (marker "ready socket=~a database=~a" socket-path database-path)
        (let loop ()
          (unless stop-requested?
            (let ((control
                   (accept-one! listener (field config 'koreader-luajit)
                                (field config 'authority-uid)
                                (field config 'authority-gid))))
              (dynamic-wind
                (lambda () #t)
                (lambda ()
                  (let ((deadline (+ (now-seconds) interaction-budget-seconds)))
                    (wait-for-ui-event! control deadline 'channel-ready)
                    (wait-for-ui-event! control deadline 'ready)
                    (set! session-number (+ session-number 1))
                    (let ((session-root
                           (string-append runtime-root "/session-"
                                          (number->string session-number))))
                      (mkdir session-root #o700)
                       (run-sandbox-session!
                        runtime control config session-root deadline
                        (field config 'book-language)))))
                (lambda () (close-book-ui-control! control)))
              (loop)))))
      (lambda ()
        (define cleanup-error #f)
        (define (remember-cleanup-error! key arguments)
          (unless cleanup-error (set! cleanup-error (cons key arguments))))
        (when (and runtime (not runtime-closed?))
          (catch #t
            (lambda ()
              (close-reader-state-runtime! runtime)
              (set! runtime-closed? #t))
            (lambda (key . arguments)
              (remember-cleanup-error! key arguments))))
        (close-port-quietly! listener)
        (set! active-listener-fd #f)
        (catch #t
          (lambda ()
            (when (file-exists? socket-path) (delete-file socket-path))
            (when (and (file-exists? runtime-root)
                       (null? (scandir
                               runtime-root
                               (lambda (name) (not (member name '("." "..")))))))
              (rmdir runtime-root)))
          (lambda (key . arguments)
            (remember-cleanup-error! key arguments)))
        (when cleanup-error
          (marker "cleanup failed: ~s" cleanup-error)
          (apply throw (car cleanup-error) (cdr cleanup-error)))))))

(define (book-state-device-main config argv)
  (if (not (null? (cdr argv)))
      2
      (catch #t
        (lambda () (run-authority! config) 0)
        (lambda (key . arguments)
          (if (eq? key 'book-state-device-stop-requested)
              (begin (marker "stopped after bounded cleanup") 0)
              (begin (marker "FAIL: key=~s details=~s" key arguments) 1))))))

(sigaction SIGPIPE SIG_IGN)
(for-each (lambda (signal)
            (sigaction
             signal
             (lambda _
               (set! stop-requested? #t)
               ;; Guile installs restarting handlers, so setting a flag alone
               ;; cannot wake blocking accept(2).  Closing this one owned port
               ;; makes shutdown event-driven without an idle timer.
               (when active-listener-fd
                 ;; shutdown(2), unlike closing the Guile port from its own
                 ;; blocking read, does not contend on the port lock.  Linux
                 ;; wakes accept with EINVAL; accept-one! maps that to the
                 ;; already-recorded stop request.
                 (c-shutdown active-listener-fd 2)))))
          (list SIGINT SIGTERM SIGHUP))
