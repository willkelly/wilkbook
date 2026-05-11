(define-module (pinenote services usb-gadget)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:export (pinenote-usb-acm-gadget-service-type))

(define (pinenote-usb-acm-gadget-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-usb-acm-gadget))
    (requirement '(root-file-system udev))
    (documentation "Expose a temporary USB CDC-ACM gadget as /dev/ttyGS0.")
    (one-shot? #t)
    (modules '((ice-9 ftw)))
    (start
     #~(lambda _
         (define (write-file path value)
           (call-with-output-file path
             (lambda (port)
               (display value port))))

         (define (ensure-directory path)
           (unless (file-exists? path)
             (mkdir path #o755)))

         (define (first-directory path)
           (let ((entries (scandir path
                                   (lambda (entry)
                                     (not (member entry '("." "..")))))))
             (and (pair? entries) (car entries))))

         (define gadget-root "/sys/kernel/config/usb_gadget/pinenote-acm")
         (define udc (first-directory "/sys/class/udc"))

         (unless udc
           (format (current-error-port) "no USB device controller found~%")
           (exit 1))

         (for-each (lambda (module)
                     (system* #$(file-append kmod "/bin/modprobe") module))
                   '("libcomposite" "u_serial" "usb_f_acm"))

         (unless (file-exists? "/sys/kernel/config/usb_gadget")
           (system* #$(file-append util-linux "/bin/mount")
                    "-t" "configfs" "none" "/sys/kernel/config"))

         (unless (file-exists? "/sys/kernel/config/usb_gadget")
           (format (current-error-port) "configfs usb_gadget path is unavailable~%")
           (exit 1))

         (ensure-directory gadget-root)

         (write-file (string-append gadget-root "/UDC") "")
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
         #t))
    (stop #~(const #t)))))

(define pinenote-usb-acm-gadget-service-type
  (service-type
   (name 'pinenote-usb-acm-gadget)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-usb-acm-gadget-shepherd-service)))
   (default-value #f)
   (description "Create a temporary PineNote USB CDC-ACM console gadget.")))
