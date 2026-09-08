(use-modules (ice-9 binary-ports)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-64)
             (two-boot ui-proxy))

(define root (mkdtemp "/tmp/opencode/two-boot-ui-proxy-test.XXXXXX"))
(chmod root #o700)
(define guest-pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
(define reader-pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
(define guest-peer (car guest-pair))
(define proxy-guest (cdr guest-pair))
(define proxy-reader (car reader-pair))
(define reader-peer (cdr reader-pair))
(define guest-bytes (string->utf8 "load-value|1|41\n"))
(define reader-bytes (string->utf8 "applied|1|41\n"))
(define proxy
  (make-private-ui-proxy
   proxy-guest proxy-reader
   (string-append root "/guest.bin")
   (string-append root "/reader.bin")))

(put-bytevector guest-peer guest-bytes)
(force-output guest-peer)
(shutdown guest-peer 1)
(put-bytevector reader-peer reader-bytes)
(force-output reader-peer)
(shutdown reader-peer 1)
(let loop ((attempt 0))
  (unless (private-ui-proxy-complete? proxy)
    (when (> attempt 500) (error "proxy did not complete"))
    (pump-private-ui-proxy! proxy)
    (usleep 1000)
    (loop (+ attempt 1))))

(test-begin "two-boot-ui-proxy")
(test-equal "guest bytes are forwarded unchanged"
  guest-bytes (get-bytevector-n reader-peer (bytevector-length guest-bytes)))
(test-equal "reader bytes are forwarded unchanged"
  reader-bytes (get-bytevector-n guest-peer (bytevector-length reader-bytes)))
(let ((snapshot (private-ui-proxy-snapshot proxy)))
  (test-equal "guest capture byte count"
    (bytevector-length guest-bytes) (assoc-ref snapshot 'guest-to-reader-bytes))
  (test-equal "reader capture byte count"
    (bytevector-length reader-bytes) (assoc-ref snapshot 'reader-to-guest-bytes))
  (test-assert "both directions reached exact EOF" (assoc-ref snapshot 'complete)))
(close-private-ui-proxy! proxy)
(test-equal "guest transcript is byte-exact"
  guest-bytes (call-with-input-file (string-append root "/guest.bin") get-bytevector-all))
(test-equal "reader transcript is byte-exact"
  reader-bytes (call-with-input-file (string-append root "/reader.bin") get-bytevector-all))
(close-port guest-peer)
(close-port reader-peer)
(delete-file (string-append root "/guest.bin"))
(delete-file (string-append root "/reader.bin"))
(rmdir root)
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-ui-proxy")
(exit (if (zero? failures) 0 1))
