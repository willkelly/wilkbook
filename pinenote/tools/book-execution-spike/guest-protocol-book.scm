;;; Fixed untrusted Guile book for the first real runsc protocol gate.
;;; Its only application channel is the donated connected socket at FD 3.
(use-modules (book-protocol blocking-io)
             (ice-9 ftw)
             (srfi srfi-1))

(define initialize-fields
  '("type" "version" "grant_count" "surface_handle"
    "surface_generation" "max_pending_requests" "max_present_text_bytes"))
(define action-fields
  '("type" "request_id" "action_id" "surface_handle"
    "surface_generation" "sequence" "text"))

(define expected-actions
  '(("guile-transform-1" . "Ada")
    ("guile-transform-2" . "élan λ")))

(define (ascii-token-character? character)
  (or (char-alphabetic? character)
      (char-numeric? character)
      (memv character '(#\- #\_))))

(define (nonce-input? value base)
  (let ((prefix (string-append base "|nonce=g-")))
    (and (string? value)
         (string-prefix? prefix value)
         (= (string-length value) (+ (string-length prefix) 16))
         (string-every ascii-token-character?
                       (substring value (string-length prefix))))))

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

(define (require-no-donated-socket-alias)
  ;; SCANDIR has released its own directory descriptor before this list is
  ;; checked.  Interpreter/module loading is complete, so no fixture-owned file
  ;; descriptor may remain hidden beside the donated endpoint.
  (let* ((donated (stat 3))
         (open
         (sort
          (filter-map
           (lambda (name)
             (let ((fd (string->number name 10)))
               (and fd
                    (catch 'system-error
                      (lambda () (fcntl fd F_GETFD) fd)
                      (lambda arguments #f)))))
           (scandir "/proc/self/fd"
                    (lambda (name)
                      (and (not (member name '("." "..")))
                           (string->number name 10)))))
          <)))
    (unless (equal? (take open (min 4 (length open))) '(0 1 2 3))
      (error "fixed Guile book lacks the donated stdio/FD3 shape" open))
    (for-each
     (lambda (fd)
       (let ((info (stat fd)))
         (when (and (= (stat:dev info) (stat:dev donated))
                    (= (stat:ino info) (stat:ino donated)))
           (error "fixed Guile book retained a duplicate donated socket" fd))
         (unless (positive? (logand (fcntl fd F_GETFD) FD_CLOEXEC))
           (error "fixed Guile book inherited an unrelated non-CLOEXEC FD" fd))))
     (drop open 4))))

(define (require-donated-socket port)
  (unless (equal? (getenv "BOOK_SESSION_FD") "3")
    (error "BOOK_SESSION_FD must name donated FD 3"))
  (unless (eq? (stat:type (stat 3)) 'socket)
    (error "donated FD 3 is not a connected socket"))
  (when (positive? (logand (fcntl 3 F_GETFD) FD_CLOEXEC))
    (error "donated FD 3 is unexpectedly close-on-exec"))
  (unless (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
    (error "donated FD 3 is not a stream socket"))
  (unless (and (= (vector-ref (getsockname port) 0) AF_UNIX)
               (= (vector-ref (getpeername port) 0) AF_UNIX))
    (error "donated FD 3 is not a connected Unix socket"))
  (require-no-donated-socket-alias))

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
    (error "initialize did not match the fixed Guile fixture")))

(define (require-action message expected sequence)
  (unless (and (exact-fields? message action-fields)
               (string=? (field message "type") "action")
               (string? (field message "request_id"))
               (not (string-null? (field message "request_id")))
               (string=? (field message "action_id") (car expected))
               (string? (field message "surface_handle"))
               (not (string-null? (field message "surface_handle")))
               (eqv? (field message "surface_generation") 1)
               (eqv? (field message "sequence") sequence)
               (nonce-input? (field message "text") (cdr expected)))
    (error "action did not match the fixed Guile fixture" sequence))
  message)

(define (computed-text input)
  (format #f "GUILE[~a]:~a" (string-length input) (string-upcase input)))

(define (present action)
  `(("type" . "present")
    ("request_id" . ,(field action "request_id"))
    ("action_id" . ,(field action "action_id"))
    ("surface_handle" . ,(field action "surface_handle"))
    ("surface_generation" . ,(field action "surface_generation"))
    ("sequence" . ,(field action "sequence"))
    ("count" . 1)
    ("text" . ,(computed-text (field action "text")))))

(define (run port)
  (write-frame port '(("type" . "hello") ("version" . 1)))
  (require-initialize (read-frame port))
  (for-each
   (lambda (expected sequence)
     (let ((action (require-action (read-frame port) expected sequence)))
       (write-frame port (present action))))
   expected-actions '(1 2)))

(let ((port (fdopen 3 "r+0")))
  (setvbuf port 'none)
  (require-donated-socket port)
  (dynamic-wind
    (lambda () #t)
    (lambda () (run port))
    (lambda ()
      (unless (port-closed? port)
        (close-port port)))))
