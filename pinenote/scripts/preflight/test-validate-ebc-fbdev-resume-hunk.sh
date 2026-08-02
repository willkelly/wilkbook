#!/bin/sh
# Mutation test for validate-ebc-fbdev-resume-hunk.sh.
#
# The gate it tests is the ONLY behavioral check on the fbdev resume
# barrier -- the ebc-logic harness compiles the `#else` no-op stub, so a
# green host suite proves nothing about the live branch.  A structural
# gate that cannot fail is worse than none, so each mutation below
# corresponds to one way the barrier could be silently lost in a rebase.
#
# Usage: test-validate-ebc-fbdev-resume-hunk.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
gate=$script_dir/validate-ebc-fbdev-resume-hunk.sh
patch=$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

fail=0

# The unmutated patch must pass.
if sh "$gate" "$patch" > "$tmp/clean.out" 2>&1; then
  echo "PASS: gate accepts the shipped patch"
else
  cat "$tmp/clean.out" >&2
  echo "FAIL: gate rejects the shipped patch" >&2
  fail=1
fi

# Each mutation must be rejected.  sed-based ones first.
mutate_sed() {
  name=$1; expr=$2
  sed "$expr" "$patch" > "$tmp/$name.patch"
  if cmp -s "$patch" "$tmp/$name.patch"; then
    echo "FAIL: mutation '$name' changed nothing (anchor drifted)" >&2
    fail=1
    return
  fi
  if sh "$gate" "$tmp/$name.patch" > "$tmp/$name.out" 2>&1; then
    echo "FAIL: gate accepted mutation '$name'" >&2
    fail=1
  else
    echo "PASS: gate rejects '$name'"
  fi
}

mutate_sed drop-call     '/^+\t\trockchip_ebc_fbdev_finish_resume();$/d'
mutate_sed drop-helper   '/^+static void rockchip_ebc_fbdev_finish_resume(void)$/,/^+}$/d'
mutate_sed drop-stub     '/^+static void rockchip_ebc_fbdev_finish_resume(void) { }$/d'
mutate_sed suspend-true  's/^+\t\t\t\t\t\t   false);$/+\t\t\t\t\t\t   true);/'
mutate_sed hand-rolled   's/^+\t\tdrm_fb_helper_set_suspend_unlocked(rockchip_ebc_defio_helper,$/+\t\tfb_set_suspend(rockchip_ebc_defio_helper->info,/'

# Block-shape mutations: rewrite the resume success block wholesale.
python3 - "$patch" "$tmp" <<'PY'
import sys
src = open(sys.argv[1]).read(); out = sys.argv[2]
anchor = ("+\tif (!ret) {\n"
          "+\t\trockchip_ebc_wake_worker(ebc,\n"
          "+\t\t\t\t\t rockchip_ebc_crtc_has_ctx(ebc));\n"
          "+\t\t/* Only then finish the fbdev client's un-suspend, so any\n"
          "+\t\t * damage it releases has a live consumer. */\n"
          "+\t\trockchip_ebc_fbdev_finish_resume();\n"
          "+\t}\n")
if anchor not in src:
    print("ANCHOR-DRIFT", file=sys.stderr); sys.exit(3)
wake = ("+\t\trockchip_ebc_wake_worker(ebc,\n"
        "+\t\t\t\t\t rockchip_ebc_crtc_has_ctx(ebc));\n")
call = "+\t\trockchip_ebc_fbdev_finish_resume();\n"
variants = {
    # un-suspend before the worker wakes: released damage has no consumer
    "order":     "+\tif (!ret) {\n" + call + wake + "+\t}\n",
    # outside the success block: also runs after a failed helper resume
    "unguarded": "+\tif (!ret) {\n" + wake + "+\t}\n" + "+\trockchip_ebc_fbdev_finish_resume();\n",
}
for name, blk in variants.items():
    open("%s/%s.patch" % (out, name), "w").write(src.replace(anchor, blk))
PY
py=$?
if [ "$py" -ne 0 ]; then
  echo "FAIL: could not build block mutations (resume block drifted)" >&2
  fail=1
fi

for name in order unguarded; do
  [ -f "$tmp/$name.patch" ] || continue
  if sh "$gate" "$tmp/$name.patch" > "$tmp/$name.out" 2>&1; then
    echo "FAIL: gate accepted mutation '$name'" >&2
    fail=1
  else
    echo "PASS: gate rejects '$name' ($(head -1 "$tmp/$name.out"))"
  fi
done

[ "$fail" -eq 0 ] && echo "PASS: fbdev resume-barrier gate mutation suite" ||
  echo "FAIL: fbdev resume-barrier gate mutation suite" >&2
exit "$fail"
