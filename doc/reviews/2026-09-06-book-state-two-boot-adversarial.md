# Book State two-fresh-boot runner v1 — adversarial review — 2026-09-06

## Verdict

**Reject frozen v1 as a future real-run authority.**  Its source-only model has
the right two-boot shape, and its timeout/OFD/process-record seam is materially
stronger than a whole-campaign timeout.  However, four source blockers precede
any legitimate VM run:

1. Guile code can execute before source authentication, and source/helpers can
   be changed by their owner after the mode-only authentication check.
2. The authorization and image-review chain has no trust anchor beyond hashes
   supplied by the same caller whose files are being checked.
3. The success checker accepts an otherwise valid console containing an extra
   generic `FAIL:` line.
4. Production integration is implemented by twelve `module-set!` operations
   rather than an explicit authenticated hook interface.

There is also a now-known image-binding incompatibility.  V1 pins the old
`nfd049…-system.drv` and guest-v3 manifest.  It cannot authenticate the pending
complete guest-v4 successor and its `qb9s3…-system.drv`; that update must be an
explicit reviewed metadata successor, not a local substitution.

No QEMU, ARM guest, runsc, KOReader, image build, mount, network, or hardware
was used in this review.  Consequently this report does **not** prove guest
execution, clean powerdown, SQLite durability, sandbox isolation, or semantic
persistence.

## Authenticated review authority

I reviewed only the immutable packet named by the request, not mutable
`pinenote/tools/book-state-qemu/two-boot/` state:

```text
bd27c96987ae17e0ee6315ea5a75dffd53c70f6b9fdcfcfc516a591faf231bf2  PACKET-EVIDENCE.sha256
427c334f7dc0932de73a6131902350815348524febd9d4cdd0f8ce01172b93fa  source/SOURCE-MANIFEST.sha256
01c2507299820833cdc95ba7ce6ebbeb268305e6aea3ae50e952207e32525e46  FROZEN-HOST-TEST.log
c014fc9aba006d6183a4428a4dab886b5c5d4daa6f41020a04cb7a6dafe3a70c  REVIEW-REPORT.md
```

The 68-entry packet manifest passed strict verification.  The packet has 69
regular files including that self-excluded manifest; `source/` has 59 regular
files including its 58-entry self-excluded manifest.  There are no symlinks,
all directories are mode 0500, 68 files are mode 0400, and the one test
entrypoint is mode 0500.

The six accepted production-parent hashes and all three exact forward patches
reproduced.  The accepted guardian and prior reviews remain:

```text
0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca  accepted disposable-qemu.scm
0c23c2e61165759586779548b0f39fca217d51627e9f6db9d0c1315f5cbc0b68  guardian adversarial review
f0cedbe6a6b44b37a03b663c7168d6880520ae6cd592427665756186fbc95db4  guest deadline adversarial review
```

Independent evidence for this review is frozen at:

```text
/tmp/opencode/book-state-qemu-two-boot-v1-independent-evidence.S5DxYk
c7a944a111ae58446c251be7c60cda8dc09c7dc67fa00a3d77a5ccd5ab112d55  EVIDENCE.sha256
```

## What passed

### Source-only host gate

I ran the supplied `run-host-tests.sh` once, bounded, from the frozen source.
It exited 0 with:

- 23 warning-enabled Scheme compilations;
- six accepted parent hashes and three exact successor patches;
- 72/72 Scheme assertions;
- accepted single, cross, payload, and final evidence models; and
- 15/15 supplied semantic/timeout/identity/mode mutations rejected.

This was a native fixture run only.  It did not invoke any guest component.

### Per-boot deadline binding

`run-two-boot.scm` constructs each `one-boot.scm` invocation through
`bind-mandatory-outer-timeout-arguments`, which appends exactly:

```text
--timeout-seconds 360 --term-grace-seconds 5
```

`one-boot.scm` independently calls
`assert-mandatory-outer-timeout-arguments` before entering the accepted outer
supervisor.  Duplicate options, zero, alternate values, and caller overrides
are rejected.  There is no 720-second whole-campaign substitute.  Boot 2 is a
`let*` successor and is unreachable if boot 1 raises or times out.

The finite native guardian fixture again returned timeout status 124, escalated
and reaped the recorded child and stubborn writer, reaped the guardian, and
left an unrelated process alive.  This verifies the accepted host-process
model and its source binding.  It still does not prove that an actual QEMU
process ran beneath that binding.

### State-writer and process lifetime

The source nests one state-volume writer window around one QEMU handoff and a
CLOEXEC anchor.  The anchor remains live while the 420-second owner call
returns or is killed and while recorded inner guardians, descendants, and run
roots are observed gone.  The writer window unwinds before single-boot semantic
checking and before boot 2 can begin.  The same accepted 64 MiB ext4 state
identity is reused; fresh launch roots, root overlays, coordinator, QEMU,
KOReader, and private UI proxy are constructed for each boot.

The graph is exact and unpaused.  It donates the state image only by inherited
OFD, contains no NIC/TCP forwarding or generic host share, and does not put the
fixed namespaces or A/B text into QEMU arguments.  The controller hashes and
copies the state image but has no backend namespace/key API.

### Evidence joins and corrected final-checker staging

The checker requires the two distinct boot IDs, process identities and run
roots; one state inode; a three-link state hash chain; the same kernel, initrd,
config, baseline, and normalized QEMU graph; fixed Guile/Python namespaces;
versions 1 then 2; receipts 2 then 4; boot-1 A save; and boot-2 A recovery and
paint before B save.  A summary PASS token cannot replace the raw origin/UI
records.

The final-checker staging correction is present.  Its three process records are
created under the guarded checker root, the checker returns and is reaped, and
only then are records copied into retained evidence.  They are excluded from
`PAYLOAD.sha256` and included in the later `EVIDENCE.sha256`.

My independent checker controls accepted the unchanged payload and final
models, then rejected all ten intended mutations:

- swapped boot consoles;
- reused cross-boot process identity;
- missing boot-2 recovered-A marker;
- A substituted for the new B value;
- wrong language namespace;
- unexpected UI stage;
- forged extra paint counter;
- a fake PASS replacing a raw origin marker;
- a final-checker record inserted before payload sealing; and
- an authenticated final-checker identity aliased to a boot process.

## Blocking findings

### BTQ-1 — Guile bootstrap executes before authentication

`run-two-boot.scm` imports all campaign modules at lines 4–22.  Its source-root
verification does not occur until line 1070.  `one-boot.scm` has the same
shape: imports happen on load and its check is at line 328.  The production
entrypoint's initial Guile, Guile modules, and gcrypt modules therefore execute
before any source or bundle authority has been established.

`run-host-tests.sh` does create a private `HOME` and `XDG_CACHE_HOME` before its
Guile calls, but it inherits `GUILE_LOAD_PATH`, `GUILE_LOAD_COMPILED_PATH`, and
`GUILE_EXTENSIONS_PATH`.  I placed a compiled `(two-boot sequential)` in an
inherited compiled path.  It executed instead of the frozen source while the
supplied sequential suite still reported all 4/4 expected passes.  A second
probe loaded a forged `(two-boot source-gate)` before production `main` even
began.

Simply clearing those variables is not a usable bootstrap: the sanitized probe
then failed to resolve `(gcrypt base16)`, because the packet supplies no pinned
gcrypt module/load-path closure for the initial interpreter.

This is not only a cache concern.  The source and prospective bundle are
caller-owned and merely lack write bits.  Their owner can restore write bits
after a successful check.  A same-UID probe passed
`verify-two-boot-source-root!`, then `chmod`ed and changed the checked helper.
The real runner later path-opens `one-boot.scm` and `check-evidence.py`, so their
authenticated bytes are not retained across that gap.

**Required correction:** start from an exact pinned Guile/gcrypt bootstrap with
explicit load and compiled-load paths and cleared ambient variables, then
authenticate before loading campaign modules.  Retain exact opened
descriptors, or copy the authenticated source/helper closure into a separately
owned guarded immutable root, and execute from that retained identity.  A
mode-bit check on caller-owned files is not post-check immutability.

### BTQ-2 — authorization and image review are caller-self-asserted

`authenticate-two-boot-authorization` compares the authorization file with
`--authorization-sha256`, but that hash is supplied by the same command line.
The authorization then supplies the bundle manifest hash.  No pinned signer,
review manifest, authorization identity, or accepted bundle identity anchors
that chain.

The bundle's `status=independently-reviewed-image`, `image-review-sha256`, and
`guest-review-sha256` are data inside that same bundle.  The review hashes need
only be lexically valid.  The BSG-3 build-source and snapshot hashes need only
be valid and different from the old incomplete hashes.  The rootfs, initrd,
and config are authenticated against the caller's bundle manifest, but not an
externally accepted image manifest.

My non-executing probe created a fresh authorization, supplied its freshly
computed hash, named an arbitrary bundle-manifest hash, and was accepted by the
authorization function.  I did not construct a bootable bundle or invoke the
campaign.

Thus “no authorization/bundle is included” is a packet fact, not a fail-closed
source guarantee.  A local caller can manufacture both records.  Later
semantic checking may reject a bad guest, but only after unauthorized VM
execution has already occurred.

**Required correction:** bind the runner to an independently accepted exact
authorization and exact reviewed bundle/capsule identity, or verify a signed,
time-bounded authorization against a public key pinned by the reviewed source.
Do not treat a caller-supplied expected hash or an in-bundle review label as the
authority it is supposed to authenticate.

### BTQ-3 — an extra generic console failure is accepted

`check_console` rejects five fixed byte fragments and strictly checks the
Book-State marker subset, one kernel lifetime, one shutdown request, and one
ordered canonical `reboot: Power down`.  It does not reject generic `FAIL:`
lines elsewhere in the console.

I appended:

```text
FAIL: independent injected console failure
```

to an otherwise valid boot-1 console, resealed the payload, and ran the actual
checker.  It exited 0 and printed the final PASS line.  This reproduces the
same class of success/failure ambiguity that invalidated the old guardian
checker, although the mechanism here is omission rather than a prefix-only
exemption.

