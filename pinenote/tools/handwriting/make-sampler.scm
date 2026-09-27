;;; Generate the EPUB and its matching writable notebook from the same artwork.
;;; guile --no-auto-compile -s make-sampler.scm NEW-OUTPUT-DIRECTORY [code-edits]
;;; Host dependencies: Guile, librsvg (rsvg-convert), ImageMagick, zip,
;;; DejaVu Sans (font-dejavu). No device access.
(use-modules (ice-9 format) (ice-9 binary-ports) (rnrs bytevectors)
             (srfi srfi-1) (srfi srfi-13) (sxml simple))

(define prompts
  '("The morning light fell across the page."
    "I left my blue notebook by the window."
    "A quiet room makes it easier to think."
    "Please bring tea and a slice of lemon."
    "Find my notes about suspend."
    "Show the books I opened last week."
    "Try the simpler explanation first."
    "Keep this idea for the next chapter."
    "Chapter 3, page 42: a useful example."
    "Meet at 10:30 on Friday, June 12."
    "The total is $24.75, including tax."
    "Version 2.0 took 15 minutes to install."
    "Why did the small boat turn back?"
    "Don't forget: save, close, then sleep."
    "She said, \"That looks much better!\""
    "One idea (perhaps two) is enough."
    "Pack my box with five dozen jugs."
    "Quick foxes jump over the lazy dog."
    "Write naturally, at your usual speed."
    "Tomorrow I will read another chapter."))

(define (write-text path text)
  (call-with-output-file path (lambda (p) (display text p))))
