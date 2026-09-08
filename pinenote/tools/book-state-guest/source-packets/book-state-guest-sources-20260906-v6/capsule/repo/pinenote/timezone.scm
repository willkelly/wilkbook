(define-module (pinenote timezone)
  #:use-module (srfi srfi-13)
  #:export (%wilkbook-timezone-variable
            %wilkbook-default-timezone
            %pinenote-timezone
            zoneinfo-directory
            resolve-timezone))

;; The build-time timezone, chosen the same way the insecure conveniences
;; are (pinenote/insecure.scm): an environment variable, off by default,
;; with a gitignored local.mk at the repo root for a persistent
;; per-checkout choice.  One mechanism, two knobs -- not two mechanisms.
;;
;;   WILKBOOK_TIMEZONE=Europe/Dublin make image-reader
;;
;; or, so you do not have to remember it every time:
;;
;;   # local.mk, gitignored
;;   export WILKBOOK_TIMEZONE = Europe/Dublin
;;
;; The Makefile `-include's that file, so the choice is per-checkout and
;; cannot be committed by accident (.gitignore carries it).
;;
;; WHY THE DEFAULT STAYS Etc/UTC.  "Something sane" for a channel that
;; anyone can clone is not a guess at where the operator lives; every
;; concrete zone is wrong for most of the world, and picking one would
;; change behaviour for a checkout that asked for nothing.  UTC is also
;; the zone this repo's own evidence trail is already written in --
;; doc/status.md entries, doc/artifacts/, the autosuspend resume log --
;; and moving the default would silently reinterpret every future log
;; against a different clock while the old ones stayed UTC.  So the
;; default is unchanged and the operator opts in, exactly like the
;; insecure flag.
;;
;; WHERE IT APPLIES.  base.scm, i.e. every flavor, not the reader alone.
;; The reader is what has a user-visible clock, but the reason the
;; timezone matters at all is log reconstruction, and the logs that get
;; reconstructed come from whichever flavor was deployed -- a dev or
;; usb-console image stamping UTC while the reader stamps local time
;; would put a mental conversion in the middle of every cross-flavor
;; comparison.  One knob, one value, all flavors agree.
;;
;; (pinenote/systems/qemu-aarch64-smoke.scm deliberately does NOT read
;; this: it is a generic ARM64 smoke VM, not a device flavor, and its
;; assertions are compared host-side.  Its hard-coded Etc/UTC is a
;; decision, and says so in place.)
;;
;; No build marker is needed here, unlike insecure.scm: Guix already
;; writes the chosen zone to /etc/timezone on every system, so a mounted
;; image and a running device can both answer "which zone is this?"
;; without inferring it from behaviour.

(define %wilkbook-timezone-variable "WILKBOOK_TIMEZONE")

(define %wilkbook-default-timezone "Etc/UTC")

;; WHY THIS VALIDATES AT ALL.  Guix does not check the string.  The
;; timezone field lands in gnu/system.scm as
;;
;;   ("localtime" ,(file-append tzdata "/share/zoneinfo/" timezone))
;;
;; -- a path built by concatenation, never opened at build time.  A
;; typo'd zone therefore produces a *dangling* /etc/localtime, glibc
;; falls back to UTC without a word, and the device boots looking
;; exactly like a device that was never configured.  That is the failure
;; mode this repo refuses to ship: wrong, quiet, and only discoverable
;; by a human noticing the clock after an image build and a deploy.  So
;; the check happens here, at evaluation time, before anything is built.
;;
;; Concatenation is also why `..' is rejected below rather than merely
;; discouraged: nothing else stops a component from walking
;; /etc/localtime out of the zoneinfo tree and into some other store
;; path.

