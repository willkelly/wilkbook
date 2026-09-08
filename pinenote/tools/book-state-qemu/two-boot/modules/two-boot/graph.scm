;;; Exact unpaused two-boot reader graph over the frozen accepted reader graph.
(define-module (two-boot graph)
  #:use-module (reader-qemu-graph)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (two-boot-vcpus
            two-boot-memory-mib
            two-boot-qemu-arguments
            assert-two-boot-qemu-arguments
            state-proc-file->fd
            state-proc-file-from-arguments))

(define two-boot-vcpus "2")
(define two-boot-memory-mib "512")
(define state-file-node "book-state-file")
(define state-raw-node "book-state")
(define state-device-id "book-state-disk")
(define state-device-serial "WBBOOKSTATEV1")

(define (graph-error message . arguments)
  (throw 'book-state-two-boot-graph-error
         (apply format #f message arguments)))

(define (state-proc-file->fd value)
  (let ((prefix "/proc/self/fd/"))
    (and (string? value)
         (string-prefix? prefix value)
         (> (string-length value) (string-length prefix))
         (every char-numeric?
                (string->list (substring value (string-length prefix))))
         (let* ((digits (substring value (string-length prefix)))
                (fd (string->number digits 10)))
           (and fd (> fd 2)
                (string=? digits (number->string fd))
                fd)))))

(define (replace-exact-pair arguments option old-value new-value)
  (let loop ((rest arguments) (result '()) (seen? #f))
    (cond
     ((null? rest)
      (unless seen? (graph-error "accepted graph lacks ~a" option))
      (reverse result))
     ((string=? (car rest) option)
      (when seen? (graph-error "accepted graph repeats ~a" option))
      (unless (and (pair? (cdr rest)) (string=? (cadr rest) old-value))
        (graph-error "accepted graph changed ~a from ~a" option old-value))
      (loop (cddr rest) (cons new-value (cons option result)) #t))
     (else (loop (cdr rest) (cons (car rest) result) seen?)))))

(define (state-device-arguments state-proc-file)
  (unless (state-proc-file->fd state-proc-file)
    (graph-error "state file must be one inherited /proc/self/fd/N"))
  (list
   "-blockdev"
   (string-append
    "{\"driver\":\"file\",\"filename\":\"" state-proc-file
    "\",\"node-name\":\"" state-file-node
    "\",\"read-only\":false,\"locking\":\"on\"}")
   "-blockdev"
   (string-append
    "{\"driver\":\"raw\",\"file\":\"" state-file-node
    "\",\"node-name\":\"" state-raw-node
    "\",\"read-only\":false}")
   "-device"
   (string-append "virtio-blk-pci,drive=" state-raw-node
                  ",id=" state-device-id
                  ",serial=" state-device-serial)))

(define (bounded-accepted-reader-arguments qemu run-root kernel initrd
                                            append-line overlay)
  ;; The accepted graph is the oracle.  The successor deliberately narrows only
  ;; its historical 4-vCPU/2-GiB resource request.
  (let* ((accepted
          (reader-qemu-arguments
           qemu run-root kernel initrd append-line overlay))
         (vcpus
          (replace-exact-pair accepted "-smp" "4" two-boot-vcpus))
         (memory
          (replace-exact-pair vcpus "-m" "2048" two-boot-memory-mib)))
    (unless (string=? (last memory)
                      "virtio-blk-pci,drive=rootfs-overlay")
      (graph-error "accepted root device is no longer the trailing base device"))
    memory))

(define (two-boot-qemu-arguments qemu run-root kernel initrd append-line
                                 overlay state-proc-file)
  (append
   (bounded-accepted-reader-arguments
    qemu run-root kernel initrd append-line overlay)
   (state-device-arguments state-proc-file)))

(define (option-values arguments option)
  (let loop ((rest arguments) (values '()))
    (cond
     ((null? rest) (reverse values))
     ((string=? (car rest) option)
      (unless (pair? (cdr rest))
        (graph-error "QEMU option ~a lacks a value" option))
      (loop (cddr rest) (cons (cadr rest) values)))
     (else (loop (cdr rest) values)))))

(define (state-proc-file-from-arguments arguments)
  (let* ((prefix
          "{\"driver\":\"file\",\"filename\":\"")
         (suffix
          "\",\"node-name\":\"book-state-file\",\"read-only\":false,\"locking\":\"on\"}")
         (matches
          (filter-map
           (lambda (value)
             (and (string-prefix? prefix value)
                  (string-suffix? suffix value)
                  (substring value (string-length prefix)
                             (- (string-length value)
                                (string-length suffix)))))
           (option-values arguments "-blockdev"))))
    (unless (= (length matches) 1)
      (graph-error "QEMU vector does not contain one canonical state file node"))
    (unless (state-proc-file->fd (car matches))
      (graph-error "state file node does not name one inherited descriptor"))
    (car matches)))

(define forbidden-fragments
  '("-S" "-snapshot" "snapshot=on" "cache.no-flush=on"
    "locking=off" "hostfwd=" "guestfwd=" "user,id=" "tap,id="
    "virtio-9p" "virtiofs" "vhost-user-fs" "-virtfs" "-fsdev"
    "-qmp" "-incoming" "-monitor tcp:" "-chardev tcp"))

(define (assert-two-boot-qemu-arguments arguments qemu run-root kernel initrd
                                         append-line overlay state-proc-file)
  (unless (and (list? arguments) (every string? arguments))
    (graph-error "QEMU vector must be a list of strings"))
  (let ((expected
         (two-boot-qemu-arguments qemu run-root kernel initrd append-line
                                  overlay state-proc-file)))
    (unless (equal? arguments expected)
      (graph-error "QEMU vector differs from the exact unpaused successor")))
  (unless (and (= (count (lambda (value) (string=? value "-nic")) arguments) 1)
               (equal? (option-values arguments "-nic") '("none"))
               (= (count (lambda (value) (string=? value "-monitor")) arguments)
                  1)
               (equal? (option-values arguments "-monitor") '("none")))
    (graph-error "QEMU graph changed its no-network/no-monitor boundary"))
  (let ((joined (string-join arguments "\n")))
    (for-each
     (lambda (fragment)
       (when (string-contains joined fragment)
         (graph-error "QEMU graph contains forbidden fragment ~s" fragment)))
     forbidden-fragments))
  (unless (string=? (state-proc-file-from-arguments arguments) state-proc-file)
    (graph-error "QEMU graph names another state descriptor"))
  #t)