**Required correction:** define and enforce a closed success-console grammar,
including exact cardinality/order for the timestamp-aware shutdown lines, and
reject every failure production that can appear in a success payload.  Add
this exact counterexample to the checker suite.

### BTQ-4 — production wiring mutates the accepted module

`one-boot.scm` performs six `module-set!` substitutions and six restorations for
the accepted outer's environment, root guardian, QEMU graph, process runner,
console validator, and cleanup function.  This is production control flow, not
test-only instrumentation.

The frozen parent and generated patch make the mutation reviewable, and the
wrappers mostly delegate to captured accepted functions.  Nevertheless it is
not an explicit accepted integration API and violates the required “no
`module-set!` wiring” boundary.  It also makes authority depend on mutable
module bindings after load.

**Required correction:** extend the pinned guardian/reader outer with a closed,
typed set of explicit hooks, authenticate that exact successor patch, and call
the resulting API without mutating module globals.

### BTQ-5 — pending guest-v4 cannot satisfy v1 metadata

This packet intentionally pins:

```text
f6331a3d43f9c5be60aa630acc5eabb0eb99c50bea9f07708e3a9b595f38f0fb  guest-v3 source manifest
/gnu/store/nfd0492jbf77bxyp9il9hfv9ck74icgd-system.drv
```

The separately frozen complete guest-v4 candidate reported during this review
has these coordination identities (reported here, not independently audited by
this review):

```text
7c71465c498449e96f63d943f392a2201cf6afad9b90e5ef110f9c1a46e77676  source manifest
1426d26f002b28a14b0e9913a8c6f39a088f2ec937d84ced28e43a22ebc3c6b4  capsule
fbc5903f08046440d4a3b4f2d802f17dd496b6e90d71ba37ae032a54cada6934  snapshot
6c19a6abfbf6758d057fa49b8839183b5e767139687a5b1d9b120df9cd15821a  evidence
/gnu/store/qb9s3c1p4xwzfy0i6j2qn084rc2g4wf8-system.drv
```

The derivation change is reported as solely the expanded embedded source
manifest; guest authority `688b2a9d…`, system source `ee43fd58…`, FD adapter
`15f8ec5c…`, kernel `334l…`/Image `5435…`, and gVisor `djgy…` are reported
unchanged.

I did not re-review that guest closure; its independent review is still active.
If it is accepted, a two-boot successor must explicitly pin its complete source
manifest, capsule/snapshot/evidence identities, and `qb9s3…` derivation while
retaining the unchanged semantic/deadline identities.  V1 must fail it rather
than silently substituting those values, and it does.

## Required successor proof

Before any image-bound run, publish and independently review a successor that:

1. closes BTQ-1 through BTQ-4;
2. pins the accepted complete guest/image authority, including the exact new
   system derivation and reviewed bundle manifest;
3. replays the finite host gate from the authenticated bootstrap;
4. retains the exact per-boot `360/5` guardian binding, writer/OFD lifetime,
   closed QEMU graph, and corrected final-checker staging; and
5. independently exercises the actual QEMU process group for each boot.

Only after those source and image gates pass can two fresh real guests establish
the intended claim: boot 1 commits A and shuts down cleanly; boot 2 reads and
paints that retained A before saving B, using only the same dedicated state
image as writable cross-boot input.

---

# V2 targeted recheck — 2026-09-06

## V2 verdict

The preceding v1 rejection remains an unchanged byte prefix with SHA-256
`0a825f5ed151c6f03b97c41a227919e9a28891a35056af963d680f3a5b101560`.

**BTQ-2, BTQ-3, and BTQ-4 are closed by frozen v2.  BTQ-1 remains open due to
one concrete pre-authentication `LD_PRELOAD` counterexample.**  Therefore v2 is
still rejected as the source authority for a real QEMU run.  This is a narrow
bootstrap defect; it does not reopen the fixed image-binding design, console
grammar, typed-hook seam, timeout nesting, or unchanged OFD/lifetime sources.

The stale-v3 metadata problem is also corrected on the source side: v2 rejects
the old target and records guest-v4 only as a provisional input.  Production is
deliberately `unavailable` pending the separately active guest-v5 denial work,
an image build/review, and a later exact source-pinned image binding.  That is an
appropriate future acceptance gate, not another authorization-framework defect.

No QEMU, runsc, ARM, KOReader, image or package build, mount, network, hardware,
or device generation was exercised.  STEP 1 semantic persistence and STEP 2
device-generation work remain downstream of the remaining source/image gates.

## V2 authority and evidence

I treated only the frozen v2 packet as authority:

```text
4e4418da13f201326ad7202852466836d2f2212c386a048d3e543858c87491c2  PACKET-EVIDENCE.sha256
8e6ba1dee773ffa61be318c5a460d97355486a6f32917ac704b87d6383888e32  source/SOURCE-MANIFEST.sha256
55faa73419ee571611613810673546c19e90032f67791240dab4ae14964f2dce  source/RUNTIME-SOURCE-MANIFEST.sha256
d7ec08d94ad01d917b9e39f574f5803d068a79ce4935988f8389735953114c7b  FROZEN-PACKET-REPLAY.log
779e9dce41ba860b3ba223ed449ff0386356056bec12a746cd54d1545bc755fe  FROZEN-HOST-TEST.log
0a825f5ed151c6f03b97c41a227919e9a28891a35056af963d680f3a5b101560  V1-REJECTION-REPORT.md
```

The complete packet manifest passed strict verification.  The 23-entry runtime
manifest is internally exact and contains every project source later imported,
loaded, staged, or executed by the intended campaign.  It excludes the test
fixture namespace.

Independent v2 evidence is frozen at:

```text
/tmp/opencode/book-state-qemu-two-boot-v2-independent-evidence.UW3S71
14388667a554d0bc743421a8d6ffbd9ee369c6e1ffcadcaedfa81f98de7f258b  EVIDENCE.sha256
```

## Finite replay

I ran the supplied frozen host gate exactly once.  It exited 0 with:

- 26 warning-enabled Scheme compilations;
- six exact accepted parent hashes and three exact forward/inverse patches;
- 73/73 Scheme assertions;
- five supplied bootstrap-boundary checks;
- twelve typed-hook checks; and
- accepted single/cross/payload/final models plus 21/21 rejected semantic,
  failure, timeout, identity, and mode mutations.

My independent controls added eight bootstrap counterexample checks and thirteen
fixed-binding/failure-grammar/typed-hook checks.  All behaved as expected.  The
separate `LD_PRELOAD` control then reproduced the one remaining BTQ-1 failure.

## BTQ-1 — partially corrected, still open

### What v2 fixed

`run-two-boot.sh` and `bootstrap.py` form an explicit, finite trust base.  The
launcher uses pinned Bash `-p`; pins Bash, coreutils, Python, Guile,
Guile-gcrypt, and Guix module outputs; gives Python `-B -I -S`; and replaces the
later process environment with private HOME/XDG/TMP paths, an empty PATH, exact
Guile source/compiled paths, and an empty extensions path.

Python pins `RUNTIME-SOURCE-MANIFEST.sha256`, opens each of its 23 entries with
`O_NOFOLLOW|O_CLOEXEC`, reads and hashes stable held-descriptor bytes, and copies
those bytes into a fresh private retained capsule.  The first Guile process
loads project modules only from that capsule and pinned Guile closures.  It
starts the accepted run-root guardian before loading retained
`run-two-boot.scm`.  Later one-boot, checker, coordinator, plugin, and module
paths all name retained copies rather than caller source.

The original v1 attacks are closed:

- forged ambient `(two-boot source-gate)` source did not execute;
- forged compiled `(two-boot sequential)` did not execute;
- caller HOME cache, Guile extension paths, and `BASH_ENV` did not execute;
- pinned gcrypt resolved under the clean environment; and
- after the 23 retained files were authenticated, changing the caller's
  `run-two-boot.scm` did not execute the changed helper.  The retained helper
  reached the fixed unavailable-binding error and its guarded capsule was
  removed.

### Remaining counterexample: dynamic loader injection before `env -i`

The static Bash itself is not affected, but line 7 unsets only `BASH_ENV`,
`ENV`, `CDPATH`, and `GLOBIGNORE`.  The launcher then invokes pinned coreutils
before the clean `$ENV -i` boundary at line 121.  Those coreutils executables
are dynamically linked, so they inherit caller `LD_PRELOAD`.

I supplied a harmless shared-library constructor through `LD_PRELOAD`.  To
exclude the test harness itself, the constructor wrote its canary only when
`/proc/self/exe` was inside the exact pinned coreutils output.  The launcher
later failed at the expected source-pinned unavailable image binding, but the
canary had already recorded execution in pinned `sha256sum`, `mktemp`, `stat`,
`cp`, `chmod`, `mkdir`, and `env` processes.  The first records were from
`sha256sum`, during the launcher's purported pre-use dependency checks.

This is caller-controlled code execution before source authentication.  It
requires neither root nor a forged Guix-store object, and arbitrary constructor
code need not preserve the later fail-closed result.  Consequently that later
result cannot yet authorize a real campaign.

**Required narrow correction:** before the first dynamically linked external
program, use static-Bash builtins to clear dynamic-loader injection variables,
at minimum the executable-code paths such as `LD_PRELOAD` and `LD_AUDIT`, or use
an entirely static pre-authentication helper closure.  Run every pre-auth
external dependency under that clean boundary and pin this exact canary as a
negative regression.  No generic PKI, privileged-host, or hostile-root claim is
needed.

## BTQ-2 — closed at the source/fixed-binding boundary

V2 removes the authorization module, caller authorization hash, in-bundle review
status, and generic production binding parameter.  Production imports the
runtime-manifest-pinned `(two-boot image-binding)` and calls
`require-production-image-binding!` before canonicalizing or opening the caller
bundle path.

