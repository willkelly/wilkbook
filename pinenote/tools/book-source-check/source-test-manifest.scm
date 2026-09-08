(use-modules (gnu packages)
             (guix profiles))

;; Trusted host source-test closure.  Book processes receive narrower load views
;; in the individual tests; this manifest does not describe a sandbox runtime.
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
