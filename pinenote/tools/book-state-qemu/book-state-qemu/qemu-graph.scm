;;; Exact descriptor-bound second-disk graph for the Book State test.
(define-module (book-state-qemu qemu-graph)
  #:use-module (book-state-qemu state-volume)
  #:use-module (reader-qemu-graph)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (state-volume-file-node-name
            state-volume-raw-node-name
            state-volume-device-id
            state-volume-device-serial
            leased-state-volume-qemu-arguments
            assert-leased-state-volume-qemu-arguments))

(define state-volume-file-node-name "book-state-file")
(define state-volume-raw-node-name "book-state")
(define state-volume-device-id "book-state-disk")
(define state-volume-device-serial "WBBOOKSTATEV1")
(define accepted-root-device "virtio-blk-pci,drive=rootfs-overlay")

(define (graph-error message . arguments)
  (throw 'book-state-qemu-graph-error (apply format #f message arguments)))

(define (json-whitespace? character)
  (memv character '(#\space #\tab #\newline #\return)))

(define (hex-value character)
  (cond
   ((char-numeric? character) (- (char->integer character) (char->integer #\0)))
   ((char<=? #\a (char-downcase character) #\f)
    (+ 10 (- (char->integer (char-downcase character)) (char->integer #\a))))
   (else #f)))

(define (parse-flat-json-object text)
  ;; QEMU blockdev objects in the accepted graph are flat objects containing
  ;; string and boolean values.  Parse exactly that language, decode all JSON
  ;; string escapes (including \uXXXX), and reject duplicate keys.  This is not
  ;; a general JSON-RPC or dynamic graph parser.
  (unless (string? text) (graph-error "blockdev JSON must be a string"))
  (let ((length (string-length text)))
    (define (skip-space index)
      (let loop ((index index))
        (if (and (< index length) (json-whitespace? (string-ref text index)))
            (loop (+ index 1))
            index)))
    (define (expect index character)
      (let ((index (skip-space index)))
        (unless (and (< index length) (char=? (string-ref text index) character))
          (graph-error "malformed flat blockdev JSON"))
        (+ index 1)))
    (define (unicode-unit index)
      (when (> (+ index 4) length)
        (graph-error "truncated JSON Unicode escape"))
      (let loop ((at index) (remaining 4) (value 0))
        (if (zero? remaining)
            (cons value at)
            (let ((digit (hex-value (string-ref text at))))
              (unless digit (graph-error "invalid JSON Unicode escape"))
              (loop (+ at 1) (- remaining 1) (+ (* value 16) digit))))))
    (define (json-string index)
      (let ((index (skip-space index)))
        (unless (and (< index length) (char=? (string-ref text index) #\"))
          (graph-error "flat blockdev JSON key/value must be a string"))
        (let ((port (open-output-string)))
          (let loop ((at (+ index 1)))
            (when (>= at length) (graph-error "unterminated JSON string"))
            (let ((character (string-ref text at)))
              (cond
               ((char=? character #\")
                (cons (get-output-string port) (+ at 1)))
               ((< (char->integer character) #x20)
                (graph-error "raw control in JSON string"))
               ((char=? character #\\)
                (when (>= (+ at 1) length)
                  (graph-error "truncated JSON escape"))
                (let ((escaped (string-ref text (+ at 1))))
                  (cond
                   ((assv escaped '((#\" . #\") (#\\ . #\\) (#\/ . #\/)
                                    (#\b . #\backspace) (#\f . #\page)
                                    (#\n . #\newline) (#\r . #\return)
                                    (#\t . #\tab)))
                    => (lambda (entry)
                         (write-char (cdr entry) port)
                         (loop (+ at 2))))
                   ((char=? escaped #\u)
                    (let* ((first (unicode-unit (+ at 2)))
                           (unit (car first))
                           (next (cdr first)))
                      (cond
                       ((<= #xd800 unit #xdbff)
                        (unless (and (<= (+ next 6) length)
                                     (char=? (string-ref text next) #\\)
                                     (char=? (string-ref text (+ next 1)) #\u))
                          (graph-error "unpaired high JSON surrogate"))
                        (let* ((second (unicode-unit (+ next 2)))
                               (low (car second)))
                          (unless (<= #xdc00 low #xdfff)
                            (graph-error "invalid low JSON surrogate"))
                          (write-char
                           (integer->char
                            (+ #x10000 (* (- unit #xd800) #x400)
                               (- low #xdc00)))
                           port)
                          (loop (cdr second))))
                       ((<= #xdc00 unit #xdfff)
                        (graph-error "unpaired low JSON surrogate"))
                       (else
                        (write-char (integer->char unit) port)
                        (loop next)))))
                   (else (graph-error "invalid JSON escape")))))
               (else
                (write-char character port)
                (loop (+ at 1)))))))))
    (define (literal index spelling value)
      (let ((end (+ index (string-length spelling))))
        (unless (and (<= end length)
                     (string=? spelling (substring text index end)))
          (graph-error "unsupported flat blockdev JSON value"))
        (cons value end)))
    (define (json-value index)
      (let ((index (skip-space index)))
        (when (>= index length) (graph-error "missing blockdev JSON value"))
        (case (string-ref text index)
          ((#\") (json-string index))
          ((#\t) (literal index "true" #t))
          ((#\f) (literal index "false" #f))
          ((#\n) (literal index "null" 'null))
          (else (graph-error "unsupported flat blockdev JSON value")))))
    (let ((start (expect 0 #\{)))
      (let loop ((index (skip-space start)) (fields '()))
        (if (and (< index length) (char=? (string-ref text index) #\}))
            (let ((end (skip-space (+ index 1))))
              (unless (= end length) (graph-error "trailing blockdev JSON data"))
              (reverse fields))
            (let* ((key+index (json-string index))
                   (key (car key+index))
                   (after-key (expect (cdr key+index) #\:))
                   (value+index (json-value after-key))
                   (value (car value+index))
                   (after-value (skip-space (cdr value+index))))
              (when (assoc key fields)
                (graph-error "duplicate blockdev JSON key: ~a" key))
              (cond
               ((and (< after-value length)
                     (char=? (string-ref text after-value) #\,))
                (let ((next (skip-space (+ after-value 1))))
                  ;; The initial object state may accept `}` for `{}`, but the
                  ;; state after a comma must consume another member.
                  (when (and (< next length)
                             (char=? (string-ref text next) #\}))
                    (graph-error "trailing comma in flat blockdev JSON object"))
                  (loop next (cons (cons key value) fields))))
               ((and (< after-value length)
                     (char=? (string-ref text after-value) #\}))
                (loop after-value (cons (cons key value) fields)))
               (else (graph-error "malformed flat blockdev JSON object")))))))))

(define (option-values option arguments)
  (let loop ((rest arguments) (values '()))
    (cond
     ((null? rest) (reverse values))
     ((null? (cdr rest))
      (when (string=? (car rest) option)
        (graph-error "QEMU option ~a lacks a value" option))
      (reverse values))
     ((string=? (car rest) option)
      (loop (cddr rest) (cons (cadr rest) values)))
     (else (loop (cdr rest) values)))))

(define reserved-node-names
  (list state-volume-file-node-name state-volume-raw-node-name))
(define reserved-device-ids (list state-volume-device-id))

(define (device-properties text)
  (let loop ((parts (string-split text #\,)) (properties '()))
    (if (null? parts)
        (reverse properties)
        (let* ((part (string-trim-both (car parts)))
               (equals (string-index part #\=)))
          (if equals
              (let ((key (string-trim-both (substring part 0 equals)))
                    (value (string-trim-both
                            (substring part (+ equals 1)))))
                (when (assoc key properties)
                  (graph-error "duplicate QEMU device property: ~a" key))
                (loop (cdr parts) (cons (cons key value) properties)))
              (loop (cdr parts) properties))))))

(define (validate-no-state-collisions arguments)
  (let ((node-names '()) (device-ids '()))
    (for-each
     (lambda (json)
       (let* ((fields (parse-flat-json-object json))
              (node (assoc-ref fields "node-name"))
              (file (assoc-ref fields "file")))
         (when (and node (member node node-names))
           (graph-error "duplicate blockdev node-name: ~a" node))
         (when (and node (member node reserved-node-names))
           (graph-error "accepted reader graph uses reserved node-name: ~a" node))
         (when (and file (member file reserved-node-names))
           (graph-error "accepted reader graph refers to reserved node: ~a" file))
         (when node (set! node-names (cons node node-names)))))
     (option-values "-blockdev" arguments))
    (for-each
     (lambda (device)
       (let* ((fields (device-properties device))
              (id (assoc-ref fields "id"))
              (drive (assoc-ref fields "drive"))
              (serial (assoc-ref fields "serial")))
         (when (and id (member id device-ids))
           (graph-error "duplicate QEMU device id: ~a" id))
         (when (and id (member id reserved-device-ids))
           (graph-error "accepted reader graph uses reserved device id: ~a" id))
         (when (and drive (member drive reserved-node-names))
           (graph-error "accepted reader graph uses reserved drive: ~a" drive))
         (when (and serial (string=? serial state-volume-device-serial))
           (graph-error "accepted reader graph uses reserved serial"))
         (when id (set! device-ids (cons id device-ids)))))
     (option-values "-device" arguments)))
  #t)

(define (accepted-reader-base qemu run-root kernel initrd append-line overlay)
  ;; Reconstruct the accepted reader vector independently.  No caller-provided
  ;; base serves as both candidate and oracle.
  (let ((arguments
         (reader-qemu-arguments qemu run-root kernel initrd append-line overlay)))
    (unless (and (list? arguments) (not (null? arguments))
                 (every string? arguments))
      (graph-error "accepted reader constructor returned an invalid vector"))
    (unless (and (string=? (last arguments) accepted-root-device)
                 (= (count (lambda (item)
                             (string=? item accepted-root-device))
                           arguments)
                    1))
      (graph-error "accepted reader graph lacks its one trailing root device"))
    (validate-no-state-collisions arguments)
    arguments))

(define (safe-handoff-file-name? path)
  (let ((prefix "/proc/self/fd/"))
    (and (string? path)
         (string-prefix? prefix path)
         (> (string-length path) (string-length prefix))
         (every char-numeric?
                (string->list (substring path (string-length prefix)))))))

(define (state-volume-device-arguments handoff)
  (let ((file-name (state-volume-qemu-handoff-file-name handoff)))
    (unless (safe-handoff-file-name? file-name)
      (graph-error "state image handoff is not one inherited descriptor"))
    ;; FILE-NAME's grammar is fixed ASCII plus decimal digits, so direct JSON
    ;; serialization is complete; no campaign pathname enters JSON.
    (list
     "-blockdev"
     (string-append
      "{\"driver\":\"file\",\"filename\":\"" file-name
      "\",\"node-name\":\"" state-volume-file-node-name
      "\",\"read-only\":false,\"locking\":\"on\"}")
     "-blockdev"
     (string-append
      "{\"driver\":\"raw\",\"file\":\"" state-volume-file-node-name
      "\",\"node-name\":\"" state-volume-raw-node-name
      "\",\"read-only\":false}")
     "-device"
     (string-append
      "virtio-blk-pci,drive=" state-volume-raw-node-name
      ",id=" state-volume-device-id
      ",serial=" state-volume-device-serial))))

(define (leased-state-volume-qemu-arguments qemu run-root kernel initrd
                                             append-line overlay handoff)
  (append (accepted-reader-base qemu run-root kernel initrd append-line overlay)
          (state-volume-device-arguments handoff)))

(define (assert-leased-state-volume-qemu-arguments arguments qemu run-root
                                                    kernel initrd append-line
                                                    overlay handoff)
  (unless (and (list? arguments) (every string? arguments))
    (graph-error "state QEMU vector must be a list of strings"))
  (let ((expected
         (leased-state-volume-qemu-arguments
          qemu run-root kernel initrd append-line overlay handoff)))
    (unless (equal? arguments expected)
      (graph-error "QEMU vector does not match the exact descriptor-bound graph"))
    #t))
