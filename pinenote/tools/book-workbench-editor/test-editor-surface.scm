(use-modules (editor-surface) (book-protocol) (rnrs bytevectors)
             (srfi srfi-1) (srfi srfi-64) (srfi srfi-13))
;; Guix's supervisor SRFI-64 logs by default; the ambient replacement runner
;; does not export this extension and already writes only to standard output.
(when (defined? 'test-log-to-file) (set! test-log-to-file #f))
(test-begin "editor-surface")
(define (rejected? thunk)
  (catch #t (lambda () (thunk) #f) (lambda args #t)))
(define surface (make-editor-surface "host-opaque"))
(define ready (editor-surface-new-view! surface))
(test-equal "declared generation" 1 (editor-message-ref ready "surface_generation"))
(test-equal "ready roundtrip" (editor-message->object ready)
  (editor-message->object (decode-editor-frame (encode-editor-message ready) 'authority-to-book)))
(test-assert "open is reserved initial action"
  (rejected? (lambda () (editor-surface-action! surface "save" ""))))
(define pending (editor-surface-action! surface "open" ""))
(define actions #(( ("id" . "custom_7") ("label" . "A book-defined action") ("enabled" . #t))
                  (("id" . "save") ("label" . "Not enabled") ("enabled" . #f))))
(define (presentation request text . rest)
  (make-editor-message
   (append `(("type" . "editor-present") ("title" . "Editor") ("status" . "")
             ("text" . ,text) ("actions" . ,(if (null? rest) actions (car rest))))
           (filter (lambda (entry) (not (member (car entry) '("type" "text"))))
                   (editor-message->object request)))))
(test-assert "one pending action"
  (rejected? (lambda () (editor-surface-action! surface "open" ""))))
(define initial (presentation pending "λ"))
(test-equal "present roundtrip including array" (editor-message->object initial)
  (editor-message->object (decode-editor-frame (encode-editor-message initial) 'book-to-authority)))
(for-each
 (lambda (key)
   (let* ((object (editor-message->object initial))
          (old (assoc-ref object key)))
     (set-cdr! (assoc key object) (if (number? old) (+ old 1) "different"))
     (test-assert (string-append "echo mismatch " key)
       (rejected? (lambda () (editor-surface-present! surface (make-editor-message object)))))
     (test-eq "rejection does not retire pending" pending (editor-surface-pending surface))))
 '("request_id" "action_id" "surface_handle" "surface_generation" "sequence"))
(editor-surface-present! surface initial)
(test-assert "duplicate response rejected"
  (rejected? (lambda () (editor-surface-present! surface initial))))
(for-each (lambda (id)
            (test-assert "disabled/unknown/reserved action rejected"
              (rejected? (lambda () (editor-surface-action! surface id "x")))))
          '("save" "unknown" "open"))
(define second (editor-surface-action! surface "custom_7" (make-string 4096 #\λ)))
(test-equal "host request monotonically allocated" 2 (editor-message-ref second "request_id"))
(editor-surface-fail! surface second)
(test-equal "failure restores last form" 'idle (editor-surface-phase surface))
(test-assert "retired failure cannot cancel next action"
  (begin (editor-surface-action! surface "custom_7" "")
         (rejected? (lambda () (editor-surface-fail! surface second)))))
(define stale (presentation (editor-surface-pending surface) "stale"))
(editor-surface-new-view! surface)
(define reopened (editor-surface-action! surface "open" "retained"))
(test-assert "new view invalidates outstanding response"
  (rejected? (lambda () (editor-surface-present! surface stale))))
(test-assert "reopen retains request monotonicity" (> (editor-message-ref reopened "request_id") 2))
(editor-surface-present! surface (presentation reopened "" #()))
(test-equal "empty text accepted" "" (editor-message-ref (editor-surface-form surface) "text"))
(test-assert "empty action vector is terminal form"
  (rejected? (lambda () (editor-surface-action! surface "custom_7" ""))))
(editor-surface-close! surface)
(test-assert "closed cannot dispatch"
  (rejected? (lambda () (editor-surface-action! surface "open" ""))))
;; The typed projection takes defensive copies both entering and leaving.
(let* ((object (editor-message->object initial)) (typed (make-editor-message object)))
  (string-set! (assoc-ref object "text") 0 #\x)
  (test-equal "constructor copies" "λ" (editor-message-ref typed "text"))
  (let ((out (editor-message-ref typed "actions")))
    (set-cdr! (assoc "enabled" (vector-ref out 0)) #f)
    (test-equal "getter copies nested actions" #t
      (assoc-ref (vector-ref (editor-message-ref typed "actions") 0) "enabled"))))
(for-each
 (lambda (replacement)
   (let ((object (editor-message->object initial)))
     (set-cdr! (assoc "actions" object) replacement)
     (test-assert "malformed action vector rejected"
       (rejected? (lambda () (make-editor-message object))))))
 (list '() (make-vector 9 (vector-ref actions 0))
       (vector (vector-ref actions 0) (vector-ref actions 0))
       #((("id" . "open") ("label" . "Open") ("enabled" . #t)))
       #((("id" . "λ") ("label" . "bad") ("enabled" . #t)))
       #((("id" . "x") ("label" . "bad") ("enabled" . 1)))
       #((("id" . "x") ("label" . "bad") ("enabled" . #t) ("path" . "/tmp")))))
(for-each
 (lambda (entry)
   (let ((object (editor-message->object initial)))
     (set-cdr! (assoc (car entry) object) (cdr entry))
     (test-assert "invalid field rejected" (rejected? (lambda () (make-editor-message object))))))
 (list (cons "text" (make-string 4097 #\λ)) (cons "text" (string #\nul))
       (cons "status" (make-string 2049 #\a)) (cons "title" (make-string 129 #\a))
       (cons "request_id" 0) (cons "request_id" 1.0) (cons "protocol_version" 2)))
(define raw-ready
  "{\"type\":\"editor-ready\",\"protocol_version\":1,\"surface_handle\":\"h\",\"surface_generation\":~a,\"max_text_bytes\":8192,\"max_actions\":8}")
(for-each (lambda (token)
            (test-assert (string-append "raw integer rejection " token)
              (rejected? (lambda () (decode-editor-payload
                                     (string->utf8 (format #f raw-ready token)) 'authority-to-book)))))
          '("1.0" "1e0" "1e-999" "0" "-1" "01" "9007199254740992"))
(test-assert "raw integer accepted"
  (editor-message? (decode-editor-payload (string->utf8 (format #f raw-ready "1")) 'authority-to-book)))
(test-assert "wrong direction rejected"
  (rejected? (lambda () (decode-editor-frame (encode-editor-message initial) 'authority-to-book))))
(test-assert "escaped duplicate key rejected"
  (rejected? (lambda () (decode-editor-payload
                         (string->utf8 "{\"type\":\"editor-ready\",\"\\u0074ype\":\"editor-ready\"}")
                         'authority-to-book))))
(test-assert "unknown field rejected"
  (rejected? (lambda () (make-editor-message (cons '("path" . "x") (editor-message->object initial))))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "editor-surface")
(exit (if (zero? failures) 0 1))
