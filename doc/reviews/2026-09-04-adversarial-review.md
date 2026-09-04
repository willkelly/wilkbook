# Adversarial review of `prealpha-candidate` (2026-09-04) — findings and dispositions

A stronger-model subagent was pointed at the candidate for
`v0.3.0-prealpha` (main plus PRs #66, #70, #67, #69) with the brief
"find what would embarrass this tag" and read-only access to the tree,
the store's kernel source, and the Guix build logs. Its findings, ranked,
with what was done about each before anything reached the device.

## Blockers

**B1 — patch 14's EXTRACT_FBS rewrite was a dangling `else`, five
times.** The first version converted `res |= copy_to_user(...)` into an
unbraced `if (copy_to_user(...)) res = -EFAULT;` inside an unbraced
`if (access_ok(...))`, and the pre-existing `else res = -EFAULT;` bound
to the inner `if`: a successful extraction returned `-EFAULT`, a bad
pointer returned 0. The build log of the derivation the docs had called
"compiled clean" carried five `-Wdangling-else` warnings; the exit
status had been read, not the log. **Fixed**: every branch braced, the
patch regenerated (`linux-pinenote-7.1-direct-correctness.patch`), and
the rule is now that a kernel build's log is grepped for warnings in
the files a patch touches before "compiled" is written anywhere.

**B2 — "no cable, no power button" overclaimed the self-reset.** The
watchdog reset is proven; what boots afterwards is U-Boot's default,
os1, unless something answers the menu. **Fixed in wording**
(CHANGELOG, CLAUDE.md): self-reset yes, hands-off return to the reader
only with the UART attached and `WILKBOOK_UART` set.

## Should-fix

**S3 — the resume-time memory repair overrode the user's explicit
Wi-Fi off.** `wifi.state` said `on` after any `off` that killed a
validated supplicant, the user's menu choice included, so the next wake
re-asserted `wifi_was_on` and the radio came back against the user's
wish, forever. **Fixed**: the device layer wraps KOReader's
`disableWifi`/`enableWifi` to record the interactive flag as a marker in
`/run/wilkbook-power/wifi.user-off`; `restoreWifiMemory` leaves the
radio alone while it exists; the marker clears when the user turns
Wi-Fi on and does not survive a reboot (where the service brings the
radio up regardless). Pinned in `test-driver.lua`.

**S4 — the deployer armed its UART watcher after the five-minute ssh
wait**, by which time U-Boot's 15 s menu was long gone. **Fixed**: with
`WILKBOOK_UART` set the watcher starts before the kexec and the
recovery path waits on it; pinned in `test-static.sh`.

**S5 — pruning keeps the newest generations, which are the least
proven.** Mitigated, not fixed: the deployer's default `KEEP` is 5, and
the standing rule (alpha-checklist) is to keep a cold-booted generation
in the window by hand. A `pin` for the ledger is the real fix, not in
this tag.

**S6 — the tester brief was a month stale.** **Fixed**: 15-minute idle
timer, no auto-sleep on the charger, `enabled=0` silencing the button
and cover, the Wi-Fi toggle, the frontlight, rotations flashing, the
battery table marked as measured on the v0.1.0 image.

## Notes, and what was done

- N7 `on`'s "already on" exit skips the association watcher when a
  supplicant survived the resume: noted, unchanged (the broker and
  KOReader both take the radio down before their sleeps).
- N8 the device-tree notice compared against DEFAULT's DTB, silent when
  DEFAULT itself was kexec'd: **fixed** — it compares against the booted
  generation's DTB and adds a second note whenever the running kernel
  was itself kexec'd.
- N9 the dither correction is a visible change no panel has run: the
  operator half of the session looks at it first.
- N10 `WARN_ON_ONCE` then an untimed wait if `queue_work` ever returned
  false: unreachable by the API contract for a fresh on-stack item (the
  reviewer found no reuse path either); kept, noted in the patch header.
- N11 the watcher pidfile could name a recycled pid and was never
  removed: **fixed** — `assoc-watch` removes it on exit, `off` signals
  only a pid whose command line is ours.
- N12 the rect-hints pin greps a line patch 14 replaces: true, harmless
  (it greps the earlier patch's text), recorded as the audit's own
  complaint about text pins.
- N13/N14 wording: the rebind never fired on glass, the KOReader-initiated
  path has four samples, the audit's item 2 is unfixed and is now in
  the CHANGELOG's known-open list, and a tester-facing entry for patch
  14 exists.

## Claims the reviewer confirmed held

The dither `+16` is arithmetically right and all three copies are
covered; `num_rects == 0` stays safe; the batch and count types are
sound and the zero-batch spin is closed; no on-stack work reuse; patch
13 is inert everywhere suspected and the ultra-coupling pin passes with
it; the 65-cycle rig did run with patch 13 live; the ioctl roster pin
still passes; the OFF_SCREEN half of the `-EFAULT` rewrite was correct
from the start.
