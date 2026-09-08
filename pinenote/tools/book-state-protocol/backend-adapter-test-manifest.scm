(use-modules (gnu packages)
             (guix profiles))

;; Host-test closure only. This does not alter either sandbox language closure.
(packages->manifest
 (map specification->package
      '("guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-json@4.7.3"
        "guile-sqlite3@0.1.3")))
