# gVisor source packaging

Status: **the exact source, reviewed fixed-input `//:release` closure, explicit
Bazel bootstrap, and dedicated runtime package are implemented.** The native
and x86_64→AArch64 runtime derivations lower successfully. The Bazel bootstrap
builds and exercises its embedded JDK and `process-wrapper` in a true Guix
build chroot. **Both six-file runtimes are realized and fully inspected without
execution.** Native retry 17 completed all 6,898 Bazel actions; the subsequent
x86_64→AArch64 build completed all 6,877. Each exact runtime layout, static ELF
machine identity, release-marker policy, and Go 1.26.3 identity matches the
checksum-pinned official release's corresponding properties. Neither set is
byte-identical to the official binaries. All bounded failures and focused
corrections are recorded below.

This is reusable gVisor packaging. It contains no PineNote mount, network,
kernel, or sandbox policy. The frozen official ARM64 release package in
`pinenote/packages/gvisor.scm` remains unchanged and must not be renamed to
imply a source build.

## Pinned source

| identity | value |
|---|---|
| upstream release | `release-20260831.0` |
| commit | `fd2f6b2674208086e324c2f739155eb7e1b48ff2` |
| Guix recursive SHA-256 | `12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy` |
| recursive SHA-256, hex | `3ede5d7a19cf960a09fa31a4f797af3910bcd832022f1f80efe8935902871e8a` |
| source date epoch | `1788467832` |
| upstream source license | Apache License 2.0 |

The release tag is unsigned. Trust is the exact commit plus content hashes,
not a release signature. `gvisor-source-origin` is always the clean upstream
tree. The diagnostic patch with SHA-256
`9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`
is not present in that origin or the default preparation path; it is used only
by the separately named `gvisor/source-diagnostic` variant.

`gvisor-source-inventory` validates the source metadata, compares the generated
direct inventory byte-for-byte with `pinned-source-inventory.json`, and runs 13
focused tests. It invokes neither Bazel nor Go and has no downloader.

```sh
pinenote/tools/gvisor-package/check.sh /tmp/opencode/gvisor-fd2f6b2674

guix build -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor-source-inventory)' \
  --derivations --no-grafts
```

## Direct declarations versus the release closure

The clean source directly declares:

| surface | direct inventory |
|---|---:|
| `bazel_dep` modules | 18 |
| `use_extension` declarations | 6 |
| root/local-extension HTTP downloads | 9 |
| explicitly content-addressed HTTP downloads | 8 |
| selected `go.mod` modules | 122 (43 direct, 79 indirect) |
| `go.sum` lines | 445 (161 content, 284 `go.mod`) |

This remains useful as a change gate, but it is not a resolved dependency
closure. The source has no `MODULE.bazel.lock`; BCR modules do not carry their
source URLs in the root module; external extensions create repositories; and a
Go `h1:` identifies canonical module contents rather than the proxy ZIP bytes
required by Guix `url-fetch`.

The fixed closure therefore comes from configured
`cquery 'deps(//:release)'` and `bazel vendor //:release`, separately for the
native and AArch64 configurations. Whole-module `bazel mod graph` is
deliberately excluded: it instantiated repositories outside the requested
target and would make the package larger than the six-file release graph.

## Discovery identities

Discovery is the only network-enabled stage and is confined to a fresh
`/tmp/opencode/gvisor-guix-vendor-*` directory. `vendor-discover.sh` requires a
commit-scoped authorization token, exactly two jobs and CPUs, 8 GiB declared
RAM, bounded JVM heap, and timeouts. It runs only vendoring, configured
analysis, and metadata generation; both logs report zero build actions.

| item | identity |
|---|---|
| Bazel | 8.3.1 Linux x86_64, SHA-256 `17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c` |
| generated lock | SHA-256 `8402c7beb4baf2c666f4b78e400ea3f15514b56117598c2cb5411d6a35208d34` |
| BCR commit | `a5e087e21fcac28ff105ffc5eaeca966e61057af` |
| BCR Git recursive hash | `057akiiiqiigylnrsi7bqyrdkfhq1h1xpsblrpyni6p614wz8paz` |
| BCR discovery archive | SHA-256 `c92bc8507886ad000356f719cf1b00cd89fe1e571b692a1ec35b895a2387daff` |
| prepared `MODULE.bazel` | SHA-256 `11413ed198eff2b36dcd5692e6d84f9d343a24b2c56ecaad9026864cc51d08f8` |
| packaging-only rules_go patch | SHA-256 `e04ae0d3acf5502887130edd7651393fb15aa20ed3fdc19cdf9530f12555c460` |
| Go release-index discovery snapshot | SHA-256 `1ed915f72633d0a72eaa2f462740153db4fe347cb56f7d1e25ec44868568f13e` |
| fixed vendor manifest after review fixes | SHA-256 `00cf6fc80955b36d6bce3344dbbdeb546eb718dff923bfe47f5449ce321d4be7` |
| canonical-ID `(CAS hash, marker)` map | SHA-256 `29acb447986ca0c9e5b9ec29abf7305c082b5ce52a06ba50c24ec6c788129715` |
| repository/origin/license relationship projection | SHA-256 `f1f8cc762586e9b2ad662c508815223d7f8609b076949d4d1c953c331a4bc3dc` |

`rules_go` normally queries mutable `go.dev` and `golang.google.cn` release
indexes even with all source archives cached. The packaging patch replaces
that query with five explicit Linux x86_64 tuples: Go 1.23.0, 1.24.0, 1.24.6,
1.25.0, and 1.26.3. Their URLs and SHA-256 values are in the target manifest;
only Go 1.26.3 is selected and fetched. This transform is applied only to a
prepared build tree. It does not alter `gvisor-source-origin`.

Upstream also enables a prebuilt protoc in `.bazelrc`. The source-build closure
overrides
`@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false`.
Consequently protoc is later built from the fixed protobuf, Abseil, and zlib
sources. Bazel 8.3.1 (with embedded Java 24) and Go 1.26.3 are the only
explicitly prebuilt bootstrap inputs.

## Separate target manifests

| target configuration | configured labels | closure SHA-256 | external repository spellings |
|---|---:|---|---:|
| native x86_64 | 18,812 | `9412d5a8944f727ca402d864f2504de30809df71e9d0fabd307b9b6c837e573f` | 106 |
| x86_64 → AArch64 | 18,791 | `60473defe06cb496ad55ebac640e21a1799444441c5111c2c8df4655dd0f4777` | 106 |

The lock, selected source inputs, 91 Go module inputs, and 261 raw vendor
members are identical between configurations. The configured labels remain
separate because their target graphs differ. The common vendor-member list has
SHA-256 `8d9c258d3ae97d468d2d83dc0d781824a4171eecad50e849a1bcce9fd6d0df2c`.

There are 129 canonical vendored repositories. The raw 261-member directory
consists of those repository directories, their 129 markers, `VENDOR.bazel`,
the `_registries` snapshot, and Bazel's path-sensitive `bazel-external`
symlink. The symlink is never packaged; each analysis recreates it for its own
fresh output base. The 106 names appearing in configured labels are apparent
or canonical label spellings, not a substitute for Bazel's 129-member vendor
closure: generated repositories and module/toolchain repositories can be
required without contributing an external configured label.

Every repository row in `release-vendor-manifest.json` is classified as
“vendored by `bazel vendor //:release`” and maps to one of:

| provenance class | repositories |
|---|---:|
| Go proxy module | 91 |
| BCR source module | 21 |
| generated repository with an identified generator | 13 |
| root archive override | 2 |
| Coral local module-extension archive | 1 |
| prebuilt Go SDK bootstrap | 1 |

## Final Guix representation

`pinenote/packages/gvisor-dependencies.scm` is generated, not hand-edited. It
contains 117 individually named `url-fetch` origins plus one BCR `git-fetch`
origin. The URL origins are 25 target source/tool archives, 91 Go module ZIPs,
and the Bazel executable. Every origin has its own URL, byte SHA-256, Guix
base32 hash, and stable input name.

`gvisor-release-vendor-inputs` assembles those origins without network access
or a downloader. Its output contains:

- 359 Bazel content-addressed cache members: 319 exact lock-addressed registry
  files, 15 BCR patches, and 25 archives;
- all 24 canonical-ID marker files required by Bazel's repository cache;
- a local Go proxy with 91 `.zip`, 91 `.mod`, and 91 `.info` files;
- the exact Bazel bootstrap, lock, packaging patch, full manifest, and both
  configured-label manifests; and
