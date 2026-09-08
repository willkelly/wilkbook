# Book interaction reader/UI adversarial review — 2026-09-04

Disposition for the final reviewed snapshot: **the first trusted-native
vertical integration gate is not accepted.** The previously accepted
`book-reader` gate is unchanged; I did not repeat its fifteen mutations. BIR-2,
BIR-3, and BIR-5 remain open. BIR-1 and BIR-4 were concrete failures in the
initial snapshot and were fixed in the active tree during this review; fresh
independent rechecks close both below.

The most important distinction is scope: none of these findings is evidence of
a shipping reader bug. `book-interaction` is explicitly a host-only trusted
fixture, not the production Guile Book runtime, broker, plugin, sandbox,
durability path, ARM64 service, or hardware UI. The failures invalidate this
new integration evidence only.

## Findings

### BIR-1 — High — Closed in final snapshot: `PrivateChannel` was blocking

`private_channel.lua:153-156` calls variadic `fcntl` through LuaJIT FFI:

```lua
C.fcntl(options.fd, F_SETFL, bit.bor(flags, O_NONBLOCK))
```

A plain Lua number is passed through a C varargs boundary as a `double`, not as
the `int` that `fcntl(F_SETFL)` expects. With the actual packaged KOReader
LuaJIT, construction returned success but a second `F_GETFL` returned `2`, not
`2050`; `O_NONBLOCK` was absent.

An independent AF_UNIX socketpair probe held the peer open with no input and
called `waitEvent()` once. Expected: return promptly with no event. Actual: it
remained inside `read(2)` until the reviewer killed it at 2 seconds:

```text
=== empty-nonblocking rc=124 elapsed_ms=2000.708 ===
FD_FLAGS_AFTER_NEW=2
```

As a counterfactual only in a disposable copy, changing the argument to
`ffi.new("int", bit.bor(flags, O_NONBLOCK))` produced:

```text
=== empty-nonblocking rc=0 elapsed_ms=1.271 ===
FD_FLAGS_AFTER_NEW=2050
RECEIVES=0
ERRORS=0
```

This is not merely a pure-probe artifact. Wrapping the real registered source's
`waitEvent()` with KOReader's monotonic clock showed the reader blocked over
the fixture books' real 350 ms delays:

```text
Guile:  355.000 ms, 355.000 ms
Python: 354.000 ms, 356.000 ms
```

The scheduled `ui-tick` runs before those reads. It therefore does not prove
that the KOReader input loop remains responsive while a response is pending.
The same bad descriptor mode also means `_pump_output()` can block before its
byte/frame budgets can help.

Required closure: pass an explicitly typed integer to the variadic call,
re-read and assert the resulting flags, and add empty-read plus saturated-write
tests using the packaged LuaJIT. The delayed integration test must prove a UI
task runs *during* the peer delay, not just immediately before the blocking
poll.

**Final-snapshot disposition: closed.** `private_channel.lua` now casts the
third argument to C `int`, re-reads the flags, and requires `O_NONBLOCK`.
`test-private-channel.lua` exercises an empty read and a never-read peer under a
five-second watchdog. My original independent socketpair driver, pointed at the
new file, observed `FD_FLAGS_AFTER_NEW=2050`; the empty poll returned in 0.637
ms, malformed/boundary cases retained their behavior, and a full delayed run
had zero `waitEvent` calls at or above 50 ms for both languages.

### BIR-2 — High — the dialog is covered by “Saving failed.” and its content is never painted

`main.lua:_submit()` returns only `false`. In pinned KOReader v2026.03,
`InputDialog` interprets `(false, nil)` as rejection with a default message and
calls `UIManager:show(InfoMessage{ text = "Saving failed." })`. Suppressing that
message requires the second return value to be `false`.

Independent instrumentation retained the real dialog reference, inspected the
actual KOReader window stack at every claimed live UI tick, and wrapped the
dialog's real `paintTo` method. Both language runs reported:

```text
INDEPENDENT_UI_TICK:update:dialog-shown=true:dialog-top=false:top-text=Saving failed.
INDEPENDENT_UI_TICK:navigation:dialog-shown=true:dialog-top=false:top-text=Saving failed.
INDEPENDENT_UI_TICK:close:dialog-shown=true:dialog-top=false:top-text=Saving failed.
```

There were **zero** `InputDialog:paintTo` observations in either run. The
current check only asks whether the underlying dialog is somewhere in
`UIManager._window_stack` and whether its backing text changed. It does not
show that the dialog is active, visible, or painted. A realistic stronger
postcondition requiring the dialog to be topmost turned the gate red with:

```text
BOOK_INTERACTION_READER: FAIL:InputDialog was not topmost while awaiting the book
```

