(define-module (pinenote packages kiosk)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages wm)
  #:use-module (gnu packages xdisorg)
  #:export (wlroots-pixman cage-pixman))

;; The stock wlroots propagates mesa (which does not cross-compile),
;; vulkan, xcb and Xwayland - none of which the PineNote kiosk can use:
;; the EBC has no GPU path, so the compositor runs wlroots' pixman
;; renderer on DRM dumb buffers.  These variants disable the GLES2 and
;; vulkan renderers, the x11 backend and Xwayland outright, which drops
;; mesa from the closure and makes the whole stack cross-buildable.
;; See doc/koreader-spike.md.

(define-public wlroots-pixman
  (package
    (inherit wlroots-0.19)
    (name "wlroots-pixman")
    (arguments
     (substitute-keyword-arguments (package-arguments wlroots-0.19)
       ((#:configure-flags flags #~'())
        #~(append '("-Drenderers=[]"      ; pixman is always built in
                    "-Dxwayland=disabled"
                    "-Dbackends=drm,libinput"
                    "-Dexamples=false")
                  #$flags))
       ((#:phases phases)
        ;; hardcode-paths substitutes the Xwayland binary path, which
        ;; needs the xorg-server-xwayland input we just dropped
        #~(modify-phases #$phases
            (delete 'hardcode-paths)))))
    (propagated-inputs
     (modify-inputs (package-propagated-inputs wlroots-0.19)
       (delete "mesa" "vulkan-headers" "vulkan-loader"
               "xcb-util-errors" "xcb-util-renderutil" "xcb-util-wm"
               "xorg-server-xwayland")
       ;; the stock package gets libdrm transitively via mesa
       (append libdrm)))
    (synopsis
     "wlroots with only the pixman renderer (no mesa/vulkan/Xwayland)")))

(define-public cage-pixman
  (package
    (inherit cage)
    (name "cage-pixman")
    (inputs
     (modify-inputs (package-inputs cage)
       (replace "wlroots" wlroots-pixman)))
    (synopsis "Wayland kiosk against the pixman-only wlroots")))
