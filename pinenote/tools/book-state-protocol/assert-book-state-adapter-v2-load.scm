;;; Load each bound application module by its exact absolute source path.
(use-modules (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13))

(define arguments (cdr (command-line)))
(unless (= (length arguments) 6)
  (error "expected load root plus five exact module source paths"))

(define expected-load-root (car arguments))
(define sources (cdr arguments))
(define protocol-source (list-ref sources 0))
(define backend-source (list-ref sources 1))
(define adapter-source (list-ref sources 2))
(define operation-id-source (list-ref sources 3))
(define state-protocol-source (list-ref sources 4))

(unless (string=? (car %load-path) expected-load-root)
  (error "explicit source load path is not first" (car %load-path)))
(unless (every (lambda (path) (string-prefix? "/gnu/store/" path))
               %load-compiled-path)
  (error "source-identity process inherited a non-store ccache"
         %load-compiled-path))

;; Dependencies first.  primitive-load names the immutable/hashed source
;; directly; no module-name search or application ccache participates.
(for-each
 (lambda (source)
   (primitive-load source)
   (format #t "BOUND-SOURCE loaded=~a~%" source))
 (list protocol-source operation-id-source state-protocol-source
       backend-source adapter-source))

(define state-interface (resolve-interface '(book-state-protocol)))
(define backend-interface (resolve-interface '(book-state)))
(define adapter-interface (resolve-interface '(book-state-backend-adapter)))
(unless (and (= (module-ref state-interface
                            'book-state-wire-max-operation-id-bytes) 128)
             (= (module-ref backend-interface
                            'book-state-max-operation-id-bytes) 128)
             (= (module-ref state-interface
                            'max-state-operation-id-bytes) 128)
             ((module-ref adapter-interface
                          'book-state-operation-id-contract-aligned?)))
  (error "loaded modules do not expose the accepted operation-ID contract"))

(format #t "BOUND-LOAD-PATH first=~a~%" (car %load-path))
(display "PASS: exact accepted backend/protocol/adapter sources loaded\n")
