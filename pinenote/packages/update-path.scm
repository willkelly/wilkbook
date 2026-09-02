(define-module (pinenote packages update-path)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (pinenote packages koreader))

;; The on-device half of the update path (doc/update-path.md): the
;; generation helper and its pure ledger module, run under the bundle's
;; luajit exactly like the platform-controls broker.
(define-public pinenote-update-path
  (package
    (name "pinenote-update-path")
    (version "0.1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((bin (string-append #$output "/bin"))
                (share (string-append #$output "/share/pinenote-update-path")))
            (mkdir-p bin)
            (mkdir-p share)
            (copy-file #$(local-file "update-path/generation_ledger.lua")
                       (string-append share "/generation_ledger.lua"))
            (copy-file #$(local-file "update-path/wilkbook-generation.lua")
                       (string-append share "/wilkbook-generation.lua"))
            (call-with-output-file (string-append bin "/wilkbook-generation")
              (lambda (port)
                (format port "#!/bin/sh~nexec ~a ~a \"$@\"~n"
                        #$(file-append koreader-bin "/lib/koreader/luajit")
                        (string-append share "/wilkbook-generation.lua"))))
            (chmod (string-append bin "/wilkbook-generation") #o555)
            (chmod (string-append share "/generation_ledger.lua") #o444)
            (chmod (string-append share "/wilkbook-generation.lua") #o444)))))
    (home-page "https://github.com/willkelly/wilkbook")
    (synopsis "System generation helper for the PineNote update path")
    (description
     "Register copied system closures as generations, render the extlinux
menu, kexec a trial boot, promote, demote and prune -- the device side of
guix-copy-based updates on a device that never builds.")
    (license gpl3+)))
