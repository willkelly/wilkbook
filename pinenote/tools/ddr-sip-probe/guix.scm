;; Out-of-tree kernel module package: ddr-sip-probe, built against the
;; exact linux-pinenote package (whose derivation output is the running
;; kernel /gnu/store/the running kernel (verify with guix build --dry-run)-linux-pinenote-7.0.11-pinenote).
;;
;; Build:
;;   guix build -L /home/wkelly/src/forgejo/wkelly/wilkbook \
;;     --target=aarch64-linux-gnu -f guix.scm
;;
;; linux-module-build-system's module-builder installs the kernel
;; package's own Module.symvers into the build tree, so with
;; CONFIG_MODVERSIONS=y the module records the running kernel's symbol
;; CRCs (module_layout, __arm_smccc_smc, _printk).

(use-modules (guix packages)
             (guix gexp)
             (guix build-system linux-module)
             ((guix licenses) #:prefix license:)
             (pinenote packages kernel))

(package
  (name "ddr-sip-probe")
  (version "1")
  (source (local-file "src" "ddr-sip-probe-source" #:recursive? #t))
  (build-system linux-module-build-system)
  (arguments
   (list #:linux linux-pinenote
         #:tests? #f))
  (home-page "https://forgejo.example/wkelly/wilkbook")
  (synopsis "Read-only Rockchip DRAM SIP version probe module")
  (description
   "Loadable kernel module that issues the Rockchip SIP version queries
(ATF version, SIP version, DRAM-interface GET_VERSION), prints the raw
SMC results, and returns -ENODEV from init so it never stays loaded.
Strictly read-only toward firmware: no SET_* subfunctions, no shared
memory establishment.")
  (license license:gpl2))
