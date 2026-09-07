# Book Computer source check

This is the public source/unit successor lane.  It prepares an exact private,
read-only source capsule from an explicit candidate tree and then runs the
finite persistence chain without reading any `build/` directory, old log,
database, image, cached profile, mutable review, or remembered store basename.

The near-9 MiB public candidate is closed by `SOURCE-ROSTER.txt`.
`SOURCE-MAP.tsv` is the narrower execution boundary: it maps each canonical
executable input to one or more prepared paths and pins its SHA-256.  Mutable
review prose can be exported for publication but is not copied into the
execution capsule.  Missing, changed, unlisted, symlink, and special-file
inputs fail before a capsule is executed.  The preparer and every execution
helper are themselves mapped inputs.  `frozen-source-metadata/` contains only
the 15,617 bytes that cannot be reconstructed exactly from canonical non-build
source.

Create a fresh candidate from a working publication tree, then check that fresh
tree explicitly:

```sh
mkdir -m 700 /tmp/opencode/book-candidate
make -C pinenote/tools/book-source-check export-candidate \
  SOURCE_ROOT="$PWD" OUTPUT=/tmp/opencode/book-candidate
make check-source SOURCE_ROOT=/tmp/opencode/book-candidate
```

`check` runs source/backend, Book Protocol, ordinary Book Session, typed state
protocol, backend adapter, completion observer, native-v2, and the real native
KOReader reader-join v2 test.  KOReader is evaluated and realized as
`koreader-bin` through `channels.scm` and a narrow, positively pinned package
view; the resolved derivation and output are logged and cross-checked.  It is a
fixed upstream binary package.  Native-v2 is trusted-host functional evidence,
not a sandbox-isolation claim.

Individual public successor targets are available with, for example,
`make -f Makefile.public check SOURCE_ROOT=/absolute/fresh-candidate` in each
owned component directory.  All require an explicit `SOURCE_ROOT`.

Historical v1/runtime evidence is not an input to source checks.  Authenticate
it separately with `make check-retained ARTIFACT_ROOT=/absolute/root`; missing
external artifacts fail and are never regenerated.  An actual replay of the
immutable v1 runner is a second, explicit command:

```sh
make -C pinenote/tools/book-source-check replay-retained \
  SOURCE_ROOT=/absolute/fresh-candidate \
  ARTIFACT_ROOT=/absolute/authenticated-root
```

The replay stages a private read-only historical layout, retains v1's own
checks (including the exact 45-path language profile), and requires the frozen
v1 adversarial review alongside the packet and host log.  Its successful result
is reproduction of v1's expected missing-codec block, not promotion over the
native-v2 successor.
