# Full-console extractor EX-1 fix — 2026-09-06

## Disposition

EX-1 has a narrow offline parser correction and is frozen for independent
recheck. This record implements the finding appended to
`2026-09-06-book-protocol-successor-image-adversarial.md`, exact SHA-256
`d42bb1041cf99280d9f0a95ab94590ec1da44a495f94827f57703a86929c6627`.

This is ancillary evidence-extractor correctness. It is not a reason to rerun
or block an otherwise accepted reader-image join. It does not change the
historical command result: that invocation remains exactly
`RUN-STATUS=1 CHECKER-STATUS=1`, with no outer success line. The immutable
console's already accepted Guile/Python exchanges and cleanup evidence are not
relabelled as an original command pass.

## Correction

`extract_full_qemu_console.py` continues to use its existing bounded read,
physical-line parser, canonical one-pass decoder, exact re-encoder, and
exclusive mode-0400 output creation. One small classifier now recognizes an
unprefixed accepted-outer control prefix for `BEGIN`, `END`, or `INCOMPLETE`
with `label=console.log`. After locating the one exact stable frame, the parser
allows only that frame's exact begin/end pair and rejects every other such
console control line.

This closes both the exact contradiction and nearby malformed variants without
turning the extractor into a new framing framework:

- the exact accepted-outer `state=changed exported-bytes=25120` record after a
  stable END is rejected;
- duplicate exact BEGIN/END and exact INCOMPLETE records before or after the
  frame are rejected;
- a malformed extra BEGIN (`source-bytes=03`) and malformed extra END
  (`retention=partial`) are rejected before and after; and
- exact framing text inside encoded console bytes remains valid because each
  rendered payload line starts with the inherited `| ` prefix. Complete
  `qemu.stderr` diagnostic frames also remain valid because their label is not
  `console.log`.

The accepted outer/emitter source remains unchanged at SHA-256
`0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`.
No guest, reader, coordinator, outer, checker, protocol/session, system, or
graph source was edited.

## Offline results

The focused packet ran 11 extractor tests successfully. Existing all-byte,
single-unescape, canonical-escape, declared-bound, prefix, byte-count,
duplicate/missing-frame, mode/link, and overwrite tests remain green. The new
tests add the exact EX-1 retained-evidence mutation, the before/after malformed
and duplicate control matrix, and the two positive boundaries above.

The exact reviewer counterexample was rebuilt by inserting only the 109-byte
INCOMPLETE line after the immutable evidence's stable END. The CLI returned
status 1 with `EvidenceDecodeError` and did not create the requested output.

The corrected extractor then decoded the unchanged mode-0400 retained evidence
(SHA-256 `5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378`)
to exactly 25,120 bytes. The new mode-0400, single-link output was byte-identical
to the committed raw console and retained SHA-256
`171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3`.
The independently accepted checker at SHA-256
`4a8e9e554d98ba8f22d16dec36578bbd727853dbcca3ffa5ddb50a02b4ca6f43`
and the unchanged clean-power-down bridge both passed that recovered console.
The checker's seven existing focused tests also passed.

## Frozen source and delta

| Item | Before SHA-256 | After SHA-256 |
|---|---|---|
| `extract_full_qemu_console.py` | `af6cb638025756e308414add83c66e2c260e4aada4aa8650b65d89843688ac44` | `5e7aeca0d9add0a130fd87d58eb047cbfcb47dc0d78cc3aeb09d9087d570a183` |
| `test_book_full_qemu_console.py` | `bdebe2b0a6cf099c44d29c7b508c348f5b689862e41b5399e06dc4c6acafbef9` | `bd9ea882cf6ae3cc6dbce3effedfab5d662bf1f1591e8b51202ff19a08bc61c2` |

Combined old-vs-new delta SHA-256:
`8a431008a97a854f24fb65477fd3631f1a75263b59e095da5cb1832ddb5408fb`.

New relevant-subset build review packet:

```text
pinenote/tools/book-execution-spike/build/protocol-control-extractor-ex1-fix-review-packet-v1.txt
SHA-256 af05d9f802b617b03b7e47cf670f71a58e32c8cae864ff60d5f968afa5f22070
mode 0400
```

Its 11 machine-gated paths bind the extractor/tests, frozen checker and checker
fixture, checker entry/bridge, accepted outer emitter, immutable retained/raw
evidence and historical wrapper, and the old 49-path manifest itself. It does
not reassert the old manifest's stale all-path claim. The two concurrently
mutable documents and the append-only adversarial review are explicitly
excluded from machine path gates instead of being repeatedly repinned:

- `doc/book-computer-implementation.md`;
- `pinenote/tools/book-execution-spike/protocol-guest/README.md`; and
- `doc/reviews/2026-09-06-book-protocol-successor-image-adversarial.md`.

The old mode-0400 49-path manifest remains untouched historical evidence at
SHA-256 `7cc2b57e7e67cde135b18b275970823a6124b8908c6a207aa6ae48d758629ddd`.

## Independent recheck packet

Private mode-0700 packet:

```text
/tmp/opencode/book-extractor-ex1-fix.10KAct
```

| Evidence | SHA-256 |
|---|---|
| `packet-manifest.json` | `c87da4c6c68e773baafdb99c11f813d9505e1e99f95eade030a19b5c046f9848` |
| `source-hashes.txt` | `2ae8c76711d169fd52796f03702c28a1040cdcd6643b27e3a5e3a5dc62aa3def` |
| `extractor-ex1-old-vs-new.diff` | `8a431008a97a854f24fb65477fd3631f1a75263b59e095da5cb1832ddb5408fb` |
| `focused-ex1-test.log` | `e1f1c9226a915d381ee0044a1f7b3c9000095ae65e736e1dc3987ce06e084f14` |
| `reviewer-ex1-counterexample.log` | `6cac1f6d8a466ca3f211e09158cb11e54523e154868d4b568112eb95874af512` |
| `reviewer-ex1-negative.stderr` | `5a8646ae333899698534aa30ed0d1354fb5f8c37bba04385bf2f695a4f3e99f7` |
| `reviewer-ex1-negative.status` | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `run-focused-ex1-check.sh` | `ebcb8b19b365b7bc6ace0544eb3f87bbe1c0fe4c97c8bebee2bea47972b8971f` |

The finite independent replay is:

```sh
/tmp/opencode/book-extractor-ex1-fix.10KAct/run-focused-ex1-check.sh \
  /tmp/opencode/wilkbook-book-computer \
  /tmp/opencode/book-extractor-ex1-fix.10KAct
```

This run uses only host Python and Guile. No QEMU, runsc, ARM execution, image
or kernel build, hardware, SSH, UART, network, deployment, staging, commit, or
push occurred.
