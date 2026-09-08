;;; Reader-level structural regression for the production session owner.  This
;;; rejects the exact malformed catch/dynamic-wind shapes that Guile accepted
;;; syntactically and only reported as wrong-number-of-args on the device.
(use-modules (ice-9 match)
             (srfi srfi-1))

(define (fail message . details) (apply error message details))

(define source
  (match (cdr (command-line))
    ((path) path)
    (_ (fail "usage: test-authority-control-structure.scm AUTHORITY.scm"))))

(define (read-session-form path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((form (read port)))
        (cond
         ((eof-object? form) (fail "run-sandbox-session! definition is absent"))
         ((and (pair? form) (eq? (car form) 'define)
               (pair? (cadr form))
               (eq? (caadr form) 'run-sandbox-session!))
          form)
         (else (loop (read port))))))))

(define (tagged-forms tree tag)
  (if (pair? tree)
      (append (if (eq? (car tree) tag) (list tree) '())
              (tagged-forms (car tree) tag)
              (tagged-forms (cdr tree) tag))
      '()))

(define (correct-arity? form) (= (length form) 4))
(define session-form (read-session-form source))
(define catches (tagged-forms session-form 'catch))
(define winds (tagged-forms session-form 'dynamic-wind))

(unless (and (= (length catches) 3) (every correct-arity? catches))
  (fail "production session catches are not exactly three key/thunk/handler calls"
        (map length catches)))
(unless (and (= (length winds) 1) (every correct-arity? winds))
  (fail "production session dynamic-wind is not one before/body/after call"
        (map length winds)))

;; Pin rejection of both historical shapes: a nested handler left catch with
;; only key/thunk, and a nested after thunk left dynamic-wind with only
;; before/body (or absorbed later body expressions as extra arguments).
(when (correct-arity? '(catch #t (lambda () (lambda (key . args) #f))))
  (fail "three-element malformed catch was accepted by the arity gate"))
(when (correct-arity?
       '(dynamic-wind (lambda () #t)
                      (lambda () (lambda () 'misnested-after))))
  (fail "three-element malformed dynamic-wind was accepted by the arity gate"))

(format #t
        "PASS: production run-sandbox-session! AST catch-calls=~a arities=~s dynamic-wind-calls=~a arities=~s; malformed forms rejected~%"
        (length catches) (map length catches)
        (length winds) (map length winds))
