# gVisor reusable runtime package: adversarial first-build review

Date: 2026-09-05

## Preliminary verdict (superseded)

This section records the native-first decision at that point in the campaign.
The realized-package verdict at the end of this review supersedes it and
corrects the stale identities and prospective statements below.

**READY for the first native Guix build, using only the exact reviewed
launcher identified below.** No finite package-boundary blocker was found.
This verdict authorizes a compilation attempt, not acceptance of a runtime
artifact. A failure that identifies a missing action-time tool or dependency
is useful first-build evidence and should be fixed narrowly; it is not a reason
to enable networking, reuse an ambient cache, weaken the lock, or substitute a
prebuilt runtime member.

This is deliberately a preliminary gate:

- no gVisor runtime target has yet been compiled by this package;
- no native output exists to inspect independently;
- the AArch64 derivation has only been lowered, not compiled;
- none of the six resulting programs has been executed; and
- this says nothing yet about Systrap functionality, hostile-book isolation,
  the Book Protocol, output import, production resources, or release
  acceptance.

The approved first action is one native `x86_64-linux` package realization.
Do not start the AArch64 build until the native output exists and passes the
package's six-file checks plus a separate artifact review.

## Review boundary

The review covered the dedicated `gnu-build-system` package, its exact source
and build-only transformations, the already accepted fixed vendor input, the
explicit Bazel/JDK/Go bootstrap boundary, native and target tool selection,
fresh-cache and downloader policy, resource limits, output validation, and the
prepared native-build launcher.

It did not repeat the accepted 13 source-inventory tests or 22 vendor mutation
families. It reran only the bounded five-test Bazel-repacker suite, ten-test
runtime setup suite, and actual source/Coral patch-shape audit. It did not run
Bazel against a gVisor target, compile gVisor, realize either runtime output,
execute runsc or any sidecar, start QEMU, or access ARM hardware, a device,
SSH, or UART. No package, tool, patch, or packaging-design source was edited;
this review document is the only implementation-side change.

## Frozen identities

### Source and package

| item | reviewed identity |
|---|---|
| upstream tag | `release-20260831.0` |
| upstream commit | `fd2f6b2674208086e324c2f739155eb7e1b48ff2` |
| source output | `/gnu/store/wbr9z2rbw73lvgwnyyfgm2ifkln5ad7f-gvisor-20260831.0-checkout` |
| source recursive hash | `12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy` |
| `pinenote/packages/gvisor-source.scm` | SHA-256 `b033ea23365c8b91147fcd7093cde8bce0b508364182052ed2b808f4cb612359` |
| native derivation | `/gnu/store/64mnhvaq54bwjpnkbijaczm3ldp7g7nk-gvisor-source-built-20260831.0.drv` |
| native derivation file | SHA-256 `0daa9dde50684b5b6c3d45b6bde0f76eee58cdf031205238f1615ab75030ab44` |
| AArch64 derivation | `/gnu/store/mf555yn3wcvw1fkaj8556badf0pn9pv0-gvisor-source-built-20260831.0.drv` |
| AArch64 derivation file | SHA-256 `add3a7dd1ee8bce9d47db066e65fa2b59106b8e9b4ee396dee95aaf690b6163e` |

The clean source output reproduces the declared Guix recursive hash. It has no
`.git` directory and therefore cannot derive a mutable or ambient version
identity. The separate clean checkout used by the bounded setup test reports
the exact commit and exact tag and has no worktree changes.

The native and AArch64 lowering commands were independently rerun under
`guix time-machine -C channels.scm`; they returned exactly the two derivations
above. Their prospective outputs remain unrealized:

```text
/gnu/store/6rpnjcv1q4hc6v3akzc9vz0yw7wj9s86-gvisor-source-built-20260831.0
/gnu/store/xb5w7z3qx0lmsh197i6x0manq6qqynar-gvisor-source-built-20260831.0
```

### Accepted fixed input and bootstrap

| item | reviewed identity |
|---|---|
| fixed-vendor derivation | `/gnu/store/bj3k09rsyd30z1b0fvvq5j7km7g4cxl6-gvisor-release-vendor-inputs-20260831.0.drv` |
| fixed-vendor derivation file | SHA-256 `230dad5bf5092dbc898c107cde541c9088b672ebcd52596e2d56d5ccf1ccb0d8` |
| fixed-vendor output | `/gnu/store/6x5h6fpqysmyam51c3zy978nk6fmrq68-gvisor-release-vendor-inputs-20260831.0` |
| fixed-vendor recursive hash | `1sfan3bnkkx7cd6ih9ldkdgr6cprnnzbnfmxs48wck7ik8180ss1` |
| Bazel-bootstrap derivation | `/gnu/store/f24xzvvg1blsviskfdd6z7r3p6p7wm0m-gvisor-bazel-bootstrap-8.3.1.drv` |
| Bazel-bootstrap output | `/gnu/store/n9mlh2xgk9shc0f5328j8a9cqbfcvb0m-gvisor-bazel-bootstrap-8.3.1` |
| Bazel-bootstrap recursive hash | `1zql5gr90a2l4z02zm8y53bjg2l05g1va6i580cs188qks8lc0mn` |
| repacked Bazel executable | SHA-256 `8fbd218e1a0e0d80868f6a87ceaeea48d9983996c4b8b1df18fb998ca1159abd` |
| installed bootstrap manifest | SHA-256 `6f7d2c867c4cc91cc86c8197bf5b7e87cb018adc6d38bc1885a49482ea9e5220` |

