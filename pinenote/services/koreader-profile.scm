(define-module (pinenote services koreader-profile)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (pinenote packages fonts)
  #:export (pinenote-koreader-font-aliases
            pinenote-koreader-font-aliases?
            pinenote-koreader-font-aliases-serif
            pinenote-koreader-font-aliases-sans-serif
            pinenote-koreader-font-aliases-monospace
            %pinenote-koreader-font-aliases

            pinenote-koreader-profile-configuration
            pinenote-koreader-profile-configuration?
            pinenote-koreader-profile-settings-file
            pinenote-koreader-profile-home-dir
            pinenote-koreader-profile-fonts
            pinenote-koreader-profile-font-size
            pinenote-koreader-profile-top-margin
            pinenote-koreader-profile-bottom-margin
            pinenote-koreader-profile-side-margins
            pinenote-koreader-profile-flash-ui?
            pinenote-koreader-profile-flash-keyboard?
            pinenote-koreader-profile-avoid-flashing-ui?
            pinenote-koreader-profile-flash-area-fraction
            pinenote-koreader-profile-show-progress?
            pinenote-koreader-profile-partial-rerendering?
            pinenote-koreader-profile-header-auto-refresh-seconds
            pinenote-koreader-profile-full-refresh-count
            pinenote-koreader-profile-refresh-on-pages-with-images?
            pinenote-koreader-profile-coverbrowser-first-run-done?
            pinenote-koreader-profile-lock-rotation?
            pinenote-koreader-profile-closed-rotation-mode
            pinenote-koreader-profile-quickstart-shown-version
            pinenote-koreader-profile-screensaver-type

            pinenote-koreader-profile-settings
            pinenote-koreader-profile->lua
            pinenote-koreader-profile-service-type))

;;; The KOReader profile seeded onto a fresh image.
;;;
;;; THIS IS THE ONLY WRITER of KOReader's settings file in the tree, and
;;; that is the point of the module existing.  The path below is the only
;;; place it is spelled out, and validate-koreader-profile.sh fails if a
;;; second Scheme file spells it.  Until 2026-08-24 there were TWO
;;; seeds -- this activation snippet (which won, because activation runs
;;; before shepherd services and both were gated on the file being
;;; absent) and a second one inside reader-session's start lambda (which
;;; was therefore always a no-op).  On 2026-08-05 the six e-ink refresh
;;; keys were added to the dead one only, and an image shipped with none
;;; of them.  `make koreader-profile-check' now fails if a second writer
;;; appears; see pinenote/scripts/preflight/validate-koreader-profile.sh.
;;;
;;; Each default is declared ONCE, in the record below, and serialized to
;;; the Lua table -- issue #12's shape.  An operator overrides a field
;;; with `modify-services' rather than editing a string.
;;;
;;; WHAT THIS IS NOT.  The generated file is a MATERIALISED copy of the
;;; defaults, which doc/configuration.md §2 names as the live trap in the
;;; tree: it is harmless today only because /root sits on p6 and every
;;; reflash wipes it, so a rebuilt default reaches the device.  Making
;;; this file durable -- moving KO_HOME to p7 -- freezes every value here
;;; at whatever shipped on the device's first boot.  The fix is the
;;; sparse-override store of doc/configuration.md §4, not a change of
;;; path.  Do not move KO_HOME without building that first.
;;;
;;; Precedence, unchanged: the seed writes only when the file is ABSENT,
;;; so a profile the user has since customized is never overwritten.
;;; KOReader rewrites the file itself from then on.

;; The three font keys are ONE field, not three, because the failure this
;; module exists to prevent had exactly that shape: a seed carrying
;; cre_font without monospace_font and cre_font_family_fonts.  With a
;; single record field they are emitted together or not at all -- there
;; is no expressible state in which one of them is missing.
;;
;; The names mirror wilkhome's fontconfig aliases (serif=Equity,
;; sans=Concourse, mono=Triplicate Code); crengine's built-in fallback
;; chain stays in effect below them.
(define-record-type* <pinenote-koreader-font-aliases>
  pinenote-koreader-font-aliases make-pinenote-koreader-font-aliases
  pinenote-koreader-font-aliases?
  (serif      pinenote-koreader-font-aliases-serif      (default "Equity A"))
  (sans-serif pinenote-koreader-font-aliases-sans-serif (default "Concourse 4"))
  (monospace  pinenote-koreader-font-aliases-monospace
              (default "Triplicate A Code")))

(define %pinenote-koreader-font-aliases
  (pinenote-koreader-font-aliases))

