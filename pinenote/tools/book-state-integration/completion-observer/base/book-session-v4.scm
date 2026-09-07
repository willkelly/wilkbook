;;; Guile authority for the experimental one-surface Book Session contract.
(define-module (book-session)
  #:use-module (book-protocol)
  #:use-module (book-state-protocol)
  #:use-module (book-state-session-delegate)
  #:use-module (gcrypt random)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (protocol-version
            max-sessions
            max-live-handles
            max-pending-requests
            max-terminal-requests
            max-peer-message-members
            max-opaque-id-bytes
            max-action-text-bytes
            max-present-text-bytes
            max-surface-generation
            max-sequence
            present-item-count
            max-input-bytes-per-pump
            max-input-frames-per-pump
            max-output-bytes-per-pump
            max-output-frames-per-pump
            max-outbound-frames
            max-outbound-bytes
            make-book-session-host
            make-book-session-host-with-state
            book-session-host?
            open-session-endpoint!
            session-endpoint?
            session-endpoint-diagnostic-name
            endpoint-ready-events
            endpoint-pump-input!
            endpoint-queue-message!
            endpoint-pump-output!
            endpoint-pump-result?
            endpoint-pump-result-status
            endpoint-pump-result-bytes
            endpoint-pump-result-frames
            endpoint-pump-result-values
            release-session-endpoint!
            restart-session!
            host-action!
            cancel-request!
            expire-request!
            navigate!
            revoke-surface!
            close-session!
            host-initial-grants
            host-session-snapshot
            surface-grant?
            surface-grant-handle
            surface-grant-generation
            initial-grant-envelope?
            initial-grant-envelope-surface
            presented-text?
            presented-text-session-id
            presented-text-request-id
            presented-text-action-id
            presented-text-surface-handle
            presented-text-surface-generation
            presented-text-sequence
            presented-text-value))

(define protocol-version 1)
(define max-sessions 8)
(define max-live-handles 1)
(define max-pending-requests 4)
(define max-terminal-requests 8)
(define max-peer-message-members 8)
(define max-field-name-characters 24)
(define max-opaque-id-bytes 96)
(define max-action-text-bytes 2048)
(define max-present-text-bytes 4096)
(define max-surface-generation 1000000)
(define max-sequence 1000000)
(define present-item-count 1)
(define max-input-bytes-per-pump 4096)
(define max-input-frames-per-pump 1)
(define max-output-bytes-per-pump 4096)
(define max-output-frames-per-pump 4)
(define max-outbound-frames 8)
(define max-outbound-bytes (* max-outbound-frames (+ max-frame-size 4)))
(define max-inbound-bytes (+ max-frame-size 4 max-input-bytes-per-pump))
;; guile-json's pinned Unicode mode emits a C0 byte such as NUL as six ASCII
;; bytes ("\\u0000").  A protocol-valid 4096-byte text can therefore expand
;; by 6x.  The largest worker response is STATE-VALUE with PRESENT=true and the
;; largest safe state version.  Its compact JSON has 101 fixed payload bytes,
;; including the empty quotes around TEXT; framing adds four more bytes.
(define max-json-bytes-per-state-text-byte 6)
(define max-state-value-fixed-payload-bytes 101)
(define max-state-outbound-frame-bytes
  (+ 4 max-state-value-fixed-payload-bytes
     (* max-json-bytes-per-state-text-byte max-state-text-bytes)))
