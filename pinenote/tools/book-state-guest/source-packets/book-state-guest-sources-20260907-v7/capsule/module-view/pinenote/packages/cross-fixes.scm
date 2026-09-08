(define-module (pinenote packages cross-fixes)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages groff)
  #:use-module (gnu packages autotools)
  #:use-module ((gnu packages linux) #:select (alsa-lib alsa-ucm-conf alsa-topology-conf))
  #:export (groff-minimal/no-pdf-docs
            automake/no-tests
            alsa-lib/native-build-tools
            fix-cross-builds))

;; Local repairs to upstream packages whose CROSS-COMPILATION path is broken.
;;
;; Why this file has to exist at all: Guix's build farm builds packages
;; NATIVELY per architecture.  It does not build `--target=aarch64-linux-gnu'
;; cross derivations, which are distinct derivations with distinct hashes.  So
;; every cross build here is a LOCAL build with no substitute, and any package
;; whose cross path is broken fails on this workstation and nowhere else --
;; including on the build farm, which is why these bugs survive upstream.
;;
;; Verified 2026-08-15: `guix weather groff-minimal' reports 100% substitute
;; availability on both servers, while
;;   guix build -d groff-minimal                        -> r70v1b9n...drv
;;   guix build -d --target=aarch64-linux-gnu groff-minimal -> dvk7raqh...drv
;; are DIFFERENT derivations.  The substitute covers the first; nothing covers
;; the second.
;;
;; Keep each entry here scoped to one package and one defect, with the upstream
;; cause written down, so it can be dropped the moment upstream fixes it.

