(define-module (pinenote packages manuals)
  #:use-module (guix gexp)
  #:use-module ((gnu packages compression) #:select (lzip zstd))
  #:use-module ((gnu packages man) #:select (mandoc))
  #:use-module ((gnu packages python) #:select (python-minimal))
  #:export (pinenote-manuals
            pinenote-manuals-source))

;; Build the reader's shelf of manuals: every man page and Texinfo manual
;; carried by the packages the flavor installs, converted to EPUB so
;; KOReader can open them (issue #17).
;;
;; The whole corpus already ships -- man-db and info-reader come from
;; %base-packages, and with them ~500 man pages and ~24 GNU manuals -- and
;; none of it is reachable, because the reader has no terminal and exactly
;; one application on screen.  This turns that dead weight into books.
;;
;; EAGER, AT BUILD TIME, and the measurement says so plainly (2026-08-24,
;; the reader flavor's own package list as resolved on one workstation
;; store): 552 man entries and 24 Texinfo manuals convert in ~1.8 s of
;; x86_64 CPU into 4.90 MiB of EPUB.  Doing that lazily on the device would
;; mean putting a roff formatter, a pipeline and a shell onto a reader that
;; has none of them, and paying RK3566 seconds for a result that never
;; differs.  Here, mandoc/python/zstd are BUILD-machine inputs and add
;; nothing to the device's closure.
;;
;; The three tools are ungexp-NATIVE (#+) and the corpus packages are
;; ungexp-TARGET (#$): under --target=aarch64-linux-gnu the converter has
;; to be an x86_64 binary reading aarch64 store paths.  Documentation is
;; architecture-independent text, so that is a real division, not a fudge.
;;
;; What is NOT established by any of this: how KOReader's engine actually
;; lays the books out.  No hardware and no QEMU run is part of this work.
;; doc/manuals.md says what was checked and what was not.

(define pinenote-manuals-source
  ;; Also read directly by pinenote/tools/manuals -- the host suite runs
  ;; the same converter this package runs, not a copy of it.
  (local-file "manuals" "pinenote-manuals-source"
              #:recursive? #t
              ;; A stray __pycache__ from running the host suite would
              ;; otherwise change this input's hash and rebuild the shelf.
              #:select? (lambda (file stat)
                          (and (not (string=? (basename file) "__pycache__"))
                               (not (string-suffix? ".pyc" file))))))

(define* (pinenote-manuals packages #:key (info? #t))
  "Return a directory of EPUBs built from the man pages and Texinfo manuals
installed by PACKAGES.  When INFO? is false only man pages are converted."
  (computed-file
   "pinenote-manuals"
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (mkdir-p #$output)
         ;; system*, and an explicit failure: a converter that quietly
         ;; produced an empty shelf would ship an image whose only visible
         ;; symptom is a library that looks the same as before.
         (let ((status
                (apply system*
                       #+(file-append python-minimal "/bin/python3")
                       (string-append #$pinenote-manuals-source
                                      "/build-manuals.py")
                       "--out" #$output
                       "--mandoc" #+(file-append mandoc "/bin/mandoc")
                       "--zstd" #+(file-append zstd "/bin/zstd")
                       "--lzip" #+(file-append lzip "/bin/lzip")
                       #$@(if info? '() '("--no-info"))
                       (list #$@packages))))
           (unless (zero? status)
             (error "pinenote-manuals: conversion failed" status)))))))
