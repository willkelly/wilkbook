# Public Book-execution source conversion — independent adversarial review

Date: 2026-09-06

## Disposition

**BLOCK the exact v3 public-source conversion gate.** The four reviewed system
sources do replace the historical local-v12 wrapper packages with the reusable
`gvisor/source` package, select `gvisor/source-diagnostic` only for the explicit
diagnostic variant, and clearly refuse to transfer old runtime evidence to the
new package identities. The finite source packet is internally authenticated.

The dependency-graph gate is not source-closed, however. After each protected
time-machine lowering, `run.sh` invokes a new, direct, PATH-resolved
`guix gc --requisites` while preserving the caller's `HOME`, `XDG_CACHE_HOME`,
and Guile startup cache behavior. I preseeded the exact Guile cache key for the
exact resolved `guix` script with reviewer-controlled bytecode. Each of the four
direct commands executed that bytecode and returned zero. The bytecode emitted
minimal forged dependency lists, and all four lists passed the exact frozen
graph checker. The resulting four PASS logs are byte-for-byte identical to the
packet's four claimed graph PASS logs.

This is **BEP-1: caller-cache code can forge all four dependency graphs**. It
blocks acceptance that the lowered public systems actually exclude the official
binary package, local wrapper, manual v12 path, or wrong diagnostic variant.
It does not show that any of those substitutions is present in the supplied
derivations; it shows that the exact gate cannot establish their absence.

Per rung order, I stopped at BEP-1. I did not run the supplied aggregate, redo
the four complete graph traversals, build anything, or reinterpret the old v12
runtime as evidence for the source package.

## Frozen boundary and authentication

The reviewed packet is:

```text
/tmp/opencode/book-execution-public-review-20260906-v3/
e7237bc2f6cff3b2c9b20b3748ac7426b6ecbd7727dce8c1b9d6c92d2425649c  MANIFEST.sha256
```

All 42 entries listed by that manifest reverified. The packet contains 43
regular files including the manifest, eight directories including its root, no
symlinks, no special files, and no writable entries. Its 11-file changed-source
manifest also matched the live candidate at review time.

The exact current system identities are:

| system | SHA-256 |
|---|---|
| `pinenote-book-execution-source-control.scm` | `5962f581c3ce4901f8e8c06c20d7f551aed4729ee3107a22a8e137c6c5d6db7e` |
| `pinenote-book-execution-diagnostic.scm` | `68578d38257702317f0d79e91e2993fd094779f2e17487fee5b9b31d53d8af81` |
| `pinenote-book-execution-protocol-control.scm` | `5332b08e8a566005924a798bae8b1c2c33a228fad995fbac3b8ad3bead68cfae` |
| `pinenote-book-execution-reader-interaction.scm` | `4e17d8ef6838baa78816737af5405ff54ab79eb7f80682d785f9fdb882a4e976` |

The source-gate identities are:

| item | SHA-256 |
|---|---|
| `SOURCE-MAP.tsv` | `8bf329dc41a07eba2cfce84f16aba74b5c48ed6fc01654ac8cd9a778daebed86` |
| `prepare.py` | `55a9dbbefc65befcbab444f378b49616f226dc3c4e8d47fe297e3c0a0855ad43` |
| `check.py` | `7c86b71687a8fda447ed82ff17743fd5c24d51d015e61d0777c343c60a57f5eb` |
| `check-systems.scm` | `5ed09f76a1ceaea926488ffcd40d61ca17cec7cab3d74df3da050f865c30c2ce` |
| `test_prepare.py` | `86c4f5ec0428fe7c564975d98d80f29a686e453bc33eeccfd3fdb1b7036f35f8` |
| `run.sh` | `64db1cfab13af18b62d31622a116578267ad2e96dcd20fde42af62d0ca5fb573` |

