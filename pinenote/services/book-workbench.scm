(define-module (pinenote services book-workbench)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages book-workbench)
  #:use-module (pinenote services book-state-device)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:export (book-workbench-service-type
            book-workbench-language-profile
            book-workbench-language-closure
             book-workbench-supervisor-profile
             book-workbench-editor-command
             book-workbench-default-configuration))

;; Reuse the proven profiles as objects; a derivation gate additionally pins the
;; expensive kernel/runtime outputs. Neither profile grants workspace access.
(define %spike (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define book-workbench-language-profile
  (module-ref %spike '%book-execution-language-profile))
(define book-workbench-language-closure
  (module-ref %spike '%book-execution-language-closure))
(define book-workbench-supervisor-profile book-state-device-supervisor-profile)

;; Separate immutable executable for each long-lived authored execution. It
;; receives only a private cleanup channel, a source snapshot path, and the
;; donated BookProtocol socket on stdin. Configuration is not on that channel.
(define book-workbench-editor-command
  (program-file
   "wilkbook-book-workbench-editor-sandbox"
   #~(begin
       (sigaction SIGPIPE SIG_IGN)
       (set! %load-path
             (cons* #$book-workbench-modules
                    (string-append #$book-workbench-supervisor-profile "/share/guile/site/3.0")
                    %load-path))
       (setenv "GUILE_AUTO_COMPILE" "0")
       (primitive-load #$(file-append book-workbench-modules "/guest-book-protocol.scm"))
       (let ((arguments (cdr (command-line))))
         (unless (and (= (length arguments) 2) (string->number (car arguments)))
           (error "editor sandbox requires control FD and source snapshot"))
         (let ((result
                ((module-ref (resolve-interface '(workbench-editor-sandbox)) 'run-editor-sandbox)
                 (list (cons 'language-profile #$book-workbench-language-profile)
                       (cons 'language-closure #$book-workbench-language-closure)
                       (cons 'runner #$book-workbench-editor-runner)
                       (cons 'guile-protocol #$book-workbench-protocol)
                       (cons 'blocking-protocol #$book-workbench-blocking)
                       (cons 'runsc-fd3-adapter #$book-workbench-fd-adapter)
                       (cons 'runtime-owner #$book-workbench-runtime-owner)
                       (cons 'runtime-parent "/run/wilkbook-book-workbench")
                       (cons 'supervisor-guile
                             #$(file-append book-workbench-supervisor-profile "/bin/guile")))
                 (string->number (car arguments)) (cadr arguments))))
           ;; clean attests cleanup, not execution success. The coordinator must
           ;; consume this terminal outcome after clean before granting a ticket.
           (primitive-exit (if (and (eq? (assoc-ref result 'status) 'ok)
                                    (eq? (assoc-ref result 'cleanup-complete?) #t)) 0 1)))))))

;; Trusted composition settings only. No UI request or authored source can
;; select these paths. The disposable guest always requires its separate disk.
(define book-workbench-default-configuration
  '((workspace-root . "/var/lib/wilkbook-book-workbench")
    (runtime-parent . "/run/wilkbook-book-workbench")
    (scenario . authoring-resources)
    (timeout-seconds . 20)))

(define (guest-program config)
  (let ((root (assoc-ref config 'workspace-root))
        (runtime (assoc-ref config 'runtime-parent))
        (timeout (assoc-ref config 'timeout-seconds))
        (scenario (assoc-ref config 'scenario)))
    (unless (and (equal? root "/var/lib/wilkbook-book-workbench")
                 (equal? runtime "/run/wilkbook-book-workbench")
                  (integer? timeout) (<= 1 timeout 30)
                  (memq scenario '(authoring-resources editor)))
      (error "invalid trusted Workbench QEMU configuration" config))
    (program-file
     "wilkbook-book-workbench-guest"
     #~(begin
         ;; Establish this before loading the source-only lifetime owner or
         ;; sandbox module: initializing it under Guile's module-loader lock
         ;; can deadlock. Broken child transports must become caught errors.
         (sigaction SIGPIPE SIG_IGN)
         ;; Shepherd's default output goes to its logger once logging starts.
         ;; Like guest-smoke's explicit console port, bypass that logger for
         ;; trusted markers and bootstrap failures. Route before module loading
         ;; so even a load error is visible. Sandbox children still get their
         ;; own bounded stdout/stderr pipes from the runtime's spawn call.
         (let ((console (open-fdes "/dev/console"
                                   (logior O_WRONLY O_NOCTTY O_CLOEXEC))))
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (force-output (current-output-port))
               (force-output (current-error-port))
               (dup2 console 1)
               (dup2 console 2)
               (fcntl 1 F_SETFD 0)
               (fcntl 2 F_SETFD 0)
               (set-port-encoding! (current-output-port) "UTF-8")
               (set-port-encoding! (current-error-port) "UTF-8")
               (display "BOOK_WORKBENCH_BOOTSTRAP: console-ready\n")
               (force-output (current-output-port)))
             (lambda () (when (> console 2) (close-fdes console)))))
         ;; Explicit load order is required by the source-only lifetime owner;
         ;; resolve-interface alone is known to hang on this module in 3.0.9.
         (primitive-load
          #$(file-append book-workbench-modules "/guest-book-protocol.scm"))
         (primitive-load #$book-workbench-guest-entry)
         ((module-ref (resolve-module '(book-workbench-guest)) 'guest-main)
          (list
           (cons 'workspace-root #$root)
           (cons 'runtime-parent #$runtime)
            (cons 'timeout-seconds #$timeout)
            (cons 'scenario '#$scenario)
            (cons 'editor-command #$book-workbench-editor-command)
            (cons 'editor-scenario
                  #$(file-append book-workbench-editor-assets
                                 "/book-workbench-editor/sandbox-scenario.py"))
            (cons 'supervisor-profile #$book-workbench-supervisor-profile)
           (cons 'language-profile #$book-workbench-language-profile)
           (cons 'language-closure #$book-workbench-language-closure)
           (cons 'runner #$book-workbench-runner)
           (cons 'guile-protocol #$book-workbench-protocol)
           (cons 'blocking-protocol #$book-workbench-blocking)
           (cons 'runsc-fd3-adapter #$book-workbench-fd-adapter)
           (cons 'runtime-owner #$book-workbench-runtime-owner)
           (cons 'supervisor-guile
                 #$(file-append book-workbench-supervisor-profile "/bin/guile"))))
         ;; guest-main reports failure as a marker too. Halt is cleanup, never
         ;; the success oracle; the outer owner requires PASS and power-down.
         (sync)
         (force-output (current-output-port))
         (force-output (current-error-port))
         (execl "/run/current-system/profile/sbin/halt" "halt")))))

(define (workbench-shepherd-services config)
  (list
   (shepherd-service
    (provision '(book-workbench-guest))
    (requirement '(user-processes udev
                  file-system-/var/lib/wilkbook-book-workbench))
    (documentation "Exercise sandboxed Workbench authoring and halt this explicit QEMU test system.")
    (respawn? #f)
    (start
     #~(make-forkexec-constructor
        (list "/run/current-system/profile/bin/env" "-i"
              "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
              "PATH=/run/current-system/profile/bin"
              "GUILE_AUTO_COMPILE=0"
              (string-append "GUILE_LOAD_PATH=" #$book-workbench-modules ":"
                             #$book-workbench-supervisor-profile
                             "/share/guile/site/3.0")
              (string-append "GUILE_LOAD_COMPILED_PATH="
                             #$book-workbench-supervisor-profile
                             "/lib/guile/3.0/site-ccache")
              #$(file-append book-workbench-supervisor-profile "/bin/guile")
              "--no-auto-compile" "-s" #$(guest-program config))
        #:file-creation-mask #o077))
    (stop #~(make-kill-destructor)))))

(define book-workbench-service-type
  (service-type
   (name 'book-workbench-guest)
   (extensions
    (list (service-extension shepherd-root-service-type
                             workbench-shepherd-services)))
   (default-value book-workbench-default-configuration)
   (description "Explicit one-shot ARM64 QEMU Workbench experiment.")))
