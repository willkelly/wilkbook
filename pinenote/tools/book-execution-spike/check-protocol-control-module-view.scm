;;; Verify that a symlinked module view retains original local-file authority.
(use-modules (guix gexp)
             (guix packages)
             (pinenote packages firmware)
             (pinenote packages gvisor-local-test-artifacts)
             (pinenote packages kernel)
             (pinenote systems pinenote-book-execution-protocol-control)
             (pinenote systems pinenote-book-execution-spike))

(define repo "/tmp/opencode/wilkbook-book-computer/")

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define (private module name)
  (module-ref (resolve-module module) name))

(define (absolute object)
  (local-file-absolute-file-name object))

(define (check-local-file label object expected)
  (check (string-append "local-file object: " label) (local-file? object))
  (check (string-append "local-file resolves original: " label)
         (string=? (absolute object) expected)))

(define gexp-inputs (@@ (guix gexp) gexp-inputs))
(define (package-source-local-files package)
  (let ((source (package-source package)))
    (unless (computed-file? source)
      (error "expected computed-file package source" (package-name package)))
    (map gexp-input-thing (gexp-inputs (computed-file-gexp source)))))

(define protocol-module
  '(pinenote systems pinenote-book-execution-protocol-control))
(define spike-module
  '(pinenote systems pinenote-book-execution-spike))

(define protocol-sources
  (list
   (cons '%accepted-guest-smoke-source
         "pinenote/tools/book-execution-spike/guest-smoke.scm")
   (cons '%accepted-base-oci-source
         "pinenote/tools/book-execution-spike/oci-bundle.scm")
   (cons '%accepted-book-protocol-source
         "pinenote/tools/book-protocol/book-protocol.scm")
   (cons '%accepted-blocking-protocol-source
         "pinenote/tools/book-protocol/book-protocol/blocking-io.scm")
   (cons '%accepted-python-protocol-source
         "pinenote/tools/book-protocol/book_protocol.py")
   (cons '%accepted-book-session-source
         "pinenote/tools/book-session/book-session.scm")
   (cons '%protocol-oci-source
         "pinenote/tools/book-execution-spike/oci-book-bundle.scm")
   (cons '%guest-protocol-adapter-source
         "pinenote/tools/book-execution-spike/guest-book-protocol.scm")
   (cons '%guile-book-source
         "pinenote/tools/book-execution-spike/guest-protocol-book.scm")
   (cons '%python-book-source
         "pinenote/tools/book-execution-spike/guest_protocol_book.py")))

(for-each
 (lambda (entry)
   (check-local-file
    (format #f "protocol ~a" (car entry))
    (private protocol-module (car entry))
    (string-append repo (cdr entry))))
 protocol-sources)

(for-each
 (lambda (entry)
   (check-local-file
    (format #f "base ~a" (car entry))
    (private spike-module (car entry))
    (string-append repo (cdr entry))))
 (list
  (cons '%book-execution-oci-source
        "pinenote/tools/book-execution-spike/oci-bundle.scm")
  (cons '%book-execution-guest-smoke-source
        "pinenote/tools/book-execution-spike/guest-smoke.scm")))

(define gvisor-module '(pinenote packages gvisor-local-test-artifacts))
(check-local-file
 "CONTROL wrapper recipe"
 (private gvisor-module '%v12-recipe)
 (string-append
  repo
  "pinenote/tools/book-execution-spike/build/proposed-v6-source-build-v12.command"))

(define v12-root "/tmp/opencode/wilkbook-gvisor-v6-source-build-v12/")
(define release-members
  '("containerd-shim-runsc-v1"
    "gvisor-bin/checkpointgofer"
    "gvisor-bin/gvisor-sentry-prewarmer"
    "gvisor-bin/gvisor_sentry"
    "gvisor-bin/runsc-metric-server"
    "runsc"))

(for-each
 (lambda (variant)
   (let ((members
          (private gvisor-module
                   (if (string=? variant "control")
                       '%v12-control-members
                       '%v12-diagnostic-members))))
     (check (string-append variant " release local-file member count")
            (= (length members) 6))
     (for-each
      (lambda (entry expected-relative)
        (check (string-append variant " release member name")
               (string=? (car entry) expected-relative))
        (check-local-file
         (string-append variant " release " expected-relative)
         (cadr entry)
         (string-append v12-root "artifacts/" variant "/" expected-relative)))
      members
      release-members))
   (check-local-file
    (string-append variant " release manifest")
    ((private gvisor-module 'v12-release-manifest) variant)
    (string-append v12-root variant "-release.sha256"))
   (check-local-file
    (string-append variant " MODULE.bazel.lock")
    ((private gvisor-module 'v12-module-lock) variant)
    (string-append v12-root "source-" variant "/MODULE.bazel.lock")))
 '("control" "diagnostic"))

(define expected-patches
  (map (lambda (name) (string-append repo "pinenote/patches/" name))
       '("linux-pinenote-7.0-forward-port.patch"
         "linux-pinenote-7.0-bsp-sip-probe.patch"
         "linux-pinenote-7.0-st-accel-pm.patch"
         "linux-pinenote-7.0-cpuidle-psci.patch"
         "linux-pinenote-7.0-vdd-cpu-auto-pfm.patch"
         "linux-pinenote-7.0-dmc-static-low.patch"
         "linux-pinenote-7.0-ultra-rails.patch"
         "linux-pinenote-7.1-hrdl-direct-mode.patch"
         "linux-pinenote-7.1-ebc-parallel-advance.patch"
         "linux-pinenote-7.1-rect-hints-bounds.patch"
         "linux-pinenote-7.1-probe-unwind.patch"
         "linux-pinenote-7.1-rk8xx-kexec-sleep-pin.patch"
         "linux-pinenote-7.1-sdio-pwrseq-delay.patch"
         "linux-pinenote-7.1-direct-correctness.patch")))
(define actual-patches
  (map absolute (private '(pinenote packages kernel) '%linux-pinenote-patches)))
(check "all 14 kernel local-file patches resolve to original source paths"
       (equal? actual-patches expected-patches))

(define (check-package-source-files label package expected-relatives)
  (let ((actual (package-source-local-files package))
        (expected (map (lambda (relative) (string-append repo relative))
                       expected-relatives)))
    (check (string-append label " local-file source count")
           (= (length actual) (length expected)))
    (for-each
     (lambda (object path)
       (check-local-file (string-append label " " (basename path)) object path))
     (sort actual
           (lambda (left right)
             (string<? (local-file-file left) (local-file-file right))))
     (sort expected string<?))))

(check-package-source-files
 "pinenote-ebc-dump"
 pinenote-ebc-dump
 '("pinenote/tools/ebc-logic/ebc-dump-format.h"
   "pinenote/tools/ebc-logic/ebc-dump-grab.c"))

(check-package-source-files
 "pinenote-wbf-clut"
 pinenote-wbf-clut
 '("pinenote/patches/linux-pinenote-7.0-forward-port.patch"
   "pinenote/tools/wbf/Makefile"
   "pinenote/tools/wbf/extract-from-patch.py"
   "pinenote/tools/wbf/shim/drm/drm_device.h"
   "pinenote/tools/wbf/shim/drm/drm_managed.h"
   "pinenote/tools/wbf/shim/drm/drm_print.h"
   "pinenote/tools/wbf/shim/kernel-shim.h"
   "pinenote/tools/wbf/shim/linux/firmware.h"
   "pinenote/tools/wbf/shim/linux/module.h"
   "pinenote/tools/wbf/shim/linux/vmalloc.h"
   "pinenote/tools/wbf/wbf-clut.c"
   "pinenote/tools/wbf/wbf-info.c"))

(check "module view exposes no source/tool selection input" #t)