This also invalidates `present-applied-to-dialog` as displayed feedback. The
book result is assigned to a backing widget and acknowledged to the host in the
same callback; there is no proven repaint before the next input overwrites it.
This review still makes no physical-display or display-settled claim—the needed
proof is only a real offscreen KOReader paint while the intended dialog is the
active widget.

Required closure: use the intended no-message pending return, assert the real
dialog is topmost during the delayed phases, retain the book result through a
KOReader repaint/tick, and independently observe a paint containing the exact
result before navigation starts.

### BIR-3 — Medium — source, FD, and widget teardown happen, but the gate does not pin them

The unmodified implementation's independently instrumented cleanup had the
right state before `UIManager:quit`:

```text
INDEPENDENT_CLEANUP:source-found=false:channel-closed=true:dialog-shown=false
```

However, the gate has no retained-reference or registry postconditions. Three
fresh realistic omissions all returned rc 0 and the final vertical-fixture
PASS:

| Mutation | Expected | Actual |
|---|---|---|
| omit `UIManager:close(self.dialog)` | fail: dialog still shown before quit | rc 0 / PASS |
| omit `UIManager:removeZMQ(self.channel)` | fail: source remains registered | rc 0 / PASS |
| omit `self.channel:stop()` | fail: channel/FD remains open | rc 0 / PASS |

`UIManager:quit` clearing global stacks or process exit closing an FD is not
proof that the fixture followed the claimed lifecycle. There is likewise no
post-close callback check.

Required closure: retain the exact dialog and channel; independently count the
public insert/remove calls; check the actual source registry, `closed` state,
and `not UIManager:isWidgetShown(dialog)` after cleanup but before quit; then
poll once more and prove no callback. Add the three omissions above as controls.

### BIR-4 — Medium — Closed in final snapshot: the untouched runner failed in a fresh copy

The 16 private-control assertions passed, but the untouched integration runner
failed before it could record either child:

```text
untouched_baseline_rc=1
In procedure canonicalize-path: Wrong type argument ...: #f
FAIL: cleanup regression host exited before recording both children
```

`integration-host.scm:16-17` initializes a top-level binding from
`(current-filename)`. In the fresh `guile --no-auto-compile` execution used by
the runner, that expression evaluated to `#f`. The test can appear to work when
an old compiled cache has captured a filename, but the promised disposable
fresh-copy path cannot rely on such a cache.

To continue the reader-side investigation, I made one labeled reviewer-only
override in another copy: `fixture-tool-dir` was set to that copy's absolute
tool directory. With no other behavior change, package-pinned v2026.03, Guile
3.0.11, and Python 3.12.12 completed both language runs.

Required closure: have `run-tests.sh` pass the already known canonical tool
directory explicitly rather than deriving it from dynamic compiler state, and
make a fresh-copy run part of the gate.

**Final-snapshot disposition: closed.** `integration-host.scm` now derives its
directory from the script pathname in `(car (command-line))`, not
`current-filename`. A new untouched isolated copy completed the exact-runtime
channel regression, cleanup and recorder controls, and both Guile and Python
interactions with rc 0.

### BIR-5 — Medium — exact book-result forwarding has a hardcoded false-positive path

Current source inspection is positive: both real fixture peers derive `Book
result: ADA`, the Guile authority commits a `<presented-text>`, and
`handle-presented!` passes `presented-text-value` to the private channel. Both
language runs reached the expected path.

The gate nevertheless also passed when that forwarding expression was replaced
with the host literal `"Book result: ADA"`. The UI has the same literal as its
expected value, so the run cannot distinguish forwarding the committed book
result from substituting a host/UI fixture constant.

This is an oracle gap, not a claim that the current host actually substitutes
the result. Closure should vary the valid book-defined result across runs and
make a hardcoded relay mutation fail while preserving the exact value through
the authority and real dialog paint.

## Positive results retained

- Canonical KOReader evaluation, derivation/output linkage, the immutable
  one-line `git-rev`, and package revision checks all occur before any writable
  fixture copy. The reviewed baseline reported `bundle-mode: package-pinned`,
  derivation
  `/gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv`,
  output
  `/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`, and
  revision `v2026.03`.
- After only the documented path bootstrap override, one Guile and one Python
  run completed the real socket/session/KOReader flow. This is diagnostic
  evidence, not an accepted baseline because BIR-1 and BIR-2 were still active.
- The surface-generation translation is coherent: navigation advances Book
  Session generation 1 to 2, verifies authority rejection of the late result,
  then sends the private semantic `stale-navigation` command; close verifies
  closed authority and a rejected peer write before sending `closed`. A private
  control generation-2 mutation failed with `private control generation
  mismatch`.
