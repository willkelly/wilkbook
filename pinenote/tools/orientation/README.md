# orientation -- offline PineNote SC7A20 autorotation tests

`orientation-bridge.lua` finds the IIO device by exact `sc7a20` name, enables
coherent buffered X/Y/Z plus the timestamp scan element, and validates the
observed layout: indices 0/1/2 `le:s12/16>>4`, timestamp index 3
`le:s64/64>>0`, one 16-byte scan. It never reads independent axis sysfs files.

The bridge holds a standard-uinput device named `wilkbook-orientation` while
the sensor is transiently absent. It advertises only EV_SYN and EV_MSC/MSC_RAW;
KOReader translates valid values 0--3 at its private boundary. Hardware map:
top/-X -> mode 1, right/-Y -> 0, bottom/+X -> 3, left/+Y -> 2. The first
on-glass run established the physical Y-axis labels; a live +2-mode A/B then
proved these numeric modes by making the UI top follow the physical top edge.

The bridge waits for `/run/wilkbook-orientation.consumer` before sampling.
The PineNote target writes that marker only after opening the named evdev node,
so the initial committed orientation cannot be emitted before a reader exists.
Each commit is also mirrored in `/run/wilkbook-orientation.state`; re-enabling
KOReader's accelerometer handler replays that state, so a rotation made while
autorotation was disabled is not lost. If the bridge process dies, the evdev
backend treats loss of this required node as fatal. Shepherd then respawns both
ends independently: the bridge creates a replacement node and reader-session
restarts KOReader to enumerate it.

Run `make orientation-check`. It runs the ordinary offline parser/classifier
tests and, where `/dev/uinput` plus the created evdev node are accessible, a
production bridge self-test: it
creates `wilkbook-orientation`, checks its exact virtual identity and only
EV_SYN|EV_MSC/MSC_RAW capabilities, emits MSC_RAW mode 2 plus SYN_REPORT, reads
that frame from its own evdev node, then destroys it. Otherwise that portion
skips cleanly. This guards the 2026-07-18 hardware finding: the live node had
`capabilities/ev=11` but `capabilities/msc=0` because `0x4004556a` is
`UI_SET_SNDBIT`; its accepted writes were discarded. The KOReader harness
additionally tests state replay, required-device loss, source gating,
autorotation toggles, and contact deferral; rung 4 validates service ordering
and the named node without a real IIO sensor.
