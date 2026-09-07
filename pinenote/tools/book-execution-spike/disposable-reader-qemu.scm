;;; Reader-specific entry over the accepted disposable-QEMU ownership engine.
;;; This module changes no non-reader invocation.  In this process only, it
;;; selects the fixed coordinator as the guarded direct child and joins its
;;; lifecycle result with the reader guest console checker.
(define-module (disposable-reader-qemu)
  #:use-module (disposable-qemu)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (reader-protocol-console-assertions)
  #:use-module (reader-qemu-graph)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (disposable-reader-qemu-main))

(define %outer-module (resolve-module '(disposable-qemu)))
(define (outer-private name) (module-ref %outer-module name))

(define coordinator-success-line
  "BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass\n")
(define inherited-success-line
  "OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS\n")
(define joined-success-line
  "OUTER-READER-QEMU-STATUS=0; COORDINATOR-STATUS=0; NATIVE-READER-LIFECYCLE=PASS; GUEST-READER-PROTOCOL=PASS; CLEAN-POWER-DOWN=PASS\n")
(define expected-koreader-package
  "/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03")

;; These are the frozen coordinator source identities handed off in
;; 2026-09-06-book-interaction-qemu-seam-implementation.md.  The outer copies
;; only these five files into its identity-guarded private run root.
(define coordinator-source-sha256
  '(;; Relative to qemu-coordinator.scm's directory.
    ("qemu-coordinator.scm"
     . "ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde")
    ("fixture/bookinteractionprobe.koplugin/_meta.lua"
     . "89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964")
    ("fixture/bookinteractionprobe.koplugin/main.lua"
     . "8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125")
    ("fixture/bookinteractionprobe.koplugin/private_channel.lua"
     . "4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832")
    ("fixture/bookinteractionprobe.koplugin/ui_audit.lua"
     . "cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a")))

(define (reader-error message . arguments)
  ((outer-private 'runner-error) (apply format #f message arguments)))

(define (file-sha256-string path)
  (bytevector->base16-string (file-sha256 path)))

(define (same-stable-file? left right)
  ((outer-private 'same-stable-file?) left right))

(define (mkdir-private path)
  (when ((outer-private 'lstat-or-false) path)
    (reader-error "refusing pre-existing reader coordinator path: ~a" path))
  (mkdir path #o700)
  (chmod path #o700))

(define (snapshot-one-source! source destination expected)
  (let ((before (lstat source)))
    (unless (and (eq? (stat:type before) 'regular)
                 (= (stat:nlink before) 1)
                 (string=? (file-sha256-string source) expected))
      (reader-error "reader coordinator source identity mismatch: ~a" source))
    (copy-file source destination)
    (chmod destination #o400)
    (let ((after (lstat source))
          (copied (lstat destination)))
      (unless (and (same-stable-file? before after)
                   (eq? (stat:type copied) 'regular)
                   (= (stat:nlink copied) 1)
                   (zero? (logand (stat:mode copied) #o222))
                   (string=? (file-sha256-string destination) expected))
        (reader-error "reader coordinator source changed while snapshotting: ~a"
                      source)))))

(define (stage-coordinator-sources! source-file run-root)
  (let* ((source-root (dirname source-file))
         (destination-root (string-append run-root "/reader-coordinator"))
         (fixture-root (string-append destination-root "/fixture"))
         (plugin-root
          (string-append fixture-root "/bookinteractionprobe.koplugin")))
    (unless (string=? (basename source-file) "qemu-coordinator.scm")
      (reader-error "fixed coordinator source must be named qemu-coordinator.scm"))
    (for-each mkdir-private
              (list destination-root fixture-root plugin-root))
    (for-each
     (lambda (entry)
       (let ((relative (car entry)) (expected (cdr entry)))
         (snapshot-one-source!
          (string-append source-root "/" relative)
          (string-append destination-root "/" relative)
          expected)))
     coordinator-source-sha256)
    (string-append destination-root "/qemu-coordinator.scm")))

(define (validate-koreader-package path)
  (let* ((canonical
          ((outer-private 'canonical-existing) path "KOReader package"))
         (info (lstat canonical)))
    (unless (and (eq? (stat:type info) 'directory)
                 (string=? canonical expected-koreader-package))
      (reader-error "KOReader package is not the exact pinned v2026.03 output"))
    canonical))

(define (validate-coordinator-source path)
  (let ((canonical
         ((outer-private 'canonical-existing) path "reader coordinator source")))
    (unless (and (eq? (stat:type (lstat canonical)) 'regular)
                 (string=? (basename canonical) "qemu-coordinator.scm"))
      (reader-error "reader coordinator source is not the fixed regular file"))
    canonical))

(define (validate-coordinator-success! run-root)
  (let ((path (string-append run-root "/qemu.stdout")))
    (let ((info ((outer-private 'lstat-or-false) path)))
      (unless (and info
                   (eq? (stat:type info) 'regular)
                   (<= (stat:size info) 4096))
        (reader-error "bounded coordinator stdout is absent or invalid")))
    (unless (string=? (call-with-input-file path get-string-all)
                      coordinator-success-line)
      (reader-error "coordinator lacked its exact payload-free success line"))))

(define (validate-reader-completion path run-root stderr-path)
  ;; The inherited engine calls this only after its guarded direct child (the
  ;; coordinator) and all same-PGID descendants have been reaped at status 0.
  (catch #t
    (lambda ()
      ((outer-private 'assert-console-retainable) path)
      (assert-reader-protocol-console-file path)
      (validate-coordinator-success! run-root))
    (lambda (key . arguments)
      ((outer-private 'emit-qemu-failure-diagnostics) run-root stderr-path)
      (reader-error "joined reader/QEMU assertions failed: ~s ~s"
                    key arguments))))

(define reader-option-names
  '("--coordinator" "--koreader-package" "--guile"))

(define (extract-reader-options argv)
  (let loop ((rest (cdr argv)) (base (list (car argv))) (options '()))
    (match rest
      (() (values (reverse base) options))
      ((name value tail ...)
       (if (member name reader-option-names string=?)
           (begin
             (when (assoc name options)
               (reader-error "duplicate reader option: ~a" name))
             (loop tail base (acons name value options)))
           (loop (cdr rest) (cons name base) options)))
      ((name)
       (if (member name reader-option-names string=?)
           (reader-error "reader option lacks a value: ~a" name)
           (loop '() (cons name base) options))))))

(define (required-reader-option options name)
  (or (assoc-ref options name)
      (reader-error "missing required reader option: ~a" name)))

(define (usage port program)
  (format port
          "usage: ~a --coordinator FILE --koreader-package DIR --guile FILE [ACCEPTED-DISPOSABLE-QEMU-OPTIONS]\n"
          program))

(define (run-reader argv)
  (call-with-values
      (lambda () (extract-reader-options argv))
    (lambda (base-argv options)
      (when (or (member "--help" base-argv string=?)
                (member "-h" base-argv string=?))
        (usage (current-output-port) (car argv))
        (exit 0))
      (unless (= (length options) 3)
        (usage (current-error-port) (car argv))
        (reader-error "all three fixed reader options are required exactly once"))
      (let* ((coordinator
              (validate-coordinator-source
               (required-reader-option options "--coordinator")))
             (koreader
              (validate-koreader-package
               (required-reader-option options "--koreader-package")))
             (guile
              ((outer-private 'resolve-executable)
               (required-reader-option options "--guile") "guile"))
             (accepted-qemu-argv (outer-private 'qemu-argv))
             (accepted-validator
              (outer-private 'validate-completed-guest-console))
             (observed-run-root #f)
             (observed-run-identity #f)
             (captured (open-output-string))
             (status #f))
        (dynamic-wind
          (lambda ()
            ;; Exact, process-local extension points only.  The separate entry
            ;; restores both even on failure; ordinary disposable-qemu users
            ;; never load this module and retain byte-for-byte behavior.
            (module-set!
             %outer-module 'qemu-argv
             (lambda (qemu run-root kernel initrd append-line overlay)
               (when observed-run-root
                 (reader-error "reader QEMU graph was requested more than once"))
               (set! observed-run-root run-root)
               (set! observed-run-identity (lstat run-root))
               (let ((private-coordinator
                      (stage-coordinator-sources! coordinator run-root)))
                 (reader-coordinator-arguments
                  guile private-coordinator koreader qemu run-root
                  kernel initrd append-line overlay))))
            (module-set! %outer-module 'validate-completed-guest-console
                         validate-reader-completion))
          (lambda ()
            (parameterize ((current-output-port captured))
              (set! status (disposable-qemu-main base-argv))))
          (lambda ()
            (module-set! %outer-module 'qemu-argv accepted-qemu-argv)
            (module-set! %outer-module 'validate-completed-guest-console
                         accepted-validator)))
        ;; The inherited root guardian has completed before the base entry
        ;; returns.  Do not remove anything here: absence proves its full
        ;; identity-safe cleanup, while either the original or a replacement
        ;; being present is a failed reader disposition.  In particular, a
        ;; same-UID foreign replacement is preserved rather than recursively
        ;; traversed by this wrapper.
        (when observed-run-root
          (let ((current ((outer-private 'lstat-or-false) observed-run-root)))
            (when current
              (if ((outer-private 'same-identity?)
                   observed-run-identity current)
                  (reader-error
                   "reader run root remained after guardian cleanup: ~a"
                   observed-run-root)
                  (reader-error
                   "reader run root was replaced; foreign root preserved: ~a"
                   observed-run-root)))))
        (when (zero? status)
          (let ((inherited (get-output-string captured)))
            (unless (string=? inherited inherited-success-line)
              (reader-error "inherited outer success disposition changed"))
            (display joined-success-line)))
        status))))

(define (disposable-reader-qemu-main argv)
  (catch #t
    (lambda () (run-reader argv))
    (lambda (key . arguments)
      (cond
       ((eq? key 'book-execution-qemu-signal)
        (let ((signal-number (car arguments)))
          (format (current-error-port)
                  "FAIL: received signal ~a; owned reader coordinator group cleaned~%"
                  signal-number)
          (+ 128 signal-number)))
       ((eq? key 'book-execution-qemu-error)
        (format (current-error-port) "FAIL: ~a~%" (car arguments))
        1)
       (else
        (format (current-error-port) "FAIL: ~s ~s~%" key arguments)
        1)))))
