(use-modules (reader-qemu-graph)
             (srfi srfi-1)
             (srfi srfi-64))

(define qemu "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-qemu/bin/qemu-system-aarch64")
(define guile "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-guile/bin/guile")
(define coordinator "/gnu/store/cccccccccccccccccccccccccccccccc-reader-coordinator/qemu-coordinator.scm")
(define koreader "/gnu/store/dddddddddddddddddddddddddddddddd-koreader-bin-2026.03")
(define root "/tmp/opencode/book-reader-qemu.123456")
(define kernel (string-append root "/boot/Image"))
(define initrd (string-append root "/boot/initrd.cpio.gz"))
(define overlay (string-append root "/disk-overlay.qcow2"))
(define append-line "root=PNGuixRoot console=ttyAMA0")
(define expected-ui
  (string-append "socket,id=bookui0,path=" root
                 "/book-ui.sock,server=on,wait=off"))
(define expected-console
  (string-append "socket,id=console0,path=" root
                 "/console.sock,server=on,wait=off,logfile=" root
                 "/console.log,logappend=off"))
(define expected-overlay-file
  (string-append
   "{\"driver\":\"file\",\"filename\":\"" overlay
   "\",\"node-name\":\"rootfs-overlay-file\",\"read-only\":false}"))
(define expected-overlay-format
  "{\"driver\":\"qcow2\",\"file\":\"rootfs-overlay-file\",\"node-name\":\"rootfs-overlay\",\"read-only\":false}")
(define expected-reader-arguments
  (list qemu
        "-no-user-config" "-nodefaults"
        "-M" "virt" "-accel" "tcg,thread=multi" "-cpu" "max"
        "-smp" "4" "-m" "2048" "-display" "none" "-no-reboot"
        "-nic" "none" "-monitor" "none"
        "-chardev" expected-console "-serial" "chardev:console0"
        "-chardev" expected-ui
        "-device" "virtio-serial-pci,id=book-ui-serial"
        "-device"
        "virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction"
        "-kernel" kernel "-initrd" initrd "-append" append-line
        "-blockdev" expected-overlay-file
        "-blockdev" expected-overlay-format
        "-device" "virtio-blk-pci,drive=rootfs-overlay"))

(define (graph-error? thunk)
  (catch 'book-execution-reader-qemu-graph-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(test-begin "reader-qemu-graph")

(let ((arguments
       (reader-qemu-arguments qemu root kernel initrd append-line overlay)))
  (test-assert "exact reader graph self-validates"
    (assert-reader-qemu-arguments
     arguments qemu root kernel initrd append-line overlay))
  (test-equal "exact coordinator-approved reader graph"
    expected-reader-arguments arguments)
  (test-equal "one UI socket chardev"
    1 (count (lambda (item) (string=? item expected-ui)) arguments))
  (test-equal "one virtio-serial controller"
    1 (count (lambda (item)
               (string=? item "virtio-serial-pci,id=book-ui-serial"))
             arguments))
  (test-equal "one exact named virtserial port"
    1 (count
       (lambda (item)
         (string=?
          item
          "virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction"))
       arguments))
  (test-equal "UI channel has no logfile"
    #f (string-contains expected-ui "logfile="))
  (test-equal "accepted no-network/no-share controls remain exact"
    '(1 1 0 0 0)
    (list (count (lambda (item) (string=? item "-nic")) arguments)
          (count (lambda (item) (string=? item "none"))
                 (let loop ((rest arguments) (after-nic? #f) (values '()))
                   (cond
                    ((null? rest) values)
                    (after-nic? (loop (cdr rest) #f (cons (car rest) values)))
                    (else (loop (cdr rest) (string=? (car rest) "-nic")
                                values)))))
          (count (lambda (item) (string=? item "-netdev")) arguments)
          (count (lambda (item) (string=? item "-virtfs")) arguments)
          (count (lambda (item) (string=? item "-fsdev")) arguments)))
  (for-each
   (lambda (mutation label)
     (test-assert label
       (graph-error?
        (lambda ()
          (assert-reader-qemu-arguments
           mutation qemu root kernel initrd append-line overlay)))))
   (list (delete expected-ui arguments)
         (cons expected-ui arguments)
         (map (lambda (item)
                (if (string=? item expected-ui)
                    (string-append expected-ui ",logfile=" root "/ui.log")
                    item))
              arguments)
         (map (lambda (item) (if (string=? item "none") "user" item))
              arguments)
         (append arguments (list "-virtfs" "local,path=/tmp")))
   '("missing UI chardev fails"
     "duplicated UI chardev fails"
     "UI logfile fails"
     "network mutation fails"
     "host share mutation fails")))

(let ((arguments
       (reader-coordinator-arguments
        guile coordinator koreader qemu root kernel initrd append-line overlay)))
  (test-equal "coordinator fixed prefix and four named options"
    (list guile "--no-auto-compile" "-L" (dirname coordinator) coordinator
          "--run-root" root
          "--socket" (string-append root "/book-ui.sock")
          "--koreader-package" koreader
          "--qemu" qemu
          "--")
    (take arguments 14))
  (test-equal "coordinator receives QEMU vector without argv zero"
    (cdr (reader-qemu-arguments qemu root kernel initrd append-line overlay))
    (drop arguments 14)))

(test-end "reader-qemu-graph")
