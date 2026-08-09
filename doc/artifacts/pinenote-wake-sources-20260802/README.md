# Power-button wake from deep — 2026-08-02

The supervised test proving a **human can wake the device from platform
deep suspend with the power button** — the gate for enabling any
auto-suspend at all. Without this proof, an idle timer that suspends the
device would have been a timer that bricked it until the RTC backstop.

`wake-test.sh` quiesced the reader and the USB gadget, armed a +90 s RTC
backstop as the safety net, and entered deep. The operator pressed the
power button; the device resumed at **35 s** — well before the backstop
— and `wake.log` is the unedited record. PASS.

Context: the 2026-08-02 deep-suspend program (`doc/power-management.md`,
and the `doc/status.md` entries of that date). This artifact predates
ultra suspend; under the 2026-08-08 rails-off configuration the power
button remains a wake source (it is rk817-internal), re-proven in R12
(`../pinenote-ultra-r12-20260808/`).
