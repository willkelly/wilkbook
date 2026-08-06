(define-module (pinenote services reader-session)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages fonts)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-reader-session-service-type))

;; KOReader running natively on the framebuffer - no compositor, no SDL.
;; The koreader-bin package grafts a "pinenote" device target into the
;; bundle (fbdev output on /dev/fb0, pure-Lua evdev input, full-refresh
;; via the EBC driver's global-refresh ioctl), the same architecture
;; KOReader uses on Kobo hardware.  See doc/koreader-spike.md for why
;; the cage/SDL kiosk was abandoned: SDL3's Wayland backend cannot
;; present without GL/Vulkan, neither of which exists on the device.
;;
;; fbcon is unbound before launch: with console=tty0 on the cmdline,
;; every kernel message would otherwise redraw the text console over
;; KOReader's framebuffer content (first-light finding, 2026-07-05).
;; It is re-bound on stop so the console comes back as a rescue path.
;;
;; v1 runs as root; unprivileged hardening is follow-up work.

(define %fbcon-bind "/sys/class/vtconsole/vtcon1/bind")

(define %orientation-ready "/run/wilkbook-orientation.ready")
(define %orientation-consumer "/run/wilkbook-orientation.consumer")

;; Blank the panel to clean white and run one global refresh, so the
;; boot console text does not linger on the e-ink (which retains it
;; unpowered) for the several seconds KOReader takes to start.  Runs via
;; the bundle's own luajit: Guile cannot issue the DRM ioctl, and the
;; ffi below beats shipping a C helper.  Best-effort on purpose — on
;; qemu-virt the ioctl fails harmlessly (no EBC), and a missing fb0
;; just skips the fill.
;;
;; The wash runs as GC16 regardless of the shipped refresh_waveform:
;; under the GL16 policy a global never drives believed-white pixels,
;; so residue of the boot text would survive every subsequent wash.
;; One deliberate GC16 deep clean here scrubs it (hardware-validated
;; 2026-07-05, when exactly that residue was observed and a live GC16
;; wash removed it); the shipped waveform is restored afterwards.
(define %panel-blank-lua "
local ffi = require('ffi')
ffi.cdef('int open(const char*,int); long write(int,const void*,unsigned long); int close(int); int ioctl(int,unsigned long,...); int poll(void*,unsigned long,int);')
local C = ffi.C
local fb = C.open('/dev/fb0', 1)
if fb >= 0 then
  local n = 1048576
  local buf = ffi.new('uint8_t[?]', n)
  ffi.fill(buf, n, 0xFF)
  while C.write(fb, buf, n) > 0 do end
  C.close(fb)
end
local wf = '/sys/module/rockchip_ebc/parameters/refresh_waveform'
local prior
local f = io.open(wf, 'r')
if f then prior = f:read('*l'); f:close() end
local function set_wf(v)
  local g = io.open(wf, 'w')
  if g then g:write(v); g:close(); return true end
  return false
end
local deep = (prior ~= nil) and set_wf('4')
local card = C.open('/dev/dri/card0', 2)
if card >= 0 then
  local arg = ffi.new('uint8_t[1]', 1)
  local rc = C.ioctl(card, 0xC0016440, arg)
  if deep and rc == 0 then C.poll(nil, 0, 3000) end
  C.close(card)
end
if deep then set_wf(prior) end
")

(define (pinenote-reader-session-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(reader-session))
    ;; the EBC module is loaded from the initrd, but the waveform
    ;; install and param application order ahead of anything that
    ;; would light the panel.  pinenote-dmc orders the DDR drop (and
    ;; its fbcon-quiesce window) ahead of the reader; it exits success
    ;; even on failure, so it can delay the reader but never block it.
    (requirement '(udev user-processes orientation-bridge
                   pinenote-waveform pinenote-ebc-params
                   pinenote-dmc))
    (documentation "KOReader running natively on the e-ink framebuffer.")
    (respawn? #t)
    (start
     #~(lambda args
         (define (orientation-node-ready?)
           (let loop ((n 0))
             (and (< n 64)
                  (let ((name (string-append "/sys/class/input/event"
                                             (number->string n)
                                             "/device/name")))
                    (if (file-exists? name)
                        (or (call-with-input-file name
                              (lambda (port)
                                (eq? (read port)
                                     'wilkbook-orientation)))
                            (loop (+ n 1)))
                        (loop (+ n 1)))))))
         ;; don't race the fb node on a slow module load; respawn
         ;; still covers the pathological case
         (let loop ((tries 0))
           (unless (or (file-exists? "/dev/fb0")
                       (>= tries 50))
             (usleep 200000)
             (loop (+ tries 1))))
          ;; The bridge marker exists only after UI_DEV_CREATE and named-evdev
          ;; discovery, not merely after its process has forked.
         (let loop ((tries 0))
           (unless (or (and (file-exists? #$%orientation-ready)
                            (orientation-node-ready?))
                       (>= tries 50))
             (usleep 200000)
             (loop (+ tries 1))))
         (unless (and (file-exists? #$%orientation-ready)
                      (orientation-node-ready?))
           (error "wilkbook-orientation did not become ready"))
         ;; This marker belongs to the evdev fd opened by one KOReader
         ;; process. Removing it pauses the bridge until the new reader opens
         ;; the named node and recreates the marker.
         (when (file-exists? #$%orientation-consumer)
           (delete-file #$%orientation-consumer))
         ;; the panel has ONE owner: kill any stray KOReader before
         ;; starting ours.  An optics-session viewer left running fought
         ;; the reading instance for the framebuffer on 2026-07-13 --
         ;; two shadow buffers flushing to one fb rendered as overstruck
         ;; text and stale bands (doc/status.md).
         (system* "/run/current-system/profile/bin/pkill" "-f" "reader\\.lua")
         (sleep 1)
         ;; keep fbcon off the panel while the reader owns it
         (when (file-exists? #$%fbcon-bind)
           (call-with-output-file #$%fbcon-bind
             (lambda (port) (display "0" port))))
         ;; wash the boot text off the panel before KOReader appears
         (when (file-exists? "/dev/fb0")
           (system* #$(file-append koreader-bin "/lib/koreader/luajit")
                    "-e" #$%panel-blank-lua))
         ;; Seed KOReader defaults once, and never overwrite on-device
         ;; choices -- this only writes when the file is absent, which on
         ;; this image means a fresh reflash (/root comes from the image).
         ;;
         ;; Two of these are e-ink refresh policy, not taste, and cost real
         ;; panel time when left at KOReader's defaults (measured on glass
         ;; 2026-08-04/05; doc/refresh-policy.md):
         ;;
         ;;   cre_show_progress=false -- ReaderRolling:showEngineProgress()
         ;;     paints a progress bar during a crengine re-render and calls
         ;;     Screen:refreshFast() every 500 ms.  publish() is fsync on
         ;;     the fbdev fd and deferred-io tracks dirty PAGES, not the
         ;;     intent's rect, so each tick republishes the whole pending
         ;;     re-render as a full-screen ~38-frame pass (~0.8 s).  A
         ;;     progress indicator that costs 0.8 s per 0.5 s tick makes the
         ;;     operation it reports on slower.  Upstream added this key for
         ;;     the same reason on SDL-over-SSH.  Rotations without it cost
         ;;     exactly 1 IRQ (one wash); with it, 76+ frames plus the wash.
         ;;
         ;;   cre_partial_rerendering=false -- otherwise crengine
         ;;     re-renders in the background and cycles a status icon
         ;;     (cre.render.partial/working/ready/reload) at 75x75, and a
         ;;     partial refresh costs ~38 frames REGARDLESS of area, so a
         ;;     corner icon costs a full-screen repaint.  Note this one is
         ;;     read per-document first (the book's .sdr sidecar) and only
         ;;     then globally, so this default loses to an existing book's
         ;;     saved value -- it governs newly opened books.
         ;;
         ;;   flash_ui=false -- tap feedback on menu rows, file rows and
         ;;     dialog buttons calls UIManager:forceRePaint() TWICE per tap
         ;;     (highlight, then unhighlight; menu.lua ~527-543).  Cost is
         ;;     per UI tick, not per intent -- within one repaint drain the
         ;;     first publish() empties the deferred-io pagelist and later
         ;;     ones are no-ops -- so what makes this expensive is the two
         ;;     EXTRA ticks, each a full pass.  This was the file-browser
         ;;     double draw.
         ;;
         ;;   flash_keyboard=false -- same mechanism, once per keystroke.
         ;;
         ;;   cre_header_auto_refresh=0 -- ReaderCoptListener:updateHeader()
         ;;     calls document:resetBufferCache() ("be sure next repaint is
         ;;     a redrawing") and setDirty over the full screen width, and
         ;;     reschedules itself every 60 s while the top bar shows a
         ;;     clock.  A whole page redraw plus a full-screen pass, once a
         ;;     minute, forever: ~48 s of panel time per hour of reading for
         ;;     a clock digit.  The clock still updates on every page turn.
         ;;
         ;;   coverbrowser_initial_default_setup_done=true -- CoverBrowser
         ;;     seeds ITSELF on at first launch (main.lua ~84-95, mode
         ;;     "list_image_meta"), then polls every 1 s patching extracted
         ;;     covers into the file browser.  Pre-setting the "already did
         ;;     first-run setup" flag leaves filemanager_display_mode unset,
         ;;     which is the classic filename list.  Note the display modes
         ;;     themselves live in BookInfoManager's sqlite cache, not here,
         ;;     so this prevents the mode being set rather than unsetting it.
         ;;
         ;; The font keys mirror wilkhome's fontconfig aliases
         ;; (serif=Equity, sans=Concourse, mono=Triplicate Code); crengine's
         ;; built-in fallback chain stays in effect below them.
         (let ((settings "/root/.config/koreader/settings.reader.lua"))
           (unless (file-exists? settings)
             (for-each (lambda (dir)
                         (unless (file-exists? dir)
                           (mkdir dir #o700)))
                       '("/root/.config" "/root/.config/koreader"))
             (call-with-output-file settings
               (lambda (port)
                 (display "\
-- seeded by wilkbook reader-session; KOReader rewrites this file
return {
    [\"cre_show_progress\"] = false,
    [\"cre_partial_rerendering\"] = false,
    [\"flash_ui\"] = false,
    [\"flash_keyboard\"] = false,
    [\"cre_header_auto_refresh\"] = 0,
    [\"coverbrowser_initial_default_setup_done\"] = true,
" port)
                 #$@(if pinenote-local-fonts
                        #~((display "\
    [\"cre_font\"] = \"Equity A\",
    [\"monospace_font\"] = \"Triplicate A Code\",
    [\"cre_font_family_fonts\"] = {
        [\"serif\"] = \"Equity A\",
        [\"sans-serif\"] = \"Concourse 4\",
        [\"monospace\"] = \"Triplicate A Code\",
    },
" port))
                        #~())
                 (display "}\n" port)))))
         (apply
          (make-forkexec-constructor
           ;; reader.lua's own shebang is #!./luajit, so run the
           ;; bundled luajit directly from the bundle directory.
           (list #$(file-append koreader-bin "/lib/koreader/luajit")
                 "reader.lua")
           #:directory #$(file-append koreader-bin "/lib/koreader")
           #:environment-variables
           ;; KO_HOME is load-bearing: without it KOReader treats its
           ;; own directory (the read-only store) as the data dir and
           ;; dies in cache init before painting anything - the panel
           ;; shows only framebuffer_linux's white init fill, on a
           ;; respawn loop (found on the 2026-07-05 boot of the first
           ;; native-reader image; reproduced offline in 30 s).
           (list "HOME=/root"
                 "KO_HOME=/root/.config/koreader"
                 "PATH=/run/current-system/profile/bin"
                 "LC_ALL=en_US.UTF-8"
                 ;; KOReader's supported external-font hook; only set
                 ;; when fonts are actually staged in this image
                 #$@(if pinenote-local-fonts
                        #~("EXT_FONT_DIR=/run/current-system/profile/share/fonts/local")
                        #~()))
           #:log-file "/var/log/reader-session.log")
          args)))
    (stop
     #~(lambda (pid . args)
         (let ((stopped ((make-kill-destructor) pid)))
           ;; restore the text console as a rescue path
           (when (file-exists? #$%fbcon-bind)
             (call-with-output-file #$%fbcon-bind
               (lambda (port) (display "1" port))))
           stopped))))))

(define pinenote-reader-session-service-type
  (service-type
   (name 'pinenote-reader-session)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-reader-session-shepherd-service)))
   (default-value #f)
   (description "Run KOReader natively on the PineNote framebuffer.")))
