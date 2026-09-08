;;; Static, non-realizing comparison for the native-reader interaction system.
(use-modules (gnu services)
             (gnu services shepherd)
             (gnu system)
             (guix gexp)
             (guix profiles)
             (pinenote packages gvisor-local-test-artifacts)
             (pinenote systems pinenote-book-execution-protocol-control)
             (pinenote systems pinenote-book-execution-reader-interaction)
             (pinenote systems pinenote-book-execution-spike)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define base pinenote-book-execution-protocol-control-operating-system)
(define reader
  pinenote-book-execution-reader-interaction-operating-system)
(define %reader-module
  (resolve-module
   '(pinenote systems pinenote-book-execution-reader-interaction)))
(define (reader-private name) (module-ref %reader-module name))
(define %protocol-module
  (resolve-module
   '(pinenote systems pinenote-book-execution-protocol-control)))
(define (protocol-private name) (module-ref %protocol-module name))
(define %spike-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
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
(define reader-services (operating-system-user-services reader))
(define base-names (map service-name base-services))
(define reader-names (map service-name reader-services))
(define reader-etc
  (service-named reader-services 'book-execution-language-profile))

(check "reader system reuses the exact accepted USER_NS kernel object"
       (eq? (operating-system-kernel base) (operating-system-kernel reader)))
(check "reader system reuses the exact accepted package list"
       (equal? (operating-system-packages base)
               (operating-system-packages reader)))
(check "accepted unpatched CONTROL artifact remains selected"
       (memq gvisor-v12-control-local-test-artifact
             (operating-system-packages reader)))
(check "sandbox file systems including cgroup2 are unchanged"
       (equal? (operating-system-file-systems base)
               (operating-system-file-systems reader)))
(check "kernel arguments are unchanged"
       (equal? (operating-system-user-kernel-arguments base)
               (operating-system-user-kernel-arguments reader)))
(check "initrd constructor is unchanged"
       (eq? (operating-system-initrd base) (operating-system-initrd reader)))

(check "service count is unchanged"
       (= (length base-services) (length reader-services)))
(check "only the one-shot service name changes"
       (equal?
        (map (lambda (name)
               (if (eq? name 'book-execution-protocol-gate)
                   'book-execution-reader-interaction-gate
                   name))
             base-names)
        reader-names))
(check "accepted automatic protocol gate remains available only in its base"
       (not (memq 'book-execution-protocol-gate reader-names)))
(check "reader interaction gate is present exactly once"
       (= 1 (count (lambda (name)
                     (eq? name 'book-execution-reader-interaction-gate))
                   reader-names)))

(let ((entries (service-value reader-etc)))
  (check "reader /etc manifest retains exactly four entries"
         (= (length entries) 4))
  (check "sandbox language profile is the exact accepted 45-path object"
         (eq? (cadr (assoc "wilkbook-execution-spike/profile" entries))
              (spike-private '%book-execution-language-profile)))
  (check "trusted Guile/JSON/gcrypt supervisor profile is unchanged"
         (eq? (cadr (assoc "wilkbook-execution-spike/supervisor-profile"
                           entries))
              (protocol-private '%book-protocol-supervisor-profile)))
  (check "only source/build manifest objects are replaced"
         (and (eq? (cadr (assoc
                          "wilkbook-execution-spike/protocol-sources" entries))
                   (reader-private '%reader-interaction-source-manifest))
              (eq? (cadr (assoc
                          "wilkbook-execution-spike/build-manifest" entries))
                   (reader-private '%reader-interaction-build-manifest)))))

(check "trusted supervisor package roster remains exactly three packages"
       (equal?
        (manifest-names+versions
         (protocol-private '%book-protocol-supervisor-profile))
        '(("guile" . "3.0.9")
          ("guile-gcrypt" . "0.5.0")
          ("guile-json" . "4.7.3"))))

(let* ((services
        ((reader-private 'book-reader-interaction-shepherd-service) #f))
       (service (car services))
       (text (object->string services)))
  (check "reader service expands to exactly one one-shot Shepherd service"
         (and (= (length services) 1)
              (not (shepherd-service-respawn? service))))
  (check "reader service waits for udev and user processes"
         (equal? (shepherd-service-requirement service)
                 '(user-processes udev)))
  (check "entry receives only accepted sources plus three trusted UI sources"
         (and
          (string-contains text "wilkbook-book-execution-language-closure")
          (string-contains text "accepted-guest-smoke")
          (string-contains text "accepted-book-session")
          (string-contains text "guest-book-protocol")
          (string-contains text "accepted-private-control")
          (string-contains text "guest-virtio-book-ui")
          (string-contains text "guest-book-interaction")
          (string-contains text
                           (reader-private '%guest-virtio-ui-sha256))
          (string-contains text
                           (reader-private '%guest-reader-authority-sha256)))))

(check "reader source/build manifests are distinct computed files"
       (and (computed-file?
             (reader-private '%reader-interaction-source-manifest))
            (computed-file?
             (reader-private '%reader-interaction-build-manifest))
            (not (eq? (reader-private '%reader-interaction-source-manifest)
                      (protocol-private '%book-protocol-source-manifest)))
            (not (eq? (reader-private '%reader-interaction-build-manifest)
                      (protocol-private '%protocol-build-manifest)))))
(check "reader source boundary pins the accepted codec and both new adapters"
       (and (string=?
             (reader-private '%private-control-sha256)
             "1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d")
            (= (string-length (reader-private '%guest-virtio-ui-sha256)) 64)
            (= (string-length
                (reader-private '%guest-reader-authority-sha256)) 64)
            (local-file? (reader-private '%private-control-source))
            (local-file? (reader-private '%guest-virtio-ui-source))
            (local-file? (reader-private '%guest-reader-authority-source))))
