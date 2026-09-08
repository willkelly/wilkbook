# Source roster and roles

`SOURCE-MANIFEST.sha256` covers the complete launcher-successor source tree. The smaller
`RUNTIME-SOURCE-MANIFEST.sha256` is pinned by trusted `bootstrap.py` and covers
exactly the 23 files a future campaign may load or stage.

## Bootstrap and inherited runtime

- `run-two-boot.sh` and `bootstrap.py` are the explicit non-self-authenticating
  trust base. The static-Bash loader scrub is unchanged; only required retained
  manifest/helper pins change.
- `bootstrap-main.scm`, `run-two-boot.scm`, `one-boot.scm`, accepted parents,
  private typed-hook successors, graph/OFD/state/sequential/UI modules, and the
  timeout contract retain the accepted campaign shape.
- Historical files under `frozen-metadata/` remain immutable rejection/provenance
  records and are never loaded by production.

## Accepted V8/V6 core and successor deltas

- `check-evidence.py` retains each V8 finalized-capture attribution, including
  capture digest, operation ID, and resulting version, and binds it to the
  immediately preceding same-language save and boot-local A/B FSM. Its one
  successor delta corrects the actual-graph root assertion to require exactly
  one Guix-native `root=PNGuixRoot` token.
- `tests/make-synthetic-evidence.py` emits an explicitly model-only valid V8
  ordering. `tests/test-check-evidence.py` adds fully sealed balanced complete-
  pair, operation-only, version-only, and wrong-boot substitutions to the
  inherited boundary mutation matrix.
- `modules/two-boot/bundle.scm` retains the accepted exact copied
  `PAYLOAD.sha256` consumer and binds the successor image's exact generated
  size; its closed role grammar is unchanged.
- `modules/two-boot/image-binding.scm` transcribes the complete version-neutral
  88-field successor author table and pins external evidence plus one exact outer bundle
  manifest. The independent V8 review fields remain parent-only records.
- `tests/test-source-bundle-binding.scm` authenticates the actual private
  successor bundle through the production entry without spawning QEMU, rejects historical
  layouts/paths and altered bundle inputs, and preserves the closed schema and
  Guix-store hard-link boundary.
- `tests/test-reviewed-payload.py` authenticates the external successor author-image
  inputs, exact payload and label-only transformation, preserves parent-review
  scope, and retains the historical V6 `PAYLOAD.sha256` versus `STATUS.json`
  role regression.
- `tests/test-boot-bundle-append.scm` calls the production downstream parser on
  the actual immutable successor bundle and rejects duplicate/mixed root and console
  forms. `tests/test-timeout-boundary.scm` also exercises twenty fast children
  against the pre-exec identity acknowledgement.
- `tests/test-root-handoff.py` binds the immutable payload's `LABEL=` input to
  the production parser's one bare-label argv token and the checker's exact
  requirement, while inspecting the pinned Guix source semantics without
  importing ambient Guile modules.
- `RUNTIME-NOTE-20260907.md` records the preserved V8 launcher attempts, V9
  attempt 1, the exact `get-string-all` diagnosis, and three direct disposable
  V9 cycles, the native UI correction, and the clean successor image/binding.

No accepted parent review, historical packet, or external evidence is modified.
V9 changed the guest declaration only at the generic filesystem-flag seam. The
post-V9 source adds the compiled Shepherd module bindings and moves the same
exact-two startup-notice consumption before `channel-ready`; its marker remains
after first `dialog-shown`. The successor checker copy still has only the
intentional root-token correction above. Runtime claims are limited to the
author evidence and exact paths in the runtime note.
