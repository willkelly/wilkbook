;;; Static graph assertions; neither a build nor a sandbox runtime claim.
(use-modules (gnu services) (gnu services shepherd) (gnu system)
             (gnu system file-systems) (guix gexp) (guix grafts) (guix packages) (guix utils)
             (ice-9 match) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))
(define (check label value)
  (unless value (error "Workbench system check failed" label))
  (format #t "PASS: ~a~%" label))

;; Inspect the pinned gexp constructor without lowering it. Unlike the public
;; approximate view this retains file-like object identity, so swapping two
;; trusted inputs cannot pass merely because both appear in the closure.
(define (source-view value)
  (cond
   ((gexp? value)
    (apply ((@@ (guix gexp) gexp-proc) value)
           (map (lambda (reference)
                  (if (gexp-input? reference)
                      (source-view (gexp-input-thing reference))
                      '(*output*)))
                ((@@ (guix gexp) gexp-references) value))))
   ((pair? value) (cons (source-view (car value)) (source-view (cdr value))))
   (else value)))
(define repo
  (canonicalize-path (string-append (dirname (car (command-line))) "/../../..")))
(define (source-exact? input relative)
  (and (local-file? input) (not (local-file-recursive? input))
       (string=? (local-file-absolute-file-name input) (string-append repo "/" relative))))

(define (check-console-routing console-form)
  ;; Execute the actual service gexp in a fresh native Guile. Only the console
  ;; pathname is substituted with a private file; stdout/stderr initially point
  ;; to a different file, as they do when Shepherd supplies logging pipes.
  ;; This never opens the host console or loads the guest/runtime modules.
  (let* ((guile (string-append
                 (or (getenv "BOOK_WORKBENCH_SUPERVISOR")
                     "/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor")
                 "/bin/guile"))
         (timeout (or (getenv "BOOK_WORKBENCH_TIMEOUT")
                      "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/timeout"))
         (root (mkdtemp "/tmp/opencode/workbench-console-check.XXXXXX"))
         (console (string-append root "/console"))
         (logger (string-append root "/logger"))
         (script (string-append root "/bootstrap.scm"))
         (bad-module (string-append root "/failing-module.scm"))
         (passed? #f))
    (for-each
     (lambda (program)
       (unless (and (file-exists? program)
                    (string-prefix? "/gnu/store/" (canonicalize-path program))
                    (access? program X_OK))
         (error "console test needs native BOOK_WORKBENCH_SUPERVISOR and BOOK_WORKBENCH_TIMEOUT" program)))
     (list guile timeout))
    (chmod root #o700)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-output-file console (lambda (port) #t))
        (call-with-output-file bad-module
          (lambda (port) (write '(error "WORKBENCH_TEST_MODULE_LOAD_FAILURE") port)))
        (call-with-output-file script
          (lambda (port)
            (for-each
             (lambda (form) (write form port) (newline port))
             `((sigaction SIGPIPE SIG_IGN)
               (define actual-open-fdes open-fdes)
               (define console-test-fd #f)
               (define (open-fdes path flags)
                 (unless (and (string=? path "/dev/console")
                              (= flags (logior O_WRONLY O_NOCTTY O_CLOEXEC)))
                   (error "unexpected console acquisition"))
                 (set! console-test-fd (actual-open-fdes ,console flags))
                 console-test-fd)
               ,console-form
               (unless (and (= (fileno (current-output-port)) 1)
                            (= (fileno (current-error-port)) 2)
                            (string=? (port-encoding (current-output-port)) "UTF-8")
                            (string=? (port-encoding (current-error-port)) "UTF-8"))
                 (error "incorrect trusted stdout/stderr ports"))
               (unless (catch 'system-error
                         (lambda () (fcntl console-test-fd F_GETFD) #f)
                         (lambda args (= EBADF (system-error-errno args))))
                 (error "extra console descriptor remains open"))
               (display (string-append "STDOUT:" (string (integer->char 955)) "\n"))
               (force-output (current-output-port))
               (display (string-append "STDERR:" (string (integer->char 955)) "\n")
                        (current-error-port))
               (force-output (current-error-port))
               (primitive-load ,bad-module)))))
        (let* ((log-port (open-output-file logger))
               (pid
                (dynamic-wind
                  (lambda () #t)
                  (lambda ()
                    (spawn timeout
                           (list timeout "--kill-after=2" "10" guile "--no-auto-compile" script)
                           #:search-path? #f
                           #:environment (list "LANG=C" "LC_ALL=C" "GUILE_AUTO_COMPILE=0"
                                               (string-append "HOME=" root))
                           #:output log-port #:error log-port))
                  (lambda () (close-port log-port))))
               (status (cdr (waitpid pid)))
               (text (call-with-input-file console
                       (lambda (port) (set-port-encoding! port "UTF-8") (get-string-all port))))
               (lines (string-split text #\newline)))
          (check "fresh native bootstrap reaches its intentional module-load failure"
                 (equal? (status:exit-val status) 1))
          (check "bootstrap marker reaches the console as one raw unprefixed line"
                 (= 1 (count (lambda (line)
                               (string=? line "BOOK_WORKBENCH_BOOTSTRAP: console-ready")) lines)))
          (check "trusted fd 1/2 retain UTF-8 and the extra console descriptor closes"
                 (and (member (string-append "STDOUT:" (string (integer->char 955))) lines)
                      (member (string-append "STDERR:" (string (integer->char 955))) lines)))
          (check "module-loading errors are visible directly on the console"
                 (string-contains text "WORKBENCH_TEST_MODULE_LOAD_FAILURE"))
          (check "trusted bootstrap bypasses the inherited Shepherd-log channel"
                 (zero? (stat:size (lstat logger)))))
        (set! passed? #t))
      (lambda ()
        (if passed?
            (begin (for-each delete-file (list console logger script bad-module)) (rmdir root))
            (format (current-error-port) "Console routing fixture retained: ~a~%" root))))))

(parameterize ((%current-target-system "aarch64-linux-gnu") (%graft? #f))
  (let* ((interface (resolve-interface '(pinenote systems pinenote-book-workbench)))
         (os (module-ref interface 'pinenote-book-workbench-operating-system))
         (base (module-ref
                (resolve-interface '(pinenote systems pinenote-book-execution-spike))
                'pinenote-book-execution-spike-operating-system))
         (services (operating-system-user-services os))
         (names (map (lambda (item) (service-type-name (service-kind item))) services))
         (fs (car (operating-system-file-systems os)))
         (service-module (resolve-module '(pinenote services book-workbench)))
         (shepherd
          (car ((module-ref service-module 'workbench-shepherd-services)
                (module-ref service-module 'book-workbench-default-configuration)))))
    (check "exact USER_NS kernel and initrd objects reused"
           (and (eq? (operating-system-kernel os) (operating-system-kernel base))
                (eq? (operating-system-initrd os) (operating-system-initrd base))))
    (check "one Workbench gate; old smoke and stale manifest absent"
           (and (= 1 (count (lambda (name) (eq? name 'book-workbench-guest)) names))
                (not (memq 'book-execution-guest-smoke names))
                (not (memq 'book-execution-language-profile names))))
    (check "source-built runtime selected exactly once"
           (and (= 1 (count (lambda (package)
                             (string=? (package-name package) "gvisor-source-built"))
                           (operating-system-packages os)))
                (not (find (lambda (package) (string=? (package-name package) "gvisor-bin"))
                           (operating-system-packages os)))))
    (check "mandatory private ext4 disk; inherited root/cgroup graph retained"
           (and (equal? (cdr (operating-system-file-systems os))
                        (operating-system-file-systems base))
                (string=? (file-system-mount-point fs) "/var/lib/wilkbook-book-workbench")
                (equal? (file-system-device fs) (file-system-label "WBWorkbenchV1"))
                (string=? (file-system-type fs) "ext4")
                (equal? (file-system-flags fs) '(no-atime no-dev no-suid no-exec))
                (not (file-system-mount-may-fail? fs))))
    (check "single non-respawning service waits for mounted workspace"
           (and (not (shepherd-service-respawn? shepherd))
                (memq 'file-system-/var/lib/wilkbook-book-workbench
                      (shepherd-service-requirement shepherd))))
    (let* ((program ((module-ref service-module 'guest-program)
                     (module-ref service-module 'book-workbench-default-configuration)))
           (body (source-view (program-file-gexp program)))
           (package-module (resolve-interface '(pinenote packages book-workbench)))
           (inputs
            (map (lambda (form)
                   (match form
                     (('cons ('quote key) value) (cons key value))
                     (_ (error "unexpected trusted guest configuration form" form))))
                 (cdr (cadr (list-ref body 5))))))
      (check "SIGPIPE is ignored before source-only module loading"
             (and (eq? (car body) 'begin)
                  (equal? (cadr body) '(sigaction SIGPIPE SIG_IGN))
                  (eq? (car (list-ref body 3)) 'primitive-load)))
      (check "trusted console setup precedes both runtime module loads"
             (match (list-ref body 2)
               (('let (('console ('open-fdes "/dev/console"
                                            ('logior 'O_WRONLY 'O_NOCTTY 'O_CLOEXEC)))) rest ...) #t)
               (_ #f)))
      (check-console-routing (list-ref body 2))
      (check "trusted callback configuration has the complete exact key roster"
             (equal? (map car inputs)
                      '(workspace-root runtime-parent timeout-seconds scenario
                        editor-command editor-scenario supervisor-profile
                       language-profile language-closure runner guile-protocol
                        blocking-protocol runsc-fd3-adapter runtime-owner supervisor-guile)))
      (let* ((command (assoc-ref inputs 'editor-command))
             (assets (module-ref package-module 'book-workbench-editor-assets))
             (asset-body (source-view (computed-file-gexp assets)))
             (files (cadr (last (last asset-body))))
             (command-body (source-view (program-file-gexp command)))
             (terminal (last (last command-body)))
             (invocation (match terminal
                           (('let (('result invocation)) verdict) invocation)
                           (_ (error "editor terminal verdict wrapper changed"))))
             (configuration (cdr (cadr invocation)))
             (scenario (assoc-ref inputs 'editor-scenario))
             (supervisor (module-ref service-module 'book-workbench-supervisor-profile))
             (bindings
              (map (lambda (form)
                     (match form
                       (('cons ('quote key) value) (cons key value))
                       (_ (error "unexpected editor sandbox configuration" form)))) configuration)))
        (check "interactive coordinator assets are copied from exact canonical source files"
               (and (equal? (map car files)
                            '("book-workbench-editor/native-editor.py"
                              "book-workbench-editor/editor-authority.scm"
                              "book-workbench-editor/editor-seed.scm"
                              "book-workbench-editor/workspace-protocol.scm"
                              "book-workbench-editor/workspace-delegate.scm"
                              "book-workbench-editor/editor-surface.scm"
                              "book-workbench-editor/workbench-editor-runner.scm"
                              "book-workbench-editor/sandbox-scenario.py"
                              "book-workbench-editor/plugin/bookworkbencheditor.koplugin/main.lua"
                              "book-workbench-editor/plugin/bookworkbencheditor.koplugin/_meta.lua"
                              "book-workbench-editor/plugin/bookworkbencheditor.koplugin/editor_channel.lua"
                              "book-workbench-editor/plugin/bookworkbencheditor.koplugin/editor_codec.lua"
                              "book-workbench/book-workspace.scm"
                              "book-workbench/schema-workspace-v1.sql"
                              "book-workbench/desktop-reader.lua"
                              "book-protocol/book_protocol.py"
                              "book-protocol/book-protocol.scm"
                              "book-protocol/book-protocol/blocking-io.scm"))
                    (every (lambda (entry)
                             (source-exact? (cadr entry) (string-append "pinenote/tools/" (car entry))))
                           files)))
        (check "interactive command has closed trusted inputs and selects only the editor runner"
               (and (eq? command (module-ref service-module 'book-workbench-editor-command))
                    (equal? (map car bindings)
                            '(language-profile language-closure runner guile-protocol blocking-protocol
                              runsc-fd3-adapter runtime-owner runtime-parent supervisor-guile))
                    (eq? (assoc-ref bindings 'runner)
                         (module-ref package-module 'book-workbench-editor-runner))
                    (source-exact? (assoc-ref bindings 'runner)
                                   "pinenote/tools/book-workbench-editor/workbench-editor-runner.scm")
                    (every (lambda (key) (eq? (assoc-ref bindings key) (assoc-ref inputs key)))
                           '(language-profile language-closure guile-protocol blocking-protocol
                             runsc-fd3-adapter runtime-owner))
                    (equal? (assoc-ref bindings 'runtime-parent) "/run/wilkbook-book-workbench")))
        (check "packaged terminal status requires execution success and complete cleanup"
               (equal? (last terminal)
                       '(primitive-exit (if (and (eq? (assoc-ref result 'status) 'ok)
                                                (eq? (assoc-ref result 'cleanup-complete?) #t)) 0 1))))
        (check "editor scenario and both supervisor paths retain exact packaged identities"
               (let ((guile (assoc-ref bindings 'supervisor-guile)))
                 (and (file-append? scenario) (eq? (file-append-base scenario) assets)
                      (equal? (file-append-suffix scenario) '("/book-workbench-editor/sandbox-scenario.py"))
                      (eq? (assoc-ref inputs 'supervisor-profile) supervisor)
                      (file-append? guile) (eq? (file-append-base guile) supervisor)
                      (equal? (file-append-suffix guile) '("/bin/guile"))))))
      (let ((spike (resolve-module '(pinenote systems pinenote-book-execution-spike)))
            (supervisor (assoc-ref inputs 'supervisor-guile)))
        (check "callback retains the existing language closure and supervisor executable"
               (and (eq? (assoc-ref inputs 'language-profile)
                         (module-ref spike '%book-execution-language-profile))
                    (eq? (assoc-ref inputs 'language-closure)
                         (module-ref spike '%book-execution-language-closure))
                    (file-append? supervisor)
                    (eq? (file-append-base supervisor)
                         (module-ref (resolve-interface '(pinenote services book-state-device))
                                     'book-state-device-supervisor-profile))
                    (equal? (file-append-suffix supervisor) '("/bin/guile")))))
      (let ((lifetime (cadr (list-ref body 3)))
            (entry (cadr (list-ref body 4))))
        (check "source-only lifetime owner and guest entry load from exact packaged inputs"
               (and (file-append? lifetime)
                    (eq? (file-append-base lifetime)
                         (module-ref package-module 'book-workbench-modules))
                    (equal? (file-append-suffix lifetime) '("/guest-book-protocol.scm"))
                    (eq? entry (module-ref package-module 'book-workbench-guest-entry))
                    (source-exact? entry "pinenote/tools/book-workbench/guest-entry.scm"))))
      (for-each
       (lambda (entry)
         (match entry
           ((key export relative)
            (let ((input (assoc-ref inputs key)))
              (check (format #f "immutable ~a is bound to its exact packaged source" key)
                     (and (eq? input (module-ref package-module export))
                          (source-exact? input relative)))))))
       '((runner book-workbench-runner "pinenote/tools/book-workbench/workbench-runner.scm")
         (guile-protocol book-workbench-protocol "pinenote/tools/book-protocol/book-protocol.scm")
         (blocking-protocol book-workbench-blocking "pinenote/tools/book-protocol/book-protocol/blocking-io.scm")
         (runsc-fd3-adapter book-workbench-fd-adapter "pinenote/tools/book-state-guest/runsc-fd3-exec.scm")
         (runtime-owner book-workbench-runtime-owner "pinenote/tools/book-workbench/workbench-runtime-owner.scm")))
      (let* ((modules (module-ref package-module 'book-workbench-modules))
             (union-body (source-view (computed-file-gexp modules)))
             (files
              (filter-map
               (lambda (form)
                 (match form
                   (('let (('source source) ('target target)) rest ...) (cons target source))
                   (_ #f)))
               (cdr union-body)))
             (expected
              '(("book-workspace.scm" . "book-workbench/book-workspace.scm")
                ("schema-workspace-v1.sql" . "book-workbench/schema-workspace-v1.sql")
                ("workbench-authority.scm" . "book-workbench/workbench-authority.scm")
                ("workbench-preview.scm" . "book-workbench/workbench-preview.scm")
                 ("workbench-sandbox.scm" . "book-workbench/workbench-sandbox.scm")
                 ("workbench-editor-sandbox.scm" . "book-workbench/workbench-editor-sandbox.scm")
                 ("sandbox-scenario.scm" . "book-workbench/sandbox-scenario.scm")
                 ("resource-scenario.scm" . "book-workbench/resource-scenario.scm")
                ("book-session.scm" . "book-session/book-session.scm")
                ("book-protocol.scm" . "book-protocol/book-protocol.scm")
                ("book-protocol/blocking-io.scm" . "book-protocol/book-protocol/blocking-io.scm")
                ("guest-smoke.scm" . "book-execution-spike/guest-smoke.scm")
                ("guest-book-protocol.scm" . "book-execution-spike/guest-book-protocol.scm")
                ("oci-bundle.scm" . "book-execution-spike/oci-bundle.scm")
                ("oci-book-bundle.scm" . "book-state-guest/oci-state-book-bundle.scm")
                ("guest-virtio-book-ui.scm" . "book-execution-spike/guest-virtio-book-ui.scm")
                ("private-control.scm" . "book-state-reader/private-control.scm"))))
        (check "module union has exactly the canonical module/source bindings"
               (and (equal? (map car files) (map car expected))
                    (every (lambda (entry)
                             (source-exact? (assoc-ref files (car entry))
                                            (string-append "pinenote/tools/" (cdr entry))))
                           expected))))
      (check "runtime owner imports only its declared Guile-standard dependencies"
             (equal? (call-with-input-file
                         (local-file-absolute-file-name (assoc-ref inputs 'runtime-owner)) read)
                     '(use-modules (ice-9 ftw) (rnrs bytevectors)
                                   (rnrs io ports) (srfi srfi-1) (system foreign)))))
     (let* ((editor (module-ref interface 'pinenote-book-workbench-editor-operating-system))
            (editor-services (operating-system-user-services editor))
            (editor-config
             (service-value
              (find (lambda (item) (eq? (service-type-name (service-kind item))
                                       'book-workbench-guest)) editor-services))))
       (check "editor QEMU changes only the trusted scenario, retaining kernel/runtime/disk graph"
              (and (equal? (assoc-ref editor-config 'scenario) 'editor)
                   (eq? (operating-system-kernel editor) (operating-system-kernel os))
                   (equal? (operating-system-packages editor) (operating-system-packages os))
                   (equal? (operating-system-file-systems editor) (operating-system-file-systems os))
                   (equal? (remove (lambda (entry) (eq? (car entry) 'scenario)) editor-config)
                           (remove (lambda (entry) (eq? (car entry) 'scenario))
                             (module-ref service-module 'book-workbench-default-configuration))))))
     (check "guest arguments retain hardware-form boot config for authenticated outer translation"
           (equal? (operating-system-user-kernel-arguments os)
                   (operating-system-user-kernel-arguments base)))))
