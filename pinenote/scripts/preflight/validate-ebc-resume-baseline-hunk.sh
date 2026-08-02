#!/bin/sh
# Structural gate: the refresh thread's resume branch must restore the
# damage-comparison baseline (doc/status.md 2026-08-02).
#
# Why this needs a gate rather than a unit test:
#
#   ctx->final_atomic_update is the buffer the blitters write into and
#   diff against.  rockchip_ebc_plane_atomic_update() DROPS any area whose
#   blit reports no change (list_del + kfree) -- silently: no error, no
#   frame, nothing logged.  The buffer is kmalloc'd, not kzalloc'd.
#
#   A system resume is the one path that reaches the thread's outer-loop
#   init with a BRAND-NEW ctx (crtc_atomic_check reallocates whenever
#   mode_changed, which drm_atomic_helper_resume's duplicated-state commit
#   always sets).  Both non-suspend init branches seed the buffer -- 0xff
#   on first run, suspend_next on re-init -- so only the suspend branch
#   could leave it uninitialised, and it did.
#
#   The rung-7a harness cannot catch this: its commit_damage() appends
#   areas directly and never calls the blitter, so the drop-on-match
#   decision is never executed offline (see doc/testing.md).
#
# Usage: validate-ebc-resume-baseline-hunk.sh [patch]
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
patch=${1:-$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch}

fail() { echo "FAIL: $1" >&2; exit 1; }

section=$(awk '/^diff --git a\/drivers\/gpu\/drm\/rockchip\/rockchip_ebc.c/{f=1}
               f && /^diff --git/ && !/rockchip_ebc.c/{exit} f{print}' "$patch")
[ -n "$section" ] || fail "no rockchip_ebc.c section in $patch"
added=$(printf '%s\n' "$section" | sed -n 's/^+//p')

# 1. The drop-on-match behaviour this gate protects against must still
#    exist -- if it is ever removed, this gate's rationale changes and the
#    gate should be revisited rather than silently passing.
printf '%s\n' "$added" | grep -qF "Drop the area if the FB didn't actually change." ||
  fail "the drop-on-match path is gone; revisit this gate's rationale"

# 2. The buffer is still the uninitialised kind (kmalloc, not kzalloc).
#    If someone switches it to kzalloc the baseline is at least
#    deterministic, but the resume restore is still required for
#    correctness -- so this is informational, not fatal.
if ! printf '%s\n' "$added" | grep -qE 'final_atomic_update = kmalloc\('; then
  echo "note: final_atomic_update is no longer a bare kmalloc; resume restore still required"
fi

# 3. The suspend/resume branch must restore final_atomic_update.
#    Isolate the `if (ebc->suspend_was_requested == 1) { ... } else` block.
resume_branch=$(printf '%s\n' "$added" |
  awk '/if\(ebc->suspend_was_requested == 1\)\{/{f=1} f{print} f&&/^\t\t\} else \{/{exit}')
[ -n "$resume_branch" ] ||
  fail "cannot isolate the suspend_was_requested resume branch"

printf '%s\n' "$resume_branch" |
  grep -qE 'memcpy\(ctx->final_atomic_update, ebc->suspend_next' ||
  fail "resume branch does not restore ctx->final_atomic_update: post-resume damage is diffed against uninitialised memory and silently dropped"

# 4. It must be restored from the same source as ctx->final -- the panel
#    shows suspend_next after the restoring global refresh, so any other
#    baseline reintroduces the mismatch in a different disguise.
printf '%s\n' "$resume_branch" |
  grep -qE 'memcpy\(ctx->final, ebc->suspend_next' ||
  fail "resume branch no longer restores ctx->final from suspend_next; the baseline pair must agree"

echo "PASS: rockchip_ebc resume damage-baseline structural gate"
