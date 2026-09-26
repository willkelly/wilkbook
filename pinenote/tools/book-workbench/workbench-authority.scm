;;; A single endpoint owns one source workspace and its preview authorization.
;;; Execution is injected by the trusted composition root. This module never
;;; evaluates authored source or lets a request choose a path or interpreter.
(define-module (workbench-authority)
  #:use-module (book-workspace)
  #:use-module (book-protocol)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (make-workbench-authority
            workbench-request!
            serve-workbench!
            encode-workbench-line
            decode-workbench-line))

(define-record-type <authority>
  (%make-authority store preview ticket closed?)
  authority?
  (store authority-store)
  (preview authority-preview)
  (ticket authority-ticket set-authority-ticket!)
  (closed? authority-closed? set-authority-closed!))

(define (make-workbench-authority store preview)
  (unless (procedure? preview) (error "Workbench needs an explicit preview runner"))
  (%make-authority store preview #f #f))

(define (refusal code) (throw 'workbench-refused code))
(define (natural? value)
  (and (integer? value) (exact? value) (<= 0 value 2147483647)))

(define (request-schema! message)
  (unless (and (list? message) (every pair? message)
               (every (lambda (entry) (string? (car entry))) message))
    (refusal "invalid-request"))
  (let* ((op (assoc-ref message "op"))
         (fields
          (and (string? op)
               (cond
                ((member op '("open" "export" "close")) '("op"))
                ((string=? op "save") '("op" "expected_version" "source"))
                ((string=? op "preview") '("op" "expected_version" "text"))
                ((string=? op "run") '("op" "text"))
                ((string=? op "activate")
                 '("op" "expected_version" "expected_activation"))
                ((string=? op "rollback") '("op" "expected_activation"))
                (else #f)))))
    (unless (and fields
                 (equal? (sort (map car message) string<?)
                         (sort fields string<?)))
      (refusal "invalid-request-fields"))
    (for-each
     (lambda (key)
       (when (member key fields)
         (unless (natural? (assoc-ref message key))
           (refusal "invalid-version"))))
     '("expected_version" "expected_activation"))
    (when (member "text" fields)
      (let ((text (assoc-ref message "text")))
        (unless (and (string? text) (not (string-index text #\nul))
                     (<= 1 (bytevector-length (string->utf8 text)) 2048))
          (refusal "invalid-input-text"))))
    (when (member "source" fields)
      (let ((source (assoc-ref message "source")))
        (unless (and (string? source) (not (string-index source #\nul))
                     (<= (bytevector-length (string->utf8 source)) 8192))
          (refusal "invalid-source"))))
    op))

(define (snapshot->wire snapshot)
  (map (lambda (entry)
         (cons (cdr entry) (assoc-ref snapshot (car entry))))
       '((workspace-version . "workspace_version")
         (source . "source") (source-digest . "source_digest")
         (active-revision . "active_revision")
         (previous-revision . "previous_revision")
         (activation-generation . "activation_generation"))))

(define (preview-identity snapshot)
  (map (lambda (key) (assoc-ref snapshot key))
       '(workspace-version source-digest activation-generation)))

(define (require-version! message snapshot)
  (unless (= (assoc-ref message "expected_version")
             (assoc-ref snapshot 'workspace-version))
    (refusal "workspace-conflict")))

(define (preview-result! result)
  ;; Neither stdout nor a book-written PASS string can produce this result.
  ;; The runner must have observed a correlated Book Session result and reaped
  ;; the execution domain before returning status=ok.
  (unless (and (list? result) (eq? (assoc-ref result 'status) 'ok))
    (refusal "preview-failed"))
  (let ((text (assoc-ref result 'text)))
    (unless (and (string? text) (not (string-index text #\nul))
                 (<= 1 (bytevector-length (string->utf8 text)) 4096))
      (refusal "invalid-preview-result")))
  result)

(define (bounded-diagnostic result)
  (let ((value (and (list? result) (assoc-ref result 'diagnostic))))
    (if (string? value)
        ;; At most 2 KiB of UTF-8 even if every character needs four bytes.
        (string-map (lambda (c) (if (char=? c #\nul) #\? c))
                    (substring value 0 (min 512 (string-length value))))
        "Preview did not complete successfully.")))

(define (workbench-request! authority message)
  (let* ((candidate (and (list? message) (every pair? message)
                         (assoc-ref message "op")))
         (op (if (and (string? candidate)
                      (member candidate '("open" "save" "preview" "run"
                                          "activate" "rollback" "export" "close")))
                 candidate "invalid")))
    (catch #t
      (lambda ()
        (when (authority-closed? authority) (refusal "session-closed"))
        (set! op (request-schema! message))
        (let* ((store (authority-store authority))
               (before (workspace-snapshot store)))
          (define (success snapshot . extra)
            (append `(("ok" . #t) ("op" . ,op)
                      ("snapshot" . ,(snapshot->wire snapshot))) extra))
          (define (read-success extra)
            ;; Do not duplicate source alongside a result/export: worst-case
            ;; JSON escaping must still fit the existing 65,536-byte codec.
            (append `(("ok" . #t) ("op" . ,op)
                      ("workspace_version" . ,(assoc-ref before 'workspace-version))
                      ("source_digest" . ,(assoc-ref before 'source-digest))
                      ("activation_generation" . ,(assoc-ref before 'activation-generation)))
                    extra))
          (cond
           ((string=? op "open")
            ;; The desktop fixture retains its donated transport between editor
            ;; windows. Opening a new view discards the previous view's preview.
            (set-authority-ticket! authority #f)
            (success before))
           ((string=? op "save")
            (set-authority-ticket! authority #f)
            (success (workspace-save! store (assoc-ref message "expected_version")
                                      (assoc-ref message "source"))))
           ((member op '("preview" "run"))
            (when (string=? op "preview")
              (set-authority-ticket! authority #f)
              (require-version! message before))
            (let* ((source
                    (if (string=? op "preview") (assoc-ref before 'source)
                        (workspace-revision-source store
                                                   (assoc-ref before 'active-revision))))
                   (result ((authority-preview authority) source
                            (assoc-ref message "text"))))
              (if (and (list? result) (eq? (assoc-ref result 'status) 'ok))
                  (begin
                    (preview-result! result)
                    (when (string=? op "preview")
                      ;; A concurrent writer cannot validate a different draft
                      ;; merely because this earlier preview succeeded.
                      (unless (equal? (preview-identity before)
                                      (preview-identity (workspace-snapshot store)))
                        (refusal "workspace-changed-during-preview"))
                      (set-authority-ticket! authority (preview-identity before)))
                    (read-success `(("text" . ,(assoc-ref result 'text))
                                    ("diagnostic" . ""))))
                  `(("ok" . #f) ("op" . ,op) ("error" . "preview-failed")
                    ("diagnostic" . ,(bounded-diagnostic result))))))
           ((string=? op "activate")
            (require-version! message before)
            (unless (equal? (authority-ticket authority) (preview-identity before))
              (refusal "preview-required-for-this-draft"))
            (unless (= (assoc-ref message "expected_activation")
                       (assoc-ref before 'activation-generation))
              (refusal "activation-conflict"))
            (let* ((revision (workspace-seal! store (assoc-ref before 'workspace-version)))
                   (after (workspace-activate-draft!
                           store revision (assoc-ref message "expected_version")
                           (assoc-ref message "expected_activation"))))
              (set-authority-ticket! authority #f)
              (success after)))
           ((string=? op "rollback")
            ;; Recovery does not depend on the draft or on successful execution.
            (set-authority-ticket! authority #f)
            (success (workspace-rollback! store (assoc-ref message "expected_activation"))))
           ((string=? op "export")
            (read-success `(("artifact" . ,(workspace-export store
                                             (assoc-ref before 'active-revision))))))
           ((string=? op "close")
            (set-authority-ticket! authority #f)
            (set-authority-closed! authority #t)
            (success before)))))
      (lambda (key . arguments)
        ;; Expected store conflicts are recoverable UI failures. Never claim a
        ;; successful write based on a book presentation or a thrown exception.
        (unless (eq? key 'workbench-refused)
          (format (current-error-port) "BOOK_WORKBENCH: ~a failed (~a)~%" op key))
        `(("ok" . #f) ("op" . ,op)
          ("error" . ,(if (and (eq? key 'workbench-refused)
                               (pair? arguments) (string? (car arguments)))
                          (car arguments)
                          (if (and (eq? key 'workspace-error)
                                   (pair? arguments)
                                   (memq (car arguments)
                                         '(revision-quota-exhausted
                                           workspace-version-exhausted
                                           activation-generation-exhausted)))
                              (symbol->string (car arguments))
                              "workspace-operation-failed"))))))))

(define max-line-bytes (+ (* 2 max-frame-size) 32))
(define hex "0123456789abcdef")

(define (encode-workbench-line kind sequence message)
  (unless (and (member kind '("command" "reply"))
               (natural? sequence) (positive? sequence))
    (refusal "invalid-line-header"))
  (let* ((frame (encode-frame message))
         (length (- (bytevector-length frame) 4))
         (encoded (make-string (* 2 length))))
    (do ((i 0 (+ i 1))) ((= i length))
      (let ((value (bytevector-u8-ref frame (+ i 4))))
        (string-set! encoded (* i 2) (string-ref hex (ash value -4)))
        (string-set! encoded (+ (* i 2) 1) (string-ref hex (logand value 15)))))
    (string->utf8 (string-append kind "|" (number->string sequence)
                                "|" encoded "\n"))))

(define (decode-workbench-line bytes expected-kind)
  (unless (and (bytevector? bytes) (<= (bytevector-length bytes) max-line-bytes))
    (refusal "oversized-control-line"))
  (let* ((line (utf8->string bytes)) (parts (string-split line #\|)))
    (unless (and (= (length parts) 3) (string=? (car parts) expected-kind))
      (refusal "invalid-line-header"))
    (let* ((token (cadr parts)) (payload (caddr parts))
           (length (string-length payload)))
      (unless (and (<= 1 (string-length token) 10)
                   (char<=? #\1 (string-ref token 0) #\9)
                   (string-every (lambda (c) (char<=? #\0 c #\9)) token)
                   (natural? (string->number token))
                   (positive? length) (even? length)
                   (<= length (* 2 max-frame-size)))
        (refusal "invalid-control-line"))
      (let ((decoded (make-bytevector (/ length 2))))
        (do ((i 0 (+ i 2))) ((= i length))
          (let ((high (string-index hex (string-ref payload i)))
                (low (string-index hex (string-ref payload (+ i 1)))))
            (unless (and high low) (refusal "invalid-control-hex"))
            (bytevector-u8-set! decoded (/ i 2) (+ (* high 16) low))))
        (list (string->number token) (decode-payload decoded))))))

(define (read-control-line port)
  (let ((buffer (make-bytevector max-line-bytes)))
    (let loop ((used 0))
      ;; Guile's buffered port read can enter an indefinite wait with a Scheme
      ;; signal callback still queued. A bounded readiness wait gives that stop
      ;; callback a dispatch point even on an idle or partially written line.
      ;; select also recognizes bytes already buffered in PORT.
      (let wait ()
        (when (null? (car (select (list port) '() '() 0 200000)))
          (wait)))
      (let ((byte (get-u8 port)))
        (cond
         ((eof-object? byte)
          (if (zero? used) byte (refusal "truncated-control-line")))
         ((= byte 10)
          (let ((result (make-bytevector used)))
            (bytevector-copy! buffer 0 result 0 used) result))
         ((= used max-line-bytes) (refusal "oversized-control-line"))
         (else (bytevector-u8-set! buffer used byte) (loop (+ used 1))))))))

(define* (serve-workbench! authority port #:key (stop-requested? (lambda () #f)))
  ;; A bounded idle readiness wait, one request and one response at a time. The
  ;; native composition root owns the descriptor and process deadline. Syntax,
  ;; framing and sequence failures terminate this connection without resync.
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let loop ((expected 1))
        (unless (stop-requested?)
          (let ((line (read-control-line port)))
            (unless (or (eof-object? line) (stop-requested?))
              (let* ((decoded (decode-workbench-line line "command"))
                     (sequence (car decoded)))
                (unless (= sequence expected) (refusal "invalid-request-sequence"))
                (let ((reply (workbench-request! authority (cadr decoded))))
                  ;; A cooperative stop can unwind a preview through its cleanup
                  ;; and be translated into a normal failed result by its boundary.
                  ;; Do not block on a reply or return to an idle read afterward.
                  (unless (stop-requested?)
                    (put-bytevector port (encode-workbench-line "reply" sequence reply))
                    (force-output port)
                    (unless (authority-closed? authority) (loop (+ expected 1)))))))))))
    (lambda ()
      (set-authority-ticket! authority #f)
      (set-authority-closed! authority #t))))
