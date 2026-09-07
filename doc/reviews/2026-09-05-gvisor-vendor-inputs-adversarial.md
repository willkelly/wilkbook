# gVisor release-vendor inputs adversarial review — 2026-09-05

## Scope and verdict

This review covers the fixed-input preparation package and the configured
analysis boundary for upstream `//:release`. It does not review or authorize a
gVisor compilation, six-file runtime package, source-built toolchain, image,
QEMU run, or sandbox execution.

**The exact realized artifact is internally consistent, but the vendor-input
gate is not yet accepted for promotion to runtime compilation.** Two
operational/audit manifest mutations pass the package's complete 11-test suite,
and the retained replay evidence does not independently record the claimed
networkless namespace. These are finite gate/evidence fixes; they do not call
for a general Bazel framework, another dependency-discovery design, or
all-toolchain-from-source work.

Reviewed identities:

- `pinenote/packages/gvisor-source.scm`:
  `8c733e25696a5f5fb2272955b544f3a99990b0c04c920c8fd184290b32c49e2d`
- `pinenote/packages/gvisor-dependencies.scm`:
  `e7f84a9a40d8690c992ccb8db72a438f81a0f242b1022f43fc0bd076f1c66734`
- `pinenote/tools/gvisor-package/vendor_manifest.py`:
  `cae17994e0b03538e35087b2491024f7e809d7877e5b0aadf428016fc80831aa`
- `pinenote/tools/gvisor-package/vendor_inputs.py`:
  `09ff4decc808251487958c3f77e8cff63bbc387b6a134079a9b048ab6e1d1bc7`
- `pinenote/tools/gvisor-package/test_vendor.py`:
  `e14c3972efc7f643d66f11e272516334fd28f37779ee392a4dba97bd1b273ed2`
- `pinenote/tools/gvisor-package/offline-check.sh`:
  `f11ee8932eb4e980d0e4a802bde1153d15341040c68d27bd8d18878785acf2e0`
- `pinenote/tools/gvisor-package/emit_guix_inputs.py`:
  `d89f961dd8e6bd8579a2ec71d0eefcaf2df34fa99ebf270d2384e39a6d3f62b3`
- `pinenote/tools/gvisor-package/release-vendor-manifest.json`:
  `2d26ed16be5c4a1cfd0810b96ce7c2f42237d8e8dd6e5ac046915792311e924e`
- `pinenote/tools/gvisor-package/release-MODULE.bazel.lock`:
  `8402c7beb4baf2c666f4b78e400ea3f15514b56117598c2cb5411d6a35208d34`
- native configured labels:
  `9412d5a8944f727ca402d864f2504de30809df71e9d0fabd307b9b6c837e573f`
- AArch64 configured labels:
  `60473defe06cb496ad55ebac640e21a1799444441c5111c2c8df4655dd0f4777`
- packaging-only rules_go patch:
  `e04ae0d3acf5502887130edd7651393fb15aa20ed3fdc19cdf9530f12555c460`
- `doc/gvisor-packaging.md`:
  `62643fa26b543f30689ff1c000bbb481c0152b733e5379df0c978a199f7ec62e`
- realized preparation output:
  `/gnu/store/3dg6drindi77hb47bbybdfz9jng1snvi-gvisor-release-vendor-inputs-20260831.0`
- output recursive hash:
  `0prgg1kcbakk73kj1jsf77nd12nb6kw12akzpc93jxr6kcrzlsrb`

## Exact-artifact evidence that passes

- The generated Scheme table is byte-for-byte reproducible from the manifest.
  It defines 117 individually hashed HTTPS `url-fetch` origins and one fixed
  BCR Git origin. There are 118 input names, 118 hashes, no duplicate input
  names, and no unhashed or non-HTTPS URL origin. The source URLs remain mutable
  locations, but their accepted bytes are fixed by Guix hashes.
- The BCR checkout independently reproduces recursive base32 hash
  `057akiiiqiigylnrsi7bqyrdkfhq1h1xpsblrpyni6p614wz8paz` and hex hash
  `5f5df43909e69a68fdcd74e9db030c18bad9b2c7eb449d2df52f461c639cea14`.
  It contains no symlinks. The Bazel bootstrap independently has SHA-256
  `17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c`.
- Every installed member was checked against the reviewed manifest: 359
  distinct CAS files, 24 exact canonical-ID markers, 273 local-Go-proxy files,
  and 319 target-registry files, with no missing or additional member. The
  installed manifest, lock, patch, and closure files match their committed
  hashes. The output contains no symlink or preparation-directory/home path.