The current binding has status `unavailable`.  Every unknown bundle, initrd,
rootfs, config, runtime-tool, and review identity is the symbol `unavailable`,
not a plausible hash.  A regular caller file containing invented review labels
and hashes still produced the exact unavailable-binding error, proving the
bundle object had not yet needed to pass directory validation.  An ambient
compiled module claiming `available` also did not load through the retained
runtime boundary.

The synthetic available binding is confined to
`tests/modules/two-boot/bundle-test-fixture.scm`, absent from the 23-file runtime
capsule, and not selectable by production CLI or environment.  Its private test
API establishes only that future `BUNDLE.scm` metadata must equal a source-pinned
binding field-for-field.

Subject to closing BTQ-1, this consumer is fit for a later small reviewed source
successor that pins the exact accepted guest-v5 capsule, image-review evidence,
BUNDLE manifest, boot artifacts, package outputs, and executable hashes.  The
normal unavailable result is source fail-closed evidence, not actual-run proof.

## BTQ-3 — closed

The actual production `check-evidence.py` now removes only canonical printk
timestamp framing and rejects line-start failure productions.  Independent
payloads proved rejection of:

- the original `FAIL: independent injected console failure` after power-down;
- `FAIL:` before the final result;
- space/tab-prefixed `FAIL:`; and
- canonical printk-timestamp-prefixed `FAIL:`.

A quoted non-record payload line containing `"FAIL:"` remained accepted, so the
fix is not an indiscriminate substring ban.  Guest failed-result and native UI
failure records remain independently fatal.  `one-boot.scm` has the matching
minimum failure-record gate in its real typed console callback; the subsequent
single-boot checker still enforces exact marker and shutdown/power-down
cardinality and order before boot 2 can start.

## BTQ-4 — closed

No file in the authenticated 23-file runtime closure contains `module-set!`.
The historical accepted snapshot is packet evidence only and is not loaded by
production.

The private outer now accepts one immutable six-callback SRFI-9 integration
record and a four-callback process-hook record.  It validates the complete
integration before `run` performs work, closes the process-role vocabulary,
rejects unknown roles before callback action, and permits an inherited exec
extension only for the `qemu`/coordinator role.  The unchanged coordinator then
enforces stdio plus the state OFD for QEMU and stdio plus private UI FD 3 for
KOReader.

The actual retained `one-boot.scm`, not merely a test shim, constructs this
record and passes it directly to `disposable-qemu-main`.  With no integration
record the accepted default outer graph remains unchanged.  All three successor
patches reproduce exactly from their six pinned parents.

## Preserved adjacent invariants and next gate

The timeout contract and state/graph/OFD/coordinator/sequential/UI modules are
byte-identical to v1.  The finite checks retain exact 300-second cooperative,
360-second VM, 5-second TERM, 5-second KILL/reap, 420-second owner, and 12-second
cleanup-observation layers.  Boot 2 remains unreachable after boot-1 failure;
the writer/OFD anchor lifetime, fresh per-boot objects, unpaused closed graph,
and staged single/cross/payload/final evidence joins remain intact at the
source/model level.

The next source action is finite: close the `LD_PRELOAD` pre-authentication gap
and replay these targeted controls.  Separately, guest-v5 and the actual image
must be accepted and installed as one exact source binding.  Only then is the
runner eligible for STEP 1's two fresh ARM/gVisor boots.  STEP 2 device
generation remains after that semantic persistence result.

---

# V3 finite BTQ-1 recheck — 2026-09-06

## V3 verdict

The preceding v1+v2 report remains an unchanged byte prefix with SHA-256
`7701e00b376a50b82258f8383ee6e01148581c6d83d393355a63a80b895f7635`.

**BTQ-1 is closed by frozen v3.  Together with the v2 decisions, BTQ-1 through
BTQ-4 are now closed at the source/pre-image gate.**  I found no remaining
caller-controlled loader or Bash-startup route before source authentication.
The runner source is fit for a later, small, independently reviewed successor
that installs one exact source-pinned current guest/image binding.

This is not permission or evidence for an actual campaign.  Production still
fails closed at `production-image-binding=unavailable`; the separately active
guest denial/mode work, built image identities, and image review are outside
this recheck.  No guest-v5/v6 or image result is accepted here.  STEP 1's two
fresh ARM/gVisor save/shutdown/reopen/paint boots and STEP 2's device generation
therefore remain pending.

## Frozen authority and scope

I authenticated the exact v3 packet:

```text
/tmp/opencode/book-state-qemu-two-boot-source-20260906-v3._f_40q4p
deaca60eec261d7060120e44ba100443e720f71605ea9dac7e4b18539678f007  PACKET-EVIDENCE.sha256
f60df94a3e65a03fb9651d3e4bc637ae4c787ea5f1ca4c817e454ca1eb099066  source/SOURCE-MANIFEST.sha256
55faa73419ee571611613810673546c19e90032f67791240dab4ae14964f2dce  source/RUNTIME-SOURCE-MANIFEST.sha256
0bb00a83e1f7f563524b0076cb0bf631b942f42703bf2869e89ce5a57a7d4878  PRE-SEAL-HOST-GATE.log
7701e00b376a50b82258f8383ee6e01148581c6d83d393355a63a80b895f7635  V2-INDEPENDENT-REVIEW.md
14388667a554d0bc743421a8d6ffbd9ee369c6e1ffcadcaedfa81f98de7f258b  V2-INDEPENDENT-EVIDENCE.sha256
```

Both packet and source manifests passed strict verification.  The packet has 80
regular files, no symlinks, mode-0400/0500 files, and mode-0500 directories.
The 23-entry runtime manifest and every file it names are byte-identical to v2.
`bootstrap.py` remains
`c71e9343da7c9e545dec298dcef29fc692869f3bef235f88bbf0a5465ddbaf81`;
`bootstrap-main.scm` remains
`01e7e8a94380df664a9b42c5aab83ddc8bb772684f5cefa1bc215eaca0369b43`.
The only production-code delta is `run-two-boot.sh`; packet text and its two
bootstrap tests changed around that delta.

Independent evidence is frozen at:

```text
/tmp/opencode/book-state-qemu-two-boot-v3-independent-evidence.5H4Buj
98a75043f7c878cc51dde4e1247198b5d4923c1b51514af7ee447f389a44870c  EVIDENCE.sha256
```

I did not repeat the unchanged full host suite.  I authenticated its supplied
log, which records 26 warning-enabled Scheme compilations, 73/73 Scheme
assertions, 13 bootstrap assertions, and 21/21 rejected evidence mutations.  I
independently ran only the delta-dependent bootstrap map and bootstrap suite;
both exited 0, including all 13 boundary assertions.

## Exact pre-exec boundary

The launcher hash is
`7c1da0da7e812b3d9815dd8ccbf39f9abe39f97c5e5d8c0c7b3bc1aa91c220a5`.
Its interpreter is the exact pinned static Bash
`7370f72d9fcab3d8885ad1b1f05642294616d8f08f8f3caf8029ca37ff9a3eea`
and the shebang supplies `-p`.

Before the first dynamic executable, the script uses only static-Bash syntax
and builtins plus a direct read of `/proc/self/environ`:

1. `set`, `umask`, and assignment retain the invocation working directory;
2. explicit builtin `unset` removes the startup-sensitive named variables;
3. builtin `read`, parameter expansion, `[[ ... =~ ... ]]`, and builtin `unset`
   walk every NUL-framed inherited entry whose name is a valid shell variable;
4. loop temporaries are removed; and
5. builtin `export` reconstructs `LANG=C` and `LC_ALL=C`.

The scrub completes at line 20.  The first dynamic execution is pinned
`sha256sum` in `hash_file` at line 49.  Thus `LD_PRELOAD`, `LD_AUDIT`,
`LD_LIBRARY_PATH`, all other valid current or future `LD_*` names,
`GLIBC_TUNABLES`, `GCONV_PATH`, `LOCPATH`, `NLSPATH`, Guile paths, HOME/XDG
paths, and caller review/binding labels are gone before any pinned coreutils,
Python, or Guile process starts.  Hash/version failures use builtin `echo` and
`exit`; all hash, copy, mode, root-identity, helper, `env -i`, and cleanup
commands occur after this boundary.

The saved working-directory value is a shell local, not retained caller
environment.  Positional arguments survive the scrub.  The launcher supplies a
fixed `--` before `"$@"`, so caller arguments resembling Python's private
`--test-before-exec-*-fd` options remain campaign arguments.  A direct control
produced no handshake marker or stdout, leaked no bootstrap root, and the
retained campaign rejected those names as unknown.

## Loader A/B controls

I compiled one harmless, bounded native probe with the reviewed compiler
`1b99826121ae6682a634e5efe09bd3e3df58ce58e0b28f849114ab5b89139c26`.
Its canary path was compiled into the library.  It implemented both a preload
constructor and the real audit `la_version` entry, recording `/proc/self/exe`
for any process that loaded it.

For both `LD_PRELOAD` and `LD_AUDIT`:

- direct positive control executed in the exact pinned coreutils `sha256sum`;
- frozen v2 reproduced the old defect, with its first marker the exact pinned
  `sha256sum` before `env -i`;
- frozen v3 produced no marker from any hash/helper/cleanup child; and
- v3 accepted the normal sanitized argv far enough to return status 1 with the
  exact `book-state-two-boot-image-binding-unavailable` refusal and no stdout.

The independent v2/v3 A/B produced 8/8 expected results.  A separate expanded
probe produced 12/12, adding the generic loader namespace, glibc/gconv/locale
paths, invented environment review hashes, and Bash edge cases.

## Readonly and exported-function edges

`bash -p` does not import caller functions.  Exported functions named `umask`,
`unset`, `read`, and `export` therefore did not run before or during the scrub;
neither did `BASH_ENV`/`ENV` startup content.  Their encoded environment names
contain `%` and are not valid shell-variable names, but privileged Bash drops
the imports rather than exposing callable overrides.

