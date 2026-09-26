;;; Explicit trusted-native developer fixture. The hardware service must use a
;;; sandbox runner; there is deliberately no automatic native fallback.
(use-modules (book-workspace) (workbench-authority) (workbench-preview)
             (ice-9 textual-ports) (ice-9 match))

(match (cdr (command-line))
  (("--trusted-native-fixture" fd-text directory seed-file guile runner protocol)
   (let ((fd (string->number fd-text)))
     (unless (and fd (integer? fd) (exact? fd) (>= fd 3))
       (error "the native fixture needs a dedicated UI descriptor"))
      (let ((cancelled? #f) (store #f) (port #f))
        (define (request-stop _signal)
          ;; Preview/request catch-all handlers may turn the throw into a failed
          ;; result. The flag still stops the server before replying/reading
          ;; again. Repeated signals must not interrupt the first unwind's reap.
          (unless cancelled?
            (set! cancelled? #t)
            (throw 'workbench-stop)))
        (catch 'workbench-stop
          (lambda ()
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                ;; Install before store acquisition: SQLite itself may wait on
                ;; another opener. Its own unwind closes a partially open store.
                (for-each (lambda (signal) (sigaction signal request-stop))
                          (list SIGTERM SIGINT SIGHUP))
                (sigaction SIGPIPE SIG_IGN)
                (set! port (fdopen fd "r+"))
                (set! store
                      (open-workspace-store
                       directory (call-with-input-file seed-file get-string-all)
                       #:environment
                       (basename (canonicalize-path (dirname (dirname guile))))))
                (let ((authority
                       (make-workbench-authority
                        store
                        (lambda (source text)
                          (preview-native source text #:guile guile #:runner runner
                                          #:protocol-directory protocol
                                          #:timeout-seconds 3)))))
                  (serve-workbench! authority port
                                    #:stop-requested? (lambda () cancelled?))))
              (lambda ()
                ;; Also protect normal EOF cleanup from its first stop signal.
                (set! cancelled? #t)
                (dynamic-wind
                  (lambda () #t)
                  (lambda () (when port (close-port port)))
                  (lambda () (when store (close-workspace-store! store)))))))
          (lambda _ #t)))))
  (_ (error "usage: native-authority.scm --trusted-native-fixture FD DIRECTORY SEED GUILE RUNNER PROTOCOL-DIRECTORY")))
