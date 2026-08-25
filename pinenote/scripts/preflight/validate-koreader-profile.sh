#!/bin/sh
# Structural gate: settings.reader.lua has exactly ONE writer, and that
# writer is the record.
#
# WHY THIS GATE EXISTS.  The tree carried TWO seeds of
# /root/.config/koreader/settings.reader.lua from 2026-07 to 2026-08-24:
# an activation snippet in the reader flavor, and a second copy inside
# reader-session's shepherd start lambda.  Only the first could ever
# run -- activation runs before shepherd services, and both were gated on
# `unless (file-exists? ...)' -- so the second was dead code that looked
# alive.  On 2026-08-05 the six e-ink refresh keys were added to the DEAD
# one, and an image shipped with none of them.  Nothing went red; the
# device was simply slower.
#
# Measured before the deletion (2026-08-24): the live seed carried 23 leaf
# settings, the dead one 11, and the 11 were a strict subset with
# identical values -- so the dead copy had never had anything to
# contribute even if it had run.
#
# The class is "two writers, one silently dead", and the defence is that a
# second writer cannot appear unnoticed.  Hence check 1, which is the
# whole point of the file; the rest pin what the surviving writer must
# still say.
#
# COVERAGE, stated rather than implied.  Checks 1-5 are text analysis and
# need nothing installed.  Check 6 -- the only one that actually RUNS the
# serializer and reads its output -- needs `guix' on PATH, because the
# record is a Guix service configuration.  CI has guile but no guix
# (.github/workflows/host-gates.yml), so check 6 SKIPS there and says so.
# A green run without check 6 has not evaluated a line of Scheme.
#
# Usage: validate-koreader-profile.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)

prof=$repo_root/pinenote/services/koreader-profile.scm
rs=$repo_root/pinenote/services/reader-session.scm
sys=$repo_root/pinenote/systems/pinenote-reader.scm
seed_test=$script_dir/test-koreader-profile-seed.scm

fail() { echo "FAIL: $1" >&2; exit 1; }
for f in "$prof" "$rs" "$sys" "$seed_test"; do
  [ -r "$f" ] || fail "cannot read $f"
done

# The Scheme that becomes the image.  pinenote/scripts and pinenote/tools
# are host-side -- gates, analysers and the Lua the image runs -- and this
# gate's own generative test necessarily names the path, so scanning them
# would make the gate fail on itself.
scan_dirs="$repo_root/pinenote/services $repo_root/pinenote/systems
           $repo_root/pinenote/images $repo_root/pinenote/packages"

# Every Scheme file under the given roots that names the seeded settings
# file.  A writer must name the path, so this is the complete candidate
# set; the gate then requires the set to be a single known file.
writers() {
  # shellcheck disable=SC2086
  find $1 -name '*.scm' -type f -exec grep -l 'settings\.reader\.lua' {} + \
    2>/dev/null | sort
}

# --- 0. The detector must be able to detect.  Without this the whole file
#        is an assertion over a set that a broken `writers' would report as
#        empty, and it would pass forever.
ctl=$(mktemp -d)
trap 'rm -rf "$ctl"' EXIT
mkdir -p "$ctl/a" "$ctl/b"
printf '(display "/root/.config/koreader/settings.reader.lua")\n' > "$ctl/a/one.scm"
printf '(display "/root/.config/koreader/settings.reader.lua")\n' > "$ctl/b/two.scm"
printf '(display "not the seed")\n' > "$ctl/b/three.scm"
ctl_n=$(writers "$ctl" | wc -l | tr -d ' ')
[ "$ctl_n" = "2" ] ||
  fail "self-test: the writer scan found $ctl_n of 2 planted writers, so a
   real second writer would not be found either"
mkdir -p "$ctl/empty"
printf '(display "nothing here")\n' > "$ctl/empty/none.scm"
ctl_z=$(writers "$ctl/empty" | wc -l | tr -d ' ')
[ "$ctl_z" = "0" ] ||
  fail "self-test: the writer scan reported $ctl_z writers in a directory
   with none, so it matches indiscriminately"
echo "PASS: writer scan finds 2 planted writers and 0 in a clean tree"

# --- 1. Exactly one writer, and it is the record's service.
found=$(writers "$scan_dirs")
n=$(printf '%s\n' "$found" | grep -c . || true)
[ "$n" = "1" ] || fail "settings.reader.lua is named by $n Scheme files:
$found
   There must be exactly ONE writer.  The last time there were two, the
   second was dead code and an image shipped without the refresh keys
   (2026-08-05).  If the new site is a READER rather than a writer, it
   still belongs behind the record's accessor -- see
   pinenote/services/koreader-profile.scm."
[ "$found" = "$prof" ] ||
  fail "the single writer is $found, not $prof"
