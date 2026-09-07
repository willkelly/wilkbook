(use-modules (gnu packages)
             (guix profiles))

;; Trusted host-test closure only.  The accepted sandbox language closure is
;; intentionally unchanged and has no SQLite binding.
(packages->manifest
 (map specification->package
      '("bash-minimal"
        "coreutils"
        "grep"
        "guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3"
        "guile-sqlite3@0.1.3")))
