;;; Static, non-realizing checks for the non-shipping execution-spike system.
(use-modules (gnu system)
             (gnu system file-systems)
             (guix packages)
             (guix profiles)
             (pinenote systems pinenote-book-execution-spike)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define os pinenote-book-execution-spike-operating-system)
(define kernel
  (@@ (pinenote systems pinenote-book-execution-spike)
      linux-pinenote-book-execution-test))
(define language-profile
  (@@ (pinenote systems pinenote-book-execution-spike)
      %book-execution-language-profile))
(define supervisor-profile
  (@@ (pinenote systems pinenote-book-execution-spike)
      %book-execution-supervisor-profile))

(define (profile-names profile)
  (map manifest-entry-name (manifest-entries (profile-content profile))))

(check "OS selects the non-shipping USER_NS test-kernel variant"
       (string=? (package-name (operating-system-kernel os))
                 "linux-pinenote-book-execution-test"))
(check "kernel variant retains an explicit USER_NS configure delta"
       (string-contains (object->string (package-arguments kernel)) "USER_NS"))
(check "system declares one cgroup2 mount at /sys/fs/cgroup"
       (= 1
          (count
           (lambda (file-system)
             (and (string=? (file-system-mount-point file-system)
                            "/sys/fs/cgroup")
                  (string=? (file-system-type file-system) "cgroup2")))
           (operating-system-file-systems os))))
(check "sandbox language profile is exactly Guile/guile-json/Python"
       (equal? (profile-names language-profile)
               '("guile" "guile-json" "python")))
(check "trusted supervisor profile excludes Python"
       (equal? (profile-names supervisor-profile)
               '("guile" "guile-json")))
