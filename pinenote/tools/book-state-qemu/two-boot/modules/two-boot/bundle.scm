;;; Consume one source-pinned reviewed image binding; callers supply no hashes.
(define-module (two-boot bundle)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (two-boot image-binding)
  #:export (authenticate-production-two-boot-bundle
            two-boot-bundle?
            bundle-root
            bundle-manifest-sha256
            bundle-id
            bundle-kernel
            bundle-initrd
            bundle-config
            bundle-baseline
            bundle-append-line
            bundle-kernel-sha256
            bundle-initrd-sha256
            bundle-config-sha256
            bundle-baseline-sha256
            bundle-qemu
            bundle-qemu-img
            bundle-mke2fs
            bundle-e2fsck
            bundle-guile
            bundle-cp
            bundle-sha256sum
            bundle-python
            bundle-koreader-output
            bundle-guest-source-manifest-sha256
            bundle-guest-source-snapshot-manifest-sha256
            bundle-guest-capsule-roster-sha256
            bundle-guest-authority-source-sha256
            bundle-guest-contract-sha256))

(define sha256-rx (make-regexp "^[0-9a-f]{64}$"))
(define store-output-rx
  (make-regexp "^/gnu/store/[0-9a-df-np-sv-z]{32}-[^/]+$"))
(define store-file-rx
  (make-regexp
   "^/gnu/store/[0-9a-df-np-sv-z]{32}-[^/]+(/[^/]+)*$"))

(define reviewed-payload-files
  '("boot-bundle/extlinux/Image"
    "boot-bundle/extlinux/extlinux.conf"
    "boot-bundle/extlinux/initrd.cpio.gz"
    "rootfs.raw"))

(define manifest-files
  (append '("BUNDLE.scm" "PAYLOAD.sha256") reviewed-payload-files))

;; Every identity used by the consumer appears both here and in the
;; source-pinned image binding.  This closed role map prevents a future source,
;; packet, review, system, image, or prepared-payload identity from being
;; silently stored under another generation's vocabulary.  BUNDLE.scm has no
;; status or binding-evidence field and no value in it can bless itself.  The
;; source-fixed evidence may be author evidence; its field name makes no review
;; claim.
(define metadata-role-fields
  '((bundle-envelope
     schema bundle-id)
    (accepted-guest-source
     guest-source-manifest-sha256
     guest-source-snapshot-manifest-sha256
     guest-capsule-roster-sha256
     guest-source-packet-manifest-sha256
     guest-source-packet-evidence-manifest-sha256
     guest-source-packet-delta-manifest-sha256
     guest-review-sha256
     guest-system-source-sha256
     guest-authority-source-sha256
     guest-oci-source-sha256
     guest-guile-denial-probe-sha256
     guest-python-denial-probe-sha256
     guest-fd3-adapter-source-sha256
     guest-contract-sha256
     reader-join-source-manifest-sha256)
    (accepted-runner-parent
     two-boot-parent-review-sha256
     two-boot-parent-packet-manifest-sha256
     two-boot-parent-source-manifest-sha256
     two-boot-parent-runtime-source-manifest-sha256)
    (guest-source-gate-system
     guest-source-gate-system-derivation
     guest-source-gate-system-derivation-sha256
     guest-source-gate-system-output)
    (accepted-original-image
     image-review-document-sha256
     image-derivation image-derivation-sha256
     image-output image-output-sha256 image-output-guix-recursive-hash
     image-output-size image-partition-table image-partition-start-sector
     image-partition-sector-count image-partition-byte-offset
     image-partition-byte-size image-source-filesystem-label
     image-filesystem-uuid image-source-partition-sha256
     image-embedded-system-derivation
     image-embedded-system-derivation-sha256
     image-embedded-system-output
     image-embedded-system-guix-recursive-hash
     image-extlinux-conf-sha256 image-initrd-output image-initrd-sha256)
    (accepted-prepared-boot-payload
     reviewed-boot-payload-manifest-sha256
     prepared-payload-source-transformation
     prepared-payload-source-changed-bytes
     prepared-payload-source-changed-ranges
     prepared-root-partition-sha256
     root-filesystem-label state-filesystem-label
     kernel-output kernel-output-guix-recursive-hash
     kernel-image-sha256 kernel-config-sha256
     kernel-dtb-rk3566-pinenote-v1.2-sha256
     initrd-sha256 boot-config-sha256 rootfs-sha256)
    (timeout-contract
     guest-cooperative-budget-seconds required-outer-qemu-timeout-seconds
     required-outer-term-grace-seconds two-boot-timeout-contract-sha256)
    (runtime-store-tools
     gvisor-source-output gvisor-output-guix-recursive-hash
     gvisor-runsc-sha256 gvisor-release gvisor-commit
     qemu-output qemu-system-sha256 qemu-img-sha256
     e2fsprogs-output mke2fs-sha256 e2fsck-sha256
     koreader-output koreader-luajit-sha256 koreader-revision
     guile-output guile-sha256 guile-gcrypt-output guix-modules-output
     coreutils-output cp-sha256 sha256sum-sha256
     python-output python-sha256)))