- The Lua private parser accepts exact bounded UTF-8 literal text and rejects
  an extra fourth field, invalid UTF-8, a 4,097-byte value, and an overlong
  line. Two buffered frames required two polls, and recursive `waitEvent()`
  delivered only one callback. Its fixed positional three-field grammar is not
  JSON, so JSON nesting and duplicate-key attacks are inapplicable to this
  channel. The separate book channel uses the unchanged accepted Guile/Python
  Book Protocol codecs, whose frozen inputs contain the depth, frame-size, and
  duplicate-key policy; this focused review did not reopen that accepted gate.
- Trust labels are accurate throughout: fixture comments, runner output, and
  README all call this trusted-native, non-sandbox, host-only work. The README
  explicitly disclaims durable save and display-settled acknowledgement.

## Final-snapshot recheck

Final recheck root: `/tmp/opencode/book-interaction-reader-current.mZmcWy`.
This copy was made after the BIR-1 and BIR-4 fixes. Its untouched baseline
passed all of the following with package-pinned KOReader v2026.03:

```text
PASS: typed fcntl and never-read private channel remain nonblocking
PASS: exact outer cleanup terminated both children after owner loss
PASS: no-op identity recorder is rejected before cleanup acceptance
BOOK_INTERACTION_HOST: language=guile update-present-navigation-close:ok
BOOK_INTERACTION_HOST: language=python update-present-navigation-close:ok
PASS: Book interaction vertical fixture
```

The independent final parser replay used the same fixed
`private_channel.lua`. It observed effective flags 2050; valid literal text,
malformed fields, UTF-8 and byte/line bounds, two buffered frames, recursion,
and an empty nonblocking poll all had the expected outcomes. This closes BIR-1
without relying only on the supplied new test.

The final UI instrumentation still observed `Saving failed.` as the top widget
at every update/navigation/close tick and zero dialog paints in both language
runs. The exact cleanup state remained positive, but the final mutation replay
returned:

```text
omitted-dialog-close rc=0
omitted-source-remove rc=0
omitted-channel-stop rc=0
hardcoded-present-forward rc=0
require-topmost-dialog rc=1
```

The last case failed for the intended `InputDialog was not topmost while
awaiting the book` diagnostic. Therefore BIR-2, BIR-3, and BIR-5 remain open,
and the final scoped gate remains rejected.

Final PID/start-time checks over every retained `*.pid` record found no live
owned identity. Process searches for the fixture book, plugin, and integration
host were also empty. Test profiles and logs are retained only inside the named
`/tmp/opencode` roots.

Final evidence hashes:

```text
445bc926d007cfb1324d0beff21d27294dfb01ba8cbaf34c3116fc1f8a45489b  control.out
86815aa5ed83bf747a85ab6de36529f90a9803aea2498f1d4b0aeda32508a715  baseline.out
8e3ce0aba96603dd434267c6cdbe7ac90b87a810582d49f7de96764e271a5360  independent fixed-channel output
fb5a83cb7dd006a8f66ca9a708f72df58fb47b26fadafc7ef1e4d34b65b59715  instrumented integration output
137ef4ef53900b5094803b6fe212a52575e10e49dc94f8a26e1460611be11e51  mutations.sh
2fcbef2e891392dba04044f72ca5f63ca1f3d7bc834fa0f3fe21586aba4e34df  mutations.out
0a496d9d8774e0ec0f6f8e0c526f731b3330fa661d8ba8d670c6eb3ebd5d9c2b  instrumentation.diff
cb2f93f7faaceccf26e06df1070e8ddd676a939f76ce7dd5ba85000e678cc5ce  instrumented Guile reader.log
bfd9b542e1522c2a39ec62cb1994f2f754beab5f09170e47c5c311654f1aef31  instrumented Python reader.log
```

The independent fixed-channel driver is under the immediately preceding
recheck root `/tmp/opencode/book-interaction-reader-final.PJCn8q` because the
only subsequent implementation changes were BIR-4's host-path fix and README;
the reviewed `private_channel.lua` hash is identical.

Final reviewed input hashes:

```text
31197623ee29033fc51ca8698a5b1682e4abdad34f50b6b9d0f1a919de4c643a  fixture/bookinteractionprobe.koplugin/main.lua
89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964  fixture/bookinteractionprobe.koplugin/_meta.lua
4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832  fixture/bookinteractionprobe.koplugin/private_channel.lua
58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363  fixture_book.py
2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d  fixture-book.scm
bda607a6cc1ee7a2c75a178c485c8ff5799158dd0a24ecaa99d3fd500ea7bf12  identity-hold.sh
647b741e1eb1afa29622e8ef86306cbb5538e4b76953e3a943d6ae381f240e48  integration-host.scm
7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e  Makefile
1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d  private-control.scm
2a397e5b83baf9654d78f7954c456ef832b32dd025efe69d35e01eb93598529a  README.md
b837f354f88730a9a36fa90d6c2b9145fd3a0d71ae546a0557d41bfb642d1dd9  run-tests.sh
e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06  test-private-channel.lua
92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a  test-private-control.scm
```

