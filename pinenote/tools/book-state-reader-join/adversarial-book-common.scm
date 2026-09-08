;;; Two fixed adversarial books used to prove the trusted join rejects surface
;;; presentation and mismatched storage completion as save evidence.
(define-module (adversarial-book-common)
  #:use-module (book-protocol blocking-io)
  #:use-module (ice-9 ftw)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (run-fixed-adversarial-book))

(define (fail message . details) (error message details))
(define (field message name)
  (let ((entry (and (list? message) (assoc name message))))
    (and entry (cdr entry))))
(define (type=? message expected)
  (and (string? (field message "type"))
       (string=? (field message "type") expected)))

(define (require-message message expected fields)
  (unless (and (list? message)
               (= (length message) (length fields))
               (every (lambda (entry)
                        (and (pair? entry) (string? (car entry))
                             (member (car entry) fields string=?)))
                      message)
               (every (lambda (name) (assoc name message)) fields)
               (type=? message expected))
    (fail "adversarial book received invalid message" expected))
  message)

(define (open-protocol-port)
  (unless (and (equal? (getenv "BOOK_SESSION_FD") "3")
               (eq? (stat:type (stat 3)) 'socket)
               (zero? (logand (fcntl 3 F_GETFD) FD_CLOEXEC)))
    (fail "adversarial book lacks exact donated FD 3"))
  (let ((port (fdopen 3 "r+0")))
    (unless (and (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
                 (= (vector-ref (getsockname port) 0) AF_UNIX)
                 (= (vector-ref (getpeername port) 0) AF_UNIX))
      (fail "adversarial book FD 3 is not a connected Unix stream"))
    (setvbuf port 'none)
    port))

(define (state-read ready)
  `(("type" . "state-read")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))))

(define (operation-id-character? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (and (char>=? character #\0) (char<=? character #\9))
      (memv character '(#\_ #\-))))

(define (operation-id action)
  (let ((value
         (format #f "note_~a_s~a_q~a"
                 (field action "surface_handle")
                 (field action "surface_generation")
                 (field action "sequence"))))
    (unless (and (<= 1 (string-length value) 128)
                 (every operation-id-character? (string->list value)))
      (fail "adversarial operation ID is outside accepted grammar"))
    value))

(define (state-commit ready action text)
  `(("type" . "state-commit")
    ("protocol_version" . 1)
    ("grant_handle" . ,(field ready "grant_handle"))
    ("grant_generation" . ,(field ready "grant_generation"))
    ("operation_id" . ,(operation-id action))
    ("expected_state_version" . 0)
    ("text" . ,text)))

(define (presentation action)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,(field action "text"))))

(define (run port behavior)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (require-message
   (read-frame port) "initialize"
   '("type" "version" "grant_count" "surface_handle"
     "surface_generation" "max_pending_requests" "max_present_text_bytes"))
  (let ((ready
         (require-message
          (read-frame port) "state-ready"
          '("type" "protocol_version" "grant_handle" "grant_generation"
            "access"))))
    (write-frame port (state-read ready))
    (let ((value
           (require-message
            (read-frame port) "state-value"
            '("type" "protocol_version" "present" "state_version" "text"))))
      (unless (and (not (field value "present"))
                   (= (field value "state_version") 0)
                   (string-null? (field value "text")))
        (fail "adversarial namespace was not initially absent")))
    (let ((action
           (require-message
            (read-frame port) "action"
            '("type" "request_id" "action_id" "surface_handle"
              "surface_generation" "sequence" "text"))))
      (unless (string=? (field action "action_id") "save-note")
        (fail "adversarial book received a non-save action"))
      (case behavior
        ((forged-present)
         (write-frame port (presentation action))
         (format #t "BOOK_STATE_READER_JOIN_ADVERSARY: forged-present-sent~%")
         (force-output))
        ((mismatched-commit)
         (let* ((wrong-text
                 (string-append (field action "text") " [book-mismatch]"))
                (op-id (operation-id action)))
           (write-frame port (state-commit ready action wrong-text))
           (let ((response (read-frame port)))
             (unless (and (type=? response "state-committed")
                          (string=? (field response "operation_id") op-id)
                          (= (field response "state_version") 1)
                          (= (field response "text_bytes")
                             (bytevector-length (string->utf8 wrong-text))))
               (fail "mismatched commit did not receive its exact receipt")))
           (format #t "BOOK_STATE_READER_JOIN_ADVERSARY: mismatched-commit-durable~%")
           (force-output)))
        (else (fail "unknown fixed adversarial behavior" behavior)))
      ;; The authority closes the endpoint after rejecting this event as UI
      ;; evidence.  Nothing else is accepted from argv, env, or storage.
      (let wait ()
        (let ((message (read-frame port)))
          (unless (eof-object? message)
            (fail "adversarial book received an extra authority message")))))))

(define (run-fixed-adversarial-book behavior)
  (unless (= (length (command-line)) 1)
    (fail "fixed adversarial book accepts no arguments"))
  (sigaction SIGPIPE SIG_IGN)
  (let ((port (open-protocol-port)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (run port behavior))
      (lambda () (unless (port-closed? port) (close-port port)))))
  (format #t "BOOK_STATE_READER_JOIN_ADVERSARY: result:ok~%")
  (force-output))
