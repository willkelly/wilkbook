;; "Generation B" for the QEMU update-flow rig (doc/update-path.md,
;; rung 4): the direct reader flavor with one observable difference --
;; the host name -- so that a successful trial boot is provable from the
;; guest (`hostname`, /run/current-system) and the closure delta that
;; `guix copy` moves is small.  Never deployed to a device.
(use-modules (gnu system)
             (pinenote systems pinenote-reader-direct))

(operating-system
  (inherit pinenote-reader-direct-operating-system)
  (host-name "pinenote-reader-direct-genb"))
