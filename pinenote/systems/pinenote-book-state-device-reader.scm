(define-module (pinenote systems pinenote-book-state-device-reader)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module ((gnu system file-systems) #:select (%control-groups))
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (pinenote packages book-state-device)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote packages koreader)
  #:use-module (pinenote services book-state-device)
  #:use-module (pinenote services reader-session)
  #:use-module (pinenote systems pinenote-reader)
  #:use-module (srfi srfi-1)
  #:export (pinenote-book-state-device-reader-operating-system))

(define %base pinenote-reader-operating-system)

(define (replace-koreader packages)
  (unless (= 1 (count (lambda (package) (eq? package koreader-bin)) packages))
    (error "reader KOReader package selection changed"))
  (map (lambda (package)
         (if (eq? package koreader-bin) koreader-book-state-device package))
       packages))

(define (replace-reader-session services)
  (unless (= 1 (count (lambda (item)
                        (eq? (service-kind item)
                             pinenote-reader-session-service-type))
                      services))
    (error "reader-session service selection changed"))
  (map (lambda (item)
         (if (eq? (service-kind item) pinenote-reader-session-service-type)
             (service pinenote-reader-session-service-type
                      koreader-book-state-device)
             item))
       services))

(define %device-build-note
  (mixed-text-file
   "wilkbook-book-state-device-build-note"
   "schema=1\n"
   "flavor=pinenote-book-state-device-reader\n"
   "base=pinenote-reader\n"
   "default-reader=unchanged\n"
   "activation=/data/wilkbook/book-state/enabled\n"
   "state-root=/data/wilkbook/book-state\n"
   "state-database=/data/wilkbook/book-state/book-state-v1.sqlite\n"
   "state-root-mode=0700\n"
   "state-file-mode=0600\n"
   "ui-socket=/run/wilkbook-book-state/control.sock\n"
   "ui=KOReader-InputDialog-human-save-callback\n"
   "book=fixed-guile-persistent-note\n"
   "fixed-runners=guile,python\n"
   "menu-runner=guile\n"
   "book-session-fd=3\n"
   "platform=systrap\n"
   "directfs=false\n"
   "network=none\n"
   "host-uds=none\n"
   "kernel-expected=/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote\n"
   "gvisor-expected=/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0\n"
   "interaction-budget-seconds=300\n"
   "service-stop-grace-seconds=12\n"
   "receipt-and-state-version-limit=64\n"))

(define pinenote-book-state-device-reader-operating-system
  (operating-system
    (inherit %base)
    (host-name "pinenote-book-state-device-reader")
    (kernel linux-pinenote-book-execution-test)
    (packages
     (cons gvisor/source
           (replace-koreader (operating-system-packages %base))))
    ;; gVisor's accepted --ignore-cgroups=false policy needs cgroup2. All
    ;; PineNote /data, display, waveform, suspend and update filesystems remain
    ;; exactly those of the reader base.
    (file-systems
     (append %control-groups (operating-system-file-systems %base)))
    (services
     (append
      (replace-reader-session (operating-system-user-services %base))
      (list
       (service pinenote-book-state-device-ready-service-type)
       (service pinenote-book-state-device-service-type)
       (simple-service
        'pinenote-book-state-device-build-note etc-service-type
        `(("wilkbook-book-state-device" ,%device-build-note))))))))

pinenote-book-state-device-reader-operating-system