## Execution record

Initial discovery root: `/tmp/opencode/book-interaction-reader-review.hZP3co`.
The final-snapshot root and hashes are recorded above.

No active source, user profile, or store item was modified. No package was
built or realised; canonical package evaluation used its build-refusing
handler and the output was already present. No network, hardware, SSH, UART,
QEMU, VM, or gVisor was used. Python appears here as the selected fixture-book
language and as explicit reviewer-side mutation/socketpair tooling, never as
the authority.

The existing store tools used were Guile 3.0.11, guile-json 4.7.3,
guile-gcrypt 0.5.0, Python 3.12.12, and the packaged KOReader LuaJIT. The common
environment was:

```sh
export PATH=/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin:\
/gnu/store/lrl6shxa3gnlzy1mfa149vmgidnh60lw-python-3.12.12/bin:$PATH
export GUILE_LOAD_PATH=/gnu/store/qqxqhl1qlgacx2sj3292c2rmb8l04d15-guile-json-4.7.3/share/guile/site/3.0:\
/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0/share/guile/site/3.0
export GUILE_LOAD_COMPILED_PATH=/gnu/store/qqxqhl1qlgacx2sj3292c2rmb8l04d15-guile-json-4.7.3/lib/guile/3.0/site-ccache:\
/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0/lib/guile/3.0/site-ccache
export GUILE_AUTO_COMPILE=0
```

The untouched commands were:

```sh
cd /tmp/opencode/book-interaction-reader-review.hZP3co/baseline/repo/pinenote/tools/book-interaction
guile --no-auto-compile -L . test-private-control.scm

BOOK_INTERACTION_TMPDIR=/tmp/opencode/book-interaction-reader-review.hZP3co/runs \
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
./run-tests.sh \
  /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

The exact mutation substitutions and invocations are retained in:

```text
/tmp/opencode/book-interaction-reader-review.hZP3co/independent-mutations.sh
SHA256 64cd1a0710a11635ac3085567a5d8bb123822a2114e12dcd6827e3adfe536247
```

The exact Lua/socketpair probes and reviewer instrumentation are retained as:

```text
1688950e7cf7b0cafe3218fe02375e24dc79a60fcaa8f9b4456ddae96f2defcf  independent-channel-tests.py
b18e4658481e84efcd52959a741b3d6b6203d1e5ba2b082d93591243982ec009  lua-channel-case.lua
4a8869991de4c991322ade7b52aff4615911325d971af74bfa005645aa9c1ad5  bootstrap-override.diff
b2fba6090559b58a3130f017daf63dfc0e30049c5588028720d99b08c67957fc  widget-instrumentation.diff
f2b5c9c2afa1e90be85a8e3ecd2a19d7d946785641be4e494a1c363beb77bd81  timing-instrumentation.diff
```

Output hashes:

```text
445bc926d007cfb1324d0beff21d27294dfb01ba8cbaf34c3116fc1f8a45489b  control-baseline.out
c51df4e8d78f1e16015075b9e64cd84c83d40bd974c31c545c347d445e87ff10  integration-baseline.out
31398bee46a11e57ab72d3b7a421b6255815b8df2b1bb74119e58a1ed02851bb  integration-unblocked.out
b158686f412558a56c121518fdb45027372c294ec285d96990ef26225caa2070  independent-channel-tests.out
f4b60aeb8014626c5e73d9481c8c3f3d582bfd4b9673fd1c9ff3a6988177bbdc  fcntl-fixed-test.out
316644760e49ca986a1c8229a552b9fa13b3a813cf75fe39ac847acf0a7f17af  instrumented Guile reader.log
6b8f16dafb76bbdd0bc6787b7c4b5cfb5b249b7a146dee6f6755b54873055134  instrumented Python reader.log
c8a890795048b8b451a1572f32ffab2f6ba207fb0292a8bffef22fc1eaad4f6c  timed Guile reader.log
7b5b1c91adef7160ddcba11fa4e19c928ead7f332f7684d10fdcc71a7c809778  timed Python reader.log
```

Final process search:

```sh
ps -eo pid=,ppid=,stat=,args= \
  | grep -F '/tmp/opencode/book-interaction-reader-review.hZP3co/' \
  | grep -v grep || true
