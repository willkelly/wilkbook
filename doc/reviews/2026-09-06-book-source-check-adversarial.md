# Book Computer public source check — independent adversarial review

Date: 2026-09-06

## Disposition

**Block the exact new public source/persistence execution gate.** The candidate
export, finite source map, private capsule construction, explicit retained-v1
boundary, public component entry points, and canonical KOReader resolver are
substantial corrections to the earlier publication audit. The supplied
aggregate also passes the complete native persistence chain, including the
already accepted 22-lifecycle KOReader reader join.

The aggregate does not, however, prove that only the mapped executable source
ran. Every new Guile runner invokes `guild compile` before assigning its private
`XDG_CACHE_HOME`. `guix shell --pure` retains the caller's `HOME`, and Guile will
load an existing auto-compiled `guild.go` from that home without authenticating
its contents against the source map. I placed canary-writing bytecode at the
exact cache path for the exact pinned `guild`, then invoked that same pinned
Guix shell with all the load/package variables the runner clears. The command
returned zero and the unlisted bytecode wrote its canary.

This is a concrete exact-source failure, not a speculative same-UID race in the
candidate tree. Project module-origin checks happen only after this compiler
program has run. A successor must give the outer Guix invocation a fresh private
home/cache before any Guile program starts, add this preseeded-cache
counterexample, freeze new identities, and rerun the bounded aggregate.

This disposition does **not** reopen the accepted backend, Protocol V2, adapter,
Book Session/delegate, observer, native-v2, UI, state-text successor, or exact
reader-join v2 behavior. It rejects only the claim that these new public
entrypoints currently provide closed-source execution evidence. It makes no
QEMU, gVisor/Systrap, ARM64, kernel, image, hostile-book, durability, resource,
deployment, hardware, or release acceptance. The unrelated legacy gVisor/local
package and system publication issues remain outside this review, so this is
not a declaration that the whole Book Computer change is PR-ready.

## Frozen review boundary

I reviewed the explicit exported candidate:

```text
/tmp/opencode/book-source-final-current-candidate.IMWonc
```

Its reproduced boundary is:

| Record | Result |
|---|---:|
| regular files | 440 |
| regular-file bytes | 9,284,029 |
| symlinks or special files | 0 |
| `SOURCE-MAP.tsv` SHA-256 | `5263f32a30034efb52d421aa6e931f6c940963f962e943f54a67680be3057317` |
| `SOURCE-ROSTER.txt` SHA-256 | `8a1924dbb3b0593eae52d12a553fafbc7ca82ae2f561a04ba71b83cae281fb1b` |
| export log SHA-256 | `f463a3f36444b00d407bd4df715ffd9a64f28279219f4be219118b3b75de6532` |

The roster exactly matched the candidate's 440 files. The map contained 180
unique prepared destinations sourced from 166 canonical files: 12 backend-v2,
38 join-v2, 29 native-v2, 16 observer-v1, 14 KOReader-package, 58 ordinary
repository, and 13 UI rows. Every mapped hash matched the candidate. The eight
small historical metadata files total exactly 15,617 bytes; they are the only
material reconstructed from dedicated `frozen-source-metadata/` files.

The host candidate path itself was mode-writable and was not a read-only mount
at review time. I therefore treat the exact roster/map identities above—not its
pathname—as the frozen boundary, and exposed that path read-only in my attempted
namespace replay. The generated execution capsule is separately sealed: its 180
mapped files plus `SOURCE-ORIGINS.tsv` and `PREPARED-MANIFEST.sha256` were all
regular files at mode `0400`, with directories at `0500`. Its identities were:

```text
5611345787a2df67c0001b33e716168e161b34877a77ecb12aa583afc909ce75  PREPARED-MANIFEST.sha256
fd1ade8ae472a2ffbd20fc90bec28e7e423f2c803c25fc8b27af837aeaff55fa  SOURCE-ORIGINS.tsv
```

All 181 entries listed by the prepared manifest reverified. The manifest does
not list itself; its external identity above closes that final file.