(define-record-type* <pinenote-koreader-profile-configuration>
  pinenote-koreader-profile-configuration
  make-pinenote-koreader-profile-configuration
  pinenote-koreader-profile-configuration?

  ;; Where the profile is seeded.  /root because reader-session runs
  ;; KOReader as root with KO_HOME=/root/.config/koreader; see the
  ;; "WHAT THIS IS NOT" note above before changing it.
  (settings-file pinenote-koreader-profile-settings-file
                 (default "/root/.config/koreader/settings.reader.lua"))

  ;; The user's library on the persistent data partition, so books
  ;; survive an os2 reflash.  pinenote-library creates it; a shadowed
  ;; fallback in the reader flavor covers the never-mounted case.
  (home-dir pinenote-koreader-profile-home-dir (default "/data/books"))

  ;; #f on a fresh clone: pinenote/fonts/local is gitignored and
  ;; licensed, so pinenote-local-fonts is #f, EXT_FONT_DIR is never set,
  ;; and naming "Equity A" would point the reader at a font that is not
  ;; in the image.
  (fonts pinenote-koreader-profile-fonts
         (default (and pinenote-local-fonts %pinenote-koreader-font-aliases)))

  ;; Reading comfort, set on 2026-07-13 during the first dogfooding
  ;; session on a bare profile.  Taste, not policy: the user's menu
  ;; changes persist and the seed never overwrites an existing profile.
  (font-size     pinenote-koreader-profile-font-size     (default 30))
  (top-margin    pinenote-koreader-profile-top-margin    (default 15))
  (bottom-margin pinenote-koreader-profile-bottom-margin (default 25))
  ;; left and right, in that order (KOReader's copt_h_page_margins).
  (side-margins  pinenote-koreader-profile-side-margins  (default '(30 30)))

  ;; --- e-ink refresh policy.  Not taste: each of these costs real panel
  ;; --- time at KOReader's stock default, measured on glass 2026-08-04/05
  ;; --- (doc/refresh-policy.md).  These are the six keys the 2026-08-05
  ;; --- image shipped without.

  ;; Tap feedback on menu rows, file rows and dialog buttons calls
  ;; UIManager:forceRePaint() TWICE per tap (highlight, then unhighlight;
  ;; menu.lua ~527-543).  The cost is per UI tick, not per intent --
  ;; within one repaint drain the first publish() empties the deferred-io
  ;; pagelist and later ones are no-ops -- so what makes this expensive is
  ;; the two EXTRA ticks, each a full pass.  This was the file-browser
  ;; double draw.
  (flash-ui? pinenote-koreader-profile-flash-ui? (default #f))
  ;; Same mechanism, once per keystroke.
  (flash-keyboard? pinenote-koreader-profile-flash-keyboard? (default #f))
  ;; KOReader distinguishes optional UI flashes (flash_ui above) from
  ;; "mandatory" ones certain widgets request regardless; this key
  ;; suppresses the mandatory class too.  Found live 2026-08-27: with
  ;; flash_ui already false, menu opens still GC16-flashed until this
  ;; was set (doc/status.md part 20d).  Default #f preserves the
  ;; shipping flavor's validated behavior; the DIRECT flavor overrides
  ;; both this and flash-area-fraction (ghosting is resolved there, so
  ;; flash promotion is no longer load-bearing).
  (avoid-flashing-ui? pinenote-koreader-profile-avoid-flashing-ui?
                      (default #f))
  ;; Our own device layer's promotion threshold: flash intents covering
  ;; at least this fraction of the panel become a full GC16 wash
  ;; (device.lua flash_policy).  0.60 was load-bearing while ghosting
  ;; accumulated; with ghosting resolved on the canon image the
  ;; promotion is reserved for genuinely full-screen intents.
  (flash-area-fraction pinenote-koreader-profile-flash-area-fraction
                       (default 0.60))
  ;; ReaderRolling:showEngineProgress() paints a progress bar during a
  ;; crengine re-render and calls Screen:refreshFast() every 500 ms.
  ;; publish() is fsync on the fbdev fd and deferred-io tracks dirty
  ;; PAGES, not the intent's rect, so each tick republishes the whole
  ;; pending re-render as a full-screen ~38-frame pass (~0.8 s).  A
  ;; progress indicator that costs 0.8 s per 0.5 s tick makes the
  ;; operation it reports on slower.  Upstream added this key for the
  ;; same reason on SDL-over-SSH.  Rotations without it cost exactly
  ;; 1 IRQ (one wash); with it, 76+ frames plus the wash.
  (show-progress? pinenote-koreader-profile-show-progress? (default #f))
  ;; Otherwise crengine re-renders in the background and cycles a status
  ;; icon (cre.render.partial/working/ready/reload) at 75x75 -- and a
  ;; partial refresh costs ~38 frames REGARDLESS of area, so a corner
  ;; icon costs a full-screen repaint.  Note this one is read
  ;; per-document first (the book's .sdr sidecar) and only then globally,
  ;; so the seed loses to an existing book's saved value; it governs
  ;; newly opened books.
  (partial-rerendering? pinenote-koreader-profile-partial-rerendering?
                        (default #f))
  ;; ReaderCoptListener:updateHeader() calls document:resetBufferCache()
  ;; ("be sure next repaint is a redrawing") and setDirty over the full
  ;; screen width, and reschedules itself every 60 s while the top bar
  ;; shows a clock.  A whole page redraw plus a full-screen pass, once a
  ;; minute, forever: ~48 s of panel time per hour of reading for a clock
  ;; digit.  0 = off; the clock still updates on every page turn.
  (header-auto-refresh-seconds
   pinenote-koreader-profile-header-auto-refresh-seconds (default 0))
  ;; 0 = never.  The idle washer owns wash cadence outright per finding
  ;; 11's validated configuration -- Will's call 2026-07-13 after finding
  ;; 6/11 evidence (48+ washless turns clean; promotion adds flashes the
  ;; washer makes redundant).
  (full-refresh-count pinenote-koreader-profile-full-refresh-count
                      (default 0))
  ;; KOReader's stock #t promotes every image-bearing page to a full
  ;; flash -- the quickstart guide flashed on nearly every turn
  ;; (2026-07-13).
  (refresh-on-pages-with-images?
   pinenote-koreader-profile-refresh-on-pages-with-images? (default #f))

  ;; CoverBrowser seeds ITSELF on at first launch (main.lua ~84-95, mode
  ;; "list_image_meta"), then polls every 1 s patching extracted covers
  ;; into the file browser.  Pre-setting the "already did first-run
  ;; setup" flag leaves filemanager_display_mode unset, which is the
  ;; classic filename list.  The display modes themselves live in
  ;; BookInfoManager's sqlite cache, not here, so this PREVENTS the mode
  ;; being set rather than unsetting it.
  (coverbrowser-first-run-done?
   pinenote-koreader-profile-coverbrowser-first-run-done? (default #t))

  ;; The SC7A20 bridge owns physical orientation.  Upstream lock_rotation
  ;; remains authoritative for document/FM overrides;
  ;; input_ignore_gsensor is the sole autorotation on/off setting and is
  ;; intentionally NOT seeded.
  (lock-rotation? pinenote-koreader-profile-lock-rotation? (default #t))
  (closed-rotation-mode pinenote-koreader-profile-closed-rotation-mode
                        (default 1))

  ;; QuickStart:isShown() is shown_version >= quickstart_force_show_version
  ;; (2021070000).  Below that, reader.lua:251-255 FORCES start_with="last"
  ;; and opens the guide, so the seeded home_dir is never consulted and the
  ;; first boot does not land in the library.  validate-koreader-library.sh
  ;; pins the threshold.
  (quickstart-shown-version
   pinenote-koreader-profile-quickstart-shown-version (default 2021070000))

  (screensaver-type pinenote-koreader-profile-screensaver-type
                    (default "cover")))


;;;
;;; Serialization to KOReader's Lua table.
;;;
;;; Values are tagged rather than inferred, so a list is never guessed at:
;;;   #t / #f          -> true / false
;;;   number           -> literal
;;;   string           -> quoted
;;;   ('array . lst)   -> { [1] = a, [2] = b }   (KOReader's 1-based arrays)
;;;   ('table . alist) -> a nested string-keyed table
;;;

(define (lua-string s)
  (string-append "\""
                 (string-concatenate
                  (map (lambda (c)
                         (case c
                           ((#\" ) "\\\"")
                           ((#\\ ) "\\\\")
                           ((#\newline) "\\n")
                           (else (string c))))
                       (string->list s)))
                 "\""))

(define (lua-key k)
  (string-append "[" (lua-string k) "]"))

(define (lua-value v indent)
  (match v
    (#t "true")
    (#f "false")
    ((? number? n) (number->string n))
    ((? string? s) (lua-string s))
    (('array . items)
     (string-append
      "{ "
      (string-join (map (lambda (item i)
                          (string-append "[" (number->string i) "] = "
                                         (lua-value item indent)))
                        items (iota (length items) 1))
                   ", ")
      " }"))
    (('table . entries)
     (let ((inner (string-append indent "    ")))
       (string-append
        "{\n"
        (string-concatenate
         (map (match-lambda
                ((k . v)
                 (string-append inner (lua-key k) " = "
                                (lua-value v inner) ",\n")))
              entries))
        indent "}")))))

(define (pinenote-koreader-profile-settings config)
  "Return CONFIG as an alist of KOReader setting name -> tagged Lua value,
sorted by name.  Sorted rather than in field order so the generated file is
stable under any reordering of the record."
  (define fonts (pinenote-koreader-profile-fonts config))
  (define base
    `(("closed_rotation_mode"
       . ,(pinenote-koreader-profile-closed-rotation-mode config))
      ("copt_b_page_margin"
       . ,(pinenote-koreader-profile-bottom-margin config))
      ("copt_font_size" . ,(pinenote-koreader-profile-font-size config))
      ("copt_h_page_margins"
       . (array . ,(pinenote-koreader-profile-side-margins config)))
      ("copt_t_page_margin" . ,(pinenote-koreader-profile-top-margin config))
      ("coverbrowser_initial_default_setup_done"
       . ,(pinenote-koreader-profile-coverbrowser-first-run-done? config))
      ("cre_header_auto_refresh"
       . ,(pinenote-koreader-profile-header-auto-refresh-seconds config))
      ("cre_partial_rerendering"
       . ,(pinenote-koreader-profile-partial-rerendering? config))
      ("cre_show_progress"
       . ,(pinenote-koreader-profile-show-progress? config))
      ("flash_keyboard" . ,(pinenote-koreader-profile-flash-keyboard? config))
      ("avoid_flashing_ui"
       . ,(pinenote-koreader-profile-avoid-flashing-ui? config))
      ("pinenote_flash_area_fraction"
       . ,(pinenote-koreader-profile-flash-area-fraction config))
      ("flash_ui" . ,(pinenote-koreader-profile-flash-ui? config))
      ("full_refresh_count"
       . ,(pinenote-koreader-profile-full-refresh-count config))
      ("home_dir" . ,(pinenote-koreader-profile-home-dir config))
      ("lock_rotation" . ,(pinenote-koreader-profile-lock-rotation? config))
      ("quickstart_shown_version"
       . ,(pinenote-koreader-profile-quickstart-shown-version config))
      ("refresh_on_pages_with_images"
       . ,(pinenote-koreader-profile-refresh-on-pages-with-images? config))
      ("screensaver_type"
       . ,(pinenote-koreader-profile-screensaver-type config))))
  ;; All three or none: one field, one branch.
  (define font-settings
    (if fonts
        `(("cre_font" . ,(pinenote-koreader-font-aliases-serif fonts))
          ("monospace_font"
           . ,(pinenote-koreader-font-aliases-monospace fonts))
          ("cre_font_family_fonts"
           . (table
              ("serif" . ,(pinenote-koreader-font-aliases-serif fonts))
              ("sans-serif"
               . ,(pinenote-koreader-font-aliases-sans-serif fonts))
              ("monospace"
               . ,(pinenote-koreader-font-aliases-monospace fonts)))))
        '()))
  (sort (append base font-settings)
        (lambda (a b) (string<? (car a) (car b)))))

(define (pinenote-koreader-profile->lua config)
  "Serialize CONFIG to the text of KOReader's settings file."
  (string-append
   "-- seeded by the wilkbook reader flavor"
   " (pinenote-koreader-profile-service-type).\n"
   "-- Generated from a record; edit the record, not this file.\n"
   "-- KOReader rewrites this file from here on.\n"
   "return {\n"
   (string-concatenate
    (map (match-lambda
           ((k . v)
            (string-append "    " (lua-key k) " = " (lua-value v "    ")
                           ",\n")))
         (pinenote-koreader-profile-settings config)))
   "}\n"))

(define (pinenote-koreader-profile-activation config)
  (let ((file (pinenote-koreader-profile-settings-file config))
        (text (pinenote-koreader-profile->lua config)))
    ;; Seed once and never overwrite an on-device choice.  On this image
    ;; "absent" means a fresh reflash, because /root comes from the image.
    #~(let ((f #$file))
        (unless (file-exists? f)
          (mkdir-p (dirname f))
          (call-with-output-file f
            (lambda (port) (display #$text port)))))))

(define pinenote-koreader-profile-service-type
  (service-type
   (name 'pinenote-koreader-profile)
   (extensions
    (list (service-extension activation-service-type
                             pinenote-koreader-profile-activation)))
   (default-value (pinenote-koreader-profile-configuration))
   (description
    "Seed KOReader's settings profile on a fresh image, from a record whose
fields declare each default exactly once.  Writes only when the settings file
is absent.")))