- All 25 general archives and 91 Go proxy ZIPs were inspected without
  extraction: 116 archives and 61,994 members total, no absolute or parent
  traversal name, duplicate member name, special file, or escaping link. The
  14 links are contained relative symlinks in the gRPC and
  protoc-gen-validate archives. The assembled output itself resolves to
  ordinary files and directories only.
- Current provenance is correct even though its validator is incomplete. All
  21 BCR-module archive URLs and hashes match `source.json` in the fixed BCR
  checkout; all 91 Go URLs match their canonical local-proxy paths. All 129
  repository rows link to the current fixed inputs or to existing generator
  repositories. The 118 recorded license evidence files match the retained
  unmodified discovery vendor tree. The resulting statuses are 115 recorded,
  13 generated-with-inherited-license, and the one documented rules_kotlin
  omission.
- Missing `bcr-snapshot`, `rules_go`, and a selected Go-module input were each
  rejected by name before assembly. Wrong bytes were rejected by SHA-256. An
  extra input-map ID and an extra configured-label artifact were also rejected.
- The 13 source-inventory tests and 11 vendor tests pass. Both retained replay
  cquery files compare byte-for-byte with the committed native and AArch64
  closure files. Both vendor and cquery logs report zero actions; both existing
  missing-input negatives terminate with `download is disabled`.
- Native and AArch64 remain separate configured analyses: 18,812 versus 18,791
  labels, each with 106 external repository spellings and the same 129
  canonical vendor repositories. No `prebuilt_protoc` repository or label is
  present. The closure contains source `@com_google_protobuf//:protoc`, Abseil,
  and zlib targets under the explicit false prebuilt-protoc setting.

These facts establish the current **analysis input closure**, not the complete
set of action-time compiler tools, successful gVisor compilation, executable
layout, or runtime behavior. Build-time discoveries remain a separate gate.

## Blocking findings

### 1. Canonical-ID marker identities are not anchored

`validate_manifest` validates each marker as a 64-hex string and requires a
total of 24, but it does not pin the mapping from CAS content hash to canonical
ID. Replacing one marker with a different valid 64-hex value while preserving
the count passed `vendor_inputs.py check`. More importantly, the entire 11-test
suite also passed against that altered golden manifest.

This is operational metadata, not commentary. The earlier failed replay
already established that byte-identical archives without the right marker can
be rejected by Bazel and cause a disabled-download failure. The current exact
mapping is good; the package gate does not protect it from silent drift.

Minimum correction:

1. Pin the exact manifest SHA-256 in the package check path, or pin a digest of
   the sorted `(CAS SHA-256, canonical ID)` mapping. The current 24-row mapping,
   serialized as sorted tab-separated rows, hashes to
   `29acb447986ca0c9e5b9ec29abf7305c082b5ce52a06ba50c24ec6c788129715`.
2. Add a behavioral test that substitutes a valid-looking marker and requires
   rejection. A count/shape assertion is not sufficient.

### 2. Repository provenance and license relationships are not validated

Replacing the first repository's provenance with a nonexistent fixed-input ID,
a wrong provenance kind, and an unrelated HTTPS URL passed both manifest check
and the full 11-test suite. `validate_manifest` currently checks repository
count, canonical-name ordering, reachability text, and protoc exclusion, but
not the provenance or license relationships that justify the audit claims.

The current 129 rows independently check out, so this is a gate defect rather
than evidence of a bad current origin. Add relational validation and mutation
tests requiring that:

- every `provenance.input` names an archive or Go input and exactly matches its
  kind and URLs;
- every `generated_by` and `license.inherits_from` names the same existing
  generator repository;
- archive `used_by_repositories` and Go `repository` links are bidirectionally
  complete; and
- license evidence paths and record shapes are safe and internally complete.

Pinning the exact manifest hash in the package check is a useful outer seal,
but should accompany these behavioral relations rather than replace them.

### 3. The retained replay does not prove its network namespace

The positive logs contain no external URL and the replay correctly uses fresh
home/output/cache roots, a file-only `GOPROXY`, disabled sumdb, local registry,
`--nosystem_rc`, `--nohome_rc`, lockfile error mode, and
`--repository_disable_download`. Those facts strongly establish no Bazel/cache
fallback for the exercised paths.