(define (zone-char? c)
  ;; Deliberately ASCII-explicit.  char-alphabetic? is Unicode-aware, so
  ;; it would happily accept "Europe/Dubl\xed;n" -- which is well-formed to
  ;; Guile and absent from every zoneinfo database.
  (or (and (char>=? c #\a) (char<=? c #\z))
      (and (char>=? c #\A) (char<=? c #\Z))
      (and (char>=? c #\0) (char<=? c #\9))
      (memv c '(#\_ #\- #\+))))

(define (zone-component-ok? component)
  (and (not (string-null? component))
       (not (string=? component "."))
       (not (string=? component ".."))
       (string-every zone-char? component)
       #t))

(define (every-component-ok? components)
  (cond ((null? components) #f)
        ((not (zone-component-ok? (car components))) #f)
        ((null? (cdr components)) #t)
        (else (every-component-ok? (cdr components)))))

(define (well-formed-zone-name? name)
  ;; Real names: "Etc/UTC", "Europe/Dublin", "Etc/GMT+5",
  ;; "America/Port-au-Prince", "America/Argentina/Buenos_Aires", "UTC".
  ;; Rejected: empty, leading/trailing slash, empty or dot components,
  ;; spaces, quotes, anything non-ASCII.
  (and (not (string-null? name))
       (every-component-ok? (string-split name #\/))))

(define (directory? path)
  (and (string? path)
       (not (string-null? path))
       (let ((st (false-if-exception (stat path))))
         (and st (eq? 'directory (stat:type st))))))

(define (regular-file? path)
  (let ((st (false-if-exception (stat path))))
    (and st (eq? 'regular (stat:type st)))))

(define (zoneinfo-from-localtime)
  ;; A Guix System host has no /usr/share/zoneinfo at all -- its
  ;; /etc/localtime is a symlink straight into a tzdata store path -- and
  ;; a Guix System workstation is exactly the host this repo is developed
  ;; on.  Recovering the tree from that symlink is what keeps the check
  ;; alive there instead of silently degrading to "no database found".
  (let ((target (false-if-exception (readlink "/etc/localtime"))))
    (and (string? target)
         (let ((idx (string-contains target "/share/zoneinfo/")))
           (and idx
                (let ((root (substring target 0
                                       (+ idx (string-length "/share/zoneinfo")))))
                  ;; /etc/localtime is sometimes a *relative* symlink
                  ;; (../usr/share/zoneinfo/...), resolved against /etc.
                  (if (string-prefix? "/" root)
                      root
                      (string-append "/etc/" root))))))))

(define (zoneinfo-directory)
  "Return a directory holding a zoneinfo tree, or #f if none can be found.
TZDIR is glibc's own override and wins, so an operator whose host database
is older than the zone they want has a standard escape hatch and this file
invents no second one."
  (let loop ((candidates (list (getenv "TZDIR")
                               "/usr/share/zoneinfo"
                               "/etc/zoneinfo"
                               (zoneinfo-from-localtime))))
    (cond ((null? candidates) #f)
          ((directory? (car candidates)) (car candidates))
          (else (loop (cdr candidates))))))

(define (timezone-error requested reason hint)
  ;; EXIT, DO NOT THROW.  Throwing was tried first and is worse than
  ;; useless here: `guix system build' catches the module-load error,
  ;; carries on, and then fails on base.scm's now-undefined reference
  ;; with
  ;;
  ;;   error: %pinenote-timezone: unbound variable
  ;;   hint: Did you forget `(use-modules (pinenote timezone))' ...
  ;;
  ;; as the LAST thing on screen -- a confident, wrong diagnosis that
  ;; sends the reader to edit base.scm, with the real explanation
  ;; scrolled off above it.  Exiting makes our message the final word and
  ;; the exit status unambiguous, which is the whole point of failing
  ;; visibly.
  ;;
  ;; And it has to be `primitive-exit', not `exit'.  Guile's `exit' is
  ;; `quit': it THROWS 'quit and relies on the REPL's top level to catch
  ;; it -- so under guix it is swallowed by the same handler, and the
  ;; misleading unbound-variable ending comes straight back.  Measured,
  ;; not assumed: `exit' was tried and reproduced the bad output exactly.
  ;; primitive-exit is the C exit(3) and cannot be caught, hence the
  ;; explicit force-output first.
  ;;
  ;; validate-timezone-selection.sh pins both halves: the explanation must
  ;; be the last line of a refusal (which `error' breaks), and this file
  ;; must literally say primitive-exit (which is the only way to catch
  ;; plain `exit', since it looks identical outside guix).
  (display (string-append
            "\n*** " %wilkbook-timezone-variable "=" requested
            " is not a usable timezone: " reason "\n"
            hint "\n"
            "    Unset " %wilkbook-timezone-variable
            " (or remove it from local.mk) to build "
            %wilkbook-default-timezone ".\n\n")
           (current-error-port))
  (force-output (current-error-port))
  (primitive-exit 1))

(define (check-known requested)
  (let ((dir (zoneinfo-directory)))
    (cond
     ((not dir)
      ;; doc/testing.md: absence of an error is not a passing test.  Say
      ;; out loud that the strongest half of the check did not run.
      (display (string-append
                "SKIP: " %wilkbook-timezone-variable "=" requested
                " was not checked against a zoneinfo database -- none found\n"
                "      (TZDIR unset, no /usr/share/zoneinfo or /etc/zoneinfo,\n"
                "      /etc/localtime is not a symlink into one).  The name is\n"
                "      well-formed; if it is not a real zone the image will fall\n"
                "      back to UTC silently.  Set TZDIR=/path/to/zoneinfo.\n")
               (current-error-port))
      (force-output (current-error-port)))
     ((not (regular-file? (string-append dir "/" requested)))
      (timezone-error
       requested
       (string-append "no such zone in " dir)
       (string-append
        "    It is well-formed but absent from the zoneinfo database on this\n"
        "    host, so /etc/localtime would dangle and the device would run UTC\n"
        "    while claiming otherwise.  Check the spelling (zones are\n"
        "    case-sensitive: Europe/Dublin, not europe/dublin), or point TZDIR\n"
        "    at a newer database if this host's is simply out of date."))))))

(define (resolve-timezone requested)
  "Resolve REQUESTED (a string, or #f when the variable is unset) to the
timezone the system definition should use.  Unset, empty, or whitespace-only
means the default; anything else is validated and returned verbatim."
  (let ((value (if (string? requested) (string-trim-both requested) "")))
    (cond
     ((string-null? value) %wilkbook-default-timezone)
     ((not (well-formed-zone-name? value))
      (timezone-error
       value
       "not a well-formed zoneinfo name"
       (string-append
        "    Expected slash-separated ASCII components of [A-Za-z0-9_+-],\n"
        "    e.g. Europe/Dublin, Etc/UTC, America/Argentina/Buenos_Aires.\n"
        "    No leading or trailing slash, no empty components, no `.' or `..'\n"
        "    (the name is concatenated into a store path, so `..' would walk\n"
        "    /etc/localtime out of the zoneinfo tree entirely).")))
     (else (check-known value) value))))

;; Read once, at module load, so an unusable value stops the evaluation
;; that would have built the image rather than surfacing later.
(define %pinenote-timezone
  (resolve-timezone (getenv %wilkbook-timezone-variable)))