Some special Bash variables are readonly and shell-generated, so a literal
claim that the post-loop shell has no exported names would be too broad.  The
finite control showed Bash regenerated its own safe `BASHOPTS`, `SHELLOPTS`,
`PWD`, `OLDPWD`, and `SHLVL`; it did not retain caller `extdebug` or `xtrace`,
and a command-bearing `PS4` did not execute.  Loader variables and other
caller-controlled valid names are ordinary unsettable variables.  Finally, the
later exact `env -i` constructs the Python environment explicitly, so these
safe shell-generated readonly values do not cross the trusted-helper boundary.

## Preserved v2 decisions and remaining image gate

The prior retained-source authentication, stable-descriptor copy, private
capsule, guardian-before-campaign-load, exact cleanup, and post-auth caller
mutation decisions remain applicable because `bootstrap.py`,
`bootstrap-main.scm`, and all runtime files are unchanged.  Environment values
claiming an available image or reviewed bundle did not create campaign, run, or
evidence directories and could not alter the source-pinned unavailable binding.

BTQ-2, BTQ-3, and BTQ-4 remain closed without reinterpretation: their production
sources are byte-identical to v2.  The timeout contract is also byte-identical,
retaining exact 300 / 360 / 5 / 5 / 420 / 12-second layers.  I did not reopen
the unchanged volume, persistence model, guest, console, typed-hook, or process
lifetime components.

The finite source review therefore stops here.  A future successor must replace
the unavailable binding with the exact independently accepted current guest,
kernel/initrd/root/config/BUNDLE and image-review identities.  Only that narrow
pre-image obligation, followed by actual per-boot process-group containment,
stands between this source authority and STEP 1 execution; no new caller-hash,
PKI, or authorization framework is required.

---

# V4 finite consumer/image-binding review — 2026-09-07

## V4 verdict

The complete v1–v3 report above remains an unchanged byte prefix with SHA-256
`672c6c7d50e99e8d886b7ae93b94d803d2fc5922d702297770b4947924668b83`.

**Reject frozen v4 for the actual two-boot run.**  The targeted schema and Guix
store hard-link changes correctly close the two numbered consumer blockers in
the independently accepted image report.  Exact production authentication now
accepts the fixed bundle and the real hard-linked QEMU without invoking it.
However, two concrete binding defects remain:

1. the role named `reviewed-boot-payload-manifest-sha256` is bound to the hash
   of the image build's `STATUS.json`, not to the accepted four-file
   `PAYLOAD.sha256`; and
2. the final evidence checker returns its full success result when both actual
   child `BOOK_STATE_SANDBOX_BOUNDARY` markers are absent.

The first defect makes one supposedly exact external-evidence role untruthful.
The second means a nominal STEP 1 PASS would not satisfy the accepted guest and
image reviews' explicit requirement to authenticate the real gVisor child's
denial result together with its positive typed read/commit path.  Therefore no
actual-run command is issued from this review.  No new caller hash, PKI, token,
or authorization framework is needed; both failures are finite source/evidence
coupling defects.

This rejection does not reopen BTQ-1 through BTQ-4, the accepted image bytes,
or the previously accepted runner/session/storage/guardian boundaries.  It also
does not establish any QEMU, runsc, ARM, KOReader, or semantic-persistence
runtime result.

## Frozen authorities and review scope

I authenticated the exact requested packet and its retained parent decisions:

```text
/tmp/opencode/book-state-qemu-two-boot-source-20260907-v4.rhkos71q
a76a81d5ef42816d3f9afc736b1c96ca78a7d4e7a8c2d438005907f063716c97  PACKET-EVIDENCE.sha256
16c9e882e8ab2d793ee04af870ba02d2313fb18c2ddb753ec82de69e294d823d  source/SOURCE-MANIFEST.sha256
997459ea52f920d2ae237ccda8a6d05990ac40ebac3344e289c2d5b45a535a08  source/RUNTIME-SOURCE-MANIFEST.sha256
d09d164624ee50a98f324f3d051b1735e04ce63e5417409e0d99fb0fbc7ee425  source/run-two-boot.sh
50e57306f82b6c844c85658047090cf9641a22ad51a6e22584b03b0149b4024f  source/bootstrap.py
9fb82a49a11c7d6ff7880d90b09d149d70a44043246fd948ec6b697f03b30bed  production-bundle/MANIFEST.sha256
2c80fe6e864589e1690361169f8ebb8bc9a4ef08d319fdca8b08106a57fd868b  PRE-SEAL-HOST-GATE.log
672c6c7d50e99e8d886b7ae93b94d803d2fc5922d702297770b4947924668b83  V3-INDEPENDENT-REVIEW.md
02a4d7adecf9dc36dbd696ea488d00500999cd95d8304a6e76472403281ffa4b  IMAGE-INDEPENDENT-REVIEW.md
eef2ebd3d483d7204b0d663a7f569368327551a439ae2dc9dbe630870e53a7df  IMAGE-INDEPENDENT-REVIEW-EVIDENCE.sha256
```

Both packet and source manifests passed strict verification.  The normalized
v3-to-v4 comparison accounts for all source paths: 49 are unchanged and 20 are
changed or added.  The runtime delta is limited to the closed metadata/binding
consumer, corresponding record field names, evidence constants, and the
source-pinned production binding; the bootstrap launcher changes only its
authenticated `bootstrap.py` hash, and `bootstrap.py` changes only its expected
runtime-manifest hash.  I did not reopen the byte-identical state-volume,
QEMU-graph, sequential, UI-proxy, timeout, one-boot, or accepted outer modules.

Independent evidence is sealed at:

```text
/tmp/opencode/book-state-qemu-two-boot-v4-independent-evidence-final.9IBQx7
05e4e150bd20296b897ec522ead3f92187441f7399b6b780c8eca7f9a16d3a17  EVIDENCE.sha256
```

No QEMU, runsc, ARM, or KOReader process was executed.  No campaign ext4 state
volume was created; the checker counterexample created and removed only its
source-suite non-claiming sparse byte fixture.  No accepted image was rewritten
or mounted, and no build, network, hardware, deployment, staging, or
repository-publication action occurred.

## Numbered image-review findings — closed

The original image review remains authoritative and accepted for the exact
realized DOS/MBR artifact
`53bee9f09d7b3a12ad5e9bf77f1dd91a1e2416be8ba205f06889becfd00de9d4`.
I did not repeat its deep image inspection.  I authenticated its evidence and
confirmed that all four production-bundle payload files are byte-identical to
the separately reviewed private payload:

```text
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  boot-bundle/extlinux/Image
f7ade895ca2b7f970d1532051ed55b72b7d9c8fe271629521d1181c9570951ed  boot-bundle/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  boot-bundle/extlinux/initrd.cpio.gz
20c28d8d4a336308862c1a95d93aba7703115d5be71b640aa05138dcf65249db  rootfs.raw
```

V4 closes image-review finding 1, “The v3 schema cannot express this review.”
The schema is version-neutral and has distinct roles for the guest source,
snapshot, capsule, packet, mode delta, external guest review, source-gate
system, image derivation/output, image-embedded system, original raw image, and
prepared payload.  There is no guest-v4/v6 alias and no caller-selectable
review, status, hash, or replacement binding.

V4 also closes image-review finding 2, “Exact store executables fail the
single-link check.”  The exact source-pinned, canonical, root-owned,
non-writable regular Guix-store executable may have `nlink >= 1`; caller source,
bundle, state, rootfs, and other mutable data retain the single-link rule.  The
actual pinned QEMU and `qemu-img` are mode 0555, root-owned, and `nlink=2`; the
actual runsc is likewise `nlink=2`.  The focused suite accepted the exact QEMU
while rejecting a wrong digest, another store executable, an outside-store
lookalike, a symlink, a replacement inode, and hard-linked caller data.

## Exact production authentication — passed without spawn

Using the retained production `authenticate-production-two-boot-bundle` entry,
with no module replacement or test binding, I authenticated:

```text
/tmp/opencode/book-state-qemu-two-boot-source-20260907-v4.rhkos71q/production-bundle
```

The returned object named the exact manifest `9fb82a49…` and selected:

```text
/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1/bin/qemu-system-aarch64
```

The check stopped there; that executable was not invoked.  The independently
run focused gate passed 48/48 assertions, including the closed metadata schema,
source-only external review authority, exact/wrong store-file cases, immutable
caller-data rules, exact 360/5 outer argv, distinct system roles, DOS/MBR role,
kernel-versus-config distinction, and production bundle mutation negatives.
The supplied full host log was authenticated and records its separate 26
warning-enabled compilations, 90 Scheme assertions, 13 bootstrap assertions,
and 21 rejected evidence mutations; I did not rerun unchanged closed suites.

The frozen entry path is
`/tmp/opencode/book-state-qemu-two-boot-source-20260907-v4.rhkos71q/source/run-two-boot.sh`,
and the CLI shape still requires exactly one `--bundle`, `--campaign-base`,
`--run-base`, and `--evidence-base`.  Those entry and bundle paths are recorded
for a corrected successor, not authorized as a runnable campaign by this
verdict.

## Counterexample 1 — the payload-manifest role names `STATUS.json`

The accepted external image evidence contains two adjacent, distinct records:

```text
9d188cd6ef2333ba6c28c515ea6c27748383256026284e8bbe2077e494c5fc82  evidence/PAYLOAD.sha256
2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25  evidence/STATUS.json
```

`PAYLOAD.sha256` is the four-record manifest listing the exact kernel, extlinux
configuration, actual image initrd, and prepared root filesystem.  `STATUS.json`
is only the four-line external command status (`returncode` and elapsed time).

Nevertheless, both
`source/modules/two-boot/image-binding.scm` and
`production-bundle/BUNDLE.scm` contain:

```text
reviewed-boot-payload-manifest-sha256=2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25
```

The source and bundle therefore agree with each other but disagree with the
external evidence role their field names.  Exact production authentication
passes this wrong-role value because the source-fixed expectation repeats it.
The separate five-file production manifest `9fb82a49…` still authenticates the
actual payload bytes, so this does not invalidate the accepted image; it does
invalidate the claim that every version-neutral identity role is truthful and
externally pinned.