The fixed-vendor derivation remains the already accepted derivation; defining
the runtime-only setup and bootstrap files did not change it. Both that
derivation and the runtime derivations reference the same
`/gnu/store/r7gamdq1f90yknjzh4gji0hsdv4gbmdl-gvisor-package-tools` input. Its
recursive selector excludes `bazel_bootstrap.py`, `runtime_setup.py`, their
tests, and `runtime-check.sh`, so runtime-only additions do not silently alter
the accepted vendor assembler.

## Source transformations and diagnostic separation

`gvisor/source` starts from `gvisor-source-origin`, not a local diagnostic
tree. Before Bazel starts, `vendor_inputs.py prepare-source` requires the exact
pristine `MODULE.bazel` SHA-256, adds the already accepted offline rules_go SDK
index patch at one pinned declaration, and requires the exact prepared module
SHA-256. The fixed lock is then copied from the accepted vendor output.

Only these runtime build adaptations are applied:

| adaptation | SHA-256 | purpose |
|---|---|---|
| `gvisor-bpf-guix-toolchain.patch` | `ed232b8f264c530ee0cd68bc5cd031b1a8a05e6cce62cde9d87c23d82f962ee9` | select declared BPF Clang and headers |
| `gvisor-release-version-offline.patch` | `9a8d0a0956db1b9d8717a348a71e7d7616829f3169c8c9dbb18dd2cbb36a2c05` | stamp the fixed release and commit without `.git` |
| `gvisor-coral-crosstool-guix.patch` | `177426cada7a351ff9d4cc1a9fe3a63b8592f4b0db711555360ec0e13423897a` | replace Coral FHS tool/include paths with declared Guix roots |

The Coral patch is not inserted into the source extension or lock. The build
extracts the exact accepted Coral archive, applies gVisor's two already
declared Coral patches, applies the Guix adaptation to that private copy, and
selects it with one explicit canonical `--override_repository`.

The approved diagnostic patch SHA-256
`9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`
does not appear in the package definition, either lowered builder, the clean
source, or the fixed-vendor derivation. Its distinctive MemoryFile/Systrap
diagnostic strings are absent from the clean source. No PineNote kernel,
Systrap mode, DirectFS, mount, network, sidecar, OCI, or other runtime-policy
setting appears in this reusable package.

## Bazel and toolchain bootstrap boundary

Bazel 8.3.1 and its embedded JDK 24, plus the rules_go-selected Go 1.26.3 SDK,
remain explicitly labelled binary bootstrap inputs. This package makes no
all-toolchain-from-source claim.

The Bazel repacker first verifies the upstream executable's fixed SHA-256. It
rejects duplicate ZIP names or changed first/final members, verifies the exact
29 dynamic ELF-member count, rewrites each executable interpreter to a
declared Guix loader, rebuilds the archive deterministically, checks every ZIP
CRC and member order, and changes the install-base key based on all transform
inputs. The realized manifest records 29 distinct dynamic ELF members: 11 with
interpreters and 18 shared objects. All 29 report dynamic dependencies.

The outer self-extracting executable is x86-64 ELF with
`PT_INTERP=/proc/self/fd/9`. Its installed wrapper opens the immutable Guix
loader on descriptor 9 and sets `LD_LIBRARY_PATH` to exactly three declared
store roots: glibc, GCC, and zlib. The executable has no RPATH/RUNPATH. Neither
the wrapper nor manifest names a host `/usr`, `/lib`, or `/lib64` runtime path.
The wrapper's `/proc/self/fd/9` indirection is why generic Guix RUNPATH
validation is disabled only for this separately named bootstrap package.

The retained Guix build log confirms the exact bootstrap was built inside the
ordinary Guix build environment. Its check phase ran `bazel version`, which
extracted and started the embedded JDK, then completed the direct extracted
`process-wrapper` probe. The package's five synthetic transform tests also
cover source-hash rejection, deterministic reconstruction, ZIP order/install
key, non-FHS library-path rejection, and ELF-count drift. This is enough to use
the fixed executable as a first-build seed; failure of a less common embedded
helper remains possible compilation evidence, not grounds for an FHS fallback.

## Build containment and dependency discovery

