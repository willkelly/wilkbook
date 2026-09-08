#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Finite host model for the accepted hard process-group guardian.
(use-modules (disposable-qemu)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64)
             (two-boot fd-handoff))

(define %outer (resolve-module '(disposable-qemu)))
(define (outer name) (module-ref %outer name))
(define root (mkdtemp "/tmp/opencode/two-boot-timeout-test.XXXXXX"))
(define helper
  (canonicalize-path
   (string-append (dirname (canonicalize-path (car (command-line))))
                  "/never-halts.scm")))
(define guile (canonicalize-path "/proc/self/exe"))
(define true-program
  "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/true")

(define (environment)
  (list (string-append "PATH=" (dirname guile))
        "HOME=/nonexistent" "LANG=C" "LC_ALL=C"))

(define (liveness-port)
  (open-file "/dev/null" "w"))

(define (wait-for path)
  (let ((deadline (+ (get-internal-real-time)
                     (* 2 internal-time-units-per-second))))
    (let loop ()
      (cond ((file-exists? path) #t)
            ((>= (get-internal-real-time) deadline) #f)
            (else (usleep 10000) (loop))))))

(define (wait-gone record)
  (let ((deadline (+ (get-internal-real-time)
                     (* 2 internal-time-units-per-second))))
    (let loop ()
      (cond
       ((not (process-instance-live? (assoc-ref record 'pid)
                                     (assoc-ref record 'start-time))) #t)
       ((>= (get-internal-real-time) deadline) #f)
       (else (usleep 10000) (loop))))))

(define (spawn-foreign)
  (force-output)
  (force-output (current-error-port))
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (setpgid 0 0)
          (for-each (lambda (signal-number) (sigaction signal-number SIG_IGN))
                    (list SIGINT SIGHUP SIGTERM SIGPIPE))
          (let loop () (usleep 100000) (loop)))
        (begin
          (usleep 20000)
          `((schema . 1) (role . foreign-control) (pid . ,pid)
            (start-time . ,(let loop ()
                             (let ((value
                                    (catch 'system-error
                                      (lambda ()
                                        (let* ((text
                                                (call-with-input-file
                                                    (format #f "/proc/~a/stat" pid)
                                                  get-string-all))
                                               (close (string-rindex text #\)))
                                               (fields
                                                (string-tokenize
                                                 (substring text (+ close 2)))))
                                          (list-ref fields 19)))
                                      (lambda _ #f))))
                               (if value value
                                   (begin (usleep 1000) (loop)))))))))))

(define (stop-foreign record)
  (when (process-instance-live? (assoc-ref record 'pid)
                                (assoc-ref record 'start-time))
    (kill (- (assoc-ref record 'pid)) SIGKILL))
  (catch 'system-error
    (lambda () (waitpid (assoc-ref record 'pid)))
    (lambda _ #f)))

(chmod root #o700)
(test-begin "two-boot-hard-timeout")
(test-assert "fast exec child remains held until its identity is observed"
  (every
   identity
   (map
    (lambda (index)
      (let* ((stem (string-append root "/fast-" (number->string index)))
             (child-record (string-append stem "-child.scm"))
             (liveness (liveness-port))
             (_ (begin (force-output) (force-output (current-error-port))))
             (result
              ((outer 'run-owned-process)
               (list true-program) (environment) root
               (string-append stem ".stdout")
               (string-append stem ".stderr")
               1.0 0.10 liveness
               #:child-observer
               (make-process-record-observer child-record 'fast-child))))
        (close-port liveness)
        (and (equal? result '(0 . #f))
             (read-process-identity child-record))))
    (iota 20))))
(let ((foreign (spawn-foreign)))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let* ((writer-record (string-append root "/deadline-writer.scm"))
             (guardian-record (string-append root "/deadline-guardian.scm"))
             (child-record (string-append root "/deadline-child.scm"))
             (liveness (liveness-port))
             (started (get-internal-real-time))
             (result
              ((outer 'run-owned-process)
               (list guile "--no-auto-compile" helper writer-record)
               (environment) root
               (string-append root "/deadline.stdout")
               (string-append root "/deadline.stderr")
               0.30 0.10 liveness
               #:guardian-observer
               (make-process-record-observer guardian-record
                                             'deadline-guardian)
               #:child-observer
               (make-process-record-observer child-record 'deadline-child)))
             (elapsed (/ (- (get-internal-real-time) started)
                         internal-time-units-per-second 1.0)))
        (close-port liveness)
        (test-equal "hard guardian reports timeout" '(124 . #t) result)
        (test-assert "hard deadline is finite and independent of helper output"
          (< elapsed 2.0))
        (test-assert "cooperative-expiry text did not stop or pass the helper"
          (string=?
           (call-with-input-file (string-append root "/deadline.stdout")
             get-string-all)
           "COOPERATIVE_GUEST_BUDGET_EXPIRED_BUT_HELPER_STILL_LIVE\n"))
        (test-assert "deadline direct child is gone"
          (wait-gone (read-process-identity child-record)))
        (test-assert "deadline stubborn writer is gone"
          (and (wait-for writer-record)
               (wait-gone (read-process-identity writer-record))))
        (test-assert "deadline guardian is reaped"
          (wait-gone (read-process-identity guardian-record)))
        (test-assert "foreign same-UID control is not signalled or reaped"
          (process-instance-live? (assoc-ref foreign 'pid)
                                  (assoc-ref foreign 'start-time))))

      (let* ((writer-record (string-append root "/kill-writer.scm"))
             (guardian-record (string-append root "/kill-guardian.scm"))
             (child-record (string-append root "/kill-child.scm"))
             (_ (begin (force-output) (force-output (current-error-port))))
             (owner (primitive-fork)))
        (if (zero? owner)
            (let ((liveness (liveness-port)))
              ((outer 'run-owned-process)
               (list guile "--no-auto-compile" helper writer-record)
               (environment) root
               (string-append root "/kill.stdout")
               (string-append root "/kill.stderr")
               30.0 0.10 liveness
               #:guardian-observer
               (make-process-record-observer guardian-record 'kill-guardian)
               #:child-observer
               (make-process-record-observer child-record 'kill-child))
              (primitive-exit 99))
            (begin
              (test-assert "owner-kill fixture published all exact identities"
                (and (wait-for writer-record) (wait-for guardian-record)
                     (wait-for child-record)))
              (kill owner SIGKILL)
              (waitpid owner)
              (test-assert "owner SIGKILL closes liveness and kills direct child"
                (wait-gone (read-process-identity child-record)))
              (test-assert "owner SIGKILL escalates stubborn writer"
                (wait-gone (read-process-identity writer-record)))
              (test-assert "owner SIGKILL leaves no accepted process guardian"
                (wait-gone (read-process-identity guardian-record)))
              (test-assert "owner SIGKILL does not touch foreign process"
                (process-instance-live? (assoc-ref foreign 'pid)
                                        (assoc-ref foreign 'start-time)))))))
    (lambda () (stop-foreign foreign))))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-hard-timeout")
((outer 'delete-created-tree) root)
(exit (if (zero? failures) 0 1))
