# Finite source capsule

This directory's `run-tests.sh` is the public fresh-candidate entry point. Run
it through `sh`; frozen packet scripts may be mode `0444` and never need to be
made executable.

The trust layers are deliberately one-way:

1. `SOURCE-MANIFEST.sha256` binds every project, local-file, and check source
   except itself.
2. `CAPSULE-ROSTER.tsv` binds those same files plus the source manifest, assigns
   each one a role and read-only capsule mode, and excludes itself to avoid a
   circular checksum.
3. A frozen packet's `SOURCE-SNAPSHOT.sha256` binds the capsule roster and every
   actual private copy.

The preparer creates four directories:

- `repo`: review and check sources, all regular mode-`0444` files;
- `module-view`: only the transitive `(pinenote ...)` modules and explicit
  relative `local-file` assets needed while those modules evaluate;
- `package-view`: one non-Scheme marker, used as `-L` for both Guix layers; and
- `metadata`: the copied roster and preparation record.

No view contains a symlink or special file. Every file is an actual private
copy with a rostered SHA-256; executable bits survive only where a Guix
`local-file` directory input needs them. All directories are mode `0555`.

`pinned-guix.sh` creates a new mode-`0700` process root and enters an `env -i`
environment before its first Guix/Guile process. It clears caller HOME/XDG
caches, compiled-load variants, extensions, `GUIX_PACKAGE_PATH`, build options,
profiles, and Python injection paths by admitting only its enumerated
environment. The immutable bootstrap command may enter only `channels.scm`'s
pinned time machine. Derivation lowering and every requisites query use this
same boundary.

Requisites are queried by `query-requisites.scm` through pinned `guix repl`,
not by a caller-environment `guix gc`. This keeps the query in the same pinned
toolchain and gives the nested command the same explicit zero-Scheme `-L` view.
`check-requisites.py` then checks the exact kernel, one source-built gVisor,
and forbidden-input boundary without realizing any graph node.

The source gate does not build an image, kernel, or gVisor, and does not invoke
QEMU, runsc, ARM code, networking, mounts, devices, SSH, or hardware.
