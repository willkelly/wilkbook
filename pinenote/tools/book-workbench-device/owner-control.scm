;;; Guile consumer of the accepted editor sandbox owner's private receipts.
;;; No process launch, socket I/O, timers, source evaluation, or ticket issuance.
(define-module (owner-control)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (make-owner-control
            owner-control-feed! owner-control-eof! owner-control-stop!
            owner-control-exited! owner-control-can-deliver?
            owner-control-cleanup-complete? owner-control-preview-eligible?))

(define-record-type <owner-control>
  (%make-owner-control pending ready clean stopped early eof terminal poisoned)
  owner-control?
  (pending pending set-pending!)
  (ready ready? set-ready!)
  (clean clean? set-clean!)
  (stopped stopped? set-stopped!)
  (early early? set-early!)
  (eof eof? set-eof!)
  (terminal terminal set-terminal!)
  (poisoned poisoned? set-poisoned!))

(define (make-owner-control)
  (%make-owner-control "" #f #f #f #f #f #f #f))

(define (reject! control reason)
  (set-poisoned! control #t)
  (throw 'owner-control-error reason))

(define (require-live! control)
  (when (poisoned? control) (reject! control 'retired-control)))

(define (owner-control-feed! control bytes)
  (require-live! control)
  (when (eof? control) (reject! control 'bytes-after-eof))
  (unless (bytevector? bytes) (reject! control 'not-bytes))
  ;; Incremental prefix validation bounds retained data to six bytes, stricter
  ;; than the accepted transport's 32-byte buffer. Arbitrary fragmentation and
  ;; coalesced ready/clean are valid; no trailing byte after clean is valid.
  (let loop ((index 0))
    (when (< index (bytevector-length bytes))
      (when (clean? control) (reject! control 'bytes-after-clean))
      (let* ((byte (bytevector-u8-ref bytes index))
             (next (string-append (pending control) (string (integer->char byte)))))
        (cond
         ((string=? next "ready\n")
          (when (ready? control) (reject! control 'duplicate-ready))
          (set-ready! control #t) (set-pending! control ""))
         ((string=? next "clean\n")
          ;; A failed preparation may send clean without ever sending ready.
          (unless (stopped? control) (set-early! control #t))
          (set-clean! control #t) (set-pending! control ""))
         ((or (and (not (ready? control)) (string-prefix? next "ready\n"))
              (string-prefix? next "clean\n"))
          (set-pending! control next))
         (else (reject! control 'invalid-receipt))))
      (loop (+ index 1)))))

(define (owner-control-eof! control)
  ;; The caller must feed every received byte before reporting actual socket EOF.
  ;; Process exit, EAGAIN, timeout or local socket closure is not that observation.
  (require-live! control)
  (unless (and (clean? control) (string-null? (pending control)))
    (reject! control 'eof-without-clean))
  (set-eof! control #t))

(define (owner-control-stop! control)
  (require-live! control)
  ;; Record trusted stop intent before sending stop. This is not proof that the
  ;; peer received it. The runtime owner's terminal verdict remains required.
  (set-stopped! control #t))

(define (owner-control-exited! control kind code)
  (require-live! control)
  (unless (and (memq kind '(exit signal)) (exact-integer? code)
               (if (eq? kind 'exit) (<= 0 code 255) (<= 1 code 127))
               (not (terminal control)))
    (reject! control 'invalid-terminal-observation))
  (unless (stopped? control) (set-early! control #t))
  ;; waitpid may become readable before the final socket bytes are drained.
  ;; Keep that ordering legal, but prohibit all subsequent authored delivery.
  (set-terminal! control (cons kind code)))

(define (owner-control-can-deliver? control)
  (and (not (poisoned? control)) (ready? control)
       (not (clean? control)) (not (stopped? control))
       (not (terminal control))))

(define (owner-control-cleanup-complete? control)
  ;; Disposal evidence, not a final stream verdict. A later invalid receipt can
  ;; still poison this state; successful preview additionally requires EOF.
  (and (not (poisoned? control)) (clean? control)
       (if (terminal control) #t #f)))

(define (owner-control-preview-eligible? control)
  ;; Necessary execution evidence only: the caller must separately prove Finish,
  ;; the accepted idle candidate form, disposable authority/store cleanup, and
  ;; the still-current saved source/version/activation CAS. Never issue a ticket
  ;; merely because this predicate returned true.
  ;; A waited owner may leave unread trailing bytes. Require terminal drain so
  ;; those bytes are validated before this predicate can authorize success.
  (and (owner-control-cleanup-complete? control) (eof? control) (ready? control)
       (stopped? control) (not (early? control))
       (equal? (terminal control) '(exit . 0))))
