(define-module (pinenote services library)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (pinenote-library-service-type))

;; Create the reader's library directory, once, on a device that has never
;; had one.
;;
;; Why this exists at all: nothing in the tree created /data/books.  It
;; exists on the one dogfooding device because a human made it by hand, and
;; the seeded KOReader profile hardcodes `home_dir = "/data/books"'.  So a
;; freshly provisioned device seeded a browser pointed at a directory that
;; was not there — and KOReader does NOT fall back when home_dir fails to
;; resolve: `realpath' returns nil, `root_path' drops through to
;; `lfs.currentdir()', and the user's first sight of "their library" is the
;; read-only Guix store directory the service happens to run from,
;; listing luajit and reader.lua.
;;
;; THIS IS A SHEPHERD ONE-SHOT AND NOT AN ACTIVATION SNIPPET, and that is
;; load-bearing.  Verified on the device 2026-08-07: /run/current-system/boot
;; mentions /data zero times and only runs `activate'; p7 is mounted by the
;; shepherd service `file-system-/data', which starts AFTER activation.  A
;; `mkdir -p "/data/books"' in activation therefore creates the directory on
;; the os2 ROOT filesystem, where the real mount immediately shadows it —
;; invisible forever, and green in every test.  A bind-mount probe of the
;; root fs confirmed the mountpoint stub there is empty.  This is the same
;; class of mistake as the DMC default regression; dmc.scm:69-77 carries the
;; pattern being copied here.
;;
;; The second load-bearing detail is `export PATH'.  Shepherd start-lambdas
;; inherit PID 1's environment, which on this device is a single
;; e2fsck-static/sbin directory — `mkdir', `ln', `mountpoint' and `sync' are
;; all unresolvable without it, and a script that silently takes its
;; failure branch would leave the directory uncreated while every gate
;; stayed green, because a developer's workstation has a full PATH.
;; wifi.scm:26-28 records the lesson; ssh-keys.scm:75 has the incantation.

(define %pinenote-library-seed
  (computed-file
   "pinenote-library-seed"
   #~(begin
       (call-with-output-file #$output
         (lambda (port)
           (display "\
#!/bin/sh
set -u
export PATH=\"/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}\"

root=\"${1:-/data}\"
lib=\"$root/books\"

# Refuse unless the shared data partition is genuinely mounted.  Without
# this guard a QEMU-virt boot (no p7) or a failed mount would create the
# library on the root filesystem, under the mountpoint, where it can never
# be seen again.
if ! mountpoint -q \"$root\"; then
  echo \"pinenote-library: $root is not a mount point -- doing nothing\"
  exit 0
fi

# An existing library is never touched: no pointer, no README, no chmod.
# The author's device already has one, with books and .sdr sidecars in it,
# and /root does not survive a reflash so this runs again on every deploy.
# A pointer the user deleted must stay deleted.
if [ -e \"$lib\" ]; then
  echo \"pinenote-library: $lib already exists -- unchanged\"
  exit 0
fi

if ! mkdir -p \"$lib\"; then
  echo \"pinenote-library: could not create $lib\"
  exit 0
fi

# os1 reads this same directory as /home/books, as uid 1000.  0775 with gid
# 1000 lets that user create files here.  Our own KOReader runs as root, so
# the sidecars IT writes stay root-owned and os1 still cannot rewrite them
# -- a known residual asymmetry, documented rather than pretended away.
chmod 0775 \"$lib\" 2>/dev/null || true
chgrp 1000 \"$lib\" 2>/dev/null || true

# A pointer to the stock Debian home, when this device has one.  p7's root
# IS os1's /home, so \"$root/user\" is the factory Debian user's home
# directory and their existing books are inside it.
#
# The target is RELATIVE on purpose.  os1 mounts this same partition at
# /home, so an absolute \"/data/user\" would dangle when followed from the
# rescue slot; \"../user\" resolves correctly from both.
#
# Note we create a symlink and never write THROUGH it: creating a link does
# not touch its target, so nothing here modifies os1's home directory.
if [ -d \"$root/user\" ] && [ ! -e \"$lib/Debian home\" ]; then
  if ln -s ../user \"$lib/Debian home\"; then
    echo \"pinenote-library: added the Debian-home pointer\"
  else
    echo \"pinenote-library: could not add the Debian-home pointer\"
  fi
fi

sync
echo \"pinenote-library: seeded $lib\"
" port)))
       (chmod #$output #o555))))

(define (pinenote-library-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-library))
    ;; file-system-/data, not file-systems: this one-shot's entire job is
    ;; to write onto p7, so it must not run before p7 is mounted.  The
    ;; reader flavor declares that file system with mount-may-fail?, so the
    ;; service exists (and settles) even on a device without the partition.
    (requirement '(file-system-/data))
    (documentation "Create /data/books on a device that has none, and point at the stock Debian home if one is present; no-op when the library already exists or the data partition is absent.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$%pinenote-library-seed "/data"))))
    (stop #~(const #t)))))

(define pinenote-library-service-type
  (service-type
   (name 'pinenote-library)
   (extensions (list (service-extension shepherd-root-service-type
                                        pinenote-library-shepherd-service)))
   (default-value #f)
   (description "Create the reader's library directory at /data/books on first boot of a device that does not have one, with a relative pointer to the stock Debian home when p7 carries it.  Never modifies an existing library, and never writes inside the Debian user's home.")))