- a 319-file target registry view reconstructed from the fixed BCR commit.

The generated material contains no preparation-directory absolute path.
`vendor_inputs.py` verifies every copied or reconstructed member and rejects
missing or undeclared input IDs. A warm cache is neither read nor installed.

The marker relationship is executable metadata, not a count check. For 24
HTTP archives, each marker ID must be SHA-256 of the space-joined URL list that
Bazel uses as the default canonical ID. The sorted tab-separated `(CAS
SHA-256, canonical ID)` mapping has the independently reviewed digest above.
The rules_go Go 1.26.3 SDK is deliberately markerless: its pinned repository
rule calls `download_and_extract` with a checksum and no explicit canonical ID.
Both a valid-looking marker substitution and a swap between two otherwise
valid markers are regression tests.

Repository provenance is now checked bidirectionally. Every direct repository
must name an existing fixed archive or Go-module input and reproduce its kind
and URLs; every archive backlink and Go repository pointer must agree; every
generated repository must use the generator implied by its canonical-name
prefix and inherit from that same existing direct repository. Direct license
records require safe relative paths, nonempty recognized SPDX evidence, sizes,
and SHA-256 values. The sole honest unknown is pinned as the empty
`rules_kotlin+` 1.9.6 missing record, so it cannot be replaced with plausible
but invented evidence. A compact projection seals repository IDs to source
archive/ZIP hashes, Go identities and `h1:` provenance, URLs, backlinks,
generated aliases, and exact license artifacts.

Build the preparation package under the pinned channel:

```sh
guix time-machine -C channels.scm -- build -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor-release-vendor-inputs)' \
  --no-grafts --max-jobs=1 --cores=1
```

The realization after the vendor-review fixes is:

- derivation:
  `/gnu/store/bj3k09rsyd30z1b0fvvq5j7km7g4cxl6-gvisor-release-vendor-inputs-20260831.0.drv`
- output:
  `/gnu/store/6x5h6fpqysmyam51c3zy978nk6fmrq68-gvisor-release-vendor-inputs-20260831.0`
- output recursive hash:
  `1sfan3bnkkx7cd6ih9ldkdgr6cprnnzbnfmxs48wck7ik8180ss1`

Those paths will change when a gate or installed manifest changes; the command
and fixed member hashes are the reproducible interface.

## Explicit Bazel bootstrap

`gvisor-bazel-bootstrap` is a dedicated binary-bootstrap package for the
hash-pinned upstream Bazel 8.3.1 Linux x86_64 executable. It is not an FHS
installation and does not consult a user Bazel cache. The input still has the
reviewed SHA-256
`17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c`.

The upstream executable is a self-extracting ELF/ZIP. Its launcher expects
`/lib64/ld-linux-x86-64.so.2`, and 29 embedded ELF executables or libraries
have the same FHS loader/runtime assumption. `bazel_bootstrap.py` performs one
deterministic packaging transform:

1. verify the raw executable hash and exact 29-member ELF inventory;
2. replace the launcher's fixed-width `PT_INTERP` bytes in place with
   `/proc/self/fd/9`, without moving Bazel's embedded-file ELF notes;
3. assign each embedded executable a declared Guix loader and retain all 29
   transformed ELF payloads before rebuilding the ZIP, preserving transformed
   member order and checking every CRC;
4. place each of the 11 executable payloads behind an embedded Bash wrapper
   that supplies only the declared glibc, GCC, and zlib library paths before
   the ELF starts (Bazel clears its own environment before launching action
   helpers, so an action environment alone is too late);
5. derive a new install-base key from the raw identity, transform ID, and
   declared patcher/loader/wrapper-shell/library paths; and
6. install a top-level wrapper that opens the Guix loader on descriptor 9 and
   sets the same fixed library path.

The embedded JDK 24 is retained and is therefore also a prebuilt bootstrap.
Bazel's code is Apache-2.0; that JDK carries GPL-2.0 with the Classpath
Exception and its own third-party legal shelf, so the heterogeneous bootstrap
package does not pretend the whole executable has one license.

The package check runs `bazel version` to extract and start the embedded JDK,
then unsets caller `LD_LIBRARY_PATH` and directly runs the extracted
`process-wrapper` in the same true Guix build chroot. It does not resolve a
Bazel registry, analyze a gVisor target, or compile anything. Guix's generic
RUNPATH validator is disabled only for this package because it cannot model
the top-level wrapper's descriptor-9 `PT_INTERP` pair or the embedded
helper/payload pairs; the package check exercises both paths directly.

Current realization:

| item | value |
|---|---|
| derivation | `/gnu/store/y8vxhya9324y7scr5bx6i9kgwql95drb-gvisor-bazel-bootstrap-8.3.1.drv` |
| output | `/gnu/store/bwxhk066irv1lmyvr7qnmbrjg3rvp07c-gvisor-bazel-bootstrap-8.3.1` |
| recursive output hash | `0a811l8l3xbzv9di7v9j97bc8ppnc7749cx97k7yi1jgrnhw943f` |
| repacked executable SHA-256 | `fed90ac872ecfb26041a58fe25ed5be93fd34961ec5c1173e23a80dc6100b7d2` |
| installed manifest SHA-256 | `bf4bbf60d339350f994c043e5aedd670cb22b77a184063d766fc3ab2fffb87e4` |
| direct output size | 61 MiB |
| closure size | about 684 MiB |

Build only this bootstrap gate with:

```sh
guix time-machine -C channels.scm -- build --no-grafts \
  --max-jobs=1 --cores=2 -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor-bazel-bootstrap)'
```

## Offline and negative proof

The vendor review correctly found that the earlier retained logs did not prove
their claimed network namespace. They remain valid cache/downloader evidence,
but are superseded for the no-NIC claim by
`/tmp/opencode/gvisor-guix-vendor-offline-netns-accepted-v4-ugR1x4`. Its exact
`guix shell --container --emulate-fhs --pure` invocation is retained as
`replay-command.sh` (SHA-256
`02c1c2543cc75ee934ecd1b51e9954a37da78477c65fe08df41561c1d94faf8b`);
it does not pass `--network`. `invocation.txt` pins the source, final
preparation package, Guix commit, tools, mounts, and two-CPU limits (SHA-256
`c8010772181d1ab36e807e1eca2a9479aa3765dca9d297e0850871bc58e0c928`).

Before entering the containers, the outer process recorded namespace
`net:[4026531833]`, 11 non-loopback interfaces, and 51 non-loopback routes.
Each replay compared its live state with that snapshot and recorded only `lo`,
no external route, and a different namespace, `net:[4026536204]`. The two
containers ran sequentially and Linux reused that inner namespace inode number;
each comparison was made before its own analysis began. The outer snapshot
SHA-256 is
`ff308c254e7c86ff7da51d6ee17880a1cd874c9d6a5f93336ec671d58561b6df`.

`network_namespace.py` then ran in the process that immediately `exec`'d each
Bazel command. Four events per architecture record the same isolated identity,
no external interface/route, no inherited HTTP/FTP/all-proxy, `NO_PROXY`,
`GONOPROXY`, or `GOINSECURE` value, and the fixed local Go environment
(`GOPROXY=file://…`, `GOSUMDB=off`, `GONOSUMDB=*`, empty `GOPRIVATE`). Event
SHA-256 values are
`9aaebd532594c0ea0488500666e886e25514c79068806ebfc58d78c992e2d89c`
(native) and
`9451f978f797c975d8f0f74a2ad750a15a460eb49cede47aa91e64abb9c44b59`
(AArch64). No external-connectivity probe was needed or attempted: the kernel
namespace inventory is the boundary.

For each architecture the measured replay:

1. copied only the realized fixed-input package into a fresh mutable cache;
2. regenerated `bazel vendor //:release` with
   `--repository_disable_download` and zero build actions;
3. copied only the fixed target registry into the vendor tree;
4. ran configured `cquery` from a fresh output base and empty repository cache,
   then compared it byte-for-byte with the committed architecture manifest;
5. removed `rules_go++go_sdk+main___download_0` and its marker, then required a
   fresh analysis to fail with `download is disabled`; and
6. independently removed the `rules_go` archive and canonical-ID marker from a
   fresh pre-vendor cache, then required vendoring to fail with `download is
   disabled`.

