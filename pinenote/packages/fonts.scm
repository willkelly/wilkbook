(define-module (pinenote packages fonts)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 ftw)
  #:use-module ((nonguix licenses) #:prefix nonguix-license:)
  #:export (pinenote-local-fonts))

;; Locally staged, licensed fonts (see ../fonts/README.md).  The
;; directory is gitignored; this package exists only when it is present
;; and non-empty, so fresh clones build without it.  Consumers must
;; handle the #f case (see pinenote/systems/pinenote-reader.scm).

(define %local-fonts-directory
  (string-append (current-source-directory) "/../fonts/local"))

(define (directory-has-fonts? dir)
  (and (file-exists? dir)
       (let ((entries (scandir dir
                               (lambda (f)
                                 (not (member f '("." "..")))))))
         (and entries (not (null? entries))))))

(define pinenote-local-fonts
  (and (directory-has-fonts? %local-fonts-directory)
       (package
         (name "pinenote-local-fonts")
         (version "0")
         ;; The staged directory itself; its contents (not its name)
         ;; determine the store hash, so font changes rebuild cleanly.
         (source (local-file "../fonts/local" "pinenote-local-fonts"
                             #:recursive? #t))
         (build-system trivial-build-system)
         (arguments
          (list
           #:modules '((guix build utils))
           #:builder
           #~(begin
               (use-modules (guix build utils))
               (let ((dest (string-append #$output "/share/fonts/local")))
                 (mkdir-p dest)
                 (copy-recursively #$(package-source this-package) dest)))))
         (home-page #f)
         (synopsis "Locally staged licensed fonts")
         (description
          "Fonts staged in @file{pinenote/fonts/local/} at build time.
Licensed, non-redistributable; never committed to the repository.")
         (license (nonguix-license:nonfree
                   "file://pinenote/fonts/README.md")))))