;; groff-minimal: the PDF documentation path ignores the cross fix.
;;
;; groff's own package definition already handles cross-compilation -- when
;; (%current-target-system) is set it passes
;;
;;   GROFF_BIN_PATH=<native groff>  GROFFBIN=<native groff>/bin/groff
;;
;; and groff-minimal supplies the full native `groff' in native-inputs for
;; exactly that purpose.  That works for the PostScript docs, which go through
;;
;;   DOC_GROFF = ... $(GROFFBIN) ...
;;
;; but NOT for the PDFs, because that path is
;;
;;   DOC_PDFMOM = GROFF_COMMAND=test-groff ... $(PDFMOMBIN) ...
;;
;; which HARDCODES `test-groff' -- a helper script in the build tree that is
;; not on PATH -- and ignores GROFFBIN entirely.  So the build reaches
;; doc/automake.pdf and dies:
;;
;;   GROFF    doc/automake.pdf
;;   sh: line 1: test-groff: command not found
;;   pdfmom: fatal error: test-groff exited with status 127
;;
;; Compounding it, groff-minimal passes `--with-doc=no', which groff 1.24.0
;; NO LONGER RECOGNISES -- the option is absent from its configure entirely, so
;; it is silently ignored and the docs build regardless.  That flag is stale in
;; Guix's own package and is the reason a "minimal" groff typesets PDFs at all.
;;
;; Emptying the PDF doc lists does not work: `.mom.pdf' is a SUFFIX RULE, so
;; every .mom file in the tree becomes a PDF target.  Clearing
;; PROCESSEDDOCFILES_PDF just moved the failure from doc/automake.pdf to
;; contrib/mom/examples/letter.pdf, and there is no end to that list.
;;
;; So repair the cause instead.  `test-groff' is a generated wrapper that runs
;; groff FROM THE BUILD TREE (GROFF_BIN_PATH=$builddir) -- which, cross
;; compiling, is an aarch64 binary this machine cannot execute, and which is
;; not on PATH anyway.  Replacing it with a wrapper around the NATIVE groff
;; makes every PDF target work at once, and is exactly what Guix already does
;; for the PostScript path via GROFFBIN.  Typesetting is architecture
;; independent; the PDFs are identical either way.
(define groff-minimal/no-pdf-docs
  (package
    (inherit groff-minimal)
    (name "groff-minimal")
    (arguments
     (substitute-keyword-arguments (package-arguments groff-minimal)
       ((#:phases phases)
        `(modify-phases ,phases
           ;; After 'configure, because configure is what generates test-groff
           ;; from test-groff.in.
           (add-after 'configure 'use-native-groff-for-docs
             (lambda* (#:key native-inputs inputs #:allow-other-keys)
               (let* ((groff (assoc-ref (or native-inputs inputs) "groff"))
                      (bin   (string-append (getcwd) "/.cross-native-bin")))
                 (unless groff
                   (error "cross-fixes: no native groff in inputs"))
                 (mkdir-p bin)
                 ;; Named test-groff because the make recipes invoke it
                 ;; unqualified; putting it on PATH is what fixes
                 ;; "test-groff: command not found".
                 (let ((script (string-append bin "/test-groff")))
                   (call-with-output-file script
                     (lambda (port)
                       (format port "#!/bin/sh~%exec ~a/bin/groff \"$@\"~%"
                               groff)))
                   (chmod script #o755))
                 (setenv "PATH" (string-append bin ":" (getenv "PATH")))
                 #t)))))))))

;; automake: its own test suite does not survive being cross-built.
;;
;; Cross-compiling alsa-lib bootstraps with libtoolize, which pulls automake as
;; a native input, and automake then runs 2734 of its own tests.  2384 pass;
;; what fails is environment-shaped rather than real:
;;
;;   FAIL:  t/strip2.sh
;;   ERROR: none / noread / noexec  -- exit 126 and 127, "missing test plan"
;;
;; noread and noexec deliberately create unreadable and non-executable files
;; and assert the harness copes; 126 (permission denied) and 127 (not found)
;; are the OUTCOMES THEY EXIST TO PRODUCE, and the TAP driver mis-classifies
;; them here.  The automake log also reports `required program libtool not
;; available', so part of the suite is being run without its own prerequisites.
;;
;; This automake is a build-time native input for a cross build.  Its test
;; suite tells us nothing about the aarch64 artifacts and cannot: it is
;; validating the automake running on the BUILD machine, which upstream and
;; the Guix build farm both already test natively, with substitutes to prove
;; it (`guix weather automake' is green).  Disabling it here is scoped to this
;; channel's cross builds and changes nothing about what lands on the device.
(define automake/no-tests
  (package
    (inherit automake)
    (name "automake")
    (arguments
     (substitute-keyword-arguments (package-arguments automake)
       ((#:tests? _ #t) #f)))))

;; alsa-lib: build tools declared as `inputs' instead of `native-inputs'.
;;
;; This is the textbook cross-compilation bug, and upstream's own definition
;; states it plainly:
;;
;;   (inputs (list autoconf-2.72 automake alsa-ucm-conf alsa-topology-conf
;;                 libtool))
;;
;; autoconf, automake and libtool are BUILD-TIME tools -- alsa-lib's `bootstrap
;; phase invokes libtoolize, aclocal, autoheader, automake and autoconf
;; directly.  In `inputs' they are built for the TARGET, so cross-compiling to
;; aarch64 produces an ARM libtoolize that the x86_64 builder cannot execute:
;;
;;   In execvp of libtoolize: No such file or directory
;;   command "libtoolize" ... failed with status 127
;;
;; The error is misleading -- the file is there; its ELF interpreter is not.
;; It works natively only because inputs and native-inputs coincide, which is
;; why the build farm never sees it.
;;
;; alsa-ucm-conf and alsa-topology-conf STAY in `inputs': they are data, they
;; are architecture independent, and the pre-install phase resolves them with
;; this-package-input, which only searches `inputs'.
(define alsa-lib/native-build-tools
  (package
    (inherit alsa-lib)
    (name "alsa-lib")
    (inputs (list alsa-ucm-conf alsa-topology-conf))
    (native-inputs (list autoconf-2.72 automake libtool))))

;; Rewrite a package graph so every dependant picks up the repaired variants.
;; Matched by SPEC (name, optionally name@version) rather than by identity, so
;; it catches the package wherever it appears -- man-db pulls groff-minimal
;; transitively, not directly.
(define fix-cross-builds
  (package-input-rewriting/spec
   `(("groff-minimal" . ,(const groff-minimal/no-pdf-docs))
     ;; automake/no-tests is deliberately NOT in this spec.  Rewriting automake
     ;; makes a variant of everything that build-depends on it -- ghostscript,
     ;; libjpeg-turbo, groff -- and those variants have no substitutes, so a
     ;; one-line fix cascades into rebuilding half the distribution and failing
     ;; somewhere new.  It was also treating a symptom: automake was only being
     ;; CROSS-built because alsa-lib mis-declared it as an input, and the fix
     ;; below moves it to native-inputs where it builds natively and substitutes.
     ;; The variant is kept exported for the record, and in case some other
     ;; package turns out to need it.
     ("alsa-lib" . ,(const alsa-lib/native-build-tools)))))