The map has 107 unique paths: 22 Scheme modules, 76 assets, and nine checks.
It maps `pinenote/packages/gvisor-source.scm` at
`0b35b6bfa406bc6b063e3e1d1ff6daabe26acfdff66a673b1fe315ceffc4b740`
and the unchanged official-reference `pinenote/packages/gvisor.scm` at
`8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d`.
The preparer validates mapped hashes and local imports, rejects local-wrapper
text, copies only the map, constructs an explicit module view and zero-Scheme
package view, then seals the capsule read-only. Those are useful finite-source
properties, but they do not protect a later program launched outside the
private startup environment.

## Source conversion observed before the stop

Direct comparison with the pre-conversion sources found the intended package
substitution:

- source-control imports `(pinenote packages gvisor-source)` and replaces the
  inherited official `gvisor-bin` with `gvisor/source` exactly once;
- diagnostic inherits source-control and replaces `gvisor/source` with
  `gvisor/source-diagnostic` exactly once;
- protocol-control and reader-interaction directly bind `gvisor/source` in
  their manifests rather than reaching through the old unexported local-wrapper
  symbol; and
- the inherited reference system, 45-path language closure, Systrap policy,
  `directfs=false`, `network=none`, `host-uds=none`, strict sidecar policy, and
  FD-3 donation declarations remain explicit. Keeping the official package in
  the historical base module is intentional; the derived systems claim to
  replace it rather than silently redefine it.

No reviewed current system source contains the local artifact module, a
`gvisor-v12-*` package binding, the manual `/tmp` build root, or a fallback from
the reusable package to `gvisor-bin`. The manifests correctly label the three
unpatched source systems as runtime-unproven and the diagnostic package as
lowered but uncompiled. These are static source observations, not an accepted
derivation-graph or runtime verdict.

The packet reports these protected time-machine lowering results:

| system | supplied AArch64 system derivation |
|---|---|
| source-control | `/gnu/store/8nis6vrw88f960mm2fg8rngzgg5c4cp3-system.drv` |
| diagnostic | `/gnu/store/57grj4sjphf9bw8184lm1p1ami4f79ji-system.drv` |
| protocol-control | `/gnu/store/yzgnn2gnw4fw0fr6kngxhn5b51s5a61c-system.drv` |
| reader-interaction | `/gnu/store/mjnjgcasxyjzd6510qkp730d98982hd5-system.drv` |

Its three unpatched graph files report the independently accepted reusable
AArch64 package derivation and output:

```text
/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv
/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0
```

The diagnostic graph instead reports the unbuilt diagnostic derivation
`/gnu/store/pb5v7rqa5iqwc98qzjpbnk474qgqbvmm-gvisor-source-built-diagnostic-20260831.0.drv`
and the reviewed patch. The demonstrated cache seam is after each lowering, so
it does not itself show those four one-line derivation records were forged. It
does prevent the packet's 2,729/2,732/2,747/2,756-entry requisite files from
serving as independently accepted dependency-conversion evidence.

The pre-conversion sources remain content-addressed in the earlier finite
candidate `/tmp/opencode/book-source-final-current-candidate.IMWonc/`, whose
recorded map and roster identities are:

```text
5263f32a30034efb52d421aa6e931f6c940963f962e943f54a67680be3057317  SOURCE-MAP.tsv
8a1924dbb3b0593eae52d12a553fafbc7ca82ae2f561a04ba71b83cae281fb1b  SOURCE-ROSTER.txt
```

That roster still lists all four old system files, which reverified as:

```text
341ca90202c24a2144087bf7f8e070880c0d27f08ad2240525ff303c1ea6a5c6  source-control
6a1c42eea0c4949fa21d77579b89bef742d1a446027144d3c3e379bfdcad55ed  diagnostic
81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047  protocol-control
eba953b32744304221537e2bc1d990c0ad18ca9d56a35afb92b1137acc88f6e8  reader-interaction
```

That pathname is mode-writable, as the earlier public-source review already
recorded. Preservation therefore rests on those recorded content identities
and the earlier roster, not on treating the pathname itself as immutable. The
new source comments and manifests preserve the important provenance rule: old
CONTROL/diagnostic/reader QEMU results apply only to exact local-v12 bytes and
are not new source-package proof.

## BEP-1 counterexample

