# gVisor source-inventory adversarial review — 2026-09-05

## Scope and verdict

This review covers only the reusable source pin and dependency-inventory first
increment. It does not review or authorize a gVisor runtime package, a Bazel
build, an image, QEMU, or any PineNote execution policy.

**The realized artifact is accepted as evidence for the exact current source
pin and its directly parsed declarations, but the inventory change gate is not
yet accepted.** Two mutations that must be visible are currently silent green:
`.bazelversion` changes and custom Starlark repository rules that call
`repository_ctx.download`. These are finite parser/test blockers, not a reason
to require a general Bazel framework or an all-toolchain-from-source build.

Reviewed identities:

- `pinenote/packages/gvisor-source.scm`:
  `2a4d7e5bc09c105123c7d33335d5f8dd73a9f8999fabd0067ab186561955d555`
- `pinenote/tools/gvisor-package/inventory.py`:
  `34305680d22e550b0990bb33b8cee8889e190f216012f738ff1e810524b7c264`
- `pinenote/tools/gvisor-package/test_inventory.py`:
  `a1d2e2121dce22dfee129278a8e46c92fa9ae01e0231819a26bf79cfe7f2c24c`
- `pinenote/tools/gvisor-package/pinned-source-inventory.json`:
  `00d88f84bd3c106e3201a493ed1997a05dc31f422aedfb268127482865ffca0d`
- `doc/gvisor-packaging.md`:
  `27fc06f601181eef4c25a6cfe1f243f15e28def6ae331d18cda49a214409ea74`
- realized preparation output:
  `/gnu/store/mb3cnma85bi8vj371f327sx2nkgbwsh4-gvisor-source-inventory-20260831.0`
- derivation:
  `/gnu/store/kwmh3ifz1sv2zr12ka8z88xd22ldbpai-gvisor-source-inventory-20260831.0.drv`

## Evidence that passes

- The fixed `git-fetch` origin names exact commit
  `fd2f6b2674208086e324c2f739155eb7e1b48ff2`. The realized source at
  `/gnu/store/wbr9z2rbw73lvgwnyyfgm2ifkln5ad7f-gvisor-20260831.0-checkout`
  independently hashes recursively to
  `12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy`. Its four recorded
  metadata SHA-256 values match the manifest. The source has no `.gitmodules`.
- The cached tag is annotated, points to the same commit, and has no signature;
  the document's commit-plus-content-hash provenance claim is accurate. Commit
  time `1788467832` also matches the documented source epoch.
- The installed tool reproduced the committed manifest byte-for-byte. Its six
  unit tests passed, as did `check.sh` against the clean exact checkout. The
  derivation contains the source checkout, Python, tool, tests, and golden
  manifest as explicit inputs; it does not invoke Bazel or Go and does not
  impersonate a runtime package.
- The current direct inventory is accurate for the parser's stated surfaces:
  18 root `bazel_dep` declarations, six `use_extension` declarations, nine
  explicit root/reachable-local-extension HTTP declarations, eight with an
  upstream digest, one unhashed `google_root_pem`, and 122 selected Go modules
  (43 direct, 79 indirect) with the stated 445 `go.sum` lines.
- Removing the Coral HTTP hash produced manifest drift, and
  `--require-explicit-hashes` rejected and named it. A dynamic URL in a known
  HTTP rule was rejected. A nested local `use_extension` was rejected.
  Conditional known HTTP declarations are conservatively inventoried even in
  a false branch; comment text is correctly ignored. Go-version and duplicate
  root-module mutations fail the pinned metadata hash gate.

These counts are a **direct source inventory, not a resolved or transitive
Bazel fetch graph**. The absent lock, BCR metadata and transitive modules,
external Python/Go/Gazelle extension results, Go SDK, and archive identities
remain blockers exactly as the generated manifest says.

## Concrete findings

### 1. `.bazelversion` is asserted, not read — blocking

`inventory.py` hard-codes Bazel 8.3.1 but neither hashes nor parses
`.bazelversion`. Replacing its contents with `9.0.0` left output byte-identical
to the golden manifest. Add the file to the pinned metadata and derive/verify
the required version from its single line. Add a mutation test for change and
absence.

### 2. A valid custom repository download can be omitted silently — blocking

The AST walk recognizes only `archive_override`, `http_archive`, `http_file`,
and `maybe(http_archive)`. In a scanned local extension, an instantiated
`repository_rule` whose implementation called `ctx.download(...)` left the
manifest byte-identical. The exact three current local extension files contain
no such primitive, so this does not change the current count; it does make the
tool unsafe as an upgrade drift gate.

The smallest correction is fail-closed rather than general Starlark
evaluation: pin hashes for every traversed local extension file, reject or
inventory calls ending in `download`/`download_and_extract` and declarations
using `repository_rule`, and add the concrete mutation as a test. Keep external
module extensions explicitly unresolved until the Bazel lock/repository graph
is imported; do not claim this static scanner computes that graph.

### 3. Two documentation phrases overstate or defer the practical package

`doc/gvisor-packaging.md` calls the manifest the “full list”; qualify this as
the full list of the directly parsed surfaces, not the transitive fetch
closure. More importantly, lines 123–125 and 151–154 make source-built Bazel
and Go the intended/default prerequisite. That is not required for the first
reusable gVisor source build. An exact prebuilt Bazel and exact Go SDK bootstrap
are acceptable when package names, descriptions, inputs, and reports label
that provenance honestly. An all-toolchain-from-source variant is separate
later work.

## Cheapest acceptable next packaging pattern