(define linux-msg-nosignal #x4000)

(define (session-error kind message)
  (throw 'book-session-error kind message))

;; Keep the local reservation honest if either the state schema or the generic
;; codec bound changes.  One response must fit one codec frame and the complete
;; bounded output queue; reserving more would reject every valid state request.
(unless (and (<= max-state-outbound-frame-bytes (+ max-frame-size 4))
             (<= max-state-outbound-frame-bytes max-outbound-bytes))
  (session-error 'state "state response reservation exceeds output bounds"))

;; Private and parameterized only so tests can inject allocation failure and a
;; cooperative callback.  Normal authority always uses libgcrypt strong random.
(define random-token-source
  (make-parameter (lambda () (random-token 18 'strong))))

(define-record-type <surface-grant>
  (%make-surface-grant handle generation)
  surface-grant?
  (handle %surface-grant-handle)
  (generation surface-grant-generation))

(define (surface-grant-handle grant)
  (string-copy (%surface-grant-handle grant)))

(define-record-type <initial-grant-envelope>
  (%make-initial-grant-envelope surface)
  initial-grant-envelope?
  (surface initial-grant-envelope-surface))

(define-record-type <presented-text>
  (%make-presented-text session-id request-id action-id surface-handle
                        generation sequence value)
  presented-text?
  (session-id %presented-text-session-id)
  (request-id %presented-text-request-id)
  (action-id %presented-text-action-id)
  (surface-handle %presented-text-surface-handle)
  (generation presented-text-surface-generation)
  (sequence presented-text-sequence)
  (value %presented-text-value))

(define (presented-text-session-id value)
  (string-copy (%presented-text-session-id value)))
(define (presented-text-request-id value)
  (string-copy (%presented-text-request-id value)))
(define (presented-text-action-id value)
  (string-copy (%presented-text-action-id value)))
(define (presented-text-surface-handle value)
  (string-copy (%presented-text-surface-handle value)))
(define (presented-text-value value)
  (string-copy (%presented-text-value value)))

(define (copy-dispatch-result value)
  (cond
   ((presented-text? value)
    (%make-presented-text
     (presented-text-session-id value)
     (presented-text-request-id value)
     (presented-text-action-id value)
     (presented-text-surface-handle value)
     (presented-text-surface-generation value)
     (presented-text-sequence value)
     (presented-text-value value)))
   ((string? value) (string-copy value))
   ((pair? value)
    (cons (copy-dispatch-result (car value))
          (copy-dispatch-result (cdr value))))
   (else value)))

(define-record-type <pending-request>
  (%make-pending-request id action-id surface-handle generation sequence
                         binding-identity)
  pending-request?
  (id pending-request-id)
  (action-id pending-request-action-id)
  (surface-handle pending-request-surface-handle)
  (generation pending-request-generation)
  (sequence pending-request-sequence)
  (binding-identity pending-request-binding-identity))

(define-record-type <session>
  (%make-session id surface-handle generation sequence state pending terminal
                 initial-grants)
  session?
  (id session-id)
  (surface-handle session-surface-handle)
  (generation session-generation set-session-generation!)
  (sequence session-sequence set-session-sequence!)
  (state session-state set-session-state!)
  (pending session-pending set-session-pending!)
  (terminal session-terminal set-session-terminal!)
  (initial-grants session-initial-grants))

;; BINDING and its socket are created together and are never selected by a
;; decoded message or supplied separately to dispatch.
(define-record-type <endpoint-binding>
  (%make-endpoint-binding identity socket diagnostic-name)
  endpoint-binding?
  (identity endpoint-binding-identity)
  (socket endpoint-binding-socket)
  (diagnostic-name endpoint-binding-diagnostic-name))

(define-record-type <session-endpoint>
  (%make-session-endpoint host binding session mutex input-owner output-owner
                          input-buffer output-queue output-bytes transport-open?
                          state-delegate)
  session-endpoint?
  (host session-endpoint-host)
  (binding session-endpoint-binding)
  (session session-endpoint-session)
  (mutex session-endpoint-mutex)
  (input-owner endpoint-input-owner set-endpoint-input-owner!)
  (output-owner endpoint-output-owner set-endpoint-output-owner!)
  (input-buffer endpoint-input-buffer set-endpoint-input-buffer!)
  (output-queue endpoint-output-queue set-endpoint-output-queue!)
  (output-bytes endpoint-output-bytes set-endpoint-output-bytes!)
  (transport-open? endpoint-transport-open?
                   set-endpoint-transport-open!)
  (state-delegate endpoint-state-delegate set-endpoint-state-delegate!))

(define-record-type <outbound-frame>
  (%make-outbound-frame bytes offset)
  outbound-frame?
  (bytes outbound-frame-bytes)
  (offset outbound-frame-offset set-outbound-frame-offset!))

(define-record-type <endpoint-pump-result>
  (%make-endpoint-pump-result status bytes frames values)
  endpoint-pump-result?
  (status endpoint-pump-result-status)
  (bytes endpoint-pump-result-bytes)
  (frames endpoint-pump-result-frames)
  (values %endpoint-pump-result-values))

(define (endpoint-pump-result-values result)
  (map copy-dispatch-result (%endpoint-pump-result-values result)))

(define-record-type <book-session-host>
  (%make-book-session-host endpoints mutex state-delegate-factory)
  book-session-host?
  (endpoints host-endpoints set-host-endpoints!)
  (mutex host-mutex)
  (state-delegate-factory host-state-delegate-factory))

(define (make-book-session-host)
  (%make-book-session-host '() (make-mutex) #f))

(define (make-book-session-host-with-state factory)
  (unless (book-state-delegate-factory? factory)
    (session-error 'state "typed Book State delegate factory required"))
  (%make-book-session-host '() (make-mutex) factory))

;; The endpoint records and cleanup shape follow the small conventions in the
;; pinned Shepherd 1.0.9 'endpoints.scm' and Guix e343ff0 'inferior.scm': make
;; socket ownership explicit, create SOCK_CLOEXEC pairs together, and close all
;; acquired descriptors on exceptional exits.  Shepherd's daemon uses Fibers
;; readiness operations; herd is its blocking control client.  This module
;; deliberately imports neither model: its supervisor-facing owner is a
;; bounded EAGAIN pump and never performs socket I/O under an authority mutex.

;; Only the raw-payload decoder constructs this record.  Session dispatch can
;; therefore never receive guile-json's normalized 1.0 as caller-supplied data.
(define-record-type <peer-message>
  (%make-peer-message kind value)
  peer-message?
  (kind peer-message-kind)
  (value peer-message-value))

(define (with-transition-owner mutex thunk)
  (when (eq? (mutex-owner mutex) (current-thread))
    (session-error 'busy "reentrant Book Session transition rejected"))
  (dynamic-wind
    (lambda () (lock-mutex mutex))
    thunk
    (lambda () (unlock-mutex mutex))))

(define (with-endpoint-owner endpoint thunk)
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  (with-transition-owner (session-endpoint-mutex endpoint) thunk))

(define (with-host-owner host thunk)
  (unless (book-session-host? host)
    (error "Book Session host record required"))
  (with-transition-owner (host-mutex host) thunk))

(define (json-whitespace? character)
  (memv character '(#\space #\tab #\newline #\return)))

(define (skip-json-whitespace text start)
  (let ((length (string-length text)))
    (let loop ((index start))
      (if (and (< index length) (json-whitespace? (string-ref text index)))
          (loop (+ index 1))
          index))))

(define (scan-string-end text start)
  ;; decode-payload already accepted TEXT; this pass finds only token endpoints.
  (let ((length (string-length text)))
    (let loop ((index start) (escaped? #f))
      (when (= index length)
        (session-error 'schema "string endpoint missing after JSON validation"))
      (let ((character (string-ref text index)))
        (cond
         (escaped? (loop (+ index 1) #f))
         ((char=? character #\\) (loop (+ index 1) #t))
         ((char=? character #\") (+ index 1))
         (else (loop (+ index 1) #f)))))))

(define (scan-number-end text start)
  (let ((length (string-length text)))
    (let loop ((index start))
      (if (or (= index length)
              (json-whitespace? (string-ref text index))
              (memv (string-ref text index) '(#\, #\})))
          index
          (loop (+ index 1))))))

(define (lexical-integer-token? text start end)
  ;; Number grammar is the accepted generic codec's responsibility.
  (let loop ((index start))
    (or (= index end)
        (and (not (memv (string-ref text index) '(#\. #\e #\E)))
             (loop (+ index 1))))))

(define (scalar-token-evidence text entries)
  ;; This is not a second JSON parser.  decode-payload has validated the whole
  ;; object, schema-shape! has limited values to scalars, and #:ordered #t lets
  ;; raw members use the corresponding decoded key even when keys are escaped.
  (let* ((length (string-length text))
         (object-start (skip-json-whitespace text 0)))
    (unless (and (< object-start length)
                 (char=? (string-ref text object-start) #\{))
      (session-error 'schema "peer message is not a JSON object"))
    (let loop ((index (+ object-start 1))
               (remaining entries)
               (evidence '()))
      (if (null? remaining)
          (let ((end (skip-json-whitespace text index)))
            (unless (= end length)
              (session-error 'schema "trailing scalar evidence data"))
            (reverse evidence))
          (let* ((key-start (skip-json-whitespace text index))
                 (key-end (scan-string-end text (+ key-start 1)))
                 (colon (skip-json-whitespace text key-end))
                 (value-start (skip-json-whitespace text (+ colon 1)))
                 (decoded-value (cdar remaining)))
            (unless (and (< key-start length)
                         (char=? (string-ref text key-start) #\")
                         (< colon length)
                         (char=? (string-ref text colon) #\:))
              (session-error 'schema "scalar evidence disagrees with object"))
            (let* ((string-value? (string? decoded-value))
                   (value-end
                    (if string-value?
                        (begin
                          (unless (and (< value-start length)
                                       (char=? (string-ref text value-start) #\"))
                            (session-error
                             'schema "string evidence disagrees with value"))
                          (scan-string-end text (+ value-start 1)))
                        (scan-number-end text value-start)))
                   (kind
                    (cond
                     (string-value? 'string)
                     ((lexical-integer-token? text value-start value-end)
                      'integer)
                     (else 'number)))
                   (delimiter (skip-json-whitespace text value-end))
                   (last? (null? (cdr remaining))))
              (unless (and (< delimiter length)
                           (char=? (string-ref text delimiter)
                                   (if last? #\} #\,)))
                (session-error 'schema "scalar evidence order mismatch"))
              (loop (+ delimiter 1)
                    (cdr remaining)
                    (cons (cons (caar remaining) kind) evidence))))))))

(define (bounded-object-size entries)
  (let loop ((remaining entries) (count 0))
    (cond
     ((null? remaining) count)
     ((>= count max-peer-message-members)
      (session-error 'schema "peer message has too many members"))
     (else (loop (cdr remaining) (+ count 1))))))

(define (exact-fields! message expected)
  (let ((count (bounded-object-size message)))
    (unless (= count (length expected))
      (session-error 'schema "peer message fields do not match exact schema"))
    (for-each
     (lambda (entry)
       (let ((key (car entry)))
         (unless (and (string? key)
                      (<= (string-length key) max-field-name-characters)
                      (member key expected string=?))
           (session-error 'schema "unknown or invalid peer message field"))))
     message)
    (for-each
     (lambda (key)
       (unless (assoc key message)
         (session-error 'schema "peer message is missing a required field")))
     expected)))

(define (field message name)
  (cdr (assoc name message)))

(define (bounded-string! name value maximum-bytes)
  (unless (string? value)
    (session-error 'schema (string-append name " must be a string")))
  (when (zero? (string-length value))
    (session-error 'schema (string-append name " must not be empty")))
  (when (or (> (string-length value) maximum-bytes)
            (> (bytevector-length (string->utf8 value)) maximum-bytes))
    (session-error 'schema (string-append name " exceeds its byte limit")))
  value)

(define (integer-shape! name value)
  (unless (and (number? value) (exact? value) (integer? value))
    (session-error 'schema
                   (string-append name " must be a lexical JSON integer"))))

(define (bounded-integer! name value minimum maximum evidence)
  (integer-shape! name value)
  (unless (eq? (assoc-ref evidence name) 'integer)
    (session-error 'schema
                   (string-append name " must be a lexical JSON integer")))
  (unless (<= (- max-safe-integer) value max-safe-integer)
    (session-error 'schema (string-append name " is not a safe integer")))
  (unless (<= minimum value maximum)
    (session-error 'schema (string-append name " is outside its field range")))
  value)

(define hello-fields '("type" "version"))
(define present-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "count" "text"))

(define (schema-shape! message)
  (bounded-object-size message)
  (let ((type-entry (assoc "type" message)))
    (unless type-entry
      (session-error 'schema "peer message has no type"))
    (let ((type (bounded-string! "type" (cdr type-entry) 16)))
      (cond
       ((string=? type "hello")
        (exact-fields! message hello-fields)
        (integer-shape! "version" (field message "version")))
       ((string=? type "present")
        (exact-fields! message present-fields)
        (for-each
         (lambda (name)
           (bounded-string! name (field message name) max-opaque-id-bytes))
         '("request_id" "action_id" "surface_handle"))
        (for-each
         (lambda (name) (integer-shape! name (field message name)))
         '("surface_generation" "sequence" "count"))
        (bounded-string! "text" (field message "text") max-present-text-bytes))
       (else
        (session-error 'schema "peer cannot send this message type"))))))

(define (validate-message! message evidence)
  (if (string=? (field message "type") "hello")
      (bounded-integer! "version" (field message "version")
                        protocol-version protocol-version evidence)
      (begin
        (bounded-integer! "surface_generation"
                          (field message "surface_generation")
                          1 max-surface-generation evidence)
        (bounded-integer! "sequence" (field message "sequence")
                          1 max-sequence evidence)
        (bounded-integer! "count" (field message "count")
                          present-item-count present-item-count evidence))))

(define (state-type-name? value)
  (and (string? value)
       (or (string=? value "state-ready")
           (string=? value "state-read")
           (string=? value "state-value")
           (string=? value "state-commit")
           (string=? value "state-committed")
           (string=? value "state-conflict")
           (string=? value "state-commit-failed"))))

(define (decode-peer-payload payload)
  (let* ((message (decode-payload payload))
         (type-entry (and (pair? message) (assoc "type" message)))
         (type (and type-entry (cdr type-entry))))
    (if (state-type-name? type)
        ;; The accepted state decoder owns all seven exact state shapes and
        ;; direction checks.  Only STATE-READ/STATE-COMMIT survive this inbound
        ;; direction; no generic Book Session JSON method is introduced.
        (%make-peer-message
         'state (decode-book-state-session-payload payload))
        (let ((text (utf8->string payload)))
          (schema-shape! message)
          (let ((evidence (scalar-token-evidence text message)))
            (validate-message! message evidence)
            (%make-peer-message 'surface message))))))

;; Private scheduling hook: tests pause after complete decoding to prove that
;; close/restart invalidation wins before dispatch.  It is called without a
;; mutex held and is the identity procedure in the runtime.
(define decoded-message-hook (make-parameter (lambda (endpoint message) #t)))
(define send-attempt-hook (make-parameter (lambda (endpoint bytes) #t)))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(define (bytevector-append left right)
  (let* ((left-length (bytevector-length left))
         (right-length (bytevector-length right))
         (result (make-bytevector (+ left-length right-length))))
    (bytevector-copy! left 0 result 0 left-length)
    (bytevector-copy! right 0 result left-length right-length)
    result))

(define (string-member? value values)
  (any (lambda (candidate) (string=? value candidate)) values))

(define (new-opaque prefix forbidden)
  (let loop ((attempts 0))
    (when (= attempts 8)
      (session-error 'state "could not allocate a fresh opaque identifier"))
    (let ((token ((random-token-source))))
      (unless (and (string? token)
                   (<= (string-length token) max-opaque-id-bytes))
        (session-error 'state "CSPRNG returned an invalid token"))
      (let ((value (string-append prefix "_" token)))
        (if (or (> (bytevector-length (string->utf8 value))
                   max-opaque-id-bytes)
                (string-member? value forbidden))
            (loop (+ attempts 1))
            value)))))

(define (new-session forbidden)
  (let* ((id (new-opaque "session" forbidden))
         (handle (new-opaque "surface" (cons id forbidden)))
         (grant (%make-surface-grant handle 1)))
    (%make-session id handle 1 0 'awaiting-hello '() '()
                   (%make-initial-grant-envelope grant))))

(define (host-forbidden-ids host)
  (append-map
   (lambda (endpoint)
     (let ((session (session-endpoint-session endpoint)))
       (list (session-id session) (session-surface-handle session))))
   (host-endpoints host)))

(define (make-registered-endpoint host socket diagnostic-name session)
  (let ((binding (%make-endpoint-binding
                  (cons 'book-session-endpoint 'identity) socket
                  (string-copy diagnostic-name))))
    (%make-session-endpoint host binding session (make-mutex)
                            #f #f (make-bytevector 0) '() 0 #t #f)))

(define (attach-state-delegate! endpoint)
  ;; The endpoint is not returned to a caller until this finishes.  Grant
  ;; creation and worker construction happen without host/endpoint mutexes.
  (let ((factory
         (host-state-delegate-factory (session-endpoint-host endpoint))))
    (when factory
      (let* ((identity
              (endpoint-binding-identity
               (session-endpoint-binding endpoint)))
             (delegate
              (open-book-state-session-delegate factory identity)))
        (catch #t
          (lambda ()
            (start-book-state-session-delegate!
             delegate
             (lambda (completed-delegate operation outcome value)
               (complete-state-backend-task!
                endpoint identity completed-delegate operation outcome value)))
            (with-endpoint-owner
             endpoint
             (lambda ()
               (unless (and (endpoint-current? endpoint identity)
                            (not (endpoint-state-delegate endpoint)))
                 (session-error 'state
                                "endpoint changed before state attachment"))
               (set-endpoint-state-delegate! endpoint delegate)))
            delegate)
          (lambda arguments
            (close-book-state-session-delegate-local!
             delegate 'attachment-failed)
            (finish-book-state-session-delegate-close! delegate)
            (apply throw arguments)))))))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (open-owned-socketpair)
  ;; Like Guix e343ff0's 'open-bidirectional-pipe', create both ends with
  ;; SOCK_CLOEXEC.  Only the authority side is nonblocking; the returned peer
  ;; is suitable for explicit pass-FD donation to a sandbox.
  (let* ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
         (authority (car pair))
         (peer (cdr pair)))
    (catch #t
      (lambda ()
        (fcntl authority F_SETFL
               (logior (fcntl authority F_GETFL) O_NONBLOCK))
        (setvbuf authority 'none)
        (setvbuf peer 'none)
        (values authority peer))
      (lambda arguments
        (close-port-quietly! authority)
        (close-port-quietly! peer)
        (apply throw arguments)))))

(define (open-session-endpoint! host diagnostic-name)
  (unless (book-session-host? host)
    (error "Book Session host record required"))
  (unless (string? diagnostic-name)
    (error "endpoint diagnostic name must be a string"))
  (call-with-values
      open-owned-socketpair
    (lambda (socket peer)
      (let ((published? #f) (registered-endpoint #f))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (let ((endpoint
                   (with-host-owner
                    host
                    (lambda ()
                      (when (>= (length (host-endpoints host)) max-sessions)
                        (session-error 'state
                                       "registered session limit reached"))
                      (let* ((session (new-session (host-forbidden-ids host)))
                             (endpoint
                              (make-registered-endpoint
                               host socket diagnostic-name session)))
                        (set-host-endpoints!
                         host (cons endpoint (host-endpoints host)))
                        endpoint)))))
              (set! registered-endpoint endpoint)
              (attach-state-delegate! endpoint)
              (set! published? #t)
              (values endpoint peer)))
          (lambda ()
            (unless published?
              (when registered-endpoint
                (catch #t
                  (lambda ()
                    (release-session-endpoint! registered-endpoint))
                  (lambda arguments #f)))
              (close-port-quietly! socket)
              (close-port-quietly! peer))))))))

(define (session-endpoint-diagnostic-name endpoint)
  (string-copy
   (endpoint-binding-diagnostic-name (session-endpoint-binding endpoint))))

(define (require-active! session)
  (unless (eq? (session-state session) 'active)
    (session-error 'state
                   (string-append "session is not active: "
                                  (symbol->string (session-state session))))))

(define (terminal-reason session request-id)
  (let loop ((entries (session-terminal session)))
    (and (pair? entries)
         (if (string=? request-id (caar entries))
             (cdar entries)
             (loop (cdr entries))))))

(define (bounded-terminal entries)
  (take entries (min max-terminal-requests (length entries))))

(define (retire-list session requests reason)
  (bounded-terminal
   (append (map (lambda (request)
                  (cons (pending-request-id request) reason))
                requests)
           (session-terminal session))))

(define (find-pending session request-id)
  (find (lambda (pending)
          (string=? request-id (pending-request-id pending)))
        (session-pending session)))

(define (accept-hello! session)
  (unless (eq? (session-state session) 'awaiting-hello)
    (session-error 'state "hello is valid only once on a fresh session"))
  (let* ((grant (initial-grant-envelope-surface
                 (session-initial-grants session)))
         (message
          `(("type" . "initialize")
            ("version" . ,protocol-version)
            ("grant_count" . ,max-live-handles)
            ("surface_handle" . ,(surface-grant-handle grant))
            ("surface_generation" . ,(surface-grant-generation grant))
            ("max_pending_requests" . ,max-pending-requests)
            ("max_present_text_bytes" . ,max-present-text-bytes))))
    (set-session-state! session 'active)
    message))

(define (accept-present! endpoint message)
  (let ((session (session-endpoint-session endpoint)))
  (require-active! session)
  (let* ((request-id (field message "request_id"))
         (action-id (field message "action_id"))
         (handle (field message "surface_handle"))
         (generation (field message "surface_generation"))
         (sequence (field message "sequence")))
    (unless (string=? handle (session-surface-handle session))
      (session-error 'authority
                     "surface handle is not granted on this endpoint"))
    (unless (= generation (session-generation session))
      (session-error 'state
                     (if (< generation (session-generation session))
                         "presentation uses a stale surface generation"
                         "presentation uses an unknown future generation")))
    (let ((pending (find-pending session request-id)))
      (unless pending
        (let ((reason (terminal-reason session request-id)))
          (session-error 'state
                         (if reason
                             (string-append "request is no longer pending: "
                                            (symbol->string reason))
                             "request is not pending on this endpoint"))))
      (unless (and (string=? action-id (pending-request-action-id pending))
                   (string=? handle (pending-request-surface-handle pending))
                   (= generation (pending-request-generation pending))
                   (= sequence (pending-request-sequence pending))
                   (eq? (endpoint-binding-identity
                         (session-endpoint-binding endpoint))
                        (pending-request-binding-identity pending)))
        (session-error 'authority
                       "presentation does not match its pending request"))
      (let* ((remaining (delq pending (session-pending session)))
             (terminal (bounded-terminal
                        (cons (cons request-id 'completed)
                              (session-terminal session))))
             (result (%make-presented-text
                      (string-copy (session-id session))
                      (string-copy request-id)
                      (string-copy action-id)
                      (string-copy handle)
                      generation sequence
                      (string-copy (field message "text")))))
        (set-session-pending! session remaining)
        (set-session-terminal! session terminal)
        result)))))

(define (state-output-reservation-available? endpoint)
  (and (< (length (endpoint-output-queue endpoint)) max-outbound-frames)
       (<= (+ (endpoint-output-bytes endpoint)
              max-state-outbound-frame-bytes)
           max-outbound-bytes)))

(define (append-outbound-frame-under-owner! endpoint frame)
  (let ((frame-length (bytevector-length frame)))
    (when (or (>= (length (endpoint-output-queue endpoint))
                  max-outbound-frames)
              (> (+ (endpoint-output-bytes endpoint) frame-length)
                 max-outbound-bytes))
      (session-error 'backpressure "outbound queue limit reached"))
    (set-endpoint-output-queue!
     endpoint
     (append (endpoint-output-queue endpoint)
             (list (%make-outbound-frame frame 0))))
    (set-endpoint-output-bytes!
     endpoint (+ (endpoint-output-bytes endpoint) frame-length))
    frame-length))

(define (queue-state-response-under-owner! endpoint delegate response)
  (let ((frame (encode-state-message response)))
    (when (> (bytevector-length frame) max-state-outbound-frame-bytes)
      (session-error 'state "bounded state response exceeded reservation"))
    (append-outbound-frame-under-owner! endpoint frame)
    (note-book-state-session-response-queued! delegate response)))

(define (dispatch-decoded! endpoint peer-message)
  (let ((message (peer-message-value peer-message)))
    (case (peer-message-kind peer-message)
      ((surface)
       (if (string=? (field message "type") "hello")
           (let* ((initialize
                   (accept-hello! (session-endpoint-session endpoint)))
                  (delegate (endpoint-state-delegate endpoint)))
             ;; The first value remains the exact accepted seven-field
             ;; initialize envelope.  A state-enabled endpoint adds one typed
             ;; state-ready value that the trusted pump owner queues second.
             (if delegate
                 (list initialize
                       (book-state-session-delegate-ready-message delegate))
                 (list initialize)))
           (list (accept-present! endpoint message))))
      ((state)
       (require-active! (session-endpoint-session endpoint))
       (let ((delegate (endpoint-state-delegate endpoint)))
         (unless delegate
           (session-error 'schema
                          "persistent-state messages are not enabled"))
         (unless (state-output-reservation-available? endpoint)
           (session-error 'backpressure
                          "no bounded output reservation for state result"))
         (let ((result
                (dispatch-book-state-session-message! delegate message)))
           (when (state-delegate-dispatch-result-response result)
             (queue-state-response-under-owner!
              endpoint delegate
              (state-delegate-dispatch-result-response result)))
           (list result))))
      (else (session-error 'schema "unknown decoded peer message kind")))))

(define (endpoint-current? endpoint identity)
  (let ((session (session-endpoint-session endpoint)))
    (and (eq? identity
              (endpoint-binding-identity (session-endpoint-binding endpoint)))
         (endpoint-transport-open? endpoint)
         (not (memq (session-state session) '(closed revoked))))))

(define (claim-io-owner! endpoint direction)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let* ((accessor (if (eq? direction 'input)
                          endpoint-input-owner
                          endpoint-output-owner))
            (setter (if (eq? direction 'input)
                        set-endpoint-input-owner!
                        set-endpoint-output-owner!))
            (owner (accessor endpoint)))
       (when owner
         (session-error 'busy
                        (string-append "concurrent "
                                       (symbol->string direction)
                                       " pump rejected")))
       (if (endpoint-current?
            endpoint
            (endpoint-binding-identity
             (session-endpoint-binding endpoint)))
           (begin
             (setter endpoint (current-thread))
             (endpoint-binding-identity
              (session-endpoint-binding endpoint)))
           #f)))))

(define (release-io-owner! endpoint direction)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let ((owner (if (eq? direction 'input)
                      (endpoint-input-owner endpoint)
                      (endpoint-output-owner endpoint))))
       (when (eq? owner (current-thread))
         ((if (eq? direction 'input)
              set-endpoint-input-owner!
              set-endpoint-output-owner!)
          endpoint #f))))))

(define (endpoint-current-snapshot? endpoint identity)
  (with-endpoint-owner endpoint
    (lambda () (endpoint-current? endpoint identity))))

(define (buffered-input-ready? endpoint)
  ;; The claimed input owner replaces this field rather than mutating a
  ;; published bytevector, so a readiness snapshot can inspect it safely.  A
  ;; complete frame or a header that is already terminally invalid is ready.
  (let* ((buffer (endpoint-input-buffer endpoint))
         (available (bytevector-length buffer)))
    (and (>= available 4)
         (let ((length (+ (ash (bytevector-u8-ref buffer 0) 24)
                          (ash (bytevector-u8-ref buffer 1) 16)
                          (ash (bytevector-u8-ref buffer 2) 8)
                          (bytevector-u8-ref buffer 3))))
           (or (zero? length)
               (> length max-frame-size)
               (>= available (+ 4 length)))))))

(define (endpoint-ready-events endpoint)
  "Return a subset of '(input output) ready without blocking or exposing the
authority socket.  OUTPUT is queried only while bounded output is queued."
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  (let ((snapshot
         (with-endpoint-owner
          endpoint
          (lambda ()
            (let ((identity
                   (endpoint-binding-identity
                    (session-endpoint-binding endpoint))))
              (and (endpoint-current? endpoint identity)
                   (list identity
                         (endpoint-binding-socket
                          (session-endpoint-binding endpoint))
                         (pair? (endpoint-output-queue endpoint))
                         (buffered-input-ready? endpoint))))))))
    (if (not snapshot)
        '()
        (let ((identity (car snapshot))
              (socket (cadr snapshot))
              (output? (caddr snapshot))
              (buffered-input? (cadddr snapshot)))
          (catch 'system-error
            (lambda ()
              ;; Zero timeout: this is a small readiness probe, not an event
              ;; loop and not a place where peer-controlled waiting can occur.
              (let ((ready
                     (select (if buffered-input? '() (list socket))
                             (if output? (list socket) '()) '() 0)))
                (if (endpoint-current-snapshot? endpoint identity)
                    (append (if (or buffered-input?
                                    (pair? (car ready)))
                                '(input)
                                '())
                            (if (pair? (cadr ready)) '(output) '()))
                    '())))
            (lambda arguments
              ;; Concurrent close invalidates first and can make SELECT see a
              ;; closed descriptor.  Any other local readiness failure is also
              ;; terminal for this transport.
              (close-session! endpoint)
              '()))))))

(define (dispatch-if-current! endpoint identity peer-message)
  (catch 'book-state-protocol-error
    (lambda ()
      (with-endpoint-owner
       endpoint
       (lambda ()
         (and (endpoint-current? endpoint identity)
              (cons 'committed
                    (dispatch-decoded! endpoint peer-message))))))
    (lambda arguments
      ;; A schema error leaves the pure model live.  Authority/generation or
      ;; impossible-state failures close it; pair the outer endpoint close and
      ;; backend revocation only after the endpoint mutex has been released.
      (let ((closing?
             (with-endpoint-owner
              endpoint
              (lambda ()
                (let ((delegate (endpoint-state-delegate endpoint)))
                  (and delegate
                       (book-state-session-delegate-closing? delegate)))))))
        (when closing? (close-session! endpoint)))
      (apply throw arguments))))

(define (take-complete-payload! endpoint)
  ;; Only the claimed input owner touches this buffer.
  (let* ((buffer (endpoint-input-buffer endpoint))
         (available (bytevector-length buffer)))
    (and (>= available 4)
         (let* ((header (bytevector-slice buffer 0 4))
                (length (frame-payload-length header))
                (end (+ 4 length)))
           (and (>= available end)
                (let ((payload (bytevector-slice buffer 4 end)))
                  (set-endpoint-input-buffer!
                   endpoint (bytevector-slice buffer end available))
                  payload))))))

(define (would-block-error? arguments)
  (memv (system-error-errno arguments) (list EAGAIN EWOULDBLOCK)))

(define (receive-nonblocking socket count)
  (let ((buffer (make-bytevector count)))
    (catch 'system-error
      (lambda ()
        (let ((received (recv! socket buffer)))
          (if (= received count)
              buffer
              (bytevector-slice buffer 0 received))))
      (lambda arguments
        (cond
         ((would-block-error? arguments) 'would-block)
         ((= (system-error-errno arguments) EINTR) 'interrupted)
         (else (apply throw arguments)))))))

(define (make-pump-result status bytes frames values)
  (%make-endpoint-pump-result status bytes frames (reverse values)))

(define (endpoint-pump-input! endpoint)
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  (let ((identity (claim-io-owner! endpoint 'input)))
    (if (not identity)
        (make-pump-result 'closed 0 0 '())
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (catch 'book-protocol-error
              (lambda ()
                (catch 'system-error
                  (lambda ()
                    (let loop ((bytes 0) (frames 0) (values '()))
                      (cond
                       ((>= frames max-input-frames-per-pump)
                        (make-pump-result 'budget bytes frames values))
                       ((take-complete-payload! endpoint)
                        =>
                        (lambda (payload)
                          (let ((message (decode-peer-payload payload)))
                            ((decoded-message-hook) endpoint message)
                            (let ((committed
                                   (dispatch-if-current!
                                    endpoint identity message)))
                              (if committed
                                  ;; One authority commit per input pump keeps
                                  ;; its returned value observable before any
                                  ;; trailing frame can reject or close.
                                   (make-pump-result
                                    'committed bytes 1
                                    (reverse (cdr committed)))
                                  (make-pump-result
                                   'stale bytes frames values))))))
                       ((>= bytes max-input-bytes-per-pump)
                        (make-pump-result 'budget bytes frames values))
                       ((not (endpoint-current-snapshot? endpoint identity))
                        (make-pump-result 'closed bytes frames values))
                       (else
                        (let* ((buffered
                                (bytevector-length
                                 (endpoint-input-buffer endpoint)))
                               (room (- max-inbound-bytes buffered))
                               (allowance
                                (min (- max-input-bytes-per-pump bytes) room)))
                          (when (<= allowance 0)
                            (protocol-error
                             "session input buffer exceeds its bound"))
                          (let ((received
                                 (receive-nonblocking
                                  (endpoint-binding-socket
                                   (session-endpoint-binding endpoint))
                                  allowance)))
                            (cond
                             ((eq? received 'would-block)
                              (make-pump-result
                               'would-block bytes frames values))
                             ((eq? received 'interrupted)
                              (make-pump-result
                               'interrupted bytes frames values))
                             ((zero? (bytevector-length received))
                              (if (zero?
                                   (bytevector-length
                                    (endpoint-input-buffer endpoint)))
                                  (begin
                                    (close-session! endpoint)
                                    (make-pump-result
                                     'eof bytes frames values))
                                  (protocol-error
                                   "EOF truncated a Book Protocol frame")))
                             (else
                              (set-endpoint-input-buffer!
                               endpoint
                               (bytevector-append
                                (endpoint-input-buffer endpoint) received))
                               (loop (+ bytes
                                        (bytevector-length received))
                                     frames values)))))))))
                  (lambda arguments
                    (close-session! endpoint)
                    (apply throw arguments))))
              (lambda arguments
                (close-session! endpoint)
                (apply throw arguments))))
          (lambda () (release-io-owner! endpoint 'input))))))

(define (typed-state-message? message)
  (or (state-ready-message? message)
      (state-read-message? message)
      (state-commit-message? message)
      (state-value-message? message)
      (state-committed-message? message)
      (state-conflict-message? message)
      (state-commit-failed-message? message)))

(define (state-looking-object? message)
  (and (list? message)
       (assoc "type" message)
       (let ((type (assoc-ref message "type")))
         (and (string? type) (string-prefix? "state-" type)))))

(define (endpoint-queue-message! endpoint message)
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  ;; Encoding is bounded by the accepted codec and intentionally happens
  ;; outside every endpoint/host mutex.
  (when (and (typed-state-message? message)
             (not (state-ready-message? message)))
    (session-error 'authority
                   "only the endpoint-owned state worker may queue state results"))
  (when (state-looking-object? message)
    (session-error 'schema
                   "state output must use its accepted typed record"))
  (let ((frame (if (state-ready-message? message)
                   (encode-state-message message)
                   (encode-frame message))))
    (with-endpoint-owner
     endpoint
     (lambda ()
       (let* ((identity
              (endpoint-binding-identity
                (session-endpoint-binding endpoint)))
               (frame-length (bytevector-length frame)))
          (unless (endpoint-current? endpoint identity)
            (session-error 'state "session endpoint is closed or revoked"))
          (when (or (>= (length (endpoint-output-queue endpoint))
                        max-outbound-frames)
                    (> (+ (endpoint-output-bytes endpoint) frame-length)
                       max-outbound-bytes))
            (session-error 'backpressure "outbound queue limit reached"))
          (when (state-ready-message? message)
            (let ((delegate (endpoint-state-delegate endpoint)))
              (unless delegate
                (session-error 'authority
                               "endpoint has no persistent-state grant"))
              (announce-book-state-session-delegate! delegate message)))
          (append-outbound-frame-under-owner! endpoint frame))))))

(define (invalidate-state-completion-under-owner! endpoint identity delegate
                                                   reason)
  ;; This runs while the endpoint mutex is held.  A failed completion therefore
  ;; closes and detaches this exact lifetime before another input pump can
  ;; publish a task.  Transport shutdown and trusted revocation remain outside
  ;; that authority mutex.
  (and (endpoint-current? endpoint identity)
       (eq? delegate (endpoint-state-delegate endpoint))
       (list (close-one-session-transition! endpoint)
             (detach-state-delegate-under-owner! endpoint reason))))

(define (finish-failed-state-completion! endpoint transition)
  ;; The local transition is already complete.  Completion is exception-total:
  ;; even an unexpected transport/revocation failure cannot resurrect the
  ;; endpoint or escape the sole worker.  The supported trusted callbacks are
  ;; required to be bounded and total; this catch is containment, not
  ;; cancellation of a callback that may still commit.
  (when transition
    (catch #t
      (lambda ()
        (when (car transition)
          (shutdown-and-close-transport! endpoint))
        (when (cadr transition)
          (finish-book-state-session-delegate-close! (cadr transition))))
      (lambda arguments #f))))

(define (complete-state-backend-task! endpoint identity delegate operation
                                      outcome value)
  ;; The delegate worker calls this after RUN-OPERATION has returned with no
  ;; authority mutex held.  Reenter once, recheck exact endpoint/delegate
  ;; lifetime, apply the exact typed result, and queue at most one response.
  (let ((transition #f))
    (define (invalidate! reason)
      (set! transition
            (invalidate-state-completion-under-owner!
             endpoint identity delegate reason))
      'closing)
    (let ((status
           (catch #t
             (lambda ()
               (with-endpoint-owner
                endpoint
                (lambda ()
                  ;; Catch every result/FSM/encoder/queue/invariant failure
                  ;; while still owning the endpoint.  Local invalidation is
                  ;; atomic with respect to the next input dispatch.
                  (catch #t
                    (lambda ()
                      (cond
                       ((or (not (endpoint-current? endpoint identity))
                            (not (eq? delegate
                                      (endpoint-state-delegate endpoint))))
                        'stale)
                       ((eq? outcome 'error)
                        (invalidate! 'state-backend-callback-failed))
                       ((not (state-output-reservation-available? endpoint))
                        (invalidate! 'state-output-backpressure))
                       (else
                        (let ((response
                               (apply-book-state-session-backend-result!
                                delegate value)))
                          (if (book-state-session-delegate-closing? delegate)
                              (invalidate! 'state-backend-result-closed)
                              (begin
                                (queue-state-response-under-owner!
                                 endpoint delegate response)
                                'queued))))))
                    (lambda arguments
                      (invalidate! 'state-completion-failed))))))
             (lambda arguments
               ;; Lock/runtime failures are not expected, but this final
               ;; containment path still attempts the ordinary total close and
               ;; never lets an exception escape the worker.
               (catch #t
                 (lambda () (close-session! endpoint))
                 (lambda ignored #f))
               'closing))))
      (finish-failed-state-completion! endpoint transition)
      (if (or transition (eq? status 'closing)) 'closed 'complete))))

(define (output-head-snapshot endpoint identity)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (and (endpoint-current? endpoint identity)
          (let ((queue (endpoint-output-queue endpoint)))
            (if (null? queue)
                'empty
                (let ((head (car queue)))
                  (list head (outbound-frame-offset head)))))))))

(define (send-nonblocking socket bytes)
  (catch 'system-error
    ;; This authority targets the Linux reader/supervisor.  Guile 3.0.11 does
    ;; not export MSG_NOSIGNAL, whose Linux value is #x4000.  Passing it keeps a
    ;; disconnected peer in the ordinary EPIPE cleanup path instead of letting
    ;; SIGPIPE terminate the authority process.
    (lambda () (send socket bytes linux-msg-nosignal))
    (lambda arguments
      (cond
       ((would-block-error? arguments) 'would-block)
       ((= (system-error-errno arguments) EINTR) 'interrupted)
       (else (apply throw arguments))))))

(define (commit-output-progress! endpoint identity head offset sent)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let ((queue (endpoint-output-queue endpoint)))
       (and (endpoint-current? endpoint identity)
            (pair? queue)
            (eq? head (car queue))
            (= offset (outbound-frame-offset head))
            (let* ((end (+ offset sent))
                   (complete?
                    (= end (bytevector-length (outbound-frame-bytes head)))))
              (set-endpoint-output-bytes!
               endpoint (- (endpoint-output-bytes endpoint) sent))
              (if complete?
                  (set-endpoint-output-queue! endpoint (cdr queue))
                  (set-outbound-frame-offset! head end))
              complete?))))))

(define (endpoint-pump-output! endpoint)
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  (let ((identity (claim-io-owner! endpoint 'output)))
    (if (not identity)
        (make-pump-result 'closed 0 0 '())
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (catch 'system-error
              (lambda ()
                (let loop ((bytes 0) (frames 0))
                  (cond
                   ((or (>= bytes max-output-bytes-per-pump)
                        (>= frames max-output-frames-per-pump))
                    (make-pump-result 'budget bytes frames '()))
                   ((output-head-snapshot endpoint identity)
                    =>
                    (lambda (snapshot)
                      (if (eq? snapshot 'empty)
                          (make-pump-result 'drained bytes frames '())
                          (let* ((head (car snapshot))
                                 (offset (cadr snapshot))
                                 (source (outbound-frame-bytes head))
                                 (end
                                  (min (bytevector-length source)
                                       (+ offset
                                          (- max-output-bytes-per-pump
                                             bytes))))
                                 (sent
                                  (begin
                                    ;; Private test hook; runtime identity is a
                                    ;; no-op and no mutex is held here.
                                    ((send-attempt-hook)
                                     endpoint (- end offset))
                                    (send-nonblocking
                                     (endpoint-binding-socket
                                      (session-endpoint-binding endpoint))
                                     (bytevector-slice source offset end)))))
                            (cond
                             ((eq? sent 'would-block)
                              (make-pump-result
                               'would-block bytes frames '()))
                             ((eq? sent 'interrupted)
                              (make-pump-result
                               'interrupted bytes frames '()))
                             ((zero? sent)
                              (close-session! endpoint)
                              (make-pump-result 'closed bytes frames '()))
                             (else
                              (let ((complete?
                                     (commit-output-progress!
                                      endpoint identity head offset sent)))
                                (if complete?
                                    (loop (+ bytes sent) (+ frames 1))
                                    (if (endpoint-current-snapshot?
                                         endpoint identity)
                                        (loop (+ bytes sent) frames)
                                        (make-pump-result
                                         'stale bytes frames '()))))))))))
                   (else
                    (make-pump-result 'closed bytes frames '())))))
              (lambda arguments
                (close-session! endpoint)
                (apply throw arguments))))
          (lambda () (release-io-owner! endpoint 'output))))))

(define (host-action! endpoint action-id text)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let ((session (session-endpoint-session endpoint)))
       (require-active! session)
       (bounded-string! "action_id" action-id max-opaque-id-bytes)
       (bounded-string! "text" text max-action-text-bytes)
       (when (>= (length (session-pending session)) max-pending-requests)
         (session-error 'state "pending request limit reached"))
       (when (>= (session-sequence session) max-sequence)
         (session-error 'state "session sequence limit reached"))
       (let* ((next-sequence (+ 1 (session-sequence session)))
              (forbidden
               (append (map pending-request-id (session-pending session))
                       (map car (session-terminal session))))
              ;; Allocation occurs before either counter or pending state moves.
              (request-id (new-opaque "request" forbidden))
              (action-copy (string-copy action-id))
              (text-copy (string-copy text))
              (pending (%make-pending-request
                        request-id action-copy (session-surface-handle session)
                        (session-generation session) next-sequence
                        (endpoint-binding-identity
                         (session-endpoint-binding endpoint))))
              (message
               `(("type" . "action")
                 ("request_id" . ,(string-copy request-id))
                 ("action_id" . ,(string-copy action-copy))
                 ("surface_handle" . ,(string-copy
                                        (session-surface-handle session)))
                 ("surface_generation" . ,(session-generation session))
                 ("sequence" . ,next-sequence)
                 ("text" . ,text-copy))))
         (set-session-sequence! session next-sequence)
         (set-session-pending! session
                               (cons pending (session-pending session)))
         message)))))

(define (take-pending! session request-id reason)
  (require-active! session)
  (bounded-string! "request_id" request-id max-opaque-id-bytes)
  (let ((pending (find-pending session request-id)))
    (unless pending
      (session-error 'state "request is not pending on this endpoint"))
    (let ((remaining (delq pending (session-pending session)))
          (terminal (bounded-terminal
                     (cons (cons (pending-request-id pending) reason)
                           (session-terminal session)))))
      (set-session-pending! session remaining)
      (set-session-terminal! session terminal))))

(define (cancel-request! endpoint request-id)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (take-pending! (session-endpoint-session endpoint)
                    request-id 'cancelled)
     `(("type" . "cancel")
       ("request_id" . ,(string-copy request-id))))))

(define (expire-request! endpoint request-id)
  ;; This is a synchronous owner event, not a timer or deadline implementation.
  (with-endpoint-owner
   endpoint
   (lambda ()
     (take-pending! (session-endpoint-session endpoint)
                    request-id 'expired))))

(define (navigate! endpoint)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let ((session (session-endpoint-session endpoint)))
       (require-active! session)
       (when (>= (session-generation session) max-surface-generation)
         (session-error 'state "surface generation limit reached"))
       (let ((terminal
              (retire-list session (session-pending session) 'navigation))
             (generation (+ 1 (session-generation session))))
         (set-session-pending! session '())
         (set-session-terminal! session terminal)
         (set-session-generation! session generation)
         generation)))))

(define (revoke-surface! endpoint)
  (let ((transition
         (with-endpoint-owner
          endpoint
          (lambda ()
            (let ((session (session-endpoint-session endpoint)))
              (require-active! session)
              (let ((terminal
                     (retire-list
                      session (session-pending session) 'revoked)))
                (set-session-pending! session '())
                (set-session-terminal! session terminal)
                 (set-session-state! session 'revoked)
                 (let ((open? (endpoint-transport-open? endpoint)))
                   (set-endpoint-transport-open! endpoint #f)
                   (set-endpoint-output-queue! endpoint '())
                   (set-endpoint-output-bytes! endpoint 0)
                   (list open?
                         (detach-state-delegate-under-owner!
                          endpoint 'surface-revoked)))))))))
    (when (car transition)
      (shutdown-and-close-transport! endpoint))
    (when (cadr transition)
      (finish-book-state-session-delegate-close! (cadr transition)))))

(define (detach-state-delegate-under-owner! endpoint reason)
  (let ((delegate (endpoint-state-delegate endpoint)))
    (when delegate
      (close-book-state-session-delegate-local! delegate reason)
      (set-endpoint-state-delegate! endpoint #f))
    delegate))

(define (close-one-session-transition! endpoint)
  (let ((session (session-endpoint-session endpoint)))
    (unless (eq? (session-state session) 'closed)
      (let ((terminal
             (retire-list session (session-pending session) 'closed)))
        (set-session-pending! session '())
        (set-session-terminal! session terminal)
        (set-session-state! session 'closed)))
    (let ((open? (endpoint-transport-open? endpoint)))
      (set-endpoint-transport-open! endpoint #f)
      (set-endpoint-output-queue! endpoint '())
      (set-endpoint-output-bytes! endpoint 0)
      open?)))

(define (shutdown-and-close-transport! endpoint)
  (let ((socket
         (endpoint-binding-socket (session-endpoint-binding endpoint))))
    ;; SHUT_RDWR is 2 on Guile's supported POSIX targets.  Shutdown affects
    ;; accidental dup/inherited aliases too; close then releases our sole
    ;; authority-owned descriptor.  Neither operation is under a state lock.
    (when (and (port? socket) (not (port-closed? socket)))
      (catch 'system-error
        (lambda () (shutdown socket 2))
        (lambda arguments #f))
      (close-port-quietly! socket))))

(define (close-session! endpoint)
  (let ((transition
         (with-endpoint-owner
          endpoint
          (lambda ()
            (list (close-one-session-transition! endpoint)
                  (detach-state-delegate-under-owner!
                   endpoint 'session-closed))))))
    (when (car transition)
      (shutdown-and-close-transport! endpoint))
    (when (cadr transition)
      (finish-book-state-session-delegate-close! (cadr transition)))))

(define (host-session-snapshot endpoint)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (let ((session (session-endpoint-session endpoint)))
       `(("session_id" . ,(string-copy (session-id session)))
         ("state" . ,(session-state session))
         ("surface_generation" . ,(session-generation session))
          ("sequence" . ,(session-sequence session))
          ("pending_requests" . ,(length (session-pending session)))
          ("live_handles" . ,(if (eq? (session-state session) 'active) 1 0))
          ("retained_terminal_requests" .
           ,(length (session-terminal session)))
          ("transport_open" . ,(endpoint-transport-open? endpoint))
          ("outbound_frames" . ,(length (endpoint-output-queue endpoint)))
          ("outbound_bytes" . ,(endpoint-output-bytes endpoint)))))))

(define (host-initial-grants endpoint)
  (with-endpoint-owner
   endpoint
   (lambda ()
     (session-initial-grants (session-endpoint-session endpoint)))))

(define (restart-session! old-endpoint diagnostic-name)
  (unless (session-endpoint? old-endpoint)
    (error "Book Session endpoint record required"))
  (unless (string? diagnostic-name)
    (error "endpoint diagnostic name must be a string"))
  (let ((host (session-endpoint-host old-endpoint)))
    (call-with-values
        open-owned-socketpair
      (lambda (new-socket new-peer)
        (let ((published? #f) (close-old? #f) (old-delegate #f)
              (replacement-created #f))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (let ((replacement
                     (with-host-owner
                      host
                      (lambda ()
                        (with-endpoint-owner
                         old-endpoint
                         (lambda ()
                           (unless (memq old-endpoint
                                         (host-endpoints host))
                             (session-error
                              'state
                              "old endpoint is no longer registered"))
                           (let* ((session
                                  (new-session (host-forbidden-ids host)))
                                  (replacement
                                   (make-registered-endpoint
                                    host new-socket diagnostic-name session))
                                  (endpoints
                                   (map (lambda (candidate)
                                          (if (eq? candidate old-endpoint)
                                              replacement
                                              candidate))
                                        (host-endpoints host))))
                             ;; No socket I/O occurs here.  The old lifetime is
                             ;; invalid before the replacement is published.
                             (set! close-old?
                                    (close-one-session-transition!
                                     old-endpoint))
                              (set! old-delegate
                                    (detach-state-delegate-under-owner!
                                     old-endpoint 'session-restarted))
                              (set-host-endpoints! host endpoints)
                              replacement)))))))
                (set! replacement-created replacement)
                (when close-old?
                  (shutdown-and-close-transport! old-endpoint))
                (when old-delegate
                  (finish-book-state-session-delegate-close! old-delegate))
                (attach-state-delegate! replacement)
                (set! published? #t)
                (values replacement new-peer)))
            (lambda ()
              (unless published?
                (when replacement-created
                  (catch #t
                    (lambda ()
                      (release-session-endpoint! replacement-created))
                    (lambda arguments #f)))
                (close-port-quietly! new-socket)
                (close-port-quietly! new-peer)))))))))

(define (release-session-endpoint! endpoint)
  (unless (session-endpoint? endpoint)
    (error "Book Session endpoint record required"))
  (let ((host (session-endpoint-host endpoint)))
    (let ((transition
           (with-host-owner
            host
            (lambda ()
              (with-endpoint-owner
               endpoint
               (lambda ()
                 (unless (memq endpoint (host-endpoints host))
                   (session-error 'state
                                  "endpoint is no longer registered"))
                  (let ((close?
                         (close-one-session-transition! endpoint))
                        (delegate
                         (detach-state-delegate-under-owner!
                          endpoint 'endpoint-released)))
                    (set-host-endpoints!
                     host (delq endpoint (host-endpoints host)))
                    (list close? delegate))))))))
      (when (car transition)
        (shutdown-and-close-transport! endpoint))
      (when (cadr transition)
        (finish-book-state-session-delegate-close! (cadr transition))))))
