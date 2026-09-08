(define-module (pinenote packages book-state-device)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (pinenote packages koreader)
  #:export (book-state-device-modules
            book-state-device-boundary-probe
            book-state-device-python-boundary-probe
            book-state-device-guile-book
            book-state-device-python-book
            book-state-device-guile-protocol
            book-state-device-blocking-protocol
            book-state-device-python-protocol
            book-state-device-runsc-fd3-adapter
            koreader-book-state-device))

;; Public repository sources, each imported by its canonical module name. The
;; device flavor does not execute a /tmp capsule and does not copy the QEMU
;; one-shot authority into a hardware system.
(define book-state-device-guile-protocol
  (local-file "../tools/book-protocol/book-protocol.scm"
              "wilkbook-device-book-protocol.scm"))

(define book-state-device-blocking-protocol
  (local-file "../tools/book-protocol/book-protocol/blocking-io.scm"
              "wilkbook-device-book-protocol-blocking-io.scm"))

(define book-state-device-modules
  (file-union
   "wilkbook-book-state-device-modules"
   `(("guest-smoke.scm"
      ,(local-file "../tools/book-execution-spike/guest-smoke.scm"))
     ("oci-bundle.scm"
      ,(local-file "../tools/book-execution-spike/oci-bundle.scm"))
     ("oci-book-bundle.scm"
      ,(local-file "../tools/book-state-guest/oci-state-book-bundle.scm"))
     ("guest-book-protocol.scm"
      ,(local-file "../tools/book-execution-spike/guest-book-protocol.scm"))
     ("guest-virtio-book-ui.scm"
      ,(local-file "../tools/book-execution-spike/guest-virtio-book-ui.scm"))
     ("private-control.scm"
       ,(local-file "../tools/book-state-reader/private-control.scm"))
     ("book-protocol.scm"
       ,book-state-device-guile-protocol)
     ("book-protocol/blocking-io.scm"
       ,book-state-device-blocking-protocol)
     ("book-state.scm"
      ,(local-file "../tools/book-state/book-state.scm"))
     ("schema-v1.sql"
      ,(local-file "../tools/book-state/schema-v1.sql"))
     ("book-state-operation-id.scm"
      ,(local-file "../tools/book-state-protocol/book-state-operation-id.scm"))
     ("book-state-protocol.scm"
      ,(local-file "../tools/book-state-protocol/book-state-protocol.scm"))
     ("book-state-backend-adapter.scm"
      ,(local-file "../tools/book-state-protocol/book-state-backend-adapter.scm"))
     ("book-state-session-delegate.scm"
      ,(local-file
        "../tools/book-state-protocol/session-integration/book-state-session-delegate.scm"))
     ("book-session.scm"
      ,(local-file
        "../tools/book-state-reader-join/empty-action-successor/book-session.scm"))
     ("book-state-reader-bridge.scm"
      ,(local-file "../tools/book-state-reader-join/book-state-reader-bridge.scm"))
     ("book-state-device-authority.scm"
      ,(local-file
        "../tools/book-state-device/book-state-device-authority.scm")))))

(define book-state-device-boundary-probe
  (local-file "../tools/book-state-device/sandbox-storage-boundary-guile.scm"
              "wilkbook-device-sandbox-storage-boundary-guile.scm"))

(define book-state-device-python-boundary-probe
  (local-file "../tools/book-state-device/sandbox_storage_boundary.py"
              "wilkbook-device-sandbox-storage-boundary-python.py"))
(define book-state-device-guile-book
  (local-file "../tools/book-state-reader-join/joined-note-book.scm"
              "wilkbook-fixed-guile-note-book.scm"))
(define book-state-device-python-book
  (local-file "../tools/book-state-reader-join/joined_note_book.py"
              "wilkbook-fixed-python-note-book.py"))
(define book-state-device-python-protocol
  (local-file "../tools/book-protocol/book_protocol.py"
              "wilkbook-book-protocol.py"))
(define book-state-device-runsc-fd3-adapter
  (local-file "../tools/book-state-guest/runsc-fd3-exec.scm"
              "wilkbook-runsc-fd3-exec.scm"))

(define %plugin-source
  (local-file
   "../tools/book-state-device/plugin/bookstatedevice.koplugin"
   "bookstatedevice.koplugin"
   #:recursive? #t))

(define koreader-book-state-device
  (package
    (inherit koreader-bin)
    (name "koreader-bin-book-state-device")
    (arguments
     (substitute-keyword-arguments (package-arguments koreader-bin)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'install 'install-dormant-book-state-plugin
              (lambda* (#:key outputs #:allow-other-keys)
                (let ((target
                       (string-append (assoc-ref outputs "out")
                                      "/lib/koreader/plugins/bookstatedevice.koplugin")))
                  (copy-recursively #$%plugin-source target))))))))))
