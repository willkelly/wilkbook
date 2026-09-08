;;; Re-verify one bootstrap-authenticated, retained two-boot source closure.
(define-module (two-boot source-gate)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (verify-two-boot-source-root!))

(define sha256-rx (make-regexp "^[0-9a-f]{64}$"))

(define (gate-error message . arguments)
  (throw 'book-state-two-boot-source-error
         (apply format #f message arguments)))

(define (hash? value)
  (and (string? value) (regexp-exec sha256-rx value) #t))

(define (file-hash path)
  (bytevector->base16-string (file-sha256 path)))

(define (safe-relative? path)
  (and (string? path) (not (string-null? path))
       (not (string-prefix? "/" path))
       (not (string-contains path "//"))
       (every (lambda (part) (not (member part '("" "." "..") string=?)))
              (string-split path #\/))
       (not (any (lambda (character) (< (char->integer character) #x20))
                 (string->list path)))))

(define (read-manifest path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((entries '()) (prior #f))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse entries)
              (begin
                (unless (and (>= (string-length line) 67)
                             (char=? (string-ref line 64) #\space)
                             (char=? (string-ref line 65) #\space)
                             (hash? (substring line 0 64))
                             (safe-relative? (substring line 66)))
                  (gate-error "source manifest contains a malformed line"))
                (let ((relative (substring line 66)))
                  (when (and prior (not (string<? prior relative)))
                    (gate-error "source manifest is not uniquely sorted"))
                  (loop (cons (cons relative (substring line 0 64)) entries)
                        relative)))))))))

(define (walk root)
  (let ((files '()) (directories '()))
    (define (visit relative)
      (let* ((path (if (string-null? relative) root
                       (string-append root "/" relative)))
             (info (lstat path)))
        (cond
         ((eq? (stat:type info) 'directory)
          (set! directories (cons relative directories))
          (for-each
           (lambda (name)
             (unless (member name '("." "..") string=?)
               (visit (if (string-null? relative) name
                          (string-append relative "/" name)))))
           (sort (scandir path) string<?)))
         ((eq? (stat:type info) 'regular)
          (set! files (cons relative files)))
         (else (gate-error "source closure contains symlink/special file: ~a"
                           relative)))))
    (visit "")
    (values (sort files string<?) directories)))

(define* (verify-two-boot-source-root! root expected-manifest
                                      #:key (guarded-private? #f))
  (unless (and (string? root) (string-prefix? "/" root)
               (string=? root (canonicalize-path root))
               (eq? (stat:type (lstat root)) 'directory))
    (gate-error "source root must be an absolute canonical real directory"))
  (unless (hash? expected-manifest)
    (gate-error "bootstrap did not retain a canonical source-manifest SHA-256"))
  (let* ((manifest (string-append root "/SOURCE-MANIFEST.sha256"))
         (info (lstat manifest)))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (zero? (logand (stat:mode info) #o222))
                 (string=? (file-hash manifest) expected-manifest))
      (gate-error "source manifest identity/authentication failed"))
    (let ((entries (read-manifest manifest)))
      (call-with-values
          (lambda () (walk root))
        (lambda (files directories)
          (unless (equal? files
                          (sort (cons "SOURCE-MANIFEST.sha256"
                                      (map car entries)) string<?))
            (gate-error "source closure roster has an addition or omission"))
          (for-each
           (lambda (relative)
             (let ((directory (if (string-null? relative) root
                                  (string-append root "/" relative))))
                (unless (and
                         (= (stat:uid (lstat directory)) (getuid))
                         (if guarded-private?
                             (= (logand (stat:mode (lstat directory)) #o7777)
                                #o700)
                             (zero? (logand (stat:mode (lstat directory))
                                            #o222))))
                  (gate-error
                   "source directory is not immutable or exact guarded-private mode: ~a"
                   relative))))
           directories)))
      (for-each
       (lambda (entry)
         (let* ((path (string-append root "/" (car entry)))
                (file-info (lstat path)))
           (unless (and (eq? (stat:type file-info) 'regular)
                        (= (stat:uid file-info) (getuid))
                        (= (stat:nlink file-info) 1)
                        (zero? (logand (stat:mode file-info) #o222))
                        (string=? (file-hash path) (cdr entry)))
             (gate-error "source closure file identity mismatch: ~a"
                         (car entry)))))
       entries)
      #t)))
