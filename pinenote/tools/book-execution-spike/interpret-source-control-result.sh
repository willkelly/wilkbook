#!/bin/sh
# Classify one immutable launcher transcript after the separately authorized
# control run.  Returning zero means only that the expected *failure* was
# reproduced; it is not the guest/runtime PASS oracle.
set -eu

fail() {
  printf 'CONTROL-EXPECTED-FAILURE-REPRODUCED=false reason=%s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || {
  printf 'usage: %s IMMUTABLE-CONTROL-RUN-LOG\n' "$0" >&2
  exit 2
}
log=$1
resolved=$(readlink -f -- "$log") || fail cannot-resolve-log
[ "$resolved" = "$log" ] || fail log-must-be-canonical-and-not-a-symlink
[ -f "$log" ] && [ ! -L "$log" ] || fail log-must-be-a-regular-file
[ "$(stat -c %h "$log")" -eq 1 ] || fail log-must-not-have-hard-link-aliases
case $(stat -c %a "$log") in
  *[2367]|*[2367][0-7]|*[2367][0-7][0-7]) fail log-must-be-immutable ;;
esac

success='OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS'
[ "$(grep -Fxc 'RUN-STATUS=1 CHECKER-STATUS=1' "$log" || true)" -eq 1 ] ||
  fail runtime-status-is-not-the-expected-failure
[ "$(grep -Fxc "$success" "$log" || true)" -eq 0 ] ||
  fail runtime-success-was-unexpectedly-reported
[ "$(grep -Fc 'BOOKEXEC-SMOKE-FAIL book-execution-guest-smoke-error' "$log" || true)" -eq 1 ] ||
  fail normal-guest-smoke-failure-marker-is-not-unique
grep -Fq 'wilkbook-python-smoke failed with status 128; bounded diagnostics emitted' "$log" ||
  fail runsc-status-128-is-absent
grep -Fq 'panic: failed to create a syscall thread\\n' "$log" ||
  fail control-panic-is-absent
grep -Fq 'pkg/sentry/platform/systrap/subprocess.go:219' "$log" ||
  fail control-panic-source-line-is-not-219
grep -Fq 'BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console.log' "$log" ||
  fail full-console-export-did-not-begin
grep -Fq 'BOOKEXEC-QEMU-DIAGNOSTIC-END label=console.log retention=full' "$log" ||
  fail full-console-export-did-not-complete
[ "$(grep -Fc 'BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE' "$log" || true)" -eq 0 ] ||
  fail console-export-was-incomplete
grep -Fq '/gnu/store/b9a3sd53w0hka2n78657x8vid68x98ph-gvisor-v12-control-local-test-artifact-20260831.0/bin/runsc' "$log" ||
  fail source-control-runsc-path-is-absent
grep -Fq '/gnu/store/b9a3sd53w0hka2n78657x8vid68x98ph-gvisor-v12-control-local-test-artifact-20260831.0/bin/gvisor-bin/gvisor_sentry' "$log" ||
  fail source-control-sentry-path-is-absent
[ "$(grep -Fc '/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0' "$log" || true)" -eq 0 ] ||
  fail frozen-prebuilt-release-appeared-in-control-log
[ "$(grep -Fc 'gvisor-v12-diagnostic-local-test-artifact' "$log" || true)" -eq 0 ] ||
  fail diagnostic-release-appeared-in-control-log
[ "$(grep -Fc 'BOOKEXEC-PYTHON-SYSTRAP-PASS' "$log" || true)" -eq 0 ] ||
  fail payload-unexpectedly-passed
[ "$(grep -Fc 'LAUNCHER-INCOMPLETE' "$log" || true)" -eq 0 ] ||
  fail launcher-did-not-finalize

printf 'CONTROL-EXPECTED-FAILURE-REPRODUCED=true\n'
printf 'CONTROL-RUNTIME-SUCCESS=false\n'
printf 'CONTROL-NEXT-GATE=separate-parent-authorization-for-diagnostic-image-and-run\n'
