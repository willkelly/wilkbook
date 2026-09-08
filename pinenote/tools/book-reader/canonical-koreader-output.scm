;; Evaluate the native package derivation and print exactly its derivation and
;; output paths. A build handler makes any attempted source/package realisation
;; an error: this gate may create derivation metadata, but never builds.
(use-modules (guix derivations)
             (guix packages)
             (guix store)
             (pinenote packages koreader))

(with-store store
  (with-build-handler
      (lambda (continue request-store things mode)
        (error "canonical KOReader evaluation attempted a build" things))
    (let ((drv (package-derivation store koreader-bin)))
      (display (derivation-file-name drv))
      (newline)
      (display (derivation->output-path drv))
      (newline))))
