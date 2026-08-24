#!/bin/sh
# Gate: the build-time timezone knob resolves, and above all REFUSES a
# name that would ship a wrong clock quietly.
#
# WHY THIS NEEDS A GATE.  Guix never opens the timezone string.  It goes
# into gnu/system.scm as
#
#   ("localtime" ,(file-append tzdata "/share/zoneinfo/" timezone))
#
# i.e. pure concatenation.  A typo'd zone evaluates fine, builds fine,
# images fine, deploys fine -- and produces a DANGLING /etc/localtime, at
# which point glibc falls back to UTC and says nothing.  The device then
# looks exactly like a device nobody configured, and the only signal is a
# human noticing the clock after a full build-and-deploy cycle.  That is
# the expensive-and-silent shape this repo exists to catch offline, so
# the refusal lives in pinenote/timezone.scm and this gate pins it there.
#
# It also pins the two halves of the mechanism the docs promise -- the
# Makefile's `-include local.mk' and .gitignore's /local.mk -- because a
# per-checkout knob that can be committed is a different, worse knob.
#
# Two layers, and the second announces itself when it cannot run:
#   * text gates over base.scm/Makefile/.gitignore -- pure shell, always;
#   * behavioural gates that actually load (pinenote timezone) under
#     guile.  `make timezone-check' supplies guile; run bare without one
#     and this says SKIP rather than passing on silence.
#
# Usage: validate-timezone-selection.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)

module=$repo_root/pinenote/timezone.scm
base=$repo_root/pinenote/systems/base.scm
makefile=$repo_root/Makefile
gitignore=$repo_root/.gitignore

fail() { echo "FAIL: $1" >&2; exit 1; }

for f in "$module" "$base" "$makefile" "$gitignore"; do
  [ -r "$f" ] || fail "cannot read $f"
done

# ----------------------------------------------------------- text gates

# 1. base.scm must take the timezone from the module, not from a literal.
#    The whole point is that every flavor shares one value; a re-hardcoded
#    string here would restore the bug while the module still looked
#    wired up.
grep -qF '(timezone %pinenote-timezone)' "$base" ||
  fail "base.scm no longer sets (timezone %pinenote-timezone)"

if grep -q '(timezone *"' "$base"; then
  fail "base.scm hard-codes a timezone string again -- the build-time knob
   (pinenote/timezone.scm) is then bypassed for every flavor inheriting it"
fi

grep -qF '(pinenote timezone)' "$base" ||
  fail "base.scm does not import (pinenote timezone)"

# 2. The default must stay Etc/UTC.  Changing it is a real decision with a
#    written argument behind it (pinenote/timezone.scm), not a drive-by.
grep -qF '(define %wilkbook-default-timezone "Etc/UTC")' "$module" ||
  fail "the default timezone is no longer Etc/UTC; if that is deliberate,
   update this gate and the argument in pinenote/timezone.scm together"

# 3. The refusal must end the process with primitive-exit.  The
#    behavioural half below catches `error' (it leaves a backtrace after
#    the message) but CANNOT catch plain `exit': Guile's `exit' is `quit',
#    which throws and looks identical under a bare guile -- and is
#    swallowed by guix exactly like `error' is.  A text gate is the only
#    thing that sees that difference offline.
grep -qF '(primitive-exit 1)' "$module" ||
  fail "pinenote/timezone.scm no longer refuses with (primitive-exit 1).
   Guile's 'exit' throws 'quit and 'error' throws too; guix catches both,
   keeps going, and ends with a misleading '%pinenote-timezone: unbound
   variable' pointing at base.scm.  Only primitive-exit is uncatchable."

# 4. The per-checkout half of the mechanism: honoured by the Makefile, and
#    unable to reach a commit.
grep -q '^-include local.mk' "$makefile" ||
  fail "Makefile no longer -includes local.mk, so the documented persistent
   choice (export WILKBOOK_TIMEZONE = ...) silently does nothing"

grep -q '^/local.mk$' "$gitignore" ||
  fail ".gitignore no longer carries /local.mk -- a per-checkout build flag
   file that can be committed is not per-checkout"

echo "PASS: timezone wiring (base.scm, default, local.mk) is intact"

# ---------------------------------------------------- behavioural gates

if ! command -v guile >/dev/null 2>&1; then
  echo "SKIP: timezone resolution/refusal gates -- no guile on PATH."
  echo "      Run 'make timezone-check', which supplies one, before"
  echo "      counting this as a green result."
  exit 0
fi

# Auto-compilation would write .go files into the user's cache and print
# warnings that read like failures; the module is small and interprets fine.
GUILE_AUTO_COMPILE=0
export GUILE_AUTO_COMPILE

expr='(begin (use-modules (pinenote timezone)) (display %pinenote-timezone))'

# Each probe runs in a subshell so the variable under test never leaks
# into the next one.
resolve() {
  ( WILKBOOK_TIMEZONE=$1; export WILKBOOK_TIMEZONE
    guile -L "$repo_root" -c "$expr" )
}

