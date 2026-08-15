# Cutting a release

Alpha is cut by a person signing `doc/alpha-signoff.md`. This page is the
mechanical half: what an artifact *is*, and what a second person needs to
be able to check.

## The claim we can make, and the one we can't

We do not host binaries. What we publish is a **commit, a channel pin, and
a hash** — and from those, anyone with Guix rebuilds the identical rootfs:

```sh
git clone <repo> && cd wilkbook && git checkout <tag>
guix time-machine -C channels.scm -- \
  system image -t raw-with-offset -L . --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-reader.scm
```

`channels.scm` pins Guix itself plus every extra channel by commit, with
channel introductions. That is the whole reproducibility claim, and it is
the one thing a rolling binary distribution structurally cannot offer:
hrdl's Arch images are built against moving mirrors with a `-git` kernel
whose `sha256sums=('SKIP')`, so "the same tarball" is not reconstructible
after the fact. Ours is.

The claim we cannot make is that our image is *tested*. It is hardly
tested. `README.md` says so at the top and means it.

## Procedure

1. **Land everything offline first.** `make check-host` (which includes
   `library-check` and `suspend-check`), then `make qemu-virt-check` and
   `make qemu-data-check` on all three fixtures — the last against a
   genuinely fresh clone, since that is the build a second person makes.
2. **Pin the channels**: `make channels-pin`, and commit `channels.scm`.
   Do this *before* building the artifact you intend to ship, or the pin
   describes a different tree than the one you built.
3. **Build the artifact**: `make rootfs-reader TIME_MACHINE=1`. The flag
   is not optional here — it is what routes the build through
   `channels.scm`, and without it this step builds against your ambient
   `guix` and quietly forfeits the byte-identical-rebuild claim made
   three paragraphs above.
4. **Write the manifest**: `make release-manifest ROOTFS=<the .ext4>`,
   which writes `SHA256SUMS` carrying the hash, the git description, and a
   pointer to `channels.scm`. Commit it.
5. **Run the human QC cycle** (`doc/alpha-signoff.md`) on that exact
   artifact. Not a rebuild of it — that one.
6. **Tag, annotated**, naming the image hash in the tag message:
   `git tag -a v0.1.0-alpha -m "..."`. The hash then lives inside signed
   history rather than beside a download.
7. **Commit the signed-off record** from `doc/alpha-signoff.md` §4 and
   add the `doc/status.md` entry.

## What we deliberately do not do

- **No hosted binary.** The audience builds from source
  (`doc/alpha-checklist.md`). Publishing a 1.9 GB image invites people who
  should not be running this to run it.
- **No update mechanism.** A new version is a reflash. `guix-service-type`
  is filtered out of release flavors on purpose.
- **No detached signatures yet.** They would only matter with a hosted
  binary. If that ever changes, the missing piece is a *"Verify what you
  downloaded"* section in `doc/install.md` carrying the full fingerprint
  and a literal `gpg --verify` invocation — the step the reference project
  omits, which makes their verification story unexecutable.

## The state of the practice we are measuring against

For calibration, from the 2026-08-07 survey of hrdl's `pinenote-dist`:
zero git tags across 66 commits and 14 months, a mutable artifact URL
(yesterday's build is unobtainable), no published SHA-256 for any
artifact, and no `gpg --verify` invocation anywhere in the README — the
key fingerprint appears only inside the pacman-repo setup step.

That is not a criticism of a project doing far more than us on the parts
that matter; it is a measurement of how low the bar is. One tag, one
committed channel pin, and one committed hash clears it, and costs an
afternoon.
