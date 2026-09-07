#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Offline finite checker for one frozen guardian-integration evidence packet.
(use-modules (guardian-integration successor-state-guardian)
             (ice-9 ftw)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define expected-checks 24)
(define checks 0)

(define (fail message . arguments)
  (throw 'book-state-qemu-guardian-evidence-error
         (apply format #f message arguments)))

(define (check label value)
  (set! checks (+ checks 1))
  (unless value (fail "check ~a failed: ~a" checks label))
  (format #t "ok ~a - ~a~%" checks label)
  #t)

(define (read-datum path)
  (call-with-input-file path read))

(define (read-text path)
  (call-with-input-file path get-string-all))

(define (count-substring text needle)
  (let loop ((start 0) (count 0))
    (let ((found (string-contains text needle start)))
      (if found
          (loop (+ found (string-length needle)) (+ count 1))
          count))))

(define (canonical-runtime-lines text)
  ;; The retained runtime is a line protocol for this checker: LF only, exactly
  ;; one final LF, no empty records, and no controls other than horizontal tab.
  ;; Keep line bytes otherwise unchanged so the one expected FAIL record can be
  ;; compared without trimming or a permissive regular expression.
  (unless (and (string? text)
               (not (string-null? text))
               (char=? (string-ref text (- (string-length text) 1)) #\newline)
               (every (lambda (character)
                        (let ((number (char->integer character)))
                          (or (char=? character #\newline)
                              (char=? character #\tab)
                              (>= number #x20))))
                      (string->list text)))
    (fail "runtime log is not canonical LF-terminated text"))
  (let* ((parts (string-split text #\newline))
         (last-part (car (last-pair parts)))
         (lines (drop-right parts 1)))
    (unless (and (string-null? last-part)
                 (pair? lines)
                 (every (lambda (line) (not (string-null? line))) lines))
      (fail "runtime log has an empty record or noncanonical final LF"))
    lines))

(define (ascii-alphanumeric? character)
  (or (and (char<=? #\0 character) (char<=? character #\9))
      (and (char<=? #\A character) (char<=? character #\Z))
      (and (char<=? #\a character) (char<=? character #\z))))

(define (randomized-component? value prefix)
  (and (string? value)
       (string-prefix? prefix value)
       (= (string-length value) (+ (string-length prefix) 6))
       (every ascii-alphanumeric?
              (string->list (substring value (string-length prefix))))))

(define (owned-sigkill-run-root? path)
  (and (string? path)
       (let* ((run-name (basename path))
              (run-base (dirname path))
              (work-root (dirname run-base))
              (work-name (basename work-root)))
         (and (string=? (dirname work-root) "/tmp/opencode")
              (string=? (basename run-base) "runs")
              (randomized-component? work-name "book-state-guardian-run.")
              (randomized-component?
               run-name "book-state-guardian.owner-sigkill.")
              (string=?
               path
               (string-append "/tmp/opencode/" work-name "/runs/" run-name))))))

(define (record root scenario suffix)
  (read-datum (string-append root "/records/" scenario "." suffix ".scm")))

(define (evidence root scenario suffix)
  (string-append root "/" scenario "." suffix))

(define (scenario-bundle root scenario)
  (let ((qmp (read-datum (evidence root scenario "qmp-proc.scm")))
        (exec (record root scenario "qemu-exec"))
        (child (record root scenario "qemu-child"))
        (guardian (record root scenario "process-guardian"))
        (run-root (record root scenario "root")))
    `((qmp . ,qmp) (exec . ,exec) (child . ,child)
      (guardian . ,guardian) (run-root . ,run-root))))

(define (root-guardian-identity root-record)
  `((pid . ,(assoc-ref root-record 'root-guardian-pid))
    (start-time . ,(assoc-ref root-record 'root-guardian-start-time))))

(define (transcript-contains? qmp needle)
  (any (lambda (line) (string-contains line needle))
       (assoc-ref qmp 'qmp-transcript)))

(define (event-sequences root scenario)
  (sort
   (filter-map
    (lambda (name)
      (let ((prefix (string-append scenario ".event-")))
        (and (string-prefix? prefix name)
             (assoc-ref (read-datum (string-append root "/records/" name))
                        'sequence))))
    (scandir (string-append root "/records")
             (lambda (name) (not (member name '("." ".."))))))
   <))

(define (regular-bounded? path)
  (let ((info (lstat path)))
    (and (eq? (stat:type info) 'regular)
         (= (stat:uid info) (getuid))
         (member (logand (stat:mode info) #o7777) '(#o600 #o400))
         (<= (stat:size info) (* 1024 1024)))))

(define (run root)
  (let* ((result (read-datum (string-append root "/RESULT.scm")))
         (runtime (read-text (string-append root "/runtime.log")))
         (runtime-lines (canonical-runtime-lines runtime))
         (scenarios '("normal" "owner-term" "owner-sigkill" "post-reap"))
         (bundles (map (lambda (name) (scenario-bundle root name)) scenarios))
         (execs (map (lambda (bundle) (assoc-ref bundle 'exec)) bundles))
         (qmps (map (lambda (bundle) (assoc-ref bundle 'qmp)) bundles))
         (children (map (lambda (bundle) (assoc-ref bundle 'child)) bundles))
         (guardians (map (lambda (bundle) (assoc-ref bundle 'guardian)) bundles))
         (contender-scenarios
          '("normal-lock-contender" "sigkill-lock-contender"))
         (contender-children
          (map (lambda (scenario) (record root scenario "qemu-child"))
               contender-scenarios))
         (contender-guardians
          (map (lambda (scenario) (record root scenario "process-guardian"))
               contender-scenarios))
         (all-root-records
          (append (map (lambda (bundle) (assoc-ref bundle 'run-root)) bundles)
                  (map (lambda (scenario) (record root scenario "root"))
                       contender-scenarios)))
         (root-guardians (map root-guardian-identity all-root-records))
         (sigkill-bundle (list-ref bundles 2))
         (sigkill-root-record (assoc-ref sigkill-bundle 'run-root))
         (sigkill-exec-record (assoc-ref sigkill-bundle 'exec))
         (sigkill-qmp-record (assoc-ref sigkill-bundle 'qmp))
         (sigkill-root-path (assoc-ref sigkill-root-record 'run-root))
         (foreign-root-record
          (read-datum (evidence root "owner-sigkill" "foreign-root.scm")))
         (expected-refusal-line
          (string-append
           "FAIL: root guardian refuses replaced run directory: "
           sigkill-root-path))
         (fail-lines
          (filter (lambda (line) (string-contains line "FAIL:"))
                  runtime-lines))
         (refusal-index
          (list-index (lambda (line) (string=? line expected-refusal-line))
                      runtime-lines))
         (state-inodes (map (lambda (entry) (assoc-ref entry 'state-inode)) execs))
         (state-devices (map (lambda (entry) (assoc-ref entry 'state-device)) execs)))
    (check "runtime status is exactly zero"
           (string=? (read-text (string-append root "/runtime.status")) "0\n"))
    (check "result is the limited 38-check PASS"
           (and (eq? (assoc-ref result 'verdict) 'pass)
                (= (assoc-ref result 'checks) 38)
                (eq? (assoc-ref result 'scope)
                     'paused-host-qemu-fd-lock-guardian-only)
                (eq? (assoc-ref result 'semantic-persistence) 'unproven)))
    (check "runtime contains exactly 38 successful assertions"
           (= (count-substring runtime "\nok ") 37))
    (check "runtime contains the one final PASS line"
           (= (count-substring runtime
                               "PASS: 38/38 finite guardian-integration checks")
              1))
    (check "exact owned-root refusal is the sole complete FAIL record"
           (and (= (count-substring runtime "FAIL:") 1)
                (equal? fail-lines (list expected-refusal-line))))
    (check "owned-root refusal occurs only at the exact SIGKILL cleanup phase"
           (and refusal-index
                (> refusal-index 0)
                (< refusal-index (- (length runtime-lines) 1))
                (string=?
                 (list-ref runtime-lines (- refusal-index 1))
                 "ok 23 - SIGKILL process guardian exits after reaping its QEMU")
                (string=?
                 (list-ref runtime-lines (+ refusal-index 1))
                 "ok 24 - SIGKILL run-root guardian exits after identity refusal")))
    (check "all four QEMU execs retain one state identity"
           (and (every (lambda (value) (= value (car state-inodes))) state-inodes)
                (every (lambda (value) (= value (car state-devices))) state-devices)
                (every (lambda (entry)
                         (= (assoc-ref entry 'state-size) (* 64 1024 1024)))
                       execs)))
    (check "each child-side allowlist is exactly its handoff FD"
           (every (lambda (entry)
                    (and (eq? (assoc-ref entry 'anchor-cloexec) #t)
                         (equal? (assoc-ref entry 'non-cloexec-above-stderr)
                                 (list (assoc-ref entry 'state-fd)))))
                  execs))
    (check "each QMP process identity equals the exec/direct-child identity"
           (every (lambda (qmp exec child)
                    (and (= (assoc-ref qmp 'pid) (assoc-ref exec 'pid))
                         (= (assoc-ref qmp 'pid) (assoc-ref child 'pid))
                         (string=? (assoc-ref qmp 'start-time)
                                   (assoc-ref exec 'start-time))
                         (string=? (assoc-ref qmp 'start-time)
                                   (assoc-ref child 'start-time))))
                  qmps execs children))
    (check "all positive QMP sessions stayed at prelaunch"
           (every (lambda (qmp) (transcript-contains? qmp "\"status\": \"prelaunch\""))
                  qmps))
    (check "all positive QMP sessions expose the state file/raw nodes"
           (every (lambda (qmp)
                    (and (transcript-contains? qmp "\"node-name\": \"book-state-file\"")
                         (transcript-contains? qmp "\"node-name\": \"book-state\"")))
                  qmps))
    (check "all positive QMP sessions expose the exact state virtio device"
           (every (lambda (qmp)
                    (transcript-contains?
                     qmp "/machine/peripheral/book-state-disk/virtio-backend"))
                  qmps))
    (check "all positive vectors select authorized resources, no NIC, and -S"
           (every (lambda (qmp)
                    (let ((argv (assoc-ref qmp 'exact-cmdline)))
                      (and (= (count (lambda (x) (string=? x "-S")) argv) 1)
                           (= (count (lambda (x) (string=? x "-smp")) argv) 1)
                           (= (count (lambda (x) (string=? x "-m")) argv) 1)
                           (let ((smp (member "-smp" argv string=?))
                                 (memory (member "-m" argv string=?)))
                             (and smp (pair? (cdr smp))
                                  (string=? (cadr smp) "2")
                                  memory (pair? (cdr memory))
                                  (string=? (cadr memory) "512")))
                           (member "-nic" argv string=?)
                           (member "none" argv string=?)
                           (not (member "-netdev" argv string=?))
                           (not (member "-fsdev" argv string=?)))))
                  qmps))
    (check "all QMP sockets were private caller-owned Unix sockets"
           (every (lambda (qmp)
                    (let ((socket (assoc-ref qmp 'qmp-socket)))
                      (and (= (assoc-ref socket 'uid) (getuid))
                           (= (assoc-ref socket 'mode) #o700))))
                  qmps))
    (check "normal lock contender retained actual write-lock refusal"
           (string-contains
            (read-text (evidence root "normal-lock-contender" "qemu.stderr.raw"))
            "Failed to get \"write\" lock"))
    (check "post-owner-death handoff contender retained write-lock refusal"
           (let ((text
                  (read-text
                   (evidence root "sigkill-lock-contender" "qemu.stderr.raw"))))
             (and (string-contains text "Failed to get \"write\" lock")
                  (string-contains text "/proc/self/fd/"))))
    (check "normal event order records guardian through root cleanup"
           (equal? (event-sequences root "normal") '(10 20 30 40 50 60 70 80)))
    (check "TERM event order records join and handoff before root cleanup"
           (equal? (event-sequences root "owner-term") '(10 20 30 40 50 80)))
    (check "SIGKILL owner has no forged post-death event"
           (equal? (event-sequences root "owner-sigkill") '(10 20 30)))
    (check "post-reap event order is a fresh complete lifetime"
           (equal? (event-sequences root "post-reap") '(10 20 30 40 50 60 70 80)))
    (check "refusal is bound to the owned root and replacement phase identities"
           (let ((root-device (assoc-ref sigkill-root-record 'run-root-device))
                 (root-inode (assoc-ref sigkill-root-record 'run-root-inode))
                 (replacement-device
                  (assoc-ref foreign-root-record 'replacement-device))
                 (replacement-inode
                  (assoc-ref foreign-root-record 'replacement-inode)))
             (and (owned-sigkill-run-root? sigkill-root-path)
                  (string=? (assoc-ref sigkill-root-record 'scenario)
                            "owner-sigkill")
                  (string=? (assoc-ref sigkill-root-record 'qmp-path)
                            (string-append sigkill-root-path "/qmp.sock"))
                  (string=? (assoc-ref sigkill-exec-record 'run-root)
                            sigkill-root-path)
                  (= (assoc-ref sigkill-exec-record 'run-root-device)
                     root-device)
                  (= (assoc-ref sigkill-exec-record 'run-root-inode)
                     root-inode)
                  (string=?
                   (assoc-ref (assoc-ref sigkill-qmp-record 'qmp-socket) 'path)
                   (string-append sigkill-root-path "/qmp.sock"))
                  (string=? (assoc-ref foreign-root-record 'replacement-path)
                            sigkill-root-path)
                  (= replacement-device root-device)
                  (not (= replacement-inode root-inode))
                  (string=?
                   (assoc-ref foreign-root-record 'held-original-path)
                   (string-append (dirname sigkill-root-path)
                                  "/held-owner-sigkill"))
                  (= (assoc-ref foreign-root-record 'held-original-device)
                     root-device)
                  (= (assoc-ref foreign-root-record 'held-original-inode)
                     root-inode)
                  (string=? (assoc-ref foreign-root-record 'marker)
                            "foreign-root-preserved\n"))))
    (check "all recorded QEMUs and both guardian layers are gone"
           (every (lambda (identity)
                    (not (process-instance-live?
                          (assoc-ref identity 'pid)
                          (assoc-ref identity 'start-time))))
                  (append children guardians contender-children
                          contender-guardians root-guardians)))
    (check "all recorded ephemeral run roots are absent"
           (every (lambda (root-record)
                    (not (false-if-exception
                          (lstat (assoc-ref root-record 'run-root)))))
                  all-root-records))
    (check "all retained raw logs are bounded private regular files"
           (every (lambda (name)
                    (or (string-suffix? ".scm" name)
                        (string=? name "runtime.status")
                        (regular-bounded? (string-append root "/" name))))
                  (scandir root
                           (lambda (name)
                             (not (member name '("." ".." "records")))))))
    (unless (= checks expected-checks)
      (fail "finite evidence count mismatch: ~a" checks))
    (format #t "PASS: ~a/~a offline evidence checks~%" checks expected-checks)
    0))

(unless (= (length (command-line)) 2)
  (format (current-error-port) "usage: ~a EVIDENCE-DIRECTORY~%"
          (car (command-line)))
  (exit 2))
(exit
 (catch #t
   (lambda () (run (canonicalize-path (cadr (command-line)))))
   (lambda (key . arguments)
     (format (current-error-port) "FAIL: ~s ~s~%" key arguments)
     1)))
