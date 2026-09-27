# Configuration: implementation and direction

**Status (2026-09-26): the single KOReader seed and the configuration
coupling gate are implemented; the general sparse, durable override system
and settings book are not.** Sections 1–8 retain the settled policy from
2026-08-24. Section 10 specifies a proposed API, not a shipping service.

What exists now:

- `pinenote/services/koreader-profile.scm` declares and serializes the one
  KOReader seed; `make koreader-profile-check` tests the generated Lua and
  detects additional Scheme seed writers. It writes only if the settings
  file is absent. It does not track which later values were user choices.
- `pinenote/tools/settings/` provides the source-only Guile coupling audit,
  mutation controls, and Lua fixtures executing the shipping broker's
  configuration parser. It inventories current defaults and known
  inconsistencies; it does not validate or rewrite a device's files.
- The shipping suspend owner is `pinenote-platform-controls`, with
  KOReader AutoSuspend owning idle timing (default 15 minutes). The old
  `autosuspend.lua` and its five-minute default are legacy compatibility
  checks, not the shipping idle policy. The direct driver's production
  overrides are `temp_override=22` and `default_hint=32`, written through
  sysfs before the CLUT rebind; the old `refresh_waveform=6` checks cover
  retained legacy paths, not a parameter the direct driver exposes.
- The notebook already uses narrow sparse preferences at
  `/data/notebooks/prefs.json` (brush, size, mode, rubber), with defaults in
  Lua. This is not the general store: its current `clean_prefs` drops
  unsupported choices rather than preserving unknown settings for future
  migration. Its last-notebook/page state is stored alongside preferences.
  That limitation does **not** change the unknown-setting policy in §4.
- `/root/.config/koreader` and `/var/lib` are on p6: they survive normal
  generation updates, but an os2 reflash replaces them. `/data` on p7
  survives either. Generation rollback also does not roll back those
  mutable p6 settings. The Guix store-importer/update path now exists
  (`doc/update-path.md`); it supplies no sparse-preference implementation.
  Guix Home's role remains undecided (§9).

General write interception, default/override provenance, a serialized shared
schema, migrations and a durable pending-decision queue remain outstanding.

`doc/` neighbours: #12 (the issue this supersedes in part), #11 (the
on-device half), `doc/power-management.md` (where the measured numbers
that constrain several of these live).

## 1. Who owns a setting

**The idle timeout belongs to the person holding the device.** It is a
preference with a tradeoff; our job is to pick defaults that are right,
not to withhold the knob. This generalises: a knob that only trades one
experience against another is the user's. Our job is the default.

That decision alone retires #12's "the p7 surface shrinks to two keys".
Two keys was never the principle — *rescue-only* was, and a tunable the
device's own UI writes needs somewhere durable to land.

## 2. Sparse overrides: only what was explicitly set

The store holds **only values a user actually set**. Never a materialised
copy of the defaults.

| state | meaning | on a new image |
|---|---|---|
| key absent | "I never cared" | **takes the new default** |
| key present | "I chose this" | **preserved** |

So a rebuilt default reaches everyone who never touched it, and nobody's
deliberate choice is silently reverted. "Restore default" is *deleting*
the key, which returns that setting to the managed state.

**A value explicitly set to today's default still counts as set.** "I
chose 300" and "I never touched it" both read 300 now, and must remain
distinguishable — otherwise the day the default moves to 600, the person
who deliberately chose 300 gets moved with it.

### The trap this exists to avoid, which is live in the tree today

`pinenote-koreader-profile-service-type`
(`pinenote/services/koreader-profile.scm`) writes **materialised
defaults** — `copt_font_size = 30`, `flash_ui = false`,
`full_refresh_count = 0` — directly into KOReader's settings file. That file
is reset by an os2 reflash: `/root` is on p6, so that replacement wipes it
and the seed reasserts. **A normal generation update preserves the file
and does not reapply the seed.** A rebuilt default therefore does not
automatically reach an existing seeded preference during an update.

