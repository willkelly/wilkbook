#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Separate-process crash/restart driver for test_book_state_crash.py only.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (book-state)
             (ice-9 match))

(define commit-fault-hook-for-test
  (@@ (book-state) commit-fault-hook))
(define book-revision "test-book@revision-1")
(define instance-id "test-user-instance-1")

(define (print-result value)
  (cond
   ((book-state-absent? value)
    (write `(absent ,(book-state-absent-state-version value))))
   ((book-state-value? value)
    (write `(value ,(book-state-value-state-version value)
                   ,(book-state-value-text value))))
   ((book-state-receipt? value)
    (write `(receipt ,(book-state-receipt-operation-id value)
                     ,(book-state-receipt-expected-state-version value)
                     ,(book-state-receipt-state-version value)
                     ,(book-state-receipt-text-bytes value))))
   ((book-state-rejection? value)
    (write `(rejection ,(book-state-rejection-code value)
                       ,(book-state-rejection-current-state-version value))))
   (else (write `(unexpected ,value))))
  (newline)
  (force-output))

(define (with-test-grant root access procedure)
  (let ((store (open-book-state-store root)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((namespace
                (open-book-instance! store book-revision instance-id))
               (owner (list 'separate-process-owner))
               (grant (issue-book-state-grant! store namespace owner access)))
          (procedure store owner grant)))
      (lambda () (close-book-state-store! store)))))

(define (main arguments)
  (match arguments
    (("read" root)
     (with-test-grant
      root 'read-only
      (lambda (store owner grant)
        (print-result
         (read-book-state store owner grant
                          (book-state-grant-generation grant))))))
    (("commit" root fault operation-id expected-version text)
     (let ((expected (string->number expected-version 10))
           (fault-point (string->symbol fault)))
       (unless (and expected (integer? expected)
                    (memq fault-point
                          '(none before-commit after-commit-before-ack)))
         (error "invalid test worker commit arguments"))
       (with-test-grant
        root 'read-write
        (lambda (store owner grant)
          (parameterize
              ((commit-fault-hook-for-test
                (lambda (point)
                  (when (eq? point fault-point)
                    (kill (getpid) SIGKILL)))))
            (print-result
             (commit-book-state!
              store owner grant (book-state-grant-generation grant)
              operation-id expected text)))))))
    (_
     (format (current-error-port)
             "usage: ~a read ROOT | commit ROOT FAULT OP EXPECTED TEXT~%"
             (car (command-line)))
     (exit 2))))

(umask #o077)
(main (cdr (command-line)))