Most Guix entry points use `run_guix_view`, which assigns
`HOME=/nonexistent`, `XDG_CACHE_HOME=/nonexistent`, disables auto-compilation,
clears the compiled load path, and supplies only the finite positive module
view before starting `guix time-machine`. The exception is line 188 of the
reviewed `run.sh`:

```sh
env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    guix gc --requisites "$derivation" >"$run_root/$name-requisites.txt"
```

This command is also not the time-machine-selected Guix client. In the review
environment it resolved as:

```text
/home/wkelly/.config/guix/current/bin/guix
  -> /gnu/store/07imsdnmnf8yjid83rsccmlbs2h30wqa-guix-command
```

The exact Guile auto-cache key under a caller-selected cache was:

```text
$XDG_CACHE_HOME/guile/ccache/3.0-LE-8-4.7/gnu/store/
  07imsdnmnf8yjid83rsccmlbs2h30wqa-guix-command.go
```

I compiled a tiny reviewer canary to that exact key. For a stronger test than
the candidate's environment clearing, I removed all three `GUIX_*` variables
plus `GUILE_LOAD_PATH`, `GUILE_LOAD_COMPILED_PATH`, and
`GUILE_EXTENSIONS_PATH`, then set only the caller-controlled `HOME` and
`XDG_CACHE_HOME`. The exact four direct `guix gc --requisites SYSTEM.drv`
shapes all returned zero, wrote the canary, and emitted reviewer-selected text.

The forged unpatched graphs contained only the accepted gVisor derivation. The
forged diagnostic graph contained two nonexistent but correctly named paths:

```text
/gnu/store/00000000000000000000000000000000-gvisor-source-built-diagnostic-20260831.0.drv
/gnu/store/11111111111111111111111111111111-gvisor-diagnostic-systrap-error-context.patch
```

The frozen `check.py` does not require the system derivation to be present, does
not require every reported path to exist, and identifies most package choices
by basename. Consequently all four forged files passed. Their checker outputs
have exactly the hashes of the supplied green logs:

| graph | forged and supplied PASS-log SHA-256 |
|---|---|
| source-control | `c204e2ed3aef814a8fadf267921283e761973eba5ccabd21cae1cc421a97bada` |
| diagnostic | `29c5b9c08861d5a79bcaed90b807bf94253e2bd004dfbb18d7bd64267d1cfa56` |
| protocol-control | `d57e2edba3cc1c4cf2f4cb22156d5d8bdf4e1b817f1e44dbcaf18cbae1755ae4` |
| reader-interaction | `a7665e5831cc9f87e92af1a8e7a78d1d45cddb1811a2bfe80de5786306832736` |

This counterexample does not mutate the candidate, packet, Guix store, or any
accepted artifact. It demonstrates arbitrary caller-cache execution and forged
green dependency checks before the graph evidence is trusted.

Reviewer evidence is retained at:

```text
/tmp/opencode/book-execution-public-independent-review-20260906/final/
e973aebfcc75dc202e56001ac28dbae79df3b78e4e7b737cb317d263d463e548  EVIDENCE.sha256
```

All 26 entries in that evidence manifest reverified. The malicious cached
`guix` bytecode is
`126f1edda0493a398fc37a093fc2438efddde7e0084c0dc218a6015c9d951bd5`;
the canary is
`0d34219669f0d4f3a44b6d2d7e7a047efe4b9a674d3128121d4c171e6aea0c2e`.

## Required successor

A successor should:

1. create a fresh mode-`0700` private `HOME` and `XDG_CACHE_HOME` before every
   Guile executable, including dependency traversal;
2. route traversal through the pinned time-machine Guix boundary, or otherwise
   pin and isolate the exact client before startup;
3. add this preseeded exact-`guix-command.go` canary and require it to remain
   absent;
4. require each graph to contain its exact root system derivation and only
   existing canonical store paths, and pin the exact expected diagnostic
   runtime derivation rather than accepting a matching basename; and
5. freeze new source, launcher, checker, packet, derivation, and output hashes,
   then rerun the bounded gate in rung order.

