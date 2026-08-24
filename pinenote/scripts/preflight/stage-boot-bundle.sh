#!/bin/sh
set -eu

usage() {
  printf 'usage: %s SYSTEM_DIRECTORY [BOOT_BUNDLE_DIRECTORY]\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

note() {
  printf 'NOTE: %s\n' "$1"
}

resolve_directory() {
  directory=$1
  (CDPATH= cd -P "$directory" && pwd -P)
}

require_inside_artifact_root() {
  path=$1
  case $path in
    "$artifact_root"/*) ;;
    *) fail "boot bundle directory must resolve under $artifact_root" ;;
  esac
}

require_file() {
  path=$1
  description=$2
  if [ ! -f "$path" ]; then
    fail "missing $description: $path"
  fi
}

stage_link() {
  source=$1
  target=$2
  if [ -e "$target" ] || [ -L "$target" ]; then
    fail "refusing to overwrite staged artifact: $target"
  fi
  ln -s "$source" "$target"
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

system_directory=$1
if [ ! -d "$system_directory" ]; then
  fail "system path is not a directory: $system_directory"
fi
system_directory=$(resolve_directory "$system_directory") || fail "cannot resolve system directory: $system_directory"

artifact_root=$(resolve_directory /tmp/wilkbook) || fail "cannot resolve /tmp/wilkbook"

if [ "$#" -eq 2 ]; then
  requested_bundle=$2
  parent=$(dirname "$requested_bundle")
  basename=$(basename "$requested_bundle")

  case $basename in
    ''|'.'|'..') fail "boot bundle basename is unsafe: $basename" ;;
  esac

  parent_root=$(resolve_directory "$parent") || fail "boot bundle parent does not exist: $parent"
  bundle=$parent_root/$basename
  require_inside_artifact_root "$bundle"

  if [ -e "$bundle" ] || [ -L "$bundle" ]; then
    fail "boot bundle path already exists; refusing to reuse it: $bundle"
  fi
  mkdir -- "$bundle"
else
  bundle=$(mktemp -d "$artifact_root/pinenote-boot-bundle.XXXXXX")
fi

bundle=$(resolve_directory "$bundle") || fail "cannot resolve boot bundle directory: $bundle"
require_inside_artifact_root "$bundle"

kernel_image=$system_directory/kernel/Image
kernel_config=$system_directory/kernel/.config
dtb=$system_directory/kernel/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb
initrd=$system_directory/initrd
parameters=$system_directory/parameters

require_file "$kernel_image" "uncompressed PineNote kernel Image"
require_file "$kernel_config" "resolved PineNote kernel config"
require_file "$dtb" "PineNote v1.2 DTB"
require_file "$initrd" "Guix initrd"
require_file "$parameters" "Guix boot parameters"

mkdir -- "$bundle/extlinux"
stage_link "$kernel_image" "$bundle/extlinux/Image"
stage_link "$kernel_config" "$bundle/extlinux/config"
stage_link "$dtb" "$bundle/extlinux/rk3566-pinenote-v1.2.dtb"
stage_link "$initrd" "$bundle/extlinux/initrd.cpio.gz"

kernel_args=$(guile -c '
(use-modules (srfi srfi-1) (srfi srfi-13))

(define (fail message)
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 1))

(define parameters-file (cadr (command-line)))
(define parameters (call-with-input-file parameters-file read))

(unless (and (pair? parameters) (eq? (car parameters) (quote boot-parameters)))
  (fail "parameters file is not a boot-parameters record"))

(let ((entries (filter (lambda (field)
                         (and (pair? field)
                              (eq? (car field) (quote kernel-arguments))))
                       (cdr parameters))))
  (unless (= (length entries) 1)
    (fail "expected exactly one kernel-arguments field"))
  (let ((arguments (cadr (car entries))))
    (unless (and (list? arguments) (every string? arguments))
      (fail "kernel-arguments field is not a string list"))
    (for-each (lambda (argument)
                (when (string-any char-whitespace? argument)
                  (fail "kernel argument contains whitespace")))
              arguments)
    (display (string-join arguments " "))))
' "$parameters") || fail "could not extract kernel arguments from: $parameters"
if [ -z "$kernel_args" ]; then
  fail "could not extract kernel arguments from: $parameters"
fi

case " $kernel_args " in
  *' root='*) fail "kernel arguments already contain root=; refusing ambiguous boot args" ;;
esac

case " $kernel_args " in
  *' root=/dev/mmcblk'*) fail "kernel arguments contain forbidden raw eMMC root path" ;;
esac

cat > "$bundle/extlinux/extlinux.conf" <<EOF
# Generated for static preflight only; do not install automatically.
LABEL pinenote-guix-preflight
  MENU LABEL Guix PineNote slim preflight
  KERNEL Image
  FDT rk3566-pinenote-v1.2.dtb
  INITRD initrd.cpio.gz
  APPEND $kernel_args root=PNGuixRoot
EOF

pass "staged boot bundle under $bundle"
pass "linked Image, matching config, PineNote DTB, initrd, and generated extlinux.conf"
note "run: pinenote/scripts/preflight/inspect-boot-bundle.sh $bundle"