However, `offline-check.sh` only instructs the caller to run it in a
networkless Guix container; it neither verifies nor records that condition.
The retained evidence has no wrapper invocation, network-namespace identity,
interface inventory, or route inventory. Therefore the manifest assertion
`networkless_analysis_proven: true` cannot be independently attributed to an
actual no-NIC run from the retained evidence alone. Downloader disablement is
not a substitute for build-level network isolation because repository rules or
subprocesses can use mechanisms outside Bazel's downloader.

Rerun the bounded zero-action replay after other active builds finish, inside
the pinned Guix container with networking omitted, and retain the invocation
plus a preflight proving only the isolated loopback/no external route is
present. Also clear inherited proxy and Go bypass variables such as
`GONOPROXY`, `GOINSECURE`, and proxy environment variables. The eventual Guix
runtime derivation must independently rely on the ordinary networkless build
sandbox; CA certificates need not be removed from fixed fetch inputs.

## Disposition

Do not redefine this increment as a runtime package and do not start the
ordinary source-built runtime package on the strength of this gate yet. Close
the two silent manifest mutations and retain the network-namespace proof, then
perform a focused recheck. The actual vendor graph does not need rediscovery
unless those corrections change its bytes.

The exact prebuilt Bazel 8.3.1 and Go 1.26.3 inputs are acceptable because they
are fixed and explicitly labelled as bootstrap binaries. No source-built Bazel
or Go package is required for this stage. The diagnostic build's prebuilt
protoc choice is a separate graph and is unaffected by the source-protoc
packaging closure reviewed here.

This review added only this record. It did not fetch or realize an origin,
invoke Bazel or Go, compile gVisor, mutate any Bazel cache or retained evidence,
poll the separate diagnostic build, or perform QEMU, runsc, hardware, SSH,
UART, mount, or device operations.

## Focused recheck — 2026-09-05

### Verdict

**Accepted. All three findings above are closed for the fixed-input
`//:release` analysis boundary.** This acceptance permits work to proceed to
the dedicated `gnu-build-system` runtime-package gate. It is not evidence that
gVisor has compiled, that the six release executables exist, or that any
runtime, image, QEMU guest, or hostile-book policy has passed.

Rechecked identities:

- `pinenote/packages/gvisor-source.scm` is unchanged at
  `8c733e25696a5f5fb2272955b544f3a99990b0c04c920c8fd184290b32c49e2d`;
- `pinenote/packages/gvisor-dependencies.scm` is unchanged at
  `e7f84a9a40d8690c992ccb8db72a438f81a0f242b1022f43fc0bd076f1c66734`;
- `pinenote/tools/gvisor-package/vendor_manifest.py`:
  `373bf691711da9783fe1ecf46cc56609591fed63830e30040fffe30e2107f17a`;
- `pinenote/tools/gvisor-package/test_vendor.py`:
  `5ed78adf66dce2a3c9b9518deb93b5849eaf55c16310c47c7d1dec03cd42ec87`;
- `pinenote/tools/gvisor-package/network_namespace.py`:
  `cecaf100c5dcd746389bbcb11d2faf3702d71c26d17ba4e25a997933825ba158`;
- `pinenote/tools/gvisor-package/offline-check.sh`:
  `2c73610649831e6ec7f8960c25ad443bf7755ab0744f9597835c12540ba9c168`;
- `pinenote/tools/gvisor-package/release-vendor-manifest.json`:
  `00cf6fc80955b36d6bce3344dbbdeb546eb718dff923bfe47f5449ce321d4be7`;
- `doc/gvisor-packaging.md`:
  `fb1c8243bcd4880ad2282f5f37b8edff99f1a0c4e8595d04e6ba82558f69ee0c`;
- realized fixed-input output:
  `/gnu/store/6x5h6fpqysmyam51c3zy978nk6fmrq68-gvisor-release-vendor-inputs-20260831.0`,
  recursive hash
  `1sfan3bnkkx7cd6ih9ldkdgr6cprnnzbnfmxs48wck7ik8180ss1`.

The lock, packaging-only source-protoc patch, generated 117-origin table, and
native/AArch64 closure files are unchanged. Their closure SHA-256 values remain
`9412d5a8944f727ca402d864f2504de30809df71e9d0fabd307b9b6c837e573f`
and `60473defe06cb496ad55ebac640e21a1799444441c5111c2c8df4655dd0f4777`.

### Finding 1: canonical-ID relationships — closed

The validator now derives each archive's expected default HTTP canonical ID
from its exact ordered URL list, compares the complete per-archive marker list,
and seals the sorted 24-row `(CAS SHA-256, canonical ID)` projection at
`29acb447986ca0c9e5b9ec29abf7305c082b5ce52a06ba50c24ec6c788129715`.

