;;; Bounded host checks over the actual accepted Guile modules and mocked UI
;;; transport.  No runsc, QEMU, target code, image, network, or device is used.
(use-modules (book-state)
             (book-state-guest-authority)
             (book-state-reader-bridge)
             (guest-virtio-book-ui)
             (ice-9 ftw)
             (private-control)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (get-bytevector-n put-bytevector))
             (srfi srfi-64))

(define scratch #f)

(define (throws-guest-error? thunk)
  (catch 'book-state-guest-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (remove-private-tree! root)
  (when (and root (file-exists? root))
    (for-each
     (lambda (name)
       (unless (member name '("." ".."))
         (let ((path (string-append root "/" name)))
           (if (eq? (stat:type (lstat path)) 'directory)
               (begin (remove-private-tree! path) (rmdir path))
               (delete-file path)))))
     (scandir root))))

(test-begin "book-state-guest-modules")
(define runner (test-runner-current))

(test-equal "absent Guile state selects first-boot save"
  'absent
  (classify-loaded-state 'guile '(absent 0 "")))
(test-equal "accepted Guile A selects restart recovery/save B"
  'a
  (classify-loaded-state
   'guile '(value 1 "Mémoire persistante A — 東京 λ\nligne deux")))
(test-equal "accepted Python B selects stable no-new-save state"
  'b
  (classify-loaded-state
   'python '(value 2 "Примечание Python B — 東京 — λ")))
(test-assert "unexpected version/text pair fails closed"
  (throws-guest-error?
   (lambda ()
     (classify-loaded-state
      'python '(value 1 "Примечание Python B — 東京 — λ")))))

;; ext4's standard lost+found is not an application namespace.  The accepted
;; backend contract permits it because only the root and fixed database object
;; are security-sensitive.
(set! scratch
      (mkdtemp
       (string-append (or (getenv "TMPDIR") "/tmp/opencode")
                      "/book-state-guest-modules.XXXXXX")))
(chmod scratch #o700)
(mkdir (string-append scratch "/lost+found") #o700)
(let ((runtime (open-reader-state-runtime scratch)))
  (test-assert "accepted backend opens a private root containing lost+found"
    (reader-state-runtime? runtime))
  (test-equal "accepted backend closes after no live endpoint workers"
    'closed (close-reader-state-runtime! runtime)))
(let ((database (string-append scratch "/book-state-v1.sqlite")))
  (test-assert "backend selected the fixed database basename"
    (and (file-exists? database)
         (= (logand (stat:mode (lstat database)) #o7777) #o600))))

(define fixed-test-profiles
  '((guile "reader-note/guile@1" "persistent-note-guile"
           "Mémoire persistante A — 東京 λ\nligne deux"
           "Mémoire persistante B — Αθήνα — café")
    (python "reader-note/python@1" "persistent-note-python"
            "Примечание Python A — مرحبا — café"
            "Примечание Python B — 東京 — λ")))

(define (expected-results version)
  (map (lambda (selected)
         `((language . ,(car selected))
           (final-version . ,version)
           (final-text . ,(list-ref selected (+ version 2)))))
       fixed-test-profiles))

(define (commit-fixed-version! version)
  (let ((store (open-book-state-store scratch)))
    (for-each
     (lambda (selected)
       (let* ((language (car selected))
              (namespace
               (open-book-instance! store (cadr selected) (caddr selected)))
              (owner (list 'host-inspector-test language version))
              (grant (issue-book-state-grant!
                      store namespace owner 'read-write))
              (receipt
               (commit-book-state!
                store owner grant (book-state-grant-generation grant)
                (format #f "guest-test-~a-v~a" language version)
                (- version 1) (list-ref selected (+ version 2)))))
         (test-assert (format #f "accepted backend commits ~a version ~a"
                              language version)
           (and (book-state-receipt? receipt)
                (= (book-state-receipt-state-version receipt) version)))
         (test-equal (format #f "accepted backend revokes ~a version ~a grant"
                             language version)
           'revoked (revoke-book-state-grant! store owner grant))))
     fixed-test-profiles)
    (test-equal (format #f "accepted backend closes after version ~a" version)
      'closed (close-book-state-store! store))))

(commit-fixed-version! 1)
(test-assert "actual authority inspector accepts exact closed A/version-1 database"
  ((@@ (book-state-guest-authority) inspect-database-contents!)
   (string-append scratch "/book-state-v1.sqlite")
   (expected-results 1) (getuid) (lambda arguments #t)))
(commit-fixed-version! 2)
(test-assert "actual authority inspector accepts exact closed B/version-2 database"
  ((@@ (book-state-guest-authority) inspect-database-contents!)
   (string-append scratch "/book-state-v1.sqlite")
   (expected-results 2) (getuid) (lambda arguments #t)))

;; Exercise the real state private codec through the accepted guest virtio
;; owner using a socketpair in place of the character device.
(let* ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
       (control (adopt-book-ui-control-port! (car pair)
                                             #:require-character? #f))
       (peer (cdr pair))
       (event-frame
        (encode-control-line 'channel-ready 1 "" reader-event-kinds)))
  (put-bytevector peer event-frame)
  (force-output peer)
  (test-equal "mocked private transport decodes accepted channel-ready"
    '(channel-ready 1 "")
    (pump-book-ui-input! control))
  (let* ((expected (encode-control-line 'open 1 "" reader-command-kinds))
         (ticket (queue-book-ui-command! control 'open 1 "")))
    (test-equal "mocked private transport drains one bounded command"
      (list 'drained (bytevector-length expected) 1)
      (pump-book-ui-output! control))
    (test-assert "command delivery ticket advances only after full write"
      (book-ui-command-delivered? control ticket))
    (test-equal "mocked peer receives exact state-reader command bytes"
      expected (get-bytevector-n peer (bytevector-length expected))))
  (close-book-ui-control! control)
  (close-port peer))

(remove-private-tree! scratch)
(rmdir scratch)
(set! scratch #f)

(test-end "book-state-guest-modules")
(when (positive? (test-runner-fail-count runner))
  (exit 1))
