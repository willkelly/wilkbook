(use-modules (gnu packages)
             (guix profiles))

(packages->manifest
 (map specification->package
      '("guile@3.0.9"
        "guile-gcrypt@0.5.0"
        "guile-sqlite3@0.1.3")))
