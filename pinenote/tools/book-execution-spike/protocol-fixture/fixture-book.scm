;;; Fixed Guile book for the first runsc FD-donation fixture.
(use-modules (book-protocol blocking-io)
             (srfi srfi-1))

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

(define (require-initialize message)
  (unless (and
           (exact-fields?
            message
            '("type" "version" "grant_count" "surface_handle"
              "surface_generation" "max_pending_requests"
              "max_present_text_bytes"))
           (string=? (field message "type") "initialize")
           (= (field message "version") 1)
           (= (field message "grant_count") 1)
           (string? (field message "surface_handle"))
           (= (field message "surface_generation") 1)
           (= (field message "max_pending_requests") 4)
           (= (field message "max_present_text_bytes") 4096))
    (error "initialize did not match the fixed fixture")))

(define (require-action message)
  (unless (and
           (exact-fields?
            message
            '("type" "request_id" "action_id" "surface_handle"
              "surface_generation" "sequence" "text"))
           (string=? (field message "type") "action")
           (string=? (field message "action_id") "guile-action")
           (string=? (field message "text") "Ada"))
    (error "action did not match the fixed Guile fixture"))
  message)

(define (run port)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (require-initialize (read-frame port))
  (let ((action (require-action (read-frame port))))
    (write-frame
     port
     `(("type" . "present")
       ("request_id" . ,(field action "request_id"))
       ("action_id" . ,(field action "action_id"))
       ("surface_handle" . ,(field action "surface_handle"))
       ("surface_generation" . ,(field action "surface_generation"))
       ("sequence" . ,(field action "sequence"))
       ("count" . 1)
       ("text" . "Guile book: ADA")))))

(unless (equal? (getenv "BOOK_SESSION_FD") "3")
  (error "BOOK_SESSION_FD must name donated FD 3"))
(let ((port (fdopen 3 "r+0")))
  (setvbuf port 'none)
  (run port)
  (close-port port))
