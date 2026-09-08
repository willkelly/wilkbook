;;; Static package/object checks for current public Book-execution systems.
(use-modules (gnu system)
             (guix packages)
             (pinenote packages gvisor)
             (pinenote packages gvisor-source)
             (pinenote systems pinenote-book-execution-diagnostic)
             (pinenote systems pinenote-book-execution-protocol-control)
             (pinenote systems pinenote-book-execution-reader-interaction)
             (pinenote systems pinenote-book-execution-source-control)
             (pinenote systems pinenote-book-execution-spike)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define base pinenote-book-execution-spike-operating-system)
(define control pinenote-book-execution-source-control-operating-system)
(define diagnostic pinenote-book-execution-diagnostic-operating-system)
(define protocol pinenote-book-execution-protocol-control-operating-system)
(define reader pinenote-book-execution-reader-interaction-operating-system)

(define (selected-once? package system)
  (= 1 (count (lambda (item) (eq? item package))
              (operating-system-packages system))))

(define (not-selected? package system)
  (not (memq package (operating-system-packages system))))

(check "default source package public name"
       (string=? (package-name gvisor/source) "gvisor-source-built"))
(check "diagnostic source package public name"
       (string=? (package-name gvisor/source-diagnostic)
                 "gvisor-source-built-diagnostic"))
(check "source package versions match the pinned release"
       (and (string=? (package-version gvisor/source) "20260831.0")
            (string=? (package-version gvisor/source-diagnostic) "20260831.0")))
(check "source package keeps the accepted x86_64 build-host boundary"
       (equal? (package-supported-systems gvisor/source) '("x86_64-linux")))
(check "default package uses the pristine fixed origin object"
       (eq? (package-source gvisor/source) gvisor-source-origin))
(check "default fixed origin has no diagnostic patch"
       (null? (origin-patches (package-source gvisor/source))))
(check "diagnostic package has exactly the explicit reviewed source patch"
       (let ((patches (origin-patches (package-source gvisor/source-diagnostic))))
         (and (= (length patches) 1)
              (eq? (car patches)
                   (@@ (pinenote packages gvisor-source)
                       %gvisor-diagnostic-error-report-patch)))))

(check "historical base remains the official binary spike"
       (and (selected-once? gvisor-bin base)
            (not-selected? gvisor/source base)
            (not-selected? gvisor/source-diagnostic base)))
(for-each
 (lambda (entry)
   (let ((name (car entry)) (system (cdr entry)))
     (check (format #f "~a selects one unpatched source runtime" name)
            (selected-once? gvisor/source system))
     (check (format #f "~a excludes diagnostic runtime" name)
            (not-selected? gvisor/source-diagnostic system))
     (check (format #f "~a excludes official binary runtime" name)
            (not-selected? gvisor-bin system))))
 `((source-control . ,control)
   (protocol-control . ,protocol)
   (reader-interaction . ,reader)))
(check "diagnostic selects exactly one explicit patched source runtime"
       (selected-once? gvisor/source-diagnostic diagnostic))
(check "diagnostic excludes unpatched and official runtimes"
       (and (not-selected? gvisor/source diagnostic)
            (not-selected? gvisor-bin diagnostic)))

(define source-arguments (object->string (package-arguments gvisor/source)))
(for-each
 (lambda (member)
   (check (string-append "source runtime package names " member)
          (string-contains source-arguments member)))
 '("containerd-shim-runsc-v1"
   "gvisor-bin/checkpointgofer"
   "gvisor-bin/gvisor-sentry-prewarmer"
   "gvisor-bin/gvisor_sentry"
   "gvisor-bin/runsc-metric-server"
   "runsc"))
(check "source runtime package does not depend on official gvisor-bin"
       (not (string-contains source-arguments "gvisor-aarch64.tar.zstd")))

(check "all current systems retain the same USER_NS test kernel object"
       (every (lambda (system)
                (eq? (operating-system-kernel control)
                     (operating-system-kernel system)))
              (list diagnostic protocol reader)))