The seed became a record on 2026-08-24 (#12 step 2), which fixed a
different problem — there were *two* writers of that file and the second
was dead code — and deliberately did **not** touch this one. Every value
is still materialised; `KO_HOME` did not move. Serializing from a record
makes the durability question expressible, not answered.

Move that file to p7 for durability and those values stay materialised
even across reflashes. That freeze already occurs across generation
updates on p6. Durability and default-propagation are in direct conflict,
and the conflict is caused
entirely by the file being materialised. §4 resolves it.

## 3. Validation and migration are the system's job

Configuration has a **validation stage that declares acceptable values as
data** — a range, a set of options — not as code buried in a parser.

- **Any previously-allowed value must be importable.** Old configs load.
- **When a previously-allowed value becomes disallowed, resolving it is
  our responsibility**, in one of three ways:
  - **silently**, when the transform preserves *meaning* rather than the
    number. Moving a range from 1–10 to 1–100 means multiplying by ten;
    the result is the same setting, so nobody is told.
  - **automatically, and the user is told**, when the change meaningfully
    affects their experience. A safety clamp from 2700 to 1800 is not a
    unit change.
  - **by asking**, when it cannot be resolved for them.

Overrides therefore carry a **schema version** — you cannot migrate what
you cannot date. And the schema is declared once and **serialised into
the image as data**, because three consumers read it: Scheme (records,
the paved path), the Lua broker, and the Lua UI. This shared schema is
proposed; today's parsers still declare their own accepted values.

### "Interacting with the user" is deferred and queued

At boot there is nobody to ask. The platform-controls broker starts before
KOReader is up — and KOReader may not come up at all. So a migration needing a human
is **not a step in the loading path**:

1. The consumer sets a temporary value it deems appropriate and runs.
2. It records what it did and why, without destroying the override.
3. A **pending-decision queue** outlives the boot, and the UI drains it
   whenever there next is a user — possibly minutes later, possibly a
   different boot.

Making that experience pleasant is part of what the config system is
*for*, not an afterthought.

## 4. Everything survives a reflash (target, not current behavior)

A tester who reflashes and loses "show clock in footer" while keeping
font size has hit a **bug**. The boundary between KOReader's settings and
ours is invisible from where they sit — same menu, same session — so it
cannot be where durability changes.

This is what makes the write-interception load-bearing rather than
convenient. The 2026-08-24 investigation identified KOReader's shared write
path —
`LuaSettings:saveSetting` (`frontend/luasettings.lua:102`) and `flush()`
(`:270`) — with **332 call sites** routing through
`G_reader_settings:saveSetting`. Those counts and line numbers describe
that inspected bundle, not a version-independent API. Interception still
needs to distinguish explicit user writes from application default/state
writes, and cover deletion, reset and nested-table updates; wrapping
`saveSetting` alone does not prove all those paths are captured.

- Our store on p7 holds **only explicitly-set values**, with provenance.
- KOReader's `settings.reader.lua` becomes a **derived artifact**,
  regenerated at boot from *current image defaults ⊕ user overrides*.
- It can stay on p6 and die at every reflash — now **harmless**, because
  it is derived rather than authoritative.
- **Unmodelled settings survive too.** The chokepoint captures any key,
  schema or no schema.

So "modelled" stops meaning *durable* and starts meaning *guaranteed*:
validated, ranged, migratable, restorable. That boundary is defensible
precisely because it is invisible in the way a tester actually cares
about.

**Open:** `saveSetting` also carries application *state* — last file
opened, view mode, window state — through the same chokepoint. Some of
that surviving is a feature; some is noise preserved forever. Undecided.

## 5. The settings book

The eventual UI is **a book**. You open it and the settings are in it as
interactable forms: a table of contents mirroring today's menu structure,
forms contributed by anything that exposes new settings (discoverable),
and an **index of every setting by name** that you can tap and set.

The index is what retroactively justifies the schema — an enumerable list
of every setting with its type, range, current value and provenance is
exactly what §3 declares, put to a second use.

It is also the **first instance of a general capability**, not a settings
feature. The same machinery serves the larger intent: drawn UIs inside
books, and handwritten code that executes.

**Mechanically it cannot be a self-contained EPUB.** crengine renders
HTML but has no forms and no scripting — verified against the shipped
bundle. So: *the document is real; the liveness is a plugin overlay.*
crengine paints the page, a plugin recognises marked regions and draws
real widgets (`inputdialog`, `inputtext`, `checkbutton`,
`doublespinwidget`, `buttontable` are all in the bundle already). That is
the same architecture the handwriting-in-books intent needs later, so it
is not a workaround.

Three write paths, all through the same system: forms, code written in
the book, and a remote API.

## 6. Sharing, capabilities — 1.0, and deliberately under-specified

Settings books should be **shareable**, which makes them a security
surface: a document that reconfigures the device, on a shelf whose entire
content model is *files other people sent you*, with KOReader currently
running as root.

The intended shape, not yet designed:

- a **capabilities system**, granted per book
- **sandboxed by default** — code executes, but with no persistent
  storage, no network, and read-only filtered access to the config API
- some capabilities **require a signature from the image**
- books run as containers

**This is a 1.0 feature, after alpha, and it needs a lot of design.** It
is recorded here so that what ships before it does not foreclose it — in
particular, the config API needs a *filterable read path* designed in
from the start, since that is what a sandboxed book gets.

## 7. What alpha ships

An **overlay**, explicitly experimental and **potentially throwaway**.

The case for it is not tester convenience, it is our own velocity: *to be
able to try more things on device without reflashing.* On a project whose
first principle is that hardware sessions are the scarce resource, every
experiment that can become a file edit avoids an OS update. The normal
OS update is now a generation transfer and trial boot, rather than dd;
that improves deployment but does not replace runtime configuration.

Alpha users should be able to write new KOReader plugins, manage config,
and touch the environment — in ways later versions will probably restrict.

Rules for now, weaker than §1–§6 on purpose:

- **Different config systems are acceptable** for now.
- **One setting is declared in one place.** This is the discipline that
  matters, and it is not in tension with overriding: one *declaration*
  site for the default, plus one *override layer* with defined
  precedence. What is banned is a default written in two files — which is
  the duplicated legacy `idle` and `backstop` defaults illustrate the
  problem. The shipping broker also has hard-coded defaults and paths,
  without a Guix configuration record yet.
- **The framework is discoverable.** What can be overridden, where it
  goes, and what is currently overridden.
- **Users may override anything**, including dangerous values.

### Dangerous values are allowed, documented, and warned about

`dmc.mode = normal` is the one knob whose wrong value fails **silently**:
DDR at 324 MHz starves the EBC's phase fetch, the display corrupts,
dmesg stays clean and no underrun interrupt fires. It takes effect at
boot, cannot be `herd stop`ped, and may leave no SSH.

It is **still allowed**. We may want to set it ourselves — and today we
cannot do so properly, because `dmc.mode` has *no Guix record field at
all*, so arming the experiment means hand-writing a p7 file. The controls
are:

1. call it out plainly in the README, the image-build docs and here;
2. **warn at image-build time** when a dangerous knob is set to a
   dangerous value.

A warning, not a refusal. Carving exceptions into "override anything"
starts a list, and lists rot.

### Say the throwaway part out loud

Alpha testers will configure things in a layer 1.0 may not carry forward.
That is acceptable for alpha — but it is a **promise to make at the
start**, not an apology at 1.0.

## 8. Language

Both Lua and Scheme reach both KOReader config and system config. **The
paved path is Scheme.**

Build/system scripts should use Guile/Guix; KOReader integration stays
Lua. Python remains available in the project where appropriate; the
small settings audit no longer needs it.

This is more achievable than it looks: **Guile 3.0.11 is on the device**,
on `PATH` at `/run/current-system/profile/bin/guile` (shepherd itself
runs on 3.0.9). Scheme-on-device is real, not host-only.

## 9. Open

1. **Application state vs preferences** through the same chokepoint (§4).
2. **Does `guix home` still have a role?** #12 §3 routes user preferences
   there, at a measured ~695 MiB of `guix` closure. If preferences live
   in the overlay instead, that trajectory may be unnecessary — and #12's
   own alternative (b), a system service materialising home-shaped
   records, remains an option. The store-importer daemon now ships for
   generational updates, so the historical incremental-closure argument
   needs remeasurement. Home is still undecided; an importer is not Home.
3. **#11 bundles two different things.** On-device *settings* and
   on-device *Wi-Fi credential entry* share a keyboard-on-e-ink problem
   and nothing else. #12 is explicit that credentials are not knobs
   ("conflating secrets with settings is how the current namespace
   grew"). The Wi-Fi half is also more urgent: a typo in staged
   credentials is currently unrecoverable — no network, so no `scp`, so
   no fix.
4. **The pending-decision queue's own failure modes** (§3): never
   drained, nagging forever, or a user who answers "keep it" for a value
   the schema still forbids.

## 10. Minimal enumerable settings contract (proposed)

This defines the common boundary for a future Scheme caller, KOReader
plugin and settings-book overlay. There is no general backend, transport,
CLI or UI implementing it yet. Operation names below describe semantics,
not a committed wire format.

### Schema and operations

The image supplies a versioned, enumerable schema as data. Each modeled
setting has a stable namespaced key, owner, type, units, default, allowed
range/options, help, risk notice where applicable, and application timing
(immediate, reader restart, service restart or boot). The distinction
between a default and an override is independent of their equal values.

| operation | minimum result / effect |
|---|---|
| `list(scope)` | Authorized descriptors and keys, including visible unmodeled overrides tagged `unmodeled`; no arbitrary filesystem enumeration. |
| `read(key)` | Descriptor/schema version, current image default, explicit-override presence and value, effective value, provenance, validation/migration state and any pending decision. Reading writes nothing. |
| `set(key, value, expected_revision)` | Validate a typed **explicit user choice**, then atomically persist only that override and its provenance. Setting today's default still stores an override. Return the new revision and whether application is immediate or pending restart/boot. |
| `reset(key, expected_revision)` | Atomically delete the override. Return the current default as effective and provenance `image-default`; never persist a replacement copy of the default. |

The revision prevents a form opened earlier from silently overwriting a
newer change; a conflict returns the current revision and requires a fresh
read. Persistence failure leaves the old override intact and is reported.
Successful persistence and successful runtime application are distinct:
return both the desired value and the applied/pending state. This is a
per-key contract; multi-key transactions and coupled-setting validation
need design before any coupled knobs are exposed for writes.

Provenance must at least distinguish `image-default`, `explicit-user`
(including an authorized book/API actor), `migrated-user`, and
`temporary-fallback`. Record schema version, override revision and writer
identity; keep enough original value/version information to explain a
migration and preserve an unresolved choice. An import cannot infer
explicit intent merely because a seeded value differs from today's
default. The transition from existing materialized KOReader settings
needs its own import policy; do not label the whole file user choices.

### Validation, migration and unknown settings

New modeled writes validate against the declared schema. Rejection is
structured (key, constraint, reason) and changes no stored value. Alpha's
dangerous-but-allowed values stay representable and carry the warning
policy in §7; risk is not an excuse to hide the user's knobs.

Loading old overrides is a separate operation from accepting new writes.
Any formerly allowed value must be importable (§3). A versioned migration
either preserves meaning silently, changes meaning with a recorded notice,
or uses a temporary effective fallback and queues a durable decision.
It never replaces an unresolved explicit override with that fallback.
Pending records need stable IDs and revisions so repeated boots do not
duplicate a question and a stale answer cannot replace a newer setting.
Queue presentation and the failure cases in §9 remain open.

Unmodeled settings and unknown values from a newer image survive import,
unrelated writes and rollback round trips. Keep their opaque data and
version/provenance even when the current consumer cannot apply them;
enumerate them as unmodeled where the caller is authorized. This preserves
§4's policy without claiming validation the image cannot perform. The
representation/size limits and write rules for unmodeled data still need
design; no executable Lua from a settings book becomes trusted config.

### Secrets and scoped grants

Wi-Fi credentials, private keys, authentication tokens and secret-bearing
paths/values are outside this API and its enumeration, provenance and
pending-decision output. Credential entry uses a separate interface
(§9); permission to change idle timing conveys no credential access.

Every caller has a scope restricting both keys and operations (`list`,
`read`, `set`, `reset`). A read grant never implies write, and a book gets
only filtered non-secret reads by default (§6), not all host settings.
An explicit grant identifies the book/actor and permitted keys/namespace;
code in a shared book cannot enlarge it. Revocation applies to subsequent
calls. Host access, networking, persistent book storage and image-signed
capabilities are separate grants. The existing book-state experiment is
not an implementation of these settings grants.

## 11. Current parser/default inventory

`pinenote/tools/settings/README.md` gives the runnable audit and the
legacy coverage map. The following describes current source behavior,
including inherited inconsistencies, rather than the schema we want:

| owner | defaults and precedence |
|---|---|
| platform-controls broker | Each reload starts at `enabled=true`, `charging=false`, `backstop=3600`, `rtc_settle=20`. Read `/data/wilkbook/autosuspend.conf`, then `/var/lib/pinenote/autosuspend.conf`, then `/run/wilkbook-power/inhibit.conf`. Last accepted value wins per key; a missing file contributes nothing. The last file can enable as well as inhibit. |
| broker parser | `enabled` is false only for `0/false/no`; `suspend_while_charging` is true only for `1/true/yes`. Both are case-sensitive. Thus `enabled=off` enables, and `suspend_while_charging=on` does not opt in. Numbers: `backstop >= 30`, floored, no finite upper-bound check; `rtc_settle >= 20`, floored and capped at 3600. Invalid later numeric values leave the prior accepted value. `idle` only warns once; `power_key` and other unknown keys are ignored. |
| Lua config lines | Leading/inter-key whitespace is accepted. Values are one non-whitespace token: `enabled=0 # comment` disables, but `enabled=0#comment` enables. Duplicate keys use the last accepted value. Parsers read files without rewriting unknown lines. |
| KOReader seed | Image profile only on an absent `settings.reader.lua`; subsequent KOReader writes win. No explicit-choice provenance. Idle timing is KOReader's AutoSuspend preference, not the broker's obsolete `idle=` key. |
| direct display | `temp_override=22`, `default_hint=32` through the service's sysfs writes. Profile and device-layer flash-area fraction default to `0.98`. The driver's native hint default differs intentionally from the service override. |
| DDR boost | Record/argv `hold=10`, config `/var/lib/pinenote/ddr-boost.conf`; accepted runtime `hold >= 1` is floored and takes precedence. Runtime `enabled=false`, with allowlist `1/true/yes`. File-scoped `enabled` has a deliberately different default from suspend. |
| DMC | `/data/wilkbook/dmc.conf`, first line beginning exactly `mode=` wins. Trim the remaining value; accept `normal/noswitch/off`, otherwise `off`, also on absence/error. Leading whitespace is rejected, unlike the Lua parsers; trailing comments are not accepted as part of a mode. No Guix mode field yet. |
| timesync | Record/daemon defaults agree on empty servers, poll 120, refresh 21600, timeout 5, max backoff 3600, not-before 1767225600 and horizon 630720000 (seconds where applicable). Service `hwclock` is an absolute store path; the standalone daemon's fallback is a PATH lookup. |

The audit pins these observations. New drift fails, and changed or removed
debt fails until the inventory is deliberately updated. The mixed boolean
grammars, missing records and whitespace differences are inherited
inconsistencies to migrate, not regressions introduced by this gate. An
equal name in different config files is not a shared setting identity.