resolve_unset() {
  ( unset WILKBOOK_TIMEZONE
    guile -L "$repo_root" -c "$expr" )
}

expect_ok() {
  want=$1
  got=$(resolve "$2" 2>/dev/null) ||
    fail "WILKBOOK_TIMEZONE='$2' was refused; expected it to resolve to $want"
  [ "$got" = "$want" ] ||
    fail "WILKBOOK_TIMEZONE='$2' resolved to '$got'; expected '$want'"
}

expect_refused() {
  if out=$(resolve "$1" 2>&1); then
    fail "WILKBOOK_TIMEZONE='$1' was ACCEPTED (resolved to '$out'); this is
   exactly the silent-wrong-clock case the gate exists to prevent"
  fi
  # A refusal has to be legible on the way past, not merely non-zero.
  printf '%s' "$out" | grep -q 'WILKBOOK_TIMEZONE' ||
    fail "WILKBOOK_TIMEZONE='$1' was refused without naming the variable in
   the message; an unexplained build failure is its own bug"
  # And the explanation must be the LAST thing said, which is really a
  # test that the module exits rather than throws.  A throw leaves a
  # Guile backtrace after the message here, and -- the case that actually
  # matters -- `guix system build' catches it, carries on, and ends with
  # "%pinenote-timezone: unbound variable / hint: Did you forget
  # (use-modules (pinenote timezone))": a confident, wrong diagnosis
  # pointing at base.scm, with the real reason scrolled off above it.
  # Both were observed while writing this gate.  Only the tail assertion
  # reproduces under a bare guile, so that is what is pinned.
  last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  case $last in
    *"Unset WILKBOOK_TIMEZONE"*) ;;
    *) fail "WILKBOOK_TIMEZONE='$1' was refused, but the last line of output
   was '$last' rather than the explanation.  That is the throw-instead-of-
   primitive-exit regression: under guix the refusal then ends in a
   misleading 'unbound variable' hint pointing at base.scm." ;;
  esac
}

# Unset means the default: a plain checkout builds exactly what it built
# before this knob existed.
unset_got=$(resolve_unset 2>/dev/null) ||
  fail "an unset WILKBOOK_TIMEZONE failed to resolve at all"
[ "$unset_got" = "Etc/UTC" ] ||
  fail "an unset WILKBOOK_TIMEZONE resolved to '$unset_got'; expected Etc/UTC"

# Empty and whitespace-only read as unset.  An exported-but-blank variable
# is the shape a half-edited local.mk leaves behind, and it must not turn
# into a build failure.
expect_ok "Etc/UTC" ""
expect_ok "Etc/UTC" "   "

# Surrounding whitespace is trimmed rather than passed through: a stray
# space off a local.mk line would otherwise dangle /etc/localtime.
expect_ok "Etc/UTC" " Etc/UTC "

# Malformed names are refused on syntax alone, no database required.
expect_refused "../../etc/passwd"       # walks out of the zoneinfo tree
expect_refused "Europe/../../etc/passwd"
expect_refused "/Etc/UTC"               # leading slash
expect_refused "Etc/UTC/"               # trailing slash
expect_refused "Etc//UTC"               # empty component
expect_refused "Europe/Dub lin"         # space
expect_refused "Etc/UTC; rm -rf /"      # shell-ish junk

echo "PASS: timezone resolution and malformed-name refusal"

# The existence half needs a zoneinfo database.  Announce it when there is
# none, rather than reporting a green that never looked anything up.
# Clear WILKBOOK_TIMEZONE for this probe the way resolve_unset does.  The
# module's top-level %pinenote-timezone primitive-exits on an unusable
# value, so an operator with a typo'd local.mk exported -- exactly the
# state this gate exists to catch -- would make this probe return empty
# and the script would SKIP the unknown-zone check instead of running it.
zoneinfo=$( ( unset WILKBOOK_TIMEZONE
              guile -L "$repo_root" -c \
                '(begin (use-modules (pinenote timezone))
                        (display (or (zoneinfo-directory) "")))' ) 2>/dev/null || true)

if [ -z "$zoneinfo" ]; then
  echo "SKIP: unknown-zone refusal -- no zoneinfo database on this host"
  echo "      (TZDIR unset, no /usr/share/zoneinfo or /etc/zoneinfo, and"
  echo "      /etc/localtime is not a symlink into one).  Syntactically"
  echo "      valid nonsense would be accepted here."
  exit 0
fi

# A well-formed name that is not a zone: the exact input that produces a
# dangling /etc/localtime and a device quietly running UTC.
expect_refused "Europe/Nowhere"
# A directory inside the database is not a zone either.
expect_refused "Europe"

# ... and a real zone still passes, so the gate is not just refusing
# everything.  Etc/GMT has been in every database for decades, so this
# does not quietly become a tzdata-version dependency.
expect_ok "Etc/GMT" "Etc/GMT"

echo "PASS: unknown-zone refusal against $zoneinfo"
