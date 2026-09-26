(define-module (pinenote systems pinenote-book-workbench)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (pinenote packages gvisor)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote services book-workbench)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:export (pinenote-book-workbench-operating-system
            pinenote-book-workbench-editor-operating-system))

;; QEMU ONLY: noninteractive exercise and automatic shutdown, never a reader
;; flavor to deploy. Reuse the USER_NS kernel and cgroup2 graph, replacing the
;; old smoke service and its stale manifest rather than inheriting its claims.
(define %base pinenote-book-execution-spike-operating-system)
(define (service-name item) (service-type-name (service-kind item)))
(define %services (operating-system-user-services %base))
(for-each
 (lambda (name)
   (unless (= 1 (count (lambda (item) (eq? (service-name item) name)) %services))
     (error "execution-spike service graph changed" name)))
 '(book-execution-guest-smoke book-execution-language-profile))
(unless (= 1 (count (lambda (item) (eq? item gvisor-bin))
                   (operating-system-packages %base)))
  (error "execution-spike runtime package graph changed"))

(define pinenote-book-workbench-operating-system
  (operating-system
   (inherit %base)
   (host-name "pinenote-book-workbench-qemu")
   (packages
    (map (lambda (item) (if (eq? item gvisor-bin) gvisor/source item))
         (operating-system-packages %base)))
   (file-systems
    (cons (file-system
           (mount-point "/var/lib/wilkbook-book-workbench")
           (device (file-system-label "WBWorkbenchV1"))
           (type "ext4")
           (flags '(no-atime no-dev no-suid no-exec))
           (mount-may-fail? #f)
           (check? #t))
          (operating-system-file-systems %base)))
   (services
    (cons (service book-workbench-service-type)
          (remove (lambda (item)
                    (memq (service-name item)
                          '(book-execution-guest-smoke
                            book-execution-language-profile)))
                  %services)))))

(define pinenote-book-workbench-editor-operating-system
  (operating-system
    (inherit pinenote-book-workbench-operating-system)
    (services
     (modify-services (operating-system-user-services pinenote-book-workbench-operating-system)
       (book-workbench-service-type config =>
          (acons 'scenario 'editor (remove (lambda (entry) (eq? (car entry) 'scenario)) config)))))))

pinenote-book-workbench-operating-system
