# Recording your PineNote's display — a contributor's guide

Thank you for helping! Every PineNote ships its **own** waveform calibration, so
a display fix tuned against one panel overfits. If you own a PineNote and *any*
camera — even a phone — you can record a short, self-describing clip of your
panel and send it back, and we can measure its optical defects (black flash,
ghosting, slow settle, …) against everyone else's. You need **no** analysis
tools; you record, we analyze.

You will produce a **bundle**: a small folder holding your capture video plus a
little metadata. Zip it and send it. That's it.

> **Privacy / firmware note.** We never want your raw waveform file (`ebc.wbf`) —
> it's per-device calibration firmware. The bundle only carries a *decoded
> summary* of it (mode/phase counts), and the tools refuse to package a `.wbf`.
> Nothing else on your device is collected.

---

## 1. The rig

The whole trick is that the test card calibrates itself from markers baked into
every page, so you do **not** need a lab. You need three things stable for the
length of one recording: the light, the camera, and the panel.

- **Light — use the PineNote's own frontlight, nothing else.** The frontlight is
  the standardized illuminant that makes your capture comparable to other
  contributors' (no room lamp to calibrate). Turn *off* room lights and avoid
  windows/sun. Set the frontlight to a **steady, moderate level — around 50–70%
  (aim for ~60%)** — bright enough for the camera, not so bright it clips to pure
  white. Warm/cool tone doesn't matter; just don't change it mid-recording.
- **Enclosure — put the device in a box.** Lay the PineNote flat, screen up,
  inside a cardboard box or under a cloth tent that blocks ambient light and
  stray reflections. Matte, dark surroundings are ideal (the analyzer keys off
  the dark bezel around the bright panel).
- **Camera — mount it directly above, looking straight down.** A phone on a
  tripod/gooseneck, or a webcam clamped over the box. Frame so the **entire
  panel and all four corner markers are visible with a little margin** all
  around — the four corner fiducials are how we correct for your camera's angle
  and any handheld shake, so if a corner is cut off that page is unusable. A
  slight tilt is fine (we rectify it); a cropped corner is not.

### Lock the camera down (this matters most)

Auto-anything will chase the black flash and ruin the measurement. Before
recording, set and **lock**:

- **Exposure / ISO — manual and locked.** No auto-exposure. Expose so the white
  patches are bright but not blown out (not a flat 255).
- **Focus — manual and locked** on the panel surface.
- **White balance — manual/locked** (any fixed value; we normalize color to gray).
- **Frame rate — 30 or 60 fps.** Higher is better for catching the flash; 30 is
  fine. Turn **HDR off**, and turn off any "beauty"/denoise/auto-scene modes.
- Resolution: 1080p is plenty. Keep the panel filling most of the frame.

On most phones: use the camera's Pro/Manual video mode, tap-and-hold to lock
AE/AF, then set WB to a fixed preset. A cheap webcam driven with locked settings
(e.g. `v4l2-ctl`) beats a phone on the subtlest cases, but a locked phone is
genuinely good enough.

---

## 2. What to record

Open the test card — **`optics-testcard.epub`** — in KOReader on the device.
(We provide it, or build it with `make testcard`; it's a fixed-layout epub, one
image per page.) In KOReader turn off any page-turn animation and set it to show
one full page per turn.

Then, with the camera already rolling:

1. Let the **opening flashes** play: the card starts with a few full-screen
   black↔white pages. Page through them at the very start — they zero our clock,
   so we don't need your camera's timecode.
2. **Page through the rest at a steady, unhurried pace** — roughly **one page
   every 1–2 seconds**, and *pause* on each page long enough for it to fully
   settle before the next turn (a beat after it stops changing). Go all the way
   to the end.
3. Stop the recording.

That single pass is one **run**. If you're comfortable changing `rockchip_ebc`
parameters (waveform mode, dithering, etc.), you can do several passes — one per
setting — and note which pass used which parameters; otherwise one default pass
is perfectly useful.

> **Coming soon: an automatic player.** A script (`recorder.py record`) will
> drive KOReader over the network — flipping parameters, paging, emitting the
> sync flashes, and logging every timestamp for you — so all you do is film. It's
> waiting on the device's Wi-Fi/networking story. Until then, the manual pass
> above is the way, and you package it yourself (next section).

---

## 3. What to send back

Package your capture into a bundle with the helper (run wherever you copied the
files off the device — it needs only Python; ffmpeg optional):

```sh
python3 recorder.py package \
    --bundle my-pinenote-bundle \
    --video  path/to/your-capture.mp4 \
    --manifest manifest.json \
    --model PineNote --frontlight-level 60 \
    --panel-temp 24 \            # if you know it (optional)
    --page-period 1.5 \          # your seconds-per-page pace
    --zip
```

That writes `my-pinenote-bundle/` (and a `.zip` to send) containing exactly:

- `capture.<ext>` — your video, copied in.
- `manifest.json` — the test card's marker/page description (ships with the card).
- `session.json` — the metadata: your device model, frontlight level, panel
  temperature if known, any `rockchip_ebc` params, and the page timeline.

If you're comfortable running the waveform inspector on-device, also grab its
**text** output and pass it so we can bin your results by your panel's timings —
this reads the decoded summary only, never copies the `.wbf`:

```sh
# on the device (or from a copied-off .wbf), capture wbf-info's printout:
wbf-info /lib/firmware/rockchip/ebc.wbf 28 > wbfinfo.txt
# then add to the package command:
    --wbf-info wbfinfo.txt --wbf-temp 28 --wbf-sha256 "$(sha256sum ebc.wbf | cut -d' ' -f1)"
```

**Send us the `.zip`.** Do **not** send `ebc.wbf` itself — the tooling won't
package it, and we don't want it. Multiple passes / multiple devices: one bundle
each, please.

That's everything. Thank you — your panel makes the whole dataset better.
