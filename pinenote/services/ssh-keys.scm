(define-module (pinenote services ssh-keys)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (pinenote-ssh-authorized-keys-service-type))

;; Root's SSH authorized keys from the persistent `data' partition
;; (doc/networking.md §3: the same out-of-band channel as the Wi-Fi
;; credentials — the design's `/state/ssh/authorized_keys' is
;; `/data/ssh/authorized_keys' in the shipped image, where the data
;; partition is mounted).
;;
;; Why: the image must stay generic.  Baking an operator's public key
;; into the flavor (as pinenote-reader.scm did until 2026-08-06) means
;; every collaborator's build is a device only the author can reach.
;; The key is not a secret, but it is per-operator state, and
;; per-operator state lives on the data partition.
;;
;; Mechanism: a one-shot copies /data/ssh/authorized_keys over
;; /root/.ssh/authorized_keys on every boot.  Guix's generated
;; sshd_config always honors `.ssh/authorized_keys' (AuthorizedKeysFile
;; line in gnu/services/ssh.scm), so no sshd configuration changes.
;; Copying — rather than pointing AuthorizedKeysFile at /data — keeps
;; the grant scoped to root (a shared non-%u path would authorize the
;; same keys for the `reader' user, which has passwordless sudo) and
;; keeps sshd's StrictModes ownership checks on a directory we control.
;; Because the copy runs every boot and /data survives an os2 reflash
;; while /root does not, the key also self-heals after reflashes — the
;; standing follow-up in doc/networking.md §6.
;;
;; The data file is the source of truth: a hand edit of
;; /root/.ssh/authorized_keys is overwritten at the next boot (and
;; would die at the next reflash anyway), and deleting the file on a
;; MOUNTED /data revokes the installed key at the next boot.  When
;; /data is not mounted (virt, transient mount failure) the
;; last-installed key is left alone, so a mount hiccup can never lock
;; SSH out.  Edit /data/ssh/ instead of /root/.ssh.
;;
;; Failure posture, mirroring pinenote-wifi: no data partition or no
;; key file is an EXPECTED state (QEMU virt, fresh device) — log and
;; exit 0; the reader boots, SSH simply has no out-of-band key, and the
;; ACM/UART consoles remain the way in.  A failed copy when the source
;; EXISTS is anomalous and exits nonzero so `herd status' shows the
;; one-shot failed, without blocking boot.
(define %pinenote-ssh-keys-install
  (computed-file
   "pinenote-ssh-keys-install"
   #~(begin
       (call-with-output-file #$output
         (lambda (port)
           (display "\
#!/bin/sh
set -u
export PATH=\"/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}\"

src=/data/ssh/authorized_keys
dst=/root/.ssh/authorized_keys

if [ ! -f \"$src\" ]; then
  # Distinguish revocation from a missing partition: with /data mounted
  # and no key file, the source of truth says root has no key -- remove
  # the installed one.  With /data unmounted (virt, mount failure) we
  # cannot know intent; leave the last-installed key so a transient
  # mount failure never locks SSH out.
  if mountpoint -q /data && [ -f \"$dst\" ]; then
    rm -f \"$dst\"
    echo \"pinenote-ssh-keys: no $src on mounted /data; removed $dst (revocation)\"
  else
    echo \"pinenote-ssh-keys: no $src; skipping (root SSH has no out-of-band key; use the ACM/UART console)\"
  fi
  exit 0
fi

umask 077
mkdir -p /root/.ssh || { echo 'pinenote-ssh-keys: cannot create /root/.ssh' >&2; exit 1; }
chmod 700 /root/.ssh 2>/dev/null || true
# A directory at $dst is broken state (no supported flow creates it);
# clear it so mv installs a file rather than moving into the directory.
[ -d \"$dst\" ] && rm -rf \"$dst\"
tmp=\"$dst.tmp.$$\"
# tr strips CRs so a key file edited on Windows still parses in sshd.
if tr -d '\\r' < \"$src\" > \"$tmp\" && chown 0:0 \"$tmp\" && chmod 600 \"$tmp\" && mv \"$tmp\" \"$dst\"; then
  n=$(grep -c -vE '^[[:space:]]*(#|$)' \"$dst\" 2>/dev/null || true)
  echo \"pinenote-ssh-keys: installed $dst from $src (${n:-0} entry line(s))\"
  exit 0
else
  rm -f \"$tmp\"
  echo \"pinenote-ssh-keys: failed to install $dst from $src\" >&2
  exit 1
fi
" port)))
       (chmod #$output #o555))))

(define (pinenote-ssh-keys-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-ssh-authorized-keys))
    ;; /data is mounted (or its mount has already failed, on systems
    ;; without the partition) once the file-system services are up.
    ;; sshd reads authorized_keys per-connection, so no ordering
    ;; dependency on ssh-daemon is needed.
    (requirement '(file-systems))
    (documentation "Install root's SSH authorized keys from the persistent data partition (/data/ssh/authorized_keys); no-op when absent.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$%pinenote-ssh-keys-install))))
    (stop #~(const #t)))))

(define pinenote-ssh-authorized-keys-service-type
  (service-type
   (name 'pinenote-ssh-authorized-keys)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-ssh-keys-shepherd-service)))
   (default-value #f)
   (description "Copy /data/ssh/authorized_keys to /root/.ssh/authorized_keys at every boot, so the reader image stays generic and the operator's key survives os2 reflashes.  No-op when the data partition or the file is absent.")))
