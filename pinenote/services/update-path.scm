(define-module (pinenote services update-path)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages package-management)
  #:use-module (guix gexp)
  #:export (pinenote-grow-root-service-type
            pinenote-guix-acl-service-type))

;;; Two one-shots for the update path (doc/update-path.md).
;;;
;;; pinenote-grow-root: the shipped ext4 is image-sized (1.76 GB) inside a
;;; 15.7 GB partition; system generations need the rest.  An online
;;; resize2fs of the mounted root is a supported grow; on a filesystem
;;; that already fills its device it says "Nothing to do" and exits 0,
;;; so every boot may run it.  The device is read from the mount table,
;;; never assumed.
;;;
;;; pinenote-guix-acl: `guix copy --to` imports only nars signed by a key
;;; in /etc/guix/acl.  The signing key is per-operator and lives outside
;;; the repo, so the device authorizes whatever public keys the data
;;; partition carries under /data/wilkbook/guix/authorized-keys/ -- the
;;; same out-of-band pattern as the Wi-Fi credentials, and it survives a
;;; reflash for the same reason.  `guix archive --authorize` is
;;; idempotent (the ACL is a set).  No keys present is a no-op, logged.

(define (pinenote-grow-root-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-grow-root))
    (requirement '(root-file-system))
    (documentation "Grow the ext4 root filesystem to fill its partition (idempotent).")
    (one-shot? #t)
    (start
     #~(lambda _
         (let* ((findmnt #$(file-append util-linux "/bin/findmnt"))
                (resize2fs #$(file-append e2fsprogs "/sbin/resize2fs"))
                (port (open-pipe* OPEN_READ findmnt "-n" "-o" "SOURCE" "/"))
                (device (read-line port)))
           (close-pipe port)
           (if (and (string? device) (string-prefix? "/dev/" device))
               (zero? (system* resize2fs device))
               (begin
                 (format (current-error-port)
                         "pinenote-grow-root: could not resolve the root device (~s); skipping~%"
                         device)
                 #t)))))
    (stop #~(const #t))
    (modules '((ice-9 popen) (ice-9 rdelim))))))

(define pinenote-grow-root-service-type
  (service-type
   (name 'pinenote-grow-root)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-grow-root-shepherd-service)))
   (default-value #f)
   (description "Grow the root filesystem to its partition on every boot (no-op once full).")))

(define %authorized-keys-dir "/data/wilkbook/guix/authorized-keys")

(define (pinenote-guix-acl-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-guix-acl))
    (requirement '(file-systems guix-daemon))
    (documentation "Authorize the operator's guix signing keys from the data partition (idempotent).")
    (one-shot? #t)
    (start
     #~(lambda _
         (let ((guix #$(file-append guix "/bin/guix"))
               (dir #$%authorized-keys-dir))
           (if (file-exists? dir)
               (let ((keys (filter (lambda (name) (string-suffix? ".pub" name))
                                   (scandir dir))))
                 (if (null? keys)
                     (format (current-error-port)
                             "pinenote-guix-acl: no *.pub under ~a; guix copy imports will be refused~%" dir)
                     (for-each
                      (lambda (name)
                        (let ((path (string-append dir "/" name)))
                          (format (current-error-port) "pinenote-guix-acl: authorizing ~a~%" path)
                          (unless (zero? (system (string-append guix " archive --authorize < " path)))
                            (format (current-error-port) "pinenote-guix-acl: FAILED to authorize ~a~%" path))))
                      keys)))
               (format (current-error-port)
                       "pinenote-guix-acl: ~a absent; guix copy imports will be refused~%" dir))
           #t)))
    (stop #~(const #t))
    (modules '((ice-9 ftw))))))

(define pinenote-guix-acl-service-type
  (service-type
   (name 'pinenote-guix-acl)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-guix-acl-shepherd-service)))
   (default-value #f)
   (description "Authorize per-operator guix signing keys found on the data partition, so `guix copy --to` imports are accepted.")))
