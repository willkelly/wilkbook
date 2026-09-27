#!/usr/bin/env -S guile --no-auto-compile -s
!#
(use-modules (pinenote lib data-device) (srfi srfi-64))

;; Caller supplies a fresh temporary directory; nothing under real sysfs or
;; /dev is written or mounted. Fixture directories stand in for block nodes.
(define root (cadr (command-line)))
(define (event name text)
  (let ((dir (string-append root "/" name)))
    (unless (file-exists? dir) (mkdir dir))
    (call-with-output-file (string-append dir "/uevent")
      (lambda (p) (display text p)))))
(define valid "DEVNAME=vda3\nDEVTYPE=partition\nPARTNAME=data\n")
(test-begin "data-device")
(define runner (test-runner-current))
(test-equal "empty kernel inventory" '() (data-device-candidates root))
(event "vda1" "DEVNAME=vda1\nDEVTYPE=partition\nPARTNAME=os1\n")
(event "vda2" "DEVNAME=vda2\nDEVTYPE=partition\nPARTNAME=data-backup\n")
(test-equal "exact partition name" '() (data-device-candidates root))
(event "vda3" valid)
(test-equal "no blkid or udev link needed" '("vda3") (data-device-candidates root))
(test-equal "returns kernel node"
  "/dev/vda3" (resolve-data-device #:sys root #:attempts 1 #:block? (const #t)))
(test-assert "does not accept regular files or directories as block devices"
  (not (resolve-data-device #:sys root #:dev root #:attempts 1)))
(define waits 0)
(test-equal "waits for node appearance" "/dev/vda3"
  (resolve-data-device #:sys root #:attempts 3
                       #:block? (lambda (_) (= waits 2))
                       #:pause (lambda (_) (set! waits (+ waits 1)))))
(set! waits 0)
(test-assert "missing node has bounded wait"
  (not (resolve-data-device #:sys root #:attempts 3 #:block? (const #f)
                            #:pause (lambda (_) (set! waits (+ waits 1))))))
(test-equal "three attempts mean two sleeps" 2 waits)
(event "vda3" "DEVNAME=other\nDEVTYPE=partition\nPARTNAME=data\n")
(test-equal "refuses inconsistent kernel basename" '() (data-device-candidates root))
(event "vda3" "DEVNAME=vda3\nDEVTYPE=disk\nPARTNAME=data\n")
(test-equal "refuses whole disk" '() (data-device-candidates root))
(event "vda3" valid)
(event "vdb3" "DEVNAME=vdb3\nDEVTYPE=partition\nPARTNAME=data\n")
(test-error "duplicate partition labels never select an arbitrary device" #t
  (resolve-data-device #:sys root #:attempts 1 #:block? (const #t)))
(test-end "data-device")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
