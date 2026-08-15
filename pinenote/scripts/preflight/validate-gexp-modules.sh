#!/bin/sh
# Structural gate: a `use-modules' inside a shepherd service's start/stop
# lambda is a NO-OP, and in this codebase a silent one.
#
# WHY THIS GATE EXISTS.  A shepherd service file is COMPILED.  The gexp in
# a (start ...) field becomes a lambda in that compiled file, and a
# `use-modules' evaluated in a lambda BODY does not import anything into
# the environment the compiled toplevel's references were resolved
# against.  The form itself does not error -- it just changes nothing --
# so every subsequent call to an imported binding throws "Unbound
# variable".  In this tree those calls almost always sit inside a
# `catch #t' whose handler returns #f, which turns the throw into a
# plausible-looking value and the bug into a service that reports success
# while doing nothing.
#
# It has shipped TWICE.
#
#   pinenote/services/dmc.scm, live on the 2026-08-07 boot: `wait-ebc-idle'
#   never waited (a #f interrupt count reads as "no EBC, nothing to wait
#   for"), the mode selector always fell back to "normal" so the device
#   opted itself into the DDR drop, and every checkpoint field but devfreq
#   -- the one function using `read' rather than `read-line' -- logged
#   "none"/"absent".  Clean logs, wrong behaviour, for a week.
#
#   pinenote/services/frontlight.scm repeated it and failed its first boot
#   with "Unbound variable: scandir".
#
# Both now carry a comment saying never to do this again.  A comment is
# not a gate; this is.
#
# THE MATCHING RULE, and it is the whole job.  There are TWO CORRECT
# patterns here and only one bug, and a matcher naive enough to grep for
# "use-modules" flags all three -- which turns a green tree red on day one
# and then gets deleted for crying wolf.  So:
#
#   VALID 1 -- explicit module reference.  `(define scandir* (@ (ice-9 ftw)
#              scandir))' resolves at the reference, needs no import, and
#              is what dmc.scm and frontlight.scm use.  Contains no
#              `use-modules', so it is never seen by this gate.
#
#   VALID 2 -- the shepherd-service `modules' field.  `(modules '((ice-9
#              ftw) (ice-9 rdelim)))' puts the imports in the COMPILED
#              service file's toplevel, which is exactly the environment
#              the references resolve against.  usb-gadget.scm does this:
#              it splices a gexp that contains `use-modules' into its
#              start lambda AND declares the matching `modules' field.
#              That is correct and is NOT flagged.
#
#   BUG     -- `use-modules' reachable from a start/stop lambda on a
#              shepherd-service that declares NO `modules' field.
#
# WHAT IT DELIBERATELY DOES NOT FLAG, each for a reason:
#
#   * Activation gexps.  They are built into standalone scripts and run as
#     scripts, so `use-modules' in one works normally -- see
#     autosuspend.scm's `pinenote-autosuspend-activation'.  Activation
#     code is not inside a shepherd-service, so it falls outside the scan
#     by construction rather than by exemption.
#
#   * `program-file' / `computed-file' / `scheme-file' / `gexp->derivation'
#     bodies, wherever they appear -- including inside a start field, as
#     in usb-gadget.scm's ACM console service.  Those gexps become their
#     own top-level script; `use-modules' in one is ordinary and correct.
#
#   * Comments and string literals.  This matters more than it sounds:
#     the two services that were BITTEN by this bug now discuss
#     `use-modules' in comments sitting literally inside their start
#     lambdas.  A line-based grep flags the warning against the mistake as
#     the mistake.  The scanner below therefore lexes Scheme properly --
#     strings (with escapes and Guile's backslash-newline continuations),
#     line comments, block comments, and `#\(' style character literals.
#
#   * Whether the declared `modules' list actually COVERS the modules the
#     lambda imports.  Presence of the field is the gate; contents are not
#     checked, because a wrong list fails loudly at build or start time
#     whereas a missing field fails silently, and only the silent failure
#     needs a gate.
#
# INDIRECTION IS FOLLOWED.  usb-gadget.scm does not write `use-modules'
# inside its start lambda; it writes `#$(pinenote-usb-acm-gadget-program)'
# there, and the use-modules is in that top-level helper 240 lines away.
# A scan that only looked between `(start' and its closing paren would
# miss the entire real-world shape of this bug.  So the gate marks every
# top-level `define' whose gexp body contains a live `use-modules', takes
# the transitive closure over helper-to-helper references, and then treats
# a start/stop that names any of them as importing there.
#
# Scope is one file at a time: helpers are module-private in
# pinenote/services/, so no cross-file reference is followed.
#
# Usage: validate-gexp-modules.sh [service.scm ...]
#        (default: every pinenote/services/*.scm)
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../../.." && pwd -P)