Both target runs passed against the final preparation output. The complete
summary SHA-256 is
`cc7dd7c908fbd90ff4e5926bbca0ae3139f9db8de58a846c540b9c6fbb8ea0da`;
the key-file `SHA256SUMS` file hashes to
`e99dfb22f49deb9dbd4f53578301a5c6ab40949583161ec17630df547a4e43c1`.
The native and AArch64 namespace-evidence files hash to
`7cca4474dbf43e719c47f425392083bd8bab8812b6d4ba6301ce85f24b28871a`
and `47e572c1331ccb86cfeaa014a82202df98558c4644b89e82c57f934d629ee5f6`.
No runtime target was compiled or executed.

The converse was exercised too, not inferred from a flag: invoking the final
`offline-check.sh` directly in the captured outer namespace exited 1 before
source/cache preparation, left its work directory empty, and reported
`network namespace did not change from the outer process`. That stderr hashes
to `b8ba5aab0be1b2a2154230ee0094c39be5d6a51d6ee14d74dbcc9d159d92df42`.

The canonical-ID negative matters: the first replay intentionally omitted
those markers. Bazel rejected the byte-identical `rules_go` archive with
downloads disabled. Hash-keyed bytes alone were therefore not treated as a
successful result; all 24 target markers are now explicit manifest data.

## Exclusions and provenance omissions

The configured release graph proves the following declarations unreachable:

- unhashed `http_file:google_root_pem` (`https://pki.goog/roots.pem`);
- LLVM and Kythe root downloads; and
- protobuf's prebuilt Linux x86_64 protoc repository, explicitly disabled in
  favor of source compilation.

The direct inventory still fails `--require-explicit-hashes` on
`google_root_pem`; no gate was weakened and no current certificate was silently
substituted.

License evidence is per canonical repository, never inherited from gVisor's
Apache license without an explicit link. At this closure, 115 repositories
have detected, hashed license evidence; 13 generated repositories identify the
source repository whose license they inherit and state that they have no
independent source; `rules_kotlin` 1.9.6's release archive contains no license
file, which remains an explicit upstream omission. Four tool-only Go module
ZIPs have authenticated `h1:` values but no matching line in gVisor's or
rules_go's selected source sums:

- `golang.org/x/exp/typeparams@v0.0.0-20221208152030-732eee02a75a`
- `golang.org/x/telemetry@v0.0.0-20250908211612-aef8a434d053`
- `gopkg.in/yaml.v2@v2.4.0`
- `honnef.co/go/tools@v0.5.1`

Their proxy ZIP byte hashes, module metadata, canonical repositories, source
URLs, and license evidence are still recorded. The omission is about where the
`h1:` was observed, not whether the Guix input is content addressed.

## Vendor-review regression matrix

The focused recheck is
`doc/reviews/2026-09-05-gvisor-vendor-inputs-adversarial.md` (SHA-256
`6229256c7b96c91febf3911a92c7aa37a54010f582f24d1ac4745dacdd5ea484`).
It accepted the corrected marker, provenance, license, and measured no-NIC
gates and authorized definition of the runtime package. This is authorization
to define and lower the package, not evidence that a runtime compiled. The
fixes did not alter any origin, configured label file, lock, source-protoc
setting, or native/AArch64 graph.

Its exact passing counterexamples are now explicit regressions among the 22
vendor tests:

| former hole / adversarial permutation | required result now |
|---|---|
| replace one marker with another valid 64-hex value | reject canonical-ID relationship |
| swap two valid marker IDs while preserving count and syntax | reject canonical-ID relationship |
| set a repository to a nonexistent input, wrong kind, and unrelated HTTPS URL | reject nonexistent input |
| mutate kind or URL independently | reject mismatch with fixed input |
| swap archive backlinks or Go repository pointers | reject bidirectional relationship |
| redirect a generated repository and its license inheritance | reject canonical alias/generator relationship |
| use `../` in license evidence | reject unsafe path |
| replace the `rules_kotlin+` omission with plausible evidence | reject fabricated license claim |
| swap valid license artifacts between direct repositories | reject sealed repository/origin/license map |
| run replay without changing from the captured outer namespace | exit 1 before preparation |

Focused-recheck source identities:

| file | SHA-256 |
|---|---|
| `pinenote/tools/gvisor-package/vendor_manifest.py` | `373bf691711da9783fe1ecf46cc56609591fed63830e30040fffe30e2107f17a` |
| `pinenote/tools/gvisor-package/test_vendor.py` | `5ed78adf66dce2a3c9b9518deb93b5849eaf55c16310c47c7d1dec03cd42ec87` |
| `pinenote/tools/gvisor-package/network_namespace.py` | `cecaf100c5dcd746389bbcb11d2faf3702d71c26d17ba4e25a997933825ba158` |
| `pinenote/tools/gvisor-package/offline-check.sh` | `2c73610649831e6ec7f8960c25ad443bf7755ab0744f9597835c12540ba9c168` |
| `pinenote/tools/gvisor-package/README.md` | `dfb780dcbcf7c2c73411ae44026fe132b27797fadb9065680e82c767210971e2` |
| `pinenote/tools/gvisor-package/release-vendor-manifest.json` | `00cf6fc80955b36d6bce3344dbbdeb546eb718dff923bfe47f5449ce321d4be7` |

The generated origin table remains
`e7f84a9a40d8690c992ccb8db72a438f81a0f242b1022f43fc0bd076f1c66734`.

The accepted fixed-input baseline remains 13 direct-inventory tests plus 22
vendor tests, the unchanged generated 117-origin Scheme table, final
preparation-package build, and both measured zero-action replays above. The
runtime setup adds 5 Bazel-bootstrap and 21
toolchain/cache/source-policy tests plus one true-Guix-chroot helper probe,
without changing the accepted preparation package.

## Runtime package boundary

`gvisor/source` exports the package named `gvisor-source-built`. It uses the
ordinary `gnu-build-system`; this is deliberately not a general Bazel build
system. It contains no PineNote service, mount, network, sandbox, or shipping
policy, and it does not replace or rename `gvisor-bin`.

`gvisor/source-diagnostic` is the separately named
`gvisor-source-built-diagnostic` variant. It inherits that same package and
changes only its source origin by applying the approved Systrap failure-context
patch. It was lowered but not built; the already completed separate diagnostic
campaign must not be duplicated by this packaging work.

The source-only proof at
`/tmp/opencode/gvisor-diagnostic-source-proof-20260905` realized the inherited
origin through both ambient Guix and the pinned channel. Both selected
`/gnu/store/zi0wl56vicmx1bb5w5nynwzyaxbd4ghs-gvisor-20260831.0-checkout`
(recursive hash
`1w1ppv4i2v4pnxrcjm2badrr0iynxgcbhx2i7gmyvjihl1kllxhm`). Its 4,961-path
inventory matches the pristine origin exactly and only the three reviewed Go
files differ; their resulting SHA-256 values are
`6f4fc255dd7371cc8f6ab8ad8d5a2e97b89deb6c579530c501ee127499326114`,
`06a076a5e87446cc5fb347c07373e00469b942b624531a3bc5788cf2d8a7082a`,
and `f15d6cd9d8f076e8d5e3439984e93669940361157f69fceb1bc9c0b5230bbb2b`.
No gVisor target was compiled or executed for this proof.

The default source remains the clean `gvisor-source-origin`. Ten narrowly
scoped build-only adaptations are applied to mutable prepared copies:

