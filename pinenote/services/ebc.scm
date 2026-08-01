(define-module (pinenote services ebc)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages ebc-test)
  #:use-module (pinenote packages firmware)
  #:export (pinenote-waveform-service-type
            pinenote-ebc-modprobe-service-type
            pinenote-ebc-params-service-type
            pinenote-ebc-test-service-type
            pinenote-ebc-modprobe-options))

;; Keep in sync with the pinenote-apply-ebc-params script in
;; (pinenote packages firmware) — that one-shot is the mechanism that
;; actually applies parameters on the device (the initrd raw-loads the
;; module, so neither modprobe.d nor kernel-cmdline tokens reach it).
;; The panfrost softdep is a module-ordering guard both postmarketOS
;; (device-pine64-pinenote panfrost.conf) and PNDeb ship independently:
;; load the EBC driver before the GPU so panfrost never claims the DRM
;; device slot ahead of the display.  Our reader image doesn't load
;; panfrost today (CONFIG_DRM_PANFROST=m, nothing modprobes it), so this
;; is inert until something does — at which point the hazard is real.
(define pinenote-ebc-modprobe-options
  "options rockchip_ebc direct_mode=0 auto_refresh=0 refresh_threshold=60 split_area_limit=0 panel_reflection=1 prepare_prev_before_a2=0 dclk_select=0 refresh_waveform=6 defio_delay_ms=250
softdep panfrost pre: rockchip_ebc\n")

(define (pinenote-waveform-shepherd-service _config)
  (list
    (shepherd-service
     (provision '(pinenote-waveform))
     ;; udev creates /dev/disk/by-partlabel/waveform, the primary source;
     ;; without it this service raced device node creation and failed
     ;; (observed on the 2026-06-11 os2 boot).
     (requirement '(root-file-system udev))
     (documentation "Install the PineNote waveform from a local partition or state file.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$(file-append pinenote-firmware-support
                                        "/bin/pinenote-install-waveform")))))
    (stop #~(const #t)))))

(define pinenote-waveform-service-type
  (service-type
   (name 'pinenote-waveform)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-waveform-shepherd-service)))
   (default-value #f)
   (description "Copy a locally supplied PineNote waveform into the rockchip_ebc firmware path.")))

(define (pinenote-ebc-modprobe-etc-files _config)
  (list `("modprobe.d/rockchip_ebc.conf"
          ,(plain-file "rockchip_ebc.conf" pinenote-ebc-modprobe-options))))

(define pinenote-ebc-modprobe-service-type
  (service-type
   (name 'pinenote-ebc-modprobe)
   (extensions
    (list (service-extension etc-service-type
                             pinenote-ebc-modprobe-etc-files)))
   (default-value #f)
   (description "Install PineNote rockchip_ebc module options into /etc/modprobe.d.")))

(define (pinenote-ebc-params-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-ebc-params))
    (requirement '(root-file-system))
    (documentation "Apply conservative PineNote rockchip_ebc module parameters when sysfs exposes them.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$(file-append pinenote-firmware-support
                                        "/bin/pinenote-apply-ebc-params")))))
    (stop #~(const #t)))))

(define pinenote-ebc-params-service-type
  (service-type
   (name 'pinenote-ebc-params)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-ebc-params-shepherd-service)))
   (default-value #f)
   (description "Apply PNDeb-derived PineNote EBC module parameter defaults.")))

(define (pinenote-ebc-test-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-ebc-test))
    (requirement '(pinenote-waveform pinenote-ebc-params))
    (documentation "Run the read-only PineNote EBC status report once.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$(file-append pinenote-ebc-test
                                        "/bin/pinenote-ebc-test")))))
    (stop #~(const #t)))))

(define pinenote-ebc-test-service-type
  (service-type
   (name 'pinenote-ebc-test)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-ebc-test-shepherd-service)))
   (default-value #f)
   (description "Run the conservative PineNote EBC test at boot.")))
