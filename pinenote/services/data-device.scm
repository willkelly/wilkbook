(define-module (pinenote services data-device)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (pinenote-data-device-service-type))

;; Let Guix retain ownership of fsck/mount/unmount. Only the device lookup
;; changes: udev's filesystem probe can fail while a dirty ext4 journal needs
;; replay, even though the kernel has already read GPT's PARTNAME correctly.
(define (data-device-services _)
    (list
     (shepherd-service
      (provision '(pinenote-data-device))
      (requirement '(root-file-system udev))
      (one-shot? #t)
      (documentation "Resolve the GPT data partition before Guix checks and mounts it.")
      (modules '((pinenote lib data-device)))
      (start
       (with-imported-modules '((pinenote lib data-device))
        #~(lambda _
           (let ((link "/run/wilkbook-data-device"))
             ;; /run is ephemeral; never retain a previous resolution on retry.
             (when (false-if-exception (lstat link)) (delete-file link))
             (catch #t
               (lambda ()
                 (let ((device (resolve-data-device)))
                   (if device
                       (begin
                         (symlink device link)
                         (format #t "pinenote-data-device: ~a -> ~a~%" link device))
                       (format #t "pinenote-data-device: no data partition; library unavailable~%"))))
               (lambda args
                 (format (current-error-port)
                         "pinenote-data-device: resolution failed: ~s; library unavailable~%" args)))
             ;; Settle even on failure: the existing mount-may-fail path boots
             ;; a diagnostic reader for recovery. Health refuses promotion.
             #t))))
      (stop #~(const #t)))))

(define pinenote-data-device-service-type
  (service-type
   (name 'pinenote-data-device)
   (extensions (list (service-extension shepherd-root-service-type data-device-services)))
   (default-value #f)
   (description "Find the data partition by kernel GPT metadata, independent of udev filesystem probing.")))
