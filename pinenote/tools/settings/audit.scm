;;; Source-only configuration inventory. Guile core modules, no Guix evaluation.
;;; Each observation carries its source span so the self-test can mutate EVERY
;;; extraction, including individual members of multi-match inventories.
(use-modules (ice-9 match) (ice-9 regex) (ice-9 textual-ports)
             (srfi srfi-1) (srfi srfi-13))

(define (slurp path) (call-with-input-file path get-string-all))
(define (normal text) (string-join (string-tokenize text) " "))
(define (hits pattern text)
  (list-matches (make-regexp pattern) text))

;; Blank comments without moving offsets or erasing quoted strings. Reject
;; unterminated comments/strings rather than letting prose satisfy an extractor.
;; This is a lexer for the source forms below, not a language evaluator.
(define (uncomment text language)
  (let* ((out (string-copy text)) (n (string-length text)))
    (define (at? s i) (string-prefix? s text 0 (string-length s) i n))
    (define (blank a b)
      (do ((i a (+ i 1))) ((= i b))
        (unless (char=? (string-ref text i) #\newline)
          (string-set! out i #\space))))
    (let loop ((i 0))
      (when (< i n)
        (let ((c (string-ref text i)))
          (cond
           ((or (char=? c #\")
                (and (eq? language 'lua) (char=? c #\')))
            (let quoted ((j (+ i 1)))
              (when (>= j n) (error "unterminated string"))
              (cond ((char=? (string-ref text j) #\\) (quoted (+ j 2)))
                    ((char=? (string-ref text j) c) (loop (+ j 1)))
                    (else (quoted (+ j 1))))))
           ((and (eq? language 'scheme) (at? "#\\" i))
            (loop (min n (+ i 3))))
           ((or (and (eq? language 'lua) (at? "--[[" i))
                (and (eq? language 'c) (at? "/*" i)))
            (let* ((end-token (if (eq? language 'lua) "]]" "*/"))
                   (end (string-contains text end-token (+ i 2))))
              (unless end (error "unterminated block comment"))
              (blank i (+ end 2)) (loop (+ end 2))))
           ((or (and (eq? language 'scheme) (at? "#|" i))
                (and (eq? language 'lua) (at? "--[=" i)))
            (error "unsupported block comment: extend the audit lexer"))
           ((or (and (eq? language 'scheme) (char=? c #\;))
                (and (eq? language 'lua) (at? "--" i))
                (and (eq? language 'c) (at? "//" i)))
            (let ((end (or (string-index text #\newline i) n)))
              (blank i end) (loop end)))
           (else (loop (+ i 1)))))))
    out))

(define (language path)
  (cond ((string-suffix? ".scm" path) 'scheme)
        ((string-suffix? ".lua" path) 'lua)
        ((string-suffix? ".c" path) 'c)
        (else 'raw)))

;; All positive matches must agree in cardinality as well as value. Missing,
;; duplicate and changed sites fail; a DEBT annotation owns only the exact
;; observed values. Fixing a debt also requires retiring/updating its row.
(define rules '())
(define* (rule id file extract expected #:optional debt)
  (set! rules (append rules (list (list id file extract expected debt)))))
(define (rx pattern)
  (lambda (text)
    (map (lambda (m) (list (normal (match:substring m 1))
                           (match:start m 1) (match:end m 1)))
         (hits pattern text))))
(define* (pin id file pattern expected #:optional debt)
  (rule id file (rx pattern) expected debt))
(define* (literal id file text #:optional debt)
  (pin id file (string-append "(" (regexp-quote text) ")") (list (normal text)) debt))
(define (within pattern extract)
  (lambda (text)
    (let ((ms (hits pattern text)))
      (unless (= 1 (length ms)) (error "missing/ambiguous enclosing site" pattern))
      (let* ((m (car ms)) (start (match:start m 1)))
        (map (match-lambda ((value a b) (list value (+ start a) (+ start b))))
             (extract (match:substring m 1)))))))

(define (read-value-span text start)
  (call-with-input-string (substring text start)
    (lambda (port)
      (let ((value (read port)))
        (when (eof-object? value) (error "missing Scheme value"))
        (list value start (+ start (seek port 0 SEEK_CUR)))))))
(define (record-extractor field)
  (lambda (text)
    (map (lambda (m)
           (let ((start (match:end m)))
             ;; Real Scheme reader handles nested defaults and quoted lists.
             ;; Only read, never eval; source records may contain store objects.
             ;; Read the enclosing field too: a complete value inside an
             ;; unterminated (field accessor (default ... is still malformed.
             (call-with-input-string (substring text (match:start m)) read)
             (read-value-span text start)))
         (hits (string-append "\\(" (regexp-quote field)
                              "[[:space:]]+[-a-zA-Z0-9?]+[[:space:]]+"
                              "\\(default[[:space:]]+") text))))
(define* (record-pin id path field value #:optional debt)
  (rule id path (record-extractor field) (list value) debt))
;; Use the value capture, not the optional field delimiter.
(define (opt key)
  (within "local opt = \\{([^}]*(\\{\\}[^}]*)*)\\}"
          (lambda (text)
            (map (lambda (m) (list (normal (match:substring m 2))
                                   (match:start m 2) (match:end m 2)))
                 (hits (string-append "(^|[ ,\n])" (regexp-quote key)
                                      "[[:space:]]*=[[:space:]]*([^,\n]+)") text)))))

(define services "pinenote/services/")
(define broker "pinenote/packages/platform-controls/pinenote-power-broker.lua")
(define legacy "pinenote/tools/power/autosuspend.lua")
(define boost "pinenote/tools/power/ddr-boost.lua")
(define dmc (string-append services "dmc.scm"))
(define reader "pinenote/systems/pinenote-reader.scm")
(define device "pinenote/packages/koreader-device/frontend/device/pinenote/device.lua")
(define profile (string-append services "koreader-profile.scm"))
(define replay "pinenote/tools/ebc-logic/ebc-replay.c")

;; Shipping owner and direct-display values. The broker has no configuration
;; record yet; do not equate its defaults with the retired daemon's record.
(literal "shipping:broker-service" reader "(service pinenote-platform-controls-service-type)")
(pin "shipping:no-retired-autosuspend" reader "(\\(service pinenote-autosuspend-service-type)" '())
(literal "shipping:direct-params-service" reader "(service pinenote-ebc-direct-params-service-type)")
(pin "broker:config-path-precedence" broker "local CONFIGS = \\{([^}]+)\\}"
     '("\"/data/wilkbook/autosuspend.conf\", \"/var/lib/pinenote/autosuspend.conf\", \"/run/wilkbook-power/inhibit.conf\""))
(pin "broker:timing-defaults" broker "local BACKSTOP, ACK_TIMEOUT, POWER_GRACE = ([^\n]+)"
     '("3600, 10, 2"))
(pin "broker:rtc-settle-default" broker "local RTC_SETTLE = ([^\n]+)" '("20"))
(pin "broker:initial-defaults" broker "local config = \\{([^}]+)\\}"
     '("enabled = true, charging = false, backstop = BACKSTOP, rtc_settle = RTC_SETTLE"))
(pin "broker:idle-warning-state" broker "local warned_idle = ([^\n]+)" '("false"))
(pin "broker:reload-defaults" broker
     "config.enabled, config.charging, config.backstop, config.rtc_settle = ([^\n]+)"
     '("true, false, BACKSTOP, RTC_SETTLE"))
(literal "broker:ordered-files" broker "for _, path in ipairs(CONFIGS) do")
(pin "broker:keys" broker "key == \"([^\"]+)\""
     '("enabled" "backstop" "suspend_while_charging" "rtc_settle" "idle"))
(literal "broker:line-grammar" broker
         "line:match(\"^%s*([%w_]+)%s*=%s*(%S+)\")")
(pin "broker:enabled-denylist" broker "then config.enabled = ([^\n]+)"
     '("not (value == \"0\" or value == \"false\" or value == \"no\")"))
(pin "broker:charging-allowlist" broker "then config.charging = ([^\n]+)"
     '("value == \"1\" or value == \"true\" or value == \"yes\"")
     "Inherited mixed boolean grammars: enabled=off is true, charging=on is false; unify through schema migration, not a silent parser change.")
(literal "broker:backstop-range" broker
         "key == \"backstop\" and tonumber(value) and tonumber(value) >= 30 then config.backstop = math.floor(value)")
(literal "broker:rtc-settle-range" broker
         "key == \"rtc_settle\" and tonumber(value) and tonumber(value) >= 20 then config.rtc_settle = math.min(3600, math.floor(value))")
(literal "broker:obsolete-idle" broker "key == \"idle\" and not warned_idle then")
(pin "broker:no-record" (string-append services "platform-controls.scm")
     "(define-record-type\\*)" '()
     "Runtime keys and paths still lack a Guix configuration record. Add a serializer with defined precedence before retiring this inventory.")
(pin "direct:sysfs-values" (string-append services "ebc-direct.scm")
     "\\(put (\"[^\"]+\"[[:space:]]+\"[^\"]+\")\\)"
     '("\"temp_override\" \"22\"" "\"default_hint\" \"32\""))
(for-each (lambda (file)
            (pin (string-append "direct:no-modprobe-copy:" file) file
                 "(options rockchip_ebc [^\"\n]+)" '()))
          (list (string-append services "ebc.scm") "pinenote/packages/firmware.scm"))
(pin "direct:no-set-parameter-copy" "pinenote/packages/firmware.scm" "(set_parameter )" '())
(pin "direct:no-qemu-waveform" "pinenote/scripts/qemu/run-virt-assertions.sh"
     "(VIRTCHK-WF-[0-9]+)" '())
(record-pin "direct:profile-flash-fraction" profile "flash-area-fraction" 0.98)
(pin "direct:device-flash-fraction" device "local flash_area_fraction = ([0-9.]+)" '("0.98"))

;; Retain all fifteen record/default pairs from the old gate. Fixed values
;; make a coordinated change visible too; change the inventory deliberately.
(define (pairs service lua rows)
  (for-each
   (match-lambda
     ((field key scm-value lua-value)
      (let ((id (string-append (if (string=? service "autosuspend") "legacy:" "") service ":" field))
            (debt (and (string=? field "hwclock")
                       "Store-path service default versus hand-run PATH lookup; retire with a shared serializer.")))
        (record-pin (string-append id ":record") (string-append services service ".scm") field scm-value debt)
        (rule (string-append id ":opt") lua (opt key) (list lua-value) debt)))) rows))
(pairs "autosuspend" legacy
       '(("idle-seconds" "idle" 300 "300") ("backstop-seconds" "backstop" 3600 "3600")
         ("overlay?" "overlay" #t "true")
         ("suspend-while-charging?" "charging_inhibits" #f "true")
         ("config-file" "config" "/var/lib/pinenote/autosuspend.conf" "\"/var/lib/pinenote/autosuspend.conf\"")))
(pairs "ddr-boost" boost
       '(("hold-seconds" "hold" 10 "10")
         ("config-file" "config" "/var/lib/pinenote/ddr-boost.conf" "\"/var/lib/pinenote/ddr-boost.conf\"")))
(pairs "timesync" "pinenote/tools/timesync/timesync.lua"
       '(("servers" "servers" (quote ()) "{}") ("poll-seconds" "poll" 120 "120")
         ("refresh-seconds" "refresh" 21600 "21600") ("timeout-seconds" "timeout" 5 "5")
         ("max-backoff-seconds" "max_backoff" 3600 "3600")
         ("not-before" "not_before" 1767225600 "1767225600")
         ("horizon-seconds" "horizon" 630720000 "630720000")
         ("hwclock" "hwclock" (file-append util-linux "/sbin/hwclock") "\"hwclock\"")))

;; Retired-driver self-heal and replay are still exercised by legacy tools.
;; These are compatibility assertions, NOT direct driver's production policy.
(pin "legacy:waveform-self-heal" legacy "local WAVEFORM_SHIPPED = \"([0-9]+)\"" '("6"))
(pin "legacy:waveform-transient" legacy "if saved == \"([0-9]+)\" then saved = WAVEFORM_SHIPPED" '("4"))
(pin "legacy:reader-self-heal" (string-append services "reader-session.scm")
     "(if prior == '4' then prior = '[0-9]+' end)" '("if prior == '4' then prior = '6' end"))
(pin "legacy:washer-transient" "pinenote/packages/koreader-device/plugins/idlewasher.koplugin/main.lua"
     "GC16 = \"([0-9]+)\"" '("4"))
(rule "legacy:replay-policy" replay
      (within "static void policy_ship\\(struct policy \\*p\\)\n\\{([^}]+)\\}"
              (rx "p->([a-z_]+[[:space:]]*=[[:space:]]*[^;]+);"))
      '("flash_frac = 0.98" "default_wf = DRM_EPD_WF_GC16"
        "refresh_wf = DRM_EPD_WF_GL16" "auto_refresh = false"
        "refresh_threshold = 60" "split_area_limit = 0" "defio_bands = true"
        "defio_delay_ms = 250" "temp_c = 25"))
(rule "legacy:replay-zero-initialization" replay
      (within "static void policy_ship\\(struct policy \\*p\\)\n\\{([^}]+)\\}"
              (rx "(memset\\(p, 0, sizeof\\(\\*p\\)\\))"))
      '("memset(p, 0, sizeof(*p))"))
;; This banner is in a C comment; explicitly scan the raw source for this one.
(define raw-rules '("legacy:replay-banner"))
(pin "legacy:replay-banner" replay "the device is[[:space:]*]+~?([0-9]+) ms" '("250"))
(rule "legacy:waveform-enum" "pinenote/patches/linux-pinenote-7.0-forward-port.patch"
      (within "\\+enum drm_epd_waveform \\{\n((\\+[^\n]*\n)*)\\+\\};"
              (rx "DRM_EPD_WF_([A-Z0-9_]+),"))
      '("RESET" "A2" "DU" "DU4" "GC16" "GCC16" "GL16" "GLR16" "GLD16"))

(for-each
 (match-lambda
   ((id file pattern expected debt) (pin id file pattern expected debt)))
 `(("legacy:runtime-defaults" ,legacy "local runtime = \\{([^}]+)\\}"
    ("idle = nil, backstop = nil, enabled = true, charging = nil, power_key = nil") #f)
   ("ddr-boost:runtime-defaults" ,boost "local runtime = \\{([^}]+)\\}"
    ("hold = nil, enabled = false") "Boost is opt-in; its enabled default differs deliberately from suspend's. Names are file-scoped.")
   ("legacy:persistent-path" ,legacy "local persistent_config = \"([^\"]+)\""
    ("/data/wilkbook/autosuspend.conf") "Persistent path has no record field; legacy compatibility only.")
   ("dmc:persistent-path" ,dmc "\\(define %mode-file \"([^\"]+)\"\\)"
    ("/data/wilkbook/dmc.conf") #f)))
(for-each
 (match-lambda
   ((file label keys)
    (pin (string-append label ":keys") file "k == \"([^\"]+)\"" keys)
    (literal (string-append label ":line-grammar") file "line:match(\"^%s*([%w_]+)%s*=%s*(%S+)\")")))
 `((,legacy "legacy" ("idle" "backstop" "enabled" "suspend_while_charging" "power_key"))
   (,boost "ddr-boost" ("hold" "enabled"))))
(for-each
 (match-lambda
   ((id file field expression debt)
    (rule id file
          (within (if (string=? file legacy)
                      "local function parse_config\\(path\\)(.*)f:close\\(\\)\nend\n\nlocal function reload_config"
                      "local function reload_config\\(\\)(.*)f:close\\(\\)\nend\nlocal function hold_secs")
                  (rx (string-append "\n[ \t]*runtime\\." field " = ([^\n]+)")))
          (list expression) debt)))
 `(("legacy:enabled-grammar" ,legacy "enabled" "not (v == \"0\" or v == \"false\" or v == \"no\")" #f)
   ("legacy:power-key-grammar" ,legacy "power_key" "not (v == \"0\" or v == \"false\" or v == \"no\")" #f)
   ("legacy:charging-grammar" ,legacy "charging" "(v == \"1\" or v == \"true\" or v == \"yes\")" "Inherited allowlist differs from enabled denylist; migrate together.")
   ("ddr-boost:enabled-grammar" ,boost "enabled" "(v == \"1\" or v == \"true\" or v == \"yes\")" "Inherited allowlist differs from suspend enabled; migrate explicitly.")))
(literal "legacy:precedence" legacy "parse_config(persistent_config)\n    parse_config(opt.config)")
(for-each
 (match-lambda
   ((service fields)
    (for-each
     (lambda (field)
       (rule (string-append "unmodelled:" service ":" field)
             (string-append services service ".scm") (record-extractor field) '()
             "Runtime-only knob: adding a record retires this absence pin; wire its serializer then.")) fields)))
 '(("autosuspend" ("enabled?" "power-key-suspends?" "persistent-config"))
   ("ddr-boost" ("enabled?")) ("dmc" ("mode"))))
(literal "dmc:whitespace-grammar" dmc "(string-prefix? \"mode=\" line)"
         "DMC rejects leading whitespace accepted by Lua config parsers; default remains off. Migrate, do not silently reinterpret old files.")
(rule "dmc:selector-defaults-and-precedence" dmc
      (lambda (text)
        (map (lambda (m) (read-value-span text (match:end m)))
             (hits "\\(define mode[[:space:]]+" text)))
      '((catch #t
          (lambda ()
            (if (file-exists? %mode-file)
                (call-with-input-file %mode-file
                  (lambda (port)
                    (let loop ()
                      (let ((line (read-line* port)))
                        (cond
                         ((eof-object? line) "off")
                         ((string-prefix? "mode=" line)
                          (let ((v (string-trim-both (substring line 5))))
                            (if (member v '("normal" "noswitch" "off")) v "off")))
                         (else (loop)))))))
                "off"))
          (lambda _ "off"))))

(define (observe rule source)
  (match rule
    ((id file extract expected debt)
     (extract (if (member id raw-rules) source (uncomment source (language file)))))))
(define (rule-result rule source)
  (catch #t
    (lambda ()
      (let ((values (map car (observe rule source))))
        (if (equal? values (list-ref rule 3)) #f
            (format #f "~a: expected ~s; observed ~s"
                    (if (list-ref rule 4) "DEBT CHANGED/stale inventory" "drift or missing/ambiguous site")
                    (list-ref rule 3) values))))
    (lambda (key . args) (format #f "malformed/missing site: ~s ~s" key args))))
(define (audit root)
  (let ((cache (make-hash-table)) (failed 0) (passed 0) (debts 0))
    (for-each
     (lambda (r)
       (match r
         ((id file extract expected debt)
          (let ((problem
                 (catch #t
                   (lambda ()
                     (let ((text (or (hash-ref cache file)
                                     (let ((s (slurp (string-append root "/" file))))
                                       (hash-set! cache file s) s))))
                       (rule-result r text)))
                   (lambda (key . args) (format #f "source unavailable: ~a" file)))))
            (cond (problem (set! failed (+ failed 1))
                           (format #t "FAIL: ~a: ~a~%" id problem))
                  (debt (set! debts (+ debts 1))
                        (format #t "DEBT: ~a: ~a~%" id debt))
                  (else (set! passed (+ passed 1)) (format #t "PASS: ~a~%" id))))))) rules)
    (format #t "settings-check: ~a passed, ~a pinned debt observations, ~a failed~%" passed debts failed)
    (zero? failed)))
