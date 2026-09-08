;;; Static comparison of source-built control and diagnostic image definitions.
(use-modules (gnu services)
             (gnu system)
             (pinenote packages gvisor-local-test-artifacts)
             (pinenote systems pinenote-book-execution-diagnostic)
             (pinenote systems pinenote-book-execution-source-control)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define control pinenote-book-execution-source-control-operating-system)
(define diagnostic pinenote-book-execution-diagnostic-operating-system)
(define control-packages (operating-system-packages control))
(define diagnostic-packages (operating-system-packages diagnostic))
(define control-services (operating-system-user-services control))
(define diagnostic-services (operating-system-user-services diagnostic))

(define (service-name item)
  (service-type-name (service-kind item)))

(define (manifest-service? item)
  (eq? (service-name item) 'book-execution-language-profile))

(define (remove-manifest-entry entries)
  (remove (lambda (entry)
            (string=? (car entry)
                      "wilkbook-execution-spike/build-manifest"))
          entries))

(define package-differences
  (filter-map
   (lambda (old new)
     (and (not (eq? old new)) (list old new)))
   control-packages diagnostic-packages))

(define service-differences
  (filter-map
   (lambda (old new)
     (and (not (eq? old new)) (list old new)))
   control-services diagnostic-services))

(check "diagnostic inherits the exact accepted USER_NS kernel object"
       (eq? (operating-system-kernel control)
            (operating-system-kernel diagnostic)))
(check "diagnostic package list has unchanged length"
       (= (length control-packages) (length diagnostic-packages)))
(check "only one package-list position changes from control"
       (= (length package-differences) 1))
(check "the sole package delta is complete control to complete diagnostic"
       (and
        (eq? (caar package-differences)
             gvisor-v12-control-local-test-artifact)
        (eq? (cadar package-differences)
             gvisor-v12-diagnostic-local-test-artifact)))
(check "control artifact is not retained by the diagnostic system"
       (not (memq gvisor-v12-control-local-test-artifact
                  diagnostic-packages)))
(check "service list names and order are unchanged"
       (equal? (map service-name control-services)
               (map service-name diagnostic-services)))
(check "only the one provenance-manifest service object changes"
       (and (= (length service-differences) 1)
            (manifest-service? (caar service-differences))
            (manifest-service? (cadar service-differences))))
(let* ((old-service (find manifest-service? control-services))
       (new-service (find manifest-service? diagnostic-services))
       (old-value (service-value old-service))
       (new-value (service-value new-service)))
  (check "manifest service retains exactly four /etc entries"
         (and (= (length old-value) 4) (= (length new-value) 4)))
  (check "only the build-manifest /etc value changes"
         (equal? (remove-manifest-entry old-value)
                 (remove-manifest-entry new-value))))
(check "file systems, including cgroup2, are unchanged"
       (equal? (operating-system-file-systems control)
               (operating-system-file-systems diagnostic)))
(check "kernel arguments are unchanged"
       (equal? (operating-system-user-kernel-arguments control)
               (operating-system-user-kernel-arguments diagnostic)))
(check "initrd constructor is unchanged"
       (eq? (operating-system-initrd control)
            (operating-system-initrd diagnostic)))
