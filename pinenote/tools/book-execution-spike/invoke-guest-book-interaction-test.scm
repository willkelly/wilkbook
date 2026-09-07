;;; Host-only reader-interaction invocation adapter.  The child below is a
;;; trusted private-UI peer; real Guile/Python books still run behind the strict
;;; fake-runsc boundary.  This entry cannot select guest evidence mode.
(use-modules (guest-virtio-book-ui)
             (ice-9 match)
             (ice-9 rdelim)
             (private-control)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (put-bytevector)))

(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(primitive-load (search-path %load-path "guest-book-interaction.scm"))

(define run-reader-protocol-pair!
  (module-ref (resolve-module '(guest-book-interaction))
              'run-reader-protocol-pair!))
(define wait-for-ui-completion!
  (module-ref (resolve-module '(guest-book-interaction))
              'wait-for-ui-completion!))
(define put-bytevector*
  (module-ref (resolve-module '(rnrs io ports)) 'put-bytevector))
(define read-line*
  (module-ref (resolve-module '(ice-9 rdelim)) 'read-line))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (send-event! port kind generation value)
  (put-bytevector* port
                   (encode-control-line kind generation value
                                        reader-event-kinds))
  (force-output port))

(define (send-raw! port text)
  (put-bytevector* port (string->utf8 text))
  (force-output port))

(define (read-command port)
  (let ((line (read-line* port)))
    (when (eof-object? line)
      (error "authority closed the private UI fixture early"))
    (decode-control-line (string->utf8 line) reader-command-kinds)))

(define (record! transcript direction message)
  (write (cons direction message) transcript)
  (newline transcript)
  (force-output transcript))

(define (require-command! transcript port kind expected-value)
  (let ((message (read-command port)))
    (record! transcript 'authority message)
    (unless (and (= (length message) 3)
                 (eq? (car message) kind)
                 (= (cadr message) 1)
                 (or (eq? expected-value #f)
                     (string=? (caddr message) expected-value)))
      (error "private UI fixture received unexpected command" message))
    message))

(define (run-ui-peer port transcript-path mode)
  (call-with-output-file transcript-path
    (lambda (transcript)
      (send-event! port 'ready 1 "dialog")
      (record! transcript 'reader '(ready 1 "dialog"))
      (let loop ((index 1))
        (when (<= index 4)
          (let* ((input-command
                  (require-command! transcript port 'input-update #f))
                 (input (caddr input-command)))
            (cond
             ((and (= index 1) (string=? mode "wrong-generation"))
              (send-event! port 'submit 2 input))
             ((and (= index 1) (string=? mode "malformed"))
              (send-raw! port "submit|1|GG\n"))
             (else
              (send-event! port 'submit 1 input)
              (record! transcript 'reader `(submit 1 ,input))
              (cond
               ((and (= index 1) (string=? mode "disconnect"))
                (close-port-quietly! port)
                (set! port #f))
               ((and (= index 1) (string=? mode "repeat-submit"))
                (send-event! port 'submit 1 input)
                (record! transcript 'reader `(submit 1 ,input)))
               (else
                (send-event! port 'tick 1 (format #f "qemu-~a" index))
                (record! transcript 'reader
                         `(tick 1 ,(format #f "qemu-~a" index)))
                (when (and (= index 1) (string=? mode "repeat-tick"))
                  (send-event! port 'tick 1 "qemu-1")
                  (record! transcript 'reader '(tick 1 "qemu-1")))
                (let* ((present
                        (require-command! transcript port 'present #f))
                       (value (caddr present)))
                  (send-event! port 'applied 1 value)
                  (record! transcript 'reader `(applied 1 ,value))
                  (loop (+ index 1))))))))))
      (when (and port (string=? mode "positive"))
        (require-command! transcript port 'finish "")
        (send-event! port 'done 1 "ok")
        (record! transcript 'reader '(done 1 "ok"))))))

(define (decoded-status status)
  (cond
   ((status:exit-val status) => (lambda (value) (cons 'exit value)))
   ((status:term-sig status) => (lambda (value) (cons 'signal value)))
   (else (cons 'unknown status))))

(define (wait-child/nohang pid)
  (catch 'system-error
    (lambda ()
      (let ((result (waitpid pid WNOHANG)))
        (and (not (zero? (car result))) (decoded-status (cdr result)))))
    (lambda arguments
      (if (= (system-error-errno arguments) ECHILD)
          '(already-reaped . 0)
          (apply throw 'system-error arguments)))))

(define (terminate-ui-peer! pid)
  (let ((status (wait-child/nohang pid)))
    (unless status
      (catch 'system-error
        (lambda () (kill pid SIGTERM))
        (lambda arguments
          (unless (= (system-error-errno arguments) ESRCH)
            (apply throw 'system-error arguments))))
      (let ((deadline (+ (now-seconds) 1.0)))
        (let loop ()
          (set! status (wait-child/nohang pid))
          (when (and (not status) (< (now-seconds) deadline))
            (usleep 10000)
            (loop))))
      (unless status
        (catch 'system-error
          (lambda () (kill pid SIGKILL))
          (lambda arguments
            (unless (= (system-error-errno arguments) ESRCH)
              (apply throw 'system-error arguments))))
        (set! status (decoded-status (cdr (waitpid pid))))))
    status))

(define (main arguments)
  (match arguments
    ((mode guile-bundle python-bundle fake-runsc timeout transcript-path)
     (unless (member mode '("positive" "disconnect" "repeat-submit"
                            "repeat-tick" "wrong-generation" "malformed"))
       (error "unknown private UI host-test mode" mode))
     (let ((seconds (string->number timeout)))
       (unless (and seconds (> seconds 0))
         (error "host-test timeout must be positive" timeout))
       (let* ((pair (socketpair AF_UNIX
                                (logior SOCK_STREAM SOCK_CLOEXEC) 0))
              (authority-port (car pair))
              (reader-port (cdr pair))
              (reader-pid (primitive-fork))
              (control #f)
              (completed? #f)
              (reader-status #f))
         (if (zero? reader-pid)
             (begin
               (close-port-quietly! authority-port)
               (catch #t
                 (lambda ()
                   (run-ui-peer reader-port transcript-path mode)
                   (close-port-quietly! reader-port)
                   (primitive-exit 0))
                 (lambda (key . details)
                   (format (current-error-port)
                           "trusted UI peer failed: ~s ~s~%" key details)
                   (force-output (current-error-port))
                   (primitive-exit 1))))
             (dynamic-wind
               (lambda ()
                 (close-port-quietly! reader-port)
                 (set! control
                       (adopt-book-ui-control-port!
                        authority-port #:require-character? #f)))
               (lambda ()
                 (let ((deadline (+ (now-seconds) seconds)))
                   (run-reader-protocol-pair!
                    control guile-bundle python-bundle
                    #:evidence-mode 'host-fake
                    #:runtime-override fake-runsc
                    #:deadline deadline)
                   (wait-for-ui-completion! control deadline)
                   (set! reader-status (decoded-status (cdr (waitpid reader-pid))))
                   (unless (equal? reader-status '(exit . 0))
                     (error "trusted UI peer did not exit zero" reader-status))
                   (set! completed? #t)
                   (display "BOOKEXEC-READER-PROTOCOL-HOST-TEST=PASS\n")))
               (lambda ()
                 (close-book-ui-control! control)
                 (unless reader-status
                   (set! reader-status (terminate-ui-peer! reader-pid))))))
         (if completed? 0 1))))
    (_
     (error "expected MODE GUILE-BUNDLE PYTHON-BUNDLE FAKE-RUNSC TIMEOUT TRANSCRIPT"))))

(exit
 (catch #t
   (lambda () (main (cdr (command-line))))
   (lambda (key . arguments)
     (format (current-error-port) "reader interaction host test failed: ~s ~s~%"
             key arguments)
     1)))
