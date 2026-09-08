;;; Trusted Guile OCI bundle generator for the non-shipping execution spike.
;;; Process style follows pinned Guix f250e74dd and GNU Shepherd 1.0.9: direct
;;; command vectors, constructed environments, CLOEXEC descriptors, explicit
;;; waitpid status handling, and primitive-exit in failed fork children.  This
;;; small synchronous tool deliberately does not import Shepherd/Fibers.
(define-module (oci-bundle)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (bundle-error
            execution-profiles
            generate-bundle
            bundle-json-string
            make-launch-argv
            make-launch-record
            make-spec
            oci-bundle-main
            run-guix-requisites))

(define oci-version "1.0.2")
(define default-store-root "/gnu/store")
(define nonroot-id 65534)
(define scratch-bytes (* 16 1024 1024))
(define dev-bytes (* 1024 1024))
(define runsc "/run/current-system/profile/bin/runsc")
(define env-program "/run/current-system/profile/bin/env")
(define guile-program
  "/etc/wilkbook-execution-spike/supervisor-profile/bin/guile")
(define cgroup-root "/sys/fs/cgroup")

;; Selection remains mandatory.  Pinned gVisor commit
;; fd2f6b2674208086e324c2f739155eb7e1b48ff2 requires user namespaces in both
;; branches: modifySpecForDirectfs adds one for directfs+network=none, while the
;; non-DirectFS sandbox path adds one for its reduced-privilege support process.
(define execution-profiles
  `(("functional-directfs"
     (directfs . #t)
     (claim . "functional-only-not-isolation-acceptance")
     (required-kernel-config . #("CONFIG_USER_NS=y")))
    ("isolation-userns"
     (directfs . #f)
     (claim . "isolation-candidate-not-yet-accepted")
     (required-kernel-config . #("CONFIG_USER_NS=y")))))

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
    "--allow-packet-socket-write=false"))

;; Fixed diagnostics for this compatibility fixture only.  These are trusted
;; generator policy, never book-selected flags.  Debug mode preserves the
;; sandbox stdio long enough to capture prewarmer failures, while debug/panic
;; files are created by runsc under separate private bundle directories and
;; donated to internal sidecars as already-open descriptors.  The guest
;; supervisor mounts independently bounded stores on those directories before
;; starting runsc, preserving late panic capacity if debug storage fills.
(define diagnostic-runtime-flags
  '("--debug=true"
    "--debug-log-format=text"
    "--alsologtostderr=true"))

(define (diagnostic-runtime-path-flags bundle)
  (list
   (string-append "--debug-log=" bundle "/runsc-debug/")
   (string-append
    "--panic-log=" bundle "/runsc-panic/runsc.panic.%COMMAND%.log")))

(define supervisor-environment
  '("HOME=/nonexistent"
    "LANG=C"
    "LC_ALL=C"
    "PATH=/run/current-system/profile/bin"))

;; This remains a sandboxed-language compatibility probe, not the Book
;; Protocol.  Python is payload only; the trusted generator and launcher are
;; Guile.  This fixed fixture emits one exact diagnostic sentinel on stdout;
;; it is not a general output channel or future protocol transport.
(define python-smoke
  "from pathlib import Path\nimport socket\n\nbook = Path(\"/book/input\")\ndata = book.read_bytes()\nPath(\"/scratch/book-size\").write_text(str(len(data)), encoding=\"ascii\")\n\nsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\nsock.settimeout(0.2)\ntry:\n    sock.connect((\"192.0.2.1\", 9))\nexcept OSError:\n    pass\nelse:\n    sock.close()\n    raise SystemExit(\"external network unexpectedly reachable\")\nfinally:\n    sock.close()\n\nprint(f\"BOOKEXEC-PAYLOAD-PYTHON book-bytes={len(data)}\", flush=True)\n")

(define (bundle-error message)
  (throw 'book-execution-bundle-error message))

(define (mark-inherited-fds-close-on-exec)
  ;; There is no Book Protocol FD in this preparation subprocess.  Follow the
  ;; pinned Guix/Shepherd convention and make every unrelated descriptor above
  ;; stderr close on exec; future protocol integration must explicitly exempt
  ;; and number its one reviewed descriptor.
  (for-each
   (lambda (name)
     (let ((fd (string->number name)))
       (when (and fd (> fd 2))
         (catch 'system-error
           (lambda ()
             (let ((flags (fcntl fd F_GETFD)))
               (unless (positive? (logand flags FD_CLOEXEC))
                 (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))
           (lambda arguments
             (unless (= EBADF (system-error-errno arguments))
               (apply throw 'system-error arguments)))))))
   (scandir "/proc/self/fd"
            (lambda (name) (and (string->number name) #t)))))

(define (lexical-absolute raw label)
  (unless (and (string? raw) (string-prefix? "/" raw))
    (bundle-error (format #f "~a must be absolute: ~s" label raw)))
  (when (or (string-index raw #\nul)
            (string-index raw #\newline)
            (string-index raw #\return))
    (bundle-error (format #f "~a contains a forbidden control character" label)))
  (when (any (lambda (part) (member part '("" "." "..")))
             (cdr (string-split raw #\/)))
    (bundle-error
     (format #f
             "~a must be lexical and traversal-free (no //, . or ..): ~s"
             label raw)))
  raw)

(define* (canonical-existing raw label #:key (allow-input-symlink? #f))
  (let* ((path (lexical-absolute raw label))
         (resolved
          (catch 'system-error
            (lambda () (canonicalize-path path))
            (lambda arguments
              (bundle-error
               (format #f "~a cannot be resolved safely: ~a" label raw))))))
    (when (and (not allow-input-symlink?) (not (string=? path resolved)))
      (bundle-error (format #f "~a must not contain a symlink: ~a" label raw)))
    resolved))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (require-type path expected label)
  (let ((info (lstat-or-false path)))
    (unless (and info (eq? (stat:type info) expected))
      (bundle-error (format #f "~a is not a real ~a: ~a" label expected path)))
    info))

(define (canonical-store-root store-root)
  (let ((store (canonical-existing store-root "Guix store root")))
    (require-type store 'directory "Guix store root")
    store))

(define (valid-store-name? name)
  (and (>= (string-length name) 34)
       (char=? (string-ref name 32) #\-)
       (string-every (lambda (character)
                       (or (char-numeric? character)
                           (and (char>=? character #\a)
                                (char<=? character #\z))))
                     (substring name 0 32))))

(define (store-item path store-root label)
  (let ((prefix (string-append store-root "/")))
    (unless (string-prefix? prefix path)
      (bundle-error (format #f "~a is outside ~a: ~a" label store-root path)))
    (let* ((relative (substring path (string-length prefix)))
           (slash (string-index relative #\/))
           (name (if slash (substring relative 0 slash) relative)))
      (when (string-null? name)
        (bundle-error (format #f "~a names the whole Guix store" label)))
      (unless (valid-store-name? name)
        (bundle-error
         (format #f "~a has an invalid Guix store item name: ~s" label name)))
      (string-append prefix name))))

(define (validate-profile raw store-root)
  (let* ((profile (canonical-existing raw "profile" #:allow-input-symlink? #t))
         (item (store-item profile store-root "profile")))
    (unless (string=? profile item)
      (bundle-error
       (format #f "profile must resolve to a top-level store item: ~a" profile)))
    (require-type profile 'directory "profile store item")
    ;; Guix profile store names are caller-selected and need not end in
    ;; "-profile".  The trusted selected object, its regular manifest, exact
    ;; closure membership, and resolved language entries are the authority.
    (require-type (string-append profile "/manifest")
                  'regular "profile manifest")
    profile))

(define (validate-requisites raw-paths profile store-root)
  (let loop ((remaining raw-paths) (index 1) (seen '()) (paths '()))
    (if (null? remaining)
        (begin
          (unless (member profile seen)
            (bundle-error "Guix requisites do not contain the selected profile"))
          (sort paths string<?))
        (let ((raw (car remaining)))
          (when (string-null? raw)
            (bundle-error (format #f "empty Guix requisite at line ~a" index)))
          (let* ((label (format #f "Guix requisite line ~a" index))
                 (requisite (canonical-existing raw label))
                 (item (store-item requisite store-root label))
                 (info (lstat requisite)))
            (unless (string=? requisite item)
              (bundle-error
               (format #f "Guix requisite must be one top-level store item: ~a"
                       requisite)))
            (unless (memq (stat:type info) '(directory regular))
              (bundle-error
               (format #f "Guix requisite has unsupported type: ~a" requisite)))
            (when (member requisite seen)
              (bundle-error (format #f "duplicate Guix requisite: ~a" requisite)))
            (loop (cdr remaining)
                  (+ index 1)
                  (cons requisite seen)
                  (cons requisite paths)))))))

(define (validate-book raw closure store-root)
  (let* ((book (canonical-existing raw "book fixture"))
         (item (store-item book store-root "book fixture")))
    (require-type book 'regular "book fixture")
    (when (member item closure)
      (bundle-error
       "book fixture belongs to the language closure; select a separate immutable store item so only the chosen file is exposed"))
    book))

(define (validate-profile-entry profile closure store-root name)
  (let* ((relative (string-append "bin/" name))
         (entry (string-append profile "/" relative))
         (resolved
          (catch 'system-error
            (lambda () (canonicalize-path entry))
            (lambda arguments
              (bundle-error
               (format #f "profile has no ~a: ~a" relative profile)))))
         (label (string-append "profile " name))
         (item (store-item resolved store-root label)))
    (unless (member item closure)
      (bundle-error
       (format #f "profile ~a resolves outside the enumerated closure" name)))
    (require-type resolved 'regular (string-append label " target"))
    (unless (access? resolved X_OK)
      (bundle-error
       (format #f "profile ~a target is not executable: ~a" name resolved)))))

(define (validate-guix raw store-root)
  (let ((guix (canonical-existing raw "guix executable"
                                   #:allow-input-symlink? #t)))
    (store-item guix store-root "guix executable")
    (require-type guix 'regular "guix target")
    (unless (access? guix X_OK)
      (bundle-error (format #f "guix target is not executable: ~a" guix)))
    guix))

(define (wait-status->exit status)
  (or (status:exit-val status)
      (let ((signal-number (status:term-sig status)))
        (if signal-number (logior #x80 signal-number) 1))))

(define (waitpid/retry pid)
  (catch 'system-error
    (lambda () (waitpid pid))
    (lambda arguments
      (if (= EINTR (system-error-errno arguments))
          (waitpid/retry pid)
          (apply throw 'system-error arguments)))))

(define (make-capture-file stem)
  (let* ((directory (or (getenv "TMPDIR") "/tmp"))
         (template (string-copy (string-append directory "/" stem ".XXXXXX")))
         (port (mkstemp! template)))
    (chmod template #o600)
    (cons template port)))

(define (run-captured executable arguments environment)
  (unless (and (every string? arguments) (every string? environment))
    (bundle-error "process arguments and environment must be lists of strings"))
  (let* ((stdout-capture (make-capture-file "wilkbook-guix-stdout"))
         (stderr-capture (make-capture-file "wilkbook-guix-stderr"))
         (stdout-path (car stdout-capture))
         (stdout-port (cdr stdout-capture))
         (stderr-path (car stderr-capture))
         (stderr-port (cdr stderr-capture)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; This synchronous tool reaps directly rather than installing the
        ;; Shepherd SIGCHLD/process-monitor fiber.  Force a waitable child even
        ;; if the invoking shell ignored SIGCHLD, then retry waitpid on EINTR.
        (sigaction SIGCHLD SIG_DFL)
        (let ((pid (primitive-fork)))
          (if (zero? pid)
              (catch #t
                (lambda ()
                  (sigaction SIGPIPE SIG_DFL)
                  (dup2 (fileno stdout-port) 1)
                  (dup2 (fileno stderr-port) 2)
                  (close-port stdout-port)
                  (close-port stderr-port)
                  (mark-inherited-fds-close-on-exec)
                  (environ environment)
                  (apply execl executable executable arguments))
                (lambda arguments
                  (format (current-error-port) "exec failed: ~s~%" arguments)
                  (force-output (current-error-port))
                  (primitive-exit 127)))
              (begin
                (close-port stdout-port)
                (close-port stderr-port)
                (let* ((status (cdr (waitpid/retry pid)))
                       (exit-code (wait-status->exit status))
                       (stdout (call-with-input-file stdout-path get-string-all))
                       (stderr (call-with-input-file stderr-path get-string-all)))
                  (list exit-code stdout stderr))))))
      (lambda ()
        (unless (port-closed? stdout-port) (close-port stdout-port))
        (unless (port-closed? stderr-port) (close-port stderr-port))
        (when (lstat-or-false stdout-path) (delete-file stdout-path))
        (when (lstat-or-false stderr-path) (delete-file stderr-path))))))

(define (run-guix-requisites guix profile)
  (match (run-captured
          guix
          (list "gc" "--requisites" profile)
          '("HOME=/nonexistent"
            "LANG=C"
            "LC_ALL=C"
            "PATH=/run/current-system/profile/bin:/usr/bin:/bin"))
    ((0 stdout stderr)
     (string-split (string-trim-right stdout) #\newline))
    ((status stdout stderr)
     (bundle-error
      (format #f "guix gc --requisites failed: ~a"
              (let ((detail (string-trim-both stderr)))
                (if (string-null? detail)
                    (format #f "exit ~a" status)
                    detail)))))))

(define (container-store-path item)
  (string-append "/gnu/store/" (basename item)))

(define* (bind-mount source destination #:key (noexec? #f))
  `(("destination" . ,destination)
    ("options" . ,(list->vector
                    (append '("bind" "ro" "nosuid" "nodev")
                            (if noexec? '("noexec") '()))))
    ("source" . ,source)
    ("type" . "bind")))

