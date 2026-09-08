(use-modules (gnu packages)
             (guix profiles))

;; Pinned host-only runtime.  The fixed books receive a narrower module view at
;; execution time and are never passed guile-sqlite3 or the retained state path.
(packages->manifest
 (map specification->package
      '("bash-minimal"
        "coreutils"
        "diffutils"
        "findutils"
        "grep"
        "patch"
        "sed"
        "guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3"
        "guile-sqlite3@0.1.3"
        "python@3.12.12")))
