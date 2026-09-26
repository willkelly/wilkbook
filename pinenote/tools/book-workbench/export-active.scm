;;; Export bytes from the sealed active revision. Authored source is never read
;;; as Scheme or evaluated here; the launcher supplies the committed seed file.
;;; Match native-authority's store-object token: interpreter plus its libraries.
(use-modules (book-workspace) (ice-9 textual-ports) (ice-9 match))

(match (cdr (command-line))
  ((directory seed-file guile)
   (let* ((seed (call-with-input-file seed-file get-string-all))
          (store (open-workspace-store directory seed
                   #:environment (basename (canonicalize-path (dirname (dirname guile))))))
          (artifact
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (workspace-export
                store (assq-ref (workspace-snapshot store) 'active-revision)))
             (lambda () (close-workspace-store! store)))))
     (set-port-encoding! (current-output-port) "UTF-8")
     (display artifact)))
  (_ (error "usage: export-active.scm WORKSPACE-DIRECTORY COMMITTED-SEED-FILE GUILE")))
