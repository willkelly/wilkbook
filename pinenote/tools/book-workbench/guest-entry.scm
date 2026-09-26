;;; Trusted, noninteractive QEMU composition. No authored source is loaded by
;;; this process; the injected callback owns sandbox execution.
(define-module (book-workbench-guest)
  #:use-module (workbench-sandbox)
  #:use-module (sandbox-scenario)
  #:use-module (resource-scenario)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (guest-main))

(define (private-directory! path)
  (unless (file-exists? path) (mkdir path #o700))
  (let ((info (lstat path)))
    (unless (and (string=? path (canonicalize-path path))
                 (eq? (stat:type info) 'directory)
                 (zero? (stat:uid info))
                 (= (logand (stat:mode info) #o7777) #o700))
      (error "Workbench directory is not private and root-owned" path))))

(define kernel-read
  (make-parameter (lambda (path) (call-with-input-file path get-string-all))))
(define kernel-write
  (make-parameter
   (lambda (path text)
     (call-with-output-file path
       (lambda (port) (display text port) (force-output port))))))

(define (mount-record root)
  (any
   (lambda (line)
     (let* ((parts (string-tokenize line))
            (separator (list-index (lambda (part) (string=? part "-")) parts)))
       (and separator (>= separator 6)
            (= (- (length parts) separator) 4)
            (string=? (list-ref parts 4) root)
            (list (list-ref parts (+ separator 1))
                  (append (string-split (list-ref parts 5) #\,)
                          (string-split (last parts) #\,))))))
   (string-split ((kernel-read) "/proc/self/mountinfo") #\newline)))

(define (require-workspace-mount! root)
  (let ((record (mount-record root)))
    (unless (and record (string=? (car record) "ext4")
                 (not (member "ro" (cadr record)))
                 (every (lambda (flag) (member flag (cadr record)))
                        '("rw" "noatime" "nodev" "nosuid" "noexec")))
      (error "Workbench requires the private ext4 workspace disk"))))

(define (prepare-cgroup-controllers!)
  ;; QEMU-only composition prerequisite. A cgroup2 mount alone leaves the
  ;; sandbox's children without resource controllers. Add only missing
  ;; controllers; never reset another service's existing root configuration.
  (let* ((root "/sys/fs/cgroup")
         (record (mount-record root))
         (required '("cpu" "memory" "pids")))
    (unless (and record (string=? (car record) "cgroup2")
                 (not (member "ro" (cadr record)))
                 (member "rw" (cadr record)))
      (error "Workbench requires a writable root cgroup2 mount"))
    (let* ((available (string-tokenize ((kernel-read) (string-append root "/cgroup.controllers"))))
           (control (string-append root "/cgroup.subtree_control"))
           (previous (string-tokenize ((kernel-read) control))))
      (unless (every (lambda (name) (member name available)) required)
        (error "Workbench CPU/memory/PID controllers are unavailable" available))
      (let ((missing (remove (lambda (name) (member name previous)) required)))
        (unless (null? missing)
          ((kernel-write) control
           (string-append (string-join (map (lambda (name) (string-append "+" name)) missing) " ")
                          "\n"))))
      (let ((enabled (string-tokenize ((kernel-read) control))))
        (unless (every (lambda (name) (member name enabled)) (append previous required))
          (error "Workbench controller enablement did not survive readback" enabled))))))

(define (observation-summary observations)
  ;; Project only fixed trusted counter files and process roles. Do not retain
  ;; command lines, comm/executable names, source, input, output or diagnostics.
  (define (sample-summary sample)
    (and sample
         (let* ((files (assoc-ref sample 'files))
                (members (take (or (assoc-ref sample 'members) '())
                               (min 64 (length (or (assoc-ref sample 'members) '())))))
                (truncated? #f)
                (counters
                 (map (lambda (name)
                        (let ((text (assoc-ref files name)))
                          (cons name
                                (if (string? text)
                                    (begin
                                      (when (> (string-length text) 256) (set! truncated? #t))
                                      (substring text 0 (min 256 (string-length text))))
                                    'unavailable))))
                      '("memory.max" "memory.current" "memory.events" "cpu.max"
                        "cpu.stat" "pids.max" "pids.current" "pids.events"))))
           `((controls-match? . ,(assoc-ref sample 'controls-match?))
             (counters . ,counters)
             (counter-text-truncated? . ,truncated?)
             (member-roles
              . ,(map (lambda (role)
                        (cons role
                              (count (lambda (member)
                                       (let ((command (assoc-ref member 'runsc-command)))
                                         (if (eq? role 'other)
                                             (not (member-command? command))
                                             (equal? command role))))
                                     members)))
                      '("boot" "gofer" "run" other)))))))
  (define (member-command? command) (member command '("boot" "gofer" "run")))
  (if (not (pair? observations))
      'unavailable
      `((evidence . host-cgroup-samples)
        (adopted-children-reaped . ,(assoc-ref observations 'adopted-children-reaped))
        (first . ,(sample-summary (assoc-ref observations 'first)))
        (dispatch . ,(sample-summary (assoc-ref observations 'dispatch)))
        (last . ,(sample-summary (assoc-ref observations 'last)))
        (enforcement-proven? . ,(assoc-ref observations 'enforcement-proven?))
        (complete-support-accounting-proven?
         . ,(assoc-ref observations 'complete-support-accounting-proven?)))))

(define (failure-evidence-record number result)
  ;; Only stderr is child-origin data here. Project before serialization, then
  ;; bound the escaped UTF-8 record too. Never display child text as console
  ;; lines, and never interpret a diagnostic marker as execution evidence.
  (let* ((evidence (assoc-ref result 'stderr-evidence))
         (owner (assoc-ref (or (assoc-ref result 'resource-observations) '()) 'runtime-owner)))
    (define (count-field key)
      (let ((value (assoc-ref evidence key)))
        (if (and (integer? value) (exact? value) (<= 0 value 1073741824)) value 'unknown)))
    (define (owner-flag key)
      (let ((value (and owner (assoc-ref owner key))))
        (if (and owner (boolean? value)) value 'unknown)))
    (and (list? evidence) (pair? evidence)
         (let* ((text (assoc-ref evidence 'text))
                (status (and owner (assoc-ref owner 'runtime-status)))
                (controls (and owner (assoc-ref owner 'controls)))
                (record
                 `((number . ,number) (evidence . untrusted-stderr-selection)
                   (captured-bytes . ,(count-field 'captured-bytes))
                   (observed-bytes . ,(count-field 'observed-bytes))
                   (capture-truncated? . ,(eq? (assoc-ref evidence 'capture-truncated?) #t))
                   (selection . ,(let ((value (assoc-ref evidence 'selection)))
                                   (if (memq value '(non-debug-lines all-lines-fallback)) value 'unknown)))
                   (selection-truncated? . ,(or (eq? (assoc-ref evidence 'selection-truncated?) #t)
                                               (and (string? text) (> (string-length text) 8192))))
                   ;; This is the owned host runsc wait status, not a guessed
                   ;; guest signal reason. Controls distinguish cancellation from
                   ;; spontaneous exit; neither attribute SIGKILL to RLIMIT_CPU.
                   (owner-runtime-wait-status . ,(if (and (integer? status) (exact? status)
                                                         (<= 0 status 65535)) status 'unknown))
                   (owner-stopped? . ,(owner-flag 'stopped?))
                   (owner-forced? . ,(owner-flag 'forced?))
                   (owner-control-count . ,(if (and (list? controls) (<= (length controls) 4))
                                              (length controls) 'unknown))
                   (text . ,(if (string? text) (string-take text (min 8192 (string-length text)))
                                "[stderr unavailable]"))))
                (serialized (format #f "~s" record)))
           (if (<= (bytevector-length (string->utf8 serialized)) 32768) record
               ;; Keep owner/counter evidence even when escaping child data
               ;; exceeds the final byte bound.
               (map (lambda (entry)
                      (cond ((eq? (car entry) 'text) '(text . "[escaped stderr record exceeded 32768 bytes]"))
                            ((eq? (car entry) 'selection-truncated?) '(selection-truncated? . #t))
                            (else entry))) record))))))

(define (observed-preview callback)
  (let ((number 0))
    (define (emit result)
      (define (flag name)
        (let ((entry (assq name result)))
          (if (and entry (boolean? (cdr entry))) (cdr entry) 'unknown)))
      (let* ((status (assoc-ref result 'status))
             (header `((number . ,number)
                       (status . ,(if (memq status '(ok failed exception)) status 'unknown))
                       (execution-started? . ,(flag 'execution-started?))
                       (cleanup-complete? . ,(flag 'cleanup-complete?))))
             (record (append header
                             `((resource-observations
                                . ,(observation-summary (assoc-ref result 'resource-observations)))))))
        ;; Escape all data via ~s. The bounded projection precedes formatting;
        ;; this last bound also accounts for escaping (at most 32 KiB UTF-8).
        (when (> (string-length (format #f "~s" record)) 8192)
          (set! record (append header '((resource-observations . record-bound-exceeded)))))
        (format #t "BOOK_WORKBENCH_PREVIEW: ~s~%" record)
        (force-output)))
    (lambda (source text)
      (set! number (+ number 1))
      (let ((result
             (catch #t
               (lambda () (callback source text))
               (lambda (key . arguments)
                 (emit '((status . exception)))
                 (apply throw key arguments)))))
        (emit result)
        ;; Failed preflight can be rejected by the scenario before its request
        ;; wrapper prints the reply. Retain that cause separately from resource
        ;; evidence. ~s escapes child-origin text; it cannot become a console
        ;; control line. Successful results never publish diagnostics.
        (when (eq? (assoc-ref result 'status) 'failed)
          (let* ((value (assoc-ref result 'diagnostic))
                 (diagnostic (if (string? value)
                                 (substring value 0 (min 1024 (string-length value)))
                                 "[diagnostic unavailable]")))
             (format #t "BOOK_WORKBENCH_PREVIEW_DIAGNOSTIC: ~s~%"
                     `((number . ,number) (diagnostic . ,diagnostic)))
             (force-output))
           (let ((record (failure-evidence-record number result)))
             (when record
               (format #t "BOOK_WORKBENCH_PREVIEW_STDERR: ~s~%" record)
               (force-output))))
        result))))

(define (guest-main config)
  (umask #o077)
  (catch #t
    (lambda ()
      (let* ((root (assoc-ref config 'workspace-root))
             (runtime (assoc-ref config 'runtime-parent)))
        (require-workspace-mount! root)
        (prepare-cgroup-controllers!)
        ;; A newly formatted ext4 root is 0755 and contains lost+found. The
        ;; authoring store receives a new empty subdirectory on every exercise;
        ;; retaining the disk retains previous runs without mixing their CAS.
        (chmod root #o700)
        (private-directory! root)
        (private-directory! runtime)
         (if (eq? (assoc-ref config 'scenario) 'editor)
             (begin
               (unless (zero? (system*
                               ;; The authority profile is Guile/SQLite-only.
                               ;; Python is already a pinned language-profile input.
                               (string-append (assoc-ref config 'language-profile) "/bin/python3")
                               "-I" "-S" (assoc-ref config 'editor-scenario)
                               (assoc-ref config 'supervisor-profile)
                               (canonicalize-path (assoc-ref config 'editor-command))
                               root runtime))
                 (error "sandboxed interactive editor scenario failed"))
               (format #t "BOOK_WORKBENCH_GUEST: status=pass~%")
               (force-output)
               '((status . pass)))
         (let* ((workspace (mkdtemp (string-append root "/exercise.XXXXXX")))
               (preview (observed-preview (make-sandbox-preview config)))
               (result
                (run-workbench-scenario!
                 workspace
                 (basename (canonicalize-path (assoc-ref config 'language-profile)))
                 preview)))
           (unless (and (eq? (assoc-ref result 'status) 'pass)
                       (integer? (assoc-ref result 'checks))
                       (positive? (assoc-ref result 'checks)))
             (error "Workbench scenario returned an unsuccessful result" result))
           ;; The canary is outside every sandbox mount and persists in the
           ;; workspace snapshot if the entire guest gate succeeds.
           (let ((canary (string-append workspace "/host-only-canary"))
                 (contents "Workbench authority private canary\n"))
             (call-with-output-file canary (lambda (port) (display contents port)))
             (chmod canary #o600)
             (run-resource-scenario!
              preview canary
              (lambda () (equal? (call-with-input-file canary get-string-all) contents))))
           (format #t "BOOK_WORKBENCH_GUEST: status=pass~%")
          (force-output)
           result))))
    (lambda (key . arguments)
      (format (current-error-port) "Workbench guest exception: ~s ~s~%" key arguments)
      (format #t "BOOK_WORKBENCH_GUEST: status=fail~%")
      (force-output)
      #f)))
