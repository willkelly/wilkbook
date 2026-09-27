;;; Resolve the data partition from the kernel, independently of blkid/udev.
(define-module (pinenote lib data-device)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (data-device-candidates resolve-data-device))

(define (read-text path)
  (catch 'system-error
    (lambda () (call-with-input-file path get-string-all))
    (lambda _ #f)))

(define (field text key)
  (and text
       (let ((prefix (string-append key "=")))
         (any (lambda (line)
                     (and (string-prefix? prefix line)
                          (substring line (string-length prefix))))
                   (string-split text #\newline)))))

(define* (data-device-candidates #:optional (sys "/sys/class/block"))
  "Return kernel partition names carrying the exact GPT name data."
  (filter-map
   (lambda (name)
     (let ((event (read-text (string-append sys "/" name "/uevent"))))
       (and (equal? (field event "PARTNAME") "data")
            (equal? (field event "DEVTYPE") "partition")
            (equal? (field event "DEVNAME") name)
            ;; Only a kernel basename may become a /dev path.
            (string-every (lambda (c) (or (char-alphabetic? c)
                                         (char-numeric? c))) name)
            name)))
   (or (scandir sys (lambda (name) (not (string-prefix? "." name)))) '())))

(define* (resolve-data-device #:key (sys "/sys/class/block") (dev "/dev")
                             (attempts 20) (pause sleep)
                             (block? (lambda (path)
                                       (let ((st (false-if-exception (stat path))))
                                         (and st (eq? (stat:type st) 'block-special))))))
  "Wait for one unambiguous data partition and its kernel device node.
Return #f when absent; ambiguity is an error, never first-match-wins."
  (let loop ((left attempts))
    (let ((names (data-device-candidates sys)))
      (cond
       ((> (length names) 1) (error "ambiguous GPT data partitions" names))
       ((and (pair? names) (block? (string-append dev "/" (car names))))
        (string-append dev "/" (car names)))
       ((<= left 1) #f)
       (else (pause 1) (loop (- left 1)))))))
