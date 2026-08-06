;; Out-of-tree kernel module package: ddr-dvfs-test, built against the
;; exact linux-pinenote package whose derivation output is the running
;; kernel /gnu/store/s7gam9gnmhjzf854b8j1jd4nxy35qxq8-linux-pinenote-7.0.11-pinenote
;; (verified by `guix build -L <repo> --target=aarch64-linux-gnu --dry-run
;;  -e '(@ (pinenote packages kernel) linux-pinenote)'` on 2026-08-06).
;;
;; Build:
;;   guix build -L /home/wkelly/src/forgejo/wkelly/wilkbook \
;;     --target=aarch64-linux-gnu -f guix.scm
;;
;; Same scaffolding as pinenote/tools/ddr-sip-probe/guix.scm:
;; linux-module-build-system installs the kernel package's own
;; Module.symvers into the build tree, so with CONFIG_MODVERSIONS=y the
;; module records the running kernel's symbol CRCs.

(use-modules (guix packages)
             (guix gexp)
             (guix build-system linux-module)
             ((guix licenses) #:prefix license:)
             (pinenote packages kernel))

(package
  (name "ddr-dvfs-test")
  (version "1")
  (source (local-file "src" "ddr-dvfs-test-source" #:recursive? #t))
  (build-system linux-module-build-system)
  (arguments
   (list #:linux linux-pinenote
         #:tests? #f))
  (home-page "https://forgejo.example/wkelly/wilkbook")
  (synopsis "Supervised Rockchip DRAM SIP DVFS test module")
  (description
   "Loadable kernel module that performs the BSP rk3568 DDR SIP init
sequence (share-mem, DRAM_INIT, GET_FREQ_INFO), exposes the firmware
frequency table and current rate via debugfs, and can issue a single
supervised SET_RATE guarded behind the allow_set=1 module parameter.
Restores the original boot rate on rmmod if it was changed.")
  (license license:gpl2))