The build uses ordinary `gnu-build-system`. It does not invoke `guix shell`, an
FHS emulation container, Docker, or a host Bazel installation. The lowered
builder contains the clean source, accepted vendor output, accepted Bazel
bootstrap, runtime setup tool, three build patches, native compiler/binutils/
libc, BPF compiler/headers, and an explicit action-tool set as Guix store
inputs. The AArch64 builder adds distinct cross GCC, GCC-library, binutils-gold,
libc, and target-header derivations; the native builder does not carry those
target inputs.

Every derivation creates private directories under its Guix build directory
for:

- `HOME`, `XDG_CACHE_HOME`, and temporary files;
- each Bazel `output_user_root` and output base;
- the materialized vendor tree and prepared Coral tree;
- an initially empty repository cache used by the post-vendor analysis/build;
  and
- a new private build action cache.

No caller `HOME` or `XDG_CACHE_HOME` is read. HTTP, HTTPS, FTP, all-proxy,
`NO_PROXY`, Go bypass, global compiler include, and library-path variables are
unset before Bazel. `HOME`, all temporary variables, locale, time zone, source
epoch, compiler variables, and Go module policy are then assigned explicitly.

Every Bazel invocation uses:

```text
--batch --nosystem_rc --nohome_rc
--repository_disable_download --lockfile_mode=error
--incompatible_strict_action_env --spawn_strategy=local
--repository_cache=<derivation-private path>
--vendor_dir=<derivation-private materialized vendor tree>
GOPROXY=file://<accepted fixed input>/go-proxy
GOSUMDB=off GONOSUMDB=* GOPRIVATE=
```

There is no configured remote cache or remote executor in the package or
upstream workspace `.bazelrc`. The initial vendor command is allowed to read
only a mutable copy of the accepted content-addressed cache. Configured
`cquery` and compilation use fresh output bases and the initially empty private
repository cache, never the discovery caches. That repository-cache directory
is shared between those two operations inside this one derivation; this is not
ambient cache reuse, and downloads remain disabled throughout. Any bytes it
can acquire came from the fixed vendor tree in the same derivation.

`--spawn_strategy=local` is explicit: the package does **not** claim a nested
Bazel action sandbox. The outer Guix build chroot/network namespace is the
filesystem and no-network boundary, while strict action environment and the
declared action `PATH` govern normal tool discovery. Local actions may see the
package's declared Guix build closure and writable build directory, but not
arbitrary host files or caches. This is acceptable for compiling fixed trusted
source and is wholly separate from the hostile-book runtime security boundary.

The first complete native build is still the test of action-time closure. If a
repository rule or action needs a tool not in the declared closure, it must
fail. The correct response is to identify and add that fixed host tool, not to
add a host mount, ambient `PATH`, downloader, network, or warm cache.

## Compiler and architecture handling

`runtime_setup.py` accepts only `native-x86_64` and `aarch64`. With
`--require-store`, every compiler, binutils, libc, Clang, header, libbpf, and
action-tool root must be an absolute existing `/gnu/store` directory. It
requires every named GCC and binutils program, including `ld.gold`, then creates
private explicit prefixes. Native setup rejects stray target inputs; AArch64
setup fails if any target component is absent. Other architectures fail before
Bazel.

The Coral configuration receives only those prefixes and declared include
roots. Native and target compilers remain distinct, unsupported Coral targets
point at visibly nonexistent paths, and `-fuse-ld=gold` remains pinned. The
strict action and repository environments receive explicit `CC`, `CXX`, `AR`,
and `LD` paths rather than selecting host tools from an ambient environment.

BPF generation deliberately remains a native build tool operation using the
declared Clang with `-target bpf`. The `//:release` BPF sources include Linux
UAPI `linux/types.h`/`linux/bpf.h` and libbpf helper headers and do not consume
the runtime target's userspace ABI. Supplying the declared Linux UAPI and
libbpf include roots independently of the native/AArch64 runtime compiler is
therefore the correct architecture split.

The command-line setting
`@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false` overrides
the upstream `.bazelrc` default for vendor, analysis, and build. The configured
native closure includes `@com_google_protobuf//:protoc` and its source targets,
and the accepted fixed graph includes protobuf 33.4, Abseil 20250814.1, and
zlib 1.3.1 sources. The excluded prebuilt-protoc repository is recorded as
disabled. Thus protoc must compile from fixed source during the first build.

## Resource and lifecycle bounds

Inside the derivation, both vendor materialization and configured analysis have
75-minute `timeout` bounds. Compilation has an eight-hour bound. GNU timeout
uses TERM followed by KILL after two minutes. Bazel is in batch mode and is
limited to two jobs, two local CPU resources, 4096 MiB of scheduled local RAM,
an 8192 MiB JVM heap, and two JVM active processors.

