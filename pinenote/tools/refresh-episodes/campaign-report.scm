;;; Complete QEMU log capture validation and checked analysis (Guile 3).
;;; Run: guile --no-auto-compile -e main -s campaign-report.scm HARVEST OUT LEDGER
;;; The Python analysers remain legacy code; see README.md for the migration gate.
(use-modules (ice-9 rdelim) (ice-9 regex) (ice-9 popen)
             (ice-9 textual-ports) (ice-9 format) (srfi srfi-1) (srfi srfi-13))

(define (checked-command command output)
  ;; No pipeline: a failing analyser must not become tee's successful exit.
  (let ((status (with-output-to-file output
                  (lambda ()
                    (with-error-to-port (current-output-port)
                      (lambda () (apply system* command)))))))
    (unless (zero? status)
      (error "command failed; see output" command status output))))

(define (sha256 path)
  (let* ((p (open-pipe* OPEN_READ "sha256sum" path))
         (line (read-line p))
         (status (close-pipe p)))
    (unless (and (zero? status) (string? line) (>= (string-length line) 64))
      (error "sha256sum failed" path))
    (substring line 0 64)))

(define (unique-value lines prefix)
  (let ((matches (filter (lambda (s) (string-prefix? prefix s)) lines)))
    (unless (= 1 (length matches))
      (error "missing or duplicate capture metadata" prefix))
    (substring (car matches) (string-length prefix))))

(define (clock-number lines prefix)
  (let* ((value (unique-value lines prefix))
         (n (and (string-match "^[0-9]+([.][0-9]+)?$" value) (string->number value))))
    (unless (and n (real? n) (finite? n) (>= n 0))
      (error "invalid capture clock" prefix))
    (exact->inexact n)))

(define (validate-harvest capture out)
  ;; Transport is base64, so terminal CRLF processing, UTF-8 chunk boundaries,
  ;; control bytes and a non-newline-terminated source cannot alter the log.
  ;; Both metadata and payload describe ONE guest-side snapshot, not the live
  ;; file sampled twice while the reader may still be appending to it.
  (let* ((lines (call-with-input-file capture
                  (lambda (p)
                    (let loop ((acc '()))
                      (let ((s (read-line p)))
                        (if (eof-object? s) (reverse acc)
                            (loop (cons (string-trim-right s #\return) acc))))))))
         (meta (string-tokenize (unique-value lines "WBCAMP-LOGSTAT ")))
         (size (and (= (length meta) 2) (string->number (car meta))))
         (hash (and size (cadr meta)))
         (guest (clock-number lines "WBCAMP-GUESTCLOCK "))
         (before (clock-number lines "WBCAMP-HOSTBEFORE WBCAMP-GUESTCLOCK "))
         (after (clock-number lines "WBCAMP-HOSTAT WBCAMP-GUESTCLOCK "))
         (encoded (string-append out "/reader-session.base64"))
         (partial (string-append out "/reader-session.log.partial"))
         (log (string-append out "/reader-session.log")))
    (unless (and size (integer? size) (> size 0)
                 (string-match "^[0-9a-f]{64}$" hash))
      (error "invalid or empty guest log snapshot" meta))
    (unless (<= before after) (error "host clock moved backwards during sample"))
    (call-with-output-file encoded
      (lambda (p)
        (let loop ((rest lines) (state 'before))
          (if (null? rest)
              (unless (eq? state 'after) (error "missing/incomplete log harvest"))
              (let ((s (car rest)))
                (cond
                 ((string=? s "WBCAMP-LOG-BEGIN")
                  (unless (eq? state 'before) (error "duplicate/out-of-order log begin"))
                  (loop (cdr rest) 'body))
                 ((string=? s "WBCAMP-LOG-END")
                  (unless (eq? state 'body) (error "out-of-order log end"))
                  (loop (cdr rest) 'after))
                 ((eq? state 'body)
                  (unless (string-match "^[A-Za-z0-9+/]+={0,2}$" s)
                    (error "non-base64 data inside log harvest" s))
                  (display s p) (newline p) (loop (cdr rest) state))
                 (else (loop (cdr rest) state))))))))
    (checked-command (list "base64" "--decode" encoded) partial)
    (unless (= size (stat:size (stat partial)))
      (error "incomplete log harvest: byte count mismatch" size))
    (unless (string=? hash (sha256 partial))
      (error "corrupt log harvest: SHA-256 mismatch"))
    (rename-file partial log)
    ;; The guest date executed between these host samples. This bounds only
    ;; this exchange, assuming neither wall clock steps; campaign drift and
    ;; input delivery/handling delay remain unmeasured.
    (let ((offset (- guest after)) (uncertainty (- after before)))
      (call-with-output-file (string-append out "/capture-validation.txt")
        (lambda (p)
          (format p "Complete snapshot: ~a bytes; SHA-256 ~a~%" size hash)
          (format p "Guest-minus-host offset interval at harvest: [~,6f, ~,6f] s~%"
                  offset (+ offset uncertainty))
          (display "Clock interval assumes no wall-clock steps; campaign drift is unmeasured.\n" p)
          (display "Ledger timestamps are host command times, not guest input/gesture times.\n" p)
          (display "Completeness covers the current log snapshot, not rotated history or untraced notebook publishing.\n" p)))
      (list log offset uncertainty))))

(define* (report-campaign capture out ledger tools #:key (python '("python3")))
  ;; Avoid mistaking stale successful output for this run after validation fails.
  (for-each (lambda (name)
              (let ((path (string-append out "/" name)))
                (when (file-exists? path) (delete-file path))))
            '("reader-session.log" "capture-validation.txt" "episodes.txt"
              "episodes.json" "triggers.txt" "triggers.json"))
  (let* ((validated (validate-harvest capture out))
         (log (car validated))
         (clock-args (list "--ledger" ledger "--clock-offset"
                           (number->string (cadr validated))
                           "--clock-uncertainty"
                           (number->string (caddr validated)))))
    (for-each
     (lambda (kind)
       (checked-command
        (append python (list (string-append tools "/refresh-" kind ".py") log)
                (if (string=? kind "episodes") clock-args '())
                (list "--json" (string-append out "/" kind ".json")))
        (string-append out "/" kind ".txt")))
     '("episodes" "triggers"))))

(define (main args)
  (unless (= (length args) 4)
    (format (current-error-port) "usage: campaign-report.scm HARVEST OUT LEDGER~%")
    (exit 2))
  (catch #t
    (lambda ()
      (report-campaign (cadr args) (caddr args) (cadddr args)
                       (dirname (canonicalize-path (car args))))
      (display "Capture validation and both analyses: OK\n"))
    (lambda (key . details)
      (format (current-error-port) "FAIL: capture/report: ~a ~s~%" key details)
      (exit 1))))