`SOURCE-MAP.tsv`, `SOURCE-ROSTER.txt`, the initial `run.sh`, `prepare.py`, and
trusted host commands are the versioned bootstrap. The preparer maps itself and
all later helpers for private re-entry, but this is not a signature over an
untrusted repository and cannot authenticate code that already ran to perform
the preparation. Likewise, the source lane is trusted-host functional testing,
not protection against a malicious `PATH`, Guix daemon, or same-UID process.

## Source preparation and entry-point findings

The preparation layer itself is fail-closed within that stated bootstrap:

- source and destination names must be strict UTF-8 canonical relative POSIX
  paths; absolute paths and `.`/`..` traversal are rejected;
- views are a closed enumeration, destination collisions and conflicting hashes
  are rejected, and hashes must be 64 lowercase hexadecimal characters;
- the roster is sorted/unique and bounded to 1,024 files, 2 MiB per file, and
  16 MiB total;
- an exact candidate scan rejects missing, unlisted, symlink, and special-file
  entries;
- each source is opened with `O_NOFOLLOW`, checked with `fstat`, read once into
  memory, hashed, and those retained bytes—not a later pathname read—populate
  every mapped destination; and
- output must be absent or empty, writes use exclusive creation, and the final
  private tree is mode-sealed before re-entry.

The usual ancestor/check-use race remains possible against a hostile same-UID
mutator because this is pathname-based host preparation rather than an
`openat2` sandbox. I did not elevate that expected trusted-host limitation into
the disposition. A read-only candidate bind is sufficient for a controlled
review run.

The ten supplied preparer tests passed in both the supplied run and my attempted
run. Additional direct checks established that:

- deleting canonical `pinenote/tools/book-protocol/book_protocol.py` made
  preparation fail with status 1 instead of falling back to the working tree;
- appending an existing unmapped live review still produced the identical
  prepared-manifest/origins identities and did not copy that review;
- an absent explicit retained-artifact root failed `check-retained` with status
  1 and did not regenerate anything; and
- changing the prepared `process-identity.sh` made the authenticated private
  closure verifier fail before its injected canary could run.

The root `check-source` target and component `Makefile.public` targets all
require an explicit absolute `SOURCE_ROOT` and delegate to the candidate's
runner. After preparation, the candidate path is not passed to children;
dispatch re-enters through mapped copies in the capsule. The command table is
finite and separates source/unit, native functional, reader join, retained
authentication, and retained replay.

The new runners correctly address the prior project-source defects apart from
the cache blocker:

- Python runs with `-I -S`; launchers load the exact mapped Book Protocol codec
  by canonical path and verify its hash and import origin.
- Project Scheme modules compile to private caches and the native/join checks
  verify source and compiled origins. Guile book load views omit SQLite and the
  backend authority.
- `GUIX_PACKAGE_PATH`, `GUIX_BUILD_OPTIONS`, `GUIX_ENVIRONMENT`, Guile load
  variables, Python variables, and the native/session selector variables are
  cleared at their relevant boundaries. Empty `-L` views prevent ambient Guix
  package-module discovery; KOReader alone gets the positively mapped package
  view.
- Live append-only reviews are not execution inputs. The join receives only
  frozen accepted provenance copies. The absent historical observer
  `EVIDENCE.sha256` was not recreated; its literal `90362b…` attestation remains
  in the frozen review copy.
- The exact 45-path language profile is not needed by source/unit or native-v2
  checks. It appears only in the explicit retained replay and in a frozen old
  runner that the public successor authenticates but does not execute.
- Retained v1 requires an explicit external artifact root. The supplied retained
  replay authenticated that packet/profile and reproduced v1's expected missing
  Python codec block; it did not reinterpret that block as success or promote
  v1 over native-v2.

The private process helper is the accepted
`97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354`
copy. The reader owner verifies the closure, hashes that private file, sources it
once, and cleanup thereafter uses the in-memory function. I found no return to
the mutable repository helper.

