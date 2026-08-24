#!/bin/sh
# Stage the built shelf of manuals into the reader's library (issue #17).
#
# Run by pinenote/services/manuals.scm as a shepherd ONE-SHOT, after
# file-system-/data and pinenote-library.  A separate file rather than a
# string inside the service, so it is covered by CI's "every tracked shell
# script parses" gate and, more importantly, so pinenote/tools/manuals can
# EXECUTE it against a fake library instead of grepping it.
#
#   manuals-stage.sh SHELF_SRC SHELF ROOT
#
#     SHELF_SRC  the store directory of EPUBs (must carry a MANIFEST)
#     SHELF      where they go, e.g. /data/books/Manuals
#     ROOT       the mount that must be live before anything is written,
#               normally /data.  EXPLICIT rather than derived from SHELF:
#               deriving it by walking up two directories is right only for
#               the default path and silently becomes "/" for any other.
#
# Every failure path exits 0.  A reader that boots without its manuals is a
# reader; a reader whose boot is held up by a documentation copy is not.
set -u

# Shepherd start-lambdas inherit PID 1's environment, which on this device is
# a single e2fsck-static/sbin directory -- mkdir, cp, rm, mountpoint and sync
# are all unresolvable without this, and a script that silently took its
# failure branch would leave the shelf uncreated while every gate stayed
# green, because a developer's workstation has a full PATH.
# wifi.scm:26-28 records the lesson; ssh-keys.scm:75 has the incantation.
export PATH="/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}"

shelf_src=${1:?usage: manuals-stage.sh SHELF_SRC SHELF ROOT}
shelf=${2:?usage: manuals-stage.sh SHELF_SRC SHELF ROOT}
root=${3:-/data}

stamp="$(dirname "$shelf")/.pinenote-manuals"

# Refuse unless the shared data partition is genuinely mounted.  Without this
# guard a QEMU-virt boot (no p7) or a failed mount would write the shelf onto
# the root filesystem, underneath the mountpoint, where it can never be seen
# again -- the mistake library.scm records having to fix.
if ! mountpoint -q "$root"; then
  echo "pinenote-manuals: $root is not a mount point -- doing nothing"
  exit 0
fi

if [ ! -f "$shelf_src/MANIFEST" ]; then
  echo "pinenote-manuals: no MANIFEST in $shelf_src -- doing nothing"
  exit 0
fi

if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$shelf_src" ]; then
  echo "pinenote-manuals: $shelf is current -- unchanged"
  exit 0
fi

# The stamp exists but the shelf does not: the user deleted it.  Record the
# new build so this stays true across deploys, and create nothing.  The stamp
# lives on the data partition, so the deletion survives an os2 reflash --
# which /var does not.
if [ -f "$stamp" ] && [ ! -d "$shelf" ]; then
  printf '%s\n' "$shelf_src" > "$stamp"
  sync
  echo "pinenote-manuals: $shelf was removed by the user -- leaving it removed"
  exit 0
fi

if ! mkdir -p "$shelf"; then
  echo "pinenote-manuals: could not create $shelf"
  exit 0
fi

# Remove only what a previous run of THIS service put here.  A book the user
# copied into the folder is not ours to delete.
if [ -f "$shelf/.wilkbook-manifest" ]; then
  while IFS= read -r old; do
    [ -n "$old" ] && rm -f "$shelf/$old"
  done < "$shelf/.wilkbook-manifest"
fi

: > "$shelf/.wilkbook-manifest.new"
n=0
for book in "$shelf_src"/*.epub; do
  [ -e "$book" ] || continue
  base=$(basename "$book")
  # Copy to a sibling and rename, so an interrupted boot never leaves a
  # half-written book that KOReader will try to open.
  if cp -f "$book" "$shelf/$base.tmp" && mv -f "$shelf/$base.tmp" "$shelf/$base"; then
    chmod 0644 "$shelf/$base" 2>/dev/null || true
    printf '%s\n' "$base" >> "$shelf/.wilkbook-manifest.new"
    n=$((n + 1))
  else
    echo "pinenote-manuals: could not stage $base"
    rm -f "$shelf/$base.tmp"
  fi
done

mv -f "$shelf/.wilkbook-manifest.new" "$shelf/.wilkbook-manifest"
printf '%s\n' "$shelf_src" > "$stamp"
# os1 reads this same partition as /home, as uid 1000; 0775 with gid 1000
# lets that user read and manage the shelf too.
chmod 0775 "$shelf" 2>/dev/null || true
chgrp 1000 "$shelf" 2>/dev/null || true
sync
echo "pinenote-manuals: staged $n book(s) into $shelf"