```

It was empty. Diagnostic files and disposable profiles are intentionally
retained only under the review root named above.

## Initial-snapshot reviewed input hashes

These hashes preserve the inputs against which BIR-1 and BIR-4 were first
reproduced. They are superseded for the final verdict by the final-snapshot
hashes above.

```text
31197623ee29033fc51ca8698a5b1682e4abdad34f50b6b9d0f1a919de4c643a  pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua
89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964  pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/_meta.lua
bb1eedd0ed611760e4a7403ed4a2af3b52ff153c1567ed7429cd7e4f165ea42e  pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua
58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363  pinenote/tools/book-interaction/fixture_book.py
2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d  pinenote/tools/book-interaction/fixture-book.scm
c7571df61a86273a3c88f9bd646f1ebc5a0790ff1913d5e274ccc87b880d84b2  pinenote/tools/book-interaction/integration-host.scm
7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e  pinenote/tools/book-interaction/Makefile
1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d  pinenote/tools/book-interaction/private-control.scm
ed9febf76c40b2e0125a549d960a47dce13e8a6bdc336f85f3d1fd9ae9b2c253  pinenote/tools/book-interaction/README.md
b17b1fdf8b5b82b65e5183654aa1a696277b03a16b557b14140ecbb04d1c59b9  pinenote/tools/book-interaction/run-tests.sh
92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a  pinenote/tools/book-interaction/test-private-control.scm
```

Read-only accepted/package-oracle hashes:

```text
f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668  pinenote/tools/book-session/book-session.scm
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  pinenote/tools/book-protocol/book-protocol.scm
4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735  pinenote/tools/book-protocol/book_protocol.py
543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd  pinenote/tools/book-protocol/book-protocol/blocking-io.scm
9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239  pinenote/tools/book-reader/canonical-koreader-output.scm
3051d24090152fd873a197cab6bfcbc88f977dbb4124ddf1ddbf910e62c9b7ff  pinenote/tools/book-reader/lint-fixture.sh
e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e  pinenote/tools/book-reader/timeout-owner.sh
97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354  pinenote/tools/book-reader/process-identity.sh
81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567  pinenote/packages/koreader.scm
661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1  channels.scm
846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5  packaged KOReader git-rev
a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc  packaged KOReader reader.lua
f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464  packaged KOReader uimanager.lua
a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4  packaged KOReader inputdialog.lua
1431c5cb7f5e42c5494c9f7ebc570d74627c9299e6d00f9c54762b4abded0f66  packaged KOReader inputtext.lua
```

---

## Implementation disposition for BIR-2, BIR-3, and BIR-5 — 2026-09-04

This is an **implementer record, not an independent re-review**. It does not
change the rejected final-snapshot verdict above. The report hash immediately
before this disposition was
`e7463a271d0be926363f4dfb5c3647f76e9cba8924a83cc1ac1c361e83c07ccd`.
The following candidate changes are submitted for a fresh focused review.

### BIR-2 candidate disposition

The actual save callback now returns `(false, false)`. This selects the pinned
InputDialog's failure/pending branch while taking its explicit no-message path;
the ordinary-run log is rejected if `Saving failed.` appears. A mutation that
removes only the second `false` runs actual pinned KOReader and fails because
the resulting `Saving failed.` widget, not the InputDialog, is topmost.

Clean disposable KOReader profiles show two unrelated startup overlays. The
fixture requires and dismisses exactly the two allowlisted pinned texts already
above the dialog before publishing reader readiness; an unknown or duplicate
overlay fails. It does not dismiss anything after a Save callback, so the
pending-callback mutation remains observable.

Navigation and close each schedule a task for 100 ms after submit. The task
must execute 70–300 ms after submit, while the plugin state is still `waiting`,
and must find the exact InputDialog topmost with its submitted text unchanged.
Both fixture books retain their 350 ms delayed replies. Thus the task executes
during the pending reply interval rather than just before entering it.

New `ui_audit.lua` retains and wraps the exact InputDialog instance. The wrapper
calls the real inherited `paintTo` first and only then records its text and
whether it was the topmost visible widget. Presentation handling arms that
observer with the runtime expected text, dirties the real dialog, and waits 50
ms for KOReader's repaint loop. It sends `applied`—which permits the host's next
action—only after the observer has seen a new topmost paint with the exact
result still in the dialog. The independent evidence lines from all four
ordinary runs were:

```text
BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:Book result: ADA
BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:Book result: ÉLAN Λ
BOOK_INTERACTION_READER: ui-wait-task:navigation:topmost-during-delay
BOOK_INTERACTION_READER: ui-wait-task:close:topmost-during-delay
```

This is a real KOReader widget paint into SDL's offscreen framebuffer. It is not
pixel-content inspection, a physical-display observation, an optical result, or
a display-settled acknowledgement.

### BIR-3 candidate disposition

The independent audit retains the exact dialog and channel after the plugin
clears its own references. Before `UIManager:quit`, it now requires all of:

1. the exact dialog is no longer in the real window stack;
2. the exact channel is absent from `UIManager._zeromqs`;
3. public `insertZMQ` and `removeZMQ` were each called exactly once for it;
4. `channel.closed` is true;
5. `fcntl(fd, F_GETFD)` returns `-1` with `EBADF`; and
6. one stale `waitEvent()` call leaves the wrapped receive-callback count
   unchanged.

The successful pre-quit observation was:

```text
BOOK_INTERACTION_UI_AUDIT: cleanup:dialog-source-counts-closed-fd-no-callback:ok
```

Three exact disposable mutations separately omit `UIManager:close`,
`UIManager:removeZMQ`, and `channel:stop`. Each actual KOReader run exits 1,
emits `cleanup-audit:before-quit`, names the missing postcondition, emits no
reader or host success marker, and leaves no matching PID/start-time record.
The checks therefore fail before process exit or UIManager's global teardown
could hide the omission.

### BIR-5 candidate disposition

The Guile host no longer contains an expected result literal or the book's
uppercase transformation. `run-tests.sh` is the test-only oracle: it derives an
expected result from each selected input and passes input and expectation as
fixture data. The host validates the authority's committed value but relays it
only through `(presented-text-value value)`. Both fixture languages independently
ran both deterministic cases through the same host:

```text
Ada     -> Book result: ADA
élan λ  -> Book result: ÉLAN Λ
```

A disposable host copy replaces only that generic relay expression with the
reported literal `Book result: ADA`. It runs the Python Unicode case through
actual KOReader, fails the plugin's runtime Unicode paint expectation, emits no
expected paint or final success marker, and leaves no owned process. The copied
host also reaches the intended presentation phase with no compiled cache at its
new path, retaining BIR-4's bootstrap property.

Python remains a test oracle and fixture book language only. It is not a host,
broker, authority, or fallback.

### Implementer execution result and scope

One final `make -C pinenote/tools/book-interaction check` passed under the pinned
Guix/KOReader environment:

```text
16 private-control assertions
typed-fcntl empty/never-read socket regression
owner-loss cleanup and no-op recorder negative
false/nil pending-callback negative
dialog-close, source-remove, and channel-stop negatives
hardcoded-host-relay negative
Guile/Latin and Python/Latin actual KOReader interactions
Guile/Unicode and Python/Unicode actual KOReader interactions
```

Every integration or mutation retained the 15-second internal fixture deadline,
20-second timeout owner, live command/deadline identity gate, exact child
cleanup, and residue checks. Guile warning compilation, Lua/Python/shell syntax,
line-length, whitespace, and `git diff --check` also passed. The accepted Book
Session and Book Protocol files were not modified. No hardware, device, VM,
QEMU, gVisor, network, deployment, package build, or image work was performed.

### Candidate hashes for focused re-review

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-interaction/README.md` | `7dd33e7f5847dbf3a483241c7f41303088b1b228c297f9ba76be46d1abd43864` |
| `pinenote/tools/book-interaction/Makefile` | `7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e` |
| `pinenote/tools/book-interaction/integration-host.scm` | `72e044abd38b33df81a2eeda9e2316f75479f0943b435cb1c72d25a426f22e0d` |
| `pinenote/tools/book-interaction/private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `pinenote/tools/book-interaction/test-private-control.scm` | `92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a` |
| `pinenote/tools/book-interaction/test-private-channel.lua` | `e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06` |
| `pinenote/tools/book-interaction/identity-hold.sh` | `bda607a6cc1ee7a2c75a178c485c8ff5799158dd0a24ecaa99d3fd500ea7bf12` |
| `pinenote/tools/book-interaction/fixture-book.scm` | `2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d` |
| `pinenote/tools/book-interaction/fixture_book.py` | `58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363` |
| `pinenote/tools/book-interaction/run-tests.sh` | `be301fcd9468cf952c2bef076290b60a3fd224582d834538126708b486d3e09e` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/_meta.lua` | `89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua` | `eb15a63999f7c4821d8b8c187fc80fb938ba175ff93430c6721c66d090d29daf` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/ui_audit.lua` | `ebcfcb14c1f5151b4d23bc820fb16b42db74cd1bf3fa1783cd0c29ebc6d4b7a3` |

The unchanged accepted Book Session authority remains
`f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`.
The accepted Guile codec, Python codec, and Guile blocking adapter remain,
respectively,
`91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44`,
`4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735`,
and `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd`.

This candidate requires the requested fresh independent reader/UI review. The
implementer does not declare BIR-2, BIR-3, BIR-5, or the overall interaction
gate accepted.

---

## Independent focused closure recheck — 2026-09-04

**Superseding disposition for the candidate hashes below: accepted for the
scoped trusted-native desktop/offscreen visible-interaction gate.** BIR-2,
BIR-3, and BIR-5 are closed. BIR-1 and BIR-4 retain their closed status; no BIR
finding remains open. The rejection at the start of this report remains the
historical verdict for the earlier snapshot and is superseded only for this
exact candidate snapshot.

Here, “visible interaction” means that the real pinned KOReader widget was
topmost and its real inherited paint method returned against SDL's offscreen
framebuffer. It remains neither pixel-content proof nor a physical-display,
settling, production-packaging, confinement, or hardware claim.

This was the requested focused recheck, not a new broad Book Protocol or Book
Session review. I did not reopen the accepted `book-reader` gate or repeat its
fifteen mutations. The unchanged accepted authority and codec hashes are
recorded below.

### Untouched baseline

I copied the candidate into a fresh isolated tree at
`/tmp/opencode/book-interaction-reader-r2.CnivwH/baseline/repo`. The untouched
runner completed with rc 0 against package-pinned KOReader v2026.03. It passed
the 16 private-control assertions, the typed-`fcntl` empty/never-read channel
regression, the owner-loss and recorder controls, all five new reader controls,
and these four actual KOReader interactions:

```text
Guile  / Ada     -> Book result: ADA
Python / Ada     -> Book result: ADA
Guile  / élan λ  -> Book result: ÉLAN Λ
Python / élan λ  -> Book result: ÉLAN Λ
PASS: Book interaction vertical fixture
```

This fresh-copy pass also preserves the BIR-1 and BIR-4 conclusions. The
package output, derivation, and revision remained the previously reviewed
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`,
`/gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv`, and
`v2026.03`.

