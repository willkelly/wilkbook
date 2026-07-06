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