Only after that fresh review may these public systems advance to image
construction or separately authorized QEMU. This rejection does not reopen the
accepted reusable unpatched AArch64 gVisor package itself, the retained kernel
source gate, Book Protocol/Session/native joins, or any guest BSG-2 work. It
makes no runtime, Systrap-isolation, image, QEMU, ARM, device, durability, or PR
acceptance.

No implementation, frozen packet, guest source, kernel, patch, image, staging
area, commit, branch, remote, mount, or device was changed. No gVisor, kernel,
system, or image build; Bazel; runsc; QEMU; ARM execution; deployment; or
hardware operation occurred. The only compiled code was the bounded native
reviewer canary used to prove BEP-1.

## Focused v4-final recheck — BEP-1 closed

### Disposition

**ACCEPT the exact v4-final public-source conversion and close BEP-1.** The
successor isolates every Guix startup that consumes or validates the candidate,
including both dependency traversals for every system. The original exact
cached-bytecode graph forgery did not execute against the actual successor
runner, and the new checker rejects all four old forged graph files on their
contents independently of that isolation.

This acceptance is limited to the finite public source/package integration and
the four authenticated AArch64 system derivation graphs below. It does not turn
the historical local-v12 runs into source-package evidence and does not accept
current runtime behavior, Systrap isolation, an image, QEMU, ARM execution, the
guest state system, cancellation/timeouts, durability, deployment, hardware, or
PR readiness. Current source-package system runtime remains unproven pending a
separately reviewed run.

### Frozen successor boundary

The accepted packet is:

```text
/tmp/opencode/book-execution-public-review-20260906-v4-final/
2ee45158f8fea25bb52bc0447a3e7d41e5a76c25538c1537ca548602589d2ff3  MANIFEST.sha256
```

The manifest binds 100 other regular files; the packet therefore has 101
regular files including `MANIFEST.sha256`. All 100 listed hashes reverified.
There are no symlinks, special files, or writable entries. Its two executables
are mode `0555`; its other 99 regular files are mode `0444`.

The remaining top-level packet identities are:

```text
42551cd2bc3849d9db9ca27ebcad7da75401c7a9969aad816598a192bda02a49  candidate-files.sha256
387d4f3baa8d31ee154f1f218d80cc8b424b737400d3929fb7770b422da1151f  v4-delta-files.sha256
7bb9ccb0dbc626da1bd8496c2d8d55d1ebd307b1c10ddb168480fc1ea502e7cf  v3-to-v4.diff
```

All 13 candidate identities matched the live source at review and rerun time.
Independent comparison with the frozen v3 packet confirmed that the only delta
is exactly these six public-source files:

| file | v4-final SHA-256 |
|---|---|
| `README.md` | `e50a3cb2f68c30c9b59181e054ba3dfe6c2899cc82c016c563c1e5c2a29b4928` |
| `SOURCE-MAP.tsv` | `78a364f82ef96a1bc702e0e445e0076bf7f6dd4b0eab125452c22c8532d7439f` |
| `check.py` | `d3434137f715901940aa109b3827a696f017a784eab56275aafd000a07e13929` |
| `guix-isolated.sh` | `c64710c3c4fcdc9f91da448b8a651438ee3bcec36527a5644dc0ea389b43bb56` |
| `run.sh` | `411b1cff7822459c03307f04dce520e441ae20259fc9b381b6adb0043f26f9a6` |
| `test_cache_isolation.py` | `f34fb6a82bb8849a8622d488d47c1160624d9412e8e6fffb3ef9bc740dcb7ee7` |

The four systems remain byte-identical to v3 at their hashes on lines 51–54 of
this review. The original v3 packet, BEP-1 evidence, and rejected review prefix
are preserved at identities `e7237bc2…`, `e973aebf…`, and `6dd4cbf2…`; this
focused acceptance does not rewrite that failed-gate history.