I independently repeated both relevant counterexamples. Replacing a marker
with another valid 64-hex value and swapping two real valid markers while
preserving syntax and count both fail with `archive canonical-ID relationship
changed`. The 22-test suite contains both regressions. This closes the prior
count-only hole without changing any fixed origin or configured graph.

### Finding 2: provenance and license relationships — closed

`validate_repository_relationships` now checks fixed-input IDs, exact origin
kind and URLs, archive and Go backlinks in both directions, Go source/license
identity, generated-repository aliases, generator existence, and exact license
inheritance. It validates evidence path/shape/hash metadata and seals the
repository/origin/license projection at
`f1f8cc762586e9b2ad662c508815223d7f8609b076949d4d1c953c331a4bc3dc`.

I independently repeated the original nonexistent-input/wrong-origin
counterexample; it now fails with `repository provenance names nonexistent
input`. The expanded tests also reject independent kind/URL drift, backlink
permutations, alias/inheritance redirection, unsafe evidence paths, fabricated
replacement of an unknown, and license-record permutations.

This verifies accurate provenance relationships for the reviewed graph; it is
not a complete legal review and does not claim every dependency is freely
licensed. `rules_kotlin+` remains the sole explicit `missing` license record
rather than being hidden or replaced with inferred evidence. The thirteen
extension-generated repositories remain explicitly tied to their canonical
source repositories.

### Finding 3: measured no-NIC replay boundary — closed

Accepted retained evidence:

- `/tmp/opencode/gvisor-guix-vendor-offline-netns-accepted-v4-ugR1x4`;
- `evidence-summary.json` SHA-256
  `cc7dd7c908fbd90ff4e5926bbca0ae3139f9db8de58a846c540b9c6fbb8ea0da`;
- `SHA256SUMS` SHA-256
  `e99dfb22f49deb9dbd4f53578301a5c6ab40949583161ec17630df547a4e43c1`.

Every entry in `SHA256SUMS` verifies. The retained invocation uses pinned Guix
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c`, `guix shell --container
--pure --no-cwd`, and no `--network` option. It records an outer namespace with
11 non-loopback interfaces and 51 external routes. Both replay containers use
the distinct namespace `net:[4026536204]`, expose only `lo`, and have no
external IPv4 or IPv6 route.

The boundary is measured in executable code rather than inferred from Bazel
flags. `offline-check.sh` rejects a missing or unchanged outer snapshot before
source/cache preparation. Its `run_bazel` wrapper starts
`network_namespace.py` for every Bazel operation; that same process re-reads
the namespace, interfaces, routes, forbidden proxy/bypass variables, and Go
environment and then immediately replaces itself with Bazel via `os.execvp`.
Both architectures retain exactly four successful pre-exec events:
`vendor-positive`, `cquery-positive`, `cquery-missing-vendor`, and
`vendor-missing-archive`.

I independently checked the event records and tested the executable validator
with a proxy variable, a remote `GOPROXY`, and a changed namespace identity.
Each was rejected before an event could be recorded. The retained real
non-isolated invocation exits 1 with `network namespace did not change from
the outer process`; its work directory remains empty. Both positive vendor and
cquery logs report zero actions, both configured closure files compare
byte-for-byte, and both missing-input negatives report `download is disabled`.

### Gate disposition

The fixed-input graph is accepted as the complete repository input set needed
for the exercised zero-action native and AArch64 `//:release` analyses. It is
not yet proof of the complete action-time compiler dependency set. The next
runtime-package gate must still use fresh caches and a networkless Guix build,
replace the Coral crosstool's FHS paths with explicit store inputs, compile and
install exactly the six release executables, and validate their ELF, linkage,
version, and toolchain identities. Any newly reached repository or host tool is
a package-input failure to resolve explicitly, not permission for network or
ambient-cache fallback.

The accepted prebuilt Bazel 8.3.1 with embedded JDK 24 and Go 1.26.3 remain
honestly labelled bootstrap inputs. This review does not require an
all-toolchain-from-source variant and makes no claim that all dependency
sources have already become build actions.

Focused checks performed here were bounded host-side validation and inspection
of retained evidence. I did not edit implementation or packaging files,
invoke Bazel or Go, fetch or realize dependencies, compile gVisor, mutate a
Bazel cache, inspect or poll the separate diagnostic build, or perform QEMU,
runsc, hardware, SSH, UART, mount, or device operations. This focused recheck
edited only this review record.
