(define-module (pinenote scripts preflight test-koreader-profile-seed)
  #:use-module (pinenote services koreader-profile)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (run-koreader-profile-seed-tests))

;;; Generative half of `make koreader-profile-check': build the record,
;;; serialize it, and read the result.  validate-koreader-profile.sh runs
;;; it through `guix repl' when guix is on PATH.
;;;
;;; A MODULE WITH NO TOP-LEVEL SIDE EFFECTS, deliberately.  `guix build
;;; -L .' walks every .scm in this tree looking for package modules and
;;; EVALUATES what it finds -- verified 2026-08-24 with a sentinel: a
;;; top-level `format' in this file printed during an unrelated
;;; `guix build koreader-bin'.  A test that ran there would print into
;;; someone else's build log and, on failure, `exit 1' out of it.  So
;;; everything lives inside the procedure below, and the caller runs it.
;;; Do not hoist an expression to the top level.
;;;
;;; WHAT IT PINS, and why each pin is here rather than in the record:
;;;
;;;   * the SET of keys the seed writes, exactly.  Dropping one is the
;;;     2026-08-05 failure (six refresh keys added to the dead seed only,
;;;     image shipped without them) and it is silent -- the device is
;;;     merely slower.  A key set is cheap to re-approve deliberately.
;;;   * the VALUES of the keys that are policy rather than taste: the six
;;;     refresh keys, home_dir, and the quickstart threshold.  Margins,
;;;     font size and screensaver style are taste and are NOT pinned, so
;;;     changing them does not drag this file along.
;;;   * that fonts on and fonts off differ by EXACTLY the three font keys.
;;;     They come from one record field, so no other difference is
;;;     expressible -- this is the check that says so out loud.
;;;
;;; The defaults themselves are declared once, in the record.  This file
;;; asserts what ships; it does not define it.

(define (substring-index haystack needle)
  (let ((hl (string-length haystack)) (nl (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i nl) hl) #f)
            ((string=? (substring haystack i (+ i nl)) needle) i)
            (else (loop (+ i 1)))))))

