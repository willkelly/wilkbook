# gVisor source-package gates

This directory owns two boundaries for upstream gVisor
`release-20260831.0` at
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`:

1. `inventory.py` parses the clean source declarations without evaluating
   Starlark or invoking Bazel. It records 18 direct Bzlmod modules, reachable
   local extension downloads, and all 122 selected `go.mod` modules.
2. `release-vendor-manifest.json` records the configured `//:release` closure
   discovered separately for native x86_64 and x86_64→AArch64. It maps every
   vendored canonical repository to fixed source provenance and license
   evidence or an explicit omission.

The ordinary gate is cheap and networkless:

```sh
pinenote/tools/gvisor-package/check.sh /tmp/opencode/gvisor-fd2f6b2674
```

It runs 13 direct-inventory tests, 22 vendor-boundary tests, compares the
generated Guix origin table, checks all committed closure artifacts, and
exercises mutation failures. It does not invoke Bazel or Go.

## Fixed-input artifacts

- `pinned-source-inventory.json` — direct source declarations.
- `release-MODULE.bazel.lock` — identical native/AArch64 generated lock.
- `release-closure-native-x86_64.txt` and
  `release-closure-aarch64.txt` — configured `deps(//:release)` labels.
- `release-vendor-manifest.json` — URLs, hashes, BCR records, Go proxy
  metadata, canonical repositories, target reachability, licenses, and known
  provenance omissions.
- `rules_go_offline_sdk_index.patch` — packaging-only replacement for the
  mutable Go release-index request.
- `emit_guix_inputs.py` and `pinenote/packages/gvisor-dependencies.scm` — the
  generated table of 117 URL origins plus one fixed BCR Git origin.
- `vendor_inputs.py` — downloader-free assembler for 359 Bazel CAS inputs,
  24 canonical-ID markers, a 273-file local Go proxy, and the Bazel bootstrap.
- `network_namespace.py` — records outer/inner namespace identities,
  interfaces, and routes, then checks the same process immediately before it
  `exec`s each Bazel operation.

The 24 marker names are not accepted merely because they look like SHA-256.
Each must equal SHA-256 of Bazel's default canonical ID (the space-joined
archive URL list), and the sorted `(CAS SHA-256, marker ID)` map is sealed by
`29acb447986ca0c9e5b9ec29abf7305c082b5ce52a06ba50c24ec6c788129715`.
The Go SDK is the one markerless archive because rules_go downloads it by
checksum without an explicit canonical ID. Repository-to-origin, reverse-link,
generated-alias, and license-evidence relationships are validated and sealed
separately; the `rules_kotlin` missing-license record cannot be replaced by
fabricated evidence.

`gvisor-release-vendor-inputs` in `pinenote/packages/gvisor-source.scm`
realizes that representation without running Bazel:

```sh
guix time-machine -C channels.scm -- build -L . \
  -e '(@ (pinenote packages gvisor-source) gvisor-release-vendor-inputs)' \
  --no-grafts --max-jobs=1 --cores=1
```

The configured closure forces protobuf's `prefer_prebuilt_protoc` setting to
false. Bazel 8.3.1 and Go 1.26.3 are the only prebuilt bootstrap inputs;
`protoc` is built later from the fixed protobuf, Abseil, and zlib sources.

## Discovery and replay

`vendor-discover.sh` is the only network-authorized tool. It requires an
explicit commit-scoped authorization token, a clean pinned checkout, an exact
Bazel 8.3.1 binary, and a new
`/tmp/opencode/gvisor-guix-vendor-*` directory. It runs only `bazel vendor`,
`cquery`, and manifest generation with two CPUs, two jobs, bounded RAM, and
timeouts; the logs must report zero build actions.

```sh
export GVISOR_VENDOR_DISCOVERY_NETWORK=\
fd2f6b2674208086e324c2f739155eb7e1b48ff2:release-target-vendor-discovery
pinenote/tools/gvisor-package/vendor-discover.sh \
  /tmp/opencode/gvisor-fd2f6b2674 \
  /tmp/opencode/wilkbook-gvisor-v6-prereqs/bazel-8.3.1-linux-x86_64 \
  /tmp/opencode/gvisor-guix-vendor-NEW
```

`offline-check.sh` consumes only the clean source and the realized fixed-input
package. Run it inside the pinned Guix/FHS container described in
`doc/gvisor-packaging.md`, with networking omitted. The caller must first
capture its outer namespace and pass that snapshot as
`GVISOR_OUTER_NETNS_SNAPSHOT`; the script fails before preparation if the
namespace identity did not change, if anything except loopback is present, or
if an external route exists. It also clears proxy/Go bypass variables and
records their state immediately before each Bazel `exec`. Downloader flags by
themselves are explicitly not accepted as this boundary. For each architecture
the script:

1. regenerates the vendor tree with downloads disabled;
2. compares fresh-cache configured analysis with the committed closure;
3. removes the required Go SDK repository and requires analysis to fail; and
4. removes the `rules_go` archive and requires attempted fallback to fail with
   `download is disabled`.

It never builds or executes a gVisor runtime target.

The unmodified source still has no upstream `MODULE.bazel.lock`, and its
unhashed `google_root_pem` declaration still makes
`inventory.py --require-explicit-hashes` fail. The target manifest excludes it
only because both configured release closures prove it unreachable; no hash
gate was weakened.