| file | scope |
|---|---|
| `gvisor-release-version-offline.patch` | records exact release/commit metadata without `.git`, disables Bazel's FHS-only workspace-status command, and points stamped consumers at the equivalent built-in `BUILD_EMBED_LABEL` |
| `gvisor-bpf-guix-toolchain.patch` | replaces PATH-selected Clang and Ubuntu `/usr/include` with declared BPF compiler/header variables and identifies the x86-64 ABI of the declared libc headers to Clang's architecture-neutral BPF frontend |
| `gvisor-prewarmer-guix-headers.patch` | supplies the freestanding prewarmer genrule with the matching declared target Linux UAPI headers |
| `gvisor-sysmsg-guix-headers.patch` | supplies the upstream split-architecture sysmsg genrules with separately selected native and AArch64 Linux UAPI headers |
| `gvisor-starlark-actions-guix-tools.patch` | gives the architecture-copy and final-release shell actions explicit Guix coreutils and the package-controlled strict action environment |
| `gvisor-coral-crosstool-guix.patch` | replaces Coral's `/bin/bash`, `/usr`, distro include, and implicit linker assumptions with explicit native/AArch64 Guix roots while retaining `-fuse-ld=gold` |
| `gvisor-protobuf-authenticity-guix-tools.patch` | keeps protobuf's source-built protoc authenticity check enabled while giving its private shell action declared Guix `grep` and `cat` paths |
| `gvisor-nogo-bazel8-file-path.patch` | passes the standard-library `go.mod` action path rather than Bazel 8's diagnostic `File` rendering |
| `gvisor-nogo-go126-stdlib-filter.patch` | recognizes the `go` directive below Go 1.26's leading `module` directive and excludes exactly the seven test-support packages rules_go intentionally omits from `go_sdk.srcs`, while preserving the general missing-source failure |
| `gvisor-vdso-guix-headers.patch` | supplies the direct VDSO compiler genrule with separately selected native/AArch64 Linux UAPI headers |

Current implementation identities:

| file | SHA-256 |
|---|---|
| `pinenote/packages/gvisor-source.scm` | `0b35b6bfa406bc6b063e3e1d1ff6daabe26acfdff66a673b1fe315ceffc4b740` |
| `pinenote/tools/gvisor-package/bazel_bootstrap.py` | `cc77fbdcbecfdb5c28c7d4e9febe2b3083fbae7d3d2335d14902102949f85bc7` |
| `pinenote/tools/gvisor-package/test_bazel_bootstrap.py` | `6e8d2aa32683f257dff63f1edb1b9d0131e03bf3fc89967b8ffa646088faa129` |
| `pinenote/tools/gvisor-package/runtime_setup.py` | `d358a998f0b351c341f32d496b8805165c7fadeba6cfdec20a1355c90b4302db` |
| `pinenote/tools/gvisor-package/runtime-check.sh` | `7dfb86d0a241cfd2a45adc76bc575b4de978143691e139fb1bc8977e3f494e4a` |
| `pinenote/tools/gvisor-package/test_runtime_setup.py` | `30c6a432df4c0b7ff6378540b814000f823c3ca7b920f47b5995bf614ab70452` |
| `pinenote/patches/gvisor-release-version-offline.patch` | `6ea3482fb32277b19d7c12a930c1b973cd301487df7a65a195d71d673ee32cba` |
| `pinenote/patches/gvisor-bpf-guix-toolchain.patch` | `4cd9df3594d43eaa391e40171727fcd43c6205b0bce64cb85c26912a8d96fdaa` |
| `pinenote/patches/gvisor-prewarmer-guix-headers.patch` | `c0a93dc2f670d2221096db790b0051c800ea7a1d50800836cae0d04afdff4f3b` |
| `pinenote/patches/gvisor-sysmsg-guix-headers.patch` | `ed95c1bd382fd4a98e9376eb211a5fc9071245fb7fedaa0b99dcc79b572f4b2a` |
| `pinenote/patches/gvisor-starlark-actions-guix-tools.patch` | `2d8d987e6c74e41e9ee35cfb9397cfaf8b25d1ee587a60af48e1bceffbc5af5f` |
| `pinenote/patches/gvisor-coral-crosstool-guix.patch` | `797f72e945b3198113bdde77dc0905dabd10be91ab2ac025acab8c7f0eb0c02b` |
| `pinenote/patches/gvisor-protobuf-authenticity-guix-tools.patch` | `7b970bf0a5b91f64c44b656c9f0b965d5adfddf9fb47b979530df1a0d9742162` |
| `pinenote/patches/gvisor-nogo-bazel8-file-path.patch` | `53b3d69bd63fcbba414397dd94af107b0d952aa160743a850c69068ba0833c4b` |
| `pinenote/patches/gvisor-nogo-go126-stdlib-filter.patch` | `46580f491a1de46f4e27b70e2f88ef604cec9d950103d6a81b5645cee6655730` |
| `pinenote/patches/gvisor-vdso-guix-headers.patch` | `43786b10c64960b61ad45205bda30cc59a1ac50d8c97c5728a9f10495b8b2b21` |
| `pinenote/patches/gvisor-diagnostic-systrap-error-context.patch` | `9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e` |

The diagnostic patch is byte-identical to the already reviewed evidence copy.
The runtime-only gate checks its exact SHA-256, applies it with zero fuzz to a
private copy of the pinned source, and requires the three accepted resulting
file hashes. It is not in `gvisor-source-origin`, `%gvisor-runtime-build-patches`,
or `gvisor/source`; only `gvisor/source-diagnostic` references it.

The Coral correction does not alter the reviewed `MODULE.bazel.lock`, source
extension, repository-cache bytes, or `gvisor-release-vendor-inputs` output.
The build extracts the exact accepted Coral archive into a mutable directory,
applies the two upstream gVisor Coral patches followed by the packaging patch,
audits the result for FHS paths, and deterministically renders its `BUILD.tpl`
and `cc_toolchain_config.bzl.tpl` as the generated crosstool repository. Bazel
receives that rendered directory through the canonical
`--override_repository=+crosstool_extension+crosstool=...`. The original Coral
extension and `.bzl` implementation therefore remain the accepted locked
bytes; the generated output alone carries declared Guix paths. This is why the
accepted preparation derivation remains exactly
`/gnu/store/bj3k09rsyd30z1b0fvvq5j7km7g4cxl6-gvisor-release-vendor-inputs-20260831.0.drv`.

### Build isolation and sequence

Each derivation creates a new empty home, temporary directory, Bazel
`output_user_root`, output base, vendor tree, action cache, and empty repository
cache under its build directory. It also creates three independent
repository-contents caches—one each for vendoring, closure analysis, and
compilation—in a private sibling of the workspace. Bazel 8 rejects this cache
inside the workspace; keeping the three passes separate also prevents the
vendor pass from becoming an undeclared cache input to either later gate. The
package never reads `HOME`, `XDG_CACHE_HOME`, or a caller-provided Bazel cache.
HTTP/FTP/all-proxy variables and Go bypass variables are removed. The local Go
proxy is the declared fixed input, `GOSUMDB=off`, and downloader fallback is
disabled for every Bazel operation. The actual Guix build chroot supplies the
network boundary; no nested `guix shell --container` is used.

The package then performs these gates in order:

1. construct explicit native and AArch64 GCC/binutils-gold tool prefixes from
   declared store inputs. Upstream's `arch_genrule` intentionally builds both
   sysmsg architectures even in the native release graph; this build-time cross
   input is therefore required without starting the separate AArch64 runtime
   build. Generated GCC launchers enter the real store driver so it retains
   access to `cc1`; each host-executable compiler reports its exact built-in
   include directories for Coral's declaration, while the matching Linux UAPI
   include is added to Coral's normal C/C++ compile features. Foreign outputs
   are inspected but never executed;
2. expose Clang BPF headers only as `-isystem` arguments for Linux headers and
   libbpf—never through global `CPATH`/`C_INCLUDE_PATH`; expose the prewarmer's
   matching native or AArch64 Linux UAPI headers through its own explicit
   genrule variable; the split sysmsg generator independently selects native
   or cross UAPI flags in each transitioned configuration; adapt gVisor's
   mandatory stdlib `nogo` pass to Bazel 8's `File.path` API and the exact
   test-support source exclusions in rules_go's pinned Go 1.26 SDK;
3. generate the vendor tree from a copy of the accepted repository cache with
   `--repository_disable_download` and lockfile error mode, then patch only its
   private protobuf copy so the authenticity action names declared utilities;
4. run configured `cquery 'deps(//:release)'` from an empty repository cache
   and compare every label, duplicate, and configuration partition with the
   reviewed architecture closure. Bazel's opaque short configuration hashes
   are allowed to be renamed by the declared Guix tool paths;
5. compile `//:release` from another fresh output base and empty repository
   cache, using a new action cache; and
6. reject a missing, extra, wrong-architecture, dynamically linked, or
   incorrectly stamped release member, and require Go 1.26.3 build metadata in
   each of the five Go executables, before installation.

