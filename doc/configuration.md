# Configuration: the direction

**Status: settled direction, not an implementation.** Almost nothing here
is built. It records a design conversation (2026-08-24) so the decisions
stop living in one thread, and so the alpha-scoped work below can be done
without re-litigating them.

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
(`pinenote/services/koreader-profile.scm`) writes 23 **materialised
defaults** — `copt_font_size = 30`, `flash_ui = false`,
`full_refresh_count = 0` — directly into KOReader's settings file. That is
harmless today *only by accident*: `/root` is on p6, so every reflash
wipes it and the seed reasserts. **That volatility is the only reason
rebuilt defaults currently reach anyone.**

The seed became a record on 2026-08-24 (#12 step 2), which fixed a
different problem — there were *two* writers of that file and the second
was dead code — and deliberately did **not** touch this one. Every value
is still materialised; `KO_HOME` did not move. Serializing from a record
makes the durability question expressible, not answered.

Move that file to p7 for durability and every one of those values
freezes at whatever shipped when the device first booted. Durability and
default-propagation are in direct conflict, and the conflict is caused
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
the image as data**, because three languages read it: Scheme (records,
the paved path), the Lua daemon, and the Lua UI.

### "Interacting with the user" is deferred and queued

At boot there is nobody to ask. `autosuspend` starts before KOReader is
up — and KOReader may not come up at all. So a migration needing a human
is **not a step in the loading path**:

1. The consumer sets a temporary value it deems appropriate and runs.
2. It records what it did and why, without destroying the override.
3. A **pending-decision queue** outlives the boot, and the UI drains it
   whenever there next is a user — possibly minutes later, possibly a
   different boot.

Making that experience pleasant is part of what the config system is
*for*, not an afterthought.

## 4. Everything survives a reflash

A tester who reflashes and loses "show clock in footer" while keeping
font size has hit a **bug**. The boundary between KOReader's settings and
ours is invisible from where they sit — same menu, same session — so it
cannot be where durability changes.

This is what makes the write-interception load-bearing rather than
convenient. KOReader has exactly one chokepoint —
`LuaSettings:saveSetting` (`frontend/luasettings.lua:102`) and `flush()`
(`:270`) — with **332 call sites** routing through
`G_reader_settings:saveSetting`. So this is a wrap of one function, not a
fork of a settings system.

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
experiment that currently costs a dd, a verify and a reboot becoming a
file edit is worth a lot.

Alpha users should be able to write new KOReader plugins, manage config,
and touch the environment — in ways later versions will probably restrict.

Rules for now, weaker than §1–§6 on purpose:

- **Different config systems are acceptable** for now.
- **One setting is declared in one place.** This is the discipline that
  matters, and it is not in tension with overriding: one *declaration*
  site for the default, plus one *override layer* with defined
  precedence. What is banned is a default written in two files — which is
  today's actual bug (`idle`, `backstop` each declared twice).
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

This is more achievable than it looks: **Guile 3.0.11 is on the device**,
on `PATH` at `/run/current-system/profile/bin/guile` (shepherd itself
runs on 3.0.9). Scheme-on-device is real, not host-only.

## 9. Open

1. **Application state vs preferences** through the same chokepoint (§4).
2. **Does `guix home` still have a role?** #12 §3 routes user preferences
   there, at a measured ~695 MiB of `guix` closure. If preferences live
   in the overlay instead, that trajectory may be unnecessary — and #12's
   own alternative (b), a system service materialising home-shaped
   records, becomes the obvious answer. Not re-examined in this
   conversation; flagged, not decided.
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