Use a dedicated `gnu-build-system` package with custom phases; the pinned Guix
channel has no Bazel package/build system, and its old
`go-gvisor-dev-gvisor` is only a stale `#:skip-build? #t` source input. Do not
introduce a general Bazel framework now.

1. Make the official Bazel 8.3.1 launcher a hash-pinned native bootstrap input
   and label it as prebuilt. Record that its launcher carries its Java runtime
   (an existing 8.3.1 install exposes embedded Java 24); do not silently use
   ambient Java. Preserve the known launcher SHA-256
   `17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c`.
2. Supply exact Go 1.26.3 as a separately identified fixed input and prevent
   `rules_go` from querying release JSON or downloading an SDK. Pinned Guix Go
   1.26.5 is not identity-equivalent. Guix Python 3.11 may satisfy host Python;
   Bazel's Python extension outputs still belong to the resolved repository
   closure.
3. Generate and review the exact lock/repository graph once, then turn every
   release-reachable registry record, BCR module/archive, Go module, and
   extension-generated repository into named fixed Guix inputs or an equally
   explicit content-addressed vendor input. A mutable Bazel cache and Go `h1`
   values alone are insufficient.
4. Patch the Coral crosstool's `/usr/bin/aarch64-linux-gnu-*` and gold-linker
   assumptions to explicit Guix store inputs. Keep build-platform Bazel/Java/
   Python separate from the output target: first prove native x86_64 output,
   then an x86_64 build producing ARM64 output without executing it.
5. Require a network-disabled build from empty local home/output/repository/
   action caches, followed by a missing-vendor negative with a fresh output
   base. Only then validate and install the exact six-file release layout.

The eventual runtime package must remain reusable and policy-neutral. Existing
Systrap, namespace, DirectFS, networking, sidecar, kernel, and PineNote gates
remain consumer/runtime concerns and are not relaxed by this preparation work.

No implementation file was edited by this review. No Guix realization,
dependency fetch, Bazel/Go invocation, gVisor build, mutable Bazel-cache access,
image, QEMU, runsc, hardware, SSH, UART, or device operation was performed.

## Focused recheck: inventory change gate closed

The focused recheck reviewed this corrected snapshot:

- `pinenote/tools/gvisor-package/inventory.py`:
  `c3280c7423f58cb8aa3b0002869092e7abf5b12359ed32b634152f6f9508ae76`
- `pinenote/tools/gvisor-package/test_inventory.py`:
  `9c50415d92c8820dd7a1b49a754467380487ecbd7bbb441c561ed74141a581ef`
- `pinenote/tools/gvisor-package/pinned-source-inventory.json`:
  `3198cf4d033ddfc47919255cf47336e3f3125386b0fc9b51f3a7332ed7633f47`
- `pinenote/tools/gvisor-package/check.sh`:
  `1dd35854a4cb076de92daee93c6504f209c0fb87e4674dadde4c342e757e7981`
- `doc/gvisor-packaging.md`:
  `e3f71000c0b4120e30eeeea0e947a691a33b4c2fa917897f6266003abb1fc211`
- unchanged `pinenote/packages/gvisor-source.scm`:
  `2a4d7e5bc09c105123c7d33335d5f8dd73a9f8999fabd0067ab186561955d555`
- rebuilt preparation output:
  `/gnu/store/vxy688rjq9j1im4pxxmynpw2bvld0fvm-gvisor-source-inventory-20260831.0`

**Verdict: accepted. The two blocking inventory change-gate findings above
are closed for this snapshot.** This accepts the preparation package as an
exact-source, direct-declaration inventory gate. It still does not accept a
resolved transitive Bazel fetch graph, a networkless gVisor build, or a runtime
package.

Evidence:

- The exact source still has Guix recursive hash
  `12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy`.
- The installed tool reproduced the corrected committed manifest byte for
  byte. The installed manifest has SHA-256
  `3198cf4d033ddfc47919255cf47336e3f3125386b0fc9b51f3a7332ed7633f47`.
- All 13 focused unit tests passed, and the integrated `check.sh` gate passed
  against the clean exact checkout.
- `.bazelversion` is now part of the pinned metadata, is parsed as `8.3.1`,
  and supplies the manifest value instead of merely being asserted by the
  scanner. Replacing it with `9.0.0` was rejected as a `.bazelversion` hash
  change; removing it is separately covered by both unit and integrated
  mutation tests.
- Repeating the original custom-repository counterexample was rejected at
  `ctx.download`, before a repinned manifest could hide it. A transitive local
  `load()` whose loaded file used `ctx.download_and_extract` was rejected while
  naming that loaded file. A benign newly loaded file was also discovered and
  rejected as a traversed-extension set change.
- The three current traversed local extension hashes independently match the
  manifest. The unit tests separately exercise recursive local-load discovery,
  per-file hash recording, hash/set drift rejection, direct
  `repository_rule`/`download` rejection, and rejection in a transitively
  loaded file. These tests assert scanner behavior on temporary source text;
  they do not pass merely because the golden JSON was regenerated.

The corrected documentation consistently labels this as direct inventory, not
the complete repository closure, and permits honestly labeled, hash-pinned
prebuilt Bazel and Go bootstraps for the first source-built gVisor package. No
general Bazel framework or all-toolchain-from-source prerequisite is imposed.
The next packaging stage should therefore capture and vendor the actual
release-target repository graph rather than expanding this inventory scanner's
specification.

This recheck edited only this review record. It performed host-side Python and
installed-tool checks against isolated temporary mutations. It did not realize
or rebuild a package, invoke Bazel or Go, inspect or mutate a Bazel cache, poll
the separate diagnostic builder, compile gVisor, or perform any image, QEMU,
runsc, hardware, SSH, UART, mount, or device operation.
