;;; Native focused test of the production authority's durable and lifetime
;;; seams.  It uses the real fixed Guile book over donated FD 3 and the exact
;;; accepted child owner, replacing only the unavailable AArch64 runsc exec.
(use-modules (book-session)
             (book-state-device-authority)
             (book-state-protocol)
             (book-state-reader-bridge)
             (guest-virtio-book-ui)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (ice-9 threads)
             (private-control)
             (rnrs bytevectors)
             (sqlite3)
             (srfi srfi-1))

(define (required-environment name)
  (or (getenv name) (error "missing authority runtime test input" name)))
(define modules (required-environment "BOOK_STATE_DEVICE_MODULES"))
(define supervisor-guile (required-environment "BOOK_STATE_DEVICE_GUILE"))
(define language-profile
  (required-environment "BOOK_STATE_DEVICE_LANGUAGE_PROFILE"))
(define language-closure
  (required-environment "BOOK_STATE_DEVICE_LANGUAGE_CLOSURE"))
(define guile-boundary
  (required-environment "BOOK_STATE_DEVICE_GUILE_BOUNDARY"))
(define python-boundary
  (required-environment "BOOK_STATE_DEVICE_PYTHON_BOUNDARY"))
(define runsc-adapter (required-environment "BOOK_STATE_DEVICE_ADAPTER"))
(define guile-book (required-environment "BOOK_STATE_DEVICE_GUILE_BOOK"))
(define python-book (required-environment "BOOK_STATE_DEVICE_PYTHON_BOOK"))
(define guile-protocol
  (required-environment "BOOK_STATE_DEVICE_GUILE_PROTOCOL"))
(define blocking-protocol
  (required-environment "BOOK_STATE_DEVICE_BLOCKING_PROTOCOL"))
(define python-protocol
  (required-environment "BOOK_STATE_DEVICE_PYTHON_PROTOCOL"))

