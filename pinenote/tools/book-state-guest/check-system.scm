;;; Static Guix object comparison; this does not lower or realize the system.
(use-modules (gnu services)
             (gnu services shepherd)
             (gnu system)
             (gnu system file-systems)
             (guix gexp)
             (guix packages)
             (guix profiles)
             (pinenote packages gvisor)
             (pinenote packages gvisor-source)
             (pinenote systems pinenote-book-execution-spike)
             (pinenote systems pinenote-book-state-reader)
             (srfi srfi-1))

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define %module-view
  (or (getenv "BOOK_STATE_MODULE_VIEW")
      (error "BOOK_STATE_MODULE_VIEW is absent")))
(define %guest-module-path
  (string-append
   %module-view "/pinenote/systems/pinenote-book-state-reader.scm"))
(define %guest-module-filename
  (module-filename
   (resolve-module '(pinenote systems pinenote-book-state-reader))))
(define %guest-module-origin
  (and %guest-module-filename
       (if (string-prefix? "/" %guest-module-filename)
           %guest-module-filename
           (search-path %load-path %guest-module-filename))))
(define %package-view
  (or (getenv "BOOK_STATE_PACKAGE_VIEW")
      (error "BOOK_STATE_PACKAGE_VIEW is absent")))
(check "guest system module originates in the canonical private positive view"
       (and (string-prefix? "/" %module-view)
            (string=? %module-view (canonicalize-path %module-view))
            (member %module-view %load-path)
            (every (lambda (path)
                     (or (string=? path %module-view)
                         (string=? path %package-view)
                         (string-prefix? "/gnu/store/" path)))
                   %load-path)
            %guest-module-origin
            (string=? %guest-module-origin %guest-module-path)))

(define base pinenote-book-execution-spike-operating-system)
(define guest pinenote-book-state-reader-operating-system)
(define module
  (resolve-module '(pinenote systems pinenote-book-state-reader)))
(define (private name) (module-ref module name))
(define (service-name item) (service-type-name (service-kind item)))
(define (service-named services name)
  (find (lambda (item) (eq? (service-name item) name)) services))
(define (profile-roster profile)
  (sort
   (map (lambda (entry)
          (cons (manifest-entry-name entry) (manifest-entry-version entry)))
        (manifest-entries (profile-content profile)))
   (lambda (left right) (string<? (car left) (car right)))))

(check "exact accepted USER_NS kernel object is inherited"
       (eq? (operating-system-kernel base) (operating-system-kernel guest)))
(let ((base-packages (operating-system-packages base))
      (guest-packages (operating-system-packages guest)))
  (check "public official-binary gVisor package is replaced exactly once"
         (and (= 1 (count (lambda (item) (eq? item gvisor-bin)) base-packages))
              (not (memq gvisor-bin guest-packages))
              (= 1 (count (lambda (item) (eq? item gvisor/source))
                          guest-packages))
              (equal? (map (lambda (item)
                             (if (eq? item gvisor-bin) gvisor/source item))
                           base-packages)
                      guest-packages)))
  (check "source-built gVisor package has the intended public identity"
         (and (string=? (package-name gvisor/source) "gvisor-source-built")
              (string=? (package-version gvisor/source) "20260831.0"))))
(check "kernel arguments are inherited"
       (equal? (operating-system-user-kernel-arguments base)
               (operating-system-user-kernel-arguments guest)))
(check "initrd constructor is inherited"
       (eq? (operating-system-initrd base) (operating-system-initrd guest)))

(let* ((base-file-systems (operating-system-file-systems base))
       (guest-file-systems (operating-system-file-systems guest))
       (added (car guest-file-systems)))
  (check "one filesystem is prepended to the accepted root/cgroup graph"
         (and (= (length guest-file-systems) (+ 1 (length base-file-systems)))
              (equal? (cdr guest-file-systems) base-file-systems)))
  (check "persistent filesystem has exact mount point/type/generic flags"
         (and (string=? (file-system-mount-point added)
                        "/var/lib/wilkbook-book-state-demo")
              (string=? (file-system-type added) "ext4")
              (equal? (file-system-flags added)
                      '(no-atime no-dev no-suid no-exec))
              (not (file-system-options added))
              (not (file-system-mount-may-fail? added))
              (file-system-check? added)))
  (check "persistent filesystem uses exact label"
         (equal? (file-system-device added)
                 (file-system-label "WBBookStateV1"))))

(let* ((base-services (operating-system-user-services base))
       (guest-services (operating-system-user-services guest))
       (names (map service-name guest-services))
       (etc (service-named guest-services 'book-execution-language-profile))
       (entries (service-value etc)))
  (check "public spike gate is replaced and one volume-preparation service is added"
         (and (= (length guest-services) (+ 1 (length base-services)))
              (= 1 (count (lambda (name) (eq? name 'book-state-guest-gate)) names))
              (= 1 (count (lambda (name) (eq? name 'book-state-volume-ready)) names))
              (not (memq 'book-execution-guest-smoke names))))
  (check "accepted 45-path sandbox profile object remains exact"
          (eq? (cadr (assoc "wilkbook-execution-spike/profile" entries))
               (module-ref
                (resolve-module
                 '(pinenote systems pinenote-book-execution-spike))
                '%book-execution-language-profile)))
  (check "only trusted profile and source/build manifests are replaced"
         (and (eq? (cadr (assoc
                          "wilkbook-execution-spike/supervisor-profile" entries))
                   (private '%book-state-supervisor-profile))
              (eq? (cadr (assoc
                          "wilkbook-execution-spike/protocol-sources" entries))
                   (private '%source-manifest))
              (eq? (cadr (assoc
                          "wilkbook-execution-spike/build-manifest" entries))
                   (private '%build-manifest))
              (not (assoc "wilkbook-execution-spike/smoke-book" entries))
              (= (length entries) 4))))

(check "trusted supervisor profile has the exact backend package roster"
       (equal? (profile-roster (private '%book-state-supervisor-profile))
               '(("guile" . "3.0.9")
                 ("guile-gcrypt" . "0.5.0")
                 ("guile-json" . "4.7.3")
                 ("guile-sqlite3" . "0.1.3"))))

(let* ((volume-services
        ((private 'book-state-volume-ready-shepherd-service) #f))
       (volume (car volume-services))
       (guest-services ((private 'book-state-guest-shepherd-service) #f))
       (authority (car guest-services)))
  (check "volume preparation waits for the exact file-system service"
          (and (= (length volume-services) 1)
               (shepherd-service-one-shot? volume)
               (equal? (shepherd-service-requirement volume)
                       '(file-system-/var/lib/wilkbook-book-state-demo))))
  (check "volume preparation imports its compiled start-procedure bindings"
         (equal? (shepherd-service-modules volume)
                 (append '((ice-9 textual-ports)
                           (srfi srfi-1)
                           (srfi srfi-13))
                         %default-modules)))
  (check "authority waits for volume, udev, and user processes"
         (and (= (length guest-services) 1)
              (not (shepherd-service-respawn? authority))
              (equal? (shepherd-service-requirement authority)
                      '(user-processes udev book-state-volume-ready)))))

(check "system source boundary is file-by-file and computed"
        (and (local-file? (private '%accepted-prerequisite-attestation))
             (local-file? (private '%outer-qemu-handoff))
             (local-file? (private '%guile-boundary-probe-source))
             (local-file? (private '%python-boundary-probe-source))
             (local-file? (private '%gvisor-source-package-definition))
            (local-file? (private '%gvisor-binary-package-definition))
            (computed-file? (private '%source-manifest))
            (computed-file? (private '%build-manifest))))
