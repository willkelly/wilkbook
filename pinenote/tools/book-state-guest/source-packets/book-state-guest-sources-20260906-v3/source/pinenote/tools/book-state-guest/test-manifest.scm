(use-modules (gnu packages)
             (gnu packages bash)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages python)
             (guix profiles))

(packages->manifest
 (list bash-minimal
       coreutils
       diffutils
       grep
       guile-3.0
       guile-json-4
       (specification->package "guile-gcrypt@0.5.0")
       guile-sqlite3
       python))
