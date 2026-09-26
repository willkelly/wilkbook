;;; One-shot ordinary Book Protocol adapter. Authored Scheme is loaded only in
;;; this child: under runsc in a prepared bundle, or the explicitly trusted
;;; native fixture. This adapter is not a language-level security boundary.
(use-modules (book-protocol blocking-io)
             (ice-9 ftw)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1))

(define (require! condition message)
  (unless condition (error message)))

(define (bounded-text? value limit)
  (and (string? value) (positive? (string-length value))
       (not (string-index value #\nul))
       (<= (bytevector-length (string->utf8 value)) limit)))

(define (field object name) (assoc-ref object name))
(define (fields? object names)
  (and (list? object) (= (length object) (length names))
       (every (lambda (entry)
                (and (pair? entry) (member (car entry) names))) object)))

(define (native-descriptors!)
  ;; spawn donates the socket as stdin; reserve FD 3 before opening /dev/null.
  ;; No authored source has been loaded at this point. Stop before the parent
  ;; records process-group ownership, and never fork in the threaded broker.
  (setpgid 0 0)
  (kill (getpid) SIGSTOP)
  (require! (eq? (stat:type (stat 0)) 'socket) "native donation is not a socket")
  (dup2 0 3)
  (let ((null (open-fdes "/dev/null" O_RDONLY)))
    (dup2 null 0)
    (close-fdes null))
  (for-each
   (lambda (name)
     (let ((fd (string->number name)))
       (when (and fd (> fd 3))
         (catch 'system-error (lambda () (close-fdes fd)) (lambda _ #f)))))
   (scandir "/proc/self/fd"))
  (for-each (lambda (fd) (fcntl fd F_SETFD 0)) '(0 1 2 3)))

(define (read-source path)
  (let* ((port (open-file path "rb"))
         (bytes (dynamic-wind
                  (lambda () #t)
                  (lambda () (get-bytevector-n port (+ 16384 1)))
                  (lambda () (close-port port)))))
    (require! (and (bytevector? bytes) (<= 1 (bytevector-length bytes) 16384))
              "source exceeds 16 KiB or is empty")
    (let ((text (utf8->string bytes)))
      (require! (not (string-index text #\nul)) "source contains NUL")
      text)))

(define (run source)
  (require! (equal? (getenv "BOOK_SESSION_FD") "3") "BOOK_SESSION_FD must be 3")
  (require! (eq? (stat:type (stat 3)) 'socket) "FD 3 is not a socket")
  (let ((port (fdopen 3 "r+0")))
    (require! (and (= (getsockopt port SOL_SOCKET SO_TYPE) SOCK_STREAM)
                   (= (vector-ref (getsockname port) 0) AF_UNIX)
                   (= (vector-ref (getpeername port) 0) AF_UNIX))
              "FD 3 must be a connected Unix stream")
    (write-frame port '(("type" . "hello") ("version" . 1)))
    (let* ((initialize (read-frame port))
           (names '("type" "version" "grant_count" "surface_handle"
                    "surface_generation" "max_pending_requests"
                    "max_present_text_bytes")))
      (require!
       (and (fields? initialize names)
            (equal? (field initialize "type") "initialize")
            (equal? (field initialize "version") 1)
            (equal? (field initialize "grant_count") 1)
            (bounded-text? (field initialize "surface_handle") 96)
            (equal? (field initialize "surface_generation") 1)
            (equal? (field initialize "max_pending_requests") 4)
            (equal? (field initialize "max_present_text_bytes") 4096))
       "unexpected ordinary initialize")
      (let ((action (read-frame port)))
        (require!
         (and (fields? action '("type" "request_id" "action_id" "surface_handle"
                               "surface_generation" "sequence" "text"))
              (equal? (field action "type") "action")
              (equal? (field action "action_id") "workbench-preview")
              (bounded-text? (field action "request_id") 96)
              (equal? (field action "surface_handle")
                      (field initialize "surface_handle"))
              (equal? (field action "surface_generation") 1)
              (equal? (field action "sequence") 1)
              (bounded-text? (field action "text") 2048))
         "unexpected ordinary preview action (no state grant is accepted)")
        ;; Read exactly the bounded snapshot once. Loading it from a string
        ;; avoids reopening a resource after validation. This is unrestricted
        ;; Scheme in the execution domain, never in the authority process.
        (let ((program (make-fresh-user-module))
              (source-text (read-source source)))
          (save-module-excursion
           (lambda ()
             (set-current-module program)
             (call-with-input-string source-text
               (lambda (input)
                 (let loop ()
                   (let ((form (read input)))
                     (unless (eof-object? form) (eval form program) (loop))))))))
          (let ((entry (module-ref program 'workbench #f)))
            (require! (procedure? entry) "source must define (workbench text)")
            (let ((text (entry (field action "text"))))
              (require! (bounded-text? text 4096)
                        "workbench result must be 1..4096 UTF-8 bytes without NUL")
              (write-frame
               port
               `(("type" . "present")
                 ("request_id" . ,(field action "request_id"))
                 ("action_id" . ,(field action "action_id"))
                 ("surface_handle" . ,(field action "surface_handle"))
                 ("surface_generation" . ,(field action "surface_generation"))
                 ("sequence" . ,(field action "sequence"))
                 ("count" . 1) ("text" . ,text))))))))
    (close-port port)))

(sigaction SIGPIPE SIG_IGN)
(let ((arguments (cdr (command-line))))
  (cond
   ((equal? arguments '("--sandbox")) (run "/book/program.scm"))
   ((and (= (length arguments) 4)
         (string=? (car arguments) "--trusted-native-fixture"))
    (native-descriptors!)
    ;; Exec after descriptor normalization: the loader may still own a port for
    ;; this script. Returning to it after closing inherited FDs would be unsafe.
    (execl (caddr arguments) (caddr arguments) "--no-auto-compile"
           "-L" (cadddr arguments) (car (command-line))
           "--native-run" (cadr arguments)))
   ((and (= (length arguments) 2) (string=? (car arguments) "--native-run"))
    (chdir (dirname (cadr arguments))) (run (cadr arguments)))
   (else (error "runner requires --sandbox or the trusted native fixture adapter"))))
