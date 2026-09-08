;;; Bounded host checks over the actual accepted Guile modules and mocked UI
;;; transport.  No runsc, QEMU, target code, image, network, or device is used.
(use-modules (book-state)
             (book-state-guest-authority)
             (book-state-reader-bridge)
             (gcrypt base16)
             (gcrypt hash)
             (guest-virtio-book-ui)
             (ice-9 ftw)
             (ice-9 textual-ports)
             (private-control)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (get-bytevector-n put-bytevector))
             (srfi srfi-13)
             (srfi srfi-64))

(define scratch #f)

(unless (= (length (command-line)) 3)
  (error "test-guest-modules requires RELAY-FIXTURE HOST-GUILE"))
(define relay-fixture (cadr (command-line)))
(define host-guile (caddr (command-line)))

(define (throws-guest-error? thunk)
  (catch 'book-state-guest-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (throws-anything? thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define %base-module (resolve-module '(guest-book-protocol)))
(define (base-private name) (module-ref %base-module name))

(define (language-container language)
  (case language
    ((guile) "wilkbook-guile-book-state")
    ((python) "wilkbook-python-book-state")
    (else (error "unknown relay-model language" language))))

(define (exact-boundary-marker language)
  (format #f
          "BOOK_STATE_SANDBOX_BOUNDARY: language=~a result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3"
          language))

(define (await-and-finalize-model-child! child)
  (let ((deadline (+ (get-internal-real-time)
                     (* 15 internal-time-units-per-second))))
    (let loop ()
      ((base-private 'reap-owned-runsc!) child)
      ((base-private 'pump-owned-captures!) child 5000)
      (unless ((@@ (guest-book-protocol) owned-runsc-status) child)
        (when (>= (get-internal-real-time) deadline)
          (error "relay model child exceeded host deadline"))
        (loop))))
  ((base-private 'finalize-owned-runsc!) child)
  ((base-private 'capture-result) child))

(define (model-case-root name)
  (let ((path (string-append scratch "/relay-" name)))
    (mkdir path #o700)
    path))

(define (run-relay-model case-name scenario language fixture-language mutation)
  (let* ((root (model-case-root case-name))
         (stdout (string-append root "/runsc.stdout"))
         (stderr (string-append root "/runsc.stderr"))
         (record (string-append root "/runsc.pid"))
         (console (string-append root "/console.log"))
         (pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
         (donation (car pair))
         (unused-peer (cdr pair))
         (child
          ((base-private 'spawn-owned-runsc)
           scenario record donation
           (list host-guile "--no-auto-compile" "-s" relay-fixture
                 scenario (symbol->string fixture-language))
           (list "HOME=/nonexistent" "LANG=C" "LC_ALL=C"
                 "GUILE_AUTO_COMPILE=0")
           root stdout stderr))
         (emitted '()))
    (close-port donation)
    (close-port unused-peer)
    (let ((result (await-and-finalize-model-child! child)))
      (define (model-console-emit line)
        (when (or (eq? mutation 'emit-source-failure)
                  (and (eq? mutation 'emit-marker-failure)
                       (= (length emitted) 1)))
          (error "model console publication failure" mutation))
        (set! emitted (append emitted (list line)))
        (let ((port (open-file console "a")))
          (display line port)
          (newline port)
          (force-output port)
          (close-port port)))
      (case mutation
        ((delete) (delete-file stdout))
        ((late-writer)
         (let ((port (open-file stdout "ab")))
           (display "LATE-WRITER-AFTER-FINALIZED-DRAIN\n" port)
           (force-output port)
           (close-port port)))
        ((none wrong-container emit-source-failure emit-marker-failure) #t)
        (else (error "unknown relay-model mutation" mutation)))
      (let ((failed?
             (throws-anything?
              (lambda ()
                ((@@ (book-state-guest-authority)
                     validate-and-publish-sandbox-boundary!)
                 language
                 (if (eq? mutation 'wrong-container)
                     "wilkbook-wrong-book-state"
                     (language-container language))
                 root child result
                 model-console-emit)))))
        `((failed? . ,failed?)
          (emitted . ,emitted)
          (console . ,console)
          (stdout . ,stdout)
          (result . ,result))))))

(define (model-value result name)
  (cdr (assq name result)))


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

;; Exercise the exact authority helper that the real runsc join calls.  Each
;; case uses the accepted owned-process/capture implementation with a harmless
;; native Guile writer in place of runsc.  This models relay observability only;
;; it is not gVisor, Sentry, ARM, or containment evidence.
(define (capture-sha256 path)
  (bytevector->base16-string (file-sha256 path)))

(define (assert-valid-relay-model language)
  (let* ((case-name (string-append "valid-" (symbol->string language)))
         (result (run-relay-model case-name "valid" language language 'none))
         (emitted (model-value result 'emitted))
         (stdout (model-value result 'stdout))
         (console (model-value result 'console))
         (expected-marker (exact-boundary-marker (symbol->string language)))
         (marker-sha256
          (bytevector->base16-string (sha256 (string->utf8 expected-marker))))
         (capture-bytes (stat:size (lstat stdout)))
         (expected-source
          (format #f
                  "BOOK-STATE-GUEST sandbox-boundary-source language=~a container=~a source=owned-finalized-runsc.stdout publication=next-line-after-child-drain marker-bytes=~a marker-sha256=~a capture-bytes=~a capture-sha256=~a"
                  language (language-container language)
                  (bytevector-length (string->utf8 expected-marker))
                  marker-sha256 capture-bytes (capture-sha256 stdout))))
    (test-assert (format #f "~a model child reaches real finalized-capture helper"
                         language)
      (not (model-value result 'failed?)))
    (test-equal (format #f "~a relay emits owned attribution then actual marker"
                        language)
      (list expected-source expected-marker) emitted)
    (test-equal (format #f "~a model console bytes equal captured marker relay"
                        language)
      (string-append expected-source "\n" expected-marker "\n")
      (call-with-input-file console get-string-all))
    (format #t "HOST-RELAY-MODEL-AUTHORITY: ~a~%" (car emitted))
    (format #t "HOST-RELAY-MODEL-ACTUAL: ~a~%" (cadr emitted))))

(assert-valid-relay-model 'guile)
(assert-valid-relay-model 'python)

(for-each
 (lambda (case)
   (let* ((case-name (list-ref case 0))
          (scenario (list-ref case 1))
          (language (list-ref case 2))
          (fixture-language (list-ref case 3))
          (mutation (list-ref case 4))
          (result
           (run-relay-model case-name scenario language fixture-language
                            mutation)))
     (test-assert (string-append case-name " fails the real relay helper")
       (model-value result 'failed?))
     (test-equal (string-append case-name " emits no trusted pass line")
       '() (model-value result 'emitted))
     (test-assert (string-append case-name " creates no model console output")
       (not (file-exists? (model-value result 'console))))))
 '(("missing-marker" "missing" guile guile none)
   ("wrong-language" "valid" guile python none)
   ("wrong-container" "valid" guile guile wrong-container)
   ("duplicate-marker" "duplicate" guile guile none)
   ("quoted-extra-marker" "extra" guile guile none)
   ("failure-marker" "failure-record" guile guile none)
   ("malformed-marker" "malformed" guile guile none)
   ("truncated-marker" "truncated" guile guile none)
   ("invalid-utf8-capture" "invalid-utf8" guile guile none)
   ("nonzero-with-marker" "nonzero" guile guile none)
   ("overflow-with-marker" "overflow" guile guile none)
   ("stderr-overflow-with-marker" "stderr-overflow" guile guile none)
   ("deleted-final-capture" "valid" guile guile delete)
   ("late-writer-after-finalize" "valid" guile guile late-writer)))

(let ((result
       (run-relay-model "source-publication-failure" "valid"
                        'guile 'guile 'emit-source-failure)))
  (test-assert "source publication failure fails the real relay helper"
    (model-value result 'failed?))
  (test-equal "source publication failure emits nothing"
    '() (model-value result 'emitted))
  (test-assert "source publication failure emits no trusted marker"
    (not (file-exists? (model-value result 'console)))))

(let* ((result
        (run-relay-model "marker-publication-failure" "valid"
                         'guile 'guile 'emit-marker-failure))
       (emitted (model-value result 'emitted)))
  (test-assert "marker publication failure fails the real relay helper"
    (model-value result 'failed?))
  (test-assert "marker publication failure retains only non-pass attribution"
    (and (= (length emitted) 1)
         (string-prefix? "BOOK-STATE-GUEST sandbox-boundary-source "
                         (car emitted))
         (not (string-contains (car emitted) "result=pass"))
         (not (string-contains (car emitted)
                               "BOOK_STATE_SANDBOX_BOUNDARY"))))
  (test-equal "marker publication failure emits no complete trusted marker"
    (string-append (car emitted) "\n")
    (call-with-input-file (model-value result 'console) get-string-all)))

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
