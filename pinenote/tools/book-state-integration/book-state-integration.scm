;;; Trusted join from one fixed BookInstance to the durable Book State backend.
(define-module (book-state-integration)
  #:use-module (book-session)
  #:use-module (book-state)
  #:use-module (book-state-backend-adapter)
  #:use-module (book-state-protocol)
  #:use-module (book-state-session-delegate)
  #:use-module (srfi srfi-9)
  #:export (open-native-book-state-runtime
            native-book-state-runtime?
            native-book-state-runtime-phase
            close-native-book-state-runtime!
            open-native-book-instance-host!
            native-book-instance-host?
            native-book-instance-session-host))

(define (integration-error kind message . details)
  (apply throw 'book-state-integration-error kind message details))

(define-record-type <native-book-state-runtime>
  (%make-native-book-state-runtime store phase)
  native-book-state-runtime?
  (store runtime-store)
  (phase native-book-state-runtime-phase set-runtime-phase!))

(define-record-type <native-book-instance-host>
  (%make-native-book-instance-host runtime session-host)
  native-book-instance-host?
  (runtime instance-runtime)
  (session-host native-book-instance-session-host))

(define (require-runtime-open runtime)
  (unless (native-book-state-runtime? runtime)
    (integration-error 'runtime "typed native Book State runtime required"))
  (unless (eq? (native-book-state-runtime-phase runtime) 'open)
    (integration-error 'closed "native Book State runtime is closed"))
  (let ((store (runtime-store runtime)))
    (unless (eq? (book-state-store-phase store) 'open)
      (integration-error 'store "Book State store is not open"))
    store))

(define (open-native-book-state-runtime root)
  "Open the accepted durable backend at trusted absolute ROOT."
  (%make-native-book-state-runtime (open-book-state-store root) 'open))

(define (backend-rejection! context result)
  (if (book-state-rejection? result)
      (integration-error
       'backend-rejection context (book-state-rejection-code result)
       (book-state-rejection-current-state-version result))
      result))

(define (make-fixed-instance-factory store namespace access)
  ;; STORE, NAMESPACE, and ACCESS are captured only by this trusted closure.
  ;; OPEN-BINDING receives solely Book Session's fresh opaque owner object.
  (define (open-binding owner)
    (let ((grant
           (backend-rejection!
            "could not issue endpoint grant"
            (issue-book-state-grant! store namespace owner access))))
      (make-state-endpoint-binding
       owner grant (book-state-grant-handle grant)
       (book-state-grant-generation grant) (book-state-grant-access grant))))
  (define (run-operation operation)
    (run-state-backend-operation store operation))
  (define (revoke-binding binding)
    (revoke-state-backend-binding! store binding))
  (make-book-state-delegate-factory
   open-binding run-operation revoke-binding))

(define* (open-native-book-instance-host!
          runtime book-revision instance-id #:optional (access 'read-write))
  "Create one state-enabled Book Session host for a trusted BookInstance.

BOOK-REVISION, INSTANCE-ID, and ACCESS are trusted caller inputs captured before
any endpoint or book message exists.  The returned host issues a fresh owner and
grant for every endpoint while retaining the same durable namespace."
  (unless (memq access '(read-only read-write))
    (integration-error 'access "access must be read-only or read-write"))
  (let* ((store (require-runtime-open runtime))
         (namespace
          (backend-rejection!
           "could not open trusted BookInstance"
           (open-book-instance! store book-revision instance-id)))
         (factory (make-fixed-instance-factory store namespace access)))
    (%make-native-book-instance-host
     runtime (make-book-session-host-with-state factory))))

(define (close-native-book-state-runtime! runtime)
  "Close the accepted store after callers have released all session endpoints."
  (unless (native-book-state-runtime? runtime)
    (integration-error 'runtime "typed native Book State runtime required"))
  (case (native-book-state-runtime-phase runtime)
    ((closed) 'already-closed)
    ((open)
     (set-runtime-phase! runtime 'closing)
     (close-book-state-store! (runtime-store runtime))
     (set-runtime-phase! runtime 'closed)
     'closed)
    (else
     (integration-error 'state "native Book State runtime is closing"))))