if [ "$#" -eq 0 ]; then
    set -- "$repo_root"/pinenote/services/*.scm
fi

scan='
function issym(c) { return index(SYMCHARS, c) > 0 }

# ---- open paren: classify the form by its head symbol -----------------
function open_form(   j, ch, head, id, p) {
    j = i + 1
    head = ""
    while (j <= n) {
        ch = substr(line, j, 1)
        if (head == "" && (ch == " " || ch == "\t")) { j++; continue }
        if (issym(ch)) { head = head ch; j++ } else break
    }
    nopen++; tick++
    id = nopen
    p = (depth > 0) ? stack[depth] : 0
    depth++
    stack[depth] = id
    o_line[id] = NR; o_head[id] = head; parent[id] = p

    # A gexp that becomes its own script: use-modules inside is correct.
    shielded[id] = (index(STANDALONE, " " head " ") > 0) || (p ? shielded[p] : 0)
    # Nearest enclosing shepherd-service, and whether we are in one.
    ss_of[id] = (head == "shepherd-service") ? id : (p ? ss_of[p] : 0)
    # Nearest enclosing start/stop FIELD of a shepherd-service.
    if ((head == "start" || head == "stop") && p && o_head[p] == "shepherd-service")
        sf[id] = id
    else
        sf[id] = (p ? sf[p] : 0)
    # Nearest enclosing top-level define.
    td[id] = (depth == 1 && head == "define") ? id : (p ? td[p] : 0)

    # (define (NAME args) ...) -- name comes from the first child form.
    if (p && o_head[p] == "define" && !(p in dname) && head != "") dname[p] = head
    # The field that makes the difference.
    if (head == "modules" && p && o_head[p] == "shepherd-service") ss_hasmod[p] = 1
    # (provision (NAME)) -- for a human-readable report.
    if (p && o_head[p] == "provision" && ss_of[p] && !(ss_of[p] in ss_name))
        ss_name[ss_of[p]] = head

    if (head == "use-modules")
        note_use(id, o_line[id])
    else if (head != "")
        note_ref(head, id, o_line[id])

    i = (head == "") ? i + 1 : j
}

function close_form(   id) {
    tick++
    if (depth > 0) { id = stack[depth]; depth-- }
    i++
}

# ---- bare symbol ------------------------------------------------------
function read_symbol(   j, sym, p) {
    j = i; sym = ""
    while (j <= n && issym(substr(line, j, 1))) { sym = sym substr(line, j, 1); j++ }
    tick++
    p = (depth > 0) ? stack[depth] : 0
    # (define NAME value) -- name is the first bare symbol.
    if (p && o_head[p] == "define" && !(p in dname)) dname[p] = sym
    if (p) note_ref(sym, p, NR)
    i = j
}

# ---- classification ---------------------------------------------------
function note_use(ctx, ln) {
    if (shielded[ctx]) return
    if (sf[ctx]) {                       # inside a start/stop lambda: the bug
        nviol++; v_sf[nviol] = sf[ctx]; v_line[nviol] = ln
    } else if (td[ctx] && !ss_of[ctx]) { # a helper gexp that imports
        unsafe_def[td[ctx]] = 1
    }
}

function note_ref(nm, ctx, ln) {
    if (nm == "" || shielded[ctx]) return
    if (sf[ctx]) {                       # named from a start/stop lambda
        nref++; r_name[nref] = nm; r_sf[nref] = sf[ctx]; r_line[nref] = ln
    } else if (td[ctx] && !ss_of[ctx]) { # helper -> helper edge
        nedge++; e_td[nedge] = td[ctx]; e_name[nedge] = nm
    }
}

function report(sfid, ln, what,   ss, svc) {
    ss = parent[sfid]
    if (ss_hasmod[ss]) return            # VALID 2: the modules field is there
    svc = (ss in ss_name) ? ss_name[ss] : "(unnamed)"
    printf "FAIL: %s:%d: %s reaches the (%s ...) of shepherd-service %s,\n", \
        disp, ln, what, o_head[sfid], svc > "/dev/stderr"
    printf "      which declares no (modules ...) field.  The service file is\n" \
        > "/dev/stderr"
    printf "      COMPILED: this import does nothing, and every reference it was\n" \
        > "/dev/stderr"
    printf "      meant to satisfy will throw Unbound variable -- silently, if it\n" \
        > "/dev/stderr"
    printf "      sits in a catch #t.  Fix with (modules %s), or resolve each\n", \
        "'"'"'((the mod) ...)" > "/dev/stderr"
    printf "      binding explicitly: (define f (@ (the mod) f)).\n" > "/dev/stderr"
    bad = 1
}

BEGIN {
    SYMCHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!$%&*/:<=>?^_~+-.@"
    # Forms whose body is built into a standalone script or file.
    STANDALONE = " program-file computed-file scheme-file gexp->derivation mixed-text-file "
    depth = 0; instr = 0; inblock = 0; nopen = 0; tick = 0
    nviol = 0; nref = 0; nedge = 0; bad = 0
}