The 4096 MiB setting is a Bazel scheduler budget, not an OS hard-memory limit;
the 8192 MiB setting is the JVM heap cap, not a cap on all compiler children.
The operator's measured 93 GiB available memory and 1.2 TiB free storage are
therefore ample for the documented roughly-12-GiB planning reservation, but
actual first-build high-water use remains evidence to collect with GNU time.
No production cgroup or PineNote resource policy has been added to this
reusable package.

## Build and installed-output gates

Before compilation, the package regenerates `bazel vendor //:release` with
downloads disabled, copies only the fixed BCR registry view into that vendor
tree, audits the prepared source and Coral tree, then runs configured `cquery`
from a fresh output base and compares its complete labels byte-for-byte with
the accepted native or AArch64 closure. A closure drift therefore blocks the
expensive action phase.

The package keeps `#:tests? #t`; it does not use a `tests? #f` architecture
shortcut. Its package-specific check is not the complete upstream test suite.
Instead it validates the reusable release artifact that `//:release` is meant
to produce. It requires exactly these six executable regular files and no
other release-tree entries:

```text
containerd-shim-runsc-v1
gvisor-bin/checkpointgofer
gvisor-bin/gvisor-sentry-prewarmer
gvisor-bin/gvisor_sentry
gvisor-bin/runsc-metric-server
runsc
```

Every member must have the selected ELF machine, no program interpreter, and
no dynamic `NEEDED` entries. The five Go-built executables must contain Go
1.26.3 metadata. The four versioned executables must contain exact
`release-20260831.0`; the containerd shim and C prewarmer must remain
unversioned. Installation copies only those six files beneath `bin/` at mode
`0555` and rechecks the exact top-level and sidecar layouts. No build tool,
source, cache, runtime flag, kernel assumption, or policy file enters the
installed output.

These checks are necessary, not final acceptance. After the native build, an
independent review must hash the actual six files, inspect their complete ELF
and Go metadata, verify no host/target or bootstrap member substitution, and
compare their provenance with the build log. Native success does not establish
that AArch64 compiles or that either architecture runs correctly.

## Bounded host-only recheck

The existing runtime-only gate was rerun against the exact clean source and
accepted fixed-vendor output. Results:

```text
5/5 Bazel repacker tests: PASS
10/10 runtime setup/package-audit tests: PASS
actual clean-source + prepared-Coral audit: PASS
runtime-check final status: PASS (no Bazel, no compilation)
```

This covered deterministic repacking and transform failures; native and
AArch64 explicit tool setup; missing gold/cross-tool failures; unused cross
input and unsupported architecture failures; store-root enforcement; source,
Coral, downloader, and caller-home audit failures; and the actual three-patch
prepared shape. It did not duplicate the accepted vendor negative matrix.

The bootstrap output and manifest identities reproduced. The native and
AArch64 derivations lowered to their frozen paths under the pinned channel.
Both runtime output paths were checked absent after lowering, confirming that
no compile was accidentally started.

## Exact first-native launcher

The prepared packet is:

```text
/tmp/opencode/gvisor-native-first-command-packet-20260905-xobhzkdx/
```

Its reviewed identities are:

| file | SHA-256 |
|---|---|
| `launch-native.sh` | `f096f32351f04a8f9739040a7719a8f10dc79806dc78d159402cad8559b4fecc` |
| `input-sha256sums` | `612e8de63860e39d25ecadaff2c2f22b35c2f47942ada6af26b1a616c6ef4c67` |
| `RUN.md` | `28a65d484b0ae3e8ade45ca71d1023b7c1b09317627958c79c79ec8f2c9eff3a` |
| `packet-validation.log` | `7fdd9c211f331c02664c378a8df9aa6591ec7f2682b3139a7b5eccff8f6129f8` |

The packet directory is owned by the operator and mode `0700`; its logs
directory is absent. The input-manifest check independently passed for all 19
frozen channel/package/tool/patch/closure files, the launcher passes `bash -n`,
and re-lowering resolves the expected native derivation. The launcher itself
must still match the exact SHA-256 above at invocation time because a script
cannot securely establish its own pre-execution identity.

The launcher refuses without the exact parent authorization value, creates its
logs directory once and refuses overwrite, uses `umask 077`, rechecks all
source hashes and both realized fixed-input recursive hashes, re-lowers and
compares the exact native derivation, and invokes only:

```text
guix time-machine -C channels.scm -- build --no-grafts \
  --max-jobs=1 --cores=2 -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor/source)'
```

An outer eight-hour timeout applies TERM then KILL after two minutes. GNU time
records resource metrics separately. The complete Guix output is retained in a
new private file; a failure prints only its final 200 lines and points to the
full log. A successful build records the output path but does not execute it.
The launcher's `/usr/bin/time` and `/usr/bin/timeout` are trusted-host
supervision tools outside the Guix package derivation and do not introduce FHS
paths into the package or its output.

The ready verdict applies only to the launcher at SHA-256
`f096f32351f04a8f9739040a7719a8f10dc79806dc78d159402cad8559b4fecc`
and only after the parent supplies the documented authorization. This reviewer
did not run it.