(define metadata-fields (append-map cdr metadata-role-fields))

(define binding-fields
  (append '(schema status unavailable-reason binding-id
             binding-evidence-sha256 bundle-manifest-sha256)
          (cdr metadata-fields)))

(define-record-type <two-boot-bundle>
  (%make-two-boot-bundle root manifest-sha256 id kernel initrd config baseline
                          append-line kernel-sha256 initrd-sha256 config-sha256
                          baseline-sha256 qemu qemu-img mke2fs e2fsck guile cp
                          sha256sum python koreader-output
                          guest-source-manifest-sha256
                          guest-source-snapshot-manifest-sha256
                          guest-capsule-roster-sha256 guest-authority-source-sha256
                          guest-contract-sha256)
  two-boot-bundle?
  (root bundle-root)
  (manifest-sha256 bundle-manifest-sha256)
  (id bundle-id)
  (kernel bundle-kernel)
  (initrd bundle-initrd)
  (config bundle-config)
  (baseline bundle-baseline)
  (append-line bundle-append-line)
  (kernel-sha256 bundle-kernel-sha256)
  (initrd-sha256 bundle-initrd-sha256)
  (config-sha256 bundle-config-sha256)
  (baseline-sha256 bundle-baseline-sha256)
  (qemu bundle-qemu)
  (qemu-img bundle-qemu-img)
  (mke2fs bundle-mke2fs)
  (e2fsck bundle-e2fsck)
  (guile bundle-guile)
  (cp bundle-cp)
  (sha256sum bundle-sha256sum)
  (python bundle-python)
  (koreader-output bundle-koreader-output)
  (guest-source-manifest-sha256 bundle-guest-source-manifest-sha256)
  (guest-source-snapshot-manifest-sha256
   bundle-guest-source-snapshot-manifest-sha256)
  (guest-capsule-roster-sha256 bundle-guest-capsule-roster-sha256)
  (guest-authority-source-sha256 bundle-guest-authority-source-sha256)
  (guest-contract-sha256 bundle-guest-contract-sha256))

