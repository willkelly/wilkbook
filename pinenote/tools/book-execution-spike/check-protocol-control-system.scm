;;; Static, non-realizing comparison for the proposed protocol-control OS.
(use-modules (gnu services)
             (gnu system)
             (guix packages)
             (guix profiles)
             (pinenote packages gvisor)
             (pinenote packages gvisor-local-test-artifacts)
             (pinenote systems pinenote-book-execution-protocol-control)
             (pinenote systems pinenote-book-execution-source-control)
             (pinenote systems pinenote-book-execution-spike)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define base pinenote-book-execution-source-control-operating-system)
(define protocol
  pinenote-book-execution-protocol-control-operating-system)
(define %protocol-module
  (resolve-module
   '(pinenote systems pinenote-book-execution-protocol-control)))
(define %spike-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (protocol-private name) (module-ref %protocol-module name))
(define (spike-private name) (module-ref %spike-module name))
(define (service-name item)
  (service-type-name (service-kind item)))
(define (service-named services name)
  (find (lambda (item) (eq? (service-name item) name)) services))
(define (manifest-names+versions profile)
  (sort (map (lambda (entry)
               (cons (manifest-entry-name entry)
                     (manifest-entry-version entry)))
             (manifest-entries (profile-content profile)))
        (lambda (left right) (string<? (car left) (car right)))))

(define base-services (operating-system-user-services base))
(define protocol-services (operating-system-user-services protocol))
(define base-names (map service-name base-services))
(define protocol-names (map service-name protocol-services))
(define base-etc
  (service-named base-services 'book-execution-language-profile))
(define protocol-etc
  (service-named protocol-services 'book-execution-language-profile))
(define protocol-supervisor
  (protocol-private '%book-protocol-supervisor-profile))
(define old-supervisor
  (spike-private '%book-execution-supervisor-profile))

(check "protocol system reuses the exact accepted USER_NS kernel object"
       (eq? (operating-system-kernel base)
            (operating-system-kernel protocol)))
(check "protocol system reuses the exact accepted package list"
       (equal? (operating-system-packages base)
               (operating-system-packages protocol)))
(check "accepted unpatched CONTROL artifact remains selected"
       (and (memq gvisor-v12-control-local-test-artifact
                  (operating-system-packages protocol))
            (not (memq gvisor-v12-diagnostic-local-test-artifact
                       (operating-system-packages protocol)))
            (not (memq gvisor-bin (operating-system-packages protocol)))))
(check "file systems including cgroup2 are unchanged"
       (equal? (operating-system-file-systems base)
               (operating-system-file-systems protocol)))
(check "kernel arguments are unchanged"
       (equal? (operating-system-user-kernel-arguments base)
               (operating-system-user-kernel-arguments protocol)))
(check "initrd constructor is unchanged"
       (eq? (operating-system-initrd base)
            (operating-system-initrd protocol)))

(check "service count is unchanged"
       (= (length base-services) (length protocol-services)))
(check "only the one-shot service name changes"
       (equal?
        (map (lambda (name)
               (if (eq? name 'book-execution-guest-smoke)
                   'book-execution-protocol-gate
                   name))
             base-names)
        protocol-names))
(check "old compatibility smoke service is absent"
       (not (memq 'book-execution-guest-smoke protocol-names)))
(check "fixed protocol gate service is present exactly once"
       (= 1 (count (lambda (name)
                     (eq? name 'book-execution-protocol-gate))
                   protocol-names)))

(let ((entries (service-value protocol-etc)))
  (check "protocol /etc manifest retains exactly four entries"
         (= (length entries) 4))
  (check "sandbox language profile is the exact accepted profile object"
         (eq? (cadr (assoc "wilkbook-execution-spike/profile" entries))
              (spike-private '%book-execution-language-profile)))
  (check "trusted supervisor profile alone is replaced"
         (eq? (cadr (assoc "wilkbook-execution-spike/supervisor-profile"
                           entries))
              protocol-supervisor))
  (check "old smoke book is not retained by the protocol system"
         (not (assoc "wilkbook-execution-spike/smoke-book" entries)))
  (check "protocol sources and build manifest are retained"
         (and (assoc "wilkbook-execution-spike/protocol-sources" entries)
              (assoc "wilkbook-execution-spike/build-manifest" entries))))

(check "old trusted profile is exactly Guile and guile-json"
       (equal? (manifest-names+versions old-supervisor)
               '(("guile" . "3.0.9") ("guile-json" . "4.7.3"))))
(check "protocol trusted profile adds only guile-gcrypt 0.5.0"
       (equal? (manifest-names+versions protocol-supervisor)
               '(("guile" . "3.0.9")
                 ("guile-gcrypt" . "0.5.0")
                 ("guile-json" . "4.7.3"))))

(let ((service-text
       (object->string
        ((protocol-private 'book-protocol-guest-shepherd-service) #f))))
  (check "Shepherd gate receives accepted closure and all fixed sources"
         (and (string-contains service-text
                               "wilkbook-book-execution-language-closure")
              (string-contains service-text "accepted-guest-smoke")
              (string-contains service-text "accepted-book-session")
              (string-contains service-text "guest-book-protocol")
              (string-contains
               service-text
                "10b2bf5155697ad4ef361e3a975bff5afa8c97a3988c44d6f7356248c6900e6e")
              (string-contains service-text
                               "accepted-book-protocol")
              (string-contains service-text
                               "accepted-book-protocol-blocking")
              (string-contains service-text "fixed-guile-protocol-book")
              (string-contains service-text "fixed-python-protocol-book"))))
