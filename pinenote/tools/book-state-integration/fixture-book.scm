;;; Native Guile fixture book for the trusted Book State integration proof.
;;; Its only protocol channel is the connected socket donated as FD 0.
(use-modules (book-protocol blocking-io)
             (ice-9 ftw)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

(define initialize-fields
  '("type" "version" "grant_count" "surface_handle"
    "surface_generation" "max_pending_requests" "max_present_text_bytes"))
(define state-ready-fields
  '("type" "protocol_version" "grant_handle" "grant_generation" "access"))
(define state-value-fields
  '("type" "protocol_version" "present" "state_version" "text"))
(define committed-fields
  '("type" "protocol_version" "operation_id" "state_version" "text_bytes"))
(define action-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "text"))
(define max-state-text-bytes 4096)

(define (fail message . details)
  (error message details))

(define (field message name)
  (let ((entry (assoc name message)))
    (and entry (cdr entry))))

(define (exact-fields? message expected)
  (and (list? message)
       (= (length message) (length expected))
       (every (lambda (entry)
                (and (pair? entry)
                     (string? (car entry))
                     (member (car entry) expected string=?)))
              message)
       (every (lambda (name) (assoc name message)) expected)))

(define (require-integer value)
  (and (integer? value) (exact? value)))

(define (require-initialize message)
  (unless (and (exact-fields? message initialize-fields)
               (string=? (field message "type") "initialize")
               (eqv? (field message "version") 1)
               (eqv? (field message "grant_count") 1)
               (string? (field message "surface_handle"))
               (not (string-null? (field message "surface_handle")))
               (eqv? (field message "surface_generation") 1)
               (eqv? (field message "max_pending_requests") 4)
               (eqv? (field message "max_present_text_bytes") 4096))
    (fail "initialize did not match the fixed native fixture")))

(define (require-state-ready message)
  (unless (and (exact-fields? message state-ready-fields)
               (string=? (field message "type") "state-ready")
               (eqv? (field message "protocol_version") 1)
               (string? (field message "grant_handle"))
               (not (string-null? (field message "grant_handle")))
               (require-integer (field message "grant_generation"))
               (> (field message "grant_generation") 0)
               (string=? (field message "access") "read-write"))
    (fail "state-ready did not match the fixed native fixture")))

(define (require-state-value message)
  (unless (and (exact-fields? message state-value-fields)
               (string=? (field message "type") "state-value")
               (eqv? (field message "protocol_version") 1)
               (boolean? (field message "present"))
               (require-integer (field message "state_version"))
               (>= (field message "state_version") 0)
               (string? (field message "text"))
               (<= (bytevector-length (string->utf8 (field message "text")))
                   max-state-text-bytes)
               (if (field message "present")
                   (> (field message "state_version") 0)
                   (and (zero? (field message "state_version"))
                        (string-null? (field message "text")))))
    (fail "state-value did not match the fixed native fixture"))
  message)

(define (require-action message action-id)
  (unless (and (exact-fields? message action-fields)
               (string=? (field message "type") "action")
               (string=? (field message "action_id") action-id)
               (string? (field message "request_id"))
               (not (string-null? (field message "request_id")))
               (string? (field message "surface_handle"))
               (not (string-null? (field message "surface_handle")))
               (require-integer (field message "surface_generation"))
               (require-integer (field message "sequence"))
               (string? (field message "text")))
    (fail "action did not match the fixed native fixture" action-id))
  message)

(define (require-committed message operation-id expected-version text)
  (let ((bytes (bytevector-length (string->utf8 text))))
    (unless (and (exact-fields? message committed-fields)
                 (string=? (field message "type") "state-committed")
                 (eqv? (field message "protocol_version") 1)
                 (string=? (field message "operation_id") operation-id)
                 (= (field message "state_version") (+ expected-version 1))
                 (= (field message "text_bytes") bytes))
      (fail "state-committed did not match the exact request")))
  message)

(define (state-read ready)
  `(("type" . "state-read")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))))

(define (state-commit ready operation-id expected-version text)
  `(("type" . "state-commit")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))
    ("operation_id" . ,operation-id)
    ("expected_state_version" . ,expected-version)
    ("text" . ,text)))

