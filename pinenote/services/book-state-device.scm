(define-module (pinenote services book-state-device)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile)
  #:use-module ((gnu packages python) #:select (python))
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (pinenote packages book-state-device)
  #:export (pinenote-book-state-device-service-type
            pinenote-book-state-device-ready-service-type
            book-state-device-language-profile
            book-state-device-language-closure
            book-state-device-supervisor-profile))

(define %guile-gcrypt (specification->package "guile-gcrypt@0.5.0"))
(define %sqlite-binding guile-sqlite3)
(define %sqlite-package
  (let ((entry (assoc "sqlite" (package-inputs %sqlite-binding))))
    (if (and entry (pair? (cdr entry)) (package? (cadr entry)))
        (cadr entry)
        (error "guile-sqlite3 no longer exposes its SQLite input"))))

(for-each
 (lambda (entry)
   (unless (string=? (package-version (car entry)) (cdr entry))
     (error "Book State device dependency changed" (package-name (car entry)))))
 `((,guile-3.0 . "3.0.9")
   (,guile-json-4 . "4.7.3")
   (,%guile-gcrypt . "0.5.0")
   (,%sqlite-binding . "0.1.3")
   (,%sqlite-package . "3.53.1")))

(define book-state-device-language-profile
  (profile
   (name "wilkbook-book-state-device-languages")
   ;; Keep the accepted Guile/Python fixture package set.  Current channels
   ;; realize it as a separately checked 46-path closure; the immutable QEMU
   ;; evidence retains its original 45-path closure.  The first device menu
   ;; exposes only the fixed Guile note.
   (content (packages->manifest (list guile-3.0 guile-json-4 python)))))

(define book-state-device-language-closure
  (references-file book-state-device-language-profile
                   "wilkbook-book-state-device-language-closure"))

(define book-state-device-supervisor-profile
  (profile
   (name "wilkbook-book-state-device-supervisor")
   (content
    (packages->manifest
     (list guile-3.0 guile-json-4 %guile-gcrypt %sqlite-binding)))))

(define %authority-entry
  (program-file
   "wilkbook-book-state-device-authority"
   #~(if (not (file-exists? "/data/wilkbook/book-state/enabled"))
         (begin
           (format (current-error-port)
                   "BOOK_STATE_DEVICE: disabled; activation marker absent~%")
           (exit 0))
         (begin
           ;; `guest-book-protocol.scm` is the accepted source-only lifetime
           ;; owner.  Loading that large module through resolve-interface on
           ;; Guile 3.0.9 does not terminate; the proven QEMU authority loads
           ;; it explicitly for the same reason.  Establish it before the
           ;; device authority imports the private bindings.
           (primitive-load
            #$(file-append book-state-device-modules
                           "/guest-book-protocol.scm"))
           (primitive-load
            #$(file-append book-state-device-modules
                           "/book-state-device-authority.scm"))
           (let* ((module (resolve-module '(book-state-device-authority)))
                (main (module-ref module 'book-state-device-main))
                (config
                 (list
              (cons 'language-profile #$book-state-device-language-profile)
              (cons 'language-closure #$book-state-device-language-closure)
               (cons 'boundary-probe #$book-state-device-boundary-probe)
               (cons 'python-boundary-probe
                     #$book-state-device-python-boundary-probe)
               (cons 'guile-book #$book-state-device-guile-book)
               (cons 'python-book #$book-state-device-python-book)
               (cons 'python-protocol #$book-state-device-python-protocol)
               ;; The authority has two compile-fixed runner implementations,
               ;; but this service and its only menu item select Guile.  No
               ;; argument, environment value, UI event, or book chooses it.
               (cons 'book-language 'guile)
               (cons 'authority-uid 0)
               (cons 'authority-gid 0)
               (cons 'guile-protocol
                     #$book-state-device-guile-protocol)
               (cons 'blocking-protocol
                     #$book-state-device-blocking-protocol)
              (cons 'supervisor-guile
                    #$(file-append book-state-device-supervisor-profile
                                  "/bin/guile"))
              (cons 'runsc-fd3-adapter #$book-state-device-runsc-fd3-adapter)
                  (cons 'koreader-luajit
                        #$(file-append koreader-book-state-device
                                      "/lib/koreader/luajit")))))
             (exit (main config (command-line))))))))

(define (pinenote-book-state-device-ready-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-book-state-device-ready))
    (requirement '(file-system-/data))
    (documentation
     "Prepare, but do not enable, the private persistent Book State directory.")
    (one-shot? #t)
    (modules (append '((ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))
                     %default-modules))
    (start
     #~(lambda _
         (define root "/data/wilkbook/book-state")
         (define enabled (string-append root "/enabled"))
         (define database (string-append root "/book-state-v1.sqlite"))
         (define (lstat-or-false path)
           (catch 'system-error
             (lambda () (lstat path))
             (lambda arguments
               (if (= (system-error-errno arguments) ENOENT)
                   #f
                   (apply throw 'system-error arguments)))))
         (define (mount-record)
           (find
            (lambda (line)
              (let* ((parts (string-tokenize line))
                     (separator
                      (list-index (lambda (part) (string=? part "-")) parts)))
                (and separator (>= separator 6)
                     (string=? (list-ref parts 4) "/data")
                     (string=? (list-ref parts (+ separator 1)) "ext4"))))
            (string-split
             (call-with-input-file "/proc/self/mountinfo" get-string-all)
             #\newline)))
         (unless (mount-record)
           (error "Book State requires the real ext4 /data mount"))
         (unless (file-exists? "/data/wilkbook")
           (mkdir "/data/wilkbook" #o755))
         (let ((parent (lstat "/data/wilkbook")))
           (unless (and (eq? (stat:type parent) 'directory)
                        (zero? (stat:uid parent)))
             (error "Book State parent is not a root-owned directory")))
         (unless (file-exists? root) (mkdir root #o700))
         (let ((info (lstat root)))
           (unless (and (eq? (stat:type info) 'directory)
                        (zero? (stat:uid info)))
             (error "Book State root is not root-owned mode 0700")))
         (chmod root #o700)
         (unless (and (string=? (canonicalize-path root) root)
                      (= (logand (stat:mode (lstat root)) #o7777) #o700))
           (error "Book State root is not canonical mode 0700"))
         (for-each
          (lambda (path)
            (let ((info (lstat-or-false path)))
              (when info
                (unless (and (eq? (stat:type info) 'regular)
                             (zero? (stat:uid info))
                             (= (stat:nlink info) 1)
                             (= (logand (stat:mode info) #o7777) #o600))
                  (error "Book State private file has unsafe identity" path)))))
          (list enabled database
                (string-append database "-journal")
                (string-append database "-wal")
                (string-append database "-shm")))
         #t))
    (stop #~(const #t)))))

(define pinenote-book-state-device-ready-service-type
  (service-type
   (name 'pinenote-book-state-device-ready)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-book-state-device-ready-shepherd-service)))
   (default-value #f)
   (description
    "Create the private durable Book State root after /data is mounted, without activating the experiment.")))

(define (pinenote-book-state-device-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-book-state-device))
    (requirement '(user-processes udev pinenote-book-state-device-ready))
    (documentation
     "Run the opt-in fixed-note Book State authority with bounded runsc cleanup.")
    (respawn? #f)
    (start
     #~(let* ((supervisor #$book-state-device-supervisor-profile)
              (guile (string-append supervisor "/bin/guile")))
         (make-forkexec-constructor
          (list
           "/run/current-system/profile/bin/env" "-i"
           "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
           "PATH=/run/current-system/profile/bin"
           "GUILE_AUTO_COMPILE=0"
           (string-append "GUILE_LOAD_PATH=" #$book-state-device-modules ":"
                          supervisor "/share/guile/site/3.0")
           (string-append "GUILE_LOAD_COMPILED_PATH=" supervisor
                          "/lib/guile/3.0/site-ccache")
           guile "--no-auto-compile" "-s" #$%authority-entry)
          #:file-creation-mask #o077
          #:log-file "/var/log/book-state-device.log")))
    (stop
     #~(lambda (process . args)
         ;; Let the authority close the UI endpoint, revoke and join the state
         ;; worker, then use the accepted runsc natural grace before escalation.
         (let ((pid (if (integer? process) process (process-id process))))
           (define (alive?)
             (catch 'system-error
               (lambda () (kill pid 0) #t)
               (lambda arguments #f)))
           (catch 'system-error (lambda () (kill pid SIGTERM))
                  (lambda arguments #f))
           (let loop ((tries 120))
             (when (and (alive?) (positive? tries))
               (sleep 1/10)
               (loop (- tries 1))))
           (if (alive?) ((make-kill-destructor) process) #f)))))))

(define pinenote-book-state-device-service-type
  (service-type
   (name 'pinenote-book-state-device)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-book-state-device-shepherd-service)))
   (default-value #f)
   (description
    "Supervise the fixed Book State note authority. It exits inertly unless /data/wilkbook/book-state/enabled is the exact opt-in marker.")))
