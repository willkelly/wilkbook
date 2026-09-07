(use-modules (gnu packages)
             (guix profiles))

;; Trusted native host-test closure only.  The book fixture receives a narrower
;; load view and never receives guile-sqlite3.
(packages->manifest
 (map specification->package
       '("bash-minimal"
         "coreutils"
        "diffutils"
         "grep"
        "patch"
        "guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3"
        "guile-sqlite3@0.1.3")))
