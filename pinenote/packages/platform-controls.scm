(define-module (pinenote packages platform-controls)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages))

(define-public pinenote-platform-controls
  (package
    (name "pinenote-platform-controls")
    (version "1.0.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((bin (string-append #$output "/bin"))
                (share (string-append #$output "/share/pinenote-platform-controls")))
            (mkdir-p bin)
            (mkdir-p share)
            (copy-file
             #$(local-file "platform-controls/pinenote-power-broker.lua")
             (string-append share "/pinenote-power-broker.lua"))
            (copy-file
             #$(local-file "platform-controls/broker_protocol.lua")
             (string-append share "/broker_protocol.lua"))
            (copy-file
             #$(local-file "platform-controls/broker_quiesce.lua")
             (string-append share "/broker_quiesce.lua"))
            (copy-file
             #$(local-file "platform-controls/pinenote-wifi-control")
             (string-append bin "/pinenote-wifi-control"))
            (chmod (string-append share "/pinenote-power-broker.lua") #o555)
            (chmod (string-append share "/broker_protocol.lua") #o444)
            (chmod (string-append share "/broker_quiesce.lua") #o444)
            (chmod (string-append bin "/pinenote-wifi-control") #o555)))))
    (home-page "https://github.com/rpedde/wilkbook")
    (synopsis "Acknowledged suspend and Wi-Fi controls for PineNote")
    (description
     "Provide the hardware-validated PineNote suspend broker, its protocol
module, and the Wi-Fi ownership helper used by KOReader and the broker.")
    (license gpl3+)))