## Blocker: ambient Guile auto-cache executes first

The exact pinned test shell resolved:

```text
/gnu/store/nrcsrmpih6c574dfa5qfsq6n55zb28nb-profile/bin/guild
  -> /gnu/store/aqpggy9i24nnx39d8ysxsms6zv4icnm5-guile-3.0.9/bin/guild
```

Guile's auto-cache key for that program is:

```text
$HOME/.cache/guile/ccache/3.0-LE-8-4.6/gnu/store/
  aqpggy9i24nnx39d8ysxsms6zv4icnm5-guile-3.0.9/bin/guild.go
```

In a private mount namespace I temporarily overlaid the source path only while
compiling a `(guild)` module whose embedded source filename was the exact
`nrc…-profile/bin/guild` path. Its `main` writes a canary. The resulting unlisted
cache object was:

```text
040d80996caaff0f977bdc624dac92140923c72e824780c9728b5cbac92ccafb  guild.go
```

I then removed all the Guix/Guile/Python variables the public runner removes,
set only `HOME` to the preseeded directory, and invoked the exact pinned shape:

```sh
guix time-machine -C CANDIDATE/channels.scm -- \
  shell --pure --no-grafts --max-jobs=1 --cores=2 \
  -L EMPTY -m CANDIDATE/pinenote/tools/book-source-check/source-test-manifest.scm \
  -- guild --version
```

It returned status 0, emitted no ordinary output, and created:

```text
ambient HOME ccache executed
```

The canary SHA-256 is
`04e0954778b8c9245fce1dca921749bb16a7c7378ff21ec51c1cc1921ed8411d`.
No candidate, capsule, Guix store, or accepted source was changed.

This joins directly to the public code. In every path, private cache assignment
comes after at least one `guild` invocation:

| Runner | first `guild` | private `XDG_CACHE_HOME` |
|---|---:|---:|
| `runners/core-source-units.sh` | 62 | 120 |
| `runners/backend-adapter-v2.sh` | 45 | 62 |
| `runners/completion-observer.sh` | 54 | 88 |
| `runners/native-v2-inner.sh` | 48 | 94 |
| `runners/reader-join-inner.sh` | 58 | 141 |

The supplied passing aggregate visibly did the same thing at log lines 31–35:
before any project test, Guile auto-compiled `guild` into the caller's poison
home. That cache happened to be initially empty and therefore received honest
bytecode. Preseeding it turns the same seam into unlisted execution while all
later source, ccache, and module-origin assertions still have the opportunity to
pass.

The repair should establish an empty mode-`0700` private `HOME` (and cache) in
`run-prepared.sh` before dispatch, pass it to every outer `guix time-machine`
invocation including KOReader resolution, and assign the private
`XDG_CACHE_HOME` inside each Guix shell before its first Guile command. Disabling
Guile auto-compilation at the outer boundary is useful defense in depth, but an
empty private home also excludes Guix/user configuration and stale cache inputs.
The regression must preseed the caller's exact `guild.go` key and require that
its canary remain absent.

## KOReader resolver provenance

The portable reader join no longer takes a remembered KOReader basename. The
mapped package inputs are the exact `pinenote/packages/koreader.scm` plus its 13
`koreader-device` files, under the pinned `channels.scm`:

```text
81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567  pinenote/packages/koreader.scm
661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1  channels.scm
```

`resolve-koreader.sh` evaluates and realizes only that positive package view
with `--no-grafts --max-jobs=1 --cores=2`. It first performs a dry run, refuses
more than 25 proposed derivations, rejects PineNote kernels, gVisor, QEMU,
systems, and disk-image names, then checks the realized `v2026.03` output and
asks the store for its deriver. In the supplied run the dry run named only the
already realized output; `build.log` was empty and no package build, image,
kernel, QEMU, gVisor, ARM, or hardware action occurred.

The newly resolved identity is:

```text
/gnu/store/klwcc796q3pyi3m72vg47m60yyhhbfc5-koreader-bin-2026.03.drv
/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03
```

