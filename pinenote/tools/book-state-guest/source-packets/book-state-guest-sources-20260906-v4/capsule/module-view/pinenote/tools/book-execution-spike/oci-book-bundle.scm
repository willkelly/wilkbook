;;; Fixed Book Protocol OCI bundles for the first real runsc FD-donation gate.
;;; This is deliberately a sibling of the accepted compatibility generator:
;;; it reuses that generator's path/closure validation but exposes no CLI and
;;; cannot select an arbitrary program, argument vector, runtime, or profile.
(define-module (oci-book-bundle)
  #:use-module (ice-9 match)
  #:use-module (json)
  #:use-module (oci-bundle)
  #:use-module (srfi srfi-1)
  #:export (generate-guile-protocol-bundle
            generate-python-protocol-bundle
            make-protocol-launch-argv
            make-protocol-launch-record
            make-protocol-spec))

(define runsc "/run/current-system/profile/bin/runsc")
(define oci-version "1.0.2")
(define nonroot-id 65534)
(define scratch-bytes (* 16 1024 1024))
(define dev-bytes (* 1024 1024))

(define pinned-runtime-flags
  '("--platform=systrap"
    "--network=none"
    "--sidecar-usage-policy=strict"
    "--sidecar-release-enforcement-policy=always"
    "--ignore-cgroups=false"
    "--host-uds=none"
    "--host-fifo=none"
    "--character-device-policy=emulated-only"
    "--allow-suid=false"
    "--allow-flag-override=false"
    "--allow-rootfs-tar-annotation=false"
    "--overlay2=none"
    "--rootless=false"
    "--file-access=exclusive"
    "--file-access-mounts=exclusive"
    "--net-raw=false"
    "--allow-packet-socket-write=false"
    "--directfs=false"))

(define diagnostic-runtime-flags
  '("--debug=true"
    "--debug-log-format=text"
    "--alsologtostderr=true"))

(define supervisor-environment
  '("HOME=/nonexistent"
    "LANG=C"
    "LC_ALL=C"
    "PATH=/run/current-system/profile/bin"))

