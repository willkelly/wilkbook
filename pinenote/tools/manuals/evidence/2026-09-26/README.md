# Installed manuals acceptance — 2026-09-26

Host-only run against already-realized generation-23 outputs. Source baseline
`1f36e77`; test-source hashes and immutable input paths are in `identities.txt`.
The shelf's realized converter source matches the checkout byte-for-byte.
No fixture substitution, hardware session, SSH, deployment or image build.

- `corpus.txt`: independent profile census, all 26 book hashes, 49 explicit
  missing identities, manifest/index/NCX/source-node count reconciliation.
- `acceptance.txt`: completed run's bounded assertion output, including
  three corpus mutation controls and the real-reader wrong-book control.
- `man-index.png`: actual ReaderUI rendering of Section 1, including aliases
  and NAME summaries; its `apropos(1)` link was hit-tested, followed and
  returned from through ReaderLink.
- `info-example.png`: actual `sed` Info Overview, prose, menu links and
  monospace examples. The long command at the bottom wraps across the page
  with a display hyphen: example fidelity remains an open issue.
- `info-table.png`: actual command-line options, with bold definition terms
  and indented bodies. A long example above the table also shows wrapping.

All three PNGs are unmodified full-resolution 1404×1872 screenshots from
KOReader v2026.03's SDL framebuffer. Together they are 665,866 bytes. They
were inspected; their text/layout agrees with the test's current-page text
and nonblank pixel assertions. They are representative evidence, not golden
pixel tests or a claim that every page looks correct.

Full disposable evidence for this run is at
`/tmp/opencode/manuals-acceptance-final` (seven screenshots, three native
logs, corpus controls, fresh reader caches). `acceptance.txt` was captured
from the command documented in the tool README, using that output path.

`make manuals-check` also passed with native mandoc available: all 71
converter/staging assertions, including end-to-end conversion, and the
identical-output second run. The acceptance gate adds no Python tooling.

Interpretation: the 711-man-entry / 25-Info shelf renders and supports the
tested navigation, but omits 21 man and 28 Info identities from the final
profile. Source `sed(1)` itself is a cross-build fallback stub; the substantive
man page tested was `apropos(1)`. The matrix is not hardware, complete-corpus,
or code-example fidelity sign-off. See `doc/manuals.md` for those limits and
the distinct August 26 hardware open-time record.