## Next gate after the build

If the native build fails, preserve the full log and timing record and classify
the first failure before changing anything. A missing ordinary build tool can
be added as a declared native/action input without reopening accepted vendor
provenance. A missing repository or attempted network/cache fallback is a
closure failure and must block rather than be papered over.

If it succeeds, retain the exact derivation, output path, full log, timing
record, and six member hashes. Independently review the realized native output
before attempting AArch64. Runtime execution and all book-computer gates remain
separate and require their own authorization and evidence.

## Final realized-package disposition

### Verdict

**ACCEPT the exact native and AArch64 outputs below as reusable Guix gVisor
runtime packages compiled from the pinned source and fixed dependency closure.**
The native compilation gate, native artifact gate, AArch64 compilation gate,
and AArch64 artifact gate pass separately. No unresolved technical package
defect was found in the bounded evidence.

This acceptance is content- and derivation-specific. It authorizes these
artifacts for downstream realized-image assembly and review; it does not accept
runtime functionality. Neither `runsc` nor any sidecar was executed during
this review. Systrap execution, ARM64 Guile or Python, Book Protocol FD
donation, hostile-book isolation, output import, production resources, the V8
image, QEMU, and release acceptance all remain separate gates.

No independent clean rebuild was requested or performed. The two existing
successful builds were authenticated and audited. Consequently this is not a
claim that a second build is byte-for-byte reproducible, and it is not an
all-toolchain-from-source claim.

### Final identities

| item | accepted identity |
|---|---|
| implementation manifest | `/tmp/opencode/gvisor-source-package-final-evidence-retry1-20260905/implementation-sha256sums`, SHA-256 `76c9aa259fa82863a42fd15dba9bf65a66a4a865d186c671630f63a229ebab64` |
| evidence manifest | `/tmp/opencode/gvisor-source-package-final-evidence-retry1-20260905/evidence-sha256sums`, SHA-256 `11be43474e1089d2a789838bdabef2bf6a00ddb8ad48014a4feeb044a3c71b6d` |
| identity record | `/tmp/opencode/gvisor-source-package-final-evidence-retry1-20260905/identities.txt`, SHA-256 `1b7c2e8f5acfaeeb6dff98ca48abab152580d1c4abcdefae9dddf7bec7b0f2a8` |
| package definition | `pinenote/packages/gvisor-source.scm`, SHA-256 `0b35b6bfa406bc6b063e3e1d1ff6daabe26acfdff66a673b1fe315ceffc4b740` |
| pristine source | `/gnu/store/wbr9z2rbw73lvgwnyyfgm2ifkln5ad7f-gvisor-20260831.0-checkout`, recursive hash `12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy` |
| fixed vendor input | `/gnu/store/6x5h6fpqysmyam51c3zy978nk6fmrq68-gvisor-release-vendor-inputs-20260831.0`, recursive hash `1sfan3bnkkx7cd6ih9ldkdgr6cprnnzbnfmxs48wck7ik8180ss1` |
| native derivation | `/gnu/store/ll18lsyll28xk0ms7zb3hkz46vpwp333-gvisor-source-built-20260831.0.drv`, SHA-256 `2d2f11b0ece814b4165be8b0f6e6fdac765872727376c936d10de88915bafb50` |
| native output | `/gnu/store/zgfaq0i8jdsm08xlahmyx5yg23ndnc30-gvisor-source-built-20260831.0`, recursive hash `093dvw89z68634683b3hvc2367jx0vvn6785lwccn9j8ab2nqcn0` |
| AArch64 derivation | `/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv`, SHA-256 `dc908b40639264c4249c28c9b6075ab866eb6a363441fb43636b90312aea830c` |
| AArch64 output | `/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`, recursive hash `06znixdbp8ak4g3psy058wfr1rdmpv42fb0yd3hah4fki8v5bdm8` |

Both output-to-derivation mappings were rechecked directly. Both outputs have
an empty Guix reference set: the build tools, source, vendor material, and
store paths did not leak into the runtime package.

### Compilation evidence

Native retry 17 completed `//:release` with 6,898 Bazel actions, passed the
package check and install phases, and exited zero. The retained log SHA-256 is
`79a4719e2bc6ebb6b0c6e1d16f633eb23e3117a873ab94e9a8f76c030375cbba`.
Only after that artifact passed its static gate was the explicit
`--target=aarch64-linux-gnu` build attempted. It completed 6,877 actions,
passed check and install, and exited zero; its log SHA-256 is
`f1b301345caa89b603bc767d906937595d0153078e9037e9e595529023f8839f`.

The outer wall times were 11:03.48 and 11:03.75 with recorded launcher-process
RSS peaks of 316480 and 320100 KiB. Those RSS figures describe the supervising
client, not the Guix daemon's complete compiler/JVM process tree, so they must
not be presented as whole-build high-water measurements.

