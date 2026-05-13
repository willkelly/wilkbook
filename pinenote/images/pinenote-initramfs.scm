(define-module (pinenote images pinenote-initramfs)
  #:use-module (gnu packages linux)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix gexp)
  #:export (%pinenote-display-initrd-modules
            pinenote-initrd
            pinenote-initramfs-note
            pinenote-kernel-arguments))

(define pinenote-initramfs-note
  "PineNote initrd keeps storage handling close to Guix defaults, but tries to
bring up the EBC framebuffer before mounting root by reading the local waveform
partition and loading PineNote display modules from the initrd.")

(define %pinenote-display-initrd-modules
  ;; Keep these out of operating-system 'initrd-modules': Guix loads that list
  ;; before the pre-mount hook, but rockchip_ebc needs waveform firmware first.
  '("tps65185-regulator"
    "panel-simple"
    "rockchipdrm"
    "rockchip_ebc"))

(define* (pinenote-initrd file-systems
                          #:key
                          (linux linux-libre)
                          (linux-modules '())
                          (mapped-devices '())
                          (keyboard-layout #f)
                          qemu-networking?
                          volatile-root?
                          (on-error 'debug))
  (let ((display-module-directory
         ((@@ (gnu system linux-initrd) flat-linux-module-directory)
          linux
          %pinenote-display-initrd-modules)))
    (raw-initrd file-systems
                #:linux linux
                #:linux-modules linux-modules
                #:mapped-devices mapped-devices
                #:helper-packages '()
                #:keyboard-layout keyboard-layout
                #:qemu-networking? qemu-networking?
                #:volatile-root? volatile-root?
                #:on-error on-error
                #:pre-mount
                #~(begin
                    (use-modules (gnu build linux-modules)
                                 ((guix build utils) #:select (mkdir-p))
                                 (ice-9 ftw)
                                 (ice-9 rdelim)
                                 (rnrs bytevectors)
                                 (rnrs io ports))

                    (define waveform-bytes (* 2048 1024))
                    (define firmware-directory "/lib/firmware/rockchip")
                    (define firmware-file
                      (string-append firmware-directory "/ebc.wbf"))

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

                    (let ((waveform-device
                           (find-partition-by-partname "waveform")))
                      (if waveform-device
                          (begin
                            (mkdir-p firmware-directory)
                            (copy-prefix waveform-device firmware-file waveform-bytes)
                            (chmod firmware-file #o644)
                            (format #t "installed PineNote waveform firmware from ~a into initrd~%"
                                    waveform-device))
                          (format (current-error-port)
                                  "warning: PineNote waveform partition not found; EBC console may stay unavailable~%")))

                    (load-linux-modules-from-directory
                     '#$%pinenote-display-initrd-modules
                     #$display-module-directory)
                    #t))))

(define pinenote-kernel-arguments
  '("ignore_loglevel"
     "rw"
    "rootwait"
    "earlycon"
     "console=tty0"
     "console=ttyS2,1500000n8"
     "fw_devlink=off"
     "rockchip_ebc.direct_mode=0"
     "rockchip_ebc.auto_refresh=1"
     "rockchip_ebc.refresh_threshold=60"
     "rockchip_ebc.split_area_limit=0"
     "rockchip_ebc.panel_reflection=1"
     "rockchip_ebc.prepare_prev_before_a2=0"
     "rockchip_ebc.dclk_select=0"))
