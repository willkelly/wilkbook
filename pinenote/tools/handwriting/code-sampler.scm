;;; Code/edit profile for make-sampler.scm. Prompts are intended text, not truth.
;;; Loaded by the generator after its SVG and output helpers are defined.

;; Each task has language, action, instruction, initial lines and final lines.
;; #f final lines means an ordinary copy task. Every block has four lines.
(define code-tasks
  '(("Python" "copy" "Copy literally: preserve case, punctuation and spaces."
     ("read_count = 12"
      "next_page = read_count + 1"
      "label = \"chapter_03\""
      "print(label, next_page)") #f)
    ("Python" "copy" "Start at the left guide; indent the body by four columns."
     ("def total_cost(prices):"
      "    subtotal = sum(prices)"
      "    tax = subtotal * 0.075"
      "    return round(subtotal + tax, 2)") #f)
    ("Guile Scheme" "copy" "Copy literally: hyphens, #t and ~ escapes are part of the code."
     ("(define read-count 12)"
      "(define next-page (+ read-count 1))"
      "(define label \"chapter_03\")"
      "(format #t \"~a: ~a~%\" label next-page)") #f)
    ("Guile Scheme" "copy" "Preserve indentation and every opening/closing parenthesis."
     ("(define (total-cost prices)"
      "  (let* ((subtotal (apply + prices))"
      "         (tax (* subtotal 0.075)))"
      "    (+ subtotal tax)))") #f)
    ("Python" "erase-digit" "Copy first. Then erase only the 8 in 1800 and write 5."
     ("timeout_ms = 1800"
      "ready = timeout_ms <= 2000"
      "status = \"ready\" if ready else \"wait\""
      "print(status, timeout_ms)")
     ("timeout_ms = 1500"
      "ready = timeout_ms <= 2000"
      "status = \"ready\" if ready else \"wait\""
      "print(status, timeout_ms)"))
    ("Python" "erase-word" "Copy first. Erase Rover inside the quotes; write River there."
     ("book_title = \"Rover\""
      "page_no = 42"
      "notes = {\"title\": book_title}"
      "print(notes[\"title\"], page_no)")
     ("book_title = \"River\""
      "page_no = 42"
      "notes = {\"title\": book_title}"
      "print(notes[\"title\"], page_no)"))
    ("Guile Scheme" "erase-operator" "Copy first. Erase >= in the second line and replace it with <=."
     ("(define delay-ms 1500)"
      "(define ok? (>= delay-ms 2000))"
      "(define status (if ok? 'ready 'wait))"
      "(write status)")
     ("(define delay-ms 1500)"
      "(define ok? (<= delay-ms 2000))"
      "(define status (if ok? 'ready 'wait))"
      "(write status)"))
    ("Guile Scheme" "erase-word" "Copy first. Erase Rover inside the quotes; write River there."
     ("(define title \"Rover\")"
      "(define page-no 42)"
      "(define notes `((title . ,title)))"
      "(write (assoc-ref notes 'title))")
     ("(define title \"River\")"
      "(define page-no 42)"
      "(define notes `((title . ,title)))"
      "(write (assoc-ref notes 'title))"))
    ("Python" "copy" "Later session: preserve indentation, braces and the f-string."
     ("items = [\"ink\", \"paper\", \"pen\"]"
      "for index, item in enumerate(items):"
      "    tag = f\"{index:02d}:{item}\""
      "    print(tag)") #f)
    ("Python" "erase-letter" "Later session: copy first; change couut to count by erasing one u."
     ("line_couut = 3"
      "enabled = True"
      "if enabled and line_count != 0:"
      "    print(\"saved\\n\")")
     ("line_count = 3"
      "enabled = True"
      "if enabled and line_count != 0:"
      "    print(\"saved\\n\")"))
    ("Guile Scheme" "copy" "Later session: preserve quotes and list structure."
     ("(use-modules (srfi srfi-1))"
      "(define items '(ink paper pen))"
      "(define selected (take items 2))"
      "(for-each write selected)") #f)
    ("Guile Scheme" "erase-boolean" "Later session: copy first; erase t in line 2's #t and write f."
     ("(define path \"/data/notes\")"
      "(define open? #t)"
      "(set! open? #t)"
      "(format #t \"~a: ~s~%\" path open?)")
     ("(define path \"/data/notes\")"
      "(define open? #f)"
      "(set! open? #t)"
      "(format #t \"~a: ~s~%\" path open?)"))))

(define (code-initial task) (list-ref task 3))
(define (code-final task) (or (list-ref task 4) (code-initial task)))
(for-each
 (lambda (task)
   (for-each (lambda (lines)
               (unless (and (= (length lines) 4)
                            (every (lambda (line) (<= (string-length line) 38)) lines))
                 (error "code block does not fit four writing lines" task)))
             (list (code-initial task) (code-final task))))
 code-tasks)
(define (code-lines page)
  (append-map code-initial (take (drop code-tasks (* page 2)) 2)))
(define (code-writing-y block) (+ 480 (* block 760)))

(define (code-art page)
  `(svg (@ (xmlns "http://www.w3.org/2000/svg")
           (width "1404") (height "1872") (viewBox "0 0 1404 1872"))
     (rect (@ (width "1404") (height "1872") (fill "white")))
     (g (@ (font-family "DejaVu Sans") (fill "#222"))
        ,(text 88 94 40 "Handwriting: code and erasing")
        ,(text 88 144 24 "Write four lines below each block. Keep indentation; do not simplify the code.")
        ,(text 88 182 24 (if (< page 4)
                             "Pages 1–4: adaptation collection. Leave pages 5–6 for a later session."
                             "Pages 5–6: later-session check. Keep these samples out of training."))
        ,@(append-map
           (lambda (block task)
             (let* ((top (+ 240 (* block 760))) (y (code-writing-y block))
                    (number (+ 1 (* page 2) block)))
               (append
                (list (text 88 top 26 (format #f "~2,'0d / ~a / ~a" number (car task) (cadr task)))
                      (text 88 (+ top 38) 22 (caddr task))
                      `(g (@ (font-family "DejaVu Sans Mono") (font-size "27")
                             (xml:space "preserve") (style "white-space:pre"))
                          ,@(map (lambda (row line) (text 88 (+ top 88 (* row 36)) 27 line))
                                 (iota 4) (code-initial task))))
                (map (lambda (column)
                       `(line (@ (x1 ,(+ 88 (* column 32))) (x2 ,(+ 88 (* column 32)))
                                 (y1 ,y) (y2 ,(+ y 288)) (stroke "#ddd")
                                 (stroke-width "1") (stroke-dasharray "4 8"))))
                     '(0 2 4 6 8 9))
                (map (lambda (row)
                       `(line (@ (x1 "88") (x2 "1316")
                                 (y1 ,(+ y 60 (* row 72))) (y2 ,(+ y 60 (* row 72)))
                                 (stroke "#aaa") (stroke-width "1")))) (iota 4))
                (list (text 88 (+ y 326) 20
                            "Write above each rule. Left guide = column 0; other guides = 2, 4, 6, 8, 9.")))))
           (iota 2) (take (drop code-tasks (* page 2)) 2))
        ,(text 88 1740 22 "Use the real area eraser for edit tasks, not undo. Keep the surrounding ink.")
        ,(text 88 1780 22 "After editing: Refresh, close/reopen, and check that erased marks stay erased.")
        ,(text 88 1820 22 "Report leftover ink, missing neighbours or a changed result after reopening.")
        ,(text 1200 1860 20 (format #f "~a / 6" (1+ page))))))

(define (write-code-manifest out)
  (mkdir (string-append out "/prompts"))
  (mkdir (string-append out "/line-prompts"))
  (call-with-output-file (string-append out "/regions.tsv")
    (lambda (p)
      (display "sample\tpage\tx\ty\tw\th\tlanguage\taction\tsplit\n" p)
      (for-each
       (lambda (n task)
         (format p "~2,'0d\t~a\t0\t~a\t1404\t288\t~a\t~a\t~a\n"
                 (1+ n) (quotient n 2) (code-writing-y (modulo n 2))
                 (car task) (cadr task) (if (< n 8) "adaptation" "later-session-check")))
       (iota 12) code-tasks)))
  (call-with-output-file (string-append out "/line-regions.tsv")
    (lambda (p)
      (display "sample\tblock\tline\tpage\tx\ty\tw\th\n" p)
      (for-each
       (lambda (n task)
         (let ((block (format #f "~2,'0d" (1+ n))))
           (write-text (string-append out "/prompts/" block ".txt")
                       (string-append (string-join (code-final task) "\n") "\n"))
           (for-each
            (lambda (row line)
              (let ((sample (format #f "~a-~a" block (1+ row))))
                (format p "~a\t~a\t~a\t~a\t0\t~a\t1404\t72\n"
                        sample block (1+ row) (quotient n 2)
                        (+ (code-writing-y (modulo n 2)) (* row 72)))
                (write-text (string-append out "/line-prompts/" sample ".txt")
                            (string-append line "\n"))))
            (iota 4) (code-final task))))
       (iota 12) code-tasks)))
  (call-with-output-file (string-append out "/tasks.scm")
    (lambda (p)
      (write `(code-edit-sampler (version 1) (label-status unverified-intended-final)
                (tasks ,@(map (lambda (n task)
                                `((sample ,(format #f "~2,'0d" (1+ n)))
                                  (language ,(car task)) (action ,(cadr task))
                                  (instruction ,(caddr task))
                                  (initial ,(code-initial task)) (intended-final ,(code-final task))))
                              (iota 12) code-tasks))) p)
      (newline p))))
