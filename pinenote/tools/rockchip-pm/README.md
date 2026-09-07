# rockchip-pm — activation-hard-off BSP SIP/PM contract tests

This rung-1 host tool extracts the exact legacy SIP header, RK3568 bindings,
typed suspend model, and generic executor from
`pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch`. It compiles those
sources with fake operations only. `check.py` proves that production links the
strict parser, model, executor, and real backend. The activation object owns a
separate platform driver and the only device-PM `.prepare`/executor edge. Its
Kconfig choice is explicit and defaults off for other platforms; the PineNote
defconfig deliberately enables it.

The C tests cover the donor's probe ordering, repeated GPIO records and
terminator, PM-prepare regulator actions, and descriptive virtual-poweroff
transaction. Controls `0x01..0x09` are pinned; `0x08` remains defined but no
builder emits it. Capacity failures and invalid policies leave caller-owned
outputs unchanged. Virtual poweroff remains descriptive host coverage only:
production rejects the property, and the real backend rejects regulator prepare
before CPU, SIP, or PSCI actions.

The fixture pipeline compiles donor PineNote and synthetic maximal DTS files,
parses the resulting DTBs through `fdtdump`, and feeds generated policy inputs
to the same C model. It recognizes the donor's exact `rockchip,power-ctrl` and
`rockchip,regulator-*-in-*` properties. GPIO controller identity comes from the
compiled DT's `gpioN` aliases rather than its MMIO unit address. The adapter
rejects unknown properties,
malformed cells, unresolved references, duplicates, overlap, and excess list
lengths in the host adapter. Production is intentionally narrower: only MEM
regulator lists are accepted, while mem-lite, mem-ultra, and virtual-poweroff
properties are rejected. Regulator phandles become standard consumer handles
with core-managed lifetime and locked transactional suspend wrappers. Provider
identity is deduplicated with `regulator_is_equal`; prior suspend settings are
restored on prepare failure and PM completion. Failed restores remain queued for
best-effort reverse-order retry. Any prepare or restore failure permanently
poisons the built-in activation instance until reboot, and suppressed bind
attributes prevent userspace unbind/rebind from escaping that state. Teardown
retries restoration and reports any remaining failure critically. `check.py`
separately mutates every required source,
object registration, config, ABI, zero-call boundary, patch-metadata form, and
activation-surface invariant and requires the static validator to fail closed.
`make suspend-check` owns the compiled policy-free DT blacklist mutations.

`check.py PATCH` validates the canonical BSP patch stage: its PineNote DTS hunk
must carry only the measured baseline-deep properties and must not add the
standing ultra override. `check.py --source-tree ROOT` instead validates the
fully applied stack, where the final PineNote DTS must contain exactly one
`rockchip,suspend-state-override = <5>;`, directly on the unique top-level
`rockchip-suspend` node with its reviewed compatible. Its source mutations
remove, change, duplicate, and move that assignment to `/chosen`, and disable
the exact unique production `CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y` line;
each must be rejected. The activation-source check is structural rather than a
general C control-flow proof: after removing comments it requires the one exact
DT snapshot restore in `rockchip_suspend_prepare()`'s direct function scope,
before one-shot handling, policy construction, and execution. Focused controls
move it late, put it behind braced/bare/preprocessor conditions, or leave it
only in a comment. The separate `validate-ultra-coupling.sh` gate proves that
the required final override is owned by the later ultra patch together with the
three rail flips and card-power change. Neither checker mode substitutes for
that coupling gate.

Run it from the repository root:

```sh
make rockchip-pm-check
```

The dedicated host-only activation-positive scenario is intentionally separate
from that dormant-contract gate:

```sh
make -C pinenote/tools/rockchip-pm activation-positive-check
```

It parses the compiled synthetic maximal fixture, emits and executes its exact
probe plus MEM-prepare actions through `fake_ops`, then fails each MEM regulator
action in turn. Successful fake mutations add their actual prior values to the
same transaction, so the test pins failure-index-to-restore-set coupling, exact
reverse unwind arguments, permanent poison, and zero-action retry behavior. The
target also runs `check.py`, retaining its
static proof that the production real backend is linked only behind the
activation-hard-off boundary; the scenario binary itself links and calls fake
operations only.

Passing proves the compiled host logic, compiled fixture interpretation,
canonical patch shape, and actual supplied-source-tree architecture. The C/DTB
tests cover the extracted fake model/executor and fixture adapter; the Python
source checker separately owns final-DTS node placement and activation-source
ordering. Host tests never invoke the real backend. They do not execute the
platform driver, boot the PineNote, activate suspend policy, or prove firmware,
DDR retention, wake, resume, display repair, or power use.

## Why the donor probe values are what they are

`test_probe()` pins four events for the compiled donor fixture — `0x01 0x5ec`,
`0x02 0x10`, `0x04 0 0xffff`, `0x05 0 0`. Those are not chosen, they are
**differentially verified against the BSP emitter** (`rockchip_pm_config.c`,
`pm_config_probe()`), and the DT values themselves are measured from os1's
booted DTB — the kernel on which deep suspend demonstrably works on this
device. Full derivation, including the control-code table and the two
non-obvious behaviours the BSP has (the *unconditional* GPIO terminator, and
`SUSPEND_DEBUG_ENABLE` firing on property **presence** rather than a non-zero
value), is in `doc/artifacts/pinenote-sip-sequence-differential-20260802.md`.

If a rebase changes any of those four events, do not "fix" the test — re-run
the differential first. The BSP emitter is the authority, not our model.
