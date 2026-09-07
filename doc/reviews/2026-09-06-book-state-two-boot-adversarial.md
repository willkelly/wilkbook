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
