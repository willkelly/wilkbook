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
(define %power-controls-ready "/run/wilkbook-power/ready")

;; Blank the panel to clean white and run one global refresh, so the
;; boot console text does not linger on the e-ink (which retains it
;; unpowered) for the several seconds KOReader takes to start.  Runs via
;; the bundle's own luajit: Guile cannot issue the DRM ioctl, and the
;; ffi below beats shipping a C helper.  Best-effort on purpose — on
;; qemu-virt the ioctl fails harmlessly (no EBC), and a missing fb0
;; just skips the fill.  The fill must be fsync'd before the ioctl:
;; deferred-io holds fbdev damage for defio_delay_ms and fsync on the
;; fb fd is the publish, so an unpublished fill lets the refresh run
;; against the OLD framebuffer content — repainting the boot console
;; instead of washing it (found 2026-08-06 after a boot whose wash
;; failed to clear the console).
;;
;; The wash runs as GC16 regardless of the shipped refresh_waveform:
;; under the GL16 policy a global never drives believed-white pixels,
;; so residue of the boot text would survive every subsequent wash.
;; One deliberate GC16 deep clean here scrubs it (hardware-validated
;; 2026-07-05, when exactly that residue was observed and a live GC16
;; wash removed it); the shipped waveform is restored afterwards.
(define %panel-blank-lua "
local ffi = require('ffi')
ffi.cdef('int open(const char*,int); long write(int,const void*,unsigned long); int fsync(int); int close(int); int ioctl(int,unsigned long,...); int poll(void*,unsigned long,int);')
local C = ffi.C
local fb = C.open('/dev/fb0', 1)
if fb >= 0 then
  local n = 1048576
  local buf = ffi.new('uint8_t[?]', n)
  ffi.fill(buf, n, 0xFF)
  while C.write(fb, buf, n) > 0 do end
  C.fsync(fb)
  C.close(fb)
end
local wf = '/sys/module/rockchip_ebc/parameters/refresh_waveform'
local prior
local f = io.open(wf, 'r')
if f then prior = f:read('*l'); f:close() end
-- 4 is only ever a wash transient: reading it back means an earlier
-- wash (here or the autosuspend resume wash) died between set and
-- restore, and re-saving it would poison every later save/restore
-- cycle.  Restore the shipped value (services/ebc.scm) instead so any
-- interrupted or interleaved sequence self-heals on the next cycle.
if prior == '4' then prior = '6' end
local function set_wf(v)
  local g = io.open(wf, 'w')
  if g then g:write(v); g:close(); return true end
  return false
end
local deep = (prior ~= nil) and set_wf('4')
-- The EBC's DRM card index is not stable across images (on the
-- direct-mode image the panfrost GPU takes card0, and a wash aimed
-- there is a malformed GPU job -- 2026-08-25); resolve by driver name
-- via sysfs, which needs no root and, unlike open()ing candidates,
-- cannot make this process DRM master of the GPU.
local ebc_card
for n = 0, 63 do
  local u = io.open('/sys/class/drm/card' .. n .. '/device/uevent', 'r')
  if u then
    for line in u:lines() do
      if line == 'DRIVER=rockchip-ebc' then ebc_card = '/dev/dri/card' .. n end
    end
    u:close()
    if ebc_card then break end
  end
end
if ebc_card == nil then
  io.stderr:write('panel-wash: no DRM card with driver rockchip-ebc\\n')
end
local card = ebc_card and C.open(ebc_card, 2) or -1
if card >= 0 then
  local arg = ffi.new('uint8_t[1]', 1)
  local rc = C.ioctl(card, 0xC0016440, arg)
  if rc ~= 0 then
    io.stderr:write('panel-wash: global-refresh ioctl rc=' .. rc .. ' errno=' .. ffi.errno() .. '\\n')
  end
  if deep and rc == 0 then C.poll(nil, 0, 3000) end
  C.close(card)
elseif ebc_card then
  io.stderr:write('panel-wash: ' .. ebc_card .. ' open failed errno=' .. ffi.errno() .. '\\n')
end
if deep and not set_wf(prior) then
  io.stderr:write('panel-wash: waveform restore failed\\n')
