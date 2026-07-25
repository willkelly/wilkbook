(define-module (pinenote services orientation)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages koreader)
  #:use-module (pinenote packages orientation)
  #:export (pinenote-orientation-bridge-service-type))

(define (pinenote-orientation-bridge-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(orientation-bridge))
    (requirement '(root-file-system udev user-processes))
    (documentation "Persistent SC7A20 buffered-IIO orientation bridge.")
    (respawn? #t)
    (start #~(lambda args
               (when (file-exists? "/run/wilkbook-orientation.ready")
                 (delete-file "/run/wilkbook-orientation.ready"))
               ;; /dev/uinput is not guaranteed to autoload on open.
               (unless (zero? (system* "/run/current-system/profile/bin/modprobe"
                                       "-d" "/run/booted-system/kernel" "uinput"))
                 (error "cannot load uinput"))
               (apply (make-forkexec-constructor
                       (list #$(file-append koreader-bin "/lib/koreader/luajit")
                             #$(file-append pinenote-orientation-bridge
                                            "/share/pinenote-orientation/orientation-bridge.lua"))
                       #:log-file "/var/log/wilkbook-orientation.log") args)))
    (stop #~(lambda (pid . args)
              (let ((stopped ((make-kill-destructor) pid)))
                (system* #$(file-append koreader-bin "/lib/koreader/luajit")
                         #$(file-append pinenote-orientation-bridge
                                        "/share/pinenote-orientation/orientation-bridge.lua")
                         "--cleanup")
                stopped))))))

(define pinenote-orientation-bridge-service-type
  (service-type
   (name 'pinenote-orientation-bridge)
   (extensions (list (service-extension shepherd-root-service-type
                                        pinenote-orientation-bridge-shepherd-service)))
   (default-value #f)
   (description "Run the PineNote SC7A20 orientation uinput bridge.")))