(define (bundle-error message . arguments)
  (throw 'book-state-two-boot-bundle-error
         (apply format #f message arguments)))

(define (sha256? value)
  (and (string? value) (regexp-exec sha256-rx value) #t))

(define (file-sha256-string path)
  (bytevector->base16-string (file-sha256 path)))

(define (same-stable-file? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))
       (= (stat:mode left) (stat:mode right))
       (= (stat:nlink left) (stat:nlink right))
       (= (stat:uid left) (stat:uid right))
       (= (stat:gid left) (stat:gid right))
       (= (stat:size left) (stat:size right))
       (= (stat:mtime left) (stat:mtime right))
       (= (stat:ctime left) (stat:ctime right))))

(define (safe-relative? path)
  (and (string? path) (not (string-null? path))
       (not (string-prefix? "/" path))
       (not (member path '("." "..") string=?))
       (not (string-contains path "//"))
       (every (lambda (part) (not (member part '("" "." "..") string=?)))
              (string-split path #\/))
       (not (any (lambda (character) (< (char->integer character) #x20))
                 (string->list path)))))

(define (exact-alist? value fields)
  (and (list? value)
       (= (length value) (length fields))
       (every (lambda (entry)
                (and (pair? entry) (symbol? (car entry))
                     (member (car entry) fields)))
              value)
       (= (length (delete-duplicates (map car value))) (length fields))
       (every (lambda (field) (assq field value)) fields)))

(define (field record name)
  (let ((entry (assq name record)))
    (and entry (cdr entry))))

(define (require-fixed-file path label . executable)
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:nlink info) 1)
                 (zero? (logand (stat:mode info) #o222))
                 (if (and (pair? executable) (car executable))
                     (access? path X_OK) #t))
      (bundle-error "~a is not an immutable single-link regular file: ~a"
                    label path)))
  path)

(define (validate-image-binding! binding)
  (unless (exact-alist? binding binding-fields)
    (bundle-error "source-pinned image binding does not have the closed schema"))
  (unless (and (equal? (map car metadata-role-fields)
                       '(bundle-envelope accepted-guest-source
                         accepted-runner-parent guest-source-gate-system
                         accepted-original-image accepted-prepared-boot-payload
                         timeout-contract runtime-store-tools))
               (= (length metadata-fields)
                  (length (delete-duplicates metadata-fields)))
               (= (field binding 'schema) 3)
               (eq? (field binding 'status) 'available)
               (eq? (field binding 'unavailable-reason) 'none)
               (string? (field binding 'binding-id))
               (string? (field binding 'bundle-id))
               (sha256? (field binding 'binding-evidence-sha256))
               (sha256? (field binding 'bundle-manifest-sha256)))
    (bundle-error "source-pinned image binding is unavailable or malformed"))
  (for-each
   (lambda (name)
     (when (string-suffix? "sha256" (symbol->string name))
       (unless (sha256? (field binding name))
          (bundle-error "image binding lacks exact SHA-256 for ~a" name))))
   metadata-fields)
  (unless (and
           (eq? (field binding 'image-partition-table) 'dos-mbr-not-gpt)
           (eq? (field binding 'prepared-payload-source-transformation)
                'private-ext4-label-only)
            (= (field binding 'image-output-size) 2063552512)
           (= (field binding 'image-partition-start-sector) 2048)
            (= (field binding 'image-partition-sector-count) 4028328)
           (= (field binding 'image-partition-byte-offset) 1048576)
            (= (field binding 'image-partition-byte-size) 2062503936)
           (= (field binding 'prepared-payload-source-changed-bytes) 97)
           (= (field binding 'prepared-payload-source-changed-ranges) 27)
           (= (field binding 'guest-cooperative-budget-seconds) 300)
           (= (field binding 'required-outer-qemu-timeout-seconds) 360)
           (= (field binding 'required-outer-term-grace-seconds) 5)
           (string=? (field binding 'image-source-filesystem-label)
                     "Guix_image")
           (string=? (field binding 'root-filesystem-label) "PNGuixRoot")
           (string=? (field binding 'state-filesystem-label) "WBBookStateV1"))
    (bundle-error "source-pinned image binding has incorrect fixed semantics"))
  binding)

(define (validate-two-boot-bundle-metadata-against-binding! metadata binding)
  ;; This private generic is used only by the source-only fixture module.  The
  ;; production entry below has no binding parameter.
  (validate-image-binding! binding)
  (unless (exact-alist? metadata metadata-fields)
    (bundle-error "BUNDLE.scm does not have the closed schema"))
  (for-each
   (lambda (name)
     (unless (equal? (field metadata name) (field binding name))
       (bundle-error "bundle metadata ~a differs from the pinned image binding"
                     name)))
   metadata-fields)
  #t)

(define (canonical-directory path label)
  (unless (and (string? path) (string-prefix? "/" path)
               (string=? path (canonicalize-path path)))
    (bundle-error "~a must be an absolute canonical directory" label))
  (let ((info (lstat path)))
    (unless (and (eq? (stat:type info) 'directory)
                 (= (stat:uid info) (getuid))
                 (zero? (logand (stat:mode info) #o222)))
      (bundle-error "~a must be caller-owned and non-writable" label)))
  path)

(define (read-one-datum path)
  (call-with-input-file path
    (lambda (port)
      (let ((value (read port)) (tail (read port)))
        (unless (eof-object? tail)
          (bundle-error "metadata contains trailing data"))
        value))))

(define (parse-manifest path expected-hash expected-files label)
  (require-fixed-file path label)
  (unless (string=? (file-sha256-string path) expected-hash)
    (bundle-error "~a differs from the pinned image binding" label))
  (let ((lines
         (call-with-input-file path
           (lambda (port)
             (let loop ((result '()))
               (let ((line (read-line port)))
                 (if (eof-object? line) (reverse result)
                     (loop (cons line result)))))))))
    (unless (and (= (length lines) (length expected-files))
                 (every (lambda (line)
                          (and (>= (string-length line) 67)
                               (string=? (substring line 64 66) "  ")
                               (sha256? (substring line 0 64))
                               (safe-relative? (substring line 66))))
                        lines))
      (bundle-error "~a has malformed records" label))
    (let ((entries
           (map (lambda (line)
                  (cons (substring line 66) (substring line 0 64)))
                lines)))
      (unless (equal? (map car entries) expected-files)
        (bundle-error "~a roster or ordering differs" label))
      entries)))

(define (walk-inventory root)
  (let ((files '()))
    (define (walk relative)
      (let* ((path (if (string-null? relative) root
                       (string-append root "/" relative)))
             (info (lstat path)))
        (cond
         ((eq? (stat:type info) 'directory)
          (unless (and (= (stat:uid info) (getuid))
                       (zero? (logand (stat:mode info) #o222)))
            (bundle-error "bundle directory is writable: ~a" relative))
          (for-each
           (lambda (name)
             (unless (member name '("." "..") string=?)
               (walk (if (string-null? relative) name
                         (string-append relative "/" name)))))
           (sort (scandir path) string<?)))
         ((eq? (stat:type info) 'regular)
          (unless (= (stat:uid info) (getuid))
            (bundle-error "bundle file is not caller-owned: ~a" relative))
          (set! files (cons relative files)))
         (else (bundle-error "bundle contains a symlink or special file: ~a"
                             relative)))))
    (walk "")
    (sort files string<?)))

(define (manifest-hash entries relative)
  (or (assoc-ref entries relative)
      (bundle-error "bundle manifest lacks ~a" relative)))

(define (authenticate-reviewed-payload-manifest! root metadata outer-entries)
  ;; PAYLOAD.sha256 is the independently reviewed four-file authority, not an
  ;; external command status and not merely a same-named metadata value.  Hash
  ;; each payload member again through this manifest and join every result to
  ;; the separately authenticated bundle envelope.
  (let* ((expected
          (field metadata 'reviewed-boot-payload-manifest-sha256))
         (path (string-append root "/PAYLOAD.sha256"))
         (entries
          (parse-manifest path expected reviewed-payload-files
                          "reviewed payload manifest")))
    (unless (string=? (manifest-hash outer-entries "PAYLOAD.sha256") expected)
      (bundle-error
       "bundle envelope does not carry the exact reviewed payload manifest"))
    (for-each
     (lambda (entry)
       (let* ((relative (car entry))
              (expected-member (cdr entry))
              (member (string-append root "/" relative)))
         (require-fixed-file member
                             (string-append "reviewed payload " relative))
         (unless (and (string=? (file-sha256-string member) expected-member)
                      (string=? (manifest-hash outer-entries relative)
                                expected-member))
           (bundle-error
            "reviewed payload member differs across its two manifests: ~a"
            relative))))
     entries)
    entries))

(define (store-output metadata name fragment)
  (let ((path (field metadata name)))
    (unless (and (string? path) (regexp-exec store-output-rx path)
                  (string-contains (basename path) fragment)
                  (string=? path (canonicalize-path path))
                  (let ((info (lstat path)))
                    (and (eq? (stat:type info) 'directory)
                         (= (stat:uid info) 0)
                         (= (stat:gid info) 0)
                         (= (logand (stat:mode info) #o7777) #o555))))
      (bundle-error "~a is not the pinned realized store output" name))
    path))

(define* (authenticated-guix-store-file path expected label
                                        #:key executable?)
  ;; Guix legitimately deduplicates immutable store files with hard links.
  ;; Authority here is the exact source-pinned store spelling and digest, not a
  ;; caller pathname and not an nlink count.  Keep one descriptor across hash
  ;; and identity checks so replacement cannot turn a validated inode into the
  ;; returned path.
  (unless (and (string? path) (sha256? expected)
               (regexp-exec store-file-rx path)
               (string=? path (canonicalize-path path)))
    (bundle-error "~a is not an exact canonical Guix store file" label))
  (let* ((before (lstat path))
         (fd (open-fdes path (logior O_RDONLY O_NOFOLLOW O_CLOEXEC)))
         (digest #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((held (stat fd)))
          (unless (and (same-stable-file? before held)
                       (eq? (stat:type held) 'regular)
                       (= (stat:uid held) 0)
                       (= (stat:gid held) 0)
                       (>= (stat:nlink held) 1)
                       (= (logand (stat:mode held) #o7777)
                          (if executable? #o555 #o444))
                       (if executable? (access? path X_OK) #t))
            (bundle-error "~a is not immutable root-owned Guix store data"
                          label))
          (set! digest
                (file-sha256-string (format #f "/proc/self/fd/~a" fd)))
          (unless (and (same-stable-file? held (stat fd))
                       (same-stable-file? held (lstat path)))
            (bundle-error "~a changed during stable-descriptor validation"
                          label))))
      (lambda () (close-fdes fd)))
    (unless (string=? digest expected)
      (bundle-error "~a differs from the pinned image binding" label))
    path))

(define (authenticated-store-executable output relative expected label)
  (unless (safe-relative? relative)
    (bundle-error "~a has an unsafe source-fixed executable role" label))
  (authenticated-guix-store-file
   (string-append output "/" relative) expected label #:executable? #t))

(define (authenticated-store-data path expected label)
  (authenticated-guix-store-file path expected label))

(define (read-append-line config)
  (let* ((lines (call-with-input-file config
                  (lambda (port)
                    (let loop ((result '()))
                      (let ((line (read-line port)))
                        (if (eof-object? line) (reverse result)
                            (loop (cons line result))))))))
         (values
          (filter-map
           (lambda (line)
             (let ((trimmed (string-trim-both line)))
               (and (string-prefix-ci? "append " trimmed)
                    (string-trim-both (substring trimmed 7)))))
           lines)))
    (unless (= (length values) 1)
      (bundle-error "boot config does not contain one APPEND line"))
    (let ((value (car values)))
      (unless (member "root=LABEL=PNGuixRoot" (string-tokenize value) string=?)
        (bundle-error "boot config does not select pinned root label"))
      value)))

(define (authenticate-two-boot-bundle-against-binding root binding)
  (validate-image-binding! binding)
  (let* ((root (canonical-directory root "boot artifact bundle"))
         (manifest-path (string-append root "/MANIFEST.sha256"))
         (manifest-hash-value (field binding 'bundle-manifest-sha256))
          (entries (parse-manifest manifest-path manifest-hash-value
                                   manifest-files "bundle manifest")))
    (unless (equal? (walk-inventory root)
                    (sort (cons "MANIFEST.sha256" manifest-files) string<?))
      (bundle-error "bundle inventory contains an addition or omission"))
    (for-each
     (lambda (entry)
       (let ((path (string-append root "/" (car entry))))
         (require-fixed-file path (car entry))
         (unless (string=? (file-sha256-string path) (cdr entry))
           (bundle-error "bundle file hash mismatch: ~a" (car entry)))))
     entries)
    (let* ((metadata (read-one-datum (string-append root "/BUNDLE.scm")))
            (_ (validate-two-boot-bundle-metadata-against-binding!
                metadata binding))
            (_reviewed-payload
             (authenticate-reviewed-payload-manifest! root metadata entries))
           (kernel (string-append root "/boot-bundle/extlinux/Image"))
           (initrd (string-append root "/boot-bundle/extlinux/initrd.cpio.gz"))
           (config (string-append root "/boot-bundle/extlinux/extlinux.conf"))
           (baseline (string-append root "/rootfs.raw"))
            (qemu-output (store-output metadata 'qemu-output "qemu-"))
            (gvisor-output
             (store-output metadata 'gvisor-source-output "gvisor-source-built-"))
            (e2fs-output (store-output metadata 'e2fsprogs-output "e2fsprogs-"))
            (koreader-output (store-output metadata 'koreader-output "koreader-bin-"))
            (kernel-output
             (store-output metadata 'kernel-output
                           "linux-pinenote-book-execution-test-"))
            (_image-system-output
             (store-output metadata 'image-embedded-system-output "system"))
            (guile-output (store-output metadata 'guile-output "guile-"))
            (python-output (store-output metadata 'python-output "python-"))
            (_gcrypt-output
             (store-output metadata 'guile-gcrypt-output "guile-gcrypt-"))
            (_guix-modules-output
             (store-output metadata 'guix-modules-output "guix-"))
            (coreutils-output (store-output metadata 'coreutils-output "coreutils-"))
            (qemu (authenticated-store-executable
                   qemu-output "bin/qemu-system-aarch64"
                   (field metadata 'qemu-system-sha256) "QEMU"))
            (qemu-img (authenticated-store-executable
                       qemu-output "bin/qemu-img"
                       (field metadata 'qemu-img-sha256) "qemu-img"))
            (mke2fs (authenticated-store-executable
                     e2fs-output "sbin/mke2fs"
                     (field metadata 'mke2fs-sha256) "mke2fs"))
            (e2fsck (authenticated-store-executable
                     e2fs-output "sbin/e2fsck"
                     (field metadata 'e2fsck-sha256) "e2fsck"))
            (guile (authenticated-store-executable
                    guile-output "bin/guile"
                    (field metadata 'guile-sha256) "Guile"))
            (cp (authenticated-store-executable
                 coreutils-output "bin/cp"
                 (field metadata 'cp-sha256) "cp"))
            (sha256sum (authenticated-store-executable
                        coreutils-output "bin/sha256sum"
                        (field metadata 'sha256sum-sha256) "sha256sum"))
            (python (authenticated-store-executable
                     python-output "bin/python3.11"
                     (field metadata 'python-sha256) "Python")))
      (authenticated-store-data
       (field metadata 'guest-source-gate-system-derivation)
       (field metadata 'guest-source-gate-system-derivation-sha256)
       "guest source-gate system derivation")
      (authenticated-store-data
       (field metadata 'image-derivation)
       (field metadata 'image-derivation-sha256) "image derivation")
      (authenticated-store-data
       (field metadata 'image-output)
       (field metadata 'image-output-sha256) "original reviewed raw image")
      (authenticated-store-data
       (field metadata 'image-embedded-system-derivation)
       (field metadata 'image-embedded-system-derivation-sha256)
       "image-embedded system derivation")
      (authenticated-store-data
       (field metadata 'image-initrd-output)
       (field metadata 'image-initrd-sha256) "actual image initrd")
      (authenticated-store-data
       (string-append kernel-output "/Image")
       (field metadata 'kernel-image-sha256) "kernel Image")
      (authenticated-store-data
       (string-append kernel-output "/.config")
       (field metadata 'kernel-config-sha256) "kernel config")
      (authenticated-store-data
       (string-append kernel-output
                      "/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb")
       (field metadata 'kernel-dtb-rk3566-pinenote-v1.2-sha256)
       "PineNote v1.2 DTB")
      (authenticated-store-executable
       gvisor-output "bin/runsc"
       (field metadata 'gvisor-runsc-sha256) "source-built gVisor runsc")
      (authenticated-store-executable
       koreader-output "lib/koreader/luajit"
       (field metadata 'koreader-luajit-sha256) "KOReader LuaJIT")
      (unless (and (string=? (manifest-hash entries "boot-bundle/extlinux/Image")
                             (field metadata 'kernel-image-sha256))
                   (string=? (manifest-hash entries
                                            "boot-bundle/extlinux/initrd.cpio.gz")
                             (field metadata 'initrd-sha256))
                   (string=? (manifest-hash entries
                                            "boot-bundle/extlinux/extlinux.conf")
                             (field metadata 'boot-config-sha256))
                   (string=? (manifest-hash entries "rootfs.raw")
                             (field metadata 'rootfs-sha256)))
        (bundle-error "bundle artifact hashes differ from pinned metadata"))
      (%make-two-boot-bundle
       root manifest-hash-value (field metadata 'bundle-id)
       kernel initrd config baseline (read-append-line config)
       (field metadata 'kernel-image-sha256) (field metadata 'initrd-sha256)
       (field metadata 'boot-config-sha256) (field metadata 'rootfs-sha256)
       qemu qemu-img mke2fs e2fsck guile cp sha256sum python koreader-output
        (field metadata 'guest-source-manifest-sha256)
        (field metadata 'guest-source-snapshot-manifest-sha256)
        (field metadata 'guest-capsule-roster-sha256)
        (field metadata 'guest-authority-source-sha256)
        (field metadata 'guest-contract-sha256)))))

(define (authenticate-production-two-boot-bundle root)
  ;; The caller supplies only a location.  All authority and every expected
  ;; identity come from the retained source binding before that location can be
  ;; accepted.
  (let ((binding (require-production-image-binding!)))
    (authenticate-two-boot-bundle-against-binding root binding)))