occ=$(grep -c 'settings\.reader\.lua' "$prof")
[ "$occ" = "1" ] ||
  fail "$prof names settings.reader.lua $occ times; the path is the
   settings-file field default and belongs in exactly one place"
echo "PASS: one writer, pinenote/services/koreader-profile.scm"

# --- 2. Nothing else declares a seeded setting.  Prose about home_dir is
#        fine; the QUOTED Lua key is what a seed writes, so that is what
#        is forbidden outside the record.
for key in closed_rotation_mode copt_b_page_margin copt_font_size \
           copt_h_page_margins copt_t_page_margin \
           coverbrowser_initial_default_setup_done cre_font \
           cre_font_family_fonts cre_header_auto_refresh \
           cre_partial_rerendering cre_show_progress flash_keyboard \
           flash_ui full_refresh_count home_dir lock_rotation \
           monospace_font quickstart_shown_version \
           refresh_on_pages_with_images screensaver_type; do
  # shellcheck disable=SC2086
  hits=$(find $scan_dirs -name '*.scm' -type f \
           -exec grep -l "\"$key\"" {} + 2>/dev/null | sort || true)
  [ -n "$hits" ] ||
    fail "no Scheme file seeds \"$key\" any more.  Every key in this list
   was in the shipped profile on 2026-08-24; dropping one is the
   2026-08-05 failure repeated."
  [ "$hits" = "$prof" ] ||
    fail "\"$key\" is written outside the record:
$hits"
done
echo "PASS: all 20 seeded settings are declared only in the record"

# --- 3. The three font keys are ONE field, not three.  This is the
#        structural replacement for the old "keep the two seeds in sync"
#        comment: with a single branch there is no expressible state in
#        which cre_font ships without monospace_font.
awk '/\(define font-settings/,/^        .\(\)\)\)/' "$prof" > "$ctl/fonts.block"
[ -s "$ctl/fonts.block" ] ||
  fail "could not find the font-settings block in $prof; check 3 cannot
   analyse what it cannot extract"
for key in cre_font monospace_font cre_font_family_fonts; do
  grep -q "\"$key\"" "$ctl/fonts.block" ||
    fail "\"$key\" is not emitted from the font-settings branch, so the
   three font keys are no longer one field and one of them can go missing
   on its own -- which is exactly what shipped before"
  total=$(grep -c "\"$key\"" "$prof")
  inblock=$(grep -c "\"$key\"" "$ctl/fonts.block")
  [ "$total" = "$inblock" ] ||
    fail "\"$key\" appears $total times in $prof but only $inblock inside
   the font branch: there is a second, separately-gated copy"
done
grep -q 'if fonts' "$ctl/fonts.block" ||
  fail "the font-settings block is not gated on the fonts field"
echo "PASS: cre_font, monospace_font and cre_font_family_fonts are one branch"

# --- 4. The dead seed is gone and stays gone.  Any seed of this file has
#        to emit a Lua table, so the table opener is the signature; check 1
#        already covers anything that names the path.
if grep -q 'return {' "$rs"; then
  fail "reader-session.scm emits a Lua table again.  It is the wrong place
   for anything seeded: it runs AFTER activation, so a seed here is a no-op
   that looks alive -- which is precisely the 2026-08-05 failure."
fi
grep -q "does NOT seed KOReader's settings file" "$rs" ||
  fail "reader-session.scm lost the note explaining why it does not seed
   the profile; that note is what stops the dead copy being re-added"

# --- 5. The flavor registers the service.
grep -q '(service pinenote-koreader-profile-service-type)' "$sys" ||
  fail "pinenote-koreader-profile-service-type is not registered in the
   reader flavor, so nothing seeds the profile at all"
grep -q '#:use-module (pinenote services koreader-profile)' "$sys" ||
  fail "pinenote-reader.scm does not import (pinenote services koreader-profile)"
echo "PASS: reader-session seeds nothing; the flavor registers the service"

# --- 6. Generate the seed and read it.  Everything above is text; this is
#        the only check that proves the record actually produces the keys.
if command -v guix >/dev/null 2>&1; then
  # The test is a module with no top-level side effects, on purpose:
  # `guix build -L .' evaluates every .scm in this tree while looking for
  # package modules, and a test that ran there would print into an
  # unrelated build and exit 1 out of it.  So the runner that actually
  # calls it lives OUTSIDE the tree, here.
  cat > "$ctl/run-seed-tests.scm" <<'EOF'
(use-modules (pinenote scripts preflight test-koreader-profile-seed))
(exit (run-koreader-profile-seed-tests))
EOF
  guix repl -L "$repo_root" "$ctl/run-seed-tests.scm"
else
  echo 'SKIP: the generated seed was NOT evaluated -- no guix on PATH.'
  echo '      Checks 1-5 above are text analysis only: they prove the'
  echo '      record is the single declaration site, NOT that it serializes'
  echo '      to the right Lua.  Run locally: make koreader-profile-check'
fi
