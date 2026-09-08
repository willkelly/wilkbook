#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; First Guile process after Python authenticated and retained all source bytes.
(use-modules (disposable-qemu)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-13)
             (two-boot source-gate)
             (two-boot timeout-contract))

(define (fail message . arguments)
  (runner-error (apply format #f message arguments)))

(define (parse-bootstrap-argv argv)
  (match (cdr argv)
    (("--bootstrap-root" root
      "--source-root" source
      "--source-manifest-sha256" manifest
      "--" campaign ...)
     (values root source manifest campaign))
    (_ (fail "authenticated bootstrap invocation has malformed arguments"))))

(define (run-authenticated-capsule argv)
  (call-with-values
      (lambda () (parse-bootstrap-argv argv))
    (lambda (root source manifest campaign)
      (unless (and (string-prefix? "/tmp/opencode/" root)
                   (string=? root (canonicalize-path root))
                   (string=? source (string-append root "/source"))
                   (string=? source (canonicalize-path source)))
        (fail "retained capsule root/source relationship differs"))
      (let ((root-identity (lstat root))
            (source-identity (lstat source))
            (guardian #f)
            (cleaned? #f)
            (status #f)
            (failure #f))
        (unless (and (eq? (stat:type root-identity) 'directory)
                     (= (stat:uid root-identity) (getuid))
                     (= (logand (stat:mode root-identity) #o7777) #o700)
                     (eq? (stat:type source-identity) 'directory)
                     (= (stat:uid source-identity) (getuid))
                     (= (logand (stat:mode source-identity) #o7777) #o700))
          (fail "retained capsule root/source mode or ownership differs"))
        (set! guardian (start-run-root-guardian root root-identity 5.0))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (verify-two-boot-source-root! source manifest
                                          #:guarded-private? #t)
            ;; Only this retained pathname is loaded; no checked caller helper
            ;; path is reopened after authentication.
            (primitive-load (string-append source "/run-two-boot.scm"))
            (let ((entry (module-ref (current-module) 'run-two-boot-main)))
              (unless (procedure? entry)
                (fail "retained campaign entry did not define its fixed main"))
              (set! status
                    (entry (cons (string-append source "/run-two-boot.scm")
                                 campaign)
                           source manifest))))
          (lambda ()
            (catch #t
              (lambda ()
                (let ((current (lstat-or-false root)))
                  (unless (and current (same-identity? current root-identity))
                    (fail "retained bootstrap root was replaced; preserved"))
                  (delete-created-tree root)
                  (set! cleaned? #t)))
              (lambda (key . arguments)
                (set! failure (cons key arguments))))
            (catch #t
              (lambda () (stop-run-root-guardian guardian cleaned?))
              (lambda (key . arguments)
                (unless failure (set! failure (cons key arguments)))))))
        (when failure (apply throw failure))
        (unless (and cleaned? (integer? status))
          (fail "authenticated capsule did not return a bounded status"))
        status))))

(for-each
 (lambda (signal-number)
   (sigaction signal-number
              (lambda (received)
                (note-disposable-qemu-signal received))))
 (list SIGINT SIGHUP SIGTERM))
(sigaction SIGPIPE SIG_IGN)
(umask #o077)

(exit
 (catch #t
   (lambda () (run-authenticated-capsule (command-line)))
   (lambda (key . arguments)
     (format (current-error-port) "TWO_BOOT_BOOTSTRAP_MAIN_FAIL: ~s ~s~%"
             key arguments)
     (force-output (current-error-port))
     1)))