The derivation builders directly bind the accepted pristine source, fixed
vendor output, actual Bazel bootstrap, package tools, declared native tools,
declared AArch64 tools, and exact patches. They do not reference the official
prebuilt gVisor runtime or the diagnostic patch. All six source-built files
also differ byte-for-byte from the corresponding official release files. This
closes prebuilt-runtime substitution for the reviewed derivations; it does not
remove the explicitly accepted Bazel/JDK/Go bootstrap boundary.

One preliminary statement requires an architectural correction: the native
derivation intentionally includes AArch64 compiler, binutils, libc, and header
inputs. Upstream's native `//:release` graph builds embedded split-architecture
sysmsg artifacts, so omitting those target tools is not a valid native purity
criterion. The separate AArch64 runtime is still selected only by Guix's
explicit target option.

### Actual Bazel bootstrap used by both builds

The preliminary `n9mlh2x...` bootstrap is superseded for final-build
provenance. Both final builders use exactly:

```text
derivation: /gnu/store/y8vxhya9324y7scr5bx6i9kgwql95drb-gvisor-bazel-bootstrap-8.3.1.drv
output:     /gnu/store/bwxhk066irv1lmyvr7qnmbrjg3rvp07c-gvisor-bazel-bootstrap-8.3.1
NAR hash:   0a811l8l3xbzv9di7v9j97bc8ppnc7749cx97k7yi1jgrnhw943f
```

The raw Bazel 8.3.1 executable remains pinned at SHA-256
`17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c`.
The v2 repacker has SHA-256
`cc77fbdcbecfdb5c28c7d4e9febe2b3083fbae7d3d2335d14902102949f85bc7`;
the installed `bazel.real` and manifest hash to
`fed90ac872ecfb26041a58fe25ed5be93fd34961ec5c1173e23a80dc6100b7d2`
and
`bf4bbf60d339350f994c043e5aedd670cb22b77a184063d766fc3ab2fffb87e4`.

The independent, non-executing reconciliation at
`/tmp/opencode/gvisor-bootstrap-v2-independent-static-audit-20260905/`
reconstructed the exact manifest from the raw and transformed ZIP/ELF bytes.
Its report SHA-256 is
`2a93444ff869e72bb70102c7c46243442ae504b53dc7506291e5b937644ffe30`.
It confirms:

- all 29 raw dynamic ELF members are accounted for;
- the 11 interpreter-bearing executables are adjacent shell-wrapper/payload
  pairs, while the other 18 are shared objects;
- transformed payloads use the declared Guix loader;
- wrappers use only the declared Bash and glibc/GCC/zlib library paths;
- the launcher uses the fixed-width `/proc/self/fd/9` interpreter rewrite;
- the derived install key is `eefc1a44140ff88c02770d654d448bdc`;
- ZIP order, fixed timestamps, CRCs, output layout, modes, and manifest all
  agree; and
- no ambient/FHS loader or library path is introduced.

That independent audit did not invoke Bazel. It instead bound the retained
no-NIC five-action helper probe to byte-identical extracted
`process-wrapper`/payload members from this exact transformed archive. The
earlier package check and helper probe are the execution evidence for the
embedded JDK and helper path; the static reconciliation is the provenance
evidence.

Bazel, embedded JDK 24, and Go 1.26.3 remain hash-pinned binary bootstrap
inputs. Accepting this package does not claim they were built from source.

### Network, downloader, cache, PATH, and FHS synthesis

For the exact release graph, the action-time boundary passes:

- the package is an ordinary `gnu-build-system` derivation, not an FHS
  container or host Bazel invocation;
- every Bazel operation uses `--batch`, `--nosystem_rc`, `--nohome_rc`,
  `--repository_disable_download`, `--lockfile_mode=error`, strict action
  environment, and `--spawn_strategy=local`;
- `HOME`, `XDG_CACHE_HOME`, temporary roots, output-user roots, output bases,
  action cache, repository caches, and three repository-contents caches are
  newly created inside each derivation;
- analysis and compilation start from empty repository caches and distinct
  repository-contents caches, so vendoring cannot become their undeclared
  secondary cache input;
- Go resolves only through the fixed local `file://` proxy with `GOSUMDB=off`,
  `GONOSUMDB=*`, and empty `GOPRIVATE`;
- HTTP, HTTPS, FTP, all-proxy, no-proxy, Go bypass, global include, and ambient
  library-path variables are removed before Bazel;
- action, host-action, and repository environments receive explicit compiler,
  linker, binutils, shell, coreutils, archive, Python, Clang, and header paths;
  `runtime_setup.py` rejects `/bin` or `/usr` in that action path; and
- targeted no-NIC probes exercised the nonstandard BPF, prewarmer, Coral,
  split-architecture sysmsg, VDSO, rules_go helper, protoc-authenticity, and
  nogo paths that failed during closure development.