The strict action environment declares its `PATH`, shell, compiler, linker,
binutils, core utilities, archive tools, Python, BPF Clang, and headers. Protoc
remains source-built with
`@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false`; its
authenticity action receives explicit `GVISOR_GUIX_GREP` and
`GVISOR_GUIX_CAT` paths, and the package audit rejects the
`allow_nonstandard_protoc` bypass.
Bazel's built-in workspace-status action hardcodes `/bin/sh` independently of
that explicit action shell. The package therefore passes
`--workspace_status_command=` and the exact
`--embed_label=release-20260831.0`; the build-only version patch points the
same eight upstream consumers at the stable built-in `BUILD_EMBED_LABEL`.

The runtime subtree is exactly upstream's six executable files:

```text
bin/containerd-shim-runsc-v1
bin/gvisor-bin/checkpointgofer
bin/gvisor-bin/gvisor-sentry-prewarmer
bin/gvisor-bin/gvisor_sentry
bin/gvisor-bin/runsc-metric-server
bin/runsc
```

Guix additionally installs the upstream Apache-2.0 `LICENSE` at
`share/doc/gvisor-source-built-20260831.0/LICENSE`; there are no other output
files.

Four upstream executables carry the exact release stamp: `runsc`,
`checkpointgofer`, `gvisor_sentry`, and `runsc-metric-server`. The containerd
shim and freestanding C prewarmer intentionally do not carry `STABLE_VERSION`.
All six are inspected, not executed, for ELF machine, static linkage, and
`INTERP` absence. Foreign AArch64 outputs must never be executed.

The successful native output is
`/gnu/store/zgfaq0i8jdsm08xlahmyx5yg23ndnc30-gvisor-source-built-20260831.0`
(recursive Guix hash
`093dvw89z68634683b3hvc2367jx0vvn6785lwccn9j8ab2nqcn0`). It has no store
references. The official comparison at
`/tmp/opencode/gvisor-official-x86_64-comparison-retry1-20260905` verifies
upstream's published SHA-256
`b9ccc6e14ca4eb2c2e65ff66e011f3b7e79d3275fb12eab747b19f95caf8e891`
for `gvisor-x86_64.tar.zstd`, then compares the six members without executing
either runtime. Both sets have the same exact layout, static ELF64 x86-64
machine/linkage, four-file release-marker policy, five-file Go 1.26.3 marker
policy, and normalized parser-visible Go build identity. All six SHA-256 values
differ; three Go binaries have equal sizes, while the shim, checkpointgofer,
and C prewarmer differ by -16, +64, and +16 bytes respectively. This is a
property-level source-build comparison, not a claim of byte reproducibility or
runtime validation.

### Native-first commands and current evidence

The cheap package gates are:

```sh
# Accepted source + vendor boundary: 13 + 22 tests.
pinenote/tools/gvisor-package/check.sh /tmp/opencode/gvisor-fd2f6b2674

# Runtime-only bootstrap/toolchain/cache/patch gate: 5 + 21 tests, the exact
# diagnostic patch identity/effect, and a true-Guix-chroot Bazel
# startup/GCC-wrapper probe; no repository resolution or gVisor compilation.
pinenote/tools/gvisor-package/runtime-check.sh \
  /tmp/opencode/gvisor-fd2f6b2674 \
  /gnu/store/6x5h6fpqysmyam51c3zy978nk6fmrq68-gvisor-release-vendor-inputs-20260831.0

# Lower only; these commands do not compile gVisor.
guix build --no-grafts --derivations -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source)'
guix build --no-grafts --derivations --target=aarch64-linux-gnu -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source)'

# Diagnostic variants lower separately; do not realize them while the earlier
# diagnostic campaign already supplies the needed build evidence.
guix build --no-grafts --derivations -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source-diagnostic)'
guix build --no-grafts --derivations --target=aarch64-linux-gnu -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source-diagnostic)'
```

The runtime tests intentionally remain in `runtime-check.sh` rather than being
added to `check.sh`: the latter is part of the accepted
`gvisor-package-tools` NAR used by `gvisor-release-vendor-inputs`. Keeping its
bytes unchanged is what preserves the accepted preparation derivation; the
runtime-only files are excluded from that NAR.

Current lowering results are:

- native x86_64:
  `/gnu/store/ll18lsyll28xk0ms7zb3hkz46vpwp333-gvisor-source-built-20260831.0.drv`;
- x86_64→AArch64:
  `/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv`;
- diagnostic native:
  `/gnu/store/y26bfq6lpwcqam1ma5k92qfim9lk0d0m-gvisor-source-built-diagnostic-20260831.0.drv`;
- diagnostic x86_64→AArch64:
  `/gnu/store/pb5v7rqa5iqwc98qzjpbnk474qgqbvmm-gvisor-source-built-diagnostic-20260831.0.drv`.

The ambient channel and `guix time-machine -C channels.scm` resolve those same
four derivations; none of the lowering commands realizes a runtime output. The
two default derivations are unchanged by adding the inherited diagnostic
variant.

### Native precompile attempts and narrow retries

The original native derivation
`/gnu/store/64mnhvaq54bwjpnkbijaczm3ldp7g7nk-gvisor-source-built-20260831.0.drv`
failed on its first realization attempt with status 1 after 2.55 seconds and a
315200 KiB maximum RSS. Source preparation and patching completed, but the
build phase raised `Unbound variable: append-map` at its first setup-command
construction. Bazel had not started and no gVisor compile action ran. The full
evidence remains at
`/tmp/opencode/gvisor-native-first-command-packet-20260905-xobhzkdx/logs/gvisor-source-built-20260831.0-native.full.log`.

The narrow correction imports `(srfi srfi-1)` for `append-map` and
`(srfi srfi-13)` for the already-used `string-join` and `string-trim-right`
inside the actual runtime build phase. A static mutation test removes the
runtime phase's SRFI-1 import and requires rejection. The separate
`gvisor-build-phase-helper-check` then instantiates those helpers and
`get-string-all` inside a real pinned Guix build chroot. It passed in 0.0
seconds:

- derivation:
  `/gnu/store/avfgd12qwanl1l1bx9n9w08hi6lndxfb-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/bv8dzcziankmk1gvfjm812wdldydgirv-gvisor-build-phase-helper-check-20260831.0`.

Retry 1 used the new no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry1-20260905`. Its corrected derivation,
`/gnu/store/h1h75c257p9zxxck7xj184hc12c67f1z-gvisor-source-built-20260831.0.drv`,
passed source preparation and entered Bazel. Bazel then rejected the implicit
repository-contents cache because it was below the source workspace. The build
phase failed after 1.2 seconds; the outer command took 12.87 seconds and peaked
at 313792 KiB RSS. Bazel did not resolve a repository or begin a compile
action. Its full evidence remains at
`/tmp/opencode/gvisor-native-first-retry1-20260905/logs/gvisor-source-built-20260831.0-native-retry1.full.log`.

The narrow correction passes an explicit `--repo_contents_cache` outside the
workspace. Vendoring, configured analysis, and compilation each receive a
different fresh cache. The static package audit rejects moving any of them
below the workspace. The true-chroot helper now starts the packaged Bazel
8.3.1 with the explicit outside-workspace option and performs only
`info workspace`; this passed in 1.2 seconds without repository resolution or
actions:

- derivation:
  `/gnu/store/hlaz1c4504azh8l1sxklwa9fylci5bbg-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/i6w2xqf1cxh88rir9g6ym2hdid44635r-gvisor-build-phase-helper-check-20260831.0`.

Retry 2 used the third no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry2-20260905`. Its derivation,
`/gnu/store/vyara3d9qfz90qxjyw43pcbql6vrvbyv-gvisor-source-built-20260831.0.drv`,
passed cache placement, loaded the pinned graph, and entered `bazel vendor`
analysis. Bazel then reported an internal `ToolchainTypeInfo` null-pointer
failure. Its retained JVM log exposed the underlying lock error: overriding
the patched Coral source changed a transitive `.bzl` implementation while
`--lockfile_mode=error` correctly retained the accepted digest. The build
phase failed after 3.2 seconds; the outer command took 5.90 seconds and peaked
at 314456 KiB RSS. No compile action ran. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry2-20260905/logs/gvisor-source-built-20260831.0-native-retry2.full.log`.

The correction does not update the lock or weaken lock checking. It renders
the patched Coral templates itself and overrides only the canonical generated
repository, `+crosstool_extension+crosstool`. A fresh rootless no-NIC probe at
`/tmp/opencode/gvisor-lock-safe-crosstool-probe-20260905` then proved:

- `bazel vendor` completed from the accepted cache with the accepted lock and
  zero actions;
- fresh-cache `cquery` completed with zero actions and emitted exactly 18,812
  entries;
- all labels, duplicates, and configuration partitions match the accepted
  native closure. Only Bazel's opaque configuration-ID spellings changed as
  expected when FHS tool paths became Guix paths.

The accepted closure files, lock, vendor derivation, and bootstrap derivation
remain byte-identical. Retry 3 used the fourth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry3-20260905`. Its derivation,
`/gnu/store/244x17lnp3bafrkbsqmshdm1glzi5f19-gvisor-source-built-20260831.0.drv`,
passed offline vendoring and exact configured-partition comparison, then
entered the build invocation. Bazel's first built-in workspace-status action
failed before compilation because Bazel 8 invokes it through hardcoded
`/bin/sh`, independently of `--shell_executable` and the script's patched
shebang. The build phase failed after 27.0 seconds; the outer command took
30.73 seconds and peaked at 315044 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry3-20260905/logs/gvisor-source-built-20260831.0-native-retry3.full.log`.

The narrow correction disables only that command and uses Bazel's built-in
stable `BUILD_EMBED_LABEL` with exact value `release-20260831.0`. The prepared
source audit requires all eight former `STABLE_VERSION` consumers to use that
key and rejects re-enabling the workspace-status command. A fresh rootless
no-NIC one-action probe at
`/tmp/opencode/gvisor-workspace-status-embed-label-probe-20260905` built
`//tools/bazeldefs:version` and inspected its output as exactly
`20260831.0`; it neither executed nor compiled a gVisor runtime.