The narrow correction is to bind this role to `9d188cd6…` (or remove/rename the
role truthfully), regenerate `BUNDLE.scm` and its five-file manifest, and freeze
the resulting source/runtime manifests in a successor.  A caller-supplied hash
or new approval mechanism is neither necessary nor acceptable.

## Counterexample 2 — final PASS with both denial markers absent

The exact v4 checker hashes to
`cd350aae94e8b48ec36863fd2ddb51fa6a032c99bbe7a68dae4a9a1db5fb6660`.
It contains no `BOOK_STATE_SANDBOX_BOUNDARY` requirement.  Its own exact
non-claiming fixture generator hashes to
`a0866bb5515a0afbfc6633b2c4431fd046d8607d7793a089e0d82e4ae2c23b54`
and emits no such marker in either boot.

I generated a complete synthetic payload, sealed its final evidence manifest,
confirmed a marker count of zero, and invoked the production checker with both
the payload and final manifest hashes.  It returned status 0 with empty stderr
and the exact full-success line:

```text
payload-manifest-sha256=832706621b602f8c69d643bc9eb79e18ac8c58903ce75138978bde58f5851762
final-manifest-sha256=2ea45e41ae21d36f6c4222aeb26a8883c1edd04fb09480450aa58424af8c8e8b
sandbox-boundary-marker-count=0
checker-status=0
PASS: exact two-fresh-boot Book State evidence and cleanup join
```

This fixture is not offered as VM evidence; it is a finite counterexample to
the acceptor.  The accepted guest review requires the actual child marker to be
authenticated together with the same process's real hello/read/commit evidence,
and the image review repeats that requirement for the two-boot run.  Source
hashes for the probes and launch order are necessary but do not demonstrate
actual denial under the source-built gVisor/Sentry process.

The correction must make each boot retain and authenticate exactly one actual
Guile and one actual Python boundary result, reject missing/duplicate/wrong
markers, and couple each result to that language's subsequent positive typed
read/commit path.  Merely adding marker text to a synthetic fixture is not a
fix.  If the accepted image does not expose the successful child capture to the
outer evidence boundary, that observability must first be added in a separately
reviewed guest/image successor.

## Required next gate

1. Correct the payload-manifest role and freeze the resulting exact bundle and
   source identities.
2. Make actual-child Guile/Python denial results observable and mandatory in
   the final evidence join, with missing-marker negative regression coverage.
3. Independently review only those corrections and repeat the no-spawn exact
   production authentication.
4. Issue one exact runnable command only after that successor is accepted.

STEP 1 remains unrun: no two fresh QEMU lifetimes have yet demonstrated save A,
clean shutdown, reopen-and-paint A, and save B.  STEP 2 device-generation work
remains separately blocked and unauthorized.

---

# V5 finite checker/source recheck — 2026-09-07

## V5 verdict

The complete v1–v4 report above remains an unchanged byte prefix with SHA-256
`9bd63cac957ef43713c332012ce8930064a38dbf95b210a984c76e530d4c983c`.

**Reject frozen v5 as the checker for a future runnable binding.**  V5 closes
the v4 `STATUS.json`/`PAYLOAD.sha256` role defect and closes the original
missing-both-marker counterexample.  It requires four exact V7 records—Guile
and Python in each boot—with the finalized-capture attribution immediately
before the actual marker and after the corresponding typed save.

One requested marker condition nevertheless remains open: **balanced
cross-boot pair reuse is accepted**.  The checker parses `capture-sha256` but
does not retain it, compare it across boots, or bind it to the immediately
preceding book-owned operation ID.  Replacing each boot's complete same-language
attribution/marker pair with the other boot's pair, while preserving every
record count and all typed/UI/state evidence, still returns the exact final
PASS.  V5's cross-reuse regression instead moves boot 2's records into boot 1,
which fails cardinality and does not cover balanced substitution.

Production is correctly `unavailable`, so this defect cannot currently launch
QEMU.  The pending V7 image inspection and exact payload/bundle binding remain
separate future authorities and are not reviewed or accepted here.  No runnable
command is issued.

## Frozen authority and finite scope

I authenticated the exact source-only packet:

```text
/tmp/opencode/book-state-qemu-two-boot-checker-20260907-v5
097324e527f501bb76b0bdc1995cb03c72dbec6ef84a02273a9a95b810f4a2a8  PACKET-EVIDENCE.sha256
299f9898c5fba331651fb842dec26c52c78c9982e6730650cecad8f6a8892c96  source/SOURCE-MANIFEST.sha256
dd26875aac1df129deba6cad27df3cc17a783469c239759c043744c86b6c367f  source/RUNTIME-SOURCE-MANIFEST.sha256
45538961af06dd7b58a7acad6b33d75282be649cd97a16dccf7c3dfe1d6165b0  source/run-two-boot.sh
ff0a4d093625c49fceec94419ec0524f837fa7041b6f269742652e09c0afa2dd  source/bootstrap.py
660d57bb3fd095441fd27bf5bd777140dbf6d6075088b311983e53fd6ef278bc  source/check-evidence.py
664407a00076191fd3185db48ec88005d76a9f09445ea7d0335ac59ddaba6932  source/modules/two-boot/bundle.scm
54c3ed60862938c93366cd324a6f0ace89ae68557402ab2bc28ffc8ae7da4191  source/modules/two-boot/image-binding.scm
05783168b5202234ae1dbfb608209db37ea811be9c3d65c76fe271bee34c0ded  FROZEN-HOST-GATE.log
```

All packet, source, and 23-entry runtime manifests passed strict verification.
The packet has 87 regular files, no symlinks, only mode-0400/0500 files, and
mode-0500 directories.  The normalized comparison accounts for all 69 source
files: 49 unchanged, 20 changed, none added or removed.  Of the authenticated
runtime entries, only `check-evidence.py`, `modules/two-boot/bundle.scm`, and
`modules/two-boot/image-binding.scm` change.  Launcher and bootstrap changes are
only the corresponding authenticated helper/runtime-manifest hashes.

I also authenticated the independently accepted V7 source review and exact
producer used by the checker grammar:

```text
ee06d8be01eba8e970c9da59a273daae48d16c23cf0f26a75f8436cd54bc4065  guest V7 independent review
49bf1e84aeda168c97395a64cd754e796d1fc32eee1199957ee90f7da9af31cc  guest V7 review EVIDENCE.sha256
d852a183608dacf5758e0424f1494522f93c57646b7b396ba80902ffbb240fdd  book-state-guest-authority.scm
```

Independent V5 review evidence is sealed at:

```text
/tmp/opencode/book-state-qemu-two-boot-v5-independent-evidence.p7JCp0
da54ed9235174fb82da8b4ad7ee1abc8c879062d75400ba05f1bfabb820d3730  EVIDENCE.sha256
```

No QEMU, runsc, ARM, or KOReader process was executed.  No image, system,
kernel, or gVisor build was performed.  No accepted image was inspected,
rewritten, or mounted.  The checker tests created and removed only their
non-claiming sparse model files; no campaign state volume was created.  No
network, hardware, device, SSH, staging, commit, or publication action occurred.

## V7 producer ordering — matched

The checker grammar agrees with the exact accepted V7 producer.  The fixed book
completes its read/UI/save interaction and the trusted authority emits the
`language=… saved=… operation=…` record.  Endpoint release then reaps the runsc
group and finalizes both bounded captures.  Only after `capture-result` verifies
that finalized status does the authority open the owned `runsc.stdout` through
a stable descriptor, validate one exact language-specific record, and publish:

1. a non-pass `sandbox-boundary-source` attribution; then
2. the exact substring extracted from the actual capture.

Cleanup follows both publications.  The attribution and marker therefore
appear after the corresponding language save and before the next language
phase or final inspector/result records, exactly as v5 requires.  The fixed OCI
source still executes the unchanged boundary probe immediately before the fixed
book in the same gVisor process and FD namespace.  This is source-exact
provenance for the two fixed books, not a general hostile-book attestation and
not runtime evidence by itself.

## Original missing-marker finding — closed

The exact v4 fully sealed model reproduces its prior identities:

```text
832706621b602f8c69d643bc9eb79e18ac8c58903ce75138978bde58f5851762  payload manifest
2ea45e41ae21d36f6c4222aeb26a8883c1edd04fb09480450aa58424af8c8e8b  final manifest
sandbox-boundary-marker-count=0
sandbox-source-attribution-count=0
v4-checker-status=0
v5-checker-status=1
```

That exact old evidence first fails v5's V7 source-identity gate, as it should.
A separate V7-identity fully sealed model removes only all four attribution and
marker records; v5 returns status 1 with zero stdout.  A missing-one model with
only boot 1's Python pair absent also returns status 1.  Conversely, a fully
sealed two-boot model with exactly four attribution/marker pairs returns status
0 and the exact final success line.  An unrelated diagnostic line without a
reserved stem remains allowed and cannot stand in for attribution.

The independent full focused matrix additionally rejected missing, duplicate,
wrong-language, failed, wrong probe value, timestamp-prefixed, quoted,
attribution-only, wrong attribution language/container/source/hash, unbalanced
cross-boot movement, whole-console boot swap, and old-V6 identity cases.  It
also retained the 21 inherited evidence mutations.  Those tests establish the
new exact grammar and cardinality but not the balanced substitution discussed
below.

## Payload-manifest role finding — closed at the consumer boundary

An available successor must now contain this closed outer roster:

```text
BUNDLE.scm
PAYLOAD.sha256
boot-bundle/extlinux/Image
boot-bundle/extlinux/extlinux.conf
boot-bundle/extlinux/initrd.cpio.gz
rootfs.raw
```

`PAYLOAD.sha256` must itself be an immutable single-link regular file with the
source-pinned `reviewed-boot-payload-manifest-sha256`.  Its records must be
exactly the four payload members above in canonical order.  Each member is
rehash-checked against that inner manifest and independently against the outer
bundle manifest; the outer manifest must also carry the exact inner-manifest
hash.  The closed inventory and fixed-file checks reject additions, omissions,
links, member mutation, and role substitution.