`--spawn_strategy=local` means Bazel actions were not protected by a nested
Bazel sandbox. The outer Guix build chroot/network namespace was the isolation
boundary. This is acceptable for compiling the pinned trusted source and is
not evidence about hostile-book runtime isolation.

The successful exact builds close the discovered action-time tool set for
`//:release`: no missing command, loader, library, or header fallback occurred.
This is not a claim that every unused upstream rule is FHS-free. Source
shebang rewriting touched many files outside the release graph; their presence
in the unpacked tree does not show that those scripts ran.

Both outer logs contain substitute checks against Guix servers and a
`/home/wkelly/.cache/guile/ccache` notice before the derivation phases start.
Those are host-side Guix evaluation/substitution activity, not Bazel action
inputs or derivation network access. The current source was newer than the
compiled Guile cache, the final derivation identities bind the current package
definition, and neither path appears in an installed runtime.

No downloader fallback, ambient Bazel cache, host `PATH`, FHS mount, remote
cache, remote executor, or prebuilt runtime substitution was found. The
network conclusion is bounded to the Guix sandbox plus reviewed flags and
no-NIC replay evidence; it is not a packet-level trace of the Guix daemon.

### Source protoc and authenticity

The explicit
`--@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false`
argument overrides the earlier inherited `.bazelrc` default on vendor,
analysis, and build commands. The fixed manifest identifies protobuf 33.4,
Abseil 20250814.1, and zlib 1.3.1 source archives and marks
`protobuf++protoc+prebuilt_protoc.linux_x86_64` excluded.

The full logs show protobuf compiler source actions; the focused no-NIC probe
compiled `src/google/protobuf/compiler/main.cc`, completed 818 actions, ran the
still-enabled `ProtocAuthenticityCheck`, and produced exactly
`libprotoc 33.4`. The private protobuf-vendor patch only replaces bare `grep`
and `cat` with declared Guix paths and opts the action into the controlled
environment. It neither enables `allow_nonstandard_protoc` nor weakens the
version mismatch failure.

### Compatibility-patch disposition

The final package has eight default source patches, not the preliminary three:

1. BPF compiler/header selection;
2. Bazel 8 nogo `File.path` compatibility;
3. Go 1.26 nogo standard-library filtering;
4. fixed offline release stamping;
5. prewarmer UAPI headers;
6. split-architecture sysmsg UAPI headers;
7. explicit tools/environment for two Starlark shell-action sites; and
8. native/AArch64 VDSO UAPI headers.

Two more transformations are kept outside the pristine/default source patch
list: the Coral crosstool adaptation is applied to a private extracted Coral
copy, and the protoc-authenticity adaptation is applied to a private vendored
protobuf copy. All ten hashes in the final implementation manifest reverify.
They replace environment/FHS assumptions or bridge pinned tool-version APIs;
none changes gVisor runtime policy, enables DirectFS/ptrace/networking, changes
Systrap behavior, or disables the protoc authenticity action.

The nogo patches need a precise qualification. The focused probe forced
`//tools/nogo:stdlib` through the exec configuration, compiled package code
including `//pkg/gohacks:gohacks`, and completed the standard-library analysis.
The seven filtered paths exactly document rules_go-omitted test/support source
packages, while the general “compiled package present but source absent” error
remains. Both complete release builds also logged standard-library analysis for
host and target configurations.

However, upstream `.bazelrc` still specifies
`build --build_tag_filters=-nogo`: explicitly tagged nogo targets are omitted
from ordinary builds and upstream says they are included by default for tests.
This package invokes `bazel build //:release`, not `bazel test`. Therefore build
success proves the analysis actions reached by the release graph; it is not
complete nogo test acceptance and not the upstream gVisor test suite.

The separate diagnostic source remains absent from the default derivations.
`gvisor/source-diagnostic` was reviewed only as a source variant: its realized
origin has the same 4,961-path inventory with exactly three approved changed
files. No diagnostic runtime was built or executed.

### Independent installed-output audit

The independent audit at
`/tmp/opencode/gvisor-runtime-package-independent-static-audit-20260905/`
used only `readelf`, `go version -m`, hashes, and filesystem inspection. It did
not execute either runtime. Its report and PASS hashes are
`cf14d3c097b5018d4746cf755a78ed94e0f0160d7afcca2c05d97190aad8e545`
and
`b99d8a0fc43e12a5558f8d6fedbbffdd8851305ddf7280e92c4fbf1f9e948612`.

Each output contains exactly the six expected runtime programs plus
`share/doc/gvisor-source-built-20260831.0/LICENSE`. Every executable is a
regular mode-`0555`, little-endian ELF64 `EXEC`, with the expected x86-64 or
AArch64 machine, no interpreter, no `DT_NEEDED`, and no store reference. The
five Go programs report Go 1.26.3. Exactly `runsc`, `checkpointgofer`,
`gvisor_sentry`, and `runsc-metric-server` carry the release marker; the
containerd shim and C prewarmer do not.