(define (has? haystack needle)
  (and (substring-index haystack needle) #t))

;; A rendered top-level entry, exactly as it must appear in the file.
(define (entry key value)
  (string-append "    [\"" key "\"] = " value ",\n"))

(define %keys-with-fonts
  '("auto_restore_wifi"
    "avoid_flashing_ui"
    "closed_rotation_mode"
    "copt_b_page_margin"
    "copt_font_size"
    "copt_h_page_margins"
    "copt_t_page_margin"
    "coverbrowser_initial_default_setup_done"
    "cre_font"
    "cre_font_family_fonts"
    "cre_header_auto_refresh"
    "cre_partial_rerendering"
    "cre_show_progress"
    "flash_keyboard"
    "flash_ui"
    "full_refresh_count"
    "home_dir"
    "lock_rotation"
    "monospace_font"
    "pinenote_flash_area_fraction"
    "quickstart_shown_version"
    "refresh_on_pages_with_images"
    "screensaver_type"
    "wifi_was_on"))

(define %font-keys '("cre_font" "cre_font_family_fonts" "monospace_font"))

;; Each costs measured panel time at KOReader's stock default
;; (doc/refresh-policy.md); these are policy, not taste.
(define %policy-values
  '(("cre_show_progress" . "false")
    ("cre_partial_rerendering" . "false")
    ("flash_ui" . "false")
    ("flash_keyboard" . "false")
    ("cre_header_auto_refresh" . "0")
    ;; Wi-Fi returns after every wake (the retired daemon's behavior):
    ;; both keys are required by NetworkListener:onResume, and KOReader
    ;; never sets wifi_was_on itself when a service brought Wi-Fi up.
    ("auto_restore_wifi" . "true")
    ("wifi_was_on" . "true")
    ;; The SHIPPING flavor's flash promotion stays at its validated
    ;; behavior: mandatory UI flashes on, promotion threshold 0.60.
    ;; Only the direct flavor overrides these (ghosting resolved there).
    ("avoid_flashing_ui" . "false")
    ("pinenote_flash_area_fraction" . "0.6")
    ("coverbrowser_initial_default_setup_done" . "true")
    ("full_refresh_count" . "0")
    ("refresh_on_pages_with_images" . "false")
    ("home_dir" . "\"/data/books\"")))

(define (run-koreader-profile-seed-tests)
  "Run the generative seed checks.  Return 0 when they all pass, 1 otherwise."
  (define failures 0)

  (define (check name ok)
    (if ok
        (format #t "PASS: ~a~%" name)
        (begin
          (set! failures (+ failures 1))
          (format #t "FAIL: ~a~%" name))))

  (define (check-equal name expected actual)
    (if (equal? expected actual)
        (format #t "PASS: ~a~%" name)
        (begin
          (set! failures (+ failures 1))
          (format #t "FAIL: ~a~%  expected: ~s~%  actual:   ~s~%"
                  name expected actual))))

  (define with-fonts
    (pinenote-koreader-profile-configuration
     (fonts (pinenote-koreader-font-aliases))))
  (define without-fonts
    (pinenote-koreader-profile-configuration (fonts #f)))

  (define (keys config)
    (map car (pinenote-koreader-profile-settings config)))

  (define lua-with (pinenote-koreader-profile->lua with-fonts))

  ;; --- 0. Controls.  Everything below asks "is this string in the
  ;;        output"; a matcher that always says yes, or an empty output,
  ;;        would pass every one of them.
  (check "control: the renderer produced a non-empty Lua table"
         (and (> (string-length lua-with) 200)
              (has? lua-with "return {")
              (has? lua-with "\n}\n")))
  (check "control: a line that IS present is found"
         (has? lua-with (entry "flash_ui" "false")))
  (check "control: a line that is NOT present is not found"
         (not (has? lua-with (entry "flash_ui" "true"))))
  (check "control: an absent key is reported absent"
         (not (has? lua-with "input_ignore_gsensor")))

  ;; --- 1. The key set, exactly.
  (check-equal "the fonts-present seed writes exactly the shipped key set"
               %keys-with-fonts (keys with-fonts))
  (check-equal "the fonts-absent seed drops exactly the three font keys"
               (lset-difference string=? %keys-with-fonts %font-keys)
               (keys without-fonts))
  (check-equal "fonts on/off differ by nothing except the font keys"
               %font-keys
               (sort (lset-difference string=? (keys with-fonts)
                                      (keys without-fonts))
                     string<?))

  ;; --- 2. The values that are policy, not taste.
  (for-each
   (match-lambda
     ((key . value)
      (check (string-append "policy value: " key " = " value)
             (has? lua-with (entry key value)))))
   %policy-values)

  ;; QuickStart:isShown() is shown_version >= 2021070000; below the
  ;; threshold a first boot opens the guide and never consults home_dir.
  (check "quickstart_shown_version clears the 2021070000 threshold"
         (>= (pinenote-koreader-profile-quickstart-shown-version
              (pinenote-koreader-profile-configuration))
             2021070000))

  ;; --- 3. The record is really the source: overriding a field must move
  ;;        the output.  Without this, a serializer that ignored the
  ;;        record and returned a constant string would pass everything
  ;;        above.
  (let ((text (pinenote-koreader-profile->lua
               (pinenote-koreader-profile-configuration
                (inherit with-fonts)
                (font-size 42)))))
    (check "overriding font-size reaches the generated seed"
           (and (has? text (entry "copt_font_size" "42"))
                (not (has? text (entry "copt_font_size" "30"))))))

  (let ((text (pinenote-koreader-profile->lua
               (pinenote-koreader-profile-configuration
                (inherit with-fonts)
                (home-dir "/data/elsewhere")))))
    (check "overriding home-dir reaches the generated seed"
           (has? text (entry "home_dir" "\"/data/elsewhere\""))))

  ;; One field, three keys: changing the serif alias must move BOTH the
  ;; cre_font key and the family table.  This is the structural
  ;; replacement for "keep the two seeds in sync".
  (let ((text (pinenote-koreader-profile->lua
               (pinenote-koreader-profile-configuration
                (inherit with-fonts)
                (fonts (pinenote-koreader-font-aliases
                        (serif "Concourse 4")))))))
    (check "one font field drives cre_font and cre_font_family_fonts together"
           (and (has? text (entry "cre_font" "\"Concourse 4\""))
                (has? text "[\"serif\"] = \"Concourse 4\",")
                (not (has? text "\"Equity A\"")))))

  ;; --- 4. The seeded path is a field, not a literal buried in a gexp.
  (check-equal "the settings file is the record's default"
               "/root/.config/koreader/settings.reader.lua"
               (pinenote-koreader-profile-settings-file
                (pinenote-koreader-profile-configuration)))

  (if (zero? failures)
      (begin
        (format #t "PASS: the seed generated from the record is what ships~%")
        0)
      (begin
        (format #t "~a check(s) failed~%" failures)
        1)))
