# Standby power A/B — 2026-08-02

**Deep suspend draws 19.3 mA, giving ~8.6 days of standby from a full
4000 mAh charge — 9.1x lower than awake-idle.**

```
awake-idle : 174.8 mA over 900s    (2651896 -> 2608208 uAh)
deep       :  19.3 mA over 2700s   (2608208 -> 2593760 uAh)
deep standby from 4000 mAh full: 8.6 days (207.3 h)
```

Measured unplugged (`rk817-charger/online = 0`, asserted before starting —
the UART cable supplies no power), from the PMIC coulomb counter
(`charge_now`, µAh), which keeps counting while the SoC is powered down.

**Both phases ran in identical device state** — reader stopped, fbcon
unbound, panel blanked, USB gadget quiesced — so the only variable is
whether the CPU was running. That is what `doc/power-management.md`
requires before any battery claim.

## What this does and does not say

**Does**: deep is worth having. A 9x reduction turns "dead overnight" into
"a week in a bag", which is the difference between a device you carry and
one you don't. It also validates the whole activation chain as
*worthwhile*, not merely working.

**Does not**:

- **This is not a battery-life figure for the product.** It is standby
  only, with the reader stopped and the panel blanked. Real use adds
  wake-ups, page turns, Wi-Fi, and frontlight.
- **Awake-idle at 174.8 mA is itself a target, not a baseline to accept.**
  That is ~23 h from full doing nothing with the screen blanked, which is
  poor — the awake-power program (`conservative` governor, selected
  2026-07-25) has more to give, and 174.8 mA suggests something is busy
  that need not be. Worth a separate look; it is the number that dominates
  any hour the device is on.
- One measurement of each phase. Repeat before quoting.
- The 4000 mAh figure is `charge_full` as reported by the gauge, not a
  measured cell capacity.

## Caveat on gauge resolution

The deep phase moved 14,448 µAh over 45 minutes — comfortably above noise,
so the 19.3 mA is trustworthy. A shorter dwell would not have been: at this
draw a 5-minute sample moves ~1,600 µAh, which is close enough to gauge
granularity to mislead. Prefer dwells of 30 min or more.