Native member SHA-256 values:

| member | SHA-256 |
|---|---|
| `containerd-shim-runsc-v1` | `2686545cc108cd2482d44ce679dfc5bb7b308df709fdfb0b8588a4c5108d5ec1` |
| `gvisor-bin/checkpointgofer` | `47f37535cf37e6f3b491abbae41762da0ce8f946dc777b7f3283ef660b2c4aa1` |
| `gvisor-bin/gvisor-sentry-prewarmer` | `bfa87c12ac5d77a91779e37cdbdb17904bc49c8c2108630eaa5ed4457a4713f9` |
| `gvisor-bin/gvisor_sentry` | `dae2d612232150bb2a8e572ba6a38a08ace5c1c082e4d7adb20419c9d8fa6f58` |
| `gvisor-bin/runsc-metric-server` | `4e0afedb92133ef106932b1804ec393925e2a80f9d483c2132eaec99181b1946` |
| `runsc` | `92208eb875775295e0823121e96f1495ff72b8e050fec7f87f1c91e66b88d430` |

AArch64 member SHA-256 values:

| member | SHA-256 |
|---|---|
| `containerd-shim-runsc-v1` | `632f5881156b7caeb12c8faf72408efdadc737633889939c6a793b79dd9de321` |
| `gvisor-bin/checkpointgofer` | `32cf655d92457ecd244c0b3877c14bc99ce9128baa5001a5c6543dcf40f1a0a6` |
| `gvisor-bin/gvisor-sentry-prewarmer` | `5bf3ed8a31bfde29d73ad5c822aacd16df52a9741caa43bacbb0e8b066034896` |
| `gvisor-bin/gvisor_sentry` | `c3603fcc0bdad6705fbb7df6741ac0fc225e3f75993a10a36154db3613c58101` |
| `gvisor-bin/runsc-metric-server` | `7d7b315b17fd41d775ad8ccab95a01ee2d2972674381334f40c9040f04642be9` |
| `runsc` | `c6f9a31fca559bd2f0ca2015eda88350b2a147ea9f349a917e000e01a43d5eb3` |

The installed license in both outputs is mode `0444`, SHA-256
`0fbab5c58efbdf6d31e8085214f2dd821659c03d73cff3ed2b08e98826ea1cd9`,
and byte-equal to the pinned upstream source `LICENSE`.

The checksum-pinned official x86-64 and AArch64 archives have the same six-file
runtime roster, architecture/static-linkage properties, release-marker policy,
and Go identity. All source-built members intentionally differ from their
official counterparts. Those comparisons are useful property oracles, not
runtime tests or byte-reproducibility claims.

### License boundary

The gVisor source and installed top-level license are Apache-2.0. The fixed
vendor manifest separately binds repository provenance to detected and hashed
license evidence: 115 direct repositories have evidence and 13 generated
repositories identify the source repository from which they inherit.
`rules_kotlin` 1.9.6 remains the single explicit unknown because its source
archive contains no license file. The bootstrap package correctly uses
`license #f` rather than flattening Bazel's Apache-2.0 and the embedded JDK's
GPL-2.0-with-Classpath-Exception/third-party shelf into one claim.

This is adequate provenance accounting for technical package acceptance, not
legal clearance. This review did not decide whether distribution requires
installing additional third-party notices beside the six binaries, and it did
not resolve the `rules_kotlin` omission. Those remain release/legal-review
items rather than reasons to substitute unpinned dependencies or block use of
the exact artifacts for the next technical gate.

### Reproducibility and remaining blocks

What is accepted:

- exact pristine source and accepted fixed dependency input;
- exact v2 Bazel bootstrap transform and explicit binary-bootstrap boundary;
- successful existing native and x86_64-to-AArch64 compilations;
- exact Guix derivation/output mappings and recursive output hashes;
- exact static runtime layout, architecture, linkage, stamps, modes, license,
  and absence of store references; and
- the reviewed networkless/fresh-cache/explicit-tool build design for this
  `//:release` graph.

What remains unproven or blocked:

- independent clean rebuild and byte-for-byte reproducibility;
- upstream gVisor tests and complete nogo test coverage;
- native or AArch64 runtime execution and general gVisor functionality;
- ARM64 Systrap, Guile, Python, and exact Book Protocol FD donation;
- exact endpoint/process/cgroup/runtime-state/diagnostic cleanup in V8;
- hostile-book isolation and general output import or persistence;
- production resources, reader integration, and release acceptance; and
- complete redistribution/legal review.

No package build, runtime, QEMU, image, mount, network, hardware, SSH, UART, or
device action was initiated by this final review. The concurrent V8 image work
was not inspected or disturbed. The next package-related gate is realized V8
system/image review; any runtime execution still requires separate explicit
authorization.