(define (presentation action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(define (read-type port expected)
  (let ((message (read-frame port)))
    (when (eof-object? message)
      (fail "authority closed before expected message" expected))
    (unless (and (string? (field message "type"))
                 (string=? (field message "type") expected))
      (fail "authority sent an unexpected message type"
            expected (field message "type")))
    message))

(define (receive-load-state-and-action port ready)
  (write-frame port (state-read ready))
  (let loop ((snapshot #f) (action #f))
    (if (and snapshot action)
        (values snapshot action)
        (let* ((message (read-frame port))
               (type (and (not (eof-object? message))
                          (field message "type"))))
          (cond
           ((and (string? type) (string=? type "state-value"))
            (when snapshot (fail "duplicate state-value"))
            (loop (require-state-value message) action))
           ((and (string? type) (string=? type "action"))
            (when action (fail "duplicate load-display action"))
            (loop snapshot (require-action message "load-display")))
           (else (fail "unexpected message before load presentation" type)))))))

(define (display-text snapshot)
  (if (field snapshot "present")
      (field snapshot "text")
      "ABSENT"))

(define (commit-text mode snapshot action)
  (cond
   ((string=? mode "save") (field action "text"))
   ((or (string=? mode "save-loaded") (string=? mode "replay"))
    (unless (string=? (field action "text")
                      (if (string=? mode "replay")
                          "REPLAY-LOADED" "SAVE-LOADED"))
      (fail "loaded-state action marker is invalid"))
    (unless (field snapshot "present")
      (fail "loaded-state save requires present state"))
    (field snapshot "text"))
   ((string=? mode "boundary-save")
    (unless (string=? (field action "text") "SAVE-NUL-4096")
      (fail "boundary action marker is invalid"))
    (make-string max-state-text-bytes #\nul))
   (else (fail "unknown fixture mode" mode))))

(define (receipt-presentation operation-id committed current-version)
  (format #f "receipt=~a|state-version=~a|text-bytes=~a|current-version=~a"
          operation-id
          (field committed "state_version")
          (field committed "text_bytes")
          current-version))

(define (run port mode operation-id replay-expected)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (let ((initialize (read-type port "initialize"))
        (ready (read-type port "state-ready")))
    (require-initialize initialize)
    (require-state-ready ready)
    (call-with-values
        (lambda () (receive-load-state-and-action port ready))
      (lambda (snapshot load-action)
        (write-frame port
                     (presentation load-action (display-text snapshot)))
        (let* ((edit-action
                (require-action (read-type port "action") "edit-save"))
               (text (commit-text mode snapshot edit-action))
               (expected
                (if (string=? mode "replay")
                    replay-expected
                    (field snapshot "state_version"))))
          (write-frame port
                       (state-commit ready operation-id expected text))
          (let* ((committed
                  (require-committed
                   (read-type port "state-committed")
                   operation-id expected text))
                 (current-version
                  (if (string=? mode "replay")
                      (begin
                        (write-frame port (state-read ready))
                        (field (require-state-value
                                (read-type port "state-value"))
                               "state_version"))
                      (field committed "state_version"))))
            (write-frame
             port
             (presentation
              edit-action
              (receipt-presentation
               operation-id committed current-version)))))))))

(define (open-protocol-port)
  (unless (equal? (getenv "BOOK_SESSION_FD") "0")
    (fail "BOOK_SESSION_FD must name donated FD 0"))
  (unless (eq? (stat:type (stat 0)) 'socket)
    (fail "donated FD 0 is not a socket"))
  (when (positive? (logand (fcntl 0 F_GETFD) FD_CLOEXEC))
    (fail "donated FD 0 remained close-on-exec"))
  (let ((port (fdopen 0 "r+0")))
    (unless (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
      (fail "donated FD 0 is not a stream socket"))
    (unless (and (= (vector-ref (getsockname port) 0) AF_UNIX)
                 (= (vector-ref (getpeername port) 0) AF_UNIX))
      (fail "donated FD 0 is not a connected Unix socket"))
    (let* ((donated (stat 0))
           (open
            (filter-map
             (lambda (name)
               (let ((fd (string->number name 10)))
                 (and fd (> fd 2)
                      (catch 'system-error
                        (lambda () (fcntl fd F_GETFD) fd)
                        (lambda arguments #f)))))
             (scandir "/proc/self/fd"
                      (lambda (name)
                        (and (not (member name '("." "..")))
                             (string->number name 10)))))))
      (for-each
       (lambda (fd)
         (let ((info (stat fd)))
           (when (and (= (stat:dev info) (stat:dev donated))
                      (= (stat:ino info) (stat:ino donated)))
             (fail "fixture retained a duplicate donated socket" fd))
           (unless (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
             (fail "fixture inherited an unrelated non-CLOEXEC FD" fd))))
       open))
    (setvbuf port 'none)
    port))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 3)
    (fail "usage: fixture-book.scm MODE OPERATION-ID REPLAY-EXPECTED"))
  ;; The supervisor records PID and Linux start time while this process is
  ;; stopped, before any protocol byte is sent.
  (setpgid 0 0)
  (kill (getpid) SIGSTOP)
  (let ((port (open-protocol-port)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (run port (car arguments) (cadr arguments)
             (or (string->number (caddr arguments) 10)
                 (fail "replay expected version is not an integer"))))
      (lambda ()
        (unless (port-closed? port) (close-port port))))))