(define (write-xml path tree)
  (call-with-output-file path
    (lambda (p)
      (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" p)
      (sxml->xml tree p))))
(define (run . args)
  (unless (zero? (apply system* args)) (error "command failed" args)))
(define (read-bytes path)
  (call-with-input-file path get-bytevector-all #:binary #t))
(define (text x y size value)
  `(text (@ (x ,x) (y ,y) (font-size ,size)) ,value))

(unless (or (= (length (command-line)) 2)
            (and (= (length (command-line)) 3) (string=? (caddr (command-line)) "code-edits")))
  (error "usage: make-sampler.scm NEW-OUTPUT-DIRECTORY [code-edits]"))
(define code? (= (length (command-line)) 3))
(when code?
  (load (string-append (dirname (canonicalize-path (car (command-line)))) "/code-sampler.scm")))
(define pages (if code? 6 5))
(define title (if code? "Handwriting — code and erasing" "Handwriting sampler"))
(define out (cadr (command-line)))
;; mkdir deliberately refuses an existing output: never replace filled journals.
(mkdir out)
(set! out (canonicalize-path out))
(define now (car (gettimeofday)))
(define nonce
  (call-with-input-file "/dev/urandom"
    (lambda (p)
      (let ((b (get-bytevector-n p 3)))
        (+ (* 65536 (bytevector-u8-ref b 0))
           (* 256 (bytevector-u8-ref b 1)) (bytevector-u8-ref b 2))))
    #:binary #t))
(define id (format #f "~a-~6,'0x" (strftime "%Y%m%dT%H%M%SZ" (gmtime now)) nonce))
(define epub (string-append out "/epub"))
(define nb (string-append out "/notebooks/" id))
(for-each mkdir (list (string-append out "/notebooks") nb epub
                      (string-append epub "/META-INF")
                      (string-append epub "/OEBPS")
                      (string-append out "/transcriptions")))
(define (ep name) (string-append epub "/OEBPS/" name))
(define (page-name n ext) (format #f "page-~a.~a" n ext))

(do ((page 0 (1+ page))) ((= page pages))
  (let* ((lines (if code? (code-lines page) (take (drop prompts (* page 4)) 4)))
         (art
          (if code? (code-art page)
          `(svg (@ (xmlns "http://www.w3.org/2000/svg")
                   (width "1404") (height "1872") (viewBox "0 0 1404 1872"))
             (rect (@ (width "1404") (height "1872") (fill "white")))
             (g (@ (font-family "DejaVu Sans") (fill "#222"))
                ,(text 88 94 42 "Handwriting sampler")
                ,(text 88 146 25 "Copy each prompt on the line below. Write in your normal hand.")
                ,(text 88 186 25 "Keep within its writing area; lift the pen between lines.")
                ,@(append-map
                   (lambda (row prompt)
                     (let ((y (+ 300 (* row 360))) (number (+ 1 (* page 4) row)))
                       (list
                        (text 88 y 24 (format #f "~2,'0d / COPY" number))
                        (text 88 (+ y 55) 38 prompt)
                        `(line (@ (x1 "88") (x2 "1316")
                                  (y1 ,(+ y 255)) (y2 ,(+ y 255))
                                  (stroke "#aaa") (stroke-width "2")))
                        (text 88 (+ y 295) 21 "Write above the rule. Leave the printed prompt intact."))))
                   (iota 4) lines)
                ,(text 88 1806 23 "Use Ball or Fine. Close the notebook when finished to save it.")
                ,(text 1160 1806 23 (format #f "~a / 5" (1+ page))))))))
    (write-xml (ep (page-name page "svg")) art)
    (run "rsvg-convert" "-o" (ep (page-name page "png")) (ep (page-name page "svg")))
    ;; Logical portrait (BB rotation 3): px = ly; py = 1403 - lx.
    (let ((raw (string-append nb "/paper.raw")))
      (run "convert" (ep (page-name page "png")) "-rotate" "-90"
           "-colorspace" "Gray" "-depth" "8" (string-append "gray:" raw))
      (let ((bytes (read-bytes raw)))
        (unless (= (bytevector-length bytes) (* 1872 1404))
          (error "unexpected raster dimensions"))
        (call-with-output-file (string-append nb "/background-" (number->string page) ".pgm")
          (lambda (p)
            (put-bytevector p (string->utf8 "P5\n1872 1404\n255\n"))
            (put-bytevector p bytes)) #:binary #t))
      (delete-file raw))
    (write-xml (ep (page-name page "xhtml"))
      `(html (@ (xmlns "http://www.w3.org/1999/xhtml") (lang "en") (xml:lang "en"))
         (head (title ,(format #f "~a ~a" title (1+ page)))
               (meta (@ (name "viewport") (content "width=1404,height=1872")))
               (style "html,body{margin:0;padding:0;} img{display:block;width:100%;height:auto;max-height:100vh;}"))
         (body (img (@ (src ,(page-name page "png"))
                       (alt ,(string-join lines " / ")))))))))

(write-text (string-append nb "/backgrounds.conf")
            (string-append "wilkbook-backgrounds-v1 1872 1404\n"
                           (string-join (map number->string (iota pages)) "\n") "\n"))
(write-text (string-append nb "/notebook.json")
  (format #f "{\"format\":\"wilkbook-notebook\",\"v\":1,\"id\":\"~a\",\"created\":~a,\"abs\":[20966,15725,4095],\"panel\":[1872,1404,227]}\n" id now))
(if code? (write-code-manifest out)
(call-with-output-file (string-append out "/regions.tsv")
  (lambda (p)
    (display "sample\tpage\tx\ty\tw\th\tprompt\n" p)
    (for-each
     (lambda (n prompt)
       (format p "~2,'0d\t~a\t88\t~a\t1228\t180\t~a\n"
               (1+ n) (quotient n 4) (+ 390 (* (modulo n 4) 360)) prompt)
       (write-text (format #f "~a/transcriptions/~2,'0d.txt" out (1+ n))
                   (string-append prompt "\n")))
     (iota 20) prompts))))

(write-text (string-append epub "/mimetype") "application/epub+zip")
(write-xml (string-append epub "/META-INF/container.xml")
  '(container (@ (xmlns "urn:oasis:names:tc:opendocument:xmlns:container") (version "1.0"))
     (rootfiles (rootfile (@ (full-path "OEBPS/package.opf")
                             (media-type "application/oebps-package+xml"))))))
(write-xml (ep "nav.xhtml")
  `(html (@ (xmlns "http://www.w3.org/1999/xhtml")
            (xmlns:epub "http://www.idpf.org/2007/ops") (lang "en") (xml:lang "en"))
     (head (title ,title))
     (body (nav (@ (epub:type "toc") (id "toc"))
             (h1 ,title)
             (ol ,@(map (lambda (n)
                          `(li (a (@ (href ,(page-name n "xhtml")))
                                  ,(if code? (format #f "Code blocks ~a–~a" (+ 1 (* n 2)) (+ 2 (* n 2)))
                                       (format #f "Prompts ~a–~a" (+ 1 (* n 4)) (+ 4 (* n 4)))))))
                        (iota pages)))))))
(write-xml (ep "package.opf")
  `(package (@ (xmlns "http://www.idpf.org/2007/opf") (version "3.0")
               (unique-identifier "book-id")
               (prefix "rendition: http://www.idpf.org/vocab/rendition/#"))
     (metadata (@ (xmlns:dc "http://purl.org/dc/elements/1.1/"))
       (dc:identifier (@ (id "book-id")) ,(if code? "urn:wilkbook:handwriting-sampler:code-edits:1"
                                            "urn:wilkbook:handwriting-sampler:1"))
       (dc:title ,(if code? title "Handwriting sampler — copy and write"))
       (dc:language "en") (dc:creator "wilkbook")
       (meta (@ (property "dcterms:modified")) ,(if code? "2026-09-27T00:00:00Z" "2026-09-26T00:00:00Z"))
       (meta (@ (property "rendition:layout")) "pre-paginated")
       (meta (@ (property "rendition:orientation")) "portrait")
       (meta (@ (property "rendition:spread")) "none"))
     (manifest
       (item (@ (id "nav") (href "nav.xhtml") (media-type "application/xhtml+xml") (properties "nav")))
       ,@(append-map
          (lambda (n)
            `((item (@ (id ,(format #f "p~a" n)) (href ,(page-name n "xhtml"))
                       (media-type "application/xhtml+xml")))
              (item (@ (id ,(format #f "i~a" n)) (href ,(page-name n "png"))
                       (media-type "image/png"))))) (iota pages)))
     (spine ,@(map (lambda (n) `(itemref (@ (idref ,(format #f "p~a" n))))) (iota pages)))))

;; The uncompressed mimetype is the first ZIP member, without extra fields.
(let ((cwd (getcwd)))
  (dynamic-wind
    (lambda () (chdir epub))
    (lambda ()
      (run "zip" "-X0q" "../handwriting-sampler.epub" "mimetype")
      (apply run "zip" "-X9q" "../handwriting-sampler.epub"
             (append '("META-INF/container.xml" "OEBPS/package.opf" "OEBPS/nav.xhtml")
                     (append-map (lambda (n)
                                   (list (string-append "OEBPS/" (page-name n "xhtml"))
                                         (string-append "OEBPS/" (page-name n "png")))) (iota pages)))))
    (lambda () (chdir cwd))))
(write-text (string-append out "/README.txt")
  (if code?
      (format #f "Code/edit sampler: 6 pages, 12 four-line blocks (48 lines).\n\nEPUB: handwriting-sampler.epub\nWritable notebook: notebooks/~a\nRequires the existing notebook background-template implementation.\nWith Notebook closed, copy the whole new notebook directory into /data/notebooks/,\nrefusing an existing destination; sync, then Tools > Notebook > Open.\nWrite pages 1-4 now. Reserve pages 5-6 for a later writing session and keep them\nout of training and parameter selection. A six-page supplement is not a promise\nof sufficient adaptation data. Record the actual session boundaries.\n\nCopy each four-line block into the ruled area below it. Preserve case, spelling,\nparentheses, quotes, indentation and literal escapes. Use Ball or Fine.\nFor erasure tasks, copy the INITIAL code, then perform the specified area erase\nand replacement in your handwriting. Do not erase the printed prompt or use undo\ninstead. Refresh and close/reopen after editing; report stale ink, damaged\nneighbours, lost replacements or replay differences.\n\nregions.tsv gives 12 BLOCK boxes; line-regions.tsv gives 48 individual-line boxes,\nall in upright portrait coordinates (rotation mode 1). Keep the common left origin\nwhen rendering code: cropping every line to its ink loses indentation.\nprompts/ and line-prompts/ contain INTENDED FINAL text, not verified labels.\ntasks.scm records initial/final prompts and edit instructions. Inspect final ink\nand put reviewed literal block transcriptions into the initially empty\ntranscriptions/ directory. Preserve leading spaces and newlines.\n\nRecognition must use final ink-only journal replay, with no printed template,\nreference prompt or erased history visible. Whole-stroke erase/undo can replay\ninto trajectories. The existing exporter refuses a line touched by an area\neraser; recognize its final raster instead. Do not silently drop erased samples.\nCurrent prose runners are not qualified for multiline code or indentation.\nUse exact code text/line/block metrics; syntax validity is only a diagnostic.\nNever execute recognized code as an evaluation check.\n" id)
      (format #f "Handwriting sampler: 5 pages, 20 lines.\n\nEPUB: handwriting-sampler.epub\nWritable notebook: notebooks/~a\nRequires the notebook background-template implementation.\nCopy the entire notebook directory into /data/notebooks/ while Notebook is closed;\nrefuse any existing destination, sync, then Tools > Notebook > Open.\nOpen the newest notebook (its name is the creation timestamp). Start at page 0.\nHold the tablet so the printed prompts are upright; keep this orientation.\nWrite above each rule, normally, in Ball or Fine. Lift between lines.\nClose Notebook when finished, then preserve a complete host-side snapshot.\n\nregions.tsv locates each writing area in upright portrait pixels (rotation mode 1).\nTranscription files are PROMPTS, not verified truth. Correct them to match what\nyou actually wrote before exporting each region, including mistakes.\nFor sample 01: export-line.lua ROOT ~a 0 transcriptions/01.txt 88 390 1228 180\nSee pinenote/tools/handwriting/README.md for the full export command.\n" id id)))
(let ((cwd (getcwd)))
  (dynamic-wind
    (lambda () (chdir out))
    (lambda ()
      (apply run "zip" "-X9qr" "handwriting-sampler-kit.zip" "handwriting-sampler.epub"
             "README.txt" "regions.tsv" "transcriptions" "notebooks"
             (if code? '("line-regions.tsv" "prompts" "line-prompts" "tasks.scm") '())))
    (lambda () (chdir cwd))))
(format #t "EPUB: ~a/handwriting-sampler.epub\nNotebook: ~a\nKit: ~a/handwriting-sampler-kit.zip\n" out nb out)
