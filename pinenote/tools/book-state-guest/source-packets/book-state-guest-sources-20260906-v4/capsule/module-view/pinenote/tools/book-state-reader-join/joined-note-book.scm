;;; Fixed Guile persistent-note book.  Its only application authority is the
;;; Book Session socket donated as FD 3.  It receives no state on argv/env.
(use-modules (book-protocol blocking-io)
             (ice-9 ftw)
             (rnrs bytevectors)
             (srfi srfi-1))

(define initialize-fields
  '("type" "version" "grant_count" "surface_handle"
    "surface_generation" "max_pending_requests" "max_present_text_bytes"))
(define ready-fields
  '("type" "protocol_version" "grant_handle" "grant_generation" "access"))
(define value-fields
  '("type" "protocol_version" "present" "state_version" "text"))
(define action-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "text"))
(define committed-fields
  '("type" "protocol_version" "operation_id" "state_version" "text_bytes"))
(define conflict-fields
  '("type" "protocol_version" "operation_id" "current_state_version"))
(define failed-fields
  '("type" "protocol_version" "operation_id" "code"))

(define (fail message . details) (error message details))
(define (marker text)
  (format #t "BOOK_STATE_READER_JOIN_BOOK: ~a~%" text)
  (force-output))
(define (field message name)
  (let ((entry (and (list? message) (assoc name message))))
    (and entry (cdr entry))))
(define (exact-fields? message fields)
  (and (list? message)
       (= (length message) (length fields))
       (every (lambda (entry)
                (and (pair? entry) (string? (car entry))
                     (member (car entry) fields string=?)))
              message)
       (every (lambda (name) (assoc name message)) fields)))
(define (exact-integer? value) (and (integer? value) (exact? value)))
(define (ascii-operation-id-character? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (and (char>=? character #\0) (char<=? character #\9))
      (char=? character #\_)
      (char=? character #\-)))
(define (valid-operation-id? value)
  (and (string? value)
       (<= 1 (string-length value) 128)
       (every ascii-operation-id-character? (string->list value))))

(define (require-initialize message)
  (unless (and (exact-fields? message initialize-fields)
               (string=? (field message "type") "initialize")
               (= (field message "version") 1)
               (= (field message "grant_count") 1)
                (string? (field message "surface_handle"))
                (not (string-null? (field message "surface_handle")))
                (<= (string-length (field message "surface_handle")) 96)
                (every ascii-operation-id-character?
                       (string->list (field message "surface_handle")))
               (= (field message "surface_generation") 1)
               (= (field message "max_pending_requests") 4)
               (= (field message "max_present_text_bytes") 4096))
    (fail "initialize does not match the fixed book"))
  message)

(define (require-ready message)
  (unless (and (exact-fields? message ready-fields)
               (string=? (field message "type") "state-ready")
               (= (field message "protocol_version") 1)
               (string? (field message "grant_handle"))
               (not (string-null? (field message "grant_handle")))
               (exact-integer? (field message "grant_generation"))
               (> (field message "grant_generation") 0)
               (string=? (field message "access") "read-write"))
    (fail "state-ready does not match the fixed book"))
  message)

(define (require-value message)
  (unless (and (exact-fields? message value-fields)
               (string=? (field message "type") "state-value")
               (= (field message "protocol_version") 1)
               (boolean? (field message "present"))
               (exact-integer? (field message "state_version"))
               (>= (field message "state_version") 0)
               (string? (field message "text"))
               (<= (bytevector-length (string->utf8 (field message "text")))
                   4096)
               (if (field message "present")
                   (> (field message "state_version") 0)
                   (and (= (field message "state_version") 0)
                        (string-null? (field message "text")))))
    (fail "state-value does not match the fixed book"))
  message)

(define (require-action message expected-id)
  (unless (and (exact-fields? message action-fields)
               (string=? (field message "type") "action")
               (string=? (field message "action_id") expected-id)
               (string? (field message "request_id"))
               (not (string-null? (field message "request_id")))
               (string? (field message "surface_handle"))
               (not (string-null? (field message "surface_handle")))
               (exact-integer? (field message "surface_generation"))
                (exact-integer? (field message "sequence"))
                (string? (field message "text"))
                (<= (bytevector-length
                     (string->utf8 (field message "text"))) 4096))
    (fail "action does not match fixed operation" expected-id))
  message)

(define (state-read ready)
  `(("type" . "state-read")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))))

(define (book-operation-id action)
  ;; The book, not UI or outer authority, chooses the operation ID.  It is
  ;; derived from the fresh CSPRNG-backed surface identity and already-validated
  ;; Book Session action metadata.  A retry retains this exact owned value.
  (let ((value
         (format #f "note_~a_s~a_q~a"
                 (field action "surface_handle")
                 (field action "surface_generation")
                 (field action "sequence"))))
    (unless (valid-operation-id? value)
      (fail "derived operation ID is outside the accepted wire grammar"))
    value))

(define (state-commit ready action operation-id version text)
  `(("type" . "state-commit")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))
    ("operation_id" . ,operation-id)
    ("expected_state_version" . ,version)
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

(define (require-operation-result message operation-id expected text)
  (let ((type (field message "type")))
    (cond
     ((and (string? type) (string=? type "state-committed"))
      (unless (and (exact-fields? message committed-fields)
                   (string=? (field message "operation_id") operation-id)
                   (= (field message "state_version") (+ expected 1))
                   (= (field message "text_bytes")
                      (bytevector-length (string->utf8 text))))
        (fail "committed response does not match exact operation"))
      (list 'committed (field message "state_version")))
     ((and (string? type) (string=? type "state-conflict"))
      (unless (and (exact-fields? message conflict-fields)
                   (string=? (field message "operation_id") operation-id))
        (fail "conflict response does not match exact operation"))
      (list 'conflict expected))
     ((and (string? type) (string=? type "state-commit-failed"))
      (unless (and (exact-fields? message failed-fields)
                   (string=? (field message "operation_id") operation-id)
                   (member (field message "code")
                           '("receipt-quota-exhausted" "read-only"
                             "storage-failure") string=?))
        (fail "failed response does not match exact operation"))
      (list 'failed expected))
     (else (fail "unexpected commit response" type)))))

(define (run port)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (let ((initialize (require-initialize (read-frame port)))
        (ready (require-ready (read-frame port))))
    (write-frame port (state-read ready))
    (let ((snapshot (require-value (read-frame port))))
      (marker (format #f "loaded:present=~a:version=~a"
                      (field snapshot "present")
                      (field snapshot "state_version")))
      (let loop ((version (field snapshot "state_version"))
                 (present? (field snapshot "present"))
                 (current-text (field snapshot "text")))
        (let ((message (read-frame port)))
          (unless (eof-object? message)
            (let ((action-id (field message "action_id")))
              (cond
                ((and (string? action-id)
                      (member action-id '("save-note" "retry-save-note")
                              string=?))
                 (let* ((action (require-action message action-id))
                        (operation-id (book-operation-id action))
                        (text (field action "text")))
                    (write-frame port
                                 (state-commit
                                  ready action operation-id version text))
                  (let ((result
                         (require-operation-result
                          (read-frame port) operation-id version text)))
                    (marker
                     (format #f "commit-result:~a:operation=~a"
                              (car result) operation-id))
                    (when (and (string=? action-id "retry-save-note")
                               (eq? (car result) 'committed))
                      ;; Lost-ack recovery is the same book operation, not a new
                      ;; UI intent: preserve ID, expected version, and text.
                      (write-frame port
                                   (state-commit
                                    ready action operation-id version text))
                      (let ((retry-result
                             (require-operation-result
                              (read-frame port) operation-id version text)))
                        (unless (and (eq? (car retry-result) 'committed)
                                     (= (cadr retry-result) (cadr result)))
                          (fail "same-operation retry changed its receipt"))
                        (marker
                         (format #f
                                 "retry-result:same-receipt:operation=~a"
                                 operation-id))))
                    (if (eq? (car result) 'committed)
                        (loop (cadr result) #t text)
                        (loop version present? current-text)))))
               ((and (string? action-id)
                     (string=? action-id "present-saved"))
                (let ((action (require-action message "present-saved")))
                  (unless (and present?
                               (string=? (field action "text") current-text))
                    (fail "presentation action differs from committed state"))
                  (write-frame port (presentation action current-text))
                  (marker "presented-after-receipt")
                  (loop version present? current-text)))
               (else (fail "unknown fixed book action" action-id))))))))))

(define (open-protocol-port)
  (unless (equal? (getenv "BOOK_SESSION_FD") "3")
    (fail "BOOK_SESSION_FD must name donated FD 3"))
  (unless (eq? (stat:type (stat 3)) 'socket)
    (fail "donated FD 3 is not a socket"))
  (when (positive? (logand (fcntl 3 F_GETFD) FD_CLOEXEC))
    (fail "donated FD 3 remained close-on-exec"))
  (let ((port (fdopen 3 "r+0")))
    (unless (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
      (fail "donated FD 3 is not a stream socket"))
    (unless (and (= (vector-ref (getsockname port) 0) AF_UNIX)
                 (= (vector-ref (getpeername port) 0) AF_UNIX))
      (fail "donated FD 3 is not a connected Unix socket"))
    (let ((donated (stat 3)))
      (for-each
       (lambda (name)
         (let ((fd (string->number name 10)))
           (when (and fd (> fd 3))
             (catch 'system-error
               (lambda ()
                 (let ((flags (fcntl fd F_GETFD))
                       (info (stat fd)))
                   (when (and (= (stat:dev info) (stat:dev donated))
                              (= (stat:ino info) (stat:ino donated)))
                     (fail "book retained a duplicate donated socket" fd))
                   (unless (positive? (logand flags FD_CLOEXEC))
                     (fail "book inherited unrelated non-CLOEXEC FD" fd))))
               (lambda arguments #f)))))
     (scandir "/proc/self/fd"
              (lambda (name)
                (and (not (member name '("." "..")))
                       (string->number name 10))))))
    (setvbuf port 'none)
    port))

(unless (= (length (command-line)) 1)
  (fail "fixed book accepts no arguments"))
(sigaction SIGPIPE SIG_IGN)
(let ((port (open-protocol-port)))
  (dynamic-wind
    (lambda () #t)
    (lambda () (run port))
    (lambda () (unless (port-closed? port) (close-port port)))))
(marker "result:ok")