The independently replayed 60-assertion source/binding suite accepted the exact
four-entry fixture and rejected each wrong member, inner omission/addition/
reordering/duplication, an outer inner-manifest mismatch, and the historical
`STATUS.json` hash `2099f4ed…` in the payload-manifest role.  The historical V6
`PAYLOAD.sha256` hash `9d188cd6…` is used only as a role regression; it is not
asserted as a V7 payload identity.

The V5 production binding truthfully retains the accepted V7 source and review,
the source-derived system and expected image paths, and exact unchanged runtime
tools.  All realized V7 image inspection, embedded-system, initrd, rootfs,
payload, bundle, and binding-review fields remain non-hash `pending-*`
sentinels.  Status is `unavailable`, and the production entry throws
`pending-reviewed-v7-image-payload-and-independent-v5-binding-review` before
canonicalizing or inspecting a caller path.  No V6 image or payload can be
relabeled as V7 through this source.

## Remaining counterexample — balanced cross-boot attribution reuse

The source-attribution regex captures both `capture-bytes` and
`capture-sha256`.  `check_console` bounds the byte count but discards the digest
and returns only the book operation IDs.  The cross-boot join proves that all
four operation IDs are distinct, but it has no field connecting an operation ID
to its following capture attribution.

This leaves a balanced transplant that preserves every local grammar and order.
I first gave each modeled boot distinct, regex-valid Guile/Python capture
attributions; the fully sealed baseline passed.  I then swapped each complete
same-language attribution/marker pair between boot 1 and boot 2, leaving the
read, recovered-A, save, operation-ID, inspector, UI, state hash, process, and
shutdown evidence untouched.  Both directions were byte-confirmed as the other
boot's original pair.  The exact final checker still returned status 0:

```text
baseline-cross-boot-source-lines-distinct=True
baseline-checker-status=0
swapped-boot1-equals-original-boot2=True
swapped-boot2-equals-original-boot1=True
8ad09869b755ba58b39a79ec2a78b19018745bb1d404fc086c6d9534c8f26349  swapped payload manifest
ff56f1913ec67ef80eedf161abc6062f1cda4cf22f2e86da878c0c76ef06cd5c  swapped final manifest
swapped-checker-status=0
PASS: exact two-fresh-boot Book State evidence and cleanup join
```

The shipped synthetic positive is weaker still: its same-language attribution
records are already identical across the two boots because its modeled capture
does not include the per-boot book output.  Thus the existing “cross-boot marker
reuse” negative proves only that moving records without replacement breaks
per-boot cardinality.

Order after `saved` is not an identity join.  The actual fixed book capture
contains the CSPRNG-derived book operation ID and boot-dependent loaded/commit
records, but v5 retains only an opaque capture hash and cannot prove that the
attribution following operation B came from the capture containing operation B.
An all-distinct digest check would reject duplication but would still accept the
balanced swap above.

## Required narrow correction

The actual-capture attribution must carry a phase-unique value already owned by
the typed path—preferably the book operation ID and resulting state version—and
the trusted guest producer must validate that value against the finalized
capture before publication.  The checker must then bind it to the immediately
preceding `saved` record and reject duplicate or cross-boot substitution.  This
uses the existing book-owned CSPRNG operation surface and durable version; it
does not require a caller token, a new phase oracle, PKI, or a general hostile-
book claim.

Because the current V7 source attribution does not publish that value, closing
the balanced-swap case requires a separately reviewed guest/image successor as
well as the corresponding checker update.  The parallel V7 image artifact may
remain useful as inspected evidence, but it cannot by itself change this source
grammar or close this finding.

Only after that correction and the separately accepted exact image/payload
binding should a metadata successor make production available and issue one
bounded `360/5` two-boot command.  STEP 1 and STEP 2 remain unrun and
unauthorized here.

---

# Joint V8 producer / V6 checker finite recheck — 2026-09-07

## Joint verdict

The complete v1–v5 report above remains an unchanged byte prefix with SHA-256
`e219c97cf37129e86752f81fefa1bd4fa9df8054dcb20240d5af6b85d2e8acbe`.

**Accept the exact V8 guest producer and V6 two-boot checker as one joint source
successor.  The balanced cross-boot substitution finding is closed.  Accept
the V8 guest/system source for one exact bounded raw-image build, but not for
runtime.**

V8 adds the operation ID and resulting state version from the same completed
typed Book save to the post-drain sandbox attribution.  V6 retains those fields
and requires each attribution to agree with its immediately preceding
same-language save—A/version 1 in boot 1 and B/version 2 in boot 2.  A complete
same-language pair transplanted between boots therefore no longer satisfies
the local join.  No new nonce, phase flag, caller token, PKI, or general log
attestation mechanism is introduced.

Production remains deliberately `unavailable`: no V8 image, image inspection,
four-file payload, production bundle, or final metadata binding is accepted by
this verdict.  No QEMU, runsc, ARM, or KOReader execution is authorized here,
and no runnable two-boot command is issued.

## Frozen joint authority

I authenticated the exact read-only joint packet:

```text
/tmp/opencode/book-state-qemu-two-boot-checker-20260907-v6-r2
6dd49ccb4f291bd68361a5aa0c90c76c3324d83b9e496c4ed2b8422241111e18  PACKET-EVIDENCE.sha256
4bac69a497d07ce17f9b1f9b81fe824f00ef0376ece2750c0e55746b6ee7b1d9  source/SOURCE-MANIFEST.sha256
0d09798ab61ef3b7fa629a0749c932b2496e10f7a41d14d0c2980f80d32bddaf  SOURCE-SNAPSHOT.sha256
998c1bc4b06281587c89d984b2b6dc8a7cc097c1c75b144ddcd3cf69a61d921c  source/RUNTIME-SOURCE-MANIFEST.sha256
6cd978978049f21119003c1e1f349ce78d9dc4167a1801453435bb9be6e18716  source/check-evidence.py
23db9bcf4caf821d07590cf7100f57b565a48f3661dce2680eed374fe3d0d114  author EVIDENCE.sha256
```

All 92 packet records, 69 source-snapshot records, 68 inner source records,
23 runtime-source records, and 14 author-evidence records passed strict hash
verification.  The packet has 93 regular files, no links, 73 mode-`0400`
files, 20 mode-`0500` files, and 20 mode-`0500` directories.

The exact frozen V8 source authority is:

```text
pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260907-v8/
e223e4232376795416beca9d598c771307515a34f068e93026f31fd02891f5a2  PACKET-CONTENTS.sha256
3cef458b490637ab03d0abb2bc1e7fa22e292e6f68a7961a91c3bff19bf71444  SOURCE-MANIFEST.sha256
95d9b5878a9232c586e59d7f6887ff9c1216543692c1c6f1d818e6057551a56c  SOURCE-SNAPSHOT.sha256
fe12fb85efff2dd3be0d820f43a39287dc100270592b67cb7a6c07f60e5daac8  CAPSULE-ROSTER.tsv
b2695e27c844e93da121f90f1346a645b913b24d976e3ea7f0cb8348f8263696  V7-V8-DELTA.tsv
f8a30641076d5e10fe4e49d5ee0f2fecf0da82450f5ac90d7137fcbdbb7037fb  book-state-guest-authority.scm
10578fb0ea715416b3d23640c7d6046fe8dc03fd7e7d09cc3ba942f34fa25098  pinenote-book-state-reader.scm
69d1acc906b8309a46e518b6e7e7a52c637b45ce794bef1a1810dcbf86c24845  author EVIDENCE.sha256
```

The accepted V7 producer review remains the source parent:
`ee06d8be01eba8e970c9da59a273daae48d16c23cf0f26a75f8436cd54bc4065`.
Strict checks also reauthenticated its packet and sealed evidence and the
rejected V5 checker packet/evidence before comparing either successor.

The V8 capsule still contains exactly 248 regular files.  Independent mode
checking found no links or special files, exactly 12 byte-only V7→V8 changes,
and exactly the same nine rostered module-view wrappers at mode `0555`; all
other frozen modes remain correct.  Independent normalized comparisons
reproduced the complete five-file functional V7→V8 diff and complete 16-file
V5→V6 source diff byte-for-byte.

## Producer result origin and publication

The production path has one lexical owner for each language result:

1. `save-through-ui-and-book!` waits for the book-issued typed commit
   completion and passes it with the exact pending UI save to
   `reader-save-completion->decision`.
2. The accepted bridge requires the completion's session, surface/grant
   generation, expected version, operation ID, and text to match the pending
   save.  It also requires the typed committed response to repeat that operation
   ID, advance the expected version by exactly one, and report the exact UTF-8
   text byte count.
3. The authority accepts only `(committed OPERATION VERSION TEXT)`, verifies
   version and text again, copies the operation ID, emits the `saved` record,
   and returns all fields in the closed `drive-fixed-language!` result.
4. `run-one-sandbox-book!` stores that result in its per-language lexical
   `scenario`.  Endpoint release and the existing accepted child drain/capture
   finalization occur before the same `scenario` is passed to
   `validate-and-publish-sandbox-boundary!`.  There is no mutable global
   last-book result and no cross-language task slot.
5. The publisher validates the exact completed-result field roster, language,
   initial version, final version, and wire operation grammar.  It then emits
   the non-pass attribution followed by the exact marker extracted from the
   already validated owned `runsc.stdout`, before cleanup and final success.

For the required campaign phases, initial absent must yield operation/version
1 and initial A must yield a different operation/version 2.  The separate
stable-B path must carry initial and final version 2 with `(operation-id . #f)`;
its attribution suffix is exactly `read-version=2 no-new-commit=true`.  It
cannot masquerade as either campaign save, and V6's boot-1/boot-2 grammar does
not accept a read-only replacement.

The probes, marker bytes and hashes, OCI invocation, fixed Guile/Python books,
Book Protocol, backend, UI, FD adapter, process/capture owner, sandbox policy,
kernel, and source-built gVisor are unchanged from the accepted parent.  The
two probes still run immediately before their corresponding fixed book in the
same gVisor process and FD namespace.  The new fields are typed-save
correlation, not a new storage or sandbox authority.

