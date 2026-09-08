;;; SQLite-free operation-ID grammar for Book State protocol clients.
(define-module (book-state-operation-id)
  #:export (book-state-wire-max-operation-id-bytes
            book-state-wire-operation-id?))

(define book-state-wire-max-operation-id-bytes 128)

(define (ascii-operation-id-character? character)
  (or (and (char>=? character #\a) (char<=? character #\z))
      (and (char>=? character #\A) (char<=? character #\Z))
      (and (char>=? character #\0) (char<=? character #\9))
      (char=? character #\_)
      (char=? character #\-)))

(define (book-state-wire-operation-id? value)
  (and (string? value)
       (let ((length (string-length value)))
         (and (<= 1 length book-state-wire-max-operation-id-bytes)
              ;; Every accepted character is one ASCII/UTF-8 byte, so the
              ;; character and byte bounds are identical after this check.
              (let loop ((index 0))
                (or (= index length)
                    (and (ascii-operation-id-character?
                          (string-ref value index))
                         (loop (+ index 1)))))))))