(define authority-module (resolve-module '(book-state-device-authority)))
(define (authority name) (module-ref authority-module name))
(define (set-authority! name value) (module-set! authority-module name value))
(define production-run-sandbox-session! (authority 'run-sandbox-session!))
(define production-base-private (authority 'base-private))
(define production-smoke-private (authority 'smoke-private))
(define production-generate-fixed-bundle! (authority 'generate-fixed-bundle!))
(define production-spawn-owned-runsc! (authority 'spawn-owned-runsc!))
(define production-read-device-closure (authority 'read-device-language-closure))
(define (base-private name) ((authority 'base-private) name))
(define (smoke-private name) ((authority 'smoke-private) name))
(define (base-record name) ((authority 'base-record) name))
(define (peer-value peer name) ((authority 'peer-value) peer name))
(define (set-peer-value! peer name value)
  ((authority 'set-peer-value!) peer name value))
(define (child-value child name) ((authority 'child-value) child name))
(define (field value name) ((authority 'field) value name))
(define (fail message . values) (apply error message values))
(define (assert value message . details)
  (unless value (apply fail message details)))

(define test-root
  (required-environment "BOOK_STATE_DEVICE_RUNTIME_TEST_ROOT"))
(unless (and (file-exists? test-root)
             (eq? (stat:type (lstat test-root)) 'directory)
             (null? (scandir test-root
                             (lambda (name) (not (member name '("." "..")))))))
  (error "authority runtime test root is not an empty directory" test-root))
(chmod test-root #o700)
(define state-root (string-append test-root "/state"))
(define activation-file (string-append state-root "/enabled"))
(define database-path (string-append state-root "/book-state-v1.sqlite"))
(define runtime-root (string-append test-root "/run"))
(define socket-path (string-append runtime-root "/control.sock"))
(mkdir state-root #o700)
(call-with-output-file activation-file
  (lambda (port) (display "enabled\n" port)))
(chmod activation-file #o600)

(for-each
 (lambda (entry) (set-authority! (car entry) (cdr entry)))
 `((state-root . ,state-root)
   (activation-file . ,activation-file)
   (database-path . ,database-path)
   (runtime-root . ,runtime-root)
   (socket-path . ,socket-path)
   (interaction-budget-seconds . 20.0)
   (ui-phase-timeout-seconds . 5.0)
   (operation-timeout-seconds . 5.0)))

(define (make-config language)
  `((book-language . ,language)
    (authority-uid . ,(getuid))
    (authority-gid . ,(getgid))
    (koreader-luajit . ,(canonicalize-path supervisor-guile))
    (supervisor-guile . ,supervisor-guile)
    (runsc-fd3-adapter . ,runsc-adapter)
    (language-profile . ,language-profile)
    (language-closure . ,language-closure)
    (boundary-probe . ,guile-boundary)
    (python-boundary-probe . ,python-boundary)
    (guile-book . ,guile-book)
    (python-book . ,python-book)
    (guile-protocol . ,guile-protocol)
    (blocking-protocol . ,blocking-protocol)
    (python-protocol . ,python-protocol)))

(define guile-text "Attended note — human callback λ\nsecond line")
(define python-text "Python runner note — fixed FD 3 boundary")
(define session-records '())
(define sessions-until-stop 0)

(define (test-run-session! runtime control config session-root deadline language)
  (let* ((selected ((authority 'profile) language))
         (label ((authority 'profile-field) selected 'label))
         (book-host
          (open-reader-book-host!
           runtime
           ((authority 'profile-field) selected 'book-revision)
           ((authority 'profile-field) selected 'instance-id)
           'read-write))
         (host (reader-book-session-host book-host))
         (peer #f)
         (world #f)
         (child #f)
         (endpoint #f)
         (released? #f)
         (stop-details #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (open-session-endpoint! host label))
          (lambda (new-endpoint donation)
            (set! endpoint new-endpoint)
            (set! peer ((base-record 'make-protocol-peer)
                        label endpoint donation #f 'state '() 0))))
        (when (eq? language 'python)
          (symlink python-protocol (string-append session-root "/book_protocol.py")))
        (let* ((donation (peer-value peer 'protocol-peer-donation))
               (donation-identity (stat donation))
               (environment
                (list "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                      "PATH=/usr/bin:/bin" "GUILE_AUTO_COMPILE=0"
                      "BOOK_SESSION_FD=3"
                      (string-append "GUILE_LOAD_PATH=" modules ":"
                                     (dirname (dirname supervisor-guile))
                                     "/share/guile/site/3.0")
                      (string-append
                       "GUILE_LOAD_COMPILED_PATH="
                       (dirname (dirname supervisor-guile))
                       "/lib/guile/3.0/site-ccache")))
               (command
                (case language
                  ((guile)
                   (list (string-append language-profile "/bin/guile")
                         "--no-auto-compile" "-L" modules
                         "-l" guile-boundary guile-book))
                  ((python)
                   (list
                    (string-append language-profile "/bin/python3")
                    "-I" "-S" "-B" "-c"
                    (string-append
                     "import runpy,sys\n"
                     "sys.path.insert(0," (object->string session-root) ")\n"
                     "runpy.run_path(" (object->string python-boundary)
                     ",run_name='__book_boundary_probe__')\n"
                     "runpy.run_path(" (object->string python-book)
                     ",run_name='__main__')\n")))
                  (else (fail "test selected unsupported language" language)))))
          (set! child
                ((authority 'spawn-owned-runsc!)
                 label (string-append session-root "/runsc.pid")
                 donation command environment session-root
                 (string-append session-root "/runsc.stdout")
                 (string-append session-root "/runsc.stderr")
                 supervisor-guile runsc-adapter deadline))
          (set-peer-value! peer 'set-protocol-peer-child! child)
          ((authority 'close-port-quietly!) donation)
          (set-peer-value! peer 'set-protocol-peer-donation! #f)
          ((base-private 'assert-parent-authority-only!) peer donation-identity)
          (set! world
                (((authority 'world-record) 'make)
                 endpoint child control deadline #f #f '() '() '() '() #f))
          (catch #t
            (lambda () ((authority 'drive-human-note!) world))
            (lambda (key . details)
              (cond
               ((eq? key 'book-state-device-ui-closed) #t)
               ((eq? key 'book-state-device-stop-requested)
                (set! stop-details (cons key details)))
               (else (apply throw key details)))))
          (((authority 'world-record) 'set-closing!) world #t)
          (set! session-records
                (append
                 session-records
                  (list
                  (let ((ready (((authority 'world-record) 'ready) world)))
                    (list language
                          (field (host-session-snapshot endpoint) "session_id")
                          (state-ready-message-grant-handle ready)
                          (state-ready-message-grant-generation ready))))))))
      (lambda ()
        (when peer
          ((base-private 'release-peer!) peer)
          (set! released? #t))))
    (assert released? "session endpoint was not released")
    (let ((snapshot (host-session-snapshot endpoint)))
      (assert (and (eq? (field snapshot "state") 'closed)
                   (not (field snapshot "transport_open")))
              "released endpoint remained live" snapshot))
    (assert
     (catch #t
       (lambda () (host-action! endpoint "save-note" "stale") #f)
       (lambda arguments #t))
     "released endpoint accepted a stale action")
    (let* ((result ((base-private 'capture-result) child))
           (stdout
            (call-with-input-file
                (string-append session-root "/runsc.stdout")
              get-string-all)))
      (assert (and (equal? (child-value child 'owned-runsc-status) '(exit . 0))
                   (child-value child 'owned-runsc-finalized?)
                   (not ((base-private 'capture-overflow?) result))
                   (not ((base-private 'process-group-exists?)
                         ((base-record 'owned-runsc-process-group) child))))
              "fixed book did not finish through bounded natural cleanup")
      (assert (and (string-contains
                    stdout
                    (format #f
                            "BOOK_STATE_SANDBOX_BOUNDARY: language=~a result=pass"
                            language))
                   (string-contains stdout
                                    "BOOK_STATE_READER_JOIN_BOOK: result:ok"))
              "fixed boundary/book output is absent" language stdout))
    (assert (not (file-exists? (string-append session-root "/runsc.pid")))
            "owned child record survived cleanup")
    ((authority 'delete-owned-tree!) session-root)
    (set! sessions-until-stop (- sessions-until-stop 1))
    (when (zero? sessions-until-stop)
      (set-authority! 'stop-requested? #t))
    (when stop-details
      (apply throw (car stop-details) (cdr stop-details)))))

(define (wait-for-path path)
  (let loop ((remaining 1000))
    (cond ((file-exists? path) #t)
          ((zero? remaining) (fail "timed out waiting for path" path))
          (else (usleep 5000) (loop (- remaining 1))))))

(define (send-event! client kind value)
  (put-bytevector client
                  (encode-control-line kind 1 value reader-event-kinds))
  (force-output client))

(define (read-frame-bytes client)
  (let loop ((bytes '()))
    (let ((byte (get-u8 client)))
      (cond ((eof-object? byte) (fail "authority UI stream reached early EOF"))
            ((= byte 10) (u8-list->bytevector (reverse bytes)))
            (else (loop (cons byte bytes)))))))

(define (receive-command! client expected-kind expected-value)
  (let ((event (decode-control-line (read-frame-bytes client)
                                    reader-command-kinds)))
    (assert (equal? event (list expected-kind 1 expected-value))
            "unexpected authority UI command" event)
    event))

(define (connect-ui)
  (let ((client (socket AF_UNIX SOCK_STREAM 0)))
    (connect client AF_UNIX socket-path)
    (setvbuf client 'none)
    client))

(define (run-ui-session! initial save-text close-mode)
  (let ((client (connect-ui)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (send-event! client 'channel-ready "")
        (send-event! client 'ready "")
        (receive-command! client
                          (if (string-null? initial) 'load-absent 'load-value)
                          initial)
        (send-event! client 'status
                     (if (string-null? initial) "loaded-absent" "loaded-value"))
        (send-event! client 'applied initial)
        (when (eq? close-mode 'stop)
          ;; Exercise the installed production signal handler while the book,
          ;; endpoint, state delegate, SQLite runtime, and listening socket all
          ;; exist.  The handler records stop and wakes the listener; the active
          ;; interaction observes the typed stop at its next bounded pump.
          (kill (getpid) SIGTERM))
         (when (and save-text (not (eq? close-mode 'stop)))
           (send-event! client 'status "dirty")
           (send-event! client 'submit save-text)
          (send-event! client 'status "pending")
          (receive-command! client 'commit-ok save-text)
          (send-event! client 'status "saved")
          (receive-command! client 'present save-text)
          (send-event! client 'applied save-text))
        (when (eq? close-mode 'clean)
          (send-event! client 'closed "")))
      (lambda () (close-port client)))))

(define (run-authority-cycle! language initial-values save-first?)
  (set! sessions-until-stop (length initial-values))
  (set-authority! 'stop-requested? #f)
  (let* ((cycle-config (make-config language))
         (save-text (case language
                      ((guile) guile-text)
                      ((python) python-text)
                      (else (fail "unknown cycle language" language))))
         (stopping?
          (any (lambda (specification)
                 (and (pair? specification)
                      (eq? (cdr specification) 'stop)))
               initial-values))
         (thread-result #f)
         (worker
         (call-with-new-thread
          (lambda ()
            (set! thread-result
                  (catch #t
                    (lambda () ((authority 'run-authority!) cycle-config) 'ok)
                    (lambda (key . details)
                      (if (eq? key 'book-state-device-stop-requested)
                          'stopped
                          (begin
                            (format (current-error-port)
                                    "AUTHORITY-THREAD-FAIL: ~s ~s~%"
                                    key details)
                            (force-output (current-error-port))
                            (cons key details))))))))))
    (wait-for-path socket-path)
    (let loop ((values initial-values) (first? save-first?))
      (unless (null? values)
        (let* ((specification (car values))
               (special-close? (pair? specification))
               (initial (if special-close?
                            (car specification)
                            specification))
               (close-mode (if special-close?
                               (cdr specification)
                               'clean)))
          (run-ui-session! initial (and first? save-text)
                           close-mode))
        (set! first? #f)
        (loop (cdr values) first?)))
    (join-thread worker)
    (assert (eq? thread-result (if stopping? 'stopped 'ok))
            "authority cycle failed" thread-result)
    (assert (and (not (file-exists? socket-path))
                 (not (file-exists? runtime-root)))
            "authority cycle retained runtime endpoint state")))

(define (query-scalar database sql)
  (let ((statement (sqlite-prepare database sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((rows (sqlite-map identity statement)))
          (and (= (length rows) 1)
               (= (vector-length (car rows)) 1)
               (vector-ref (car rows) 0))))
      (lambda () (sqlite-finalize statement)))))

(define (query-rows database sql)
  (let ((statement (sqlite-prepare database sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (sqlite-map identity statement))
      (lambda () (sqlite-finalize statement)))))

(define (inspect-closed-database! expected)
  (let ((info (lstat database-path)))
    (assert (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (= (logand (stat:mode info) #o7777) #o600))
            "database lost its private identity"))
  (for-each
   (lambda (suffix)
     (assert (not (file-exists? (string-append database-path suffix)))
             "closed database retained a sidecar" suffix))
   '("-journal" "-wal" "-shm"))
  (let ((database (sqlite-open database-path SQLITE_OPEN_READONLY)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (assert (string=? (query-scalar database "PRAGMA quick_check") "ok")
                "closed database failed quick_check")
        (let ((rows
               (query-rows
                database
                "SELECT book_revision, instance_id, state_version, text FROM book_instances ORDER BY book_revision, instance_id")))
          (assert (= (length rows) (length expected))
                  "closed database has wrong namespace count")
          (for-each
           (lambda (row wanted)
             (assert
              (and (= (vector-length row) 4)
                   (string=? (vector-ref row 0) (list-ref wanted 0))
                   (string=? (vector-ref row 1) (list-ref wanted 1))
                   (= (vector-ref row 2) (list-ref wanted 2))
                   (string=? (vector-ref row 3) (list-ref wanted 3)))
              "closed database row differs from fixed namespace" row wanted))
           rows expected))
        (assert (= (query-scalar database "SELECT COUNT(*) FROM commit_receipts")
                   (length expected))
                "closed database has wrong receipt count"))
      (lambda () (sqlite-close database)))))

(define (check-fixed-bundles!)
  (let* ((root (string-append test-root "/bundle-check"))
         (closure ((smoke-private 'read-closure) language-closure)))
    (mkdir root #o700)
    (for-each
     (lambda (language)
       (let* ((selected ((authority 'profile) language))
              (bundle (string-append root "/" (symbol->string language)))
              (bundle-config (make-config language)))
         ((authority 'generate-fixed-bundle!)
          language selected bundle-config bundle closure)
         (call-with-values
             (lambda () ((base-private 'read-launch-record)
                         bundle (symbol->string language)
                         ((authority 'profile-field) selected 'container-id)))
           (lambda (argv environment)
             (assert (and (pair? argv) (pair? environment))
                     "generated bundle rejected by production launch reader")))
         (let* ((spec (call-with-input-file
                         (string-append bundle "/config.json")
                       get-string-all))
               (launch (call-with-input-file
                           (string-append bundle "/launch.json")
                         get-string-all))
               (combined (string-append spec "\n" launch)))
           (for-each
            (lambda (token)
              (assert (string-contains combined token)
                      "fixed OCI bundle lost policy token" language token))
            '("--platform=systrap" "--network=none" "--directfs=false"
              "--host-uds=none"))
           (assert (and (string-contains launch "--pass-fd=3:3")
                        (if (eq? language 'python)
                            (and (string-contains combined "-I")
                                 (string-contains combined "-S")
                                 (string-contains combined "-B"))
                            (string-contains combined "/profile/bin/guile")))
                   "fixed launch record lost its language/FD boundary"
                   language))))
     '(guile python))
    ((authority 'delete-owned-tree!) root)))

;; Exercise the canonical production session owner's catches and dynamic-wind.
;; Only unavailable host boundaries are replaced: OCI/runsc launch becomes the
;; accepted FD-3 adapter launching the real fixed book directly, and cgroup/
;; diagnostic-mount operations become ordered observations.  This is not a
;; host sandbox claim; the generated OCI policy itself is checked separately.
(define controlled-stage #f)
(define controlled-language 'guile)
(define controlled-events '())
(define controlled-spawn-count 0)

(define (controlled-event! value)
  (set! controlled-events (append controlled-events (list value))))

(define (controlled-book-command bundle label)
  (let ((environment
         (list "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
               "PATH=/usr/bin:/bin" "GUILE_AUTO_COMPILE=0"
               "BOOK_SESSION_FD=3"
               (string-append "GUILE_LOAD_PATH=" modules ":"
                              (dirname (dirname supervisor-guile))
                              "/share/guile/site/3.0")
               (string-append
                "GUILE_LOAD_COMPILED_PATH="
                (dirname (dirname supervisor-guile))
                "/lib/guile/3.0/site-ccache"))))
    (values
     (case controlled-language
       ((guile)
        (list (string-append language-profile "/bin/guile")
              "--no-auto-compile" "-L" modules
              "-l" guile-boundary guile-book))
       ((python)
        (list
         (string-append language-profile "/bin/python3")
         "-I" "-S" "-B" "-c"
         (string-append
          "import runpy,sys\n"
          "sys.path.insert(0," (object->string bundle) ")\n"
          "runpy.run_path(" (object->string python-boundary)
          ",run_name='__book_boundary_probe__')\n"
          "runpy.run_path(" (object->string python-book)
          ",run_name='__main__')\n")))
       (else (fail "controlled production entry selected unknown language"
                   controlled-language)))
     environment)))

(define (install-controlled-production-seams!)
  ;; Native profiles have architecture-specific requisites (25 on this host);
  ;; the deployed authority separately pins its ARM closure to 46 paths.
  ;; This controlled native launch reads the supplied host closure without
  ;; pretending it is the device's closure. No production pin is relaxed.
  (set-authority! 'read-device-language-closure
                  (production-smoke-private 'read-closure))
  (set-authority!
   'generate-fixed-bundle!
   (lambda (language selected config bundle closure)
     (controlled-event! (list 'generate language (length closure)))
     (when (eq? controlled-stage 'outer)
       (throw 'controlled-outer 'original-sentinel))
     (mkdir bundle #o700)
     (when (eq? language 'python)
       (symlink python-protocol (string-append bundle "/book_protocol.py")))))
  (set-authority!
   'smoke-private
   (lambda (name)
     (if (eq? name 'call-with-diagnostic-stores)
         (lambda (bundle thunk)
           (controlled-event! 'diagnostic-enter)
           (let ((value (thunk 'controlled-stores)))
             (controlled-event! 'diagnostic-leave)
             value))
         (production-smoke-private name))))
  (set-authority!
   'base-private
   (lambda (name)
     (case name
       ((prepare-owned-runtime-state!)
        (lambda (bundle container-id)
          (controlled-event! 'runtime-prepare)
          (list bundle container-id)))
       ((cleanup-owned-runtime-state!)
        (lambda (owner container-id)
          (controlled-event! 'runtime-cleanup)))
       ((assert-runtime-state-clean!)
        (lambda (bundle container-id)
          (controlled-event! 'runtime-clean-assert)))
       ((assert-cgroup2-preflight!)
        (lambda (container-id)
          (controlled-event! 'cgroup-preflight)
          (when (eq? controlled-stage 'inner)
            (throw 'controlled-inner 'original-sentinel))))
       ((read-launch-record)
         (lambda (bundle label container-id)
           (assert (string=? label (symbol->string controlled-language))
                   "production entry confused language with UI label" label)
          (controlled-event! (list 'launch controlled-language))
          (controlled-book-command bundle label)))
       ((release-peer!)
        (let ((release (production-base-private name)))
          (lambda (peer)
            (controlled-event! 'peer-release)
            (release peer))))
       ((assert-diagnostic-stores-unmounted!)
        (lambda (bundle) (controlled-event! 'diagnostic-unmounted)))
       (else (production-base-private name)))))
  (set-authority!
   'spawn-owned-runsc!
   (lambda arguments
     (set! controlled-spawn-count (+ controlled-spawn-count 1))
     (controlled-event! (list 'spawn controlled-language))
     (apply production-spawn-owned-runsc! arguments))))

(define (restore-production-seams!)
  (set-authority! 'read-device-language-closure production-read-device-closure)
  (set-authority! 'base-private production-base-private)
  (set-authority! 'smoke-private production-smoke-private)
  (set-authority! 'generate-fixed-bundle! production-generate-fixed-bundle!)
  (set-authority! 'spawn-owned-runsc! production-spawn-owned-runsc!)
  (set-authority! 'run-sandbox-session! production-run-sandbox-session!))

(define (production-failure-case! stage expected-key required-events)
  (set! controlled-stage stage)
  (set! controlled-language 'guile)
  (set! controlled-events '())
  (let* ((session-root (string-append test-root "/production-" (symbol->string stage)))
         (runtime (open-reader-state-runtime state-root))
         (caught #f))
    (mkdir session-root #o700)
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! caught
              (catch #t
                (lambda ()
                  (production-run-sandbox-session!
                   runtime #f (make-config 'guile) session-root
                   (+ ((authority 'now-seconds)) 10.0) 'guile)
                  '(unexpected-success))
                (lambda (key . details) (cons key details)))))
      (lambda () (close-reader-state-runtime! runtime)))
    (assert (equal? caught (list expected-key 'original-sentinel))
            "production session masked the original exception" stage caught)
    (assert (not (file-exists? session-root))
            "production failure retained its session root" stage)
    (for-each
     (lambda (event)
       (assert (= (count (lambda (observed) (equal? observed event))
                         controlled-events)
                  1)
               "production failure cleanup event was absent or repeated"
               stage event controlled-events))
     required-events)))

(define (check-production-session-owner!)
  (install-controlled-production-seams!)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (production-failure-case!
       'outer 'controlled-outer
       '(runtime-clean-assert diagnostic-unmounted))
      (production-failure-case!
       'inner 'controlled-inner
       '(runtime-prepare cgroup-preflight peer-release runtime-cleanup
         diagnostic-unmounted))
      (set! controlled-stage #f)
      (set! controlled-events '())
      (set! controlled-spawn-count 0)
      (for-each
       (lambda (language)
         (set! controlled-language language)
         (set-authority! 'stop-requested? #f)
         (set-authority!
          'run-sandbox-session!
          (lambda arguments
            (apply production-run-sandbox-session! arguments)
            (set-authority! 'stop-requested? #t)))
         (run-authority-cycle! language (list "") #f))
       '(guile python))
      (assert (= controlled-spawn-count 2)
              "production session entry did not spawn both controlled books"
              controlled-spawn-count)
      (assert (and (member '(spawn guile) controlled-events equal?)
                   (member '(spawn python) controlled-events equal?))
              "production session entry missed a language spawn"
              controlled-events)
      ;; The two no-save production-entry probes legitimately created empty
      ;; fixed namespaces. Remove that closed test database so the pre-existing
      ;; persistence campaign below retains its original initial conditions.
      (for-each
       (lambda (suffix)
         (assert (not (file-exists? (string-append database-path suffix)))
                 "production-entry probe retained a SQLite sidecar" suffix))
       '("-journal" "-wal" "-shm"))
      (when (file-exists? database-path) (delete-file database-path))
      (display
       "PASS: canonical run-sandbox-session! preserved outer/inner exceptions, unwound peer/runtime/diagnostics, and spawned real Guile/Python FD-3 books through the controlled host adapter (not a sandbox claim)\n"))
    (lambda () (restore-production-seams!))))

(dynamic-wind
  (lambda () #t)
  (lambda ()
    ;; A stale runtime root is fatal before the database or socket is opened.
    (mkdir runtime-root #o700)
    (set-authority! 'stop-requested? #f)
    (assert
     (catch 'book-state-device-error
       (lambda () ((authority 'run-authority!) (make-config 'guile)) #f)
       (lambda details #t))
     "authority accepted stale transient state")
    (assert (and (not (file-exists? database-path))
                 (not (file-exists? socket-path)))
            "stale-state refusal opened durable or UI authority")
    (rmdir runtime-root)

    ;; Save once, close, reopen in the same service, then restart the service
    ;; and reader connection and recover the same human-provided value again.
    (if (getenv "BOOK_STATE_DEVICE_TEST_SKIP_BUNDLE_CHECK")
        (display
         "SKIP: fixed OCI regeneration uses device 46-path closure with older native host executables; policy was not claimed by this mixed-input run\n")
        (check-fixed-bundles!))
    (check-production-session-owner!)
    (set-authority! 'run-sandbox-session! test-run-session!)
    (run-authority-cycle! 'guile (list "" guile-text) #t)
    (inspect-closed-database!
     (list (list "reader-note/guile@1" "persistent-note-guile" 1 guile-text)))
    ;; The restarted authority first loses KOReader without a close event,
    ;; then accepts a fresh reader connection and recovers the same value.
    (run-authority-cycle!
     'guile (list (cons guile-text 'disconnect) guile-text) #f)
    (inspect-closed-database!
     (list (list "reader-note/guile@1" "persistent-note-guile" 1 guile-text)))
    (run-authority-cycle! 'guile (list (cons guile-text 'stop)) #f)
    (inspect-closed-database!
     (list (list "reader-note/guile@1" "persistent-note-guile" 1 guile-text)))
    (run-authority-cycle! 'python (list "" python-text) #t)
    (run-authority-cycle! 'python (list python-text) #f)
    (inspect-closed-database!
     (list (list "reader-note/guile@1" "persistent-note-guile" 1 guile-text)
           (list "reader-note/python@1" "persistent-note-python" 1 python-text)))

    (assert (= (length session-records) 8)
            "wrong number of endpoint lifetimes")
    (assert (= (length (delete-duplicates (map cadr session-records) string=?)) 8)
            "reopen/restart reused a session identity")
    (assert (= (length (delete-duplicates (map caddr session-records) string=?)) 8)
            "reopen/restart reused a grant handle")
    (let ((generations (map cadddr session-records)))
      ;; Generations are scoped to one open store.  A service restart may begin
      ;; at one again, but the CSPRNG-backed handle and session are both fresh.
      (assert (equal? generations '(1 2 1 2 1 1 2 1))
              "grant generation lifecycle changed" generations))

    (display
     "PASS: Guile/Python authority runners saved, closed, reopened, disconnected/reconnected, stopped active, restarted, invalidated endpoints, reaped naturally, and rejected stale state\n"))
  (lambda ()
    (when (file-exists? test-root)
      ((authority 'delete-owned-tree!) test-root))))
