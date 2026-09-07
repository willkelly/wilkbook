(use-modules (gnu packages)
             (guix profiles))

;; Host-only candidate closure.  In particular, there is no guile-sqlite3.
(packages->manifest
 (map specification->package
      '("bash-minimal"
        "coreutils"
        "grep"
        "patch"
        "guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3")))
