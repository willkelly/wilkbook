(define-module (pinenote services usb-gadget)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:export (pinenote-usb-acm-gadget-service-type
            pinenote-usb-acm-console-service-type))

(define (pinenote-usb-acm-gadget-program)
  #~(begin
      (use-modules (ice-9 ftw)
                   (ice-9 rdelim))

      (define (write-file path value)
        (call-with-output-file path
          (lambda (port)
            (display value port))))

      (define (ensure-directory path)
        (unless (file-exists? path)
          (mkdir path #o755)))

      (define (first-directory path)
        (and (file-exists? path)
             (let ((entries (scandir path
                                     (lambda (entry)
                                       (not (member entry '("." "..")))))))
               (and (pair? entries) (car entries)))))

      (define (read-first-line path)
        (and (file-exists? path)
             (call-with-input-file path
               (lambda (port)
                 (let ((line (read-line port)))
                   (and (not (eof-object? line)) line))))))

      (define (gadget-bound-udc gadget-root)
        (let ((udc (read-first-line (string-append gadget-root "/UDC"))))
          (and udc (not (string=? udc "")) udc)))

      (define (log message . arguments)
        (apply format #t
               (string-append "PineNote USB ACM gadget: " message "~%")
               arguments)
        (force-output))

      (define (write-file-if-exists path value)
        (when (file-exists? path)
          (catch #t
            (lambda ()
              (write-file path value)
              #t)
            (lambda (key . _)
              (log "warning: could not write ~s to ~a: ~a"
                   value
                   path
                   key)
              #f))))

      (define (wait-for-udc name attempts)
        (cond
         ((file-exists? (string-append "/sys/class/udc/" name)) name)
         ((zero? attempts) #f)
         (else
          (sleep 1)
          (wait-for-udc name (- attempts 1)))))

      (define (wait-for-line path expected attempts)
        (let ((line (read-first-line path)))
          (cond
           ((and line (string=? line expected)) #t)
           ((zero? attempts) #f)
           (else
            (sleep 1)
            (wait-for-line path expected (- attempts 1))))))

      (define (usb-role-switches)
        (if (file-exists? "/sys/class/usb_role")
            (scandir "/sys/class/usb_role"
                     (lambda (entry)
                       (not (member entry '("." "..")))))
            '()))

      (define (role-switch-path role-switch)
        (string-append "/sys/class/usb_role/" role-switch "/role"))

      (define (role-switch-device? role-switch)
        (let ((role (read-first-line (role-switch-path role-switch))))
          (and role (string=? role "device"))))

      (define (target-role-switch? role-switch)
        (or (string-contains role-switch "fcc00000.usb")
            (let ((path (string-append "/sys/class/usb_role/" role-switch)))
              (catch #t
                (lambda ()
                  (string-contains (readlink path) "fcc00000.usb"))
                (lambda _ #f)))))

      (define (target-role-switches role-switches)
        (cond
         ((null? role-switches) '())
         ((target-role-switch? (car role-switches))
          (cons (car role-switches)
                (target-role-switches (cdr role-switches))))
         (else (target-role-switches (cdr role-switches)))))

      (define (all-role-switches-device? role-switches)
        (cond
         ((null? role-switches) #t)
         ((role-switch-device? (car role-switches))
          (all-role-switches-device? (cdr role-switches)))
         (else #f)))

      (define (wait-for-role-switch-device role-switches attempts)
        (cond
         ((all-role-switches-device? role-switches) #t)
         ((zero? attempts) #f)
         (else
          (sleep 1)
          (wait-for-role-switch-device role-switches (- attempts 1)))))

      (define (set-role-switches-to-device role-switches)
        (for-each
         (lambda (role-switch)
           (let ((path (role-switch-path role-switch)))
             (log "setting USB role switch ~a to device" role-switch)
             (write-file-if-exists path "device")))
         role-switches))

      (define (set-dwc3-device-mode)
        (let ((mode-path "/sys/kernel/debug/usb/fcc00000.usb/mode"))
          (if (not (file-exists? mode-path))
              (begin
                (log "DWC3 debugfs mode path is unavailable")
                #f)
              (begin
                (write-file-if-exists mode-path "device")
                (if (wait-for-line mode-path "device" 15)
                    #t
                    (begin
                      (log "DWC3 mode did not settle to device; last mode was ~s"
                           (read-first-line mode-path))
                      #f))))))

      (define (prepare-usb-device-role)
        (let* ((available-role-switches (usb-role-switches))
               (role-switches (target-role-switches available-role-switches)))
          (when (and (not (null? available-role-switches))
                     (null? role-switches))
            (log "no USB role switch matched fcc00000.usb; available switches: ~s"
                 available-role-switches))
          (set-role-switches-to-device role-switches)
          (if (not (wait-for-role-switch-device role-switches 15))
              (begin
                (log "target USB role switches did not report device role: ~s"
                     (map (lambda (role-switch)
                            (cons role-switch
                                  (read-first-line (role-switch-path role-switch))))
                          role-switches))
                #f)
              (set-dwc3-device-mode))))

      (define (fail message . arguments)
        (apply log message arguments)
        #f)

      ;; Point modprobe at the kernel profile with -d: only the profile under
      ;; /run/booted-system/kernel carries modules.dep (the raw kernel package
      ;; has none), and the previous LINUX_MODULE_DIRECTORY setenv demonstrably
      ;; never reached modprobe on the 2026-06-11 boot (it searched
      ;; /lib/modules).  -d needs no environment at all; verified against the
      ;; deployed image's own kmod in an os2 chroot, 2026-07-03.
      (for-each (lambda (module)
                  (let ((status
                         (system* #$(file-append kmod "/bin/modprobe")
                                  "-d" "/run/booted-system/kernel"
                                  module)))
                    (unless (zero? status)
                      (log "warning: modprobe ~a exited with ~a"
                           module
                           status))))
                '("wusb3801" "libcomposite" "u_serial" "usb_f_acm"))

      (unless (file-exists? "/sys/kernel/debug/usb")
        (when (file-exists? "/sys/kernel/debug")
          (system* #$(file-append util-linux "/bin/mount")
                   "-t" "debugfs" "none" "/sys/kernel/debug")))

      (if (not (prepare-usb-device-role))
          (fail "USB device role is not ready; not binding gadget")
          (begin
            (unless (file-exists? "/sys/kernel/config/usb_gadget")
              (when (file-exists? "/sys/kernel/config")
                (system* #$(file-append util-linux "/bin/mount")
                         "-t" "configfs" "none" "/sys/kernel/config")))

            (if (not (file-exists? "/sys/kernel/config/usb_gadget"))
                (fail "configfs usb_gadget path is unavailable")
                (let* ((gadget-root "/sys/kernel/config/usb_gadget/pinenote-acm")
                       (udc (or (wait-for-udc "fcc00000.usb" 10)
                                (first-directory "/sys/class/udc"))))
                  (if (not udc)
                      (fail "no USB device controller found")
                      (let ((bound-udc (gadget-bound-udc gadget-root)))
                        (if bound-udc
                            (begin
                              (log "gadget is already bound to UDC ~a" bound-udc)
                              #t)
                            (begin
                  (log "binding to UDC ~a" udc)
                  (ensure-directory gadget-root)

                  ;; On a fresh configfs gadget, writing an empty UDC is
                  ;; unnecessary and can abort before descriptors are created.
                  (write-file (string-append gadget-root "/idVendor") "0x1d6b")
                  (write-file (string-append gadget-root "/idProduct") "0x0104")
                  (write-file (string-append gadget-root "/bcdDevice") "0x0001")
                  (write-file (string-append gadget-root "/bcdUSB") "0x0200")

                  (ensure-directory (string-append gadget-root "/strings"))
                  (ensure-directory (string-append gadget-root "/strings/0x409"))
                  (write-file (string-append gadget-root "/strings/0x409/serialnumber")
                              "pinenote-guix-gate6")
                  (write-file (string-append gadget-root "/strings/0x409/manufacturer")
                              "Pine64")
                  (write-file (string-append gadget-root "/strings/0x409/product")
                              "PineNote Guix Gate6 ACM Console")

                  (ensure-directory (string-append gadget-root "/configs"))
                  (ensure-directory (string-append gadget-root "/configs/c.1"))
                  (ensure-directory (string-append gadget-root "/configs/c.1/strings"))
                  (ensure-directory (string-append gadget-root "/configs/c.1/strings/0x409"))
                  (write-file (string-append gadget-root "/configs/c.1/strings/0x409/configuration")
                              "CDC ACM console")
                  (write-file (string-append gadget-root "/configs/c.1/MaxPower") "250")

                  (ensure-directory (string-append gadget-root "/functions"))
                  (ensure-directory (string-append gadget-root "/functions/acm.usb0"))
                  (let ((link (string-append gadget-root "/configs/c.1/acm.usb0")))
                    (unless (file-exists? link)
                      (symlink (string-append gadget-root "/functions/acm.usb0") link)))

                  (write-file (string-append gadget-root "/UDC") udc)
                  (log "bound CDC-ACM function as /dev/ttyGS0")
                  #t))))))))))

(define (pinenote-usb-acm-gadget-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-usb-acm-gadget))
    ;; file-systems (not just root-file-system): starting alongside the
    ;; fstab mounts raced the kernel debugfs/configfs mounts to EBUSY on
    ;; first light (2026-07-04), cascading into every dependent service.
    (requirement '(file-systems))
    (documentation "Expose a temporary USB CDC-ACM gadget as /dev/ttyGS0.")
    (one-shot? #t)
    (modules '((ice-9 ftw)
               (ice-9 rdelim)))
    (start
     #~(lambda _
         #$(pinenote-usb-acm-gadget-program)))
    (stop #~(const #t)))))

(define pinenote-usb-acm-gadget-service-type
  (service-type
   (name 'pinenote-usb-acm-gadget)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-usb-acm-gadget-shepherd-service)))
   (default-value #f)
   (description "Create a temporary PineNote USB CDC-ACM console gadget.")))

(define (pinenote-usb-acm-console-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-usb-acm-console))
    (requirement '(pinenote-usb-acm-gadget))
    (documentation "Run a login console on the PineNote USB ACM gadget.")
    (respawn? #t)
    (start
     #~(make-forkexec-constructor
        (list #$(program-file
                 "pinenote-usb-acm-reader-console"
                 #~(begin
                     (let wait-for-tty ()
                       (unless (file-exists? "/dev/ttyGS0")
                         (sleep 1)
                         (wait-for-tty)))
                     (execl #$(file-append bash-minimal "/bin/bash")
                            "bash"
                            "-c"
                            (string-append
                             "exec </dev/ttyGS0 >/dev/ttyGS0 2>&1\n"
                             "# Guix setuid wrappers must win, and stty needs PATH before first use.\n"
                             "export PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin\n"
                             "stty sane -echo 115200 cs8 -cstopb -parenb -ixon -ixoff -crtscts clocal cread || true\n"
                             "export TERM=vt100 HOME=/home/reader USER=reader LOGNAME=reader SHELL="
                             #$(file-append bash-minimal "/bin/bash")
                             "\n"
                             "export PS1='pinenote-acm$ '\n"
                             "cd /home/reader 2>/dev/null || cd /\n"
                             "printf '\\r\\nPineNote Guix ACM reader shell ready\\r\\n'\n"
                             "exec "
                             #$(file-append bash-minimal "/bin/bash")
                             " -i\n")))))
        #:user "reader"
        #:group "users"
        #:supplementary-groups '("wheel" "tty" "dialout")))
    (stop #~(make-kill-destructor)))))

(define pinenote-usb-acm-console-service-type
  (service-type
   (name 'pinenote-usb-acm-console)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-usb-acm-console-shepherd-service)))
   (default-value #f)
   (description "Start a temporary reader shell on the PineNote USB ACM gadget.")))
