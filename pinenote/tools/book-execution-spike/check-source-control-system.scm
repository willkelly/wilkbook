;;; Static comparison of the accepted v5 system and local-artifact control OS.
(use-modules (gnu services)
             (gnu system)
             (guix packages)
             (pinenote packages gvisor)
             (pinenote packages gvisor-local-test-artifacts)
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
(define base-packages (operating-system-packages base))
(define control-packages (operating-system-packages control))
(define base-services (operating-system-user-services base))
(define control-services (operating-system-user-services control))

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
   base-packages control-packages))

(define service-differences
  (filter-map
   (lambda (old new)
     (and (not (eq? old new)) (list old new)))
   base-services control-services))

(check "control inherits the exact accepted USER_NS kernel object"
       (eq? (operating-system-kernel base)
            (operating-system-kernel control)))
(check "control package list has unchanged length"
       (= (length base-packages) (length control-packages)))
(check "only one package-list position changes"
       (= (length package-differences) 1))
(check "the sole package delta is frozen gvisor-bin to v12 control artifact"
       (and (eq? (caar package-differences) gvisor-bin)
            (eq? (cadar package-differences)
                 gvisor-v12-control-local-test-artifact)))
(check "diagnostic artifact is not selected by the control system"
       (not (memq gvisor-v12-diagnostic-local-test-artifact
                  control-packages)))
(check "service list names and order are unchanged"
       (equal? (map service-name base-services)
               (map service-name control-services)))
(check "only the one manifest service object changes"
       (and (= (length service-differences) 1)
            (manifest-service? (caar service-differences))
            (manifest-service? (cadar service-differences))))
(let* ((old-service (find manifest-service? base-services))
       (new-service (find manifest-service? control-services))
       (old-value (service-value old-service))
       (new-value (service-value new-service)))
  (check "manifest service retains exactly four /etc entries"
         (and (= (length old-value) 4) (= (length new-value) 4)))
  (check "only the build-manifest /etc value changes"
         (equal? (remove-manifest-entry old-value)
                 (remove-manifest-entry new-value))))
(check "file systems, including cgroup2, are unchanged"
       (equal? (operating-system-file-systems base)
               (operating-system-file-systems control)))
(check "kernel arguments are unchanged"
       (equal? (operating-system-user-kernel-arguments base)
               (operating-system-user-kernel-arguments control)))
(check "initrd constructor is unchanged"
       (eq? (operating-system-initrd base)
            (operating-system-initrd control)))
