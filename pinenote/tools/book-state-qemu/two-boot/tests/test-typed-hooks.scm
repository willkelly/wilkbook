#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Host-only proof for the closed private-outer integration record.
(use-modules (disposable-qemu)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define qemu-argv/integration
  (@@ (disposable-qemu) qemu-argv/integration))
(define process-hooks-for
  (@@ (disposable-qemu) process-hooks-for))
(define validate-integration
  (@@ (disposable-qemu) validate-book-state-integration))
(define hook-exec
  (@@ (disposable-qemu) book-state-process-exec-extension))
(define hook-guardian
  (@@ (disposable-qemu) book-state-process-guardian-observer))
(define hook-child
  (@@ (disposable-qemu) book-state-process-child-observer))
(define hook-complete
  (@@ (disposable-qemu) book-state-process-completion-observer))

(define (rejected? thunk)
  (catch 'book-execution-qemu-error
    (lambda () (thunk) #f)
    (lambda _ #t)))

(test-begin "two-boot-typed-private-outer-hooks")

(let* ((events '())
       (fixed-vector '("trusted-coordinator" "--" "qemu"))
       (integration
        (make-book-state-qemu-integration
         (lambda (root identity)
           (set! events (cons (list 'root root identity) events)))
         (lambda (pid) (set! events (cons (list 'root-guardian pid) events)))
         (lambda arguments
           (set! events (cons (cons 'graph arguments) events))
           fixed-vector)
         (lambda (role argv environment cwd stdout stderr timeout grace)
           (set! events
                 (cons (list 'process role argv environment cwd stdout stderr
                             timeout grace)
                       events))
           (make-book-state-process-hooks
            (and (eq? role 'qemu) (lambda () #t))
            (lambda (pid) (set! events (cons (list 'guardian role pid) events)))
            (lambda (pid) (set! events (cons (list 'child role pid) events)))
            (lambda (completed result)
              (set! events (cons (list 'complete completed result) events)))))
         (lambda arguments
           (set! events (cons (cons 'console arguments) events)))
         (lambda (root identity)
           (set! events (cons (list 'delete root identity) events))))))
  (test-assert "complete fixed-role integration validates before use"
    (eq? integration (validate-integration integration)))
  (test-equal "graph call uses only the committed record callback"
    fixed-vector
    (qemu-argv/integration integration
                           "qemu" "/run" "/kernel" "/initrd" "append"
                           "/overlay"))
  (let ((hooks
         (process-hooks-for integration 'qemu '("owner") '("LC_ALL=C")
                            "/run" "/out" "/err" 360.0 5.0)))
    (test-assert "qemu role receives an exact typed hook record"
      (and (book-state-process-hooks? hooks)
           (procedure? (hook-exec hooks))))
    ((hook-guardian hooks) 1001)
    ((hook-child hooks) 1002)
    ((hook-complete hooks) 'qemu '(0 . #f)))
  (let ((before (length events)))
    (test-assert "unknown process role is rejected before callback action"
      (rejected?
       (lambda ()
         (process-hooks-for integration 'caller-plugin '("x") '() "/run"
                            "/out" "/err" 1.0 1.0))))
    (test-equal "unknown role did not enter trusted hook builder"
      before (length events))))

(test-assert "incomplete/non-record integration fails closed"
  (rejected? (lambda () (validate-integration (vector 'callbacks)))))

(let ((bad
       (make-book-state-qemu-integration
        (lambda _ #t) (lambda _ #t) (lambda _ '("qemu"))
        (lambda _
          (make-book-state-process-hooks
           (lambda () #t) (lambda _ #t) (lambda _ #t) (lambda _ #t)))
        (lambda _ #t) (lambda _ #t))))
  (test-assert "only fixed qemu/coordinator role may receive an inherited FD"
    (rejected?
     (lambda ()
       (process-hooks-for bad 'copy-kernel '("cp") '() "/run"
                          "/out" "/err" 60.0 5.0)))))

(let ((default
       (qemu-argv/integration
         #f "qemu" "/run" "/kernel" "/initrd" "root=PNGuixRoot ro"
        "/overlay")))
  (test-equal "no-integration path preserves accepted default graph prefix"
    '("qemu" "-no-user-config" "-nodefaults" "-M" "virt" "-accel"
      "tcg,thread=multi" "-cpu" "max" "-smp" "4" "-m" "2048")
    (list-head default 13))
  (test-assert "no-integration path retains unpaused accepted graph"
    (and (not (member "-S" default))
         (member "-device" default))))

;; Static source proof is intentional: production must never restore the old
;; global mutation route, even though a test could mutate module bindings.
(for-each
 (lambda (path)
   (let ((text (call-with-input-file path get-string-all)))
     (test-assert (string-append path " has no module-set integration")
       (not (string-contains text "module-set!")))))
 '("one-boot.scm" "modules/disposable-qemu.scm" "run-two-boot.scm"))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-typed-private-outer-hooks")
(exit (if (zero? failures) 0 1))