Retry 4 used the fifth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry4-20260905`. Its derivation,
`/gnu/store/3gcrr7ga05sfyyj589fwz3mbry08y868-gvisor-source-built-20260831.0.drv`,
passed vendoring, configured-closure comparison, and release stamping. Bazel
then began real actions: 75 internal actions were present and the first
protobuf C compiler action ran. It failed because GCC was invoked through a
renamed symlink and therefore could not locate its private `cc1` executable.
The build phase failed after 37.6 seconds; the outer command took 41.32 seconds
and peaked at 315020 KiB RSS. This is compilation-attempt evidence, not a
completed gVisor runtime. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry4-20260905/logs/gvisor-source-built-20260831.0-native-retry4.full.log`.

The correction replaces generated GCC symlinks with explicit launchers that
enter the declared store compiler, while binutils remains on the declared
action `PATH`. It also asks each host-executable compiler for the exact
built-in C/C++ include directories that Coral must declare; the AArch64 query
runs the cross compiler itself, never target output. The focused daemon-chroot
helper now compiles a trivial C object through the renamed launcher:

- derivation:
  `/gnu/store/w6d58b9h3jk28s55x1jwc95zgpz73vpk-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/0xv41s8bw9hxwqan7njy0zjg7h2zkmw4-gvisor-build-phase-helper-check-20260831.0`.

A fresh rootless no-NIC probe at
`/tmp/opencode/gvisor-gcc-wrapper-probe-retry1-20260905` then compiled the exact
failed protobuf `utf8_range` C target and separately reproduced all 18,812
accepted configured entries and partitions with zero cquery actions. It did
not build or execute a gVisor runtime.

Retry 5 used the sixth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry5-20260905`. Its derivation,
`/gnu/store/rqx1ah20ldkcqqavqcqqv1bqliy08hvq-gvisor-source-built-20260831.0.drv`,
passed vendoring and configured-closure comparison, then advanced to 1,099
actions. The freestanding `gvisor-sentry-prewarmer` genrule failed because it
invokes `$(CC)` directly, outside Coral's normal C/C++ actions, and therefore
did not receive the declared Linux UAPI-header path for `asm/unistd.h`. The
build phase failed after 37.3 seconds; the outer command took 50.31 seconds and
peaked at 315072 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry5-20260905/logs/gvisor-source-built-20260831.0-native-retry5.full.log`.

The narrow build-only patch adds one genrule variable,
`GVISOR_PREWARMER_INCLUDE_FLAGS`, populated as an explicit `-isystem` argument
from the native Linux-header input or the declared cross Linux-header input.
It does not use global `CPATH`, change prewarmer source, or weaken the build
boundaries. A fresh rootless no-NIC probe at
`/tmp/opencode/gvisor-prewarmer-headers-probe-20260905` then:

- vendored from the accepted fixed cache in fresh private roots;
- reproduced all 18,812 accepted configured entries and partitions with zero
  cquery actions;
- built the exact prewarmer target with the declared Linux-header path; and
- inspected, without executing, a 1,432-byte static x86-64 ELF with no
  interpreter (SHA-256
  `bfa87c12ac5d77a91779e37cdbdb17904bc49c8c2108630eaa5ed4457a4713f9`).

The true-chroot helper at that point, which compiled only its trivial compiler
probe, was:

- derivation:
  `/gnu/store/j15zlhmsx72rl2kz9gnfzpqnxy5dqfzj-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/zhx79yrdd3dj511qcaxfhrknl6wg6hsg-gvisor-build-phase-helper-check-20260831.0`.

Retry 6 used the seventh no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry6-20260905`. Its derivation,
`/gnu/store/hsxm6026zfnwjap0hwap6b5dlaz5a0p9-gvisor-source-built-20260831.0.drv`,
passed vendoring and configured-closure comparison, then executed six local
actions before the zlib tool build failed. The Guix glibc `limits.h` includes
`linux/limits.h`; compiler-discovered directories were declared to Bazel, but
Coral had not yet added the matching Linux UAPI path to normal C/C++ compile
actions. The build phase failed after 33.0 seconds; the outer command took
41.18 seconds and peaked at 315620 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry6-20260905/logs/gvisor-source-built-20260831.0-native-retry6.full.log`.

The narrow correction uses Coral's existing
system-include feature to add one explicit `-isystem` path to C and C++
actions. The template selects it by Coral CPU: native tool actions retain the
native Linux headers while AArch64 target actions select the separately
declared cross headers. Global include environment variables remain removed.
A fresh rootless no-NIC probe at
`/tmp/opencode/gvisor-coral-target-headers-probe-20260905` then:

- vendored from the accepted cache in fresh private roots;
- reproduced all 18,812 accepted configured entries and partitions with zero
  cquery actions; and
- built the exact failed zlib target as `libz.a` (SHA-256
  `5e1380384c3a7d5448acdfdf874e949f1b7b4f42b52f9f616b03ba01c700f1d7`).

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/wvadm8nhqy9hpwjcmq502xmqaj3qsnl9-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/8wvqyfmv2gr6398d7zy3h3b19sp4wmyi-gvisor-build-phase-helper-check-20260831.0`.

Retry 7 used the eighth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry7-20260905`. Its derivation,
`/gnu/store/1fzzfmic8cvgnspysk83zi1ml86a2ggf-gvisor-source-built-20260831.0.drv`,
passed vendoring and configured-closure comparison, reached 1,704 of 6,786
actions, and then selected the deliberately unsupported AArch64 compiler for
the sysmsg `syshandler` transition. This is an upstream split transition, not
an erroneous AArch64 runtime build: the accepted native closure contains both
sysmsg configuration partitions. The build phase failed after 34.0 seconds;
the outer command took 43.78 seconds and peaked at 316468 KiB RSS. Full
evidence remains at
`/tmp/opencode/gvisor-native-first-retry7-20260905/logs/gvisor-source-built-20260831.0-native-retry7.full.log`.

Changing `arch_genrule` to target-only would alter the frozen configured
closure, so the correction instead declares the existing AArch64 GCC,
binutils-gold, libc, and Linux-header build inputs for both package targets.
The direct sysmsg compiler macro gets architecture-selected `-isystem` flags.
Its custom copy action and the final release-layout action also use explicit
Guix `cp`/`mkdir`/`dirname` paths and opt into the package-controlled strict
action environment so Bazel's transformed `process-wrapper` receives its
declared libraries. No global include path or FHS shim is introduced.