The revised finite map has 109 unique rows: 22 modules, 76 assets, and 11
checks. It adds the isolated launcher and cache regression while preserving the
same module and asset counts. All eight post-preparation public-source helpers
are mapped. `SOURCE-MAP.tsv` itself remains the separately reviewed initial
launcher input; the preparer copies it into capsule metadata rather than
silently treating it as a runtime helper.

### Guix startup and helper audit

The exact `run.sh` plus finite map form the declared trusted, versioned host
bootstrap boundary. This is not a signature or authentication mechanism for an
arbitrary repository. Within that boundary:

- the runner resolves Python, Guix, Guile, and Guild without executing them,
  requires canonical regular executable Guix-store targets, then replaces its
  ordinary host `PATH`;
- before the only pre-capsule Python execution, it obtains the preparer hash
  from the finite map and verifies the regular non-symlink preparer; Python then
  runs as the absolute store interpreter with `-I -S -B`;
- all later helpers are addressed through `capsule/repo`, checked against the
  prepared map, and run from that read-only copy. In particular,
  `isolated_launcher=$prepared_tool/guix-isolated.sh`; the runner never executes
  a mutable-worktree copy of the new launcher after capsule preparation;
- the top-level `run.sh` is not falsely presented as re-executed from the
  capsule. It remains the explicit initial bootstrap at the exact accepted hash
  above;
- the one bootstrap-client version probe uses the absolute immutable Guix
  script under a separate `env -i` with private directories and empty `PATH`;
  every time-machine operation—version, fixed-source resolution, host test
  shell, system-object load, missing-module negative, all four lowerings, and
  all eight graph traversals—uses the authenticated capsule launcher;
- `guix-isolated.sh` performs no discovery. Before the bootstrap Guix process
  starts it executes `/usr/bin/env -i`, assigns the runner-created private
  `HOME`, all XDG roots, `TMPDIR`, an empty `PATH`, the one positive module
  view, empty compiled/extension paths, and disabled auto-compilation, then
  enters the pinned `channels.scm` time machine; and
- the `-L` package view contains zero Scheme files. No direct ambient `guix gc`,
  local wrapper, broad repository load path, caller home/cache, or caller Guile
  path survives to a Guix query.

The complete supplied gate and independent rerun both resolved:

```text
bootstrap Guix: /gnu/store/07imsdnmnf8yjid83rsccmlbs2h30wqa-guix-command
bootstrap SHA-256: 97e13089e1003f10673888d02bf2868972005f1fbec55f06fdaa2dfdfe89f014
pinned Guix: guix (GNU Guix) f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c
```

Both runs also recorded identical immutable Python 3.11.14 and Guile/Guild
3.0.11 paths and hashes. Empty `PATH` was not papered over by a fallback: the
actual source resolution, nested Guile/Guild probes, Scheme system loads,
lowerings, and traversals all completed through explicit store/profile tools.
The seven private process directories were real, empty, mode-`0700`
directories at the end of the independent run.

### Independent original-counterexample replay

Before invoking the actual v4 runner, I compiled the original BEP-1 payload
shape to the exact caller-XDG cache key for the exact resolved bootstrap Guix:

```text
/tmp/opencode/book-execution-public-v4-independent-recheck-20260906/
  outer-poison-xdg-cache/guile/ccache/3.0-LE-8-4.7/gnu/store/
  07imsdnmnf8yjid83rsccmlbs2h30wqa-guix-command.go
0621c2fdeb2e4ed6b385ae141df1d79a799dc57ef2e69bb88d627dba265a869d  guix-command.go
```

That cache object was newer than the immutable Guix script, wrote a persistent
marker if loaded, and emitted the same minimal forged default/diagnostic graph
shapes used to establish BEP-1. I then invoked the actual candidate `run.sh`
once with that poisoned `HOME`/`XDG_CACHE_HOME`, hostile Guile load/compiled/
extension paths, and hostile Guix package/build variables.

The complete gate returned zero. The outer marker was absent after completion.
The runner's separately generated default-HOME cache, XDG cache, and compiled
module-path markers were also absent. Their source never removes a marker, so
the final absence, together with the immediate internal checks after every Guix
operation, establishes that no canary executed before a checker and was merely
rejected afterward. In the graph loop specifically, marker checks occur after
each of the two real queries and before `check.py` reads the graph.

