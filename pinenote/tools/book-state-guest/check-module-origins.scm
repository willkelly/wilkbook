;;; Assert that every project module came from the finite private module view.
(use-modules (ice-9 match)
             (pinenote systems pinenote-book-state-reader)
             (srfi srfi-1))

(define view (or (getenv "BOOK_STATE_MODULE_VIEW")
                 (error "BOOK_STATE_MODULE_VIEW is absent")))
(unless (and (string-prefix? "/" view)
             (string=? view (canonicalize-path view)))
  (error "module view is not canonical" view))
(define package-view
  (or (getenv "BOOK_STATE_PACKAGE_VIEW")
      (error "BOOK_STATE_PACKAGE_VIEW is absent")))
(unless (and (member view %load-path)
             (every (lambda (path)
                      (or (string=? path view)
                          (string=? path package-view)
                          (string-prefix? "/gnu/store/" path)))
                    %load-path))
  (error "Guile load path contains an ambient source directory" %load-path))

(define (absolute-module-filename module)
  (let ((filename (module-filename module)))
    (and filename
         (if (string-prefix? "/" filename)
             filename
             (search-path %load-path filename)))))

(define project-modules
  '(((pinenote images pinenote-bootloader)
     "pinenote/images/pinenote-bootloader.scm")
    ((pinenote images pinenote-initramfs)
     "pinenote/images/pinenote-initramfs.scm")
    ((pinenote images pinenote-partitions)
     "pinenote/images/pinenote-partitions.scm")
    ((pinenote packages boot) "pinenote/packages/boot.scm")
    ((pinenote packages cross-fixes) "pinenote/packages/cross-fixes.scm")
    ((pinenote packages ebc-test) "pinenote/packages/ebc-test.scm")
    ((pinenote packages firmware) "pinenote/packages/firmware.scm")
    ((pinenote packages gvisor-dependencies)
     "pinenote/packages/gvisor-dependencies.scm")
    ((pinenote packages gvisor-source) "pinenote/packages/gvisor-source.scm")
    ((pinenote packages gvisor) "pinenote/packages/gvisor.scm")
    ((pinenote packages kernel) "pinenote/packages/kernel.scm")
    ((pinenote packages system-tools) "pinenote/packages/system-tools.scm")
    ((pinenote services diagnostics) "pinenote/services/diagnostics.scm")
    ((pinenote services ebc) "pinenote/services/ebc.scm")
    ((pinenote services state) "pinenote/services/state.scm")
    ((pinenote systems base) "pinenote/systems/base.scm")
    ((pinenote systems pinenote-book-execution-spike)
     "pinenote/systems/pinenote-book-execution-spike.scm")
    ((pinenote systems pinenote-book-state-reader)
     "pinenote/systems/pinenote-book-state-reader.scm")
    ((pinenote timezone) "pinenote/timezone.scm")))

(for-each
 (match-lambda
   ((name relative)
    (resolve-interface name)
    (let* ((module (resolve-module name))
           (actual (absolute-module-filename module))
           (expected (string-append view "/" relative)))
      (unless (and actual (string=? actual expected))
        (error "project module did not originate in private view"
               name actual expected))
      (format #t "MODULE-ORIGIN ~a=~a~%" name actual))))
 project-modules)

(format #t "PASS: all project module origins are the exact private positive view~%")
