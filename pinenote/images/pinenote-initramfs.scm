(define-module (pinenote images pinenote-initramfs)
  #:use-module (gnu packages linux)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix gexp)
  #:export (%pinenote-display-initrd-modules
            pinenote-initrd
            pinenote-initrd-6.6
            pinenote-initramfs-note
            pinenote-kernel-arguments))

(define pinenote-initramfs-note
  "PineNote initrd keeps storage handling close to Guix defaults, but tries to
bring up the EBC framebuffer before mounting root by reading the local waveform
partition and loading PineNote display modules from the initrd.")

(define %pinenote-display-initrd-modules
  ;; Keep these out of operating-system 'initrd-modules': Guix loads that list
  ;; before the pre-mount hook, but rockchip_ebc needs waveform firmware first.
  '("tps65185"
    "panel-simple"
    "rockchipdrm"
    "rockchip_ebc"))

(define %pinenote-display-initrd-modules-6.6
  ;; Linux 6.6 downstream names the TPS65185 module with the legacy suffix.
  '("tps65185-regulator"
    "panel-simple"
    "rockchipdrm"
    "rockchip_ebc"))

(define* (pinenote-initrd* display-initrd-modules
                           file-systems
                           #:key
                          (linux linux-libre)
                          (linux-modules '())
                          (mapped-devices '())
                          (keyboard-layout #f)
                          qemu-networking?
                          volatile-root?
                          (on-error 'debug))
  (let ((linux-modules*
         `(,@linux-modules
           ,@(file-system-modules file-systems)))
        (helper-packages
         (file-system-packages file-systems
                               #:volatile-root? volatile-root?))
        (display-module-directory
         ((@@ (gnu system linux-initrd) flat-linux-module-directory)
          linux
          display-initrd-modules)))
    (raw-initrd file-systems
                #:linux linux
                #:linux-modules linux-modules*
                #:mapped-devices mapped-devices
                #:helper-packages helper-packages
                #:keyboard-layout keyboard-layout
                #:qemu-networking? qemu-networking?
                #:volatile-root? volatile-root?
                #:on-error on-error
                #:pre-mount
                #~(begin
                    (use-modules (gnu build file-systems)
                                 (gnu build linux-modules)
                                 ((guix build utils) #:select (mkdir-p))
                                 (ice-9 ftw)
                                 (ice-9 rdelim)
                                 (rnrs bytevectors)
                                 (rnrs io ports))

                    (define waveform-bytes (* 2048 1024))
                    (define firmware-directory "/lib/firmware/rockchip")
                    (define firmware-file
                      (string-append firmware-directory "/ebc.wbf"))

                    (define (pinenote-initrd-log message . arguments)
                      (apply format #t
                             (string-append "PineNote initrd: " message "~%")
                             arguments)
                      (force-output))

                    (define (copy-prefix source destination bytes)
                      (call-with-input-file source
                        (lambda (input)
                          (call-with-output-file destination
                            (lambda (output)
                              (let loop ((remaining bytes))
                                (when (> remaining 0)
                                  (let ((chunk (get-bytevector-n
                                                input
                                                (min remaining 65536))))
                                    (unless (eof-object? chunk)
                                     (put-bytevector output chunk)
                                     (loop (- remaining
                                               (bytevector-length chunk))))))))))))

                    (define (uevent-partname? uevent-file expected)
                      (and (file-exists? uevent-file)
                           (call-with-input-file uevent-file
                             (lambda (port)
                               (let loop ()
                                 (let ((line (read-line port)))
                                   (cond
                                    ((eof-object? line) #f)
                                    ((string=? line
                                               (string-append "PARTNAME="
                                                              expected))
                                     #t)
                                    (else (loop)))))))))

                    (define (find-partition-by-partname expected)
                      (or (and (file-exists? "/dev/disk/by-partlabel/waveform")
                               "/dev/disk/by-partlabel/waveform")
                          (let ((block-root "/sys/class/block"))
                            (and (file-exists? block-root)
                                 (let loop ((entries (scandir block-root)))
                                   (and (pair? entries)
                                        (let ((entry (car entries)))
                                          (if (or (string=? entry ".")
                                                  (string=? entry ".."))
                                              (loop (cdr entries))
                                              (let ((uevent-file
                                                     (string-append block-root
                                                                    "/" entry
                                                                    "/uevent"))
                                                    (device
                                                     (string-append "/dev/"
                                                                    entry)))
                                                (if (and (uevent-partname?
                                                          uevent-file
                                                          expected)
                                                         (file-exists? device))
                                                    device
                                                    (loop (cdr entries))))))))))))

                    (pinenote-initrd-log "pre-mount diagnostics starting")
                    (let ((waveform-device
                           (find-partition-by-partname "waveform")))
                      (if waveform-device
                          (begin
                            (mkdir-p firmware-directory)
                            (copy-prefix waveform-device firmware-file waveform-bytes)
                            (chmod firmware-file #o644)
                            (pinenote-initrd-log
                             "installed waveform firmware from ~a"
                             waveform-device))
                          (pinenote-initrd-log
                           "warning: waveform partition not found; EBC console may stay unavailable")))

                    (pinenote-initrd-log "loading EBC display modules")
                    (catch #t
                      (lambda ()
                        (load-linux-modules-from-directory
                         '#$display-initrd-modules
                         #$display-module-directory)
                        (pinenote-initrd-log "loaded EBC display modules"))
                      (lambda (key . _)
                        (pinenote-initrd-log
                         "warning: EBC display module load failed: ~a"
                         key)))
                    (let ((root-device (find-partition-by-label "PNGuixRoot")))
                      (if root-device
                          (pinenote-initrd-log
                           "PNGuixRoot is visible before Guix root mount at ~a"
                           root-device)
                          (begin
                            (pinenote-initrd-log
                             "PNGuixRoot is not visible before Guix root mount")
                            (when (file-exists? "/proc/partitions")
                              (call-with-input-file "/proc/partitions"
                                (lambda (port)
                                  (let loop ()
                                    (let ((line (read-line port)))
                                      (unless (eof-object? line)
                                        (pinenote-initrd-log
                                         "partition: ~a" line)
                                        (loop))))))))))
                    (pinenote-initrd-log
                     "handoff to Guix root mount for PNGuixRoot")
                    #t))))


(define* (pinenote-initrd file-systems
                          #:key
                          (linux linux-libre)
                          (linux-modules '())
                          (mapped-devices '())
                          (keyboard-layout #f)
                          qemu-networking?
                          volatile-root?
                          (on-error 'debug))
  (pinenote-initrd* %pinenote-display-initrd-modules
                    file-systems
                    #:linux linux
                    #:linux-modules linux-modules
                    #:mapped-devices mapped-devices
                    #:keyboard-layout keyboard-layout
                    #:qemu-networking? qemu-networking?
                    #:volatile-root? volatile-root?
                    #:on-error on-error))

(define* (pinenote-initrd-6.6 file-systems
                              #:key
                              (linux linux-libre)
                              (linux-modules '())
                              (mapped-devices '())
                              (keyboard-layout #f)
                              qemu-networking?
                              volatile-root?
                              (on-error 'debug))
  (pinenote-initrd* %pinenote-display-initrd-modules-6.6
                    file-systems
                    #:linux linux
                    #:linux-modules linux-modules
                    #:mapped-devices mapped-devices
                    #:keyboard-layout keyboard-layout
                    #:qemu-networking? qemu-networking?
                    #:volatile-root? volatile-root?
                    #:on-error on-error))

(define pinenote-kernel-arguments
  '("ignore_loglevel"
     "rw"
    "rootwait"
    "earlycon"
     "console=tty0"
     "console=ttyS2,1500000n8"
     ;; brcmfmac is udev-loaded post-boot (not from the initrd like
     ;; rockchip_ebc), so a cmdline module param DOES apply here — belt to
     ;; the /etc/modprobe.d brace in (pinenote services wifi).  Disables the
     ;; firmware WPA offloads (FWSUP 0x2000 + SAE 0x80000) the Apr-2021
     ;; BCM4345/6 firmware mis-negotiates with wpa_supplicant 2.11; without
     ;; it the radio associates but the 4-way never completes
     ;; (hardware-confirmed 2026-07-10; doc/status.md, doc/networking.md).
     "brcmfmac.feature_disable=0x82000"
     ;; Kill the fbcon cursor.  With console=tty0 the blinking cursor is a
     ;; *periodic damage source* on the panel, and rockchip_ebc's partial
     ;; refresh only exits when its area list drains while re-splicing the
     ;; queue every frame (patch:4244-4247, 4269-4286).  A blink every
     ;; ~200 ms against an area lifetime of ~47 frames (~746 ms at 63 Hz)
     ;; means the list never empties, the refresh thread never returns to
     ;; the top of its loop, and anything waiting on do_one_full_refresh --
     ;; the generation barrier and the legacy global-refresh ioctl alike --
     ;; is starved silently.  That starved the 2026-07-29 barrier campaign
     ;; to -110 with a completely silent kernel log (doc/status.md).
     ;; reader-session unbinds fbcon while it owns the panel, but re-binds
     ;; it on stop, so the hazard is live for every maintenance window.
     ;; Stock Debian on os1 ships exactly this argument.
     "vt.global_cursor_default=0"
     ;; Keep the ttyS2 console alive through suspend entry/exit.  Without
     ;; it the 8250 port is suspended by its own dev_pm_ops and the trace
     ;; stops after "Freezing remaining freezable tasks" -- which is
     ;; exactly where the 2026-08-02 deep hang needed to be observed.  The
     ;; runtime knob (/sys/module/printk/parameters/console_suspend=N)
     ;; suppresses *console* suspension but demonstrably does NOT hold the
     ;; port up: that run still lost every dpm_suspend message.  Costs a
     ;; little power and a little suspend latency whenever suspend is used
     ;; at all -- which in production is never, since suspend is disabled.
     ;; Revert with the suspend program if that ever changes.
     "no_console_suspend"
     "fw_devlink=off"))

;; Do NOT put rockchip_ebc.* parameters on the kernel command line: they
;; are inert.  module.param=value cmdline tokens only reach loadable
;; modules via modprobe (which reads /proc/cmdline), and our initrd
;; raw-loads rockchip_ebc with load-linux-modules-from-directory, which
;; passes no parameters at all.  Hardware-confirmed 2026-07-05: an image
;; carrying rockchip_ebc.refresh_waveform=6 here booted with the driver
;; default (4).  EBC parameters belong in the pinenote-ebc-params
;; one-shot (pinenote/packages/firmware.scm), which writes them through
;; /sys/module/rockchip_ebc/parameters after boot and verifies each one.