A fresh rootless no-NIC probe at
`/tmp/opencode/gvisor-split-arch-sysmsg-probe-retry3-20260905` preserved the
complete 18,812-entry configured closure and built all 15 actions for
`sighandler_binary_arch`. The amd64 and AArch64 relocatable objects were
inspected without execution (SHA-256 respectively
`d2f55902c494279a5d6871b1e6e8829b0371bab5168f1e767b3ba0110a043326`
and `cb99e3443fa50e47c9f9ccd51ba5e38565359497b8bfd7395cb2e4b55b9e206c`).
The probe process itself returned nonzero only after Bazel success because its
first inspection command named a stale Guix `readelf` path; inspection was
then completed with the declared native binutils path and recorded in
`objects-readelf.txt` and `inspection-status.txt`.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/hcp7vxi2q4i8lnx4pdsfr3ajcln9jsfr-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/mh7x57rhmfi73hfxlalyiq4klg30s3al-gvisor-build-phase-helper-check-20260831.0`.

Retry 8 used the ninth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry8-20260905`. Its derivation,
`/gnu/store/la9s46al5hy77jfmdnd02w0crm8ynh04-gvisor-source-built-20260831.0.drv`,
again passed vendoring and configured-closure comparison. It reached 1,646 of
6,504 actions before the AArch64 `sysrestorer [for tool]` action failed because
`GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS` was absent from the exec-configuration
environment. The variable was already in `--action_env`; Bazel requires the
separate `--host_action_env` boundary for this configured edge. The build phase
failed after 36.0 seconds; the outer command took 64.41 seconds and peaked at
316224 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry8-20260905/logs/gvisor-source-built-20260831.0-native-retry8.full.log`.

The correction supplies the same explicit compiler, UAPI-header, coreutils,
and transformed-helper library environment to target and host actions. A
fresh rootless no-NIC proof at
`/tmp/opencode/gvisor-sysmsg-exec-env-probe-retry1-20260905` introduced only a
temporary probe rule whose source attribute uses `cfg = "exec"`. It preserved
the complete 18,812-entry release closure, built all 15 sysmsg actions with
`[for tool]` configuration, and inspected the resulting x86-64 and AArch64
relocatable objects without executing them. Their SHA-256 values are
`def95009fd77e60f90c858a4f96e7bfe9098565e59e1d99f6d5aec17176ebdbb`
and `3ae2b791a448a1c6977212fd697a9905c4315bda6b2804a297800e4ffd554593`.
The complete build log hashes to
`8ae122b79c92c67aa1e5f9ccbf34483f86e5b083b0ca34f02d0898635c2e3983`.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/3pnd0j6p9sjc6xsfdnx771p1xjxg3wqc-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/9d5i3mlkffkcmwbgjsxrqkv64d107blm-gvisor-build-phase-helper-check-20260831.0`.

Retry 9 used the tenth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry9-20260905`. Its derivation,
`/gnu/store/adl1hhwkf25ik9ww85axgm5g8vj0mpng-gvisor-source-built-20260831.0.drv`,
passed vendoring, closure comparison, and the exec-config sysmsg actions. It
then reached 918 of 6,669 actions before the exact XDP target
`//tools/xdp/cmd/bpf:tunnel_host_ebpf` failed. Clang's `bpf` target deliberately
has no host CPU predefine; glibc's x86-64 `bits/wordsize.h` therefore selected
the unavailable `gnu/stubs-32.h`. The build phase failed after 37.3 seconds;
the outer command took 41.31 seconds and peaked at 316144 KiB RSS. Full
evidence remains at
`/tmp/opencode/gvisor-native-first-retry9-20260905/logs/gvisor-source-built-20260831.0-native-retry9.full.log`.

The build-only correction keeps the already declared Linux/libbpf `-isystem`
paths and explicitly defines `__x86_64__` for this BPF frontend invocation.
That identifies the ABI of the declared native libc headers; it does not turn
the architecture-independent BPF object into an x86-64 runtime output. A fresh
rootless no-NIC probe at
`/tmp/opencode/gvisor-bpf-host-abi-probe-retry1-20260905` preserved all 18,812
configured release entries, built the exact failed target in two actions, and
inspected the result as an ELF64 `Linux BPF` relocatable object without
executing it. The object SHA-256 is
`8e524a417111ee5851876f035c391093fda7c47d253e233d8f85e9368b2607a9`;
the complete build log hashes to
`1c7ab8108f006d0807a53e871dd9b5292feeb02a1ee6168663acdbeed83cf8c3`.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/r7y06qv6xvv68irdkrcw6nfvijz7w2ld-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/xbzv5x11sa4625nmdfgrmmin47k669cf-gvisor-build-phase-helper-check-20260831.0`.

Retry 10 used the eleventh no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry10-20260905`. Its derivation,
`/gnu/store/r3ym94p0fx8sr93d4v7kdr8z82w40lb5-gvisor-source-built-20260831.0.drv`,
passed the BPF fix and reached 2,260 of 6,898 actions. The rules_go SDK
`builder [for tool]` action then failed before its declared host action
environment could be installed: Bazel's own transformed `process-wrapper`
needed `libstdc++.so.6` while Bazel was entering its deliberately cleared spawn
environment. The build phase failed after 106.6 seconds; the outer command took
159.68 seconds and peaked at 316844 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry10-20260905/logs/gvisor-source-built-20260831.0-native-retry10.full.log`.

Adding RPATH to that helper remains rejected: the earlier experiment crashed
it. Instead, transform version 2 keeps every embedded ELF's declared Guix
loader and adds an adjacent shell wrapper for each executable payload. The
wrapper supplies the declared libraries before entering the ELF, while the
action itself still receives an explicit target or host `LD_LIBRARY_PATH`.
The revised bootstrap passed `bazel version` and direct `process-wrapper`
execution in a true Guix build chroot with caller `LD_LIBRARY_PATH` unset.

A fresh rootless no-NIC proof at
`/tmp/opencode/gvisor-bazel-helper-wrapper-probe-retry1-20260905` then built the
exact rules_go SDK `builder` target in five actions. It preserved all 18,812
configured release entries, inspected the builder as x86-64, verified the real
`process-wrapper` uses the declared Guix loader and has no RPATH/RUNPATH, and
did not execute any runtime or foreign output. The builder SHA-256 is
`ebabd819a66ed534073fd1dadae4e8b033bab022adb4060f6a1736a84c871d5c`;
the build log hashes to
`246a9f577956189eb62b7529368fe1af9f7ebe6715420982ca7b13b21d9c7af9`.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/j9w67yhn3wsmk3s4djml4jwdj65ikdx6-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/lz1fff2phdwvx1siq3fm1v71yfdkqjbv-gvisor-build-phase-helper-check-20260831.0`.

Retry 11 used the twelfth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry11-20260905`. Its derivation,
`/gnu/store/bcgwvc9r2idrm6ardhraw44j7rra0n8l-gvisor-source-built-20260831.0.drv`,
passed the helper correction and reached 4,047 of 6,898 actions. The
source-built protobuf `protoc` linked successfully, but its separate
`ProtocAuthenticityCheck` action invoked bare `grep` and `cat` from an action
environment whose rule-level default had omitted package `PATH`. Both commands
were absent, so the enforced version check failed rather than being bypassed.
The build phase failed after 515.7 seconds; the outer command took 520.38
seconds and peaked at 316300 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry11-20260905/logs/gvisor-source-built-20260831.0-native-retry11.full.log`.

