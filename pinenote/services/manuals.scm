(define-module (pinenote services manuals)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (pinenote packages manuals)
  #:export (pinenote-manuals-service-type
            pinenote-manuals-configuration
            pinenote-manuals-configuration?
            pinenote-manuals-packages
            pinenote-manuals-info?
            pinenote-manuals-directory
            pinenote-manuals-shelf))

;; Stage the built shelf of manuals into the reader's library (issue #17).
;;
;; The books themselves are built by (pinenote packages manuals) at system
;; build time; this service is only about getting them where KOReader's file
;; browser will find them.  They are COPIED, not symlinked: KOReader writes
;; a .sdr sidecar beside every document it opens, and the store is read-only.
;; The cost is ~5 MiB on the data partition, paid once per deploy.
;;
;; A SHEPHERD ONE-SHOT AND NOT AN ACTIVATION SNIPPET, for exactly the reason
;; pinenote/services/library.scm spells out: activation runs before p7 is
;; mounted, so an activation-time copy lands on the os2 root filesystem
;; underneath the mount, invisible forever and green in every test.
;;
;; Three rules about the user's own directory, in order of precedence:
;;
;;   1. /data must genuinely be a mount point, or nothing happens at all.
;;   2. If the stamp file exists but the shelf directory does not, the user
;;      DELETED the shelf.  It stays deleted: the stamp is refreshed and
;;      nothing is created.  (The stamp lives on p7, so it survives an os2
;;      reflash and the deletion survives with it.)
;;   3. On a refresh, only files named in the shelf's own previous manifest
;;      are removed.  Anything the user put in the directory is theirs.

(define-record-type* <pinenote-manuals-configuration>
  pinenote-manuals-configuration make-pinenote-manuals-configuration
  pinenote-manuals-configuration?
  ;; The packages whose share/man and share/info are converted.  The flavor
  ;; passes the SAME list it installs, so the shelf describes the software
  ;; that is actually on the device and nothing else.  Empty means no shelf.
  (packages  pinenote-manuals-packages  (default '()))
  ;; Convert Texinfo manuals as well as man pages.  On by default, and the
  ;; argument for that is in the corpus rather than in taste: measured over
  ;; this flavor's own packages, info is 10.34 MiB of text against man's
  ;; 4.43 MiB -- more than twice the corpus -- and for the GNU tools the man
  ;; page is a stub that says so out loud ("the full documentation is
  ;; maintained as a Texinfo manual").  Turning this off drops 24 manuals
  ;; and ~3 MiB of the shelf.
  (info?     pinenote-manuals-info?     (default #t))
  ;; Where the shelf is staged.  Inside the library, so the file browser
  ;; opens on it without the user going looking.  Expected to live under
  ;; /data: that is the mount the staging script requires to be live, and it
  ;; is passed explicitly rather than guessed from this path.
  (directory pinenote-manuals-directory (default "/data/books/Manuals")))

(define (pinenote-manuals-shelf config)
  "The store directory of EPUBs this configuration builds."
  (pinenote-manuals (pinenote-manuals-packages config)
                    #:info? (pinenote-manuals-info? config)))

(define %pinenote-manuals-stage
  ;; A real file, not a string inside this module: CI's "every tracked shell
  ;; script parses" gate then covers it, and pinenote/tools/manuals executes
  ;; it against a fake library rather than grepping it.
  (local-file "manuals-stage.sh" "pinenote-manuals-stage"))

(define (pinenote-manuals-shepherd-service config)
  (if (null? (pinenote-manuals-packages config))
      '()
      (list
       (shepherd-service
        (provision '(pinenote-manuals))
        ;; file-system-/data because the whole job is to write onto p7, and
        ;; pinenote-library because that is what creates /data/books.
        (requirement '(file-system-/data pinenote-library))
        (documentation "Stage the generated manual/info EPUBs into the reader's library; no-op when the data partition is absent, when the shelf is already current, or when the user has deleted it.")
        (one-shot? #t)
        (start
         #~(lambda _
             (zero? (system* "/bin/sh" #$%pinenote-manuals-stage
                             #$(pinenote-manuals-shelf config)
                             #$(pinenote-manuals-directory config)
                             "/data"))))
        (stop #~(const #t))))))

(define pinenote-manuals-service-type
  (service-type
   (name 'pinenote-manuals)
   (extensions (list (service-extension shepherd-root-service-type
                                        pinenote-manuals-shepherd-service)))
   (default-value (pinenote-manuals-configuration))
   (description "Convert the man pages and Texinfo manuals of the installed packages into EPUBs at build time, and stage them into the reader's library so KOReader can open them.  Never modifies a book the user put there, and never recreates a shelf the user deleted.")))