### BIR-2 — Closed independently

I did not use `BOOK_INTERACTION_UI_AUDIT` markers as the paint oracle. In fresh
instrumented copies, a reviewer observer captured the dialog's inherited
`paintTo` before `UIAudit:retainDialog` wrapped it. `debug.getinfo` resolved that
captured function to the packaged
`@frontend/ui/widget/container/inputcontainer.lua`. The observer called that
captured KOReader method first and recorded text and stack position only after
the real method returned.

One Guile/Latin and one Python/Unicode positive run passed. In both, the exact
book result had one returned real-method paint while the intended InputDialog
was topmost:

```text
INDEPENDENT_PACKAGED_PAINT_RETURNED:topmost=true:text=Book result: ADA
INDEPENDENT_PACKAGED_PAINT_RETURNED:topmost=true:text=Book result: ÉLAN Λ
```

An independently scheduled task also ran 150–151 ms into each 350 ms
navigation and close response delay. In every observation the fixture was
still waiting, the exact dialog was topmost, and its submitted text was still
present. Thus neither the supplied audit callback nor a task immediately
before polling is the evidence for responsiveness.

I then restored the original bad pending return by changing only `return
false, false` to `return false`. Actual KOReader showed the real modal as the
top widget while the intended dialog remained underneath:

```text
INDEPENDENT_MODAL_SHOW:top=true:dialog-still-shown=true
BOOK_INTERACTION_READER: FAIL:InputDialog was not topmost before presentation; top-text=Saving failed.
```

