;;; Host-side serial assertion chain for the reader-driven guest protocol gate.
;;; Console markers report trusted guest semantics and cleanup; private UI and
;;; Book Protocol values never use this channel.
(define-module (reader-protocol-console-assertions)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (assert-reader-protocol-console
            assert-reader-protocol-console-file
            reader-protocol-required-markers))

(define max-console-bytes (* 16 1024 1024))

(define reader-protocol-required-markers
  '("BOOKEXEC-READER-PROTOCOL-SOURCE-PROVENANCE-PASS"
    "BOOKEXEC-KERNEL-IDENTITY-PASS"
    "BOOKEXEC-NETWORK-ABSENT-PASS"
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS"
    "BOOKEXEC-RUNSC-VERSION-PASS"
    "BOOKEXEC-READER-PROTOCOL-SCHEMA-REJECTION-PASS"
    "BOOKEXEC-READER-PROTOCOL-STALE-REJECTION-PASS"
    "BOOKEXEC-READER-PROTOCOL-TRUNCATED-CLOSE-PASS"
    "BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS"
    "BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS"
    "BOOKEXEC-READER-PROTOCOL-CGROUP-TEARDOWN-PASS"
    "BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS"
    "BOOKEXEC-READER-PROTOCOL-PASS"))

(define forbidden-fragments
  '("BOOKEXEC-READER-PROTOCOL-FAIL"
    "BOOKEXEC-READER-PROTOCOL-HOST-TEST"
    "BOOKEXEC-PROTOCOL-PASS"
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
  (throw 'book-execution-reader-protocol-console-error message))

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

(define power-down-timestamp-regexp
  (make-regexp
   "^\\[( *)(0|[1-9][0-9]*)\\.([0-9]{6})\\] reboot: Power down$"))

(define (power-down-line? line)
  ;; Linux may prepend its canonical printk timestamp.  Match that one field
  ;; structurally rather than stripping arbitrary prefixes from any marker.
  (or (string=? line "reboot: Power down")
      (let ((match (regexp-exec power-down-timestamp-regexp line)))
        (and match
             (let ((padding (match:substring match 1))
                   (seconds (match:substring match 2)))
               ;; printk's seconds field is space-padded to width five and
               ;; naturally grows beyond five digits without leading zeroes.
               (= (+ (string-length padding) (string-length seconds))
                  (max 5 (string-length seconds))))))))

(define (one-power-down-line-index lines)
  (let ((indexes
         (filter-map (lambda (line index)
                       (and (power-down-line? line) index))
                     lines (iota (length lines)))))
    (unless (= (length indexes) 1)
      (assertion-error
       (format #f "expected exactly one canonical reboot: Power down line, observed ~a"
               (length indexes))))
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

(define (canonical-decimal value)
  (and (string? value)
       (or (string=? value "0")
           (and (char-numeric? (string-ref value 0))
                (not (char=? (string-ref value 0) #\0))
                (every char-numeric? (string->list value))))
       (string->number value 10)))

(define (store-summary-match line label file-limit capacity)
  (regexp-exec
   (make-regexp
    (string-append
     "^BOOKEXEC-DIAGNOSTIC-STORE label=" label
     " entries=(0|[1-9][0-9]*) file-limit=" file-limit
     " source-bytes=(0|[1-9][0-9]*)"
     " allocated-bytes=(0|[1-9][0-9]*) capacity-bytes=" capacity
     " invalid-entry=#f byte-exhausted=#f inode-exhausted=#f overflow=#f$"))
   line))

(define (store-summary-valid? line label file-limit capacity)
  (let ((match (store-summary-match line label file-limit capacity)))
    (and match
         (let ((entries (canonical-decimal (match:substring match 1)))
               (source (canonical-decimal (match:substring match 2)))
               (allocated (canonical-decimal (match:substring match 3)))
               (limit (string->number file-limit 10))
               (maximum (string->number capacity 10)))
           (and entries source allocated
                (<= entries limit)
                (<= source allocated)
                (<= allocated maximum))))))

(define (assert-reader-protocol-console text)
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
               reader-protocol-required-markers))
         (debug-indexes
          (prefix-indexes lines
                          "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug "))
         (panic-indexes
          (prefix-indexes lines
                          "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic "))
         (all-store-indexes
          (prefix-indexes lines "BOOKEXEC-DIAGNOSTIC-STORE label="))
         (guile-index
          (one-line-index
           lines "BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS"))
         (python-index
          (one-line-index
           lines "BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS"))
         (final-index
          (one-line-index lines "BOOKEXEC-READER-PROTOCOL-PASS"))
         (power-down-index (one-power-down-line-index lines)))
    (unless (strictly-increasing? marker-indexes)
      (assertion-error "reader protocol guest markers are out of order"))
    (unless (and (= (length all-store-indexes) 4)
                 (= (length debug-indexes) 2)
                 (= (length panic-indexes) 2)
                 (every (lambda (index)
                          (store-summary-valid?
                           (list-ref lines index)
                           "runsc-debug" "10" "4194304"))
                        debug-indexes)
                 (every (lambda (index)
                          (store-summary-valid?
                           (list-ref lines index)
                           "runsc-panic" "2" "1048576"))
                        panic-indexes)
                 (< (car debug-indexes) (car panic-indexes) guile-index)
                 (< guile-index
                    (cadr debug-indexes) (cadr panic-indexes) python-index))
      (assertion-error
       "each reader language PASS must follow its exact bounded runsc-debug/runsc-panic summaries"))
    (unless (< final-index power-down-index)
      (assertion-error "clean power-down did not follow reader protocol PASS"))
    #t))

(define (assert-reader-protocol-console-file path)
  (let ((info (stat path)))
    (unless (eq? (stat:type info) 'regular)
      (assertion-error "guest console path is not a regular file"))
    (when (> (stat:size info) max-console-bytes)
      (assertion-error "guest console file exceeds the 16 MiB assertion bound")))
  (assert-reader-protocol-console
   (call-with-input-file path get-string-all)))
