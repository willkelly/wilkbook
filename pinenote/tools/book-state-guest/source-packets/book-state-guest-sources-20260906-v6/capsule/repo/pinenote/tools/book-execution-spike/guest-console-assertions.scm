;;; Parse the automatic guest's serial log after QEMU exits.
;;; Control-plane evidence only; this is not a Book Protocol transport.
(define-module (guest-console-assertions)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (assert-guest-console
            assert-guest-console-file
            guest-console-assertions-main
            required-guest-markers))

(define max-console-bytes (* 16 1024 1024))

(define required-guest-markers
  '("BOOKEXEC-KERNEL-IDENTITY-PASS"
    "BOOKEXEC-NETWORK-ABSENT-PASS"
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS"
    "BOOKEXEC-RUNSC-VERSION-PASS"
    "BOOKEXEC-PYTHON-SYSTRAP-PASS"
    "BOOKEXEC-GUILE-SYSTRAP-PASS"
    "BOOKEXEC-CGROUP-TEARDOWN-PASS"
    "BOOKEXEC-SMOKE-PASS"))

(define forbidden-console-fragments
  '("BOOKEXEC-SMOKE-FAIL"
    "Kernel panic"
    "BUG:"
    "Oops:"))

(define (assertion-error message)
  (throw 'book-execution-guest-assertion-error message))

(define (normalize-line line)
  (string-trim-right line #\return))

(define (marker-index lines marker)
  (let ((indexes
         (filter-map (lambda (line index)
                       (and (string=? line marker) index))
                     lines
                     (iota (length lines)))))
    (unless (= (length indexes) 1)
      (assertion-error
       (format #f "expected exactly one serial marker ~s, observed ~a"
               marker (length indexes))))
    (car indexes)))

(define (assert-guest-console text)
  (for-each
   (lambda (fragment)
     (when (string-contains text fragment)
       (assertion-error
        (string-append "forbidden serial fragment: " fragment))))
   forbidden-console-fragments)
  (let* ((lines (map normalize-line (string-split text #\newline)))
         (indexes (map (lambda (marker) (marker-index lines marker))
                       required-guest-markers)))
    (unless (every < indexes (cdr indexes))
      (assertion-error "required guest markers are out of order"))
    (unless (any (lambda (line) (string-contains line "reboot: Power down"))
                 lines)
      (assertion-error "serial log lacks clean kernel power-down")))
  #t)

(define (read-console path)
  (let ((info (lstat path)))
    (unless (eq? (stat:type info) 'regular)
      (assertion-error "console input is not a regular file"))
    (when (> (stat:size info) max-console-bytes)
      (assertion-error "console input exceeds the 16 MiB evidence bound"))
    (call-with-input-file path
      (lambda (port)
        ;; Kernel serial output is byte-oriented.  Latin-1 makes every byte
        ;; readable while all asserted markers remain exact ASCII.
        (set-port-encoding! port "ISO-8859-1")
        ;; Read one byte beyond the independent checker limit rather than
        ;; trusting stat size or using an unbounded whole-port read.
        (let ((value (get-string-n port (+ max-console-bytes 1))))
          (if (eof-object? value)
              ""
              (begin
                (when (> (string-length value) max-console-bytes)
                  (assertion-error
                   "console input exceeds the 16 MiB evidence bound"))
                value)))))))

(define (assert-guest-console-file path)
  (assert-guest-console (read-console path)))

(define (guest-console-assertions-main argv)
  (catch 'book-execution-guest-assertion-error
    (lambda ()
      (match (cdr argv)
        ((path)
         (assert-guest-console-file path)
         (display "PASS: ordered book-execution guest markers and clean power-down\n")
         0)
        (_
         (format (current-error-port) "usage: ~a CONSOLE-LOG\n" (car argv))
         2)))
    (lambda (key message)
      (format (current-error-port) "FAIL: ~a\n" message)
      1)))
