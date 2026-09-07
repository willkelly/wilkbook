;;; Exact reader-specific extension of the accepted disposable-QEMU graph.
(define-module (reader-qemu-graph)
  #:use-module (disposable-qemu)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (reader-ui-port-name
            reader-ui-socket-path
            reader-qemu-arguments
            assert-reader-qemu-arguments
            reader-coordinator-arguments))

(define reader-ui-port-name "org.wilkbook.book-interaction")

(define accepted-qemu-arguments
  (@@ (disposable-qemu) qemu-argv))

(define (graph-error message . arguments)
  (throw 'book-execution-reader-qemu-graph-error
         (apply format #f message arguments)))

(define (reader-ui-socket-path run-root)
  (string-append run-root "/book-ui.sock"))

(define (reader-device-arguments run-root)
  (list
   "-chardev"
   (string-append "socket,id=bookui0,path="
                  (reader-ui-socket-path run-root)
                  ",server=on,wait=off")
   "-device" "virtio-serial-pci,id=book-ui-serial"
   "-device"
   (string-append
    "virtserialport,id=book-ui-port,chardev=bookui0,name="
    reader-ui-port-name)))

(define (insert-before-kernel base extra)
  (unless (= (count (lambda (value) (string=? value "-kernel")) base) 1)
    (graph-error "accepted QEMU vector lacks one -kernel boundary"))
  (let loop ((rest base) (prefix '()))
    (match rest
      (() (graph-error "accepted QEMU vector lacks one -kernel boundary"))
      ((head . tail)
       (if (string=? head "-kernel")
           (append (reverse prefix) extra rest)
           (loop tail (cons head prefix)))))))

(define (reader-qemu-arguments qemu run-root kernel initrd append-line overlay)
  ;; Preserve the accepted complete graph byte-for-byte and insert only the
  ;; fixed private chardev/controller/port triplet before its kernel options.
  (let ((base
         (accepted-qemu-arguments
          qemu run-root kernel initrd append-line overlay)))
    (when (any (lambda (value)
                 (or (string-contains value "bookui0")
                     (string-contains value "book-ui-serial")
                     (string-contains value reader-ui-port-name)))
               base)
      (graph-error "accepted QEMU vector unexpectedly contains reader UI state"))
    (insert-before-kernel base (reader-device-arguments run-root))))

(define (assert-reader-qemu-arguments arguments qemu run-root kernel initrd
                                      append-line overlay)
  (unless (and (list? arguments) (every string? arguments))
    (graph-error "reader QEMU vector must be a list of strings"))
  (let ((expected
         (reader-qemu-arguments
          qemu run-root kernel initrd append-line overlay)))
    (unless (equal? arguments expected)
      (graph-error "QEMU argument vector does not match the exact reader graph"))
    #t))

(define (reader-coordinator-arguments guile coordinator koreader qemu run-root
                                      kernel initrd append-line overlay)
  ;; The coordinator receives the complete QEMU vector without argv[0], exactly
  ;; as fixed by qemu-coordinator-contract.md.  There is no semantic/book input.
  (let ((qemu-arguments
         (reader-qemu-arguments
          qemu run-root kernel initrd append-line overlay)))
    (append
     (list guile "--no-auto-compile"
           "-L" (dirname coordinator)
           coordinator
           "--run-root" run-root
           "--socket" (reader-ui-socket-path run-root)
           "--koreader-package" koreader
           "--qemu" qemu
           "--")
     (cdr qemu-arguments))))