This is a legitimate derivation from the mapped package, but it is **not**
byte-identical to the KOReader runtime accepted by the old UI/reader-join
reviews. The relationship is unusually clear: old
`amd75p0f…-koreader-bin-2026.03.drv` declares
`((type . graft) (graft (count . 2)))` and directly takes the new `klwcc796…drv`
as its base input. Its old `s48x0n…` output replaces the base Wayland and
libxkbcommon references with two grafted outputs. The recursive hashes differ:

```text
1cpcs4zxdqj51v3nlsx6rxaak049i6qmq75pm17kw7bvhr5v250m  p9wk… (current ungrafted base)
1zp7gqcc6p6kg04090vw9hjh0pkw07skvfs3zajpwa8z5hb4fx5f  s48x… (old two-graft output)
```

The supplied 22-lifecycle native reader join did execute the current `p9wk…`
output successfully. That supports functional continuity for this public
successor; it does not extend the old hash-specific runtime acceptance or permit
a byte-identity claim.

## Supplied execution and reviewer attempt

I authenticated the supplied aggregate log as:

```text
8389efafc2f1ef2f933737c315d34bc586a6d0a018e6735a3e737ecd78dae50e  /tmp/opencode/book-source-final-current-check.PiyG8E.log
```

It reported:

| Stage | Seconds | Result |
|---|---:|---|
| source units | 18 | PASS |
| backend adapter | 7 | PASS |
| completion observer | 24 | PASS |
| native-v2 | 14 | PASS |
| KOReader prepare | 2 | PASS |
| reader join v2 | 46 | PASS |

Within the already frozen joins, it reproduced the accepted protocol/session/
backend/adapter/observer/native regressions, private Python and Scheme origins,
state-text patch equality, eight join source mutations, helper provenance, 22
fresh authority/book/KOReader lifecycles, persistent versions `1 → 2 → 3`,
present-empty save/reopen, exact 4 KiB text, retry idempotence, delayed-edit and
forged/mismatched rejection, SQLite integrity, and process cleanup. I did not
re-audit those accepted internals. Because of the cache counterexample, this log
is trusted-host functional evidence rather than closed-source execution
evidence.

I invoked the aggregate once independently with the candidate read-only and old
working/artifact/profile/KOReader paths masked in a private namespace. It
authenticated the candidate, generated the exact same capsule identities, and
passed all ten preparer tests. My namespace had also made all of `/var`
read-only, however, so `guix time-machine` stopped before source-unit execution
when a cache/profile timestamp update received `EROFS`:

```text
2765698fff5da9f403b8a8b21e907ad34c62ba0b400c625897d2d96b3ef30f37  aggregate.log
aggregate status: 2
```

That is reviewer setup failure, not a functional candidate failure. I did not
consume a second aggregate invocation. The passing functional record above is
therefore the supplied record, not an independent replay claim.

Reviewer-owned source, KOReader, negative-test, failed-attempt, and cache
counterexample records are retained at:

```text
/tmp/opencode/book-source-check-independent-review-20260906/
0947ec24a4c6e1b357f075b62c96dd26c02465ca472a0e98a6f178d1187fa235  EVIDENCE.sha256
```

No implementation, accepted packet, prerequisite, unrelated active work,
staging area, commit, branch, remote, or device was changed by this review.

## Successor v2 recheck — scoped acceptance

**Accept the successor v2 candidate for the finite public source/persistence
lane.** This supersedes the blocking disposition above only for the exact v2
identities recorded here. It does not alter the finding against the 440-file
`IMWonc` candidate: the original `guild.go` counterexample remains valid, and
the first 330 lines of this review remain byte-for-byte the record of that
block (`7739e982cebdaeea60c3924e4c7f973e4e183069dfda1560d6a2c9b93277e2e8`).

The accepted successor boundary is:

```text
/tmp/opencode/book-source-v2-candidate.4VthNc
b2b68cfcc0d060a10056dd91b956abbe7bdc0feeb130b183bbd60b2e50ec43a4  SOURCE-MAP.tsv
a18022c36d260960b636a82af4ebd65adbeeab0ebda98336ceabb5fc6161d496  SOURCE-ROSTER.txt
f7ee9f18ea74885fdb57af8f9503e4839c6bd440d79259ca945cb6c5aa4be837  PREPARED-MANIFEST.sha256
59103a59a20b95bf4c21a361aa90b13040cc75ca58052e9761eef042d522cb51  SOURCE-ORIGINS.tsv
```

I reproduced 442 regular files and 9,306,841 bytes, with no writable file or
directory, symlink, special file, forbidden generated/cache artifact, or roster
discrepancy. All 442 candidate hashes passed. The source map has 182 prepared
destinations from 168 canonical files; every mapped hash passed. The supplied
capsule has 182 mapped files plus `SOURCE-ORIGINS.tsv`; all 183 entries in its
manifest reverified, with files at mode `0400`, directories at `0500`, and no
symlink or special file.

### The startup-cache blocker is closed

The mapped delta from `IMWonc` is confined to the source-check command table,
the new shared private-environment helper and cache regression, and the public
dispatch/Guix runners that apply that helper. No accepted Protocol, operation
ID, backend, adapter, Book Session/delegate, observer, UI, native-v2,
state-text, or reader-join functional source hash changed.

`run.sh` still performs the reviewed isolated-Python preparation bootstrap
first. It then sources the authenticated helper from the sealed capsule,
resolves `guix` without executing it, and creates a fresh mode-`0700` private
environment before the first Guix/Guile/Guild process. `run-prepared.sh`
creates a separate dispatcher environment. Every component runner creates or
re-enters its own private environment before its outer `guix time-machine` and
again before early Guile, `guild --version`, compilation, or module queries.
The boundary replaces caller values for `HOME`, all relevant XDG directories,
Guile load/compiled/extension paths and compiler controls, Guix package/config
paths, and Python code paths. `--pure` therefore retains the new private home,
not the caller's home. The Guix-shell package paths are accepted only as
existing `/gnu/store` directories; project bytecode precedes them only from the
fresh private project ccache.

This coverage includes source units, adapter, observer, native-v2, all four
KOReader resolution/query operations, reader join, and the explicit retained
replay. Retained authentication runs no Guix or Guile. Before the historical
v1 runner starts, its wrapper has already established the private home/cache;
the frozen runner's early `guild` and later direct `guix gc`/`guix hash`
therefore inherit that boundary even though the immutable historical script is
not rewritten.

The reviewed host selected:

```text
/gnu/store/07imsdnmnf8yjid83rsccmlbs2h30wqa-guix-command
97e13089e1003f10673888d02bf2868972005f1fbec55f06fdaa2dfdfe89f014  guix-command
```

It is a canonical executable regular file in `/gnu/store`; its script embeds
its Guile wrapper and compiled store module paths. Resolving the selected link
uses only `command -v` and `readlink -f`, so this trusted bootstrap code is not
executed until after private `HOME`/XDG/load roots exist. The path is discovered
and logged rather than accepted from a caller-provided expected hash. This is
still the review's declared trusted-host bootstrap, not protection against a
malicious host, daemon, `PATH`, or same-UID process.

The supplied aggregate's private user caches contain seven generated `.go`
files, all Guix compilations of mapped manifest sources under the fresh private
XDG roots. Those are expected private compiler products. No private environment
contains `guild.go`; disabling auto-compilation is not being mistaken for the
security boundary.

I independently ran the public `protocol` entrypoint from the frozen candidate
with poisoned caller HOME, XDG, Guile, Guix, and Python path variables. Its
automatic regression constructed executable bytecode at both exact Guile 3.0.9
cache routes:

```text
$HOME/.cache/guile/ccache/3.0-LE-8-4.6/gnu/store/aqpggy9i24nnx39d8ysxsms6zv4icnm5-guile-3.0.9/bin/guild.go
$XDG_CACHE_HOME/guile/ccache/3.0-LE-8-4.6/gnu/store/aqpggy9i24nnx39d8ysxsms6zv4icnm5-guile-3.0.9/bin/guild.go
```

