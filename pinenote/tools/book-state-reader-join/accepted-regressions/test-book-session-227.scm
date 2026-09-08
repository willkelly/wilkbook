(use-modules (book-protocol)
             (book-protocol blocking-io)
             (book-session)
             (ice-9 format)
             (ice-9 threads)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define random-token-source-for-test
  (@@ (book-session) random-token-source))
(define decoded-message-hook-for-test
  (@@ (book-session) decoded-message-hook))
(define send-attempt-hook-for-test
  (@@ (book-session) send-attempt-hook))
(define endpoint-socket-for-test
  (lambda (endpoint)
    ((@@ (book-session) endpoint-binding-socket)
     ((@@ (book-session) session-endpoint-binding) endpoint))))

(define (put-length! bytevector length)
  (bytevector-u8-set! bytevector 0 (logand (ash length -24) #xff))
  (bytevector-u8-set! bytevector 1 (logand (ash length -16) #xff))
  (bytevector-u8-set! bytevector 2 (logand (ash length -8) #xff))
  (bytevector-u8-set! bytevector 3 (logand length #xff)))

(define (raw-frame text)
  (let* ((payload (string->utf8 text))
         (length (bytevector-length payload))
         (frame (make-bytevector (+ length 4))))
    (put-length! frame length)
    (bytevector-copy! payload 0 frame 4 length)
    frame))

(define (send-raw port text)
  (put-bytevector port (raw-frame text))
  (force-output port))

(define (send-range port bytes start count)
  (put-bytevector port bytes start count)
  (force-output port))

(define (append-bytevectors . inputs)
  (let* ((length (fold (lambda (input total)
                         (+ (bytevector-length input) total))
                       0 inputs))
         (result (make-bytevector length)))
    (let loop ((remaining inputs) (offset 0))
      (if (null? remaining)
          result
          (let* ((input (car remaining))
                 (input-length (bytevector-length input)))
            (bytevector-copy! input 0 result offset input-length)
            (loop (cdr remaining) (+ offset input-length)))))))

(define (send-frames-together port . frames)
  (put-bytevector port (apply append-bytevectors frames))
  (force-output port))

(define (kernel-input-ready? endpoint)
  (pair? (car (select (list (endpoint-socket-for-test endpoint))
                      '() '() 0))))

(define (replace-first text old new)
  (let ((index (string-contains text old)))
    (unless index (error "test replacement text was not found"))
    (string-append (substring text 0 index)
                   new
                   (substring text (+ index (string-length old))))))

(define (field object name)
  (assoc-ref object name))

(define (snapshot endpoint name)
  (field (host-session-snapshot endpoint) name))

(define (session-error-kind thunk)
  (catch 'book-session-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) kind)))

(define (session-error-message thunk)
  (catch 'book-session-error
    (lambda () (thunk) #f)
    (lambda (_ kind message) message)))

(define (protocol-error? thunk)
  (catch 'book-protocol-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (make-fixture name)
  (let ((host (make-book-session-host)))
    (call-with-values
        (lambda () (open-session-endpoint! host name))
      (lambda (endpoint peer)
        (values host endpoint peer)))))

(define (open-on-host host name)
  (open-session-endpoint! host name))

(define (pump-one! endpoint)
  (let loop ((attempts 0))
    (when (= attempts 32)
      (error "nonblocking input pump made no complete-frame progress"))
    (let* ((result (endpoint-pump-input! endpoint))
           (values (endpoint-pump-result-values result))
           (status (endpoint-pump-result-status result)))
      (cond
       ((pair? values) (car values))
       ((eq? status 'eof) (eof-object))
       ((memq status '(budget interrupted)) (loop (+ attempts 1)))
       ((eq? status 'would-block)
        (error "input pump would block before expected complete frame"))
       (else
        (error (format #f "input pump stopped with ~a" status)))))))

(define (pump-one/eventually! endpoint)
  (let loop ((attempts 0))
    (when (= attempts 10000)
      (error "timed out waiting for one nonblocking frame"))
    (let* ((result (endpoint-pump-input! endpoint))
           (values (endpoint-pump-result-values result))
           (status (endpoint-pump-result-status result)))
      (cond
       ((pair? values) (car values))
       ((eq? status 'eof) (eof-object))
       ((memq status '(closed stale))
        (error (format #f "input endpoint became ~a" status)))
       (else
        (usleep 1000)
        (loop (+ attempts 1)))))))

(define (flush-output! endpoint)
  (let loop ((attempts 0))
    (when (= attempts 10000)
      (error "timed out flushing bounded nonblocking output"))
    (let ((status
           (endpoint-pump-result-status (endpoint-pump-output! endpoint))))
      (cond
       ((eq? status 'drained) #t)
       ((memq status '(budget would-block interrupted))
        (when (eq? status 'would-block) (usleep 1000))
        (loop (+ attempts 1)))
       (else (error (format #f "output endpoint became ~a" status)))))))

(define (queue-and-flush! endpoint message)
  (endpoint-queue-message! endpoint message)
  (flush-output! endpoint))

(define (initialize! endpoint peer)
  (write-frame peer '(("type" . "hello") ("version" . 1)))
  (pump-one! endpoint))

(define (present-for action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(define (present-json action integer-field token)
  (define (integer-token name value)
    (if (string=? name integer-field) token (number->string value)))
  (format #f
          "{\"type\":\"present\",\"request_id\":\"~a\",~
\"action_id\":\"~a\",\"surface_handle\":\"~a\",~
\"surface_generation\":~a,\"sequence\":~a,\"count\":~a,~
\"text\":\"rendered text\"}"
          (field action "request_id")
          (field action "action_id")
          (field action "surface_handle")
          (integer-token "surface_generation"
                         (field action "surface_generation"))
          (integer-token "sequence" (field action "sequence"))
          (integer-token "count" 1)))

(define (send-present! endpoint peer message)
  (write-frame peer message)
  (pump-one! endpoint))

(define (close-fixture! endpoint peer)
  (unless (port-closed? peer) (close-port peer))
  (unless (eq? (snapshot endpoint "state") 'closed)
    (close-session! endpoint)))

(define (thread-outcome thunk success)
  (catch 'book-session-error
    (lambda () (thunk) success)
    (lambda (_ kind message) kind)))

(test-begin "book-session-guile")

(call-with-values
    (lambda () (make-fixture "worker-a"))
  (lambda (host endpoint peer)
    (test-equal "host action is inactive before hello" 'state
      (session-error-kind (lambda () (host-action! endpoint "submit" "x"))))
    (let* ((envelope (host-initial-grants endpoint))
           (grant (initial-grant-envelope-surface envelope))
           (handle-copy (surface-grant-handle grant)))
      (test-assert "initial grant is one immutable surface record"
        (and (initial-grant-envelope? envelope)
             (surface-grant? grant)
             (= (surface-grant-generation grant) 1)))
      (string-set! handle-copy 0 #\X)
      (test-assert "mutating returned handle copy cannot alter grant"
        (not (string=? handle-copy (surface-grant-handle grant)))))
    (let ((initialize (initialize! endpoint peer)))
      (test-equal "initialize has seven exact fields" 7 (length initialize))
      (test-equal "initialize grants exactly one surface" 1
        (field initialize "grant_count"))
      (test-equal "endpoint becomes active with one live handle" '(active 1)
        (list (snapshot endpoint "state") (snapshot endpoint "live_handles")))
      (test-assert "host-generated handle is a bounded string"
        (and (string? (field initialize "surface_handle"))
             (<= (bytevector-length
                  (string->utf8 (field initialize "surface_handle")))
                 max-opaque-id-bytes))))
    (write-frame peer '(("type" . "hello") ("version" . 1)))
    (test-equal "hello is accepted only once" 'state
      (session-error-kind (lambda () (pump-one! endpoint))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "lexical-hello"))
  (lambda (host endpoint peer)
    (for-each
     (lambda (token)
       (send-raw peer
                 (string-append "{\"type\":\"hello\",\"version\":"
                                token "}"))
       (test-equal (string-append "hello rejects raw alias " token) 'schema
         (session-error-kind
          (lambda () (pump-one! endpoint))))
       (test-equal (string-append "hello alias is atomic " token)
         'awaiting-hello (snapshot endpoint "state")))
     '("true" "1.0" "1e0" "-0.0" "0.99999999999999999"))
    (send-raw peer "{\"type\":\"hello\",\"\\u0076ersion\":1.0}")
    (test-equal "escaped integer-field key cannot bypass lexical check" 'schema
      (session-error-kind (lambda () (pump-one! endpoint))))
    (send-raw peer "{ \"\\u0076ersion\" : 1 , \"type\" : \"hello\" }")
    (test-equal "escaped reordered lexical integer is accepted" "initialize"
      (field (pump-one! endpoint) "type"))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "valid-flow"))
  (lambda (host endpoint peer)
    (let* ((initialize (initialize! endpoint peer))
           (action (host-action! endpoint "submit-value" "forty two"))
           (present (present-for action "42"))
           (result (send-present! endpoint peer present)))
      (test-equal "action uses initialized surface" '(1 1)
        (list (field action "surface_generation") (field action "sequence")))
      (test-assert "valid presentation returns Guile authority result"
        (and (presented-text? result)
             (string=? (presented-text-value result) "42")))
      (test-equal "success consumes pending request" 0
        (snapshot endpoint "pending_requests"))
      (write-frame peer present)
      (test-assert "duplicate success is rejected as completed"
        (string-contains
         (session-error-message
          (lambda () (pump-one! endpoint)))
         "completed")))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "lexical-present"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((action (host-action! endpoint "submit" "input")))
      (for-each
       (lambda (name)
         (for-each
          (lambda (token)
            (send-raw peer (present-json action name token))
            (test-equal
                (format #f "~a rejects raw alias ~a" name token) 'schema
              (session-error-kind
               (lambda () (pump-one! endpoint))))
            (test-equal
                (format #f "~a alias leaves request pending" name) 1
              (snapshot endpoint "pending_requests")))
          '("true" "1.0" "1e0" "-0.0" "0.99999999999999999")))
       '("surface_generation" "sequence" "count"))
      (for-each
       (lambda (case)
         (send-raw peer (present-json action (car case) (cdr case)))
         (test-equal (format #f "~a rejects range ~a" (car case) (cdr case))
           'schema
           (session-error-kind
            (lambda () (pump-one! endpoint)))))
       `(("surface_generation" . "0")
         ("surface_generation" . "-1")
         ("surface_generation" . "1000001")
         ("surface_generation" . ,(number->string max-safe-integer))
         ("sequence" . "1000001")
         ("count" . "0")
         ("count" . "2")))
      (send-raw
       peer
       (replace-first
        (present-json action "sequence" "1.0")
        "\"sequence\":1.0"
        "\"\\u0073equence\":1.0"))
      (test-equal "escaped present key retains noninteger evidence" 'schema
        (session-error-kind
         (lambda () (pump-one! endpoint))))
      (test-equal "all lexical failures precede request consumption" 1
        (snapshot endpoint "pending_requests"))
      (test-equal "valid retry after lexical failures succeeds" "ok"
        (presented-text-value
         (send-present! endpoint peer (present-for action "ok")))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "schema-retry"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let* ((action (host-action! endpoint "submit" "input"))
           (valid (present-for action "literal <b>/etc/passwd</b>"))
           (bad-messages
            (list
             (acons "owner" "claimed" valid)
             (filter (lambda (entry) (not (string=? (car entry) "text"))) valid)
             (acons "path" "/etc/passwd" valid)
             (acons "markup" "<b>unsupported field</b>" valid)
             (map (lambda (entry)
                    (if (string=? (car entry) "action_id")
                        (cons "action_id" "other") entry))
                  valid)
             (map (lambda (entry)
                    (if (string=? (car entry) "sequence")
                        (cons "sequence" 2) entry))
                  valid))))
      (for-each
       (lambda (message)
         (write-frame peer message)
         (test-assert "schema/authority rejection is atomic"
           (session-error-kind
            (lambda () (pump-one! endpoint))))
         (test-equal "rejected message retains pending request" 1
           (snapshot endpoint "pending_requests")))
       bad-messages)
      (test-equal "plain text remains literal, not markup or path"
        "literal <b>/etc/passwd</b>"
        (presented-text-value (send-present! endpoint peer valid))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "limits"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (test-equal "oversized host action ID is rejected" 'schema
      (session-error-kind
       (lambda ()
         (host-action! endpoint (make-string (+ max-opaque-id-bytes 1) #\a)
                       "x"))))
    (test-equal "oversized host text is rejected before pending mutation" 0
      (begin
        (session-error-kind
         (lambda ()
           (host-action! endpoint "submit"
                         (make-string (+ max-action-text-bytes 1) #\x))))
        (snapshot endpoint "pending_requests")))
    (let* ((action (host-action! endpoint "submit" "input"))
           (too-long (present-for
                      action (make-string (+ max-present-text-bytes 1) #\x))))
      (write-frame peer too-long)
      (test-equal "oversized presentation is rejected before lookup" 'schema
        (session-error-kind
         (lambda () (pump-one! endpoint))))
      (test-equal "exact presentation byte maximum succeeds"
        max-present-text-bytes
        (string-length
         (presented-text-value
          (send-present! endpoint peer
                         (present-for action
                                      (make-string max-present-text-bytes #\x)))))))
    (let ((all-controls-accepted?
           (let loop ((codepoint 0))
             (if (= codepoint 32)
                 #t
                 (let* ((action (host-action! endpoint "control" "input"))
                        (value (string (integer->char codepoint)))
                        (result
                         (send-present! endpoint peer (present-for action value))))
                   (and (string=? value (presented-text-value result))
                        (loop (+ codepoint 1))))))))
      (test-assert "all C0 scalars are literal presentation text"
        all-controls-accepted?))
    (let ((action (host-action! endpoint "empty" "input")))
      (write-frame peer (present-for action ""))
      (test-equal "empty presentation remains forbidden in version 1" 'schema
        (session-error-kind
         (lambda () (pump-one! endpoint)))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "lifecycle"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((actions
           (map (lambda (index)
                  (host-action! endpoint
                                (format #f "action-~a" index) "input"))
                (iota max-pending-requests))))
      (test-equal "four pending actions have unique monotonic sequences"
        '(1 2 3 4) (sort (map (lambda (a) (field a "sequence")) actions) <))
      (test-equal "fifth pending action is rejected without sequence mutation"
        '(state 4 4)
        (list
         (session-error-kind
          (lambda () (host-action! endpoint "fifth" "input")))
         (snapshot endpoint "sequence")
         (snapshot endpoint "pending_requests")))
      (let ((cancelled (car actions)) (expired (cadr actions)))
        (cancel-request! endpoint (field cancelled "request_id"))
        (write-frame peer (present-for cancelled "late"))
        (test-assert "cancelled late result is rejected"
          (string-contains
           (session-error-message
            (lambda () (pump-one! endpoint))) "cancelled"))
        (expire-request! endpoint (field expired "request_id"))
        (write-frame peer (present-for expired "late"))
        (test-assert "synchronously expired late result is rejected"
          (string-contains
           (session-error-message
            (lambda () (pump-one! endpoint))) "expired")))
      (let ((old (caddr actions)))
        (test-equal "navigation advances generation" 2 (navigate! endpoint))
        (write-frame peer (present-for old "stale"))
        (test-assert "navigation rejects stale generation"
          (string-contains
           (session-error-message
            (lambda () (pump-one! endpoint))) "stale")))
      (let* ((current (host-action! endpoint "current" "input"))
             (future (map (lambda (entry)
                            (if (string=? (car entry) "surface_generation")
                                (cons "surface_generation" 3) entry))
                          (present-for current "future"))))
        (write-frame peer future)
        (test-assert "future generation is rejected without consuming current"
          (and (session-error-kind
                (lambda () (pump-one! endpoint)))
               (= (snapshot endpoint "pending_requests") 1)))
        (send-present! endpoint peer (present-for current "current"))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "revoked"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((action (host-action! endpoint "submit" "input")))
      (revoke-surface! endpoint)
      (test-equal "revocation clears pending and live handles" '(revoked 0 0)
        (list (snapshot endpoint "state")
              (snapshot endpoint "pending_requests")
              (snapshot endpoint "live_handles")))
      (test-equal "revocation closes transport before any late result"
        '(closed #t)
        (list (endpoint-pump-result-status
               (endpoint-pump-input! endpoint))
              (eof-object? (get-u8 peer))))
      (test-equal "revoked endpoint rejects host action" 'state
        (session-error-kind
         (lambda () (host-action! endpoint "submit" "later")))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "terminal-bound"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((old #f))
      (for-each
       (lambda (index)
         (let ((action (host-action! endpoint
                                     (format #f "action-~a" index) "input")))
           (unless old (set! old action))
           (send-present! endpoint peer (present-for action "done"))))
       (iota (+ max-terminal-requests 4)))
      (test-equal "terminal request memory remains bounded"
        max-terminal-requests (snapshot endpoint "retained_terminal_requests"))
      (write-frame peer (present-for old "old duplicate"))
      (test-equal "evicted history is unknown, never valid" 'state
        (session-error-kind
         (lambda () (pump-one! endpoint)))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "allocation"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (test-equal "entropy failure leaves sequence and pending unchanged"
      '(entropy-failure 0 0)
      (let ((failure
             (catch 'entropy-failure
               (lambda ()
                 (parameterize
                     ((random-token-source-for-test
                       (lambda () (throw 'entropy-failure))))
                   (host-action! endpoint "submit" "input"))
                 #f)
               (lambda arguments 'entropy-failure))))
        (list failure
              (snapshot endpoint "sequence")
              (snapshot endpoint "pending_requests"))))
    (let ((reentrant-kind #f))
      (parameterize
          ((random-token-source-for-test
            (lambda ()
              (set! reentrant-kind
                    (session-error-kind
                     (lambda () (revoke-surface! endpoint))))
              "cooperative-reentry-token")))
        (test-equal "outer action commits after cooperative reentry rejection" 1
          (field (host-action! endpoint "submit" "input") "sequence")))
      (test-equal "same-thread transition reentry is rejected" 'busy
        reentrant-kind)
      (test-equal "reentry cannot revoke or add a second transition" '(active 1)
        (list (snapshot endpoint "state")
              (snapshot endpoint "pending_requests"))))
    (close-fixture! endpoint peer)))

(let ((host (make-book-session-host)))
  (call-with-values
      (lambda () (open-on-host host "same-label"))
    (lambda (endpoint-a peer-a)
      (call-with-values
          (lambda () (open-on-host host "same-label"))
        (lambda (endpoint-b peer-b)
          (initialize! endpoint-a peer-a)
          (initialize! endpoint-b peer-b)
          (let ((action-a (host-action! endpoint-a "submit" "a"))
                (action-b (host-action! endpoint-b "submit" "b")))
            ;; Every token is known; only the source endpoint differs.
            (write-frame peer-b (present-for action-a "from-a-on-b"))
            (test-equal
                "A tokens arriving on B socket cannot select A authority"
              'authority
              (session-error-kind (lambda () (pump-one! endpoint-b))))
            (write-frame peer-a (present-for action-b "from-b-on-a"))
            (test-equal
                "B tokens arriving on A socket cannot select B authority"
              'authority
              (session-error-kind (lambda () (pump-one! endpoint-a))))
            (test-equal "cross-socket attempts consume neither request" '(1 1)
              (list (snapshot endpoint-a "pending_requests")
                    (snapshot endpoint-b "pending_requests")))
            (test-equal
                "each captured endpoint accepts only its own pending result"
              '(accepted-a accepted-b)
              (list
               (begin
                 (send-present! endpoint-a peer-a
                                (present-for action-a "accepted-a"))
                 'accepted-a)
               (begin
                 (send-present! endpoint-b peer-b
                                (present-for action-b "accepted-b"))
                 'accepted-b))))
          (close-fixture! endpoint-a peer-a)
          (close-fixture! endpoint-b peer-b))))))

(let ((host (make-book-session-host))
      (fixtures '()))
  (do ((index 0 (+ index 1)))
      ((= index max-sessions))
    (call-with-values
        (lambda () (open-on-host host (format #f "bounded-~a" index)))
      (lambda (endpoint peer)
        (set! fixtures (cons (cons endpoint peer) fixtures)))))
  (let ()
    (test-equal "host registry rejects a ninth endpoint" 'state
      (session-error-kind
       (lambda () (open-on-host host "ninth"))))
    (let ((released (car fixtures)))
      (release-session-endpoint! (car released))
      (close-port (cdr released))
      (set! fixtures (cdr fixtures)))
    (call-with-values
        (lambda () (open-on-host host "replacement"))
      (lambda (replacement peer)
        (test-assert "explicit release admits one replacement endpoint"
          (session-endpoint? replacement))
        (set! fixtures (cons (cons replacement peer) fixtures)))))
  (for-each
   (lambda (fixture)
     (release-session-endpoint! (car fixture))
     (close-port (cdr fixture)))
   fixtures))

(test-assert
    "same-port/cross-host and dup registration are absent from runtime API"
  (let ((interface (resolve-interface '(book-session))))
    (every (lambda (name) (not (module-variable interface name)))
           '(register-session-endpoint!
             session-endpoint-file-descriptor
             endpoint-binding-socket))))

(call-with-values
    (lambda () (make-fixture "old-endpoint"))
  (lambda (host old-endpoint old-peer)
    (let* ((old-fd (fileno (endpoint-socket-for-test old-endpoint)))
           (duplicate (dup old-fd))
           (duplicate-port (fdopen duplicate "r+b"))
           (old-initialize (initialize! old-endpoint old-peer))
           (old-session-id (snapshot old-endpoint "session_id"))
           (old-action (host-action! old-endpoint "submit" "old")))
      (call-with-values
          (lambda () (restart-session! old-endpoint "new-endpoint"))
        (lambda (new-endpoint new-peer)
          (test-equal
              "restart factory invalidates old authority and old peer"
            '(closed awaiting-hello #t 0)
            (list (snapshot old-endpoint "state")
                  (snapshot new-endpoint "state")
                  (eof-object? (get-u8 old-peer))
                  (recv! duplicate-port (make-bytevector 1))))
          (test-equal "delayed old input pump observes closed lifetime" 'closed
            (endpoint-pump-result-status
             (endpoint-pump-input! old-endpoint)))
          (test-equal "delayed synchronous expiry retains old endpoint epoch"
            'state
            (session-error-kind
             (lambda ()
               (expire-request! old-endpoint
                                (field old-action "request_id")))))
          (test-equal "restart does not auto-activate host actions" 'state
            (session-error-kind
             (lambda () (host-action! new-endpoint "submit" "too early"))))
          (let ((new-initialize (initialize! new-endpoint new-peer)))
            (test-assert "restart creates fresh session and surface strings"
              (and (not (string=? old-session-id
                                  (snapshot new-endpoint "session_id")))
                   (not (string=?
                         (field old-initialize "surface_handle")
                         (field new-initialize "surface_handle")))))
            (write-frame new-peer (present-for old-action
                                               "old exact response"))
            (test-equal
                "old exact response cannot cross fresh endpoint binding"
              'authority
              (session-error-kind (lambda () (pump-one! new-endpoint))))
            (let ((new-action
                   (host-action! new-endpoint "submit" "new")))
              (test-equal "fresh endpoint completes its own interaction"
                "new result"
                (presented-text-value
                 (send-present! new-endpoint new-peer
                                (present-for new-action "new result"))))))
          (close-port duplicate-port)
          (close-port old-peer)
          (close-fixture! new-endpoint new-peer))))))

(call-with-values
    (lambda () (make-fixture "numeric-fd-old"))
  (lambda (host old-endpoint old-peer)
    (let ((old-fd (fileno (endpoint-socket-for-test old-endpoint))))
      (release-session-endpoint! old-endpoint)
      (call-with-values
          (lambda () (open-on-host host "numeric-fd-new"))
        (lambda (new-endpoint new-peer)
          (test-equal "fresh factory connection may safely reuse numeric FD"
            old-fd (fileno (endpoint-socket-for-test new-endpoint)))
          (test-equal "old object cannot dispatch through reused numeric FD"
            'closed
            (endpoint-pump-result-status
             (endpoint-pump-input! old-endpoint)))
          (initialize! new-endpoint new-peer)
          (close-port old-peer)
          (close-fixture! new-endpoint new-peer))))))

(test-equal "restart accepts no caller-supplied donor descriptor"
  '(2 0 #f)
  (procedure-minimum-arity restart-session!))

(call-with-values
    (lambda () (make-fixture "restart-allocation-failure"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let* ((session-id (snapshot endpoint "session_id"))
           (repeated-token (substring session-id (string-length "session_"))))
      (test-equal "restart allocation failure leaves old endpoint authoritative"
        '(state active 1)
        (list
         (parameterize
             ((random-token-source-for-test (lambda () repeated-token)))
           (session-error-kind
            (lambda () (restart-session! endpoint "must-not-publish"))))
         (snapshot endpoint "state")
         (field (host-action! endpoint "still-live" "input") "sequence"))))
    (close-fixture! endpoint peer)))

(let ((frame (raw-frame "{\"type\":\"hello\",\"version\":1}")))
  (do ((split 1 (+ split 1)))
      ((= split (bytevector-length frame)))
    (call-with-values
        (lambda () (make-fixture (format #f "partial-~a" split)))
      (lambda (host endpoint peer)
        (send-range peer frame 0 split)
        (let ((partial (endpoint-pump-input! endpoint)))
          (test-equal
              (format #f "partial frame boundary ~a returns EAGAIN" split)
            '(would-block 0 awaiting-hello)
            (list (endpoint-pump-result-status partial)
                  (endpoint-pump-result-frames partial)
                  (snapshot endpoint "state"))))
        (send-range peer frame split (- (bytevector-length frame) split))
        (test-equal
            (format #f "partial frame boundary ~a resumes exactly once" split)
          '("initialize" active)
          (list (field (pump-one! endpoint) "type")
                (snapshot endpoint "state")))
        (close-fixture! endpoint peer)))))

(call-with-values
    (lambda () (make-fixture "silent-peer"))
  (lambda (host endpoint peer)
    (let ((result (endpoint-pump-input! endpoint)))
      (test-equal "silent peer makes bounded input pump return immediately"
        '(would-block 0 0)
        (list (endpoint-pump-result-status result)
              (endpoint-pump-result-bytes result)
              (endpoint-pump-result-frames result))))
    (close-session! endpoint)
    (test-equal "silent peer cannot delay close transition" '(closed #t)
      (list (snapshot endpoint "state") (eof-object? (get-u8 peer))))
    (close-port peer)))

(call-with-values
    (lambda () (make-fixture "readiness"))
  (lambda (host endpoint peer)
    (test-equal "private endpoint readiness starts empty"
      '() (endpoint-ready-events endpoint))
    (endpoint-queue-message! endpoint '(("type" . "queued")))
    (write-frame peer '(("type" . "hello") ("version" . 1)))
    (test-equal "readiness reports input and queued output without exposing FD"
      '(input output) (endpoint-ready-events endpoint))
    (close-session! endpoint)
    (test-equal "closed endpoint reports no readiness events"
      '() (endpoint-ready-events endpoint))
    (close-port peer)))

(call-with-values
    (lambda () (make-fixture "input-byte-budget"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let* ((action (host-action! endpoint "submit" "input"))
           (text (make-string max-present-text-bytes #\x))
           (frame (encode-frame (present-for action text))))
      (put-bytevector peer frame)
      (force-output peer)
      (let ((first (endpoint-pump-input! endpoint)))
        (test-equal "input pump enforces its per-call byte budget"
          `(budget ,max-input-bytes-per-pump 0 1)
          (list (endpoint-pump-result-status first)
                (endpoint-pump-result-bytes first)
                (endpoint-pump-result-frames first)
                (snapshot endpoint "pending_requests"))))
      (test-equal "next input pump completes the buffered large frame"
        max-present-text-bytes
        (string-length (presented-text-value (pump-one! endpoint)))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "success-success-delivery"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((actions
           (map (lambda (index)
                   (host-action! endpoint (format #f "batch-~a" index) "x"))
                (iota 2))))
      (send-frames-together
       peer
       (encode-frame (present-for (car actions) "first"))
       (encode-frame (present-for (cadr actions) "second")))
      (let* ((first (endpoint-pump-input! endpoint))
             (ready-after-first (endpoint-ready-events endpoint))
             (second (endpoint-pump-input! endpoint))
             (third (endpoint-pump-input! endpoint)))
        (test-equal "success/success results are delivered once in order"
          '((committed 1 "first")
            (input)
            (committed 1 "second")
            (would-block 0 0)
            (0 2))
          (list
           (list (endpoint-pump-result-status first)
                 (endpoint-pump-result-frames first)
                 (presented-text-value
                  (car (endpoint-pump-result-values first))))
           ready-after-first
           (list (endpoint-pump-result-status second)
                 (endpoint-pump-result-frames second)
                 (presented-text-value
                  (car (endpoint-pump-result-values second))))
           (list (endpoint-pump-result-status third)
                 (endpoint-pump-result-frames third)
                 (length (endpoint-pump-result-values third)))
           (list (snapshot endpoint "pending_requests")
                 (snapshot endpoint "retained_terminal_requests"))))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "valid-hello-bad-follower"))
  (lambda (host endpoint peer)
    (send-frames-together
     peer
     (raw-frame "{\"type\":\"hello\",\"version\":1}")
     (raw-frame "{\"type\":\"hello\",\"version\":1.0}"))
    (let ((first (endpoint-pump-input! endpoint)))
      (test-equal "valid hello returns initialize before bad schema follower"
        '(committed "initialize" active)
        (list (endpoint-pump-result-status first)
              (field (car (endpoint-pump-result-values first)) "type")
              (snapshot endpoint "state")))
      (test-equal "buffered bad hello remains ready without kernel bytes"
        '(#f (input))
        (list (kernel-input-ready? endpoint)
              (endpoint-ready-events endpoint))))
    (test-equal "bad hello follower rejects only on its own pump" 'schema
      (session-error-kind (lambda () (endpoint-pump-input! endpoint))))
    (let ((after (endpoint-pump-input! endpoint)))
      (test-equal "initialize is not redelivered after follower rejection"
        '(would-block 0 0 active)
        (list (endpoint-pump-result-status after)
              (endpoint-pump-result-frames after)
              (length (endpoint-pump-result-values after))
              (snapshot endpoint "state"))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "valid-present-bad-follower"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((action (host-action! endpoint "submit" "input")))
      (send-frames-together
       peer
       (encode-frame (present-for action "accepted-first"))
       (raw-frame (present-json action "count" "1.0")))
      (let ((first (endpoint-pump-input! endpoint)))
        (test-equal
            "valid present returns result before bad schema follower"
          '(committed "accepted-first" 0 1 (input))
          (list
           (endpoint-pump-result-status first)
           (presented-text-value
            (car (endpoint-pump-result-values first)))
           (snapshot endpoint "pending_requests")
           (snapshot endpoint "retained_terminal_requests")
           (endpoint-ready-events endpoint))))
      (test-equal "bad present follower rejects on next pump" 'schema
        (session-error-kind (lambda () (endpoint-pump-input! endpoint))))
      (let ((after (endpoint-pump-input! endpoint)))
        (test-equal "presented result is never redelivered"
          '(would-block 0 0)
          (list (endpoint-pump-result-status after)
                (endpoint-pump-result-frames after)
                (length (endpoint-pump-result-values after))))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "bad-first-valid-follower"))
  (lambda (host endpoint peer)
    (send-frames-together
     peer
     (raw-frame "{\"type\":\"hello\",\"version\":1.0}")
     (raw-frame "{\"type\":\"hello\",\"version\":1}"))
    (test-equal "bad first frame rejects without committing follower" 'schema
      (session-error-kind (lambda () (endpoint-pump-input! endpoint))))
    (test-equal "valid follower remains ready after ordinary schema rejection"
      '(awaiting-hello (input))
      (list (snapshot endpoint "state") (endpoint-ready-events endpoint)))
    (let ((second (endpoint-pump-input! endpoint))
          (third #f))
      (set! third (endpoint-pump-input! endpoint))
      (test-equal "valid follower commits once on the next pump"
        '((committed "initialize" active) (would-block 0 0))
        (list
         (list (endpoint-pump-result-status second)
               (field (car (endpoint-pump-result-values second)) "type")
               (snapshot endpoint "state"))
         (list (endpoint-pump-result-status third)
               (endpoint-pump-result-frames third)
               (length (endpoint-pump-result-values third))))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "valid-present-terminal-follower"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((action (host-action! endpoint "submit" "input")))
      (send-frames-together
       peer
       (encode-frame (present-for action "delivered-before-terminal"))
       (make-bytevector 4 0))
      (let ((first (endpoint-pump-input! endpoint)))
        (test-equal
            "valid present is delivered before zero-length terminal follower"
          '(committed "delivered-before-terminal" (input))
          (list
           (endpoint-pump-result-status first)
           (presented-text-value
            (car (endpoint-pump-result-values first)))
           (endpoint-ready-events endpoint))))
      (test-assert "terminal follower closes only on its own pump"
        (protocol-error? (lambda () (endpoint-pump-input! endpoint))))
      (let ((after (endpoint-pump-input! endpoint)))
        (test-equal "terminal close cannot hide or redeliver prior result"
          '(closed 0 0 closed)
          (list (endpoint-pump-result-status after)
                (endpoint-pump-result-frames after)
                (length (endpoint-pump-result-values after))
                (snapshot endpoint "state")))))
    (close-port peer)))

(call-with-values
    (lambda () (make-fixture "close-between-input-pumps"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((first-action (host-action! endpoint "first" "input"))
          (second-action (host-action! endpoint "second" "input")))
      (send-frames-together
       peer
       (encode-frame (present-for first-action "first-result"))
       (encode-frame (present-for second-action "must-stay-stale")))
      (let ((first (endpoint-pump-input! endpoint)))
        (test-equal "first queued presentation commits before close"
          '(committed "first-result" 1 (input))
          (list
           (endpoint-pump-result-status first)
           (presented-text-value
            (car (endpoint-pump-result-values first)))
           (snapshot endpoint "pending_requests")
           (endpoint-ready-events endpoint))))
      (close-session! endpoint)
      (let ((late (endpoint-pump-input! endpoint)))
        (test-equal "close between pumps leaves queued late frame stale"
          '(closed 0 0 closed 0 2 ())
          (list (endpoint-pump-result-status late)
                (endpoint-pump-result-frames late)
                (length (endpoint-pump-result-values late))
                (snapshot endpoint "state")
                (snapshot endpoint "pending_requests")
                (snapshot endpoint "retained_terminal_requests")
                (endpoint-ready-events endpoint)))))
    (close-port peer)))

(call-with-values
    (lambda () (make-fixture "output-backpressure"))
  (lambda (host endpoint peer)
    (setsockopt (endpoint-socket-for-test endpoint)
                SOL_SOCKET SO_SNDBUF 4096)
    (let ((message `(("type" . "bulk")
                     ("text" . ,(make-string 60000 #\x)))))
      (do ((index 0 (+ index 1)))
          ((= index max-outbound-frames))
        (endpoint-queue-message! endpoint message))
      (test-equal "outbound frame queue rejects its ninth frame" 'backpressure
        (session-error-kind
         (lambda () (endpoint-queue-message! endpoint message))))
      (let loop ((attempts 0) (within-budgets? #t))
        (when (= attempts 1000)
          (error "never-read peer did not exert socket backpressure"))
        (let ((result (endpoint-pump-output! endpoint)))
          (let ((within-budgets?
                 (and within-budgets?
                      (<= (endpoint-pump-result-bytes result)
                          max-output-bytes-per-pump)
                      (<= (endpoint-pump-result-frames result)
                          max-output-frames-per-pump))))
            (if (eq? (endpoint-pump-result-status result) 'would-block)
                (test-assert
                    "each output pump stays within byte/frame budgets"
                  within-budgets?)
                (loop (+ attempts 1) within-budgets?)))))
      (test-assert "never-read peer leaves only bounded queued output"
        (and (positive? (snapshot endpoint "outbound_bytes"))
             (<= (snapshot endpoint "outbound_bytes") max-outbound-bytes)
             (<= (snapshot endpoint "outbound_frames")
                 max-outbound-frames))))
    (let ((gate (make-mutex))
          (condition (make-condition-variable))
          (entered? #f)
          (release? #f))
      (define (blocking-send-hook ignored-endpoint ignored-count)
        (lock-mutex gate)
        (set! entered? #t)
        (signal-condition-variable condition)
        (let wait ()
          (unless release?
            (wait-condition-variable condition gate)
            (wait)))
        (unlock-mutex gate))
      (let ((writer
             (call-with-new-thread
              (lambda ()
                (parameterize
                    ((send-attempt-hook-for-test blocking-send-hook))
                  (catch #t
                    (lambda ()
                      (endpoint-pump-result-status
                       (endpoint-pump-output! endpoint)))
                    (lambda (key . arguments) key)))))))
        (lock-mutex gate)
        (let wait ()
          (unless entered?
            (wait-condition-variable condition gate)
            (wait)))
        (test-equal "second concurrent output owner is rejected" 'busy
          (session-error-kind (lambda () (endpoint-pump-output! endpoint))))
        (close-session! endpoint)
        (test-equal "close commits while output owner is paused" '(closed #f)
          (list (snapshot endpoint "state")
                (snapshot endpoint "transport_open")))
        (set! release? #t)
        (signal-condition-variable condition)
        (unlock-mutex gate)
        (let ((writer-result (join-thread writer)))
          (test-assert "late output attempt cannot revive closed lifetime"
            (and (memq writer-result
                       '(closed stale system-error wrong-type-arg misc-error))
                 (eq? (snapshot endpoint "state") 'closed)))))
    (close-port peer))))

(call-with-values
    (lambda () (make-fixture "disconnected-output"))
  (lambda (host endpoint peer)
    (endpoint-queue-message! endpoint '(("type" . "queued-before-close")))
    (close-port peer)
    (let ((key
           (catch #t
             (lambda ()
               (endpoint-pump-output! endpoint)
               #f)
             (lambda (key . arguments) key))))
      (test-equal "disconnected output becomes caught EPIPE, not SIGPIPE"
        '(system-error closed #f)
        (list key
              (snapshot endpoint "state")
              (snapshot endpoint "transport_open"))))))

(call-with-values
    (lambda () (make-fixture "output-frame-budget"))
  (lambda (host endpoint peer)
    (do ((index 0 (+ index 1)))
        ((= index max-outbound-frames))
      (endpoint-queue-message!
       endpoint `(("type" . "small") ("index" . ,index))))
    (let* ((first (endpoint-pump-output! endpoint))
           (after-first (snapshot endpoint "outbound_frames"))
           (second (endpoint-pump-output! endpoint))
           (after-second (snapshot endpoint "outbound_frames"))
           (third (endpoint-pump-output! endpoint))
           (after-third (snapshot endpoint "outbound_frames")))
      (test-equal "output frame budget requires two bounded pumps plus drain"
        `((budget ,max-output-frames-per-pump 4)
          (budget ,max-output-frames-per-pump 0)
          (drained 0 0))
        (list
         (list (endpoint-pump-result-status first)
               (endpoint-pump-result-frames first)
               after-first)
         (list (endpoint-pump-result-status second)
               (endpoint-pump-result-frames second)
               after-second)
         (list (endpoint-pump-result-status third)
               (endpoint-pump-result-frames third)
               after-third)))
      (test-equal "queued output preserves FIFO frame order"
        (iota max-outbound-frames)
        (map (lambda (ignored) (field (read-frame peer) "index"))
             (iota max-outbound-frames))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "stale-decode"))
  (lambda (host old-endpoint old-peer)
    (let ((gate (make-mutex))
          (condition (make-condition-variable))
          (decoded? #f)
          (release? #f))
      (define (blocking-decode-hook ignored-endpoint ignored-message)
        (lock-mutex gate)
        (set! decoded? #t)
        (signal-condition-variable condition)
        (let wait ()
          (unless release?
            (wait-condition-variable condition gate)
            (wait)))
        (unlock-mutex gate))
      (write-frame old-peer '(("type" . "hello") ("version" . 1)))
      (let ((reader
             (call-with-new-thread
              (lambda ()
                (parameterize
                    ((decoded-message-hook-for-test blocking-decode-hook))
                  (endpoint-pump-input! old-endpoint))))))
        (lock-mutex gate)
        (let wait ()
          (unless decoded?
            (wait-condition-variable condition gate)
            (wait)))
        (test-equal "second concurrent input owner is rejected" 'busy
          (session-error-kind
           (lambda () (endpoint-pump-input! old-endpoint))))
        (call-with-values
            (lambda () (open-on-host host "unrelated-while-read-paused"))
          (lambda (unrelated unrelated-peer)
            (test-assert "paused peer decode does not hold host registry mutex"
              (session-endpoint? unrelated))
            (call-with-values
                (lambda () (restart-session! old-endpoint "after-stale-read"))
              (lambda (replacement replacement-peer)
                (test-equal
                    "restart invalidates before paused decode may commit"
                  '(closed awaiting-hello #t)
                  (list (snapshot old-endpoint "state")
                        (snapshot replacement "state")
                        (eof-object? (get-u8 old-peer))))
                (set! release? #t)
                (signal-condition-variable condition)
                (unlock-mutex gate)
                (let ((late-result (join-thread reader)))
                  (test-equal "unblocked decoded frame is stale, not committed"
                    '(stale 0 0 closed awaiting-hello)
                    (list (endpoint-pump-result-status late-result)
                          (endpoint-pump-result-frames late-result)
                          (length (endpoint-pump-result-values late-result))
                          (snapshot old-endpoint "state")
                          (snapshot replacement "state"))))
                (initialize! replacement replacement-peer)
                (release-session-endpoint! unrelated)
                (close-port unrelated-peer)
                (close-port old-peer)
                (close-fixture! replacement replacement-peer)))))))))

(call-with-values
    (lambda () (make-fixture "thread-actions"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((gate (make-mutex))
          (condition (make-condition-variable))
          (started 0)
          (allocator-entered? #f)
          (release-allocator? #f)
          (token-number 0)
          (threads '()))
      (define (token-source)
        (lock-mutex gate)
        (set! allocator-entered? #t)
        (broadcast-condition-variable condition)
        (let wait ()
          (unless release-allocator?
            (wait-condition-variable condition gate)
            (wait)))
        (set! token-number (+ token-number 1))
        (let ((token (format #f "thread-token-~a" token-number)))
          (unlock-mutex gate)
          token))
      (define (worker index)
        (parameterize ((random-token-source-for-test token-source))
          (lock-mutex gate)
          (set! started (+ started 1))
          (broadcast-condition-variable condition)
          (unlock-mutex gate)
          (catch 'book-session-error
            (lambda () (cons 'action
                             (host-action! endpoint
                                           (format #f "thread-~a" index)
                                           "input")))
            (lambda (_ kind message) (cons 'error kind)))))
      (set! threads
            (map (lambda (index) (call-with-new-thread
                                  (lambda () (worker index))))
                 (iota (+ max-pending-requests 1))))
      (lock-mutex gate)
      (let wait ()
        (unless (and (= started (+ max-pending-requests 1))
                     allocator-entered?)
          (wait-condition-variable condition gate)
          (wait)))
      (set! release-allocator? #t)
      (broadcast-condition-variable condition)
      (unlock-mutex gate)
      (let* ((results (map join-thread threads))
             (actions (filter (lambda (result) (eq? (car result) 'action))
                              results))
             (errors (filter (lambda (result) (eq? (car result) 'error))
                             results))
             (sequences
              (sort (map (lambda (result)
                           (field (cdr result) "sequence"))
                         actions)
                    <)))
        (test-equal "five simultaneous actions serialize to four plus reject"
          '(4 (state))
          (list (length actions) (map cdr errors)))
        (test-equal "threaded actions retain unique sequences and pending cap"
          '((1 2 3 4) 4)
          (list sequences (snapshot endpoint "pending_requests")))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "reply-expiry-race"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let* ((action (host-action! endpoint "submit" "input"))
           (request-id (field action "request_id")))
      (write-frame peer (present-for action "race result"))
      (let* ((reply-thread
              (call-with-new-thread
               (lambda ()
                 (thread-outcome
                  (lambda () (pump-one! endpoint))
                  'presented))))
             (expiry-thread
              (call-with-new-thread
               (lambda ()
                 (thread-outcome
                  (lambda () (expire-request! endpoint request-id))
                  'expired))))
             (outcomes (list (join-thread reply-thread)
                             (join-thread expiry-thread))))
        (test-assert "reply/expiry race has exactly one terminal winner"
          (or (equal? outcomes '(presented state))
              (equal? outcomes '(state expired))))
        (test-equal "reply/expiry race leaves one terminal and no pending"
          '(0 1)
          (list (snapshot endpoint "pending_requests")
                (snapshot endpoint "retained_terminal_requests")))))
    (close-fixture! endpoint peer)))

(call-with-values
    (lambda () (make-fixture "endpoint-eof"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (host-action! endpoint "submit" "input")
    (close-port peer)
    (test-assert "clean endpoint EOF closes authority"
      (eof-object? (pump-one! endpoint)))
    (test-equal "EOF retires pending work and rejects delayed owner event"
      '(closed 0 state)
      (list (snapshot endpoint "state")
            (snapshot endpoint "pending_requests")
            (session-error-kind
             (lambda () (host-action! endpoint "late" "input")))))))

(call-with-values
    (lambda () (make-fixture "endpoint-frame-error"))
  (lambda (host endpoint peer)
    (put-bytevector peer (u8-list->bytevector '(0 0 0 0)))
    (force-output peer)
    (test-assert "generic framing error closes captured endpoint"
      (protocol-error? (lambda () (pump-one! endpoint))))
    (test-equal "framing failure leaves no live endpoint authority" '(closed 0)
      (list (snapshot endpoint "state") (snapshot endpoint "live_handles")))
    (close-port peer)))

(call-with-values
    (lambda () (make-fixture "action-revoke-race"))
  (lambda (host endpoint peer)
    (initialize! endpoint peer)
    (let ((gate (make-mutex))
          (condition (make-condition-variable))
          (entered? #f)
          (release? #f))
      (define (blocked-token)
        (lock-mutex gate)
        (set! entered? #t)
        (signal-condition-variable condition)
        (let wait ()
          (unless release?
            (wait-condition-variable condition gate)
            (wait)))
        (unlock-mutex gate)
        "action-before-revoke-token")
      (let ((action-thread
             (call-with-new-thread
              (lambda ()
                (parameterize ((random-token-source-for-test blocked-token))
                  (host-action! endpoint "submit" "input"))))))
        (lock-mutex gate)
        (let wait ()
          (unless entered?
            (wait-condition-variable condition gate)
            (wait)))
        (let ((revoke-thread
               (call-with-new-thread (lambda () (revoke-surface! endpoint)))))
          (set! release? #t)
          (signal-condition-variable condition)
          (unlock-mutex gate)
          (let ((action (join-thread action-thread)))
            (join-thread revoke-thread)
            (test-equal "revoke waits for whole action transaction then retires it"
              '(revoked 0 1)
              (list (snapshot endpoint "state")
                    (snapshot endpoint "pending_requests")
                    (snapshot endpoint "retained_terminal_requests")))
            (test-equal "serialized revoke permits no post-revoke result"
              '(closed #t)
              (list (endpoint-pump-result-status
                     (endpoint-pump-input! endpoint))
                    (eof-object? (get-u8 peer))))))))
    (close-fixture! endpoint peer)))

(define (run-inherited-alias-shutdown)
  (force-output (current-output-port))
  (force-output (current-error-port))
  (call-with-values
      (lambda () (make-fixture "inherited-host-alias"))
    (lambda (host old-endpoint old-peer)
      (let* ((control (pipe))
             (control-input (car control))
             (control-output (cdr control))
             (pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (close-port control-output)
              (close-port old-peer)
              (catch #t
                (lambda ()
                  (get-u8 control-input)
                  (let ((count
                         (recv! (endpoint-socket-for-test old-endpoint)
                                (make-bytevector 1))))
                    (close-port (endpoint-socket-for-test old-endpoint))
                    (close-port control-input)
                    (primitive-exit (if (zero? count) 0 81))))
                (lambda arguments (primitive-exit 90))))
            (begin
              (close-port control-input)
              (call-with-values
                  (lambda ()
                    (restart-session! old-endpoint "after-inherited-alias"))
                (lambda (replacement replacement-peer)
                  (put-u8 control-output 1)
                  (force-output control-output)
                  (close-port control-output)
                  (let* ((waited (waitpid pid))
                         (exit-value (status:exit-val (cdr waited)))
                         (old-peer-eof? (eof-object? (get-u8 old-peer))))
                    (close-port old-peer)
                    (release-session-endpoint! replacement)
                    (close-port replacement-peer)
                    (list exit-value old-peer-eof?))))))))))

(test-equal
    "restart shutdown defeats an inherited copy of the old broker descriptor"
  '(0 #t)
  (run-inherited-alias-shutdown))

(define (run-inherited-fd-trace)
  (force-output (current-output-port))
  (force-output (current-error-port))
  (let ((host (make-book-session-host)))
    (call-with-values
        (lambda () (open-on-host host "inherited-child"))
      (lambda (endpoint peer)
        (let ((pid (primitive-fork)))
          (if (zero? pid)
              (begin
                ;; Guix e343ff0's inferior launcher closes the unused end in
                ;; each process.  The child is only the herd-like client here;
                ;; the parent retains the Shepherd-like authority endpoint.
                (close-port (endpoint-socket-for-test endpoint))
                (catch #t
                  (lambda ()
                    (write-frame peer
                                 '(("type" . "hello") ("version" . 1)))
                    (let* ((initialize (read-frame peer))
                           (action (read-frame peer)))
                      (send-raw peer
                                (present-json action "sequence" "1.0"))
                      (let ((rejected (read-frame peer)))
                        (write-frame peer
                                     (present-for action "Hello, Ada"))
                        (let ((accepted (read-frame peer)))
                          (unless
                              (equal?
                               (list (field initialize "type")
                                     (field action "type")
                                     (field rejected "type")
                                     (field rejected "pending")
                                     (field accepted "type")
                                     (field accepted "text"))
                               '("initialize" "action" "rejected" 1
                                 "accepted" "Hello, Ada"))
                            (primitive-exit 81)))))
                    (close-port peer)
                    (primitive-exit 0))
                  (lambda arguments (primitive-exit 90))))
              (begin
                (close-port peer)
                (alarm 10)
                (let ((initialize (pump-one/eventually! endpoint)))
                  (queue-and-flush! endpoint initialize)
                  (let ((action
                         (host-action! endpoint "submit-name" "Ada")))
                    (queue-and-flush! endpoint action)
                    (let ((kind
                           (session-error-kind
                            (lambda ()
                              (pump-one/eventually! endpoint)))))
                      (unless (and (eq? kind 'schema)
                                   (= (snapshot endpoint
                                                "pending_requests")
                                      1))
                        (error "child lexical rejection was not atomic"))
                      (queue-and-flush!
                       endpoint
                       '(("type" . "rejected") ("pending" . 1))))
                    (let ((result (pump-one/eventually! endpoint)))
                      (queue-and-flush!
                       endpoint
                       `(("type" . "accepted")
                         ("text" . ,(presented-text-value result)))))))
                (let* ((waited (waitpid pid))
                       (exit-value (status:exit-val (cdr waited))))
                  (alarm 0)
                  (release-session-endpoint! endpoint)
                  exit-value))))))))

(test-equal "forked Guile authority owns inherited-FD strict dispatch trace"
  0
  (run-inherited-fd-trace))

(test-end "book-session-guile")
