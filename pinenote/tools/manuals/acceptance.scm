;;; Run with Guile 3: acceptance.scm SYSTEM SHELF KOREADER_BUNDLE NEW_OUTPUT_DIR
;;; Uses realized inputs only. Reader-facing code is in the Lua controller.
(use-modules (ice-9 ftw) (ice-9 match) (ice-9 popen) (ice-9 regex)
             (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))

(define tool (dirname (canonicalize-path (car (command-line)))))
(define repo (dirname (dirname (dirname tool))))
(define (read-text path) (call-with-input-file path get-string-all))
(define (write-text path text)
  (call-with-output-file path (lambda (p) (display text p))))
(define (capture . args)
  (let* ((p (apply open-pipe* OPEN_READ args))
         (text (get-string-all p)) (status (close-pipe p)))
    (unless (zero? status) (error "command failed" args status)) text))
(define (run-log log directory . args)
  ;; Redirect in the child only; keep the parent ports usable on failure.
  (force-output)
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (chdir directory)
          (let ((p (open-output-file log)))
            (dup2 (fileno p) 1) (dup2 (fileno p) 2))
          (apply execlp (car args) (car args) (cdr args)))
        (cdr (waitpid pid)))))
(define (mkdirs . paths) (for-each (lambda (p) (mkdir p #o700)) paths))
(define (copy-plugin destination)
  (mkdir destination #o700)
  (for-each (lambda (name)
              (copy-file (string-append tool "/manualacceptance.koplugin/" name)
                         (string-append destination "/" name))) '("main.lua" "_meta.lua")))
(define (require-match pattern text)
  (let ((m (string-match pattern text)))
    (unless m (error "missing identity" pattern)) (match:substring m 0)))

(match (cdr (command-line))
  ((system shelf bundle output)
   (let* ((system (canonicalize-path system))
          (profile (canonicalize-path (string-append system "/profile")))
          (shelf (canonicalize-path shelf))
          (bundle (canonicalize-path bundle))
          (reader (string-append bundle "/lib/koreader"))
          (exceptions (string-append tool "/profile-omissions.txt"))
          (guile (string-trim-right (capture "which" "guile")))
          (conf (require-match "/gnu/store/[a-z0-9]+-shepherd.conf" (read-text (string-append system "/boot"))))
          (service (require-match "/gnu/store/[a-z0-9]+-shepherd-pinenote-manuals.go" (read-text conf))))
     (unless (member shelf (string-split (capture "strings" service) #\newline))
       (error "shelf is not referenced by this system's manuals service" shelf service))
     (unless (string=? (string-trim-right (read-text (string-append reader "/git-rev"))) "v2026.03")
       (error "expected native KOReader v2026.03" bundle))
     ;; Query existing store metadata only. A stale shelf must not appear to
     ;; validate an edited converter merely because the old book still opens.
     (define derivation
       (require-match "/gnu/store/[a-z0-9]+-pinenote-manuals.drv"
                      (capture "guix" "gc" "--derivers" shelf)))
     (define source
       (require-match "/gnu/store/[a-z0-9]+-pinenote-manuals-source" (read-text derivation)))
     (for-each
      (lambda (name)
        (unless (string=? (read-text (string-append source "/" name))
                          (read-text (string-append repo "/pinenote/packages/manuals/" name)))
          (error "realized shelf converter differs from checkout" name source)))
      '("manuals.py" "build-manuals.py"))
     ;; Never reuse a profile/cache/output from a previous run.
     (when (file-exists? output) (error "output must not exist" output))
     (mkdir output #o700)
     (let* ((output (canonicalize-path output))
            (census (string-append output "/corpus.txt"))
            (identities (string-append output "/identities.txt")))
       (write-text identities
                   (string-append "system\t" system "\nprofile\t" profile "\nshelf\t" shelf
                                  "\nservice\t" service "\nnative-reader\t" bundle
                                  "\nshelf-derivation\t" derivation "\nconverter-source\t" source
                                  "\nmode\tSDL offscreen; 1404x1872 at 227 dpi; fresh profiles\n"
                                  (capture "sha256sum" (string-append reader "/reader.lua")
                                           (string-append reader "/libs/libkoreader-cre.so")
                                           (string-append source "/manuals.py")
                                           (string-append source "/build-manuals.py")
                                           (string-append tool "/manualacceptance.koplugin/main.lua")
                                           (string-append tool "/corpus-check.scm")
                                           (string-append tool "/acceptance.scm") exceptions)))
       (unless (zero? (run-log census tool guile "--no-auto-compile"
                              (string-append tool "/corpus-check.scm") profile shelf exceptions))
         (error "corpus check failed; see" census))
       ;; Mutation controls verify that a green census actually rejects
       ;; missing books, wrong counts, and unreviewed/stale exclusions.
       (let ((bad (string-append output "/mutation-shelf"))
             (manifest (read-text (string-append shelf "/MANIFEST"))))
         (mkdir bad #o700)
         (for-each (lambda (name)
                     (when (string-suffix? ".epub" name)
                       (symlink (string-append shelf "/" name) (string-append bad "/" name))))
                   (scandir shelf))
         (define (reject name expected omitfile)
           (let ((log (string-append output "/reject-" name ".log")))
             (when (zero? (run-log log tool guile "--no-auto-compile"
                                  (string-append tool "/corpus-check.scm") profile bad omitfile))
               (error "mutation wrongly accepted" name))
             (unless (string-contains (read-text log) expected)
               (error "mutation failed for unrelated reason" name log))
             (format #t "PASS: census rejects ~a~%" name)))
         (write-text (string-append bad "/MANIFEST") manifest)
         (delete-file (string-append bad "/sed.epub"))
         (reject "missing-book" "missing manifest book" exceptions)
         (symlink (string-append shelf "/sed.epub") (string-append bad "/sed.epub"))
         (let* ((end (string-index manifest #\newline))
                (fields (string-split (substring manifest 0 end) #\tab)))
           (write-text (string-append bad "/MANIFEST")
                       (string-append (string-join (append (take fields 3) '("1")) "\t")
                                      (substring manifest end))))
         (reject "wrong-count" "man manifest count differs" exceptions)
         (write-text (string-append bad "/MANIFEST") manifest)
         (write-text (string-append output "/bad-omissions.txt") "info:not-a-real-manual\n")
         (reject "omissions" "unreviewed or stale omissions" (string-append output "/bad-omissions.txt")))
       (for-each
        (lambda (mode filename negative?)
          (let* ((run (string-append output "/" mode))
                 (home (string-append run "/home"))
                 (ko (string-append run "/ko"))
                 (book (string-append run "/" filename))
                 (log (string-append run "/reader.log")))
            (mkdirs run home ko (string-append ko "/plugins") (string-append run "/shots")
                    (string-append run "/tmp"))
            (copy-plugin (string-append ko "/plugins/manualacceptance.koplugin"))
            (copy-file (string-append shelf "/" filename) book)
            (write-text (string-append ko "/settings.reader.lua")
                        "return { [\"closed_rotation_mode\"] = 0, [\"lock_rotation\"] = true }\n")
            (let ((status
                   (run-log log reader "timeout" "--kill-after=2" "120"
                            "env" "-i" (string-append "PATH=" (getenv "PATH")) "LC_ALL=C.UTF-8"
                            (string-append "HOME=" home) (string-append "KO_HOME=" ko)
                            (string-append "XDG_CONFIG_HOME=" home)
                            (string-append "XDG_CACHE_HOME=" home)
                            (string-append "XDG_DATA_HOME=" home)
                            (string-append "TMPDIR=" run "/tmp")
                            (string-append "MANUALS_MODE=" (if negative? "info" mode))
                            (string-append "MANUALS_OUT=" run "/shots")
                            "SDL_VIDEODRIVER=offscreen" "SDL_AUDIODRIVER=dummy"
                            "EMULATE_READER_W=1404" "EMULATE_READER_H=1872" "EMULATE_READER_DPI=227"
                            (string-append reader "/luajit") "reader.lua" book)))
              (unless (= status (if negative? 256 0))
                (error "KOReader unexpected exit or exceeded 120 seconds; see" log status)))
            (let ((text (read-text log)))
              (if negative?
                  (begin
                    (unless (and (string-contains text "missing reader TOC entry: 1 Introduction")
                                 (not (string-contains text "MANUALS: result:ok:")))
                      (error "reader negative control failed for unrelated reason" log))
                    (format #t "PASS: actual reader rejects wrong book for Info matrix~%"))
                  (begin
                    (unless (and (string-contains text (string-append "MANUALS: result:ok:" mode))
                                 (not (string-contains text "MANUALS: FAIL:"))
                                 (string-contains text "Tearing down UIManager with exit code: 0"))
                      (error "missing reader acceptance/clean teardown" log))
                    (for-each (lambda (line) (when (string-prefix? "MANUALS:" line) (display line) (newline)))
                              (string-split text #\newline)))))))
        '("man" "info" "wrong-book") '("Manual pages.epub" "sed.epub" "Manual pages.epub") '(#f #f #t))
       (format #t "PASS: installed manuals acceptance; evidence: ~a~%" output))))
  (_ (error "usage: acceptance.scm SYSTEM SHELF KOREADER_BUNDLE NEW_OUTPUT_DIR")))