The independent networkless native/static replay compiled the exact authority,
FD adapter, OCI source, and Guile probe and passed 18 liveness assertions and
92 connected guest-module assertions.  Its real owned-capture helper accepted
four save results—both languages at versions 1 and 2—plus the stable-B
read-only result.  Missing result, invalid operation, wrong version, and missing
save operation all failed before trusted publication.  Static source, module
origin, capsule, cache-poison, system graph, and unchanged containment checks
also passed.  This is host producer mechanics and source provenance, not an
actual runsc/Sentry probe execution.

## Checker correlation and balanced replay

All three V6 accepting modes—single boot, pre-cleanup cross-boot, and final
sealed campaign—enter the same `check_console` path.  It parses and retains the
complete attribution, including capture hash, operation ID, and resulting
version.  The closed guest-record sequence places each source attribution
directly after that language's save in the trusted semantic stream.  V6 then
requires:

```text
attribution.operation == preceding-same-language-save.operation
attribution.resulting-state-version == save.version == boot-index
```

The existing global all-four-operation distinctness check remains, but is no
longer the correlation mechanism.  Marker/source cardinality, exact source
grammar, physical source→marker adjacency, language phase order, and final
result order remain separately enforced.

An independent fully sealed replay produced these decisive results:

```text
valid.status=0
valid.stdout=PASS: exact two-fresh-boot Book State evidence and cleanup join
valid.same-language-capture-hash-equal-across-boots=True

2aff4647b74a98a8c03cf5c1500954b7be36eb73caab37a01bc30c82c3986d7d  balanced-pair-swap payload
c384c8965733222c7a70c1fc2b2d887a47bcdf2948b430ddf0a7a42bad333ad7  balanced-pair-swap final manifest
balanced-complete-pair-swap.status=1
balanced-operation-only-swap.status=1
balanced-version-only-swap.status=1
wrong-boot-operation-and-version.status=1
old-v7-attribution-grammar.status=1
```

Every rejection had zero stdout and the normal strict-checker failure prefix.
The complete-pair transplant now fails at boot 1's Guile local join rather than
at a later cardinality side effect.  Conversely, equal capture hashes remain
valid: the fixed probe marker and modeled capture can legitimately be identical
across boots.  The operation/version fields tie each publication to its typed
book invocation without treating the capture digest as a per-boot nonce.

This closes the exact `e219c97c…` finding.  It does not claim that an
unretained raw capture can be rehashed from the outer console, cryptographically
authenticate an arbitrarily rewritten complete evidence world, or make a
hostile arbitrary book trustworthy.  The accepted scope is internal
correlation emitted by the source-pinned trusted producer, later consumed
inside the existing closed image, capture, console, and final-manifest evidence
boundary.

The full independent V6 host gate also passed all 26 source compilations, the
23-file isolated bootstrap closure, 13 loader/cache-poison assertions, seven
graph assertions, four fail-stop assertions, seven byte-transparent UI-proxy
assertions, 12 hard-timeout/guardian assertions, 12 typed-hook assertions, and
64 source/binding assertions.  Its sealed matrix retained all missing,
duplicate, malformed, wrong language/container/hash/value/order, old V6/V7,
generic failure, process, cleanup, and inherited semantic mutations.  The
original v4 zero-marker final counterexample still exits 1.

## Unchanged payload and production boundaries

V6 does not change `modules/two-boot/bundle.scm`.  The accepted consumer still
requires a copied exact `PAYLOAD.sha256`, independently parses its exact
canonical four-entry roster, joins every member hash to the outer closed bundle
manifest and metadata, and rejects the historical `STATUS.json` digest
`2099f4ed…` in that role.  The historical V6 payload digest `9d188cd6…`
remains only a regression fixture, not a V8 artifact claim.

`image-binding.scm` truthfully pins the V8 source packet, author replay,
source-derived system/image derivations, and unchanged runtime dependencies,
while leaving independent V8 review, image bytes/layout/inspection, embedded
system, initrd, rootfs, payload, production bundle, and final binding-review
roles as explicit `pending-*` sentinels.  Status is `unavailable`, and the
production entry refuses before caller path or QEMU use.  The accepted V7 image
cannot be relabeled as V8.

## Exact one-build disposition

The authenticated author replay lowered, but did not realize, these exact
derivations:

```text
/gnu/store/35bsagzm09wjrn18my3jh61am624phlq-system.drv
  10c639fdd9bd9cb863a68327fea994e66dac5b65f8d8e3c442ebabea5a816558
  -> /gnu/store/v536sbh5v4gfngx5yv5k4w3fv6ihh5vc-system
/gnu/store/iaw5idj7sbwcvv74fcal8i5nx7x3vvhq-disk-image.drv
  b01e21a93b1826276754b2a762fc482ed9ec3555fc9eddfac9b4f7f4c1b5ff16
  -> /gnu/store/rj1a6k042gcchcmcsb8pli426b83w34g-disk-image
```

Both expected outputs remained absent after this review.  The accepted cached
kernel `334ljs8…` and source-built gVisor `djgy782…` remained unchanged.

This verdict permits **one** realization of the exact V8 `raw-with-offset`
image using the frozen packet's private no-argument `image_guix` build with
exactly `--target=aarch64-linux-gnu --no-grafts --no-substitutes --max-jobs=1
--cores=2`.  Its sole accepted expected output identity is
`rj1a6k…-disk-image`.  Any changed source, mode, channel, option, derivation,
dependency choice, or output identity is outside this disposition and must stop
before execution.

The resulting bytes would still require independent finite artifact inspection,
exact four-file payload extraction/authentication, and a separately accepted
metadata-only final binding.  Only then may the parent request or issue the one
exact `360/5` two-fresh-boot command.  Image construction alone is not runtime,
sandbox-denial, persistence, clean-shutdown, containment, or device evidence.

## Independent evidence and conduct

The sealed independent joint evidence is:

```text
/tmp/opencode/book-state-qemu-two-boot-v8-v6-joint-independent-evidence.ZAEn35
b93e51dafb17cc4792c77b7c1317b4dad6fffa9c54db93d7e873603f8130dd02  EVIDENCE.sha256
```

It contains strict joint/V8/V7/V5 packet and evidence checks, exact normalized
delta reproduction, the V8 mode gate, complete networkless producer native/
static replay, complete V6 host gate, independent fully sealed correlation
matrix, and derivation/output boundary.  Every retained file is mode `0400`,
the directory is mode `0500`, and there are no links or special entries.

No image, system, kernel, or gVisor output was built or realized.  No QEMU,
runsc, ARM, KOReader, device, SSH, network, host mount, deployment, staging,
commit, push, fetch, merge, or rebase occurred.  Native Guile/Python compilation
and parser models used private temporary roots and were removed.  No campaign
state volume was created.  No frozen packet, producer, checker, guest review,
or image review was edited; this two-boot review append is the sole
repository-path edit made for the joint recheck.

STEP 1 remains unrun.  STEP 2 device-generation work remains separately
blocked and unauthorized.

---

# Final V8 image/bundle binding review — 2026-09-07

## Final binding verdict

The complete v1–joint-V8/V6 report above remains an unchanged byte prefix with
SHA-256
`a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19`.

**Accept the exact final V8 source-fixed binding and exact seven-file private
production bundle.  They are fit for one actual bounded two-fresh-boot
campaign.**  This is campaign authorization, not runtime success: STEP 1 still
depends on the parent executing the command below and retaining its sealed
result.  STEP 2 remains separately blocked and unauthorized.

The focused successor truthfully joins the accepted joint V8 producer/V6
checker review, independently accepted V8 image, independently accepted
four-file payload, copied inner payload manifest, closed 88-field metadata, and
source-pinned outer bundle manifest.  The production authenticator reaches the
exact QEMU selection boundary without invoking it.  No caller-supplied expected
hash, review, status, token, or alternate binding exists.

## Frozen final authority

The exact read-only final packet is:

```text
/tmp/opencode/book-state-qemu-two-boot-v8-final-binding-20260907-v1
f5a9d2f7c09a2d4c8439e4b7511070d3bf98bafaef1b84f16eb4849136962747  PACKET-EVIDENCE.sha256
d00ebdd090f261598d993daaa12a21408a7a608485848945efaa0abcdd00026d  source/SOURCE-MANIFEST.sha256
f95b6b6980510fc805e3057e481f8c184e5ac39f2d18a41415eb85dd8634a2da  source/RUNTIME-SOURCE-MANIFEST.sha256
4441feca3ceab46d7b0254db621e7a71c5dcaaed054d0a497e12bb9d6bb70e31  source/modules/two-boot/bundle.scm
25d6a57d45748eb8fc12ba713e2df5288aad8ee12cab7f7adc06c49b26a16930  source/modules/two-boot/image-binding.scm
6cd978978049f21119003c1e1f349ce78d9dc4167a1801453435bb9be6e18716  source/check-evidence.py
e899a373889a9ecd00ba8a9c4df51fbee5843419b692a9c5bbe59a33163f1c2a  V6-R2-TO-V8-BINDING-SOURCE.patch
ffbb3200336a53e28d8b9c1507e88ce2dcc320c0979cb563245d87a38632e80a  AUTHOR-PREFLIGHT.log
```

Strict verification passed all 86 packet-manifest records, 68 source-manifest
records, and 23 runtime-manifest records.  The packet has exactly 87 regular
single-link files, 22 directories, no links or special files, 67 mode-`0400`
files, 20 mode-`0500` files, and 22 mode-`0500` directories.

The independently accepted artifact authority is:

```text
1a014ece021a59c12daebaa811938496754bf4e6e6b14679f89045ed37e51d53  V8 image review document
/tmp/opencode/book-state-image-v8-independent-review-20260907/review-packet-v1
b6df27f74422c13bf0083008f76997ddbde6e3e54d8eab4e13885e70a79550a9  REVIEW-EVIDENCE.sha256
5a6ae03ec7f7351674e617a522cb511e4dc8e0634b19af4a014fc7e74a710d22  BINDING-PARAMETERS.tsv
```

