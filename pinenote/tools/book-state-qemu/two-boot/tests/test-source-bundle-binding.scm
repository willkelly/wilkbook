#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Finite source-only checks for source, pinned image binding, and timeouts.
(use-modules (gcrypt base16)
             (gcrypt hash)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64)
             (two-boot bundle)
             (two-boot bundle-test-fixture)
             (two-boot image-binding)
             (two-boot source-gate)
             (two-boot timeout-contract))

(define test-root
  (mkdtemp "/tmp/opencode/two-boot-source-binding-gates.XXXXXX"))
(chmod test-root #o700)

(define (file-hash path)
  (bytevector->base16-string (file-sha256 path)))

(define (write-text path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define (remove-tree path)
  (let ((info (lstat path)))
    (if (eq? (stat:type info) 'directory)
        (begin
          (chmod path #o700)
          (for-each
           (lambda (name)
             (unless (member name '("." "..") string=?)
               (remove-tree (string-append path "/" name))))
           (scandir path))
          (rmdir path))
        (begin (chmod path #o600) (delete-file path)))))

(define (rejected? key thunk)
  (catch key (lambda () (thunk) #f) (lambda _ #t)))

(define* (make-source name #:key addition omission writable-file
                      writable-directory symlink-entry duplicate)
  (let* ((root (string-append test-root "/" name))
         (nested (string-append root "/nested"))
         (input (string-append nested "/input.txt"))
         (manifest (string-append root "/SOURCE-MANIFEST.sha256")))
    (mkdir root #o700)
    (mkdir nested #o700)
    (write-text input "frozen source input\n")
    (let ((line (format #f "~a  nested/input.txt~%" (file-hash input))))
      (write-text manifest (if duplicate (string-append line line) line)))
    (when omission (delete-file input))
    (when addition
      (write-text (string-append root "/unknown.txt") "addition\n")
      (chmod (string-append root "/unknown.txt") #o400))
    (when symlink-entry
      (symlink "nested/input.txt" (string-append root "/alias")))
    (when (file-exists? input)
      (chmod input (if writable-file #o600 #o400)))
    (chmod manifest #o400)
    (chmod nested (if writable-directory #o700 #o500))
    (chmod root #o500)
    (cons root (file-hash manifest))))

(define (replace-field record field value)
  (map (lambda (entry) (if (eq? (car entry) field)
                           (cons field value) entry))
       record))

(define (rename-field record old new)
  (map (lambda (entry) (if (eq? (car entry) old)
                           (cons new (cdr entry)) entry))
       record))

(define timeout-hash
  "e584555b6ef21abc7ab799dee7a3d0d27b4f7869ba5f5a3fb012d2d1ec49708a")

(define reviewed-payload-files
  (@@ (two-boot bundle) reviewed-payload-files))

(define (write-payload-manifest path entries)
  (write-text
   path
   (string-concatenate
    (map (lambda (entry)
           (format #f "~a  ~a~%" (cdr entry) (car entry)))
         entries))))

(define* (make-reviewed-payload name
                                #:key
                                (inner-transform identity)
                                (metadata-transform identity)
                                (outer-transform identity))
  (let* ((root (string-append test-root "/" name))
         (boot (string-append root "/boot-bundle"))
         (extlinux (string-append boot "/extlinux")))
    (mkdir root #o700)
    (mkdir boot #o700)
    (mkdir extlinux #o700)
    (for-each
     (lambda (relative)
       (let ((path (string-append root "/" relative)))
         (write-text path (string-append "synthetic payload: " relative "\n"))
         (chmod path #o400)))
     reviewed-payload-files)
    (let* ((actual
            (map (lambda (relative)
                   (cons relative (file-hash (string-append root "/" relative))))
                 reviewed-payload-files))
           (inner (inner-transform actual))
           (manifest (string-append root "/PAYLOAD.sha256")))
      (write-payload-manifest manifest inner)
      (chmod manifest #o400)
      (chmod extlinux #o500)
      (chmod boot #o500)
      (chmod root #o500)
      (let* ((manifest-hash (file-hash manifest))
             (metadata
              `((reviewed-boot-payload-manifest-sha256
                 . ,(metadata-transform manifest-hash))))
             (outer
              (outer-transform
               (cons (cons "PAYLOAD.sha256" manifest-hash) actual))))
        (list root metadata outer)))))

(define (authenticate-reviewed-payload fixture)
  ((@@ (two-boot bundle) authenticate-reviewed-payload-manifest!)
   (car fixture) (cadr fixture) (caddr fixture)))

(umask #o077)
(test-begin "two-boot-source-bundle-binding")

(let ((valid (make-source "source-valid")))
  (test-assert "immutable exact source roster is accepted"
    (verify-two-boot-source-root! (car valid) (cdr valid))))
(for-each
 (lambda (case)
   (test-assert (car case)
     (rejected? 'book-state-two-boot-source-error
                (lambda ()
                  (let ((fixture (apply make-source (cdr case))))
                    (verify-two-boot-source-root! (car fixture)
                                                  (cdr fixture)))))))
 `(("source addition is rejected" "source-addition" #:addition #t)
   ("source omission is rejected" "source-omission" #:omission #t)
   ("writable source file is rejected" "source-writable-file"
    #:writable-file #t)
   ("writable source directory is rejected" "source-writable-directory"
    #:writable-directory #t)
   ("source symlink is rejected" "source-symlink" #:symlink-entry #t)
   ("duplicate source manifest record is rejected" "source-duplicate"
    #:duplicate #t)))

(test-assert "separate test-only synthetic binding accepts its exact metadata"
  (validate-synthetic-binding! synthetic-bundle-metadata
                               synthetic-image-binding))
(test-equal "closed metadata roles are exact"
  '(bundle-envelope accepted-guest-source accepted-runner-parent
    guest-source-gate-system accepted-original-image
    accepted-prepared-boot-payload timeout-contract runtime-store-tools)
  (map car (@@ (two-boot bundle) metadata-role-fields)))
(test-assert "closed metadata role map has one owner for every field"
  (let* ((roles (@@ (two-boot bundle) metadata-role-fields))
         (fields (append-map cdr roles)))
    (and (= (length fields) (length (delete-duplicates fields)))
         (equal? fields (@@ (two-boot bundle) metadata-fields)))))
(test-assert "version-neutral schema has no guest-v4/v6 aliases"
  (every (lambda (name)
           (not (or (string-contains (symbol->string name) "guest-v4")
                    (string-contains (symbol->string name) "guest-v6"))))
         (@@ (two-boot bundle) metadata-fields)))
(test-assert "metadata cannot self-assert a different artifact hash"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (validate-synthetic-binding!
                (replace-field synthetic-bundle-metadata 'rootfs-sha256
                               (make-string 64 #\f))
                synthetic-image-binding))))
(test-assert "metadata cannot add a reviewer/status assertion"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (validate-synthetic-binding!
                (cons '(status . independently-reviewed-image)
                      synthetic-bundle-metadata)
                synthetic-image-binding))))
(test-assert "metadata cannot add its own binding-evidence assertion"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (validate-synthetic-binding!
                (cons `(binding-evidence-sha256 . ,(make-string 64 #\e))
                      synthetic-bundle-metadata)
                synthetic-image-binding))))
(test-assert "metadata cannot rename the neutral source role to a version alias"
  (rejected? 'book-state-two-boot-bundle-error
              (lambda ()
                (validate-synthetic-binding!
                 (rename-field synthetic-bundle-metadata
                               'guest-source-manifest-sha256
                               'guest-v6-source-manifest-sha256)
                 synthetic-image-binding))))
(test-assert "fixture binding itself requires external binding evidence"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (validate-synthetic-binding!
                synthetic-bundle-metadata
                (replace-field synthetic-image-binding
                               'binding-evidence-sha256
                               'caller-says-reviewed)))))

(test-equal "production binding is available only from retained source"
  'available (production-image-binding-status))
(test-equal "available binding has no unavailable reason"
  'none
  (assoc-ref production-image-binding 'unavailable-reason))
(let ((caller-location (string-append test-root "/caller-bundle-claim")))
  (write-text caller-location "not the source-pinned bundle\n")
  (chmod caller-location #o400)
  (test-assert "production authority rejects an unpinned caller location"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 (authenticate-production-two-boot-bundle caller-location)))))
(test-equal "binding input is exact external successor author evidence"
  "9c6b55822571c5c69f6b06ed48a58f7987cbda53e072b741122995ac7e65cfe8"
  (assoc-ref production-image-binding 'binding-evidence-sha256))
(test-equal "exact successor outer manifest is fixed before final review"
  "bd7151f0c4e729d40c4ed6ef65fe381ad07c30e4e3912089a83bfe0d1849245b"
  (assoc-ref production-image-binding 'bundle-manifest-sha256))
(test-assert "bundle metadata cannot carry external binding evidence"
  (not (member 'binding-evidence-sha256
               (@@ (two-boot bundle) metadata-fields))))

(define store-file (@@ (two-boot bundle) authenticated-guix-store-file))
(define store-executable
  (@@ (two-boot bundle) authenticated-store-executable))
(define qemu-output
  "/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1")
(define qemu-system-sha256
  "364cea5b2ea702806fdeab1e2ee48a6d265daba7100156d3ab828c29a9c00e20")
(define qemu-path (string-append qemu-output "/bin/qemu-system-aarch64"))
(test-equal "actual hard-linked pinned QEMU passes the store validator"
  qemu-path
  (store-executable qemu-output "bin/qemu-system-aarch64"
                     qemu-system-sha256
                     "QEMU"))
(test-assert "actual QEMU demonstrates legitimate Guix hard-link deduplication"
  (> (stat:nlink (lstat qemu-path)) 1))
(test-assert "wrong executable digest is rejected"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (store-executable qemu-output "bin/qemu-system-aarch64"
                                 (make-string 64 #\0) "wrong QEMU"))))
(test-assert "a different store executable cannot replace the fixed role"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
                (store-executable qemu-output "bin/qemu-img"
                                  qemu-system-sha256
                                  "replaced QEMU"))))
(let* ((outside (string-append test-root "/outside-qemu"))
       (alias (string-append test-root "/outside-qemu-link")))
  (write-text outside "not a store executable\n")
  (chmod outside #o500)
  (symlink outside alias)
  (test-assert "outside-store executable lookalike is rejected"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 (store-file outside (file-hash outside) "outside"
                             #:executable? #t))))
  (test-assert "symlink executable candidate is rejected"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 (store-file alias (file-hash outside) "symlink"
                             #:executable? #t))))
  (delete-file alias))
(let ((left (string-append test-root "/inode-left"))
      (right (string-append test-root "/inode-right")))
  (write-text left "left\n")
  (write-text right "right\n")
  (test-assert "replacement inode identity is rejected by the stable predicate"
    (not ((@@ (two-boot bundle) same-stable-file?)
          (lstat left) (lstat right)))))
(let ((original (string-append test-root "/caller-single-link"))
      (alias (string-append test-root "/caller-hard-link")))
  (write-text original "caller data\n")
  (chmod original #o400)
  (link original alias)
  (test-assert "caller-owned data still requires a single link"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 ((@@ (two-boot bundle) require-fixed-file)
                  original "caller data")))))

(test-equal "executable timeout record equals the frozen file"
  two-boot-timeout-contract
  (call-with-input-file "TIMEOUT-CONTRACT.scm" read))
(test-equal "mandatory outer argv is exact"
  '("--timeout-seconds" "360" "--term-grace-seconds" "5")
  mandatory-outer-timeout-arguments)
(test-assert "exact mandatory outer argv validates"
  (assert-mandatory-outer-timeout-arguments
   (append '("qemu-owner") mandatory-outer-timeout-arguments)))
(test-equal "campaign argv binder appends the mandatory pair exactly once"
  '("owner" "--timeout-seconds" "360" "--term-grace-seconds" "5")
  (bind-mandatory-outer-timeout-arguments '("owner")))
(for-each
 (lambda (case)
   (test-assert (car case)
     (rejected? 'book-state-two-boot-timeout-error (cadr case))))
 (list
  (list "timeout zero is rejected"
        (lambda ()
          (assert-mandatory-outer-timeout-arguments
           '("owner" "--timeout-seconds" "0" "--term-grace-seconds" "5"))))
  (list "TERM grace zero is rejected"
        (lambda ()
          (assert-mandatory-outer-timeout-arguments
           '("owner" "--timeout-seconds" "360" "--term-grace-seconds" "0"))))
  (list "a duplicate timeout override is rejected"
        (lambda ()
          (assert-mandatory-outer-timeout-arguments
           '("owner" "--timeout-seconds" "360" "--term-grace-seconds" "5"
             "--timeout-seconds" "0"))))
  (list "argv binder rejects a caller timeout"
        (lambda ()
          (bind-mandatory-outer-timeout-arguments
           '("owner" "--timeout-seconds" "0"))))))

(test-equal "timeout source identity remains exact"
  timeout-hash (file-hash "TIMEOUT-CONTRACT.scm"))
(test-equal "binding pins the successor guest source manifest"
  "920bacf12f7f5c011671e1c10f1b56afb891cc4c9af387a78e3c74cc5f2d4492"
  (assoc-ref production-image-binding 'guest-source-manifest-sha256))
(test-equal "binding pins the successor guest source packet"
  "082d078491dc72bba54cade339daa57dccf9ec4e93ffa49f2d76bf18ea64419a"
  (assoc-ref production-image-binding 'guest-source-packet-manifest-sha256))
(test-equal "binding keeps successor replay distinct from parent review"
  "65bff26e399dae844b2b228b2ce07ce44bca793ac506c0123271531e330e79cf"
  (assoc-ref production-image-binding
             'guest-source-packet-evidence-manifest-sha256))
(test-equal "binding pins the exact V9-to-successor capsule delta"
  "92f24af6e00fb8fef46c35770c0eaa98c38664269a1ac5b2dad1751238633885"
  (assoc-ref production-image-binding
             'guest-source-packet-delta-manifest-sha256))
(test-equal "binding pins independently accepted joint V8/V6 review"
  "a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19"
  (assoc-ref production-image-binding 'guest-review-sha256))
(test-equal "binding pins the successor source-derived system"
  '("/gnu/store/33xmfibdw08ywzy52pl0vf2kgd4hkkzc-system.drv"
    "/gnu/store/4bdjy4khvvw1f4h0xf35sz2fwr3bkg9s-system")
  (list (assoc-ref production-image-binding
                   'guest-source-gate-system-derivation)
        (assoc-ref production-image-binding
                    'guest-source-gate-system-output)))
(test-equal "binding pins the exact successor system derivation bytes"
  "05f1f6eb980b60cf7b53fe98a8b9e147b023f4ca021f1751ab1e92b074642c11"
  (assoc-ref production-image-binding
             'guest-source-gate-system-derivation-sha256))
(test-equal "binding pins the author-built successor image path"
  '("/gnu/store/ynds2p541hz4krjna26rj78dismm7gzf-disk-image.drv"
    "/gnu/store/j6i1p44vabm88dxa79f1dyzljzjgzyzc-disk-image")
  (list (assoc-ref production-image-binding 'image-derivation)
        (assoc-ref production-image-binding 'image-output)))
(test-equal "binding pins the exact successor image derivation bytes"
  "9a46122e5ebc3ba8b05fc5e8e5e98fc781fc10644489cca44cfa3ca3c0987ae1"
  (assoc-ref production-image-binding 'image-derivation-sha256))
(test-equal "image-embedded-system role is distinct and author-inspected"
  "/gnu/store/dqkg4qzp23zywamf80dr7jh64h9bp1lf-system.drv"
  (assoc-ref production-image-binding 'image-embedded-system-derivation))
(test-equal "binding pins author-inspected successor DOS/MBR layout"
  'dos-mbr-not-gpt
  (assoc-ref production-image-binding 'image-partition-table))
(test-equal "unchanged kernel config and successor boot config remain separate roles"
  '("0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309"
    "230308b6312c7d5a0818d6b79b9b307f73a82e0c71c0e9abde9699efd1d9118f")
  (list (assoc-ref production-image-binding 'kernel-config-sha256)
        (assoc-ref production-image-binding 'boot-config-sha256)))
(test-equal "binding pins current ungrafted KOReader output"
  "/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03"
  (assoc-ref production-image-binding 'koreader-output))

(test-equal "reviewed payload grammar is exactly four independently named files"
  '("boot-bundle/extlinux/Image"
    "boot-bundle/extlinux/extlinux.conf"
    "boot-bundle/extlinux/initrd.cpio.gz"
    "rootfs.raw")
  reviewed-payload-files)
(test-assert "exact copied four-entry payload manifest authenticates"
  (authenticate-reviewed-payload
   (make-reviewed-payload "payload-valid")))
(test-assert "the old STATUS.json digest cannot occupy the payload-manifest role"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (authenticate-reviewed-payload
                (make-reviewed-payload
                 "payload-status-role"
                 #:metadata-transform
                 (lambda (_)
                   "2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25"))))))
(test-equal "binding pins exact copied successor payload manifest"
  "dacfad2ad38644c8dd71556c94074f047f9a175c1ff1bc2c8e9d7e65a7a48f2e"
  (assoc-ref production-image-binding
             'reviewed-boot-payload-manifest-sha256))
(test-assert "the successor reuses neither V6 manifest nor status hash"
  (not (member
        (assoc-ref production-image-binding
                   'reviewed-boot-payload-manifest-sha256)
        '("9d188cd6ef2333ba6c28c515ea6c27748383256026284e8bbe2077e494c5fc82"
          "2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25"))))

(for-each
 (lambda (relative)
   (test-assert
       (string-append "reviewed payload independently rejects wrong " relative)
     (rejected? 'book-state-two-boot-bundle-error
                (lambda ()
                  (authenticate-reviewed-payload
                   (make-reviewed-payload
                    (string-append "payload-member-" (basename relative))
                    #:inner-transform
                    (lambda (entries)
                      (map (lambda (entry)
                             (if (string=? (car entry) relative)
                                 (cons relative (make-string 64 #\f)) entry))
                           entries))))))))
 reviewed-payload-files)

(for-each
 (lambda (case)
   (test-assert (car case)
     (rejected? 'book-state-two-boot-bundle-error
                (lambda ()
                  (authenticate-reviewed-payload
                   (make-reviewed-payload (cadr case)
                                          #:inner-transform (caddr case)))))))
 (list
  (list "payload manifest omission is rejected" "payload-omission"
        (lambda (entries) (drop-right entries 1)))
  (list "payload manifest addition is rejected" "payload-addition"
        (lambda (entries)
          (append entries (list (cons "STATUS.json" (make-string 64 #\e))))))
  (list "payload manifest reordering is rejected" "payload-reordered" reverse)
  (list "payload manifest duplicate is rejected" "payload-duplicate"
        (lambda (entries) (append entries (list (car entries)))))))

(test-assert "bundle envelope must carry the exact payload manifest copy"
  (rejected? 'book-state-two-boot-bundle-error
             (lambda ()
               (authenticate-reviewed-payload
                (make-reviewed-payload
                 "payload-envelope-mismatch"
                 #:outer-transform
                 (lambda (entries)
                   (map (lambda (entry)
                          (if (string=? (car entry) "PAYLOAD.sha256")
                              (cons "PAYLOAD.sha256" (make-string 64 #\0))
                              entry))
                         entries)))))))

(define production-bundle-root (getenv "TWO_BOOT_V9_BUNDLE"))
(test-assert "host gate supplies one private successor location, not authority"
  (and production-bundle-root
       (string-prefix? "/tmp/opencode/" production-bundle-root)))
(test-equal "private bundle carries the exact source-pinned outer manifest"
  (assoc-ref production-image-binding 'bundle-manifest-sha256)
  (file-hash (string-append production-bundle-root "/MANIFEST.sha256")))

(define authenticate-against-binding
  (@@ (two-boot bundle) authenticate-two-boot-bundle-against-binding))
(define validate-against-binding
  (@@ (two-boot bundle) validate-two-boot-bundle-metadata-against-binding!))
(define exact-bundle-metadata
  ((@@ (two-boot bundle) read-one-datum)
   (string-append production-bundle-root "/BUNDLE.scm")))

(test-assert "actual successor binding authenticates through the no-spawn boundary"
  (let ((bundle (authenticate-production-two-boot-bundle
                 production-bundle-root)))
    (and (two-boot-bundle? bundle)
         (string=? (bundle-manifest-sha256 bundle)
                   (assoc-ref production-image-binding
                              'bundle-manifest-sha256))
         (string=? (bundle-qemu bundle)
                   "/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1/bin/qemu-system-aarch64"))))

(for-each
 (lambda (case)
   (test-assert (car case)
     (rejected? 'book-state-two-boot-bundle-error
                (lambda ()
                  (authenticate-against-binding
                   "/tmp/opencode/not-inspected-for-old-layout"
                   (replace-field production-image-binding
                                  (cadr case) (caddr case)))))))
  `(("old V6 image size rejects before caller path or spawn"
     image-output-size 2063540224)
    ("old V9 image size rejects before caller path or spawn"
     image-output-size 2063556608)
    ("old V6 partition sectors reject before caller path or spawn"
     image-partition-sector-count 4028304)
    ("old V9 partition sectors reject before caller path or spawn"
     image-partition-sector-count 4028336)
    ("old V6 partition byte size rejects before caller path or spawn"
     image-partition-byte-size 2062491648)
    ("old V9 partition byte size rejects before caller path or spawn"
     image-partition-byte-size 2062508032)))

(for-each
 (lambda (case)
   (test-assert (car case)
     (rejected? 'book-state-two-boot-bundle-error
                (lambda ()
                  (validate-against-binding
                   exact-bundle-metadata
                   (replace-field production-image-binding
                                  'image-output (cadr case)))))))
  `(("old V6 image path rejects before store/tool/spawn use"
     "/gnu/store/9yx1xmhf2hnsp6vdwnvvxzqv3i9i9fkz-disk-image")
    ("old V7 image path rejects before store/tool/spawn use"
     "/gnu/store/lsk489hgzszvym56m5pnsbrvf5malhiy-disk-image")
    ("old V9 image path rejects before store/tool/spawn use"
     "/gnu/store/cm20vv4a7fbh3g3gbkmhyvg7iwwlbk1p-disk-image")))

(let ((root (string-append test-root "/altered-outer-manifest")))
  (mkdir root #o700)
  (write-text (string-append root "/MANIFEST.sha256")
              (string-append (make-string 64 #\0) "  BUNDLE.scm\n"))
  (chmod (string-append root "/MANIFEST.sha256") #o400)
  (chmod root #o500)
  (test-assert "altered outer manifest rejects before inventory/tool/spawn use"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 (authenticate-production-two-boot-bundle root)))))

(let* ((root (string-append test-root "/altered-payload-member"))
       (boot (string-append root "/boot-bundle"))
       (extlinux (string-append boot "/extlinux")))
  (mkdir root #o700)
  (mkdir boot #o700)
  (mkdir extlinux #o700)
  (for-each
   (lambda (relative)
     (let ((target (string-append root "/" relative)))
       (if (member relative '("BUNDLE.scm" "PAYLOAD.sha256") string=?)
           (copy-file (string-append production-bundle-root "/" relative)
                      target)
           (write-text target (string-append "altered: " relative "\n")))
       (chmod target #o400)))
   '("BUNDLE.scm" "PAYLOAD.sha256"
     "boot-bundle/extlinux/Image"
     "boot-bundle/extlinux/extlinux.conf"
     "boot-bundle/extlinux/initrd.cpio.gz" "rootfs.raw"))
  (copy-file (string-append production-bundle-root "/MANIFEST.sha256")
             (string-append root "/MANIFEST.sha256"))
  (chmod (string-append root "/MANIFEST.sha256") #o400)
  (chmod extlinux #o500)
  (chmod boot #o500)
  (chmod root #o500)
  (test-assert "altered payload member rejects before metadata/tool/spawn use"
    (rejected? 'book-state-two-boot-bundle-error
               (lambda ()
                 (authenticate-production-two-boot-bundle root)))))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-source-bundle-binding")
(remove-tree test-root)
(exit (if (zero? failures) 0 1))
