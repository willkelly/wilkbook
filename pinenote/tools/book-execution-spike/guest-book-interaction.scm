;;; Reader-driven successor to the accepted automatic guest Book Protocol gate.
;;; The fixed KOReader control stream remains trusted and distinct from each
;;; separately donated sandbox Book Protocol socket.
(define-module (guest-book-interaction)
  #:use-module (book-protocol)
  #:use-module (book-session)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (guest-virtio-book-ui)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (private-control)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (guest-book-interaction-main
            run-reader-protocol-pair!))

(define whole-run-timeout-seconds 360.0)
(define host-test-timeout-seconds 15.0)
(define scheduler-sleep-microseconds 5000)
(define control-generation 1)
(define accepted-guest-adapter-sha256
  "eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d")
(define accepted-private-control-sha256
  "1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d")

;; The fixed entrypoint primitive-loads the accepted adapter before this
;; sibling source, exactly as its existing host invocation adapter does.  Do
;; not import (guest-book-protocol) through Guile's module autoloader: the
;; accepted program-file is intentionally loaded as an entry source.
(define %base-module (resolve-module '(guest-book-protocol)))
(define (base-private name) (module-ref %base-module name))
(define %smoke-module (resolve-module '(guest-smoke)))
(define (smoke-private name) (module-ref %smoke-module name))

;; SRFI-9 record bindings are syntax at module lookup time.  Resolve their
;; procedure values lexically from the already primitive-loaded accepted
;; module; do not mistake a syntax transformer returned by module-ref for a
;; callable accessor.
(define %base-record-procedures
  `((make-protocol-peer
     . ,(@@ (guest-book-protocol) make-protocol-peer))
    (protocol-peer-label
     . ,(@@ (guest-book-protocol) protocol-peer-label))
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
    (protocol-peer-actions
     . ,(@@ (guest-book-protocol) protocol-peer-actions))
    (owned-runsc-status
     . ,(@@ (guest-book-protocol) owned-runsc-status))
    (owned-runsc-process-group
     . ,(@@ (guest-book-protocol) owned-runsc-process-group))
    (owned-runsc-finalized?
     . ,(@@ (guest-book-protocol) owned-runsc-finalized?))))

(define (base-record-procedure name)
  (let ((entry (assq name %base-record-procedures)))
    (unless entry (fail "unknown accepted record operation: ~s" name))
    (cdr entry)))

(define-record-type <reader-book-state>
  (make-reader-book-state peer phase index ui-index-base action-envelope
                          committed ticked? book-eof?)
  reader-book-state?
  (peer reader-book-peer)
  (phase reader-book-phase set-reader-book-phase!)
  (index reader-book-index set-reader-book-index!)
  (ui-index-base reader-book-ui-index-base)
  (action-envelope reader-book-action-envelope
                   set-reader-book-action-envelope!)
  (committed reader-book-committed set-reader-book-committed!)
  (ticked? reader-book-ticked? set-reader-book-ticked?!)
  (book-eof? reader-book-eof? set-reader-book-eof?!))

(define (fail message . arguments)
  (throw 'book-execution-reader-interaction-error
         (apply format #f message arguments)))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (snapshot endpoint name)
  (let ((entry (assoc name (host-session-snapshot endpoint))))
    (and entry (cdr entry))))

(define (peer-value peer accessor)
  ((base-record-procedure accessor) peer))

(define (set-peer-value! peer setter value)
  ((base-record-procedure setter) peer value))

(define (child-value child accessor)
  ((base-record-procedure accessor) child))

(define (deadline-check! deadline)
  (when (>= (now-seconds) deadline)
    (fail "reader interaction exceeded its supervisor-owned whole-run deadline")))

(define (assert-ui-book-descriptors-separated! control donation)
  (let ((ui-info (stat (book-ui-control-fd control)))
        (book-info (stat donation)))
    (unless (and (book-ui-control-open? control)
                 (= (logand (fcntl (book-ui-control-fd control) F_GETFD)
                            FD_CLOEXEC)
                    FD_CLOEXEC)
                 (eq? (stat:type book-info) 'socket)
                 (not (and (= (stat:dev ui-info) (stat:dev book-info))
                           (= (stat:ino ui-info) (stat:ino book-info)))))
      (fail "UI control and donated Book Protocol descriptors are not isolated"))))

(define (pump-ui-output! control)
  (let ((result (pump-book-ui-output! control)))
    (when (eq? result 'closed)
      (fail "private UI channel closed with queued output"))
    result))

(define (take-ui-event! control)
  (pump-ui-output! control)
  (let ((event (pump-book-ui-input! control)))
    (when (eq? event 'eof)
      (fail "private UI channel reached EOF while work was pending"))
    (when (eq? event 'closed)
      (fail "private UI channel closed while work was pending"))
    (and (list? event) event)))

(define (require-event! event kind expected-value label)
  (unless (and (list? event)
               (= (length event) 3)
               (eq? (car event) kind)
               (= (cadr event) control-generation)
               (or (eq? expected-value #f)
                   (string=? (caddr event) expected-value)))
    (fail "private UI sent an unexpected ~a event: ~s" label event)))

(define (wait-for-ui-event! control deadline kind expected-value label)
  (let loop ()
    (deadline-check! deadline)
    (let ((event (take-ui-event! control)))
      (if event
          (begin (require-event! event kind expected-value label) event)
          (begin (usleep scheduler-sleep-microseconds) (loop))))))

(define (queue-current-input! state control)
  (let* ((peer (reader-book-peer state))
         (actions (peer-value peer 'protocol-peer-actions))
         (action (list-ref actions (reader-book-index state))))
    (set-reader-book-action-envelope! state #f)
    (set-reader-book-committed! state #f)
    (set-reader-book-ticked?! state #f)
    (queue-book-ui-command! control 'input-update control-generation
                            (cadr action))
    (set-reader-book-phase! state 'await-submit)))

(define (validate-presentation! state value)
  (let* ((peer (reader-book-peer state))
         (endpoint (peer-value peer 'protocol-peer-endpoint))
         (action
          (list-ref (peer-value peer 'protocol-peer-actions)
                    (reader-book-index state)))
         (envelope (reader-book-action-envelope state)))
    (unless (and envelope
                 (presented-text? value)
                 (string=? (presented-text-session-id value)
                           (snapshot endpoint "session_id"))
                 (string=? (presented-text-request-id value)
                           (assoc-ref envelope "request_id"))
                 (string=? (presented-text-action-id value)
                           (assoc-ref envelope "action_id"))
                 (string=? (presented-text-action-id value) (car action))
                 (string=? (presented-text-surface-handle value)
                           (assoc-ref envelope "surface_handle"))
                 (= (presented-text-surface-generation value)
                    (assoc-ref envelope "surface_generation"))
                 (= (presented-text-surface-generation value)
                    control-generation)
                 (= (presented-text-sequence value)
                    (assoc-ref envelope "sequence"))
                 (= (presented-text-sequence value)
                    (+ (reader-book-index state) 1))
                 (string=? (presented-text-value value) (caddr action)))
      (fail "~a returned a presentation outside the exact committed request"
            (peer-value peer 'protocol-peer-label)))
    value))

(define (relay-committed-presentation! state control)
  (let ((value (reader-book-committed state)))
    (unless (and value (reader-book-ticked? state))
      (fail "attempted to relay a result before commit and UI tick"))
    (queue-book-ui-command! control 'present control-generation
                            (presented-text-value value))
    (set-reader-book-phase! state 'await-applied)))

(define (handle-book-commit! state control value)
  (let* ((peer (reader-book-peer state))
         (label (peer-value peer 'protocol-peer-label)))
    (case (reader-book-phase state)
      ((await-hello)
       (unless ((base-private 'exact-initialize?) value)
         (fail "~a did not produce the exact capability initialize envelope"
               label))
       (endpoint-queue-message!
        (peer-value peer 'protocol-peer-endpoint) value)
       (queue-current-input! state control))
      ((await-result)
       (validate-presentation! state value)
       (set-reader-book-committed! state value)
       (if (reader-book-ticked? state)
           (relay-committed-presentation! state control)
           (set-reader-book-phase! state 'await-tick)))
      (else
       (fail "~a committed an unexpected message in reader phase ~a"
             label (reader-book-phase state))))))

(define (handle-book-eof! state)
  (let* ((peer (reader-book-peer state))
         (actions (peer-value peer 'protocol-peer-actions))
         (last-index (- (length actions) 1)))
    (unless (and (= (reader-book-index state) last-index)
                 (reader-book-committed state)
                 (memq (reader-book-phase state)
                       '(await-tick await-applied awaiting-eof)))
      (fail "~a transport closed before both committed presentations"
            (peer-value peer 'protocol-peer-label)))
    (set-reader-book-eof?! state #t)
    (when (eq? (reader-book-phase state) 'awaiting-eof)
      (set-reader-book-phase! state 'done))))

(define (pump-book-input! state control)
  (let* ((peer (reader-book-peer state))
         (endpoint (peer-value peer 'protocol-peer-endpoint)))
    (unless (reader-book-eof? state)
      (when (memq 'input (endpoint-ready-events endpoint))
        (let ((result (endpoint-pump-input! endpoint)))
          (case (endpoint-pump-result-status result)
            ((committed)
             (let ((values (endpoint-pump-result-values result)))
               (unless (= (length values) 1)
                 (fail "book input pump did not commit exactly one value"))
               (handle-book-commit! state control (car values))))
            ((eof closed) (handle-book-eof! state))
            ((would-block interrupted budget) #t)
            ((stale) (fail "live reader Book Session endpoint became stale"))
            (else
             (fail "book input pump returned unknown status: ~s"
                   (endpoint-pump-result-status result)))))))
    (when (> (snapshot endpoint "outbound_frames") 0)
      (let ((result (endpoint-pump-output! endpoint)))
        (unless (memq (endpoint-pump-result-status result)
                      '(drained budget would-block interrupted))
          (fail "book output pump failed: ~s"
                (endpoint-pump-result-status result)))))))

(define (handle-ui-event! state control event)
  (let* ((peer (reader-book-peer state))
         (endpoint (peer-value peer 'protocol-peer-endpoint))
         (actions (peer-value peer 'protocol-peer-actions))
         (action (list-ref actions (reader-book-index state))))
    (case (reader-book-phase state)
      ((await-submit)
       (require-event! event 'submit (cadr action) "submit")
       ;; The trusted guest creates the request only after Lua echoed the exact
       ;; current text.  Lua never supplies language, action, request, surface,
       ;; or endpoint identity.
       (let ((envelope (host-action! endpoint (car action) (cadr action))))
         (unless (and (string=? (assoc-ref envelope "action_id") (car action))
                      (string=? (assoc-ref envelope "text") (cadr action))
                      (= (assoc-ref envelope "surface_generation")
                         control-generation)
                      (= (assoc-ref envelope "sequence")
                         (+ (reader-book-index state) 1)))
           (fail "trusted authority constructed an unexpected action envelope"))
         (set-reader-book-action-envelope! state envelope)
         (endpoint-queue-message! endpoint envelope)
         (set-reader-book-phase! state 'await-result)))
      ((await-result await-tick)
       ;; The value is the Lua fixture's local presentation ordinal, never a
       ;; language or authority identity.
       (require-event!
        event 'tick
        (format #f "qemu-~a"
                (+ (reader-book-ui-index-base state)
                   (reader-book-index state) 1))
        "scheduled UI tick")
       (when (reader-book-ticked? state)
         (fail "private UI repeated the scheduled tick"))
       (set-reader-book-ticked?! state #t)
       (when (reader-book-committed state)
         (relay-committed-presentation! state control)))
      ((await-applied)
       (require-event! event 'applied
                       (presented-text-value (reader-book-committed state))
                       "paint application")
       (if (< (+ (reader-book-index state) 1) (length actions))
           (begin
             (set-reader-book-index! state (+ (reader-book-index state) 1))
             (queue-current-input! state control))
           (if (reader-book-eof? state)
               (set-reader-book-phase! state 'done)
               (set-reader-book-phase! state 'awaiting-eof))))
      (else
       (fail "private UI event arrived in reader phase ~a: ~s"
             (reader-book-phase state) event)))))

(define (assert-closed-reader-result! state)
  (let* ((peer (reader-book-peer state))
         (endpoint (peer-value peer 'protocol-peer-endpoint)))
    (unless (and (eq? (reader-book-phase state) 'done)
                 (reader-book-eof? state)
                 (eq? (snapshot endpoint "state") 'closed)
                 (not (snapshot endpoint "transport_open"))
                 (= (snapshot endpoint "pending_requests") 0)
                 (= (snapshot endpoint "outbound_frames") 0)
                 (= (snapshot endpoint "sequence") 2)
                 (= (snapshot endpoint "retained_terminal_requests") 2))
      (fail "~a did not reach the exact closed reader result state: ~s"
            (peer-value peer 'protocol-peer-label)
            (host-session-snapshot endpoint)))))

(define (run-reader-loop! state control deadline)
  (let* ((peer (reader-book-peer state))
         (child (peer-value peer 'protocol-peer-child)))
    (let loop ()
      (deadline-check! deadline)
      (pump-ui-output! control)
      (pump-book-input! state control)
      (let ((event (take-ui-event! control)))
        (when event (handle-ui-event! state control event)))
      ((base-private 'reap-owned-runsc!) child)
      (let ((status (child-value child 'owned-runsc-status)))
        (when (and status (not (equal? status '(exit . 0))))
          (fail "~a runsc process failed: ~s"
                (peer-value peer 'protocol-peer-label) status))
        (if (and (eq? (reader-book-phase state) 'done)
                 (equal? status '(exit . 0))
                 (not ((base-private 'process-group-exists?)
                       (child-value child 'owned-runsc-process-group))))
            (assert-closed-reader-result! state)
            (begin
              ((base-private 'pump-owned-captures!)
               child scheduler-sleep-microseconds)
              (loop)))))))

(define (revoke-active-peer! peer)
  (when peer
    (let ((endpoint (peer-value peer 'protocol-peer-endpoint)))
      (when (eq? (snapshot endpoint "state") 'active)
        (revoke-surface! endpoint)))))

(define* (run-one-reader-book!
          host control label actions ui-index-base bundle container-id deadline
          evidence-mode runtime-override diagnostic-wrapper cgroup-preflight
          post-store-check marker-emitter marker)
  (let ((peer #f)
        (state #f)
        (result #f)
        (observations #f)
        (runtime-state-owner #f)
        (runtime-cleaned? #f)
        (runtime-state-evidence-emitted? #f)
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
              (unless runtime-state-evidence-emitted?
                ((base-private 'emit-runtime-state-diagnostics)
                 bundle container-id)
                (set! runtime-state-evidence-emitted? #t))
              ((base-private 'cleanup-owned-runtime-state!)
               runtime-state-owner container-id))
            ((base-private 'assert-runtime-state-clean!) bundle container-id))))
    (diagnostic-wrapper
     bundle
     (lambda (stores)
       (catch #t
         (lambda ()
           (when (eq? evidence-mode 'guest-runsc)
             (set! runtime-state-owner
                   ((base-private 'prepare-owned-runtime-state!)
                    bundle container-id)))
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (call-with-values
                   (lambda () (open-session-endpoint! host label))
                 (lambda (endpoint donation)
                   (set! peer
                         ((base-record-procedure 'make-protocol-peer)
                          label endpoint donation #f 'hello actions 0))))
               (cgroup-preflight container-id)
               (call-with-values
                   (lambda ()
                     ((base-private 'read-launch-record)
                      bundle label container-id))
                 (lambda (fixed-argv environment)
                   (let* ((argv
                           ((base-private 'replace-runtime-for-host-test)
                            fixed-argv runtime-override evidence-mode))
                          (donation (peer-value peer 'protocol-peer-donation))
                          (donation-identity (stat donation))
                          (stdout (string-append bundle "/runsc.stdout"))
                          (stderr (string-append bundle "/runsc.stderr"))
                          (record (string-append bundle "/runsc.pid")))
                     (assert-ui-book-descriptors-separated! control donation)
                     (set-peer-value!
                      peer 'set-protocol-peer-child!
                      ((base-private 'spawn-owned-runsc)
                       label record donation argv environment bundle stdout stderr))
                     ;; The accepted child path closes every descriptor above
                     ;; three and then requires exactly FDs 0,1,2,3 with FD 3
                     ;; a Unix socket.  The UI descriptor remains CLOEXEC and
                     ;; authority-owned here; it cannot reach runsc.
                     ((base-private 'close-port-quietly!) donation)
                     (set-peer-value! peer 'set-protocol-peer-donation! #f)
                     ((base-private 'assert-parent-authority-only!)
                      peer donation-identity)
                     (set! state
                           (make-reader-book-state peer 'await-hello 0
                                                   ui-index-base #f #f #f #f))
                     (run-reader-loop! state control deadline)
                     (set! completed? #t)))))
             (lambda ()
               (unless completed? (revoke-active-peer! peer))
               ((base-private 'release-peer!) peer)))
           (set! result
                 ((base-private 'capture-result)
                  (peer-value peer 'protocol-peer-child)))
           (unless (equal?
                    (child-value (peer-value peer 'protocol-peer-child)
                                 'owned-runsc-status)
                    '(exit . 0))
             (fail "~a runsc did not exit zero" label))
           (when ((base-private 'capture-overflow?) result)
             (fail "~a capture overflow: ~a" label
                   ((base-private 'capture-overflow-summary) result)))
           (cleanup-runtime-once!)
           (when (pair? stores)
             (set! observations
                   ((smoke-private 'observe-diagnostic-stores) stores))
             (when ((smoke-private 'diagnostic-stores-overflow?) observations)
               (fail "~a exhausted a bounded diagnostic store" label)))
           (emit-store-evidence-once! stores #f))
         (lambda (key . arguments)
           (when (and peer (peer-value peer 'protocol-peer-child)
                      (child-value (peer-value peer 'protocol-peer-child)
                                   'owned-runsc-finalized?))
             (set! result
                   ((base-private 'capture-result)
                    (peer-value peer 'protocol-peer-child))))
           ;; UI loss after launch uses the same exact runsc/cgroup/null-netns
           ;; cleanup as success.  Any ownership mismatch remains fatal rather
           ;; than being recursively removed.
           (when (or runtime-state-owner
                     (and peer (peer-value peer 'protocol-peer-child)))
             (cleanup-runtime-once!))
           (emit-store-evidence-once! stores #t)
           (when (and (eq? evidence-mode 'guest-runsc) result)
             ((base-private 'emit-runtime-failure-diagnostics)
              bundle container-id result))
           (apply throw key arguments)))))
    (post-store-check bundle)
    (when (eq? evidence-mode 'guest-runsc)
      (marker-emitter marker))))

(define* (run-reader-protocol-pair!
          control guile-bundle python-bundle
          #:key
          (evidence-mode 'guest-runsc)
          (runtime-override #f)
          (deadline
           (+ (now-seconds)
              (if (eq? evidence-mode 'guest-runsc)
                  whole-run-timeout-seconds host-test-timeout-seconds)))
          (diagnostic-wrapper
           (if (eq? evidence-mode 'guest-runsc)
               (smoke-private 'call-with-diagnostic-stores)
               (lambda (_bundle thunk) (thunk '()))))
          (cgroup-preflight
           (if (eq? evidence-mode 'guest-runsc)
               (base-private 'assert-cgroup2-preflight!)
               (lambda (_container-id) #t)))
          (post-store-check
           (if (eq? evidence-mode 'guest-runsc)
               (base-private 'assert-diagnostic-stores-unmounted!)
               (lambda (_bundle) #t)))
          (marker-emitter
           (if (eq? evidence-mode 'guest-runsc)
               (smoke-private 'emit)
               (lambda (_marker) #t))))
  (unless (and (book-ui-control? control)
               (book-ui-control-open? control)
               (number? deadline)
               (> deadline (now-seconds)))
    (fail "reader protocol pair requires a live bounded UI control"))
  (when (and (eq? evidence-mode 'guest-runsc)
             (not (module-ref %base-module 'source-provenance-checked?)))
    (fail "guest reader evidence requires checked source/profile provenance"))
  (wait-for-ui-event! control deadline 'ready "dialog" "reader readiness")
  (let ((host (make-book-session-host))
        (guile-actions
         ((base-private 'make-nonce-actions)
          (module-ref %base-module 'guile-action-specs) "g"
          (base-private 'guile-computed-text)))
        (python-actions
         ((base-private 'make-nonce-actions)
          (module-ref %base-module 'python-action-specs) "p"
          (base-private 'python-computed-text))))
    (run-one-reader-book!
     host control "guile" guile-actions 0 guile-bundle
     "wilkbook-guile-book-protocol" deadline evidence-mode runtime-override
     diagnostic-wrapper cgroup-preflight post-store-check marker-emitter
     "BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS")
    (run-one-reader-book!
     host control "python" python-actions 2 python-bundle
     "wilkbook-python-book-protocol" deadline evidence-mode runtime-override
     diagnostic-wrapper cgroup-preflight post-store-check marker-emitter
     "BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS")
    #t))

(define (file-sha256-string path)
  (bytevector->base16-string (file-sha256 path)))

(define (assert-file-sha256! label path expected)
  (unless (and (string? path)
               (eq? (stat:type (stat path)) 'regular)
               (= (string-length expected) 64)
               (string=? (file-sha256-string path) expected))
    (fail "immutable reader source provenance mismatch: ~a" label)))

(define (assert-reader-source-provenance!
         profile closure-file guest-smoke base-oci protocol-oci guest-adapter
         guile-book python-book guile-protocol blocking-protocol python-protocol
         book-session private-control-source ui-adapter reader-adapter
         expected-ui-adapter-sha256 expected-reader-adapter-sha256)
  ((base-private 'assert-source-provenance!)
   profile closure-file guest-smoke base-oci protocol-oci guest-adapter
   accepted-guest-adapter-sha256 guile-book python-book guile-protocol
   blocking-protocol python-protocol book-session)
  (assert-file-sha256! "private-control.scm" private-control-source
                       accepted-private-control-sha256)
  (assert-file-sha256! "guest-virtio-book-ui.scm" ui-adapter
                       expected-ui-adapter-sha256)
  (assert-file-sha256! "guest-book-interaction.scm" reader-adapter
                       expected-reader-adapter-sha256))

(define (wait-for-ui-completion! control deadline)
  (let ((finish-ticket
         (queue-book-ui-command! control 'finish control-generation "")))
    ;; A queued frame is not a sent frame.  While this exact ticket is pending,
    ;; interleave bounded output and input pumps so a prequeued DONE or EOF is
    ;; rejected rather than accepted after EOF invalidation clears the queue.
    (let flush-finish ()
      (deadline-check! deadline)
      (pump-ui-output! control)
      (unless (book-ui-command-delivered? control finish-ticket)
        (let ((event (pump-book-ui-input! control)))
          (cond
           ((eq? event 'eof)
            (fail "private UI reached EOF before finish was delivered"))
           ((eq? event 'closed)
            (fail "private UI closed before finish was delivered"))
           ((list? event)
            (fail "private UI sent an event before finish was delivered: ~s"
                  event))
           (else
            (usleep scheduler-sleep-microseconds)
            (flush-finish)))))))
  (wait-for-ui-event! control deadline 'done "ok" "reader completion")
  ;; DONE is only an acknowledgement.  The native reader must then remove its
  ;; source, close its exact FD, and expose transport EOF before guest PASS.
  (let loop ()
    (deadline-check! deadline)
    (pump-ui-output! control)
    (let ((event (pump-book-ui-input! control)))
      (cond
       ((eq? event 'eof) #t)
       ((list? event)
        (fail "private UI emitted an event after done: ~s" event))
       ((eq? event 'closed)
        (fail "private UI closed without EOF after done"))
       (else (usleep scheduler-sleep-microseconds) (loop))))))

(define (run-guest arguments)
  (match arguments
    ((base-oci-source protocol-oci-source profile closure-file
      guile-book python-book guile-protocol blocking-protocol python-protocol
      guest-smoke book-session guest-adapter private-control-source ui-adapter
      reader-adapter expected-ui-adapter-sha256
      expected-reader-adapter-sha256 expected-kernel-release)
     (define work-root "/run/wilkbook-book-reader-interaction-gate")
     (define guile-bundle (string-append work-root "/guile"))
     (define python-bundle (string-append work-root "/python"))
     (define deadline (+ (now-seconds) whole-run-timeout-seconds))
     (define control #f)
     (when ((base-private 'lstat-or-false) work-root)
       (fail "refusing stale guest reader work root: ~a" work-root))
     (mkdir work-root #o700)
     (chmod work-root #o700)
     (dynamic-wind
       (lambda () #t)
       (lambda ()
         (assert-reader-source-provenance!
          profile closure-file guest-smoke base-oci-source protocol-oci-source
          guest-adapter guile-book python-book guile-protocol blocking-protocol
          python-protocol book-session private-control-source ui-adapter
          reader-adapter expected-ui-adapter-sha256
          expected-reader-adapter-sha256)
         ((smoke-private 'emit)
          "BOOKEXEC-READER-PROTOCOL-SOURCE-PROVENANCE-PASS")
         ((smoke-private 'assert-kernel) expected-kernel-release)
         ((smoke-private 'assert-host-boundaries))
         ((smoke-private 'assert-sidecar-layout))
         ((smoke-private 'run-version) work-root)
         ((base-private 'run-protocol-self-tests!))
         ((smoke-private 'emit)
          "BOOKEXEC-READER-PROTOCOL-SCHEMA-REJECTION-PASS")
         ((smoke-private 'emit)
          "BOOKEXEC-READER-PROTOCOL-STALE-REJECTION-PASS")
         ((smoke-private 'emit)
          "BOOKEXEC-READER-PROTOCOL-TRUNCATED-CLOSE-PASS")
         (primitive-load base-oci-source)
         (primitive-load protocol-oci-source)
         (let* ((closure ((base-private 'read-language-closure) closure-file))
                (module (resolve-module '(oci-book-bundle)))
                (generate-guile
                 (module-ref module 'generate-guile-protocol-bundle))
                (generate-python
                 (module-ref module 'generate-python-protocol-bundle)))
           (generate-guile
            #:profile-input profile
            #:book-entry-input guile-book
            #:protocol-input guile-protocol
            #:blocking-input blocking-protocol
            #:bundle-input guile-bundle
            #:container-id "wilkbook-guile-book-protocol"
            #:requisites-runner (lambda (_profile) closure))
           (generate-python
            #:profile-input profile
            #:book-entry-input python-book
            #:protocol-input python-protocol
            #:bundle-input python-bundle
            #:container-id "wilkbook-python-book-protocol"
            #:requisites-runner (lambda (_profile) closure)))
         (set! control (open-book-ui-control! deadline))
         (run-reader-protocol-pair! control guile-bundle python-bundle
                                    #:deadline deadline)
         (for-each
          (lambda (container-id)
            (when ((base-private 'lstat-or-false)
                   (string-append "/sys/fs/cgroup/wilkbook-execution-"
                                  container-id))
              (fail "final reader cgroup teardown check failed: ~a"
                    container-id)))
          '("wilkbook-guile-book-protocol"
            "wilkbook-python-book-protocol"))
         ((smoke-private 'emit)
          "BOOKEXEC-READER-PROTOCOL-CGROUP-TEARDOWN-PASS")
         (wait-for-ui-completion! control deadline)
         ((smoke-private 'emit) "BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS")
         ((smoke-private 'emit) "BOOKEXEC-READER-PROTOCOL-PASS")
         0)
       (lambda () (close-book-ui-control! control))))
    (_
     (fail "expected BASE-OCI PROTOCOL-OCI PROFILE CLOSURE GUILE-BOOK PYTHON-BOOK GUILE-PROTOCOL BLOCKING-PROTOCOL PYTHON-PROTOCOL GUEST-SMOKE BOOK-SESSION ACCEPTED-GUEST-ADAPTER PRIVATE-CONTROL UI-ADAPTER READER-ADAPTER UI-ADAPTER-SHA256 READER-ADAPTER-SHA256 KERNEL-RELEASE"))))

(define (guest-book-interaction-main argv)
  (catch #t
    (lambda () (run-guest (cdr argv)))
    (lambda (key . arguments)
      (catch #t
        (lambda ()
          ((smoke-private 'emit)
           (format #f "BOOKEXEC-READER-PROTOCOL-FAIL ~a ~s"
                   key arguments)))
        (lambda secondary #f))
      1)))

(sigaction SIGPIPE SIG_IGN)