(define %base-module (resolve-module '(oci-bundle)))
(define (base-private name)
  (module-ref %base-module name))

(define (lstat-or-false path)
  ((base-private 'lstat-or-false) path))

(define (mkdir-mode path mode)
  ((base-private 'mkdir-mode) path mode))

(define (touch-mode path mode)
  ((base-private 'touch-mode) path mode))

(define (container-store-path item)
  ((base-private 'container-store-path) item))

(define* (bind-mount source destination #:key (noexec? #f))
  ((base-private 'bind-mount) source destination #:noexec? noexec?))

(define (validate-fixed-source raw closure store-root label)
  (let* ((canonical
          ((base-private 'canonical-existing) raw label))
         (item ((base-private 'store-item) canonical store-root label)))
    (unless (string=? canonical item)
      (bundle-error
       (format #f "~a must be one top-level immutable store file: ~a"
               label canonical)))
    ((base-private 'require-type) canonical 'regular label)
    (when (member item closure)
      (bundle-error
       (format #f
               "~a must be a separately declared source, not part of the language closure"
               label)))
    canonical))

(define (require-distinct-sources sources)
  (unless (= (length sources) (length (delete-duplicates sources string=?)))
    (bundle-error "fixed protocol source outputs must be distinct")))

(define (cgroups-path container-id)
  (string-append "/wilkbook-execution-" container-id))

(define (base-mounts)
  `((
     ("destination" . "/proc")
     ("options" . #("nosuid" "noexec" "nodev"))
     ("source" . "proc")
     ("type" . "proc"))
    (("destination" . "/dev")
     ("options" . #("nosuid" "noexec" "strictatime" "mode=755"
                     ,(string-append "size=" (number->string dev-bytes))))
     ("source" . "tmpfs")
     ("type" . "tmpfs"))
    (("destination" . "/scratch")
     ("options" . #("nosuid" "nodev" "noexec" "mode=1777"
                     ,(string-append "size="
                                     (number->string scratch-bytes))))
     ("source" . "tmpfs")
     ("type" . "tmpfs"))))

(define empty-capabilities
  '(("ambient" . #())
    ("bounding" . #())
    ("effective" . #())
    ("inheritable" . #())
    ("permitted" . #())))

(define python-entry-code
  "import runpy,sys\nsys.path.insert(0,'/book/modules')\nrunpy.run_path('/book/entry.py',run_name='__main__')\n")

(define (fixed-process kind)
  (case kind
    ((guile)
     `(("args" . #("/profile/bin/guile" "--no-auto-compile"
                    "-L" "/book/modules" "/book/entry.scm"))
       ("env" . #("BOOK_SESSION_FD=3"
                   "GUILE_AUTO_COMPILE=0"
                   "GUILE_LOAD_PATH=/profile/share/guile/site/3.0"
                   "GUILE_LOAD_COMPILED_PATH=/profile/lib/guile/3.0/site-ccache"
                   "HOME=/scratch"
                   "LANG=C.UTF-8"
                   "LC_ALL=C.UTF-8"
                   "PATH=/profile/bin"
                   "TMPDIR=/scratch"))))
    ((python)
     `(("args" . #("/profile/bin/python3" "-I" "-B" "-c"
                    ,python-entry-code))
       ("env" . #("BOOK_SESSION_FD=3"
                   "HOME=/scratch"
                   "LANG=C.UTF-8"
                   "LC_ALL=C.UTF-8"
                   "PATH=/profile/bin"
                   "PYTHONDONTWRITEBYTECODE=1"
                   "PYTHONNOUSERSITE=1"
                   "TMPDIR=/scratch"))))
    (else (bundle-error "unknown fixed protocol-book kind"))))

(define (source-destinations kind sources)
  (case kind
    ((guile)
     (match sources
       ((entry protocol blocking)
        (list (cons entry "/book/entry.scm")
              (cons protocol "/book/modules/book-protocol.scm")
              (cons blocking "/book/modules/book-protocol/blocking-io.scm")))
       (_ (bundle-error "Guile bundle requires exactly three fixed sources"))))
    ((python)
     (match sources
       ((entry protocol)
        (list (cons entry "/book/entry.py")
              (cons protocol "/book/modules/book_protocol.py")))
       (_ (bundle-error "Python bundle requires exactly two fixed sources"))))
    (else (bundle-error "unknown fixed protocol-book kind"))))

(define (make-protocol-spec kind profile closure sources container-id)
  (let* ((process-fields (fixed-process kind))
         (source-mounts
          (map (lambda (entry)
                 (bind-mount (car entry) (cdr entry) #:noexec? #t))
               (source-destinations kind sources)))
         (store-mounts
          (map (lambda (item)
                 (bind-mount item (container-store-path item)))
               closure))
         (mounts (append (base-mounts) store-mounts source-mounts)))
    `(("hostname" . "wilkbook-protocol-fixture")
      ("linux" .
       (("cgroupsPath" . ,(cgroups-path container-id))
        ("maskedPaths" . #("/proc/acpi" "/proc/asound" "/proc/kcore"
                            "/proc/keys" "/proc/latency_stats"
                            "/proc/sched_debug" "/proc/timer_list"
                            "/proc/timer_stats" "/sys/firmware"))
        ("namespaces" . ,(list->vector
                           '((("type" . "pid"))
                             (("type" . "network"))
                             (("type" . "ipc"))
                             (("type" . "uts"))
                             (("type" . "mount")))))
        ("readonlyPaths" . #("/proc/bus" "/proc/fs" "/proc/irq"
                              "/proc/sys" "/proc/sysrq-trigger"))))
      ("mounts" . ,(list->vector mounts))
      ("ociVersion" . ,oci-version)
      ("process" .
       (("args" . ,(assoc-ref process-fields "args"))
        ("capabilities" . ,empty-capabilities)
        ("cwd" . "/scratch")
        ("env" . ,(assoc-ref process-fields "env"))
        ("noNewPrivileges" . #t)
        ("rlimits" . ,(list->vector
                        '((("hard" . 0) ("soft" . 0)
                           ("type" . "RLIMIT_CORE"))
                          (("hard" . 1048576) ("soft" . 1048576)
                           ("type" . "RLIMIT_FSIZE"))
                          (("hard" . 64) ("soft" . 64)
                           ("type" . "RLIMIT_NOFILE")))))
        ("terminal" . #f)
        ("user" . (("additionalGids" . #())
                    ("gid" . ,nonroot-id)
                    ("uid" . ,nonroot-id)
                    ("umask" . 63)))))
      ("root" . (("path" . "rootfs") ("readonly" . #t))))))

(define (diagnostic-runtime-path-flags bundle)
  (list
   (string-append "--debug-log=" bundle "/runsc-debug/")
   (string-append
    "--panic-log=" bundle "/runsc-panic/runsc.panic.%COMMAND%.log")))

(define (make-protocol-launch-argv bundle container-id)
  (append
   (list runsc (string-append "--root=" bundle "/runsc-state"))
   diagnostic-runtime-flags
   (diagnostic-runtime-path-flags bundle)
   pinned-runtime-flags
   (list "run"
         "--pass-fd=3:3"
         (string-append "--bundle=" bundle)
         container-id)))

(define (make-protocol-launch-record bundle container-id kind)
  `(("argv" . ,(list->vector
                  (make-protocol-launch-argv bundle container-id)))
    ("cgroupsPath" . ,(cgroups-path container-id))
    ("claim" . "fixed-book-protocol-fd-donation-gate")
    ("executionProfile" . "isolation-userns")
    ("fixtureKind" . ,(symbol->string kind))
    ("guestProtocolFd" . 3)
    ("requiredKernelConfig" . #("CONFIG_USER_NS=y"))
    ("supervisorEnv" . ,(list->vector
                          (append supervisor-environment
                                  (list (string-append
                                         "TMPDIR=" bundle
                                         "/supervisor-tmp")))))
    ("supervisorUid" . 0)))

(define (make-rootfs rootfs profile closure destinations)
  (mkdir-mode rootfs #o755)
  (for-each
   (lambda (relative)
     (mkdir-mode (string-append rootfs "/" relative) #o755))
   '("gnu" "gnu/store" "book" "book/modules" "proc" "dev" "scratch"))
  (when (any (lambda (entry)
               (string-prefix? "/book/modules/book-protocol/" (cdr entry)))
             destinations)
    (mkdir-mode (string-append rootfs "/book/modules/book-protocol") #o755))
  (for-each
   (lambda (item)
     (let ((destination (string-append rootfs (container-store-path item))))
       (case (stat:type (lstat item))
         ((directory) (mkdir-mode destination #o555))
         ((regular) (touch-mode destination #o444))
         (else (bundle-error "language closure contains an unsupported type")))))
   closure)
  (for-each
   (lambda (entry)
     (touch-mode (string-append rootfs (cdr entry)) #o444))
   destinations)
  (symlink (container-store-path profile) (string-append rootfs "/profile")))

(define (write-json path value)
  ((base-private 'write-json) path value))

(define* (generate-fixed-protocol-bundle
          #:key kind profile-input source-inputs bundle-input container-id
          requisites-runner (store-root "/gnu/store"))
  (let* ((store ((base-private 'canonical-store-root) store-root))
         (profile ((base-private 'validate-profile) profile-input store))
         (closure
          ((base-private 'validate-requisites)
           (requisites-runner profile) profile store)))
    ;; Keep the accepted Guile/guile-json/Python language profile whole and
    ;; unchanged even though each fixed bundle selects only one interpreter.
    ((base-private 'validate-profile-entry) profile closure store "python3")
    ((base-private 'validate-profile-entry) profile closure store "guile")
    ((base-private 'validate-container-id) container-id)
    (let ((sources
           (map (lambda (entry)
                  (validate-fixed-source (car entry) closure store (cdr entry)))
                source-inputs)))
      (require-distinct-sources sources)
      ;; Validate the exact source count before claiming the destination.
      (let ((destinations (source-destinations kind sources))
            (bundle ((base-private 'validate-bundle-destination)
                     bundle-input store)))
        (let ((parent-before (lstat (dirname bundle)))
              (created? #f)
              (bundle-identity #f))
          (catch #t
            (lambda ()
              (mkdir-mode bundle #o700)
              (set! created? #t)
              (set! bundle-identity (lstat bundle))
              (let ((parent-after (lstat (dirname bundle))))
                (unless (and (= (stat:dev parent-before) (stat:dev parent-after))
                             (= (stat:ino parent-before) (stat:ino parent-after)))
                  (bundle-error
                   "bundle parent identity changed before creation")))
              (make-rootfs (string-append bundle "/rootfs")
                           profile closure destinations)
              (for-each
               (lambda (relative)
                 (mkdir-mode (string-append bundle "/" relative) #o700))
               '("runsc-state" "supervisor-tmp" "runsc-debug" "runsc-panic"))
              (write-json
               (string-append bundle "/config.json")
               (make-protocol-spec kind profile closure sources container-id))
              (write-json
               (string-append bundle "/launch.json")
               (make-protocol-launch-record bundle container-id kind))
              bundle)
            (lambda (key . arguments)
              (when created?
                (let ((current (lstat-or-false bundle)))
                  (when (and current bundle-identity
                             (= (stat:dev current) (stat:dev bundle-identity))
                             (= (stat:ino current) (stat:ino bundle-identity)))
                    ((base-private 'delete-created-tree) bundle))))
              (apply throw key arguments))))))))

(define* (generate-guile-protocol-bundle
          #:key profile-input book-entry-input protocol-input blocking-input
          bundle-input container-id requisites-runner
          (store-root "/gnu/store"))
  (generate-fixed-protocol-bundle
   #:kind 'guile
   #:profile-input profile-input
   #:source-inputs
   `((,book-entry-input . "Guile fixed book entry")
     (,protocol-input . "accepted Guile protocol module")
     (,blocking-input . "accepted Guile blocking adapter"))
   #:bundle-input bundle-input
   #:container-id container-id
   #:requisites-runner requisites-runner
   #:store-root store-root))

(define* (generate-python-protocol-bundle
          #:key profile-input book-entry-input protocol-input bundle-input
          container-id requisites-runner (store-root "/gnu/store"))
  (generate-fixed-protocol-bundle
   #:kind 'python
   #:profile-input profile-input
   #:source-inputs
   `((,book-entry-input . "Python fixed book entry")
     (,protocol-input . "accepted Python protocol module"))
   #:bundle-input bundle-input
   #:container-id container-id
   #:requisites-runner requisites-runner
   #:store-root store-root))
