;;; Test-only paused/QMP wrapper around the frozen accepted state-reader graph.
(define-module (guardian-integration successor-reader-graph)
  #:use-module (book-state-qemu qemu-graph)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (paused-state-reader-qemu-arguments
            assert-paused-state-reader-qemu-arguments))

(define (graph-error message . arguments)
  (throw 'book-state-qemu-guardian-integration-error
         (apply format #f message arguments)))

(define (safe-qmp-path? run-root qmp-path)
  (and (string? run-root)
       (string? qmp-path)
       (string=? qmp-path (string-append run-root "/qmp.sock"))
       (not (any (lambda (character)
                   (or (< (char->integer character) #x20)
                       (char=? character #\,)))
                 (string->list qmp-path)))))

(define (replace-exact-option arguments option old-value new-value)
  (let loop ((remaining arguments) (result '()) (seen? #f))
    (cond
     ((null? remaining)
      (unless seen?
        (graph-error "accepted reader graph lacks ~a" option))
      (reverse result))
     ((string=? (car remaining) option)
      (when seen?
        (graph-error "accepted reader graph repeats ~a" option))
      (unless (and (pair? (cdr remaining))
                   (string=? (cadr remaining) old-value))
        (graph-error "accepted reader graph changed ~a from ~a"
                     option old-value))
      (loop (cddr remaining)
            (cons new-value (cons option result))
            #t))
     (else
      (loop (cdr remaining) (cons (car remaining) result) seen?)))))

(define (bounded-reader-arguments base)
  ;; The accepted graph requests four vCPUs and 2 GiB.  This authorized host
  ;; gate privately narrows those two resource values and changes nothing else.
  (replace-exact-option
   (replace-exact-option base "-smp" "4" "2")
   "-m" "2048" "512"))

(define (paused-state-reader-qemu-arguments qemu run-root kernel initrd
                                             append-line overlay handoff)
  (unless (safe-qmp-path? run-root (string-append run-root "/qmp.sock"))
    (graph-error "run root cannot name the fixed private QMP socket"))
  (let* ((qmp-path (string-append run-root "/qmp.sock"))
         (accepted-base
          (leased-state-volume-qemu-arguments
           qemu run-root kernel initrd append-line overlay handoff)))
    (assert-leased-state-volume-qemu-arguments
     accepted-base qemu run-root kernel initrd append-line overlay handoff)
    ;; This finite host gate deliberately pauses before the first guest
    ;; instruction, narrows the accepted resource request to the authorized
    ;; maximum, and adds one private Unix QMP fixture.  It does not alter the
    ;; frozen reader/state source or introduce a TCP listener.
    (append (bounded-reader-arguments accepted-base)
            (list "-S" "-qmp"
                  (string-append "unix:" qmp-path
                                 ",server=on,wait=off")))))

(define (assert-paused-state-reader-qemu-arguments
         arguments qemu run-root kernel initrd append-line overlay handoff)
  (let ((expected
         (paused-state-reader-qemu-arguments
          qemu run-root kernel initrd append-line overlay handoff)))
    (unless (and (list? arguments)
                 (every string? arguments)
                 (equal? arguments expected)
                  (= (count (lambda (item) (string=? item "-S")) arguments) 1)
                  (= (count (lambda (item) (string=? item "-qmp")) arguments) 1)
                  (= (count (lambda (item) (string=? item "-smp")) arguments) 1)
                  (= (count (lambda (item) (string=? item "-m")) arguments) 1)
                  (let ((smp (member "-smp" arguments string=?))
                        (memory (member "-m" arguments string=?)))
                    (and smp (pair? (cdr smp)) (string=? (cadr smp) "2")
                         memory (pair? (cdr memory))
                         (string=? (cadr memory) "512")))
                  (member "none" arguments string=?)
                 (not (member "-netdev" arguments string=?))
                 (not (member "-virtfs" arguments string=?))
                 (not (member "-fsdev" arguments string=?)))
      (graph-error "paused QEMU vector is not the exact test-only extension"))
    #t))