All 141 external image-review evidence records and the reviewed payload's four
records passed strict verification.  The accepted joint source review remains
`a7e13c9f…`; its V6 checker and operation/version correlation are not changed
or re-decided here.

## Exact minimal source delta

Independent whole-source comparison reproduced the supplied normalized patch
byte-for-byte: 16 of 69 source files differ and 53 are byte-identical.  Of the
23 authenticated runtime files, only these two change:

```text
modules/two-boot/bundle.scm
modules/two-boot/image-binding.scm
```

`bundle.scm` changes exactly three fixed layout constants:

```text
image-output-size:              2063540224 -> 2063556608
image-partition-sector-count:      4028304 ->    4028336
image-partition-byte-size:      2062491648 -> 2062508032
```

Those values are the independently measured V8 DOS/MBR layout.  The rest of
the bundle consumer is byte-identical.  `image-binding.scm` replaces the
explicit pending values with the accepted closed table, source-pins the exact
outer manifest, and changes status to available for that one object.  Other
changed files are documentation, focused binding tests, the host-test entry,
and required source/runtime-manifest hash propagation.  `bootstrap.py` changes
only its expected retained runtime-manifest hash; `run-two-boot.sh` changes only
its expected `bootstrap.py` hash.

The accepted checker remains exact hash `6cd97897…`.  `run-two-boot.scm`,
`one-boot.scm`, graph, sequential fail-stop owner, FD handoff, typed hooks,
timeout contract, QEMU owner/guardian, UI proxy, and accepted parents are
byte-identical.  Thus the A→B semantics, four operation/version-bound sandbox
records, generic `FAIL:` rejection, one retained OFD, fresh roots/processes,
and timeout nesting `300/360/5/5/420/12` are unchanged.

The static-Bash launcher still removes the complete inherited environment
namespace before its first dynamic dependency, validates the pinned bootstrap
programs, retains `bootstrap.py` through FD 9, and enters the authenticated
23-file private runtime capsule.  The focused host gate passed all 26 Scheme
warning-compilations, 13 bootstrap/cache/loader assertions, seven graph
assertions, four sequential assertions, seven UI-proxy assertions, 12 hard
guardian assertions, 12 typed-hook assertions, the full V6 evidence mutation
matrix, and the original sealed missing-both regression.

## Exact 88-field image and payload join

The `BUNDLE.scm` datum and source-fixed `production-bundle-metadata` are equal
88-field alists in the exact role-table order.  Every row equals the
authenticated `BINDING-PARAMETERS.tsv`; no value remains pending.  Important
independent joins include:

```text
joint V8/V6 review:       a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19
image review:             1a014ece021a59c12daebaa811938496754bf4e6e6b14679f89045ed37e51d53
original image:           /gnu/store/rj1a6k042gcchcmcsb8pli426b83w34g-disk-image
original image SHA-256:   2a492559aece65eb92832bf836b6b90751f5475101db3642a174c058e5ffa366
original image size:      2063556608
partition:                start 2048, sectors 4028336, bytes 2062508032
embedded system drv:      /gnu/store/911rbkh4ba70jfbsp443mx1slncarqpx-system.drv
embedded system output:   /gnu/store/9rkms12jnb68h83la5w9j4w77mxl4i3y-system
reviewed PAYLOAD.sha256:  c26dfa9416c438a59a6fe697773d5325cca863a171e2a6537e9fa93bec2491bc
```

The embedded system remains correctly distinct from the source-gate system
`35bsag… -> v536sb…`.  All runtime tool paths and full hashes match the external
table, including the unchanged kernel, gVisor, QEMU, e2fsprogs, KOReader,
Guile, Python, and coreutils identities.

The private production bundle is closed to exactly:

```text
BUNDLE.scm
PAYLOAD.sha256
boot-bundle/extlinux/Image
boot-bundle/extlinux/extlinux.conf
boot-bundle/extlinux/initrd.cpio.gz
rootfs.raw
MANIFEST.sha256
```

The exact copied inner manifest and its four files are byte-identical to the
independent review packet:

```text
c26dfa9416c438a59a6fe697773d5325cca863a171e2a6537e9fa93bec2491bc  PAYLOAD.sha256
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  boot-bundle/extlinux/Image
185b41ffcc4209ba517a58ebcc1f6e7f78095e7f7a18343f7163ca0d9f874e34  boot-bundle/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  boot-bundle/extlinux/initrd.cpio.gz
14abe02a4aeb08bb2e0306b23ca2f326fd5b9893a53939a431137af93d877c46  rootfs.raw
```

The source-pinned outer manifest is:

```text
e116907aa8d3cb1476d84b91325be6bb05a6ee48cee05d2caf96173d2415299d  MANIFEST.sha256
1e8e0142c0b15898d853fd35a38c49ffde63ef5aafe1339f1d3374c1b8a3aeb0  BUNDLE.scm
```

It covers exactly `BUNDLE.scm`, `PAYLOAD.sha256`, and the four payload members;
all six actual hashes verify both inward and outward.  The V8 build-status hash
`f1550fb51c481221fdd186b04fb2f12c4ee36eb611ce93d1b2074e398c5ac67d`
is absent from bundle metadata and source binding and cannot occupy the payload
role.  Historical V6/V7 payload, status, image, size, and path identities are
not accepted as V8.

The source binding alone supplies status `available`, external image-review/
binding-input evidence `b6df27f7…`, and expected outer manifest `e116907a…`.
The bundle cannot carry status, binding evidence, an alternate expected hash,
authorization, or self-review.  The caller supplies only a canonical private
bundle directory.  Caller source, bundle, evidence, state, and mutable data
retain `nlink == 1`; only exact root-owned immutable source-pinned Guix-store
executables may have Guix deduplication links.

## No-spawn production and negative replay

I called the actual production authenticator on the exact bundle in a private
Guile HOME/XDG/load/compiled boundary.  It returned:

```text
metadata-fields=88
binding-status=available
bundle-manifest-sha256=e116907aa8d3cb1476d84b91325be6bb05a6ee48cee05d2caf96173d2415299d
selected-qemu=/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1/bin/qemu-system-aarch64
qemu-invoked=no
result=pass-no-spawn-production-authentication
```

The focused 79-assertion binding suite additionally rejects, before any runtime
spawn:

- V6 and V7 image sizes;
- V6 and V7 partition-sector counts;
- V6 and V7 partition byte sizes;
- V6 and V7 image store paths;
- an altered outer manifest;
- an altered payload member;
- each wrong inner payload member, plus inner omission, addition, reordering,
  duplication, and outer/inner-manifest disagreement;
- wrong, outside-store, linked, replaced, or digest-mismatched executable roles.

No counterexample was found.

## Exactly one authorized production command

Run this command **once**, as a non-root user, from the host carrying the exact
frozen packet and its source-pinned Guix-store closure:

```sh
set -eu
umask 077
PACKET=/tmp/opencode/book-state-qemu-two-boot-v8-final-binding-20260907-v1
MKTEMP=/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/mktemp
CAMPAIGN_BASE=$($MKTEMP -d /tmp/opencode/book-state-v8-campaign-base.XXXXXX)
RUN_BASE=$($MKTEMP -d /tmp/opencode/book-state-v8-run-base.XXXXXX)
EVIDENCE_BASE=$($MKTEMP -d /tmp/opencode/book-state-v8-evidence-base.XXXXXX)
printf '%s\n' "CAMPAIGN_BASE=$CAMPAIGN_BASE" "RUN_BASE=$RUN_BASE" "EVIDENCE_BASE=$EVIDENCE_BASE"
exec "$PACKET/source/run-two-boot.sh" \
  --bundle "$PACKET/production-bundle" \
  --campaign-base "$CAMPAIGN_BASE" \
  --run-base "$RUN_BASE" \
  --evidence-base "$EVIDENCE_BASE"
```

The three bases must be canonical directories directly under `/tmp/opencode`,
owned by the invoking non-root user, mode `0700`, mutually distinct, and not
nested in one another.  Campaign and run bases must begin empty; the command
also creates a fresh empty evidence base.  Do not reuse any base from another
attempt and do not run concurrently against the bundle.

Do **not** add caller timeout options or an enclosing 720-second override.  The
authenticated runner injects exactly `--timeout-seconds 360
--term-grace-seconds 5` once for each fresh QEMU owner and rejects an override.
The unchanged internal nesting remains guest 300 s, inner grace 5 s, one-boot
owner 420 s, and guardian grace 12 s.

On success, retain the immutable evidence path and exact final line:

```text
BOOK_STATE_TWO_BOOT: status=pass; evidence=PATH; manifest-sha256=HASH; state-artifact=read-only
```

On any failure, stop after this single invocation.  Do not clean, retry, repair,
sync, unmount, or reinterpret the private campaign/evidence paths; retain the
reported failure and preserved roots for review.  Guardian-forced termination
continues to mean process/VM crash semantics, not clean close or halt evidence.

## Independent evidence and review conduct

The sealed focused-review evidence is:

```text
/tmp/opencode/book-state-qemu-two-boot-v8-final-binding-independent-evidence.ZcWfSA
01cd4a8669fc9a9ff1ac9f15325e29d568c95da723b9d764d7d3106032a8af85  EVIDENCE.sha256
```

It contains the strict packet/source/runtime/image-review checks, normalized
source-delta proof, full focused host gate, byte-exact inner/outer manifest
join, independent no-spawn production authentication, private-base contract,
and the exact authorized command.  Every retained file is mode `0400`; the
directory is mode `0500`; there are no links or special entries.

No QEMU, runsc, ARM, or KOReader process was executed during this review.  No
image, system, kernel, or package was built; no state volume was created; and no
filesystem was mounted.  No network, hardware, device, SSH, deployment,
staging, commit, push, fetch, merge, or rebase occurred.  Native finite
Guile/Python checks used temporary private roots and removed them.  No frozen
packet, source, implementation, image report, guest review, or artifact was
edited; this two-boot review append is the sole repository-path edit made for
the final binding review.
