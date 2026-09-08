;;; Fresh-process idle stop test: Shepherd sends TERM while the authority owns
;;; SQLite and blocks in accept(2), with no client and no polling timer.
(use-modules (book-state-device-authority)
             (ice-9 ftw))

(define (required name)
  (or (getenv name) (error "missing idle-stop test input" name)))
(define authority-module (resolve-module '(book-state-device-authority)))
(define (authority name) (module-ref authority-module name))
(define (set-authority! name value) (module-set! authority-module name value))
(define root (required "BOOK_STATE_DEVICE_IDLE_ROOT"))
(define guile (required "BOOK_STATE_DEVICE_GUILE"))
(define state-root (string-append root "/state"))
(define activation (string-append state-root "/enabled"))
(define runtime-root (string-append root "/run"))

(unless (and (file-exists? root)
             (null? (scandir root
                             (lambda (name) (not (member name '("." "..")))))))
  (error "idle-stop root is not an empty directory" root))
(chmod root #o700)
(mkdir state-root #o700)
(call-with-output-file activation (lambda (port) (display "enabled\n" port)))
(chmod activation #o600)
(for-each
 (lambda (entry) (set-authority! (car entry) (cdr entry)))
 `((state-root . ,state-root)
   (activation-file . ,activation)
   (database-path . ,(string-append state-root "/book-state-v1.sqlite"))
   (runtime-root . ,runtime-root)
   (socket-path . ,(string-append runtime-root "/control.sock"))))

(exit
 ((authority 'book-state-device-main)
  `((book-language . guile)
    (authority-uid . ,(getuid))
    (authority-gid . ,(getgid))
    (koreader-luajit . ,(canonicalize-path guile)))
  '("book-state-device-authority")))