The two generated objects necessarily have new byte identities because the
regression embeds per-run label/canary pathnames; they target the same exact
program and cache key as the original `040d8099…` object. As positive controls,
direct invocation through the genuine
`nrcsrmpih6c574dfa5qfsq6n55zb28nb-profile/bin/guild` loaded each object,
returned zero, and wrote its canary. In the repaired default-HOME and explicit-
XDG pipelines, both canaries were absent after the legitimate Protocol pipeline
passed and authenticated `book-protocol.scm` from the capsule. Thus this is the
same executable early-cache counterexample, not an inert or malformed poison,
and the check rejects execution at the seam rather than relying on a later
module-origin assertion.

The independent narrow record is:

```text
7c2e78b732b5f8525a77d5e22c12c1b7d7ab6e49fc4c866103999f635f4debe4  book-source-v2-independent-cache-recheck.6vVcb8.log
175b662e36825f6d70ec42f47e04b816d7728c7a1c5c982c080fa164147a3941  default-HOME guild.go
0aceab45cd2962e9dd31993ab137ffe84d401c95b39f4644d125f54346adbbfd  explicit-XDG guild.go
```

### Authenticated aggregate and retained evidence

The supplied evidence manifest and principal records authenticate as:

```text
efdc6ab1ecd13fdcc292835ede3359bb04f68c5b2ad5fe2f76de9bdc742d776e  EVIDENCE.sha256
bd5ced995c4b4017843c6d75fa9127cf79ef6e486356d81545bdbe665ae12f28  book-source-v2-final-check.mdaXNF.log
e700f667e1c8335dfd579998ce70434e9cceed91c30fc26cf065162c221c81e4  book-source-v2-cache-regression.mWCCr9.log
498a092c3c7ea4770477ceb5cdf4dae7d8a8c160fd363d1f21751d407085cfcf  book-source-v2-retained-replay.fnMrin.log
```

All ten preparer mutations and both cache routes passed. The sealed aggregate
then passed source units, adapter, observer, native-v2, KOReader preparation,
and reader-join v2 in 18/7/17/13/2/37 seconds. Its execution log names no old
working checkout, `IMWonc`/`48X1UB` capsule, retained packet/profile, or old
KOReader path. The supplied namespace record says those paths were masked. The
aggregate retained the accepted 22 lifecycles, 66 fresh process identities,
present-empty and exact-4-KiB behavior, retry idempotence, origin checks,
SQLite integrity, cleanup, and the other already reviewed join results. I did
not repeat the deep functional/FSM audit because those source hashes did not
change.

The retained-v1 replay remains explicit and separate: authentication passed,
the exact 45-path profile passed, the immutable historical runner reproduced
the expected missing-`book_protocol` rejection, and a missing retained root was
rejected. The absent observer `EVIDENCE.sha256` was not recreated; its literal
`90362b…` attestation remains only in frozen provenance.

KOReader resolved, with `--no-grafts`, to the same current identities recorded
above: `klwcc796…drv` and `p9wkidd…` output. `p9wk…` is the ungrafted base input
of the old two-graft `amd75…drv`/`s48x…` output. The successful current native
join proves functional continuity for this source lane only; their recursive
hashes differ, and this acceptance does not claim byte identity with or extend
the old hash-specific KOReader runtime acceptance.

### Scope ceiling

This closes only the public source/persistence startup-cache blocker for the
exact v2 candidate. It does not accept or reopen QEMU, runsc/gVisor/Systrap,
ARM64, guest/outer joining, kernel, image, hostile-book isolation, output
import, resources, physical durability, deployment, hardware, release, BSG3,
or the separate legacy BEP1/direct-`gc` publication lane. Global PR readiness
remains unresolved. No QEMU, runsc, ARM, package/kernel/image build, device,
network, staging, commit, or repository implementation action was performed in
this recheck.
