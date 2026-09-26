# settings — configuration coupling audit

From the repository root:

```sh
guile --no-auto-compile -s pinenote/tools/settings/check-settings.scm
guile --no-auto-compile -s pinenote/tools/settings/test-check-settings.scm
lua pinenote/tools/settings/test-broker-config.lua
```

Each accepts an optional repository root. The Scheme commands default to
their checkout; the Lua fixture defaults to the current directory. Requires
Guile 3 and Lua 5.1+ or LuaJIT (substitute `luajit` for `lua`). No Guix
evaluation, builds, store reads, Python, device files or network access.

The root `settings-check` target should run these three commands, replacing
its two Python invocations. `koreader-profile-check` remains the seed writer
and serialization gate; this audit does not duplicate that implementation.

## What is checked

| scope | observations |
|---|---|
| Shipping suspend | Reader selects platform-controls, not the retired autosuspend service. Broker initial/reload defaults, timing constants, config path order, key roster, boolean grammar, numeric ranges, obsolete `idle`, and the absence of a Guix configuration record. |
| Shipping display | Reader selects direct params; exactly `temp_override=22` and `default_hint=32` are written through sysfs. No reintroduced modprobe/set_parameter copies or QEMU assertions of the retired `refresh_waveform` node. Profile and device-layer flash fraction both default to `0.98`. |
| Existing record/daemon couplings | All fifteen original pairs: five legacy autosuspend, two DDR boost, eight timesync (including negated charging policy and the known store-path/PATH `hwclock` difference). |
| Legacy display compatibility | Old autosuspend and reader-session waveform self-heal (`6`), GC16 wash transient (`4`) and idlewasher legacy branch. The original forward-port waveform enum, replay policy, zero initialization and 250-ms banner are **retired-driver** checks; they do not describe the direct driver's production defaults. Replay's flash fraction still matches the live reader layer. |
| Config inventory | Legacy/boost key rosters, no-file defaults, boolean expressions, persistent paths, unmodeled record fields, and DMC's first-match selector/default-off/whitespace grammar. |

The checked values are an explicit source inventory in `audit.scm`, not
runtime defaults imported by the product. Both ends of a coupling are
pinned, so even coordinated changes require an intentional inventory update.
The direct driver's native hint and the service's optics override are
different layers, not an accidental divergence.

## Known inconsistencies versus regressions

`DEBT` annotations describe inherited observations: mixed case-sensitive
boolean grammars, runtime-only keys without records, the timesync fallback
path, and DMC whitespace handling. Different `enabled` defaults in different
files are intentional and file-scoped; their inconsistent parsing still
needs migration. `doc/configuration.md` §11 records exact current behavior.

A debt annotation owns an **exact value/cardinality**, not a blanket
exemption for that site. Changed debt or a paid-off absence fails with
`DEBT CHANGED/stale inventory`. Retire the annotation when fixing the source;
do not expand it to excuse a new regression. The summary counts observations,
not distinct bugs (one inherited difference may have two pinned operands).

## Tests and limits

The Guile suite reads the source spans actually extracted, then independently
removes and changes **every observed member**. Negative assertions get
planted positive fixtures, with an obligation for every new absence rule.
It also checks missing source files, malformed defaults/tables, duplicates,
and comments pretending to supply missing sites. Tests mutate in-memory
source fixtures; an empty scratch directory exercises the real I/O failure
path. No copy of the whole checkout or subprocess per mutation is needed.

The Lua suite extracts and executes only the broker's config declarations
and `reload_config`, with virtual read-only files. It tests booleans (including
case and unrecognized tokens), numeric boundaries, fractional/exponential
values, the existing unbounded backstop, missing files, duplicates, unknown
keys, obsolete idle, last-writer precedence and removal restoring defaults.
It never loads the broker's FFI, display, clocks or event loop. This avoids
coupling to unrelated broker work.

This is a narrow source audit, not a complete Scheme/Lua/C parser or a proof
of hardware behavior. Extractors require their sites and cardinality; Scheme
defaults use Guile's reader without evaluation. A small comment lexer keeps
prose out of code observations; unsupported block-comment forms fail rather
than guessing. Source refactors may require extractor changes and new
fixtures. Whole-project syntax, service serialization and runtime behavior
outside configuration belong to their existing suites.
