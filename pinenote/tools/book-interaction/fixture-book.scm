;;; Trusted fixture book.  This is peer program behavior, not host policy.
(use-modules (book-protocol blocking-io)
             (ice-9 match)
             (srfi srfi-1))

(define protocol-version 1)
(define expected-initialize-fields
  '("type" "version" "grant_count" "surface_handle" "surface_generation"
    "max_pending_requests" "max_present_text_bytes"))
(define expected-action-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "text"))

(define (marker text)
  (format #t "BOOK_INTERACTION_PEER: ~a~%" text)
  (force-output))

(define (fail message)
  (format (current-error-port) "BOOK_INTERACTION_PEER: FAIL:~a~%" message)
  (force-output (current-error-port))
  (primitive-exit 1))

(define (field message name)
  (let ((entry (assoc name message)))
    (and entry (cdr entry))))

(define (exact-fields? message expected)
  (and (list? message)
       (= (length message) (length expected))
       (every (lambda (entry)
                (and (pair? entry)
                     (string? (car entry))
                     (member (car entry) expected)))
              message)
       (every (lambda (name) (assoc name message)) expected)))

(define (require-initialize message)
  (unless (and (exact-fields? message expected-initialize-fields)
               (string=? (field message "type") "initialize")
               (= (field message "version") protocol-version)
               (= (field message "grant_count") 1)
               (string? (field message "surface_handle"))
               (= (field message "surface_generation") 1)
               (= (field message "max_pending_requests") 4)
               (= (field message "max_present_text_bytes") 4096))
    (fail "initialize did not match the fixture contract")))

(define (require-action message expected-action-id)
  (unless (and (exact-fields? message expected-action-fields)
               (string=? (field message "type") "action")
               (string=? (field message "action_id") expected-action-id)
               (string? (field message "request_id"))
               (string? (field message "surface_handle"))
               (integer? (field message "surface_generation"))
               (integer? (field message "sequence"))
               (string? (field message "text")))
    (fail (string-append "action did not match phase " expected-action-id)))
  message)

(define (presentation action text)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,text)))

(define (run port)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (require-initialize (read-frame port))
  (marker "initialize:accepted")

  (let ((action (require-action (read-frame port) "update")))
    (write-frame
     port
     (presentation action
                   (string-append "Book result: "
                                  (string-upcase (field action "text")))))
    (marker "update:presented"))

  (let ((action (require-action (read-frame port) "navigate-stale")))
    (usleep 350000)
    (write-frame port (presentation action "late navigation result"))
    (marker "navigation:late-present-attempted"))

  (let ((action (require-action (read-frame port) "close-stale")))
    (usleep 350000)
    (let ((rejected?
           (catch 'system-error
             (lambda ()
               (write-frame port (presentation action "late close result"))
               #f)
             (lambda arguments #t))))
      (unless rejected?
        (fail "close-stale presentation unexpectedly crossed shutdown"))
      (marker "close:late-present-rejected")))
  (marker "result:ok"))

(sigaction SIGPIPE SIG_IGN)
(unless (equal? (getenv "BOOK_SESSION_FD") "3")
  (fail "session donation environment did not name FD 3"))
(let ((port (fdopen 3 "r+0")))
  (setvbuf port 'none)
  (catch #t
    (lambda ()
      (run port)
      (close-port port)
      (primitive-exit 0))
    (lambda (key . arguments)
      (format (current-error-port)
              "BOOK_INTERACTION_PEER: FAIL:~s ~s~%" key arguments)
      (force-output (current-error-port))
      (primitive-exit 1))))
