(define-module (pinenote packages book-workbench)
  #:use-module (guix gexp)
  #:export (book-workbench-modules
            book-workbench-runner
            book-workbench-protocol
            book-workbench-blocking
            book-workbench-fd-adapter
             book-workbench-runtime-owner
             book-workbench-editor-runner
             book-workbench-editor-assets
             book-workbench-guest-entry))

;; Import individual canonical sources, not the historical demonstration packet
;; or a recursive checkout (which would retain tests and developer workspaces).
(define book-workbench-runner
  (local-file "../tools/book-workbench/workbench-runner.scm"))
(define book-workbench-protocol
  (local-file "../tools/book-protocol/book-protocol.scm"))
(define book-workbench-blocking
  (local-file "../tools/book-protocol/book-protocol/blocking-io.scm"))
(define book-workbench-fd-adapter
  (local-file "../tools/book-state-guest/runsc-fd3-exec.scm"))
(define book-workbench-runtime-owner
  ;; Standalone fresh-process owner, not an importable module. Its only code
  ;; dependencies are Guile's standard modules and the separately passed adapter.
  (local-file "../tools/book-workbench/workbench-runtime-owner.scm"))
(define book-workbench-guest-entry
  (local-file "../tools/book-workbench/guest-entry.scm"))

(define book-workbench-editor-runner
  (local-file "../tools/book-workbench-editor/workbench-editor-runner.scm"))

(define %tools-directory
  (canonicalize-path (string-append (dirname (current-filename)) "/../tools")))

;; Python resolves __file__ before selecting siblings. Copy this exact source
;; inventory into one immutable tree; a file-union of symlinks would resolve
;; individual files out of that tree. No tests, caches or native owner are shipped.
(define book-workbench-editor-assets
  (let ((sources
         (append
          (map (lambda (name)
                 (list (string-append "book-workbench-editor/" name)
                       (local-file (string-append %tools-directory "/book-workbench-editor/" name))))
               '("native-editor.py" "editor-authority.scm" "editor-seed.scm"
                 "workspace-protocol.scm" "workspace-delegate.scm" "editor-surface.scm"
                 "workbench-editor-runner.scm" "sandbox-scenario.py"
                 "plugin/bookworkbencheditor.koplugin/main.lua"
                 "plugin/bookworkbencheditor.koplugin/_meta.lua"
                 "plugin/bookworkbencheditor.koplugin/editor_channel.lua"
                 "plugin/bookworkbencheditor.koplugin/editor_codec.lua"))
          (map (lambda (name)
                 (list (string-append "book-workbench/" name)
                       (local-file (string-append %tools-directory "/book-workbench/" name))))
               '("book-workspace.scm" "schema-workspace-v1.sql" "desktop-reader.lua"))
          (map (lambda (name)
                 (list (string-append "book-protocol/" name)
                       (local-file (string-append %tools-directory "/book-protocol/" name))))
               '("book_protocol.py" "book-protocol.scm" "book-protocol/blocking-io.scm")))))
    (with-imported-modules '((guix build utils))
      (computed-file
       "wilkbook-book-workbench-editor-assets"
       #~(begin
           (use-modules (guix build utils))
           (for-each
            (lambda (entry)
              (let ((target (string-append #$output "/" (car entry))))
                (mkdir-p (dirname target))
                (copy-file (cadr entry) target)))
            '#$sources))))))

(define book-workbench-modules
  (file-union
   "wilkbook-book-workbench-modules"
   `(("book-workspace.scm"
      ,(local-file "../tools/book-workbench/book-workspace.scm"))
     ("schema-workspace-v1.sql"
      ,(local-file "../tools/book-workbench/schema-workspace-v1.sql"))
     ("workbench-authority.scm"
      ,(local-file "../tools/book-workbench/workbench-authority.scm"))
     ("workbench-preview.scm"
      ,(local-file "../tools/book-workbench/workbench-preview.scm"))
     ("workbench-sandbox.scm"
       ,(local-file "../tools/book-workbench/workbench-sandbox.scm"))
     ("workbench-editor-sandbox.scm"
      ,(local-file "../tools/book-workbench/workbench-editor-sandbox.scm"))
     ("sandbox-scenario.scm"
      ,(local-file "../tools/book-workbench/sandbox-scenario.scm"))
     ("resource-scenario.scm"
      ,(local-file "../tools/book-workbench/resource-scenario.scm"))
     ("book-session.scm"
      ,(local-file "../tools/book-session/book-session.scm"))
     ("book-protocol.scm" ,book-workbench-protocol)
     ("book-protocol/blocking-io.scm" ,book-workbench-blocking)
     ("guest-smoke.scm"
      ,(local-file "../tools/book-execution-spike/guest-smoke.scm"))
     ("guest-book-protocol.scm"
      ,(local-file "../tools/book-execution-spike/guest-book-protocol.scm"))
     ("oci-bundle.scm"
      ,(local-file "../tools/book-execution-spike/oci-bundle.scm"))
     ("oci-book-bundle.scm"
      ,(local-file "../tools/book-state-guest/oci-state-book-bundle.scm"))
     ("guest-virtio-book-ui.scm"
      ,(local-file "../tools/book-execution-spike/guest-virtio-book-ui.scm"))
     ("private-control.scm"
      ,(local-file "../tools/book-state-reader/private-control.scm")))))
