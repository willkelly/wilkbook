# Attempt 2 evidence (2026-08-02 03:50, UART live)

On-disk half, harvested from os2's `/tmp` by mounting `/dev/mmcblk0p6`
read-only from os1 after the hang. All 8 files verified **byte-identical**
to the device copies (sha256) before the mount was released.

The UART half is `../uart-deep-entry-trace.log`. **The two stitch into a
gapless timeline** — which is the point of running both channels:

| source | covers | ends/begins at |
| --- | --- | --- |
| on-disk `dmesg-pre.txt` | boot → gadget quiesce | `[435.236920] dwc3 … ep0 out start transfer failed: -110` |
| UART capture | suspend entry → firmware handoff | `[439.643831] PM: suspend entry (deep)` … `abcdeghij7` |

`ladder.log` ends at the suspend write, exactly as in attempt 1:

```
[03:50:50] pre: irq=640 fb0.state=0 crtc_active=1 VCOM=8f
[03:50:53] CONTROL PASS: 46 frames before any suspend
[03:50:55] post-blank: crtc_active=0 irq=686
[03:51:00] alarm armed=1785642720 now=1785642660 (+60s absolute epoch)
[03:51:00] --- RUNG 3: echo mem > /sys/power/state  (mode=deep)
```

`rung3.err` is 0 bytes. Nothing after the suspend write ever ran.

Note the control painted **46** frames here versus **38** in the s2idle
runs earlier the same night. Both are one full pass — the phase count is
temperature-compensated (GC16/GL16 are both 46 phases at 23 °C per
`doc/refresh-policy.md`), so the panel had cooled. Not a defect, and a
useful reminder that raw frame counts are only comparable within a
thermal window.

Reminder that made this harvest possible at all: **Guix wipes `/tmp` on
boot**, so booting os2 would have destroyed this. Harvest from os1 first,
always.
