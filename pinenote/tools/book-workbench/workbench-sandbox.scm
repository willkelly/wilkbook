;;; Owned, one-shot Workbench execution through the fixed source-built runsc.
;;; Source is data until the donated ordinary session reaches the guest runner.
;;; No runtime override or native fallback is accepted by the public entrypoint.
(define-module (workbench-sandbox)
  #:use-module (workbench-preview)
  #:use-module (book-session)
  #:use-module (guest-book-protocol)
  #:use-module (guest-smoke)
  #:use-module (oci-bundle)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 threads)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (system foreign)
  #:export (preview-sandbox make-sandbox-preview))

(define (private module name) (module-ref (resolve-module module) name))
(define (preview name) (private '(workbench-preview) name))
(define (base name) (private '(guest-book-protocol) name))
(define (smoke name) (private '(guest-smoke) name))
(define (oci name) (private '(oci-bundle) name))
(define (fail message . args)
  (throw 'workbench-sandbox-error (apply format #f message args)))
(define (now) (/ (get-internal-real-time) internal-time-units-per-second 1.0))
(define clock-gettime
  (pointer->procedure int (dynamic-func "clock_gettime" (dynamic-link)) (list int '*)))
(define (monotonic-now)
  ;; Both supported hosts (x86_64 and aarch64) have 64-bit struct timespec.
  ;; Unlike Guile's process-relative clock, this deadline survives exec/spawn.
  (unless (= (sizeof long) 8) (fail "runtime owner requires a 64-bit Linux host"))
  (let ((out (make-bytevector 16 0)))
    (unless (zero? (clock-gettime 1 (bytevector->pointer out))) (fail "CLOCK_MONOTONIC unavailable"))
    (+ (bytevector-s64-native-ref out 0) (/ (bytevector-s64-native-ref out 8) 1000000000.0))))
(define (check-time! deadline)
  (when (>= (now) deadline) (fail "sandbox wall-clock timeout")))
(define (field value key) (assoc-ref value key))
(define (replace value key new)
  (map (lambda (entry) (if (equal? (car entry) key) (cons key new) entry)) value))
(define (close! port) ((preview 'close-quietly) port))
(define (exists path) ((preview 'exists) path))
(define (same? left right) ((base 'same-file-identity?) left right))
(define diagnostic-prefix "runsc-sandbox: ")
(define* (result status text diagnostic #:optional (started? #f) (cleaned? #f) (resources '()) (stderr #f))
  (let ((diagnostic (string-append diagnostic-prefix diagnostic)))
    `((status . ,status) (text . ,text)
      (execution-started? . ,started?) (cleanup-complete? . ,cleaned?)
      (resource-observations . ,resources)
      ,@(if stderr `((stderr-evidence . ,stderr)) '())
      (diagnostic . ,(substring diagnostic 0 (min 1024 (string-length diagnostic)))))))

;;; Strict data validation is independently exercised with a synthetic store.
;;; The public execution API has no store-root or validation bypass keyword.
(define (json-normal value)
  (cond
   ((vector? value) (list->vector (map json-normal (vector->list value))))
   ((list? value)
    (unless (and (every (lambda (entry) (and (pair? entry) (string? (car entry)))) value)
                 (= (length value) (length (delete-duplicates (map car value) string=?))))
      (fail "JSON object has malformed or duplicate keys"))
    (map (lambda (entry) (cons (car entry) (json-normal (cdr entry))))
         (sort value (lambda (a b) (string<? (car a) (car b))))))
   (else value)))
(define (read-owned-bytes path limit mode)
  (let ((port (fdopen (open-fdes path (logior O_RDONLY O_NONBLOCK O_NOFOLLOW O_CLOEXEC)) "rb")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((info (stat port)))
          (unless (and (eq? (stat:type info) 'regular) (= (stat:uid info) (getuid))
                       (= (stat:nlink info) 1) (= (logand (stat:mode info) #o7777) mode)
                       (<= 1 (stat:size info) limit))
            (fail "owned launch file type/owner/mode/size changed: ~a" path)))
        (let ((bytes (get-bytevector-n port (+ limit 1))))
          (unless (and (bytevector? bytes) (<= 1 (bytevector-length bytes) limit))
            (fail "owned launch file exceeds bound: ~a" path))
          bytes))
      (lambda () (close! port)))))
(define (read-owned-json path)
  (let ((text (utf8->string (read-owned-bytes path 262144 #o600))))
    (call-with-input-string text
      (lambda (port)
        (let ((value (json->scm port #:ordered #t)))
          (unless (string-null? (string-trim-both (get-string-all port)))
            (fail "trailing JSON input"))
          (json-normal value))))))

(define* (expected-spec bundle id profile closure sources #:key (editor? #f))
  ;; Inherit the accepted base namespace/device/root policy, independently spell
  ;; every Workbench delta. Whole-object comparison rejects extra mounts, hooks,
  ;; annotations, capabilities and environment entries, not just known bad ones.
  (let* ((spec (make-spec profile closure (string-append bundle "/program.scm") id))
         (process (field spec "process"))
         (linux (field spec "linux"))
         (mounts (map (lambda (mount)
                        (if (equal? (field mount "destination") "/book/input")
                            (replace mount "destination" "/book/program.scm") mount))
                      (vector->list (field spec "mounts")))))
    (set! mounts (append mounts
                        (map (lambda (source target)
                               ((oci 'bind-mount) source target #:noexec? #t))
                             sources '("/book/runner.scm" "/book/modules/book-protocol.scm"
                                       "/book/modules/book-protocol/blocking-io.scm"))))
    (set! process (replace process "args"
                          #("/profile/bin/guile" "--no-auto-compile" "-L" "/book/modules"
                            "/book/runner.scm" "--sandbox")))
    (set! process (replace process "env"
                          #("HOME=/scratch" "LANG=C.UTF-8" "LC_ALL=C.UTF-8" "PATH=/profile/bin"
                            "TMPDIR=/scratch" "BOOK_SESSION_FD=3" "GUILE_AUTO_COMPILE=0"
                            "GUILE_LOAD_PATH=/profile/share/guile/site/3.0"
                            "GUILE_LOAD_COMPILED_PATH=/profile/lib/guile/3.0/site-ccache")))
    (set! process (replace process "rlimits"
                          (list->vector
                           (append (vector->list (field process "rlimits"))
                                    (if editor? '()
                                        '((("type" . "RLIMIT_CPU") ("soft" . 10) ("hard" . 10))))
                                    '((("type" . "RLIMIT_NPROC") ("soft" . 32) ("hard" . 32)))))))
    (set! linux (cons '("resources" . (("memory" . (("limit" . 268435456)))
                                       ("cpu" . (("period" . 100000) ("quota" . 50000)))
                                        ("pids" . (("limit" . 256))))) linux))
    (replace (replace (replace spec "process" process) "linux" linux)
             "mounts" (list->vector mounts))))

(define (validate-rootfs! bundle profile closure)
  (let* ((root (string-append bundle "/rootfs"))
         (entries (append
                   (map (lambda (path) (list path 'directory #o755))
                        '("" "/gnu" "/gnu/store" "/book" "/proc" "/dev" "/scratch"
                          "/book/modules" "/book/modules/book-protocol"))
                   (map (lambda (path) (list path 'regular #o444))
                        '("/book/input" "/book/program.scm" "/book/runner.scm"
                          "/book/modules/book-protocol.scm"
                          "/book/modules/book-protocol/blocking-io.scm"))
                   (map (lambda (item)
                          (let ((type (stat:type (lstat item))))
                            (list ((oci 'container-store-path) item) type
                                  (if (eq? type 'directory) #o555 #o444)))) closure)
                   '(("/profile" symlink #f)))))
    (define (walk relative)
      (let* ((entry (assoc relative entries)) (path (string-append root relative))
             (info (lstat path)))
        (unless (and entry (eq? (stat:type info) (cadr entry))
                     (= (stat:uid info) (getuid))
                     (or (not (caddr entry)) (= (logand (stat:mode info) #o7777) (caddr entry))))
          (fail "rootfs placeholder changed: ~a" relative))
        (case (stat:type info)
          ((regular) (unless (and (= (stat:nlink info) 1) (= (stat:size info) 0))
                       (fail "rootfs placeholder is not empty/single-link")))
          ((symlink) (unless (equal? (readlink path) ((oci 'container-store-path) profile))
                       (fail "rootfs profile link changed")))
          ((directory)
           (let ((directory (opendir path)))
             (dynamic-wind
               (lambda () #t)
               (lambda ()
                 (let loop ()
                   (let ((name (readdir directory)))
                     (unless (eof-object? name)
                       (unless (member name '("." ".."))
                         (walk (string-append relative "/" name)))
                       (loop)))))
               (lambda () (closedir directory))))))))
    ;; Also detect missing required empty placeholders, not only unexpected ones.
    (for-each (lambda (entry)
                (unless (exists (string-append root (car entry)))
                  (fail "rootfs placeholder is missing: ~a" (car entry)))) entries)
    (walk "")))

(define* (validate-launch! bundle id bytes profile closure sources
                          #:optional (store "/gnu/store") #:key (editor? #f))
  (unless (boolean? editor?) (fail "editor variant must be boolean"))
  (when (and editor? (> (bytevector-length bytes) 8192))
    (fail "editor source exceeds 8192 bytes"))
  ((oci 'validate-container-id) id)
  (unless (equal? ((oci 'canonical-existing) bundle "private bundle") bundle)
    (fail "noncanonical bundle"))
  (let ((info (lstat bundle)))
    (unless (and (eq? (stat:type info) 'directory) (= (stat:uid info) (getuid))
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "bundle is not caller-owned mode 0700")))
  ;; Revalidate broker paths and closure; never trust launch.json to select them.
  ((oci 'validate-profile) profile store)
  ((oci 'validate-requisites) closure profile store)
  (for-each (lambda (name) ((oci 'validate-profile-entry) profile closure store name))
            '("guile" "python3"))
  (unless (and (= (length sources) 3)
               (= (length (delete-duplicates sources string=?)) 3))
    (fail "three distinct immutable adapter inputs required"))
  (for-each (lambda (path) ((preview 'immutable-source) path closure store)) sources)
  (let* ((snapshot (read-owned-bytes (string-append bundle "/program.scm") 16384 #o444))
         ;; Do not derive expected argv from the prepared record, or even from
         ;; Workbench's generator: add FD 3 to the accepted base run invocation.
         (argv (append-map (lambda (arg)
                             (if (string=? arg "run") '("run" "--pass-fd=3:3") (list arg)))
                           (make-launch-argv bundle id "isolation-userns")))
         (environment (list "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                            "PATH=/run/current-system/profile/bin"
                            (string-append "TMPDIR=" bundle "/supervisor-tmp")))
         (expected `(("argv" . ,(list->vector argv))
                      ("claim" . ,(if editor? "workbench-editor-preparation-only"
                                      "workbench-preview-preparation-only"))
                     ("cgroupsPath" . ,(string-append "/wilkbook-execution-" id))
                     ("executionProfile" . "isolation-userns")
                      ("fixtureKind" . ,(if editor? "workbench-guile-editor" "workbench-guile-preview"))
                      ("guestProtocolFd" . 3)
                     ("requiredKernelConfig" . #("CONFIG_USER_NS=y"))
                     ("sourceSha256" . ,((preview 'sha256-hex) bytes))
                     ("sourceBytes" . ,(bytevector-length bytes))
                     ("supervisorEnv" . ,(list->vector environment)) ("supervisorUid" . 0))))
    (unless (bytevector=? bytes snapshot) (fail "source snapshot differs from requested bytes"))
    (unless (equal? (read-owned-json (string-append bundle "/launch.json"))
                    (json-normal expected))
      (fail "launch record changed exact Workbench policy/source digest/environment/argv"))
    (unless (equal? (read-owned-json (string-append bundle "/config.json"))
                     (json-normal (expected-spec bundle id profile closure sources #:editor? editor?)))
      (fail "OCI configuration changed exact Workbench policy"))
    (validate-rootfs! bundle profile closure)
    (values argv environment)))

(define (trusted-program! path executable?)
  ;; Profiles may contain store symlinks, but their resolved program must be an
  ;; immutable regular store file. The caller, never authored text, selects it.
  (unless (and (string? path) (string-prefix? "/" path))
    (fail "trusted program must be an explicit absolute path"))
  (let* ((resolved ((oci 'canonical-existing) path "trusted supervisor input"
                    #:allow-input-symlink? #t)) (info (stat resolved)))
    ((oci 'store-item) resolved "/gnu/store" "trusted supervisor input")
    (unless (and (eq? (stat:type info) 'regular) (zero? (logand (stat:mode info) #o222))
                 (or (not executable?) (access? resolved X_OK)))
      (fail "trusted supervisor input must be immutable~a" (if executable? " and executable" "")))
    resolved))
(define (trusted-ancestry! path inspect)
  ;; An owned leaf is replaceable if an ancestor is writable by another user.
  ;; Permit root-owned sticky /tmp, whose sticky rule protects our root-owned
  ;; child; all other ancestors must be root-owned and non-group/world-writable.
  (let loop ((current path))
    (let ((info (inspect current)))
      (unless (and (eq? (stat:type info) 'directory) (= (stat:uid info) 0)
                   (or (zero? (logand (stat:mode info) #o022))
                       (and (string=? current "/tmp")
                            (positive? (logand (stat:mode info) #o1000)))))
        (fail "runtime path has replaceable/untrusted ancestor: ~a" current)))
    (unless (string=? current "/") (loop (dirname current)))))
(define (private-parent! path)
  ((oci 'canonical-existing) path "runtime parent")
  (trusted-ancestry! path lstat)
  (let ((info (lstat path)))
    (unless (and (< (string-length path) 256) (eq? (stat:type info) 'directory)
                 (= (stat:uid info) 0) (= (stat:gid info) 0)
                 (= (logand (stat:mode info) #o7777) #o700))
      (fail "runtime parent must be a root-owned mode-0700 canonical directory")))
  path)
(define (runtime-preflight! id)
  (unless (and (zero? (getuid)) (zero? (geteuid)) (zero? (getgid)))
    (fail "runsc sandbox requires the root supervisor"))
  (let ((runtime (trusted-program! "/run/current-system/profile/bin/runsc" #t)))
  (unless (exists "/proc/self/ns/user") (fail "CONFIG_USER_NS runtime support is absent"))
  ((base 'assert-cgroup2-preflight!) id)
  (let ((enabled (string-tokenize
                  (call-with-input-file "/sys/fs/cgroup/cgroup.subtree_control" get-string-all))))
    (unless (every (lambda (controller) (member controller enabled)) '("cpu" "memory" "pids"))
      (fail "cgroup2 cpu, memory and pids controllers must be enabled in root subtree_control")))
  runtime))

;;; Nonblocking capture uses the native fixture's acquisition-tested pipe and
;;; read syscall, with a separate runtime-log budget (debug runsc writes stderr).
(define capture-limit 262144)
(define-record-type <capture>
  (make-capture port bytes eof? tail chunks) capture?
  (port capture-port) (bytes capture-bytes set-capture-bytes!)
  (eof? capture-eof? set-capture-eof!) (tail capture-tail set-capture-tail!)
  ;; #f for stdout; reversed bounded chunks for stderr. No concatenation on
  ;; the pump path, and no growth after the first capture-limit bytes.
  (chunks capture-chunks set-capture-chunks!))
(define (pump-capture! capture)
  (unless (capture-eof? capture)
    (let ((bytes (make-bytevector 4096)))
      (call-with-values
          (lambda () ((preview 'c-read) (fileno (capture-port capture))
                      (bytevector->pointer bytes) 4096))
        (lambda (count errno)
          (cond ((zero? count) (set-capture-eof! capture #t))
                 ((positive? count)
                  (when (capture-chunks capture)
                    (let ((keep (min count (max 0 (- capture-limit (capture-bytes capture))))))
                      (when (positive? keep)
                        (let ((part (make-bytevector keep)))
                          (bytevector-copy! bytes 0 part 0 keep)
                          (set-capture-chunks! capture (cons part (capture-chunks capture)))))))
                  (set-capture-bytes! capture (+ count (capture-bytes capture)))
                 (let* ((old (capture-tail capture))
                        (keep (min 1024 count)) (prior (min (bytevector-length old) (- 1024 keep)))
                        (tail (make-bytevector (+ prior keep))))
                   (bytevector-copy! old (- (bytevector-length old) prior) tail 0 prior)
                   (bytevector-copy! bytes (- count keep) tail prior keep)
                   (set-capture-tail! capture tail))
                 (when (> (capture-bytes capture) capture-limit)
                   (fail "runsc stdout/stderr exceeded 256 KiB per-stream bound")))
                ((memv errno (list EINTR EAGAIN)) #f)
                 (else (fail "terminal runsc capture read failure"))))))))

(define (capture-evidence capture)
  ;; Failure-only O(captured bytes) assembly/selection after cleanup. This is
  ;; untrusted text, never a signal/exit-status or enforcement authority.
  (let* ((parts (reverse (capture-chunks capture)))
         (size (apply + (map bytevector-length parts)))
         (bytes (make-bytevector size)))
    (let loop ((parts parts) (offset 0))
      (unless (null? parts)
        (let ((n (bytevector-length (car parts))))
          (bytevector-copy! (car parts) 0 bytes offset n)
          (loop (cdr parts) (+ offset n)))))
    (let* ((text (bytevector->string bytes
                   (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace))))
           (lines (string-split text #\newline))
           ;; The severity/date prefix is only a display heuristic. Authored
           ;; text may imitate it; do not use this selection for any verdict.
           (selected (filter (lambda (line)
                               (not (and (>= (string-length line) 6)
                                         (char=? (string-ref line 0) #\D)
                                         (every char-numeric? (string->list (substring line 1 5)))
                                         (char=? (string-ref line 5) #\space)))) lines))
           (filtered (string-join selected "\n"))
           (fallback? (string-null? (string-trim-both filtered)))
           (selected (if fallback? text filtered))
           (truncated? (> (string-length selected) 8192)))
      `((captured-bytes . ,size) (observed-bytes . ,(capture-bytes capture))
        (capture-truncated? . ,(> (capture-bytes capture) size))
        (selection . ,(if fallback? 'all-lines-fallback 'non-debug-lines))
        (selection-truncated? . ,truncated?)
        (text . ,(if truncated?
                     (string-append (string-take selected 4096) "\n[...]\n"
                                    (string-take-right selected 4089))
                     selected))))))

(define (read-kernel-text path limit)
  (call-with-input-file path
    (lambda (port)
      (let ((text (get-string-n port (+ limit 1))))
        (unless (or (eof-object? text) (and (string? text) (<= (string-length text) limit)))
          (fail "kernel observation exceeds bound: ~a" path))
        (if (eof-object? text) "" (string-trim-both text))))))
(define observation-deadline (make-parameter #f))
(define (cgroup-disappeared? root identity deadline)
  ;; kernfs deactivates attributes before unlinking the directory. Only wait
  ;; after that exact ENODEV, never retry counter reads or accept a partial
  ;; sample. A persistent/replaced/inaccessible group still fails closed.
  (let loop ()
    (let ((current (exists root)))
      (cond ((not current) #t)
            ((not (same? current identity)) #f)
            ((>= (now) deadline) #f)
            (else
             (usleep (min 1000 (max 1 (inexact->exact (floor (* 1000000 (- deadline (now))))))))
             (loop))))))
(define* (observe-cgroup id #:optional (hierarchy "/sys/fs/cgroup"))
  ;; Trusted host observations, never inferred from guest allocation failure.
  ;; The first and latest live samples are retained. Names/counters alone do
  ;; not prove enforcement or full support-process accounting under every load.
  ;; HIERARCHY is private, for synthetic observation-parser tests only.
  (let ((root (string-append hierarchy "/wilkbook-execution-" id))
         (reading-controls? #f) (root-identity #f))
    (catch 'system-error
      (lambda ()
         (and (begin (set! root-identity (exists root)) root-identity)
             (let* ((names '("memory.max" "memory.current" "memory.events" "cpu.max" "cpu.stat"
                             "pids.max" "pids.current" "pids.events" "cgroup.procs"))
                    (files (begin
                             (set! reading-controls? #t)
                             (let ((files (map (lambda (name)
                                                (cons name (read-kernel-text (string-append root "/" name) 4096))) names)))
                               (set! reading-controls? #f)
                               files)))
                    (pids (string-tokenize (field files "cgroup.procs"))))
               (unless (<= (length pids) 256) (fail "cgroup member count exceeds 256"))
               `((sampled-at . ,(now))
                 (controls-match? . ,(and (equal? (field files "memory.max") "268435456")
                                          (equal? (field files "cpu.max") "50000 100000")
                                           (equal? (field files "pids.max") "256")))
                 (files . ,files)
                 (members . ,(map (lambda (pid)
                                    (unless (and (string->number pid)
                                                 (every char-numeric? (string->list pid)))
                                      (fail "malformed cgroup PID"))
                                    (let ((number (string->number pid)))
                                      `((pid . ,number)
                                        (start-time . ,((base 'read-process-start-time) number))
                                        (comm . ,(catch 'system-error
                                                   (lambda () (read-kernel-text
                                                               (string-append "/proc/" pid "/comm") 64))
                                                   (lambda _ "exited")))
                                        (executable . ,(catch 'system-error
                                                         (lambda () (readlink (string-append "/proc/" pid "/exe")))
                                                         (lambda _ #f)))
                                        (runsc-command . ,(catch 'system-error
                                                            (lambda ()
                                                              (let ((args (string-split
                                                                           (read-kernel-text
                                                                            (string-append "/proc/" pid "/cmdline") 16384)
                                                                           #\nul)))
                                                                (find (lambda (word) (member word '("boot" "gofer" "run"))) args)))
                                                            (lambda _ #f)))))) pids))))))
      (lambda args
        ;; kernfs_seq_start/file_read_iter return ENODEV if an opened node
        ;; loses its active reference during runsc's cgroup removal. Drop only
        ;; that incomplete control-file sample, after confirming the group is
        ;; absent. Allow at most 50 ms for the namespace unlink after kernfs
        ;; deactivation, within the original work deadline. An inaccessible,
        ;; replaced or still-present group fails; no control values are retried.
        ;; Metadata reads and other errors do not acquire this exception.
        (if (or (= (system-error-errno args) ENOENT)
                 (and reading-controls? (= (system-error-errno args) ENODEV)
                      (cgroup-disappeared? root root-identity
                                           (min (+ (now) 0.05)
                                                (or (observation-deadline) +inf.0)))))
            ;; ARGS already includes the exception key; preserve the errno's
            ;; original position for callers inspecting a non-vanishing error.
            #f (apply throw args))))))

;;; Linux mount calls avoid the older utility helper's independent 180-second
;;; timeout. These are cooperative deadline checks around kernel operations,
;;; like remove-owned-tree; a kernel-blocked syscall cannot be preempted here.
(define c-mount (pointer->procedure int (dynamic-func "mount" (dynamic-link))
                                   (list '* '* '* unsigned-long '*) #:return-errno? #t))
(define c-umount (pointer->procedure int (dynamic-func "umount2" (dynamic-link))
                                    (list '* int) #:return-errno? #t))
(define (unmount! path deadline)
  (check-time! deadline)
  (call-with-values (lambda () (c-umount (string->pointer path) 0))
    (lambda (status errno)
      (unless (zero? status) (fail "nonlazy unmount failed (~a): ~a" errno path)))))
(define (mount-diagnostic! store deadline)
  (check-time! deadline)
  (let ((options (format #f "size=~a,nr_inodes=~a,mode=0700,uid=0,gid=0"
                         ((@@ (guest-smoke) diagnostic-store-capacity-bytes) store)
                         (+ 1 ((@@ (guest-smoke) diagnostic-store-max-files) store)))))
    (call-with-values
        (lambda () (c-mount
                    (string->pointer ((@@ (guest-smoke) diagnostic-store-source) store))
                    (string->pointer ((@@ (guest-smoke) diagnostic-store-path) store))
                    (string->pointer "tmpfs") 14 (string->pointer options))) ; NOSUID|NODEV|NOEXEC
      (lambda (status errno)
        (unless (zero? status) (fail "diagnostic tmpfs mount failed (~a)" errno))))
    (unless ((smoke 'diagnostic-store-mounted?) store)
      (fail "diagnostic tmpfs verification failed"))))
(define (cleanup-diagnostic! store deadline)
  (let ((path ((@@ (guest-smoke) diagnostic-store-path) store)))
    (when (pair? ((base 'mountinfo-at) path))
      (unless ((smoke 'diagnostic-store-mounted?) store)
        (fail "diagnostic mount changed identity/policy"))
      (unmount! path deadline))
    (check-time! deadline)
    (unless (and (null? ((base 'mountinfo-at) path))
                 (same? (lstat path) ((@@ (guest-smoke) diagnostic-store-identity) store))
                 (null? ((base 'directory-entry-names) path)))
      (fail "diagnostic mountpoint did not return to owned empty directory"))
    (rmdir path)))

(define (cleanup-runtime! owner id executed? deadline)
  ;; Same null-netns ownership checks as guest-book-protocol, including the
  ;; authority namespace distinction and a nonlazy unmount. Also accept an
  ;; unchanged placeholder when runsc failed before installing its pin.
  (let* ((root ((@@ (guest-book-protocol) owned-runtime-state-root) owner))
         (pin ((@@ (guest-book-protocol) owned-runtime-state-pin) owner))
         (root-id ((@@ (guest-book-protocol) owned-runtime-state-root-identity) owner))
         (pin-id ((@@ (guest-book-protocol) owned-runtime-state-placeholder-identity) owner))
         (net-id ((@@ (guest-book-protocol) owned-runtime-state-authority-netns-identity) owner))
         (mounts ((base 'mountinfo-at) pin)))
    (check-time! deadline)
    (when (exists (string-append "/sys/fs/cgroup/wilkbook-execution-" id))
      (fail "runtime left stale cgroup"))
    (unless (and (same? (stat "/proc/self/ns/net") net-id)
                 ((base 'private-runtime-state-root?) (lstat root) root-id)
                 (null? ((base 'mountinfo-at) root))
                 (equal? ((base 'directory-entry-names) root) '("null-netns")))
      (fail "runtime state root/namespace/contents changed"))
    (when (pair? mounts)
      (unless (and executed? (= (length mounts) 1)
                   ((base 'expected-null-netns-mount?) (car mounts) (lstat pin) pin-id net-id))
        (fail "unexpected runtime null-netns mount"))
      (unmount! pin deadline))
    (check-time! deadline)
    (unless (and (null? ((base 'mountinfo-at) pin))
                 (null? ((base 'mountinfo-at) root))
                 ((base 'private-runtime-state-root?) (lstat root) root-id)
                 (equal? ((base 'directory-entry-names) root) '("null-netns"))
                 ((base 'owned-null-netns-placeholder?) (lstat pin) pin-id))
      (fail "runtime pin did not return to owned placeholder"))
    (delete-file pin) (rmdir root)))

(define (assert-tree-unmounted! root)
  (let ((prefix (string-append root "/")))
    (for-each
     (lambda (line)
       (let ((entry ((base 'parse-runtime-mountinfo-line) line)))
         (when entry
           (let ((point ((@@ (guest-book-protocol) runtime-mountinfo-point) entry)))
             (when (or (string=? point root) (string-prefix? prefix point))
               (fail "owned runtime tree still contains a mount: ~a" point))))))
     (string-split (call-with-input-file "/proc/self/mountinfo" get-string-all) #\newline))))

;;; One runtime owner, and the same process-wide subreaper mutex as the native
;;; fixture. No primitive-fork is performed in a potentially threaded authority.
(define (failure-diagnostic root failure cleanup-failure stderr)
  ;; Reserve space for BOTH failure stages before adding untrusted stderr.
  ;; Account for result's prefix. Keep the end of stderr rather than
  ;; clipping its final error a second time at the public 1024-character limit.
  (define (bounded text limit)
    (if (<= (string-length text) limit) text
        (string-append (substring text 0 (- limit 5)) "[...]")))
  (let* ((head (string-append
                (if cleanup-failure
                    (string-append "cleanup-incomplete; retained-root=" (bounded root 320) "; ") "")
                "failure=" (bounded (or failure "none (cleanup only)") 200)
                "; cleanup=" (bounded (or cleanup-failure "complete") 200)))
         (label "\nstderr-tail: ")
         (room (max 0 (- 1024 (string-length diagnostic-prefix)
                        (string-length head) (string-length label)))))
    (string-append head (if (string-null? stderr) ""
                           (string-append label (string-take-right stderr (min room (string-length stderr))))))))

(define (execute-bundle! root bundle id argv environment text guile adapter owner deadline work-deadline)
  (let ((endpoint #f) (donation #f) (ports '()) (captures '()) (root-identity (lstat root))
        (pid #f) (identity #f) (status #f) (reaped? #f) (adopted-reaped 0)
         (runtime #f) (stores '()) (executed? #f) (answer #f) (initialized? #f)
         (action-queued? #f) (action-dispatched? #f)
        (protocol-eof? #f) (failure #f) (cleanup-failure #f) (incomplete? #f) (owner-proof #f)
         (first-observation #f) (dispatch-observation #f) (last-observation #f) (next-observation 0)
        (old-subreaper ((preview 'subreaper?))))
    (define (remember! key args)
      (unless failure (set! failure (format #f "~a: ~s" key args))))
    (define (cleanup thunk)
      (catch #t thunk (lambda (key . args)
                       (set! incomplete? #t)
                       (unless cleanup-failure
                         (set! cleanup-failure (format #f "~a: ~s" key args))))))
    (define (own-pipe!)
      (let ((pair ((preview 'capture-pipe))))
        (set! ports (cons (car pair) (cons (cdr pair) ports))) pair))
    (define (pump-action!)
      (case (endpoint-pump-result-status (endpoint-pump-output! endpoint))
        ((drained budget would-block interrupted)
         ;; The final send can exhaust a pump budget before its empty-queue
         ;; check. Inspect the still-live endpoint immediately after this pump;
         ;; closed/error results or release-cleared queues are not delivery.
         (when action-queued?
           (let ((snapshot (host-session-snapshot endpoint)))
             (when (and (eq? (field snapshot "state") 'active)
                        (field snapshot "transport_open")
                        (zero? (field snapshot "outbound_frames"))
                        (zero? (field snapshot "outbound_bytes")))
               (set! action-dispatched? #t)))))
        (else (fail "ordinary session output failed"))))
    (define (observe!)
      (let ((sample (parameterize ((observation-deadline work-deadline))
                      (observe-cgroup id))))
        (when sample
          (unless first-observation (set! first-observation sample))
          (set! last-observation sample))
        (set! next-observation (+ (now) 0.05))
        sample))
    (define (reap!)
      (when pid
        ((preview 'require-owned-pid!) pid identity)
        (let loop ((budget 64))
          (when (positive? budget)
            (let ((waited ((preview 'wait-child) (- pid) WNOHANG)))
              (when (and waited (positive? (car waited)))
                (if (= (car waited) pid)
                    (begin (set! reaped? #t) (set! status (cdr waited)))
                    (set! adopted-reaped (+ adopted-reaped 1)))
                (loop (- budget 1))))))
        ;; The adapter may fail before setpgid, or still be entering its stop.
        (unless reaped?
          (let ((waited ((preview 'wait-child) pid WNOHANG)))
            (when (and waited (positive? (car waited)))
              (set! reaped? #t) (set! status (cdr waited)))))))
    (define (gone?) (and reaped? (not ((preview 'group-exists?) pid))))
    (define (owner-proof!)
      (when executed?
        (let* ((path (string-append bundle "/owner-result.scm"))
               (bytes (read-owned-bytes path 4096 #o600))
               (proof (call-with-input-string (utf8->string bytes) read)))
          (unless (and (equal? (field proof 'owner-pid) pid)
                       (equal? (field proof 'owner-start-time) identity)
                       (eq? (field proof 'children-empty?) #t))
            (fail "dedicated runtime owner did not prove exact descendant cleanup"))
          (set! owner-proof proof))))
    (define (stop!)
      (when pid
        (reap!)
        (unless (gone?)
          ;; The dedicated owner kills through the guest RPC and allows attached
          ;; Destroy. Forced pidfd termination withholds proof and retains state;
          ;; numeric-PID metadata must never be passed to delete --force after reap.
          ;; Do not kill that owner and lose its adopted-child ledger.
          (if executed?
              ((preview 'write-exclusive) (string-append bundle "/owner-stop") #vu8(49) #o600)
              ((preview 'signal-child!) pid SIGKILL identity))
          (let loop ()
            (reap!)
            ;; Drain pipes while controls/Destroy write their bounded diagnostics.
            (for-each (lambda (capture) (catch #t (lambda () (pump-capture! capture)) (lambda _ #f))) captures)
            (unless (gone?) (check-time! deadline) (usleep 1000) (loop))))
        (unless (gone?) (fail "dedicated runtime owner cleanup incomplete"))
        (owner-proof!)))
    (dynamic-wind
      (lambda () ((preview 'set-subreaper!) #t))
      (lambda ()
        (catch #t
          (lambda ()
            (check-time! work-deadline)
            (set! stores ((smoke 'diagnostic-stores) bundle))
            (for-each (lambda (store) (mount-diagnostic! store work-deadline)) stores)
            (set! runtime ((base 'prepare-owned-runtime-state!) bundle id))
            (call-with-values
                (lambda () (open-session-endpoint! (make-book-session-host) id))
              (lambda (e d) (set! endpoint e) (set! donation d)))
            (let* ((stdout (own-pipe!)) (stderr (own-pipe!))
                   (donation-id (stat donation)))
              (set! captures (list (make-capture (car stdout) 0 #f #vu8() #f)
                                    (make-capture (car stderr) 0 #f #vu8() '())))
              (check-time! work-deadline)
              (set! pid (spawn guile
                               (append (list guile "--no-auto-compile" adapter
                                             "--directory" bundle "--"
                                             guile "--no-auto-compile" owner "--guile" guile
                                             "--adapter" adapter "--deadline"
                                             (number->string (+ (monotonic-now) (max 0 (- deadline (now))))) "--") argv)
                               #:search-path? #f #:environment environment
                               #:input donation #:output (cdr stdout) #:error (cdr stderr)))
              (close! (cdr stdout)) (close! (cdr stderr))
              (close! donation) (set! donation #f)
              (when ((base 'open-fd-has-identity?) donation-id)
                (fail "parent retained donated Book Session endpoint")))
            (let wait-stop ()
              (check-time! work-deadline)
              (let ((waited ((preview 'wait-child) pid (logior WUNTRACED WNOHANG))))
                (cond ((and waited (zero? (car waited))) (usleep 1000) (wait-stop))
                      ((and waited (equal? (status:stop-sig (cdr waited)) SIGSTOP))
                       (set! identity ((base 'read-process-start-time) pid))
                       (unless identity (fail "stopped adapter has no process identity"))
                       ((base 'write-process-record!) (string-append bundle "/runsc.pid") pid identity pid)
                       (set! executed? #t) (kill pid SIGCONT))
                      (else
                       (when waited (set! reaped? #t) (set! status (cdr waited)))
                       (fail "FD adapter exited before ownership handshake")))))
            (let loop ()
              (check-time! work-deadline)
              (unless protocol-eof?
                (when (memq 'input (endpoint-ready-events endpoint))
                  (let ((pumped (endpoint-pump-input! endpoint)))
                    (case (endpoint-pump-result-status pumped)
                      ((committed)
                       (for-each
                        (lambda (value)
                          (cond
                           ((and (not initialized?) ((base 'exact-initialize?) value))
                            (set! initialized? #t)
                             (let ((sample (observe!)))
                               (unless (and sample (field sample 'controls-match?))
                                 (fail "live cgroup controls do not match requested memory/cpu/pids limits"))
                               (set! dispatch-observation sample))
                            (endpoint-queue-message! endpoint value)
                             (endpoint-queue-message! endpoint
                                                      (host-action! endpoint "workbench-preview" text))
                             (set! action-queued? #t))
                            ((and action-dispatched? (not answer) (presented-text? value)
                                 (equal? (presented-text-action-id value) "workbench-preview")
                                 (= (presented-text-sequence value) 1)
                                 (= (presented-text-surface-generation value) 1))
                            (set! answer (presented-text-value value))
                            ((preview 'bounded-text!) answer 4096 "preview result"))
                           (else (fail "unexpected ordinary preview session value"))))
                        (endpoint-pump-result-values pumped)))
                      ((eof closed)
                       (unless answer (fail "protocol EOF before preview result"))
                       (set! protocol-eof? #t))
                      ((would-block interrupted budget) #t)
                      (else (fail "ordinary session input failed"))))))
              (when (memq 'output (endpoint-ready-events endpoint))
                (pump-action!))
              (when (>= (now) next-observation) (observe!))
              (let ((before (map capture-bytes captures)))
              (for-each pump-capture! captures) (reap!)
              (when (and reaped? (not (equal? (status:exit-val status) 0)))
                (fail "runsc exited unsuccessfully"))
              ;; The dedicated owner's zero exit is provisional until its
              ;; PID/start-time-bound proof also establishes descendant cleanup.
              (unless (and answer protocol-eof? (gone?) (every capture-eof? captures))
                ;; One read per stream per iteration bounds work and leaves the
                ;; protocol/deadline checks between chunks. Sleep only on no progress.
                (when (equal? before (map capture-bytes captures)) (usleep 5000))
                (loop))))
            (let ((snapshot (host-session-snapshot endpoint)))
              (unless (and (eq? (field snapshot "state") 'closed)
                           (not (field snapshot "transport_open"))
                           (= (field snapshot "sequence") 1)
                           (= (field snapshot "pending_requests") 0)
                           (= (field snapshot "outbound_frames") 0))
                (fail "ordinary session did not reach exact closed state"))))
          (lambda (key . args)
            (remember! key args)
            (catch #t observe! (lambda _ #f)))))
      (lambda ()
        (cleanup (lambda () (when endpoint (release-session-endpoint! endpoint))))
        (cleanup (lambda () (close! donation)))
         (cleanup stop!)
         ;; A failed protocol may stop polling before the reaped runtime's last
         ;; writes are read. Harvest only immediately available bounded data;
         ;; never wait for diagnostic EOF or extend the owner's deadline.
         (for-each
          (lambda (capture)
            (let loop ((budget 65))
              (when (and (positive? budget) (< (now) deadline)
                         (not (capture-eof? capture)) (<= (capture-bytes capture) capture-limit))
                (let ((before (capture-bytes capture)))
                  (catch #t (lambda () (pump-capture! capture)) (lambda _ #f))
                  (when (> (capture-bytes capture) before) (loop (- budget 1))))))) captures)
         (for-each (lambda (port) (cleanup (lambda () (close! port)))) ports)
        (cleanup (lambda () ((preview 'set-subreaper!) old-subreaper)))
        ;; Unmount and delete only after exact process/descriptor cleanup. Keep
        ;; the whole owned root if anything remains uncertain, including mounts.
        (unless incomplete?
          (when runtime
            (cleanup (lambda () (cleanup-runtime! runtime id executed? deadline))))
          ;; Failed runtime cleanup preserves its bounded debug/panic mounts as
          ;; evidence too. Their ownership can be inspected from the retained root.
          (unless incomplete?
            (for-each (lambda (store) (cleanup (lambda () (cleanup-diagnostic! store deadline))))
                      (reverse stores))))
        (unless incomplete?
          (cleanup (lambda ()
                     (unless (same? (lstat root) root-identity)
                       (fail "runtime root identity changed before removal"))
                     (assert-tree-unmounted! root)
                     ((preview 'remove-owned-tree) root deadline))))))
    (let ((resources `((evidence . host-cgroup-samples)
                       (adopted-children-reaped . ,adopted-reaped)
                       (runtime-owner . ,owner-proof)
                        (first . ,first-observation) (dispatch . ,dispatch-observation)
                        (last . ,last-observation)
                       (enforcement-proven? . #f) (complete-support-accounting-proven? . #f))))
      (if (or failure incomplete?)
          (result 'failed "" (failure-diagnostic root failure cleanup-failure
                              (if (= (length captures) 2)
                                  (catch #t
                                    (lambda () (utf8->string (capture-tail (cadr captures))))
                                    (lambda _ "[non-UTF-8]")) ""))
                  action-dispatched? (not incomplete?) resources
                  (and (= (length captures) 2) (capture-evidence (cadr captures))))
          (result 'ok answer "ordinary protocol result, EOF, zero exit, bounded captures; runtime cleaned"
                  action-dispatched? #t resources)))))

(define* (preview-sandbox source text #:key profile runner protocol blocking closure requisites-runner
                          supervisor-guile fd-adapter runtime-owner runtime-parent (timeout-seconds 10))
  "Run one new-source, no-state ordinary Book Session in the fixed runsc.
All keyword inputs are trusted broker configuration. Supply exactly one of
CLOSURE (list of requisite store paths) or REQUISITES-RUNNER (profile -> list).
RUNTIME-PARENT must already be a canonical root-owned mode-0700 directory.
The 0 < timeout <= 30 seconds budget includes preparation, execution and cleanup;
the default is 10 seconds, reserving at most 3 seconds for cleanup. Trusted
closure callbacks and individual kernel/filesystem calls must return promptly.
Stdout/stderr each have a 256 KiB bound; neither is result authority. Incomplete
cleanup returns failed, retains the owned root, and names it in the diagnostic."
  (catch #t
    (lambda ()
      (unless (and (real? timeout-seconds) (> timeout-seconds 0) (<= timeout-seconds 30))
        (fail "timeout must be positive and at most 30 seconds"))
      (let ((mutex (preview 'native-mutex)))
        (unless (try-mutex mutex) (fail "another Workbench execution is active"))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (let* ((deadline (+ (now) timeout-seconds))
                   (work-deadline (- deadline (min 3 (/ timeout-seconds 3))))
                   (bytes ((preview 'source-bytes) source)) (root #f) (handed-off? #f))
              (catch #t
                (lambda ()
                  ((preview 'bounded-text!) text 2048 "preview input")
                  (unless (or (and closure (not requisites-runner) (list? closure))
                              (and (not closure) (procedure? requisites-runner)))
                    (fail "supply exactly one trusted closure or requisites-runner"))
                  (set! supervisor-guile (trusted-program! supervisor-guile #t))
                  (set! fd-adapter (trusted-program! fd-adapter #f))
                  (set! runtime-owner (trusted-program! runtime-owner #f))
                  (private-parent! runtime-parent)
                  (let* ((profile ((oci 'validate-profile) profile "/gnu/store"))
                         (closure ((oci 'validate-requisites)
                                   (or closure (requisites-runner profile)) profile "/gnu/store")))
                    (check-time! work-deadline)
                    (set! root (mkdtemp (string-append runtime-parent "/preview.XXXXXX")))
                    (chmod root #o700)
                    (let* ((bundle (string-append root "/bundle"))
                           (id (string-append "workbench-" (string-downcase (basename root)))))
                      (let ((runtime-program (runtime-preflight! id)))
                      (generate-workbench-preview-bundle
                       #:source bytes #:profile-input profile #:runner-input runner
                       #:protocol-input protocol #:blocking-input blocking #:bundle-input bundle
                       #:container-id id #:requisites-runner (lambda (_) closure)
                       #:cleanup-deadline deadline)
                      (check-time! work-deadline)
                      (call-with-values
                          (lambda () (validate-launch! bundle id bytes profile closure
                                                        (list runner protocol blocking)))
                        (lambda (argv environment)
                          (set! handed-off? #t)
                          ;; Metadata is validated against the policy alias;
                          ;; execution/control use its one pinned immutable target.
                          (execute-bundle! root bundle id (cons runtime-program (cdr argv)) environment text
                                           supervisor-guile fd-adapter runtime-owner deadline work-deadline)))))))
                (lambda (key . args)
                  ;; Before execution no mount or child can exist. Once handed
                  ;; off, the runtime owner alone decides whether deletion is safe.
                  (let ((retained? (and root handed-off?)))
                    (when (and root (not handed-off?))
                      (catch #t (lambda () ((preview 'remove-owned-tree) root deadline))
                        (lambda _ (set! retained? #t))))
                    (result 'failed ""
                            (string-append
                             (if retained? (string-append "cleanup-incomplete; retained-root=" root "; ") "")
                             (format #f "~a: ~s" key args))))))))
          (lambda () (unlock-mutex mutex)))))
    (lambda (key . args) (result 'failed "" (format #f "~a: ~s" key args)))))

(define (read-language-closure path)
  ;; %book-execution-language-closure writes one Scheme list, not line-oriented
  ;; guix gc output. Read data only, with a byte bound and no trailing forms.
  ;; The caller has pinned PATH to an immutable canonical store file. Requisite
  ;; path/profile validation remains in preview-sandbox before preparation.
  (let* ((limit 262144)
         (port (fdopen (open-fdes path (logior O_RDONLY O_NONBLOCK O_NOFOLLOW O_CLOEXEC)) "rb"))
         (bytes
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (unless (eq? (stat:type (stat port)) 'regular)
                (fail "language closure manifest is not a regular file"))
              (let ((bytes (get-bytevector-n port (+ limit 1))))
                (unless (and (bytevector? bytes) (<= 1 (bytevector-length bytes) limit))
                  (fail "language closure manifest must be 1..262144 UTF-8 bytes"))
                bytes))
            (lambda () (close! port)))))
    (call-with-input-string (utf8->string bytes)
      (lambda (input)
        (let ((value (read input)))
          (unless (and (list? value) (every string? value) (eof-object? (read input)))
            (fail "language closure manifest must contain exactly one Scheme list of strings"))
          value)))))

(define (make-sandbox-preview config)
  "Return the (source text) callback for trusted CONFIG. Keys: language-profile,
language-closure (list of requisite paths, or immutable UTF-8 store file containing
exactly one Scheme list of path strings, at most 262144 bytes), runner,
guile-protocol, blocking-protocol, supervisor-guile,
runsc-fd3-adapter, runtime-owner, runtime-parent, timeout-seconds (default 10, maximum 30).
The callback reports execution-started? only after valid live controls, queued
initialize/action frames, and an accepted output pump with an empty live queue
snapshot (host-observed socket delivery, not source completion), and
cleanup-complete? only after owned cleanup. resource-observations retains first
and latest live host cgroup samples; it makes no enforcement/accounting claim."
  (let* ((selected (field config 'language-closure))
         (closure (if (string? selected)
                      (begin
                        (set! selected (trusted-program! selected #f))
                        (read-language-closure selected))
                      selected)))
    (lambda (source text)
      (preview-sandbox source text
                       #:profile (field config 'language-profile) #:closure closure
                       #:runner (field config 'runner) #:protocol (field config 'guile-protocol)
                       #:blocking (field config 'blocking-protocol)
                       #:supervisor-guile (field config 'supervisor-guile)
                       #:fd-adapter (field config 'runsc-fd3-adapter)
                       #:runtime-owner (field config 'runtime-owner)
                       #:runtime-parent (field config 'runtime-parent)
                       #:timeout-seconds (or (field config 'timeout-seconds) 10)))))