{
    line = $0; n = length(line); i = 1
    while (i <= n) {
        c = substr(line, i, 1)
        if (inblock) {                                   # #| ... |#
            if (c == "|" && substr(line, i + 1, 1) == "#") { inblock = 0; i += 2 }
            else i++
            continue
        }
        if (instr) {                                     # "..." incl. \ escapes
            if (c == "\\") i += 2
            else if (c == "\"") { instr = 0; i++ }
            else i++
            continue
        }
        if (c == ";") break                              # line comment
        if (c == "#") {
            nx = substr(line, i + 1, 1)
            if (nx == "|") { inblock = 1; i += 2; continue }
            if (nx == "\\") {                            # #\c , #\space , #\)
                i += 3
                while (i <= n && issym(substr(line, i, 1))) i++
                continue
            }
            if (nx == "$" || nx == "~") {                # gexp escapes: #$ #~ #$@
                i += 2
                if (substr(line, i, 1) == "@") i++
                continue
            }
            i++
            continue
        }
        if (c == "\"") { instr = 1; i++; continue }
        if (c == "(" || c == "[") { open_form(); continue }
        if (c == ")" || c == "]") { close_form(); continue }
        if (issym(c)) { read_symbol(); continue }
        i++
    }
}

END {
    if (depth != 0) {
        printf "FAIL: %s: unbalanced parentheses (ended at depth %d) --\n", disp, depth \
            > "/dev/stderr"
        printf "      the scanner cannot be trusted on this file, so it refuses to\n" \
            > "/dev/stderr"
        printf "      pass it.  Fix the file or the scanner, not this message.\n" \
            > "/dev/stderr"
        exit 1
    }
    for (id in unsafe_def) if (id in dname) unsafe[dname[id]] = 1
    # Transitive closure: a helper that names an importing helper imports too.
    changed = 1
    while (changed) {
        changed = 0
        for (k = 1; k <= nedge; k++)
            if ((e_name[k] in unsafe) && (e_td[k] in dname) && !(dname[e_td[k]] in unsafe)) {
                unsafe[dname[e_td[k]]] = 1; changed = 1
            }
    }
    for (k = 1; k <= nviol; k++)
        report(v_sf[k], v_line[k], "a (use-modules ...) form")
    for (k = 1; k <= nref; k++)
        if (r_name[k] in unsafe)
            report(r_sf[k], r_line[k], "the importing gexp helper `" r_name[k] "'"'"'")
    exit (bad ? 1 : 0)
}
'

fail=0
checked=0
for service in "$@"; do
    if [ ! -r "$service" ]; then
        printf 'FAIL: cannot read %s\n' "$service" >&2
        fail=1
        continue
    fi
    checked=$((checked + 1))
    disp=${service#"$repo_root"/}
    awk -v disp="$disp" "$scan" "$service" || fail=1
done

if [ "$checked" -eq 0 ]; then
    printf 'FAIL: no service files to scan\n' >&2
    exit 1
fi

if [ "$fail" -eq 0 ]; then
    printf 'PASS: %d service file(s): no use-modules reaches a shepherd-service\n' "$checked"
    printf '      start/stop lambda without a (modules ...) field.  Explicit\n'
    printf '      (@ (mod) binding) references, declared modules fields, activation\n'
    printf '      gexps, and program-file/computed-file bodies are all correct and\n'
    printf '      are deliberately not flagged.\n'
fi
exit "$fail"
