#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Exercise the production successor boot-bundle parser and its closed boundaries.
(use-modules (ice-9 ftw)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64)
             (disposable-qemu))

(define read-fixed-append (@@ (disposable-qemu) read-fixed-append))
(define validate-boot-bundle (@@ (disposable-qemu) validate-boot-bundle))
(define work (mkdtemp "/tmp/opencode/two-boot-append-test.XXXXXX"))
(chmod work #o700)

(define system "/gnu/store/a4qgl0y3k0c265mwx9wx0v8g24jla6bs-system")
(define system-arguments
  (string-append "gnu.system=" system " gnu.load=" system "/boot"))

(define (write-config name append)
  (let ((path (string-append work "/" name)))
    (call-with-output-file path
      (lambda (port) (format port "LABEL test~%  APPEND ~a~%" append)))
    (chmod path #o400)
    path))

(define (append-from-config path)
  (call-with-input-file path
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (cond
           ((eof-object? line) (error "test config lacks APPEND"))
           ((string-prefix? "  APPEND " line) (substring line 9))
           (else (loop))))))))

(define (rejected? thunk)
  (catch 'book-execution-qemu-error
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define bundle-root (getenv "TWO_BOOT_V9_BUNDLE"))
(unless bundle-root (error "TWO_BOOT_V9_BUNDLE is required"))
(define boot-root (string-append bundle-root "/boot-bundle"))
(define actual-config (string-append boot-root "/extlinux/extlinux.conf"))
(define actual-append (append-from-config actual-config))

(test-begin "production boot-bundle APPEND")

(let ((validated (validate-boot-bundle boot-root)))
  (test-assert "immutable successor input keeps its prepared LABEL spelling"
    (member "root=LABEL=PNGuixRoot" (string-tokenize actual-append)))
  (test-equal "actual successor emits exactly one Guix-native root"
    '("root=PNGuixRoot")
    (filter (lambda (token) (string-prefix? "root=" token))
            (string-tokenize (list-ref validated 4))))
  (test-equal "actual successor output has exactly one QEMU console"
    '("console=ttyAMA0")
    (filter (lambda (token) (string-prefix? "console=" token))
            (string-tokenize (list-ref validated 4)))))

(test-equal "legacy PineNote line retains its one-time conversion"
  (string-append "quiet root=PNGuixRoot console=ttyAMA0 " system-arguments)
  (read-fixed-append
   (write-config
    "legacy.conf"
    (string-append
     "quiet root=PNGuixRoot console=tty0 console=ttyS2,1500000n8 "
     system-arguments))))

(for-each
 (lambda (case)
   (test-assert
       (car case)
     (rejected?
      (lambda ()
        (read-fixed-append
         (write-config (string-append "reject-" (number->string (cadr case)) ".conf")
                       (cadr (cdr case))))))))
 `(("duplicate roots reject"
    . (1 ,(string-append
           "root=LABEL=PNGuixRoot root=PNGuixRoot console=ttyAMA0 "
           system-arguments)))
   ("duplicate QEMU consoles reject"
    . (2 ,(string-append
           "root=LABEL=PNGuixRoot console=ttyAMA0 console=ttyAMA0 "
           system-arguments)))
   ("mixed QEMU and hardware consoles reject"
    . (3 ,(string-append
           "root=LABEL=PNGuixRoot console=ttyAMA0 console=ttyS2,1500000n8 "
           system-arguments)))
   ("prepared line with a secondary console rejects"
    . (4 ,(string-append
           "root=LABEL=PNGuixRoot console=ttyAMA0 console=tty0 "
           system-arguments)))
   ("legacy line with an unknown console rejects"
    . (5 ,(string-append
           "root=PNGuixRoot console=ttyS2,1500000n8 console=ttyS0 "
           system-arguments)))
   ("unsupported root spelling rejects"
    . (6 ,(string-append
           "root=/dev/vda1 console=ttyAMA0 " system-arguments)))))

(test-end "production boot-bundle APPEND")

(for-each
 (lambda (name)
   (let ((path (string-append work "/" name)))
     (chmod path #o600)
     (delete-file path)))
 (scandir work (lambda (name) (not (member name '("." "..") string=?)))))
(rmdir work)