The correction patches only the private generated `vendor/protobuf+` copy,
leaving the accepted archive, lock, configured closure, and fixed-input package
unchanged. The action names declared Guix `grep` and `cat`, opts into the
package-controlled environment, and retains `fail_on_mismatch`; source-built
protoc remains selected. A fresh rootless no-NIC proof at
`/tmp/opencode/gvisor-protobuf-authenticity-tools-probe-retry2-20260905`
preserved all 18,812 configured release entries and completed the exact
authenticity target in 818 actions. Its validation output is exactly
`libprotoc 33.4`; the output SHA-256 is
`36885442447887c9e9ee6d23146be6b495ed463b82107d3e4f77aea3b650bc54`,
and the complete build log hashes to
`b26169b036a13bf74fd674d2611bfdad7a930be91063b889a7d51efc4f839771`.
No runtime or foreign output was executed.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/47x915pavz0k86j1wlggqv4lngalfhlb-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/lsq2gkmqpi6s60khk2icnm9yhix6h07h-gvisor-build-phase-helper-check-20260831.0`.

Retry 12 used the thirteenth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry12-20260905`. Its derivation,
`/gnu/store/c2yvhna91z73ynhkd09xvzx23xgzsaqx-gvisor-source-built-20260831.0.drv`,
passed source-built protoc authenticity and reached gVisor's exec-config
`GoStandardLibraryAnalysis`. That action passed Bazel 8's diagnostic rendering
of a `File` (`<source file src/go.mod>`) instead of a path; after that is
corrected, Go 1.26's `module std` line exposes a non-multiline version regexp,
and its installed package archives include seven test-support packages that
rules_go deliberately excludes from `go_sdk.srcs`. The build phase failed after
104.7 seconds; the outer command took 109.26 seconds and peaked at 315412 KiB
RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry12-20260905/logs/gvisor-source-built-20260831.0-native-retry12.full.log`.

Adding the omitted SDK source labels was rejected before compilation at
`/tmp/opencode/gvisor-nogo-go126-probe-20260905`: the complete closure gate
showed exactly eight new `net/internal/socktest` labels. The accepted 18,812
entry multiset therefore remains authoritative. The correction instead uses
the existing `File.path`, makes only the `go`-line regexp multiline-aware, and
removes exactly the seven compiled packages corresponding to rules_go's
declared test-support exclusions before retaining the general hard failure for
every other source mismatch.

A first closure-preserving exec-config probe at
`/tmp/opencode/gvisor-nogo-go126-probe-retry1-20260905` confirmed that
`File.path` produced the correct
`external/rules_go++go_sdk+main___download_0/src/go.mod` argument, then failed
on the non-multiline regexp and the next excluded package. That bounded failure
kept the full command and action evidence used to enumerate all seven exact
rules_go exclusions rather than adding them one at a time.

A fresh rootless no-NIC proof at
`/tmp/opencode/gvisor-nogo-go126-probe-retry2-20260905` preserved the complete
accepted closure and forced `//tools/nogo:stdlib` through an exec transition,
matching the failed `[for tool]` configuration without building a runtime.
`GoStandardLibraryAnalysis` completed and produced nonempty facts plus the raw
findings output. Their SHA-256 values are respectively
`8e05797c013d32cb31e31975348d8824f9f447abc1a9e10a76e23feaef048e5a`
and `ebcd8e5aa3f5a38c5b53f5260da3fa1c7b571354354203197eddd76d7cff283c`;
the build log hashes to
`42a20d1060855faa143bec33c40d0fd38d298ddd8949eebc91c8545e42158773`.

The true-chroot helper at that point was:

- derivation:
  `/gnu/store/pmbc50bw2fd0yhh2yiw4qxv52gqx42jb-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/r6vyysmvy66d16b3xcrxzzw35gilr4z6-gvisor-build-phase-helper-check-20260831.0`.

Retry 13 used the fourteenth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry13-20260905`. Its derivation,
`/gnu/store/d9ilr3w9llc7xv6ih0jymyzjyl99czmb-gvisor-source-built-20260831.0.drv`,
passed the complete standard-library `nogo` action and reached 4,762 of 6,898
actions. The next direct compiler action, `//vdso:vdso [for tool]`, failed on
`asm/unistd.h`: like prewarmer and sysmsg, this genrule sits outside Coral's
ordinary compile actions and had no declared Linux UAPI include flag. The build
phase failed after 521.9 seconds; the outer command took 526.49 seconds and
peaked at 314020 KiB RSS. Full evidence remains at
`/tmp/opencode/gvisor-native-first-retry13-20260905/logs/gvisor-source-built-20260831.0-native-retry13.full.log`.

The correction selects a dedicated `-isystem` flag for native or AArch64 from
the already declared Linux-header inputs; it does not use global `CPATH`. Two
probe-harness failures that did not compile the target remain at
`/tmp/opencode/gvisor-vdso-headers-probe-retry1-20260905` and
`/tmp/opencode/gvisor-vdso-headers-probe-retry2-20260905`; both retained
protobuf's validation-only output group and therefore requested no VDSO output.
The corrected fresh rootless no-NIC proof at
`/tmp/opencode/gvisor-vdso-headers-probe-retry3-20260905` preserves both
accepted configured closures, forces the native VDSO through an exec
transition, and separately cross-builds the AArch64 VDSO. `readelf` reports
ELF64 x86-64 and ELF64 AArch64 respectively; neither output was executed. The
native and AArch64 output SHA-256 values are
`6368c5a23195e7261e7206fac99a1896b902f0a8e35c19a1462b5a650fd84d98`
and `0301693a3e438e9e765a34927e26fab920dbbd3142d8ebd24d660cebf2b57df4`.

The current true-chroot helper is:

- derivation:
  `/gnu/store/ckmsgbycx19cqrzhn30g9kzi3n88lzmx-gvisor-build-phase-helper-check-20260831.0.drv`;
- output:
  `/gnu/store/sx1hvavm40x02gal8q8yg773yck33gb3-gvisor-build-phase-helper-check-20260831.0`.

Retry 14 used the fifteenth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry14-20260905`, but stopped in its sealed
preflight before lowering or starting Guix: a probe-log assertion omitted the
shell's quotes around the `-isystem` value. Its only run artifact is the
checksum-successful `logs/preflight.log`; no build log or status file was
created. Retry 15 used the sixteenth no-overwrite evidence root
`/tmp/opencode/gvisor-native-first-retry15-20260905`, but its packet-only
authorization constant retained the old token suffix; it refused before
creating a run directory. Retry 16 used a seventeenth no-overwrite evidence
root, `/tmp/opencode/gvisor-native-first-retry16-20260905`, but was rejected
during packet construction before its launcher was invoked because the
exact-token validator caught the same inherited suffix. All prior derivations
and logs remain preserved.

Retry 17 used `/tmp/opencode/gvisor-native-first-retry17-20260905` and replaced
the authorization assignment structurally. It succeeded: Bazel completed all
6,898 actions, the package's check and install phases passed, and Guix realized
the output above. The build phase took 655.1 seconds; the bounded outer command
took 663.48 seconds and peaked at 316480 KiB RSS. The build log SHA-256 is
`79a4719e2bc6ebb6b0c6e1d16f633eb23e3117a873ab94e9a8f76c030375cbba`.

`supported-systems` deliberately names only `x86_64-linux`, the execution host
supported by the fixed Bazel and Go seeds. The separate target-aware path
accepts only `aarch64-linux-gnu`; every other host or target fails explicitly.
This does not fabricate an AArch64 execution host: the proven AArch64 artifact
is an x86_64-hosted cross-build selected explicitly with `--target`.

The exact bounded native command is:

```sh
guix time-machine -C channels.scm -- build --no-grafts \
  --max-jobs=1 --cores=2 -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source)'
```

Guix is bounded to one job and two cores; Bazel is bounded to two jobs, two CPU
resources, 4096 MiB of scheduled local actions, and an 8192 MiB JVM heap cap.
For the first complete build, reserve roughly 12 GiB of RAM including Guix,
the JVM, and compiler processes, at least 20 GiB of free store/build space, and
several hours. Those are conservative operator planning figures, not measured
gVisor build results.

Only after native output passed all six layout/ELF/stamp checks was the AArch64
command attempted with `--target=aarch64-linux-gnu`. It succeeded from the
sealed packet at
`/tmp/opencode/gvisor-aarch64-first-retry1-20260905`: Bazel completed 6,877
actions, the package check/install phases passed, and Guix realized
`/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`
(recursive Guix hash
`06znixdbp8ak4g3psy058wfr1rdmpv42fb0yd3hah4fki8v5bdm8`). The build phase took
658.0 seconds; the bounded outer command took 663.75 seconds and peaked at
320100 KiB RSS. The build log SHA-256 is
`f1b301345caa89b603bc767d906937595d0153078e9037e9e595529023f8839f`.
The output has no store references.

The independent non-executing audit at
`/tmp/opencode/gvisor-official-aarch64-comparison-20260905` authenticated the
official archive at published SHA-256
`c1182b6046e1c64b871cd13b4d11335f1d55ba89c3a5c7e8cf4dc1c8f3ac0d3a`.
Both source-built and official trees have exactly the six expected files,
static ELF64 AArch64 identity, the same four release-marker placements, and the
same five Go 1.26.3 identities. All six content hashes differ, so this is a
property-level comparison rather than a byte-reproducibility claim. No AArch64
output was executed.

A later, separately named all-toolchain-from-source variant may replace Bazel
and Go; it must not retroactively relabel this package. No produced runtime was
executed, and no status was read or inferred from the forbidden separate
diagnostic-build directory.
