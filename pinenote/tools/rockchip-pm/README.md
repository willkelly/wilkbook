# rockchip-pm — activation-hard-off BSP SIP/PM contract tests

This rung-1 host tool extracts the exact legacy SIP header, RK3568 bindings,
typed suspend model, and generic executor from
`pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch`. It compiles those
sources with fake operations only. `check.py` proves that production links the
strict parser, model, executor, and real backend. The activation object owns a
separate platform driver and the only device-PM `.prepare`/executor edge; hidden
exact-default-n Kconfig omits that object from the PineNote candidate.

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
canonical patch shape, and actual supplied-source-tree architecture. Host tests
never invoke the real backend. It does not execute the platform driver, boot the
PineNote, activate suspend policy, or prove firmware, DDR retention, wake,
resume, display repair, or power use.
