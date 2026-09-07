;;; Host-side serial assertion chain for the fixed actual-guest protocol gate.
;;; This parses trusted control markers only; Book Protocol never uses serial.
(define-module (protocol-console-assertions)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (assert-protocol-guest-console
            assert-protocol-guest-console-file
            protocol-guest-required-markers))

(define max-console-bytes (* 16 1024 1024))

(define protocol-guest-required-markers
  '("BOOKEXEC-PROTOCOL-SOURCE-PROVENANCE-PASS"
    "BOOKEXEC-KERNEL-IDENTITY-PASS"
    "BOOKEXEC-NETWORK-ABSENT-PASS"
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS"
    "BOOKEXEC-RUNSC-VERSION-PASS"
    "BOOKEXEC-PROTOCOL-SCHEMA-REJECTION-PASS"
    "BOOKEXEC-PROTOCOL-STALE-REJECTION-PASS"
    "BOOKEXEC-PROTOCOL-TRUNCATED-CLOSE-PASS"
    "BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS"
    "BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS"
    "BOOKEXEC-PROTOCOL-CGROUP-TEARDOWN-PASS"
    "BOOKEXEC-PROTOCOL-PASS"))

(define forbidden-fragments
  '("BOOKEXEC-PROTOCOL-FAIL"
    "BOOKEXEC-PROTOCOL-FD-HOST-TEST"
    "BOOKEXEC-PROTOCOL-AUTHORITY-HOST-TEST"
    "BOOKEXEC-PROTOCOL-PROVENANCE-HOST-TEST"
    "BOOKEXEC-SMOKE-FAIL"
    "BOOKEXEC-SMOKE-PASS"
    "BOOKEXEC-PAYLOAD-PYTHON"
    "BOOKEXEC-PAYLOAD-GUILE"
    "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW"
    "BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW"
    "BOOKEXEC-DIAGNOSTIC-STORE state=unavailable"
    "BOOKEXEC-DIAGNOSTIC-RUNSC state=unavailable"
    "Kernel panic"
    "BUG:"
    "Oops:"))

(define (assertion-error message)
  (throw 'book-execution-protocol-console-error message))

(define (normalized-lines text)
  (map (lambda (line) (string-trim-right line #\return))
       (string-split text #\newline)))

(define (exact-line-indexes lines expected)
  (filter-map (lambda (line index)
                (and (string=? line expected) index))
              lines (iota (length lines))))

(define (one-line-index lines expected)
  (let ((indexes (exact-line-indexes lines expected)))
    (unless (= (length indexes) 1)
      (assertion-error
       (format #f "expected exactly one serial marker ~s, observed ~a"
               expected (length indexes))))
    (car indexes)))

(define (prefix-indexes lines prefix)
  (filter-map (lambda (line index)
                (and (string-prefix? prefix line) index))
              lines (iota (length lines))))

(define (strictly-increasing? numbers)
  (or (null? numbers)
      (null? (cdr numbers))
      (and (< (car numbers) (cadr numbers))
           (strictly-increasing? (cdr numbers)))))

(define (store-summary-valid? line label file-limit capacity)
  (and (string-prefix?
        (string-append "BOOKEXEC-DIAGNOSTIC-STORE label=" label " ") line)
       (string-contains line (string-append "file-limit=" file-limit " "))
       (string-contains line (string-append "capacity-bytes=" capacity " "))
       (string-suffix? "overflow=#f" line)))

(define (assert-protocol-guest-console text)
  (unless (string? text)
    (assertion-error "guest console must be a string"))
  (when (> (bytevector-length (string->utf8 text)) max-console-bytes)
    (assertion-error "guest console exceeds the 16 MiB assertion bound"))
  (for-each
   (lambda (fragment)
     (when (string-contains text fragment)
       (assertion-error
        (string-append "forbidden guest console fragment: " fragment))))
   forbidden-fragments)
  (let* ((lines (normalized-lines text))
         (marker-indexes
          (map (lambda (marker) (one-line-index lines marker))
               protocol-guest-required-markers))
         (debug-indexes
          (prefix-indexes lines "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug "))
         (panic-indexes
          (prefix-indexes lines "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic "))
         (guile-index (one-line-index lines
                                     "BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS"))
         (python-index (one-line-index lines
                                      "BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS")))
    (unless (strictly-increasing? marker-indexes)
      (assertion-error "protocol guest markers are out of order"))
    (unless (and (= (length debug-indexes) 2)
                 (= (length panic-indexes) 2)
                 (every (lambda (index)
                          (store-summary-valid?
                           (list-ref lines index) "runsc-debug" "10" "4194304"))
                        debug-indexes)
                 (every (lambda (index)
                          (store-summary-valid?
                           (list-ref lines index) "runsc-panic" "2" "1048576"))
                        panic-indexes)
                 (< (car debug-indexes) (car panic-indexes) guile-index)
                 (< guile-index
                    (cadr debug-indexes) (cadr panic-indexes) python-index))
      (assertion-error
       "each language PASS must follow its bounded debug/panic store summaries"))
    #t))

(define (assert-protocol-guest-console-file path)
  (let ((info (stat path)))
    (unless (eq? (stat:type info) 'regular)
      (assertion-error "guest console path is not a regular file"))
    (when (> (stat:size info) max-console-bytes)
      (assertion-error "guest console file exceeds the 16 MiB assertion bound")))
  (assert-protocol-guest-console
   (call-with-input-file path get-string-all)))