As defense in depth rather than a substitute for process isolation, I fed the
four exact old forged graph files from the v3 independent evidence to the new
frozen checker. All four returned status 1: three lacked their exact root system
derivation and the diagnostic file named nonexistent store paths. The new
checker also requires a nonempty duplicate-free graph, existing canonical store
paths, the exact default or diagnostic gVisor derivation, and the prior
forbidden-package/manual-path rules.

### Accepted graph evidence

I independently parsed every supplied graph and every graph from my actual
rerun rather than relying only on the checker logs. Each primary/replay pair is
byte-identical, and my four primary graphs are also byte-identical to the
supplied packet graphs:

| system | exact root derivation | lines | graph SHA-256 |
|---|---|---:|---|
| source-control | `/gnu/store/8nis6vrw88f960mm2fg8rngzgg5c4cp3-system.drv` | 2,729 | `9d7edb16203c40d4cb9310453c22c16d095af0fd9e778bd0b8c62aefd309fb17` |
| diagnostic | `/gnu/store/57grj4sjphf9bw8184lm1p1ami4f79ji-system.drv` | 2,732 | `0c2c3cea9a3a0d3a2d38fcbbd2593c5d7204eeacfb38b2100280c1d91876013b` |
| protocol-control | `/gnu/store/yzgnn2gnw4fw0fr6kngxhn5b51s5a61c-system.drv` | 2,747 | `09447ffecf06eda28d044735a25e588f44b128c42c5f0b385f609650e56113d8` |
| reader-interaction | `/gnu/store/mjnjgcasxyjzd6510qkp730d98982hd5-system.drv` | 2,756 | `9373581ce2518d38eebec246ba19c98810d2fc7b0aadaedce862ab1ba11aef05` |

Every list contains its exact root once and only existing canonical store
paths. The three unpatched systems contain exactly
`/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv`.
The diagnostic system instead contains exactly
`/gnu/store/pb5v7rqa5iqwc98qzjpbnk474qgqbvmm-gvisor-source-built-diagnostic-20260831.0.drv`
and one diagnostic patch. No graph contains `gvisor-bin`, a local-test/v12
wrapper, diagnostic/default crossover, or the manual local artifact root.

All eight supplied and independent graph attestations reverified against the
actual root derivation hashes, bootstrap identity, pinned version record, raw
and replay graph bytes, checker identity, checker log, and expected runtime.
The attestation is useful binding evidence, but the acceptance rests on the
real isolated Guix query and independent graph inspection—not on replaying two
copies of an unauthenticated forged input.

Reviewer evidence is retained at:

```text
/tmp/opencode/book-execution-public-v4-independent-recheck-20260906/
051f92843438816c5a85f173d306b95dfd343c49cbbfffbb615027a61103e293  EVIDENCE.sha256
fd0fb216705ade7fd353cf55e697325f0c8cf0cd89f34d6b8615251d92fda369  actual-run.stdout
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  actual-run.stderr
11ab8aba4e98a801138d7698b5be22e28250ff829ecc27d5456d418dd2510a80  validation.stdout
```

All 208 files listed by the reviewer evidence manifest reverified. One ad-hoc
reviewer assertion initially and incorrectly included `SOURCE-MAP.tsv` among
the map's runtime-helper rows. Inspection confirmed the documented separate
bootstrap role; the corrected 109-row/8-helper check passed. This was reviewer
setup error, not a candidate gate failure. The packet separately preserves the
first implementer v4 attempt that stopped at cache-fixture setup before source
resolution or lowering; only `v4-2` and the independent rerun are positive
evidence.

No implementation, frozen packet, prior evidence, guest/state source, kernel,
patch, image, staging area, commit, branch, remote, mount, or device was changed
by this recheck. No gVisor, kernel, system, or image build; Bazel; runsc; QEMU;
ARM execution; device access; SSH; deployment; or hardware operation occurred.
The only new compiled objects were bounded native reviewer cache canaries.
