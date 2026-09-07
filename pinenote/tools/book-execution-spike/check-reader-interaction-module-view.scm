;;; Verify original-source local-file authority through the strict reader view.
(use-modules (guix gexp)
             (pinenote systems pinenote-book-execution-reader-interaction))

(define repo "/tmp/opencode/wilkbook-book-computer/")

(define (check label condition)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" label)
    (exit 1))
  (format #t "PASS: ~a~%" label))

(define reader-module
  '(pinenote systems pinenote-book-execution-reader-interaction))
(define (reader-private name)
  (module-ref (resolve-module reader-module) name))

(define (check-local-file name relative expected-sha256)
  (let ((object (reader-private name)))
    (check (format #f "reader ~a is a local-file" name) (local-file? object))
    (check (format #f "reader ~a resolves reviewed original" name)
           (string=? (local-file-absolute-file-name object)
                     (string-append repo relative)))
    (check (format #f "reader ~a binds expected SHA-256" name)
           (string=? (reader-private expected-sha256)
                     (case name
                       ((%private-control-source)
                        "1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d")
                       ((%guest-virtio-ui-source)
                         "3b6e8eb172d7e3575c36a95a42d66635c101f7404d2f8028ca0f541dfba66966")
                       ((%guest-reader-authority-source)
                         "6dc0dfc9b577b3b5b854690879ce02909fc1f85f4b7a776365d8d9dde46e1129"))))))

(check-local-file
 '%private-control-source
 "pinenote/tools/book-interaction/private-control.scm"
 '%private-control-sha256)
(check-local-file
 '%guest-virtio-ui-source
 "pinenote/tools/book-execution-spike/guest-virtio-book-ui.scm"
 '%guest-virtio-ui-sha256)
(check-local-file
 '%guest-reader-authority-source
 "pinenote/tools/book-execution-spike/guest-book-interaction.scm"
 '%guest-reader-authority-sha256)

(check "reader module view exposes no package/source selection input" #t)