The changed candidate paints its dialog during startup, so this replay had two
pre-result dialog paints rather than the old snapshot's zero total paints. It
had **zero book-result paints** (`result-paint-count=0`) and exited 1 before a
success marker. This is the relevant replay of the original modal/zero-painted-
result failure. The positive runs each had `result-paint-count=1` after the
actual packaged method returned.

### BIR-3 — Closed independently

The reviewer observer separately retained the exact dialog and channel,
wrapped the public source insertion/removal methods, inspected `_zeromqs`,
called `fcntl(F_GETFD)`, and made one post-close `waitEvent()` call immediately
before passing control to the original `UIManager:quit`. A positive run
reported:

```text
code=0:dialog-shown=false:source-found=false:insert=1:remove=1:
closed=true:fd-result=-1:fd-errno=9:no-stale-callback=true
```

Three fresh copies then omitted one real cleanup operation apiece. All exited
1 before reader/host success, and the independent pre-quit observations named
the actual leaked state:

| Independent mutation | Independent state at attempted quit | Result |
|---|---|---|
| omit `UIManager:close(self.dialog)` | `dialog-shown=true` | rc 1 |
| omit `UIManager:removeZMQ(self.channel)` | `source-found=true`, `insert=1`, `remove=0` | rc 1 |
| omit `self.channel:stop()` | `closed=false`, `fd-result=0`, `fd-errno=0` | rc 1 |

The channel remained empty in these tests, so the post-close call did not
spuriously invoke the callback. The positive state, public call counts, three
discriminating omissions, and failure before the original quit collectively
close the teardown-oracle gap.

### BIR-5 — Closed independently

The positive Python/Unicode run passed the exact real-method paint above. In a
separate fresh copy I replaced only:

```scheme
(queue-control! control 'present (presented-text-value value))
```

with the host literal `"Book result: ADA"` and ran the Python/Unicode case. The
private channel received that valid but wrong Latin value, the independently
parameterized Unicode oracle rejected it, no book-result paint occurred, and
the run exited 1:

