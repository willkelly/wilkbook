(use-modules (srfi srfi-1) (srfi srfi-64) (two-boot graph))

(define qemu "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-qemu/bin/qemu-system-aarch64")
(define root "/tmp/opencode/graph-fixture")
(define kernel (string-append root "/boot/Image"))
(define initrd (string-append root "/boot/initrd.cpio.gz"))
(define overlay (string-append root "/disk-overlay.qcow2"))
(define append-line "console=ttyAMA0 root=PNGuixRoot ro")
(define state "/proc/self/fd/17")
(define graph
  (two-boot-qemu-arguments qemu root kernel initrd append-line overlay state))

(define (rejected? thunk)
  (catch 'book-state-two-boot-graph-error
    (lambda () (thunk) #f)
    (lambda _ #t)))

(test-begin "two-boot-graph")
(test-assert "accepted reader graph plus state graph is exact"
  (assert-two-boot-qemu-arguments
   graph qemu root kernel initrd append-line overlay state))
(test-equal "resource narrowing is exact"
  '("-smp" "2" "-m" "512")
  (let ((smp (list-index (lambda (item) (string=? item "-smp")) graph))
        (memory (list-index (lambda (item) (string=? item "-m")) graph)))
    (list (list-ref graph smp) (list-ref graph (+ smp 1))
          (list-ref graph memory) (list-ref graph (+ memory 1)))))
(test-assert "graph is unpaused" (not (member "-S" graph)))
(test-assert "state path parser rejects leading-zero aliases"
  (and (not (state-proc-file->fd "/proc/self/fd/017"))
       (= (state-proc-file->fd state) 17)))
(test-assert "paused mutation is rejected"
  (rejected?
   (lambda ()
     (assert-two-boot-qemu-arguments
      (append graph '("-S")) qemu root kernel initrd append-line overlay state))))
(test-assert "network mutation is rejected"
  (rejected?
   (lambda ()
     (assert-two-boot-qemu-arguments
      (append graph '("-netdev" "user,id=bad"))
      qemu root kernel initrd append-line overlay state))))
(test-assert "path-opened state mutation is rejected"
  (rejected?
   (lambda ()
     (two-boot-qemu-arguments qemu root kernel initrd append-line overlay
                              "/tmp/opencode/state.ext4"))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-graph")
(exit (if (zero? failures) 0 1))
