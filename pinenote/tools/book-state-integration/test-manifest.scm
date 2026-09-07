(use-modules (gnu packages)
             (guix profiles))

;; Trusted native host-test closure only.  This does not replace or extend the
;; accepted sandbox language profile.
(packages->manifest
 (map specification->package
       '("bash-minimal"
         "coreutils"
         "findutils"
         "grep"
        "guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3"
        "guile-sqlite3@0.1.3"
        "python@3.12.12")))
