#!/usr/bin/env guile
!#
(load (string-append (dirname (current-filename)) "/audit.scm"))
(define root
  (if (= (length (command-line)) 2) (cadr (command-line))
      (canonicalize-path (string-append (dirname (current-filename)) "/../../.."))))
(define passed 0)
(define failed 0)
(define (check label ok)
  (if ok (set! passed (+ passed 1)) (set! failed (+ failed 1)))
  (format #t "~a: ~a~%" (if ok "PASS" "FAIL") label))
(define (replace-span text a b new)
  (string-append (substring text 0 a) new (substring text b)))
(define sources
  (map (lambda (file) (cons file (slurp (string-append root "/" file))))
       (delete-duplicates (map cadr rules))))

;; Positive controls are generated from the ACTUAL spans the extractor read,
;; not copies of its regex. Every extracted member must fail both when absent
;; and when changed. Adding an extraction automatically adds these controls.
(for-each
 (lambda (r)
   (let* ((id (car r)) (text (assoc-ref sources (cadr r)))
          (problem (rule-result r text)))
     (check (string-append "baseline " id) (not problem))
     (when problem (format #t "  ~a~%" problem))
     (unless problem
       (let ((observations (observe r text)))
         (for-each
          (match-lambda
            ((value a b)
             (check (string-append "remove " id " " (object->string value))
                    (and (< a b) (rule-result r (replace-span text a b ""))))
             (check (string-append "drift " id " " (object->string value))
                    (rule-result r (replace-span text a b "MUTATED"))))) observations))))) rules)

;; Absence assertions need planted positives; deleting an absent thing proves
;; nothing. Cover every negative rule, and fail if a future one has no fixture.
(define planted
  '(("shipping:no-retired-autosuspend" . "(service pinenote-autosuspend-service-type)")
    ("broker:no-record" . "(define-record-type* <broker>)")
    ("direct:no-modprobe-copy:pinenote/services/ebc.scm" . "\"options rockchip_ebc temp_override=99\"")
    ("direct:no-modprobe-copy:pinenote/packages/firmware.scm" . "\"options rockchip_ebc temp_override=99\"")
    ("direct:no-set-parameter-copy" . "\"set_parameter temp_override 99\"")
    ("direct:no-qemu-waveform" . "VIRTCHK-WF-6")
    ("unmodelled:autosuspend:enabled?" . "(enabled? accessor (default #t))")
    ("unmodelled:autosuspend:power-key-suspends?" . "(power-key-suspends? accessor (default #t))")
    ("unmodelled:autosuspend:persistent-config" . "(persistent-config accessor (default \"/data/wilkbook/autosuspend.conf\"))")
    ("unmodelled:ddr-boost:enabled?" . "(enabled? accessor (default #f))")
    ("unmodelled:dmc:mode" . "(mode accessor (default \"off\"))")))
(for-each
 (lambda (r)
   (when (null? (list-ref r 3))
     (let* ((id (car r)) (fixture (assoc-ref planted id)))
       (check (string-append "plant forbidden/stale-debt site " id)
              (and fixture (rule-result r (string-append (assoc-ref sources (cadr r)) "\n" fixture "\n"))))))) rules)

;; Exercise the I/O boundary too: a missing tree must not turn negative-only
;; rules into successes. No source is ever read from the real tree as fallback.
(let ((dir (mkdtemp "/tmp/opencode/settings-empty-XXXXXX")))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let ((result #t))
        (let ((output (with-output-to-string (lambda () (set! result (audit dir))))))
          (check "absent source tree is rejected" (not result))
          (check "missing negative-only source is named"
                 (string-contains output "source unavailable: pinenote/services/platform-controls.scm")))))
    (lambda () (rmdir dir))))

;; Parser/extractor fixtures independent of today's file formatting.
(define rec (record-extractor "value"))
(check "nested Scheme default is read as data"
       (equal? (map car (rec "(value accessor (default (file-append pkg \"a;b\")))"))
               '((file-append pkg "a;b"))))
(check "comments do not supply record defaults"
       (null? (rec (uncomment "; (value accessor (default 1))\n" 'scheme))))
(let ((r (list "fixture" "fixture.scm" rec '(10) #f)))
  (check "duplicate record field fails"
         (rule-result r "(value a (default 10)) (value b (default 10))"))
  (check "malformed nested default fails"
         (rule-result r "(value a (default (broken"))
  (check "unterminated field with a valid scalar fails"
         (rule-result r "(value a (default 10"))
  (check "unterminated string fails" (rule-result r "(value a (default \"broken"))
  (check "comment cannot hide a removed field"
         (rule-result r "; (value a (default 10))")))
(let ((r (list "fixture" "fixture.lua" (opt "idle") '("300") #f)))
  (check "Lua comments cannot supply a default"
         (rule-result r "local opt = {\n-- idle = 300,\n}"))
  (check "duplicate Lua defaults fail"
         (rule-result r "local opt = {\n idle = 300, idle = 300,\n}"))
  (check "malformed opt table fails" (rule-result r "local opt = { idle = 300,")))
(check "Lua strings preserve comment tokens"
       (string=? (uncomment "local x = \"--ok\" -- comment\n" 'lua)
                 "local x = \"--ok\"           \n"))
(format #t "settings self-test: ~a passed, ~a failed~%" passed failed)
(exit (zero? failed))
