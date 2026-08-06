(define-module (pinenote services ssh-keys)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (pinenote-ssh-authorized-keys-service-type))

;; Per-operator/per-device SSH state from the persistent `data'
;; partition (doc/networking.md §3: the same out-of-band channel as the
;; Wi-Fi credentials — the design's `/state/ssh/…' is `/data/ssh/…' in
;; the shipped image, where the data partition is mounted).  Two jobs:
;;
;; 1. AUTHORIZED KEY (operator state): copy /data/ssh/authorized_keys
;;    over /root/.ssh/authorized_keys.  The image must stay generic —
;;    baking an operator's public key into the flavor (as
;;    pinenote-reader.scm did until 2026-08-06) means every
;;    collaborator's build is a device only the author can reach.
;; 2. HOST KEYS (device identity): keep /etc/ssh/ssh_host_*_key
;;    synchronized with /data/ssh/host/ so the device's SSH identity
;;    survives an os2 reflash (/etc/ssh does not, /data does) and the
;;    fingerprint stops changing on every reflash.
;;
;; Mechanism notes:
;; - Guix's generated sshd_config always honors `.ssh/authorized_keys'
;;   (AuthorizedKeysFile in gnu/services/ssh.scm) and carries no HostKey
;;   override, so sshd reads the default /etc/ssh/ssh_host_*_key paths.
;; - Guix's sshd runs INETD-STYLE (make-inetd-constructor): a fresh sshd
;;   per connection, so host keys are read per connection and this boot
;;   one-shot needs no ordering against the listener.
;; - Guix's openssh activation runs `ssh-keygen -A' BEFORE shepherd, so
;;   generated keys always exist by the time this one-shot runs.
;; - Copying — rather than pointing AuthorizedKeysFile/HostKey at /data
;;   — keeps the authorized-key grant scoped to root (a shared non-%u
;;   path would authorize the same keys for the passwordless-sudo
;;   `reader' user) and keeps sshd's strictness checks on directories we
;;   control.
;;
;; Semantics:
;; - The authorized-keys data file is the source of truth: a hand edit
;;   of /root/.ssh/authorized_keys is overwritten at the next boot, and
;;   deleting the file on a MOUNTED /data revokes the installed key at
;;   the next boot.  When /data is not mounted (virt, transient mount
;;   failure) the last-installed key is left alone, so a mount hiccup
;;   can never lock SSH out.  Edit /data/ssh/, not /root/.ssh.
;; - Host keys are a UNION, /data winning per key type: every VALID
;;   /data/ssh/host/ssh_host_*_key is restored into /etc/ssh, and every
;;   /etc/ssh type missing from /data — or present but invalid (a
;;   zero-length post-power-cut file re-seeds rather than wedging) — is
;;   seeded INTO /data (first boot after a reflash self-seeds; a type
;;   added by a future Guix persists from its first appearance).  No
;;   valid key FILE is ever deleted from /etc/ssh (only crash-orphaned
;;   temps and directories squatting on key paths), so there is no
;;   keyless window even on failure.  Host-key deletion
;;   is NOT revocation (identity, not authorization): to rotate the
;;   device identity, delete the type from BOTH /data/ssh/host and
;;   /etc/ssh and reboot (activation regenerates, the seed persists it).
;; - Exposure tradeoff, documented in doc/networking.md §4.1: host
;;   PRIVATE keys live 0600 root-owned on the shared unencrypted p7 (the
;;   partition os1 mounts at /home) — the same class of exposure as the
;;   Wi-Fi PSK hash already staged there, on a single-trust-domain
;;   device whose console users have passwordless sudo anyway.
;;
;; Failure posture, mirroring pinenote-wifi: an absent /data or absent
;; files are EXPECTED states (QEMU virt, fresh device) — log and exit 0.
;; A failed copy when the source EXISTS is anomalous and exits nonzero
;; so `herd status' shows the one-shot failed, without blocking boot.
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

rc=0

# ---- 1. root's authorized key (operator state) -----------------------
src=/data/ssh/authorized_keys
dst=/root/.ssh/authorized_keys

if [ ! -f \"$src\" ]; then
  # Distinguish revocation from a missing partition: with /data mounted
  # and no key file, the source of truth says root has no key -- remove
  # the installed one.  With /data unmounted we cannot know intent;
  # leave the last-installed key so a transient mount failure never
  # locks SSH out.
  if mountpoint -q /data && [ -f \"$dst\" ]; then
    rm -f \"$dst\"
    echo \"pinenote-ssh-keys: no $src on mounted /data; removed $dst (revocation)\"
  else
    echo \"pinenote-ssh-keys: no $src; skipping (root SSH has no out-of-band key; use the ACM/UART console)\"
  fi
else
  umask 077
  if mkdir -p /root/.ssh; then
    chmod 700 /root/.ssh 2>/dev/null || true
    # A directory at $dst is broken state (no supported flow creates
    # it); clear it so mv installs a file, not a file inside it.
    [ -d \"$dst\" ] && rm -rf \"$dst\"
    tmp=\"$dst.tmp.$$\"
    # tr strips CRs so a key file edited on Windows still parses.
    if tr -d '\\r' < \"$src\" > \"$tmp\" && chown 0:0 \"$tmp\" && chmod 600 \"$tmp\" && mv \"$tmp\" \"$dst\"; then
      n=$(grep -c -vE '^[[:space:]]*(#|$)' \"$dst\" 2>/dev/null || true)
      echo \"pinenote-ssh-keys: installed $dst from $src (${n:-0} entry line(s))\"
    else
      rm -f \"$tmp\"
      echo \"pinenote-ssh-keys: failed to install $dst from $src\" >&2
      rc=1
    fi
  else
    echo 'pinenote-ssh-keys: cannot create /root/.ssh' >&2
    rc=1
  fi
fi

# ---- 2. persistent host keys (device identity) -----------------------
hostdir=/data/ssh/host
etc=/etc/ssh

# valid_key <priv>: installable iff non-empty AND (when ssh-keygen is
# available, which the reader profile ships) parseable.  This is the
# integrity floor: an empty file (unsynced seed + power cut) or garbage
# (operator cp/symlink mistake) must never overwrite a working key --
# ssh-keygen -A does not regenerate over existing files, so installing
# junk would leave that key type dead until manual rotation.
valid_key() {
  [ -s \"$1\" ] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -y -f \"$1\" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# write_pub <priv> <pub>: regenerate the .pub from the installed
# private key so it can never drift from the identity sshd serves.
# Cosmetic (inetd-style sshd derives the public key from the private
# per connection); failure warns but does not fail the service.
write_pub() {
  ptmp=\"$(dirname \"$2\")/.$(basename \"$2\").tmp.$$\"
  if command -v ssh-keygen >/dev/null 2>&1 \\
     && ssh-keygen -y -f \"$1\" > \"$ptmp\" 2>/dev/null \\
     && chmod 644 \"$ptmp\" && mv -T \"$ptmp\" \"$2\" 2>/dev/null; then
    :
  else
    rm -f \"$ptmp\"
    echo \"pinenote-ssh-keys: warning: could not refresh $2 (cosmetic; sshd derives its own)\" >&2
  fi
}

if mountpoint -q /data; then
  umask 077
  if mkdir -p \"$hostdir\" \"$etc\"; then
    # Tighten hand-created staging dirs (sudo mkdir -p under umask 022
    # leaves 0755; private keys are 0600 regardless, this hides names).
    chmod 700 /data/ssh \"$hostdir\" 2>/dev/null || true
    # Clean crash-orphaned temp files from previous runs (dot-prefixed,
    # so the ssh_host_*_key globs below can never match them).
    rm -f \"$etc\"/.ssh_host_*.tmp.* \"$hostdir\"/.ssh_host_*.tmp.*
    restored=0 seeded=0 current=0
    # Restore: every valid key type present on /data wins over /etc/ssh.
    for k in \"$hostdir\"/ssh_host_*_key; do
      [ -f \"$k\" ] || continue
      base=$(basename \"$k\")
      if ! valid_key \"$k\"; then
        echo \"pinenote-ssh-keys: refusing invalid $base from $hostdir (not installed)\" >&2
        rc=1
        continue
      fi
      if cmp -s \"$k\" \"$etc/$base\" 2>/dev/null; then
        current=$((current + 1))
        # Repair a stale/missing .pub even when the private is current.
        if command -v ssh-keygen >/dev/null 2>&1; then
          d=$(ssh-keygen -y -f \"$etc/$base\" 2>/dev/null || true)
          [ \"$d\" = \"$(cat \"$etc/$base.pub\" 2>/dev/null)\" ] || write_pub \"$etc/$base\" \"$etc/$base.pub\"
        fi
        continue
      fi
      # A directory at the /etc/ssh destination is broken state we own;
      # clear it (mv -T would fail loudly, but /etc/ssh is ours to fix).
      [ -d \"$etc/$base\" ] && rm -rf \"$etc/$base\"
      tmp=\"$etc/.$base.tmp.$$\"
      if cp \"$k\" \"$tmp\" && chown 0:0 \"$tmp\" && chmod 600 \"$tmp\" && mv -T \"$tmp\" \"$etc/$base\"; then
        restored=$((restored + 1))
        write_pub \"$etc/$base\" \"$etc/$base.pub\"
        [ -f \"$k.pub\" ] || write_pub \"$k\" \"$k.pub\"
      else
        rm -f \"$tmp\"
        echo \"pinenote-ssh-keys: failed to restore $base into $etc\" >&2
        rc=1
      fi
    done
    # Seed: any /etc/ssh type missing from /data persists from now on.
    # A /data copy that exists but is INVALID (e.g. zero-length after a
    # pre-sync power cut) is re-seeded over -- strictly safe, and it
    # makes persistence self-healing instead of failing every boot
    # until someone deletes the corrupt file by hand.
    # mv -T on the /data side: a directory at the destination is the
    # operator's staging mistake -- fail LOUDLY rather than delete their
    # data or (worse) silently count a non-persisted key as seeded.
    for k in \"$etc\"/ssh_host_*_key; do
      [ -f \"$k\" ] || continue
      base=$(basename \"$k\")
      [ -f \"$hostdir/$base\" ] && valid_key \"$hostdir/$base\" && continue
      if ! valid_key \"$k\"; then
        echo \"pinenote-ssh-keys: not seeding invalid $base from $etc (image bug?)\" >&2
        rc=1
        continue
      fi
      tmp=\"$hostdir/.$base.tmp.$$\"
      if cp \"$k\" \"$tmp\" && chmod 600 \"$tmp\" && mv -T \"$tmp\" \"$hostdir/$base\"; then
        seeded=$((seeded + 1))
        write_pub \"$hostdir/$base\" \"$hostdir/$base.pub\"
      else
        rm -f \"$tmp\"
        echo \"pinenote-ssh-keys: failed to seed $base into $hostdir\" >&2
        rc=1
      fi
    done
    # Durability: the whole point is surviving reflashes AND power cuts;
    # without this, ext4 writeback could persist a zero-length seed.
    [ $((restored + seeded)) -gt 0 ] && sync
    echo \"pinenote-ssh-keys: host keys: $restored restored, $seeded seeded, $current already current (identity persists on /data)\"
  else
    echo \"pinenote-ssh-keys: cannot create $hostdir or $etc; host keys unchanged\" >&2
    rc=1
  fi
else
  echo 'pinenote-ssh-keys: /data not mounted; host keys unchanged'
fi

exit $rc
" port)))
       (chmod #$output #o555))))

(define (pinenote-ssh-keys-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-ssh-authorized-keys))
    ;; /data is mounted (or its mount has already failed, on systems
    ;; without the partition) once the file-system services are up.
    ;; sshd is inetd-style (fresh sshd per connection), so both the
    ;; authorized key and the host keys are picked up per-connection —
    ;; no ordering dependency on ssh-daemon is needed for SAFETY.  On
    ;; each post-reflash boot there is a benign window (listener up
    ;; before this one-shot) where a very early client could pin the
    ;; freshly generated key and see one extra fingerprint change; not
    ;; worth an ordering edge.
    (requirement '(file-systems))
    (documentation "Install root's SSH authorized key from /data/ssh/authorized_keys and synchronize persistent host keys with /data/ssh/host/; no-op when the data partition is absent.")
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
   (description "Copy /data/ssh/authorized_keys to /root/.ssh/authorized_keys at every boot, and keep /etc/ssh host keys synchronized with /data/ssh/host/ (union, /data winning per key type), so the reader image stays generic, the operator's key survives os2 reflashes, and the device's SSH identity persists across reflashes.  No-op when the data partition is absent.")))