(define (cgroups-path container-id)
  (string-append "/wilkbook-execution-" container-id))

(define (make-spec profile closure book container-id)
  (let* ((base-mounts
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
                             ,(string-append "size=" (number->string scratch-bytes))))
             ("source" . "tmpfs")
             ("type" . "tmpfs"))))
         (store-mounts
          (map (lambda (item)
                 (bind-mount item (container-store-path item)))
               closure))
         (mounts
          (append base-mounts store-mounts
                  (list (bind-mount book "/book/input" #:noexec? #t))))
         (empty-capabilities
          '(("ambient" . #())
            ("bounding" . #())
            ("effective" . #())
            ("inheritable" . #())
            ("permitted" . #()))))
    `(("hostname" . "wilkbook-execution-spike")
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
       (("args" . #("/profile/bin/python3" "-I" "-c" ,python-smoke))
        ("capabilities" . ,empty-capabilities)
        ("cwd" . "/scratch")
        ("env" . #("HOME=/scratch" "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
                    "PATH=/profile/bin" "PYTHONNOUSERSITE=1"
                    "TMPDIR=/scratch"))
        ("noNewPrivileges" . #t)
        ("rlimits" . ,(list->vector
                        '((("hard" . 0) ("soft" . 0) ("type" . "RLIMIT_CORE"))
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

(define (profile-policy execution-profile)
  (let ((entry (assoc execution-profile execution-profiles)))
    (unless entry
      (bundle-error (format #f "unknown execution profile: ~s" execution-profile)))
    (cdr entry)))

(define (make-launch-argv bundle container-id execution-profile)
  (let* ((policy (profile-policy execution-profile))
         (directfs? (assoc-ref policy 'directfs)))
    (append
     (list runsc (string-append "--root=" bundle "/runsc-state"))
     diagnostic-runtime-flags
     (diagnostic-runtime-path-flags bundle)
     pinned-runtime-flags
     (list (string-append "--directfs=" (if directfs? "true" "false"))
           "run"
           (string-append "--bundle=" bundle)
           container-id))))

(define (make-launch-record bundle container-id execution-profile)
  (let* ((policy (profile-policy execution-profile))
         (environment
          (append supervisor-environment
                  (list (string-append "TMPDIR=" bundle "/supervisor-tmp")))))
    `(("argv" . ,(list->vector
                   (make-launch-argv bundle container-id execution-profile)))
      ("cgroupsPath" . ,(cgroups-path container-id))
      ("claim" . ,(assoc-ref policy 'claim))
      ("executionProfile" . ,execution-profile)
      ("requiredKernelConfig" . ,(assoc-ref policy 'required-kernel-config))
      ("supervisorEnv" . ,(list->vector environment))
      ("supervisorUid" . 0))))

(define (mkdir-mode path mode)
  (mkdir path mode)
  (chmod path mode))

(define (touch-mode path mode)
  (call-with-output-file path (lambda (port) #t))
  (chmod path mode))

(define (make-rootfs rootfs profile closure)
  (mkdir-mode rootfs #o755)
  (for-each
   (lambda (relative)
     (mkdir-mode (string-append rootfs "/" relative) #o755))
   '("gnu" "gnu/store" "book" "proc" "dev" "scratch"))
  (for-each
   (lambda (item)
     (let ((destination (string-append rootfs (container-store-path item))))
       (case (stat:type (lstat item))
         ((directory) (mkdir-mode destination #o555))
         ((regular) (touch-mode destination #o444)))))
   closure)
  (touch-mode (string-append rootfs "/book/input") #o444)
  (symlink (container-store-path profile) (string-append rootfs "/profile")))

(define (valid-container-id? container-id)
  (and (<= 1 (string-length container-id) 64)
       (string-match "^[a-z0-9][a-z0-9_.-]*$" container-id)))

(define (validate-container-id container-id)
  (unless (valid-container-id? container-id)
    (bundle-error
     "container ID must be 1..64 lowercase ASCII letters, digits, '.', '_' or '-', starting with a letter or digit")))

(define (validate-bundle-destination raw store-root)
  (let* ((bundle (lexical-absolute raw "bundle destination"))
         (parent (dirname bundle)))
    (when (lstat-or-false bundle)
      (bundle-error (format #f "bundle destination already exists: ~a" bundle)))
    (let ((resolved-parent
           (catch 'system-error
             (lambda () (canonicalize-path parent))
             (lambda arguments
               (bundle-error (format #f "bundle parent does not exist: ~a" parent))))))
      (unless (string=? resolved-parent parent)
        (bundle-error (format #f "bundle parent must not contain a symlink: ~a"
                              parent))))
    (let ((parent-info (require-type parent 'directory "bundle parent")))
      ;; Generation state is security-sensitive and must not be exposed to or
      ;; redirected by another local account.  The trusted owner may still
      ;; mutate it, which remains an explicit preparation assumption.
      (unless (and (= (stat:uid parent-info) (getuid))
                   (zero? (logand (stat:mode parent-info) #o077)))
        (bundle-error
         (format #f "bundle parent must be owned by the caller and mode 0700: ~a"
                 parent))))
    (when (or (string=? bundle store-root)
              (string-prefix? (string-append store-root "/") bundle))
      (bundle-error "bundle destination must not be inside the Guix store"))
    bundle))

(define (delete-created-tree path)
  (let ((info (lstat-or-false path)))
    (when info
      (if (eq? (stat:type info) 'directory)
          (begin
            (for-each
             (lambda (name)
               (unless (member name '("." ".."))
                 (delete-created-tree (string-append path "/" name))))
             (scandir path))
            (rmdir path))
          (delete-file path)))))

(define (write-bundle-json value port)
  ;; guile-json 4.7.3 requires Unicode mode to escape every C0 control;
  ;; that mode also deliberately escapes supplementary code points.
  (scm->json value port
             #:unicode #t
             #:null 'null
             #:validate #t
             #:pretty #t))

(define (bundle-json-string value)
  (call-with-output-string
    (lambda (port) (write-bundle-json value port))))

(define (write-json path value)
  (call-with-output-file path
    (lambda (port)
      (write-bundle-json value port)
      (newline port)))
  (chmod path #o600))

(define (write-scheme-string value port)
  (write value port))

(define (shell-quote value)
  (call-with-output-string
    (lambda (port)
      (display "'" port)
      (string-for-each
       (lambda (character)
         (if (char=? character #\')
             (display "'\"'\"'" port)
             (write-char character port)))
       value)
      (display "'" port))))

(define (write-launcher path launch-record)
  (let* ((argv (vector->list (assoc-ref launch-record "argv")))
         (environment (vector->list (assoc-ref launch-record "supervisorEnv")))
         (target-cgroup (assoc-ref launch-record "cgroupsPath")))
    (call-with-output-file path
      (lambda (port)
        (display ";;; Generated fixed-policy gVisor launcher.\n" port)
        (display ";;; Process conventions: Guix f250e74dd / Shepherd 1.0.9.\n" port)
        (display "(use-modules (ice-9 ftw) (ice-9 rdelim))\n" port)
        (display "(define runsc " port) (write-scheme-string runsc port)
        (display ")\n(define argv '" port) (write argv port)
        (display ")\n(define supervisor-environment '" port) (write environment port)
        (display ")\n(define cgroup-root " port) (write-scheme-string cgroup-root port)
        (display ")\n(define cgroups-path " port) (write-scheme-string target-cgroup port)
        (display ")\n" port)
        (display
         "(define (fail message) (format (current-error-port) \"FAIL: ~a~%\" message) (exit 1))\n\
(define (path-present? path) (catch 'system-error (lambda () (lstat path) #t) (lambda _ #f)))\n\
(define (preflight-error message)\n\
  (throw 'wilkbook-cgroup-preflight-error message))\n\
(define (preflight-cgroup-child probe path-present? mkdir-probe rmdir-probe)\n\
  (let ((created? #f))\n\
    (catch #t\n\
      (lambda ()\n\
        (when (path-present? probe)\n\
          (preflight-error \"cgroup write probe path already exists\"))\n\
        (catch 'system-error\n\
          (lambda () (mkdir-probe probe #o700) (set! created? #t))\n\
          (lambda _\n\
            (preflight-error\n\
             \"cannot create a child in the cgroup2 hierarchy\")))\n\
        (unless (path-present? (string-append probe \"/cgroup.procs\"))\n\
          (preflight-error \"cgroup2 child lacks cgroup.procs\"))\n\
        (catch 'system-error\n\
          (lambda () (rmdir-probe probe) (set! created? #f))\n\
          (lambda _\n\
            (preflight-error\n\
             \"cannot remove the cgroup2 write probe\"))))\n\
      (lambda (key . arguments)\n\
        ;; Error cleanup is best effort, but it cannot replace the exception\n\
        ;; that made this preflight fail.\n\
        (when created?\n\
          (catch 'system-error\n\
            (lambda () (rmdir-probe probe))\n\
            (lambda _ #f)))\n\
        (apply throw key arguments)))))\n\
(define (cgroup2-mounted?)\n\
  (call-with-input-file \"/proc/self/mountinfo\"\n\
    (lambda (input)\n\
      (let loop ()\n\
        (let ((line (read-line input)))\n\
          (cond ((eof-object? line) #f)\n\
                ((and (string-contains line \" /sys/fs/cgroup \" )\n\
                      (string-contains line \" - cgroup2 \")) #t)\n\
                (else (loop))))))))\n\
(define (mark-inherited-fds-close-on-exec)\n\
  (for-each\n\
   (lambda (name)\n\
     (let ((fd (string->number name)))\n\
       (when (and fd (> fd 2))\n\
         (catch 'system-error\n\
           (lambda ()\n\
             (let ((flags (fcntl fd F_GETFD)))\n\
               (unless (positive? (logand flags FD_CLOEXEC))\n\
                 (fcntl fd F_SETFD (logior flags FD_CLOEXEC)))))\n\
           (lambda arguments\n\
             (unless (= EBADF (system-error-errno arguments))\n\
               (apply throw 'system-error arguments)))))))\n\
   (scandir \"/proc/self/fd\"\n\
            (lambda (name) (and (string->number name) #t)))))\n\
(unless (= (getuid) 0) (fail \"execution spike requires guest-root runsc supervisor\"))\n\
(unless (and (cgroup2-mounted?)\n\
             (path-present? \"/sys/fs/cgroup/cgroup.controllers\"))\n\
  (fail \"declared cgroup2 hierarchy is not mounted at /sys/fs/cgroup\"))\n\
(let ((target (string-append cgroup-root cgroups-path)))\n\
  (when (path-present? target)\n\
    (fail (string-append \"refusing stale cgroup path: \" target))))\n\
(let ((probe (string-append cgroup-root \"/.wilkbook-preflight-\"\n\
                            (number->string (getpid)))))\n\
  (catch 'wilkbook-cgroup-preflight-error\n\
    (lambda ()\n\
      (preflight-cgroup-child probe path-present? mkdir rmdir))\n\
    (lambda (key message) (fail message))))\n\
(umask #o077)\n\
(for-each (lambda (signal-number) (sigaction signal-number SIG_DFL))\n\
          (list SIGINT SIGHUP SIGTERM SIGPIPE SIGCHLD))\n\
(mark-inherited-fds-close-on-exec)\n\
(environ supervisor-environment)\n\
(apply execl runsc argv)\n"
         port)))
    (chmod path #o400)))

(define (write-launch-wrapper path bundle)
  (call-with-output-file path
    (lambda (port)
      (format port
              "#!/bin/sh\nset -eu\numask 077\nexec ~a -i HOME=/nonexistent LANG=C LC_ALL=C PATH=/run/current-system/profile/bin ~a GUILE_AUTO_COMPILE=0 ~a --no-auto-compile -s ~a\n"
              (shell-quote env-program)
              (shell-quote (string-append "TMPDIR=" bundle "/supervisor-tmp"))
              (shell-quote guile-program)
              (shell-quote (string-append bundle "/launch.scm")))))
  (chmod path #o500))

(define* (generate-bundle #:key
                          profile-input
                          book-input
                          bundle-input
                          container-id
                          execution-profile
                          requisites-runner
                          (store-root default-store-root))
  (let* ((store (canonical-store-root store-root))
         (profile (validate-profile profile-input store))
         (closure
          (validate-requisites (requisites-runner profile) profile store))
         (book (validate-book book-input closure store)))
    (validate-profile-entry profile closure store "python3")
    (validate-profile-entry profile closure store "guile")
    (validate-container-id container-id)
    (profile-policy execution-profile)
    (let* ((bundle (validate-bundle-destination bundle-input store))
           (parent (dirname bundle))
           (parent-before (lstat parent))
           (created? #f)
           (bundle-identity #f))
      (catch #t
        (lambda ()
          ;; mkdir is the no-overwrite claim.  Re-check the private parent
          ;; identity before writing descendants.
          (mkdir-mode bundle #o700)
          (set! created? #t)
          (set! bundle-identity (lstat bundle))
          (let ((parent-after (lstat parent)))
            (unless (and (= (stat:dev parent-before) (stat:dev parent-after))
                         (= (stat:ino parent-before) (stat:ino parent-after)))
              (bundle-error "bundle parent identity changed before creation")))
          (let ((rootfs (string-append bundle "/rootfs")))
            (make-rootfs rootfs profile closure)
            (mkdir-mode (string-append bundle "/runsc-state") #o700)
            (mkdir-mode (string-append bundle "/supervisor-tmp") #o700)
            (mkdir-mode (string-append bundle "/runsc-debug") #o700)
            (mkdir-mode (string-append bundle "/runsc-panic") #o700)
            (let* ((spec (make-spec profile closure book container-id))
                   (launch-record
                    (make-launch-record bundle container-id execution-profile)))
              (write-json (string-append bundle "/config.json") spec)
              (write-json (string-append bundle "/launch.json") launch-record)
              (write-launcher (string-append bundle "/launch.scm") launch-record)
              (write-launch-wrapper (string-append bundle "/run.sh") bundle)))
          bundle)
        (lambda (key . arguments)
          (when created?
            (let ((current (lstat-or-false bundle)))
              (when (and current bundle-identity
                         (= (stat:dev current) (stat:dev bundle-identity))
                         (= (stat:ino current) (stat:ino bundle-identity)))
                (delete-created-tree bundle))))
          (apply throw key arguments))))))

(define cli-options
  '((profile (value #t))
    (book (value #t))
    (bundle (value #t))
    (container-id (value #t))
    (execution-profile (value #t))
    (guix (value #t))
    (help (single-char #\h))))

(define (usage port program)
  (format port
          "usage: ~a --profile PATH --book PATH --bundle PATH --execution-profile PROFILE [--container-id ID] [--guix PATH]\n"
          program))

(define (required-option options name program)
  (let ((value (option-ref options name #f)))
    (unless value
      (usage (current-error-port) program)
      (bundle-error (format #f "missing required --~a" name)))
    value))

(define (find-on-path name)
  (let loop ((directories (string-split (or (getenv "PATH") "") #\:)))
    (and (pair? directories)
         (let ((candidate (string-append (car directories) "/" name)))
           (if (and (lstat-or-false candidate) (access? candidate X_OK))
               candidate
               (loop (cdr directories)))))))

(define (oci-bundle-main argv)
  (let ((program (car argv)))
    (catch 'book-execution-bundle-error
      (lambda ()
        (let ((options (getopt-long argv cli-options)))
          (when (option-ref options 'help #f)
            (usage (current-output-port) program)
            (exit 0))
          (let* ((profile (required-option options 'profile program))
                 (book (required-option options 'book program))
                 (bundle (required-option options 'bundle program))
                 (execution-profile
                  (required-option options 'execution-profile program))
                 (container-id
                  (option-ref options 'container-id "wilkbook-python-smoke"))
                 (guix-input (or (option-ref options 'guix #f)
                                 (find-on-path "guix"))))
            (unless guix-input
              (bundle-error "guix not found; pass an absolute trusted --guix path"))
            (let* ((store (canonical-store-root default-store-root))
                   (guix (validate-guix guix-input store))
                   (result
                    (generate-bundle
                     #:profile-input profile
                     #:book-input book
                     #:bundle-input bundle
                     #:container-id container-id
                     #:execution-profile execution-profile
                     #:requisites-runner
                     (lambda (selected-profile)
                       (run-guix-requisites guix selected-profile))
                     #:store-root store)))
              (display result)
              (newline)
              0))))
      (lambda (key message)
        (format (current-error-port) "FAIL: ~a~%" message)
        1))))
