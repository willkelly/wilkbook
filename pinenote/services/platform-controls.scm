(define-module (pinenote services platform-controls)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages koreader)
  #:use-module (pinenote packages platform-controls)
  #:export (pinenote-platform-controls-service-type))

;; The broker owns every /sys/power/state write and creates the named uinput
;; device through which physical power and cover events enter KOReader's
;; ordinary suspend path.  reader-session requires this service and performs
;; the final named-device/ready-marker check before launching KOReader.
(define (pinenote-platform-controls-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-platform-controls))
    (requirement '(root-file-system udev user-processes))
    (documentation "Supervised PineNote suspend broker and virtual power input device.")
    (respawn? #t)
    (start
     #~(lambda args
         (unless (file-exists? "/run/wilkbook-power")
           (mkdir "/run/wilkbook-power"))
         (when (file-exists? "/run/wilkbook-power/ready")
           (delete-file "/run/wilkbook-power/ready"))
         ;; /dev/uinput is not guaranteed to autoload on open.
         (unless (zero? (system* "/run/current-system/profile/bin/modprobe"
                                 "-d" "/run/booted-system/kernel" "uinput"))
           (error "cannot load uinput for pinenote-platform-controls"))
         (apply
          (make-forkexec-constructor
           (list #$(file-append koreader-bin "/lib/koreader/luajit")
                 #$(file-append pinenote-platform-controls
                                "/share/pinenote-platform-controls/pinenote-power-broker.lua"))
           #:environment-variables
           (list
            (string-append
             "WILKBOOK_KOREADER_ROOT="
             #$(file-append koreader-bin "/lib/koreader"))
            (string-append
             "WILKBOOK_WIFI_CONTROL="
             #$(file-append pinenote-platform-controls
                            "/bin/pinenote-wifi-control")))
           #:log-file "/var/log/pinenote-platform-controls.log")
          args)))
    (stop
     #~(lambda (process . args)
         (let ((stopped ((make-kill-destructor) process)))
           (when (file-exists? "/run/wilkbook-power/ready")
             (delete-file "/run/wilkbook-power/ready"))
           stopped))))))

(define (pinenote-platform-controls-profile _config)
  (list pinenote-platform-controls))

(define pinenote-platform-controls-service-type
  (service-type
   (name 'pinenote-platform-controls)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-platform-controls-shepherd-service)
          (service-extension profile-service-type
                             pinenote-platform-controls-profile)))
   (default-value #f)
   (description
    "Run the hardware-validated PineNote suspend broker under Shepherd and
install its KOReader Wi-Fi control helper in the system profile.")))
