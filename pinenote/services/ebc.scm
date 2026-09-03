(define-module (pinenote services ebc)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (pinenote packages ebc-test)
  #:use-module (pinenote packages firmware)
  #:export (pinenote-waveform-service-type
            pinenote-ebc-modprobe-service-type
            pinenote-ebc-modprobe-configuration
            pinenote-ebc-modprobe-configuration?
            pinenote-ebc-modprobe-configuration-options
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
  ;; One driver (the direct-mode driver, since the embrace sweep's S1) and
  ;; one string.  Its parameters cannot be set here at all: the initrd
  ;; raw-loads rockchip_ebc, so modprobe.d never reaches it -- the two that
  ;; matter (temp_override, default_hint) are written through sysfs by the
  ;; pinenote-ebc-direct-params one-shot (pinenote services ebc-direct).
  ;; What remains is the module-ordering softdep both postmarketOS and PNDeb
  ;; ship: load the EBC driver before the GPU so panfrost never claims the
  ;; DRM device slot ahead of the display.
  "softdep panfrost pre: rockchip_ebc\n")

(define-record-type* <pinenote-ebc-modprobe-configuration>
  pinenote-ebc-modprobe-configuration make-pinenote-ebc-modprobe-configuration
  pinenote-ebc-modprobe-configuration?
  (options pinenote-ebc-modprobe-configuration-options
           (default pinenote-ebc-modprobe-options)))

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

(define (pinenote-ebc-modprobe-etc-files config)
  (list `("modprobe.d/rockchip_ebc.conf"
          ,(plain-file "rockchip_ebc.conf"
                       (pinenote-ebc-modprobe-configuration-options config)))))

(define pinenote-ebc-modprobe-service-type
  (service-type
   (name 'pinenote-ebc-modprobe)
   (extensions
    (list (service-extension etc-service-type
                             pinenote-ebc-modprobe-etc-files)))
   ;; The default is the shipping text, so `(service
   ;; pinenote-ebc-modprobe-service-type)' in base.scm is unchanged and
   ;; produces a byte-identical /etc/modprobe.d/rockchip_ebc.conf.
   (default-value (pinenote-ebc-modprobe-configuration))
   (description "Install PineNote rockchip_ebc module options into /etc/modprobe.d.")))

(define (pinenote-ebc-test-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-ebc-test))
    (requirement '(pinenote-waveform))
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
