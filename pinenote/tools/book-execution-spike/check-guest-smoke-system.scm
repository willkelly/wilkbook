;;; Static, non-realizing checks for the automatic in-guest smoke service.
(use-modules (gnu services)
              (gnu services base)
              (gnu services shepherd)
              (gnu system)
             (gnu system file-systems)
             (guix packages)
             (pinenote systems pinenote-book-execution-spike)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define os pinenote-book-execution-spike-operating-system)
(define service-names
  (map (lambda (item) (service-type-name (service-kind item)))
       (operating-system-user-services os)))
(define package-names
  (filter-map (lambda (item) (and (package? item) (package-name item)))
              (operating-system-packages os)))
(define store-file-systems
  (filter (lambda (file-system)
            (string=? (file-system-mount-point file-system) "/gnu/store"))
          (operating-system-file-systems os)))
(define expected-runtime-release
  (@@ (pinenote systems pinenote-book-execution-spike)
       %book-execution-kernel-release))
(define smoke-shepherd-service
  (car
   ((@@ (pinenote systems pinenote-book-execution-spike)
        book-execution-guest-smoke-shepherd-service)
    #f)))

(check "exact non-shipping PineNote USER_NS kernel remains selected"
       (string=?
        (package-name (operating-system-kernel os))
        "linux-pinenote-book-execution-test"))
(check "automatic guest smoke Shepherd service is present once"
       (= 1 (count (lambda (name) (eq? name 'book-execution-guest-smoke))
                     service-names)))
(check "guest smoke is a supervised non-one-shot non-respawning service"
       (and (not (shepherd-service-one-shot? smoke-shepherd-service))
            (not (shepherd-service-respawn? smoke-shepherd-service))))
(check "headless smoke image has no serial agetty service"
       (not (memq 'agetty service-names)))
(check "the image has no Guix daemon service"
       (not (memq 'guix service-names)))
(check "the image includes the complete gVisor package"
       (member "gvisor-bin" package-names))
(check "guest uname assertion matches the built module release"
       (string=? expected-runtime-release "7.1.8"))
(check "one cgroup2 hierarchy is declared"
       (= 1
          (count
           (lambda (file-system)
             (and (string=? (file-system-mount-point file-system)
                            "/sys/fs/cgroup")
                  (string=? (file-system-type file-system) "cgroup2")))
            (operating-system-file-systems os))))
(check "pinned Guix declares only its read-only store self-bind"
       (and (= 1 (length store-file-systems))
            (let ((store (car store-file-systems)))
              (and (string=? (file-system-device store) "/gnu/store")
                   (string=? (file-system-type store) "none")
                   (every (lambda (flag)
                            (memq flag (file-system-flags store)))
                          '(read-only bind-mount no-atime))))))
(check "hardware console remains for fixed log/marker output without a getty"
       (and (member "console=ttyS2,1500000n8"
                    (operating-system-user-kernel-arguments os))
            (not (member "console=ttyAMA0"
                         (operating-system-user-kernel-arguments os)))))
