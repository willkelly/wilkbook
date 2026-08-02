# SIP-sequence differential: our emitter vs the BSP — 2026-08-02

**Result: byte-for-byte identical for the real device policy, including two
behaviours that are easy to get wrong.** This was the highest-risk
assumption blocking activation: before handing firmware a configuration
sequence, prove it is the same sequence the known-working kernel sends.

## Reference (independent, derived from the BSP source — not copied)

`rockchip_pm_config.c` from hrdl's `v6.19_rk_suspend_driver`
(`scratchpad/hrdl/v6.19_rk_suspend_driver__rockchip_pm_config.c`, 291
lines) with control codes from its `rockchip_sip.h`:

| control | code |
| --- | --- |
| `SUSPEND_MODE_CONFIG` | `0x01` |
| `WKUP_SOURCE_CONFIG` | `0x02` |
| `PWM_REGULATOR_CONFIG` | `0x03` |
| `GPIO_POWER_CONFIG` | `0x04` |
| `SUSPEND_DEBUG_ENABLE` | `0x05` |
| `APIOS_SUSPEND_CONFIG` | `0x06` |
| `VIRTUAL_POWEROFF` | `0x07` |
| `LINUX_PM_STATE` | `0x09` |

`#define PM_INVALID_GPIO 0xffff` (`:25`). `int i = 0;` at `:164`.

`pm_config_probe()` emits, for a node carrying **only** the three
properties the PineNote actually has (measured from os1's booted DTB,
`doc/artifacts/pinenote-os1-suspend-policy-20260802/`):

1. `SUSPEND_MODE_CONFIG, 0x5ec, 0` — `sleep-mode-config` present
2. `WKUP_SOURCE_CONFIG, 0x10, 0` — `wakeup-config` present
3. *(`pwm-regulator-config` absent → `dev_warn`, no call)*
4. `GPIO_POWER_CONFIG, 0, 0xffff` — **unconditional**; the GPIO scan loop
   is commented out in the BSP, so `i` keeps its initial `0` and this
   degenerates to a bare terminator record
5. `SUSPEND_DEBUG_ENABLE, 0, 0` — guarded by `if (!of_property_read…)`,
   i.e. **presence**, not truth: it fires even though the value is `0`
6. *(`apios-suspend` absent → no call; `virtual-poweroff` commented out)*

Then separately at suspend time, `pm_config_prepare()` emits
`LINUX_PM_STATE, mem_sleep_current, 0` before touching regulator lists.

## Ours, for the same compiled donor DTB

`pinenote/tools/rockchip-pm/rockchip-pm-test.c::test_probe()` feeds the
compiled donor fixture through the production parser and builder and pins:

```c
expect(rockchip_suspend_model_build_probe(&policy, events, 4) == 4, …);
legacy(&events[0], 0x01, 0x5ec, 0);
legacy(&events[1], 0x02, 0x10,  0);
legacy(&events[2], 0x04, 0,     0xffff);
legacy(&events[3], 0x05, 0,     0);
```

## Verdict

| # | BSP reference | ours | |
| --- | --- | --- | --- |
| 1 | `0x01, 0x5ec, 0` | `0x01, 0x5ec, 0` | ✔ |
| 2 | `0x02, 0x10, 0` | `0x02, 0x10, 0` | ✔ |
| 3 | `0x04, 0, 0xffff` | `0x04, 0, 0xffff` | ✔ |
| 4 | `0x05, 0, 0` | `0x05, 0, 0` | ✔ |
| count | 4 | 4 | ✔ |

Both subtle behaviours are reproduced: the **unconditional GPIO
terminator** (trivially omitted if you only emit for properties that
exist) and **`SUSPEND_DEBUG_ENABLE` firing on presence rather than truth**
(trivially omitted if you skip zero values). Neither is guessable from the
binding docs; both come from reading the emitter.

## Caveats, stated

- The reference is hrdl's **v6.19** branch, while os1 runs **6.12**. Same
  BSP lineage, and the docs already establish hrdl's ultra delta in this
  file is 8 lines; the probe emitter is not where they diverge. A stricter
  check would read 6.12's own copy — os1 ships no kernel source, so that
  would mean fetching the exact Debian source package.
- This validates the **configuration sequence**, not that bl31 accepts it,
  and not the prepare-time regulator work. `LINUX_PM_STATE` numeric
  acceptance by the deployed 2022-06-09 bl31 remains unverified
  (`doc/power-management.md`).
- Our stack still does not *send* any of this: activation is compiled out
  and the production parser refuses a policy-bearing DT. That is the next
  change, and it is now the only untested step between here and deep.