```text
INDEPENDENT_VALIDATED_PRESENT:Book result: ADA
BOOK_INTERACTION_READER: FAIL:presentation did not match the independent test oracle
result-paint-count=0
```

The gate therefore distinguishes the authority's committed runtime value from
a hardcoded host/UI relay while also proving the correct Unicode value reaches
a real topmost InputDialog paint.

### Focused recheck record

The independent positives and each mutation used a distinct fresh copy under
`/tmp/opencode/book-interaction-reader-r2.CnivwH/independent`. The exact
reviewer driver and outputs are retained there. Relevant hashes are:

```text
ff1a688abfe1c2fc3fa9707aef7b64577a67018879017441a3a409356570b5dd  candidate-baseline.out
25a7741e4c73c3a619c027ea95682ba23e2cc242fcb5bf53e168fbdb6655a1d8  independent-focused.sh
cb8f0654e32fbf2c04c8ff046f3a81500fc15ae592510084fc343905dc9f1ad3  independent-focused.out
bf2789ee56c9d254417aa76ee3e6495ad68d77bdf14ddb586b641d483bae4453  independent positive output.log
5229ad3dc9a6bfcd2e7f71abfb1e6f9e79857b33f7ff147a88db5428e89a28f4  independent Guile/Latin reader.log
96c5229c65140bbd5b61c44431dcdb6610183dca62230b2d8a5408bbf8835b55  independent Python/Unicode reader.log
5eeae8b8d8e262a0f383d13ac657b808b4aacbd12f707bdf49f26dea862176a9  modal output.log
b5e37b67176db28127d580f0abcd448cab420427f4835322b45aacfc74646089  modal reader.log
5020dcd1dabdf0ea83462ca33de685ee17a86f177aaed5435fd3e403df103b9b  omitted-close output.log
8700f604bcfa2881be9deb2366f04ef535728814191777c8f00a795031f5260f  omitted-close reader.log
c9fb105b68763d15385e30b5486c989ab96c3d6222df6fb174fa8051c576ee9a  omitted-remove output.log
61e093742748e386193b75f78a28053fcba390263fddf516522f127bfa91e335  omitted-remove reader.log
644b04a097de437338368a5030f87f5e3c99935f932af8d430d28d3fcff0cab8  omitted-stop output.log
37e998630e166f451ecd1ffea436e6a57eb9a65758ab640873cad3b0c02e36cd  omitted-stop reader.log
83f822c964a25768db243dca8fe58f7780f736de4aa44f7596da84c1045b08f3  hardcoded-relay output.log
dac735146859a02b3f7ed6ffb652b9a28985043c49f9a5b314251a361a7ee901  hardcoded-relay reader.log
```

The report hash before this independent appendix was
`cd26a247cbd8493d99cefa1c005dfab06f5d5b3907e7f14867555d699351ac0d`.
The exact accepted candidate inputs were:

```text
eb15a63999f7c4821d8b8c187fc80fb938ba175ff93430c6721c66d090d29daf  fixture/bookinteractionprobe.koplugin/main.lua
89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964  fixture/bookinteractionprobe.koplugin/_meta.lua
4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832  fixture/bookinteractionprobe.koplugin/private_channel.lua
ebcfcb14c1f5151b4d23bc820fb16b42db74cd1bf3fa1783cd0c29ebc6d4b7a3  fixture/bookinteractionprobe.koplugin/ui_audit.lua
58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363  fixture_book.py
2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d  fixture-book.scm
bda607a6cc1ee7a2c75a178c485c8ff5799158dd0a24ecaa99d3fd500ea7bf12  identity-hold.sh
72e044abd38b33df81a2eeda9e2316f75479f0943b435cb1c72d25a426f22e0d  integration-host.scm
7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e  Makefile
1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d  private-control.scm
7dd33e7f5847dbf3a483241c7f41303088b1b228c297f9ba76be46d1abd43864  README.md
be301fcd9468cf952c2bef076290b60a3fd224582d834538126708b486d3e09e  run-tests.sh
e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06  test-private-channel.lua
92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a  test-private-control.scm
```

The accepted core files remained unchanged:

```text
f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668  book-session.scm
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  book-protocol.scm
4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735  book_protocol.py
543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd  book-protocol/blocking-io.scm
```

Final PID/start-time checks found no retained identity matching a live process;
scoped process searches for this review root, fixture books, plugin, and host
were empty. I did not touch or clean up the separately running diagnostic QEMU
process. No implementation or accepted-core file, active user profile, store
item, hardware, SSH/UART endpoint, network, QEMU/VM/gVisor instance, package,
or image was modified or exercised. Python was used only as a fixture-book
language and explicit reviewer-side copy/mutation tooling.