end
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
    ;; pinenote-library creates /data/books.  Shepherd starts services
    ;; CONCURRENTLY, so without this edge the reader can open its file
    ;; browser before the library exists -- and KOReader does not recover
    ;; from an unresolvable home_dir, it lands in the store directory.
    ;; Like pinenote-dmc, the one-shot exits success even when it does
    ;; nothing, so it can delay the reader but never block it.
    ;; pinenote-ebc-clut: the reader starts only once the CLUT is compiled
    ;; and the driver rebound (decision 9 of the embrace sweep,
    ;; 2026-09-03) -- no race with the first paint.  Off a PineNote the
    ;; one-shot succeeds doing nothing, so this never blocks the rig.
    (requirement '(udev user-processes orientation-bridge
                   pinenote-platform-controls
                   pinenote-waveform pinenote-ebc-direct-params
                   pinenote-ebc-clut
                   pinenote-dmc pinenote-library))
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
         (define (power-control-node-ready?)
           (let loop ((n 0))
             (and (< n 64)
                  (let ((name (string-append "/sys/class/input/event"
                                             (number->string n)
                                             "/device/name")))
                    (if (file-exists? name)
                        (or (call-with-input-file name
                              (lambda (port)
                                (eq? (read port)
                                     'wilkbook-power-control)))
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
         ;; Shepherd considers a forked service started before its process has
         ;; necessarily completed UI_DEV_CREATE.  Do not launch the production
         ;; driver until both the broker marker and named input node exist.
         (let loop ((tries 0))
           (unless (or (and (file-exists? #$%power-controls-ready)
                            (power-control-node-ready?))
                       (>= tries 50))
             (usleep 200000)
             (loop (+ tries 1))))
         (unless (and (file-exists? #$%power-controls-ready)
                      (power-control-node-ready?))
           (error "pinenote-platform-controls did not become ready"))
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
         ;; NOTE: this service does NOT seed KOReader's settings file.  It
         ;; used to, and that copy was DEAD CODE for its whole life: activation
         ;; runs before shepherd services, both writers were gated on the
         ;; file being absent, so the flavor's activation seed always won
         ;; and this one always found the file already there.  On
         ;; 2026-08-05 the six e-ink refresh keys were added here only,
         ;; and an image shipped with none of them.
         ;;
         ;; The one seed, its defaults and the measurement behind each now
         ;; live on the record in (pinenote services koreader-profile).
         ;; Do not add a second writer here; `make koreader-profile-check'
         ;; fails if one appears.
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
     #~(lambda (process . args)
         ;; SIGINT before the kill: KOReader's INT handler runs the CLEAN
         ;; close that flushes the crengine cache, while TERM -- what
         ;; make-kill-destructor leads with -- truncates it to zero bytes
         ;; and silently re-arms the next open's full re-parse (30.3 s
         ;; for the manuals book vs 1.7 s cached, measured on glass
         ;; 2026-08-26; doc/manuals.md).  Two shepherd-1.0.9 facts this
         ;; code depends on, both proven in a scratch shepherd during
         ;; review: (1) the stop procedure receives a <process> RECORD,
         ;; not a pid -- unwrap before any kill, or the whole procedure
         ;; dies on a wrong-type-arg that 'system-error does not catch;
         ;; (2) shepherd's fiberized runtime replaces SLEEP with the
         ;; cooperative version but NOT usleep -- a usleep poll blocks
         ;; PID 1 whole, starves the SIGCHLD reaper fiber, and the exit
         ;; can never be observed.  (sleep 1/10) yields; the reviewed
         ;; lab run stopped a clean-exiting reader in 0.65 s.  Up to 8 s
         ;; of courtesy, then the normal destructor handles a reader
         ;; that is wedged or ignoring INT.  A clean INT exit skips the
         ;; destructor's process-GROUP sweep, so KOReader-spawned
         ;; children can outlive the stop; the start path's stale-reader
         ;; cleanup covers them, and INT is an orderly app shutdown.
         (let ((pid (if (integer? process) process (process-id process))))
           (define (alive? p)
             (catch 'system-error
               (lambda () (kill p 0) #t)
               (lambda _ #f)))
           (catch 'system-error
             (lambda () (kill pid SIGINT))
             (lambda _ #f))
           (let loop ((tries 80))
             (when (and (alive? pid) (positive? tries))
               (sleep 1/10)
               (loop (- tries 1))))
           (let ((stopped (if (alive? pid)
                              ((make-kill-destructor) process)
                              #f)))
             ;; restore the text console as a rescue path
             (when (file-exists? #$%fbcon-bind)
               (call-with-output-file #$%fbcon-bind
                 (lambda (port) (display "1" port))))
             stopped)))))))

(define pinenote-reader-session-service-type
  (service-type
   (name 'pinenote-reader-session)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-reader-session-shepherd-service)))
   (default-value #f)
   (description "Run KOReader natively on the PineNote framebuffer.")))
