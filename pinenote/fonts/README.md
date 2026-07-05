# Local fonts (never committed)

Licensed fonts staged for image builds, following the same pattern as
the per-device waveform: **local data the repo consumes but never
ships**. Everything under `local/` is gitignored.

## How it works

- Put font files (`.otf`/`.ttf`) in `pinenote/fonts/local/`. Flat is
  fine; subdirectories work too.
- If the directory exists and is non-empty at build time,
  `pinenote-local-fonts` (`pinenote/packages/fonts.scm`) packages it
  into the image at `share/fonts/local`, and the reader flavor's
  `reader-session` service points KOReader at it via `EXT_FONT_DIR`
  (KOReader's supported external-font mechanism — the fonts appear in
  its font menu automatically).
- If the directory is absent or empty, the build proceeds without it —
  a fresh clone builds fine.

The reader-session service also seeds the font defaults on first boot
(only when no KOReader settings exist yet; it never overwrites choices
made on the device), mirroring wilkhome's fontconfig aliases: book/serif
= Equity A, sans-serif = Concourse 4, monospace = Triplicate A Code.
KOReader's built-in fallback chain (Noto Serif/Sans, Noto CJK,
FreeSans/FreeSerif) remains in effect beneath these.

## Provenance (Will's setup)

The MB Type library (Equity, Century Supra, Valkyrie, Concourse,
Heliotrope, Triplicate — Matthew Butterick's commercial fonts, licensed
per person, not redistributable) lives in
`~/src/willkelly/wilkhome/guix-home/files/private-fonts/mbtype/`. A
curated OTF subset of the text/UI families is copied into `local/`;
re-run something like:

    cp "$HOME/src/willkelly/wilkhome/guix-home/files/private-fonts/mbtype/MB Type Library 250822/OTF font files (best for Mac OS)/Equity A"/*.otf pinenote/fonts/local/

per family to adjust the set.
