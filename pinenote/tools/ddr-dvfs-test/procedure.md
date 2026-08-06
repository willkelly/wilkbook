# Supervised DDR DVFS first-light procedure (ddr-dvfs-test.ko)

For the main agent. This is a hardware session with a real (small but
nonzero) hang risk at exactly one step; everything before and after that
step is read-only or reversible. Read `protocol.md` first. The module is
`ddr-dvfs-test.ko` (sha256
`e720c6fe087bf737b050b73a175c50eaf18cc68dbe1c9023be42dc2dffd78486`), built
from `src/` against the exact running kernel
`/gnu/store/s7gam9gnmhjzf854b8j1jd4nxy35qxq8-linux-pinenote-7.0.11-pinenote`
(vermagic `7.0.11 SMP preempt_rt mod_unload modversions aarch64`; all 31
MODVERSIONS CRCs verified against that kernel's Module.symvers).

## The honest worst case, up front

`SET_RATE` retrains the DRAM the kernel is executing from. If the firmware
sequence goes wrong, the SoC stops mid-SMC: no oops, no log, UART goes
silent right after the announced "issuing SMC now" line. Recovery is a
**PMIC long-press power-cycle** (hold the power button ~8 s), and the
session is over. That is why: UART attached and proven live, user present,
filesystems synced, EBC idle, and the first target is the **lowest**
supported rate with everything quiesced. If a hang happens: power-cycle,
**boot os1 first** (booting os2 wipes its /tmp evidence — memory note
2026-08-02), harvest `/dev/mmcblk0p6` logs read-only, then report. Do not
retry the SET_RATE in the same session.

Bounded sub-cases that are NOT the worst case: firmware rejects the call
(a0 < 0 — collect and stop, nothing changed); verify mismatch (rate readable
but wrong — rmmod will attempt restore); module refuses (EPERM/EINVAL —
your command was wrong, nothing was issued).

## Preconditions (all must hold before insmod)

1. **User informed and present.** This session issues the first-ever DDR
   SIP writes on this device.
2. **UART attached and proven live** — not a passive listen: transmit a
   marker from the device and see it on the host
   (`stty -F /dev/ttyS2 1500000` on the device first; host
   `stty -F /dev/ttyUSB0 1500000 cs8 -cstopb -parenb -crtscts clocal -echo raw`
   — the 9600-default trap, memory `pinenote-device-access`). Keep
   `cat /dev/ttyUSB0 > uart-session.log` running for the whole session.
   Kernel console messages must reach it (`dmesg -n 7` or check
   `console=` on cmdline) so a hang postmortem shows the last announced SMC.
3. **On battery**: charger/ACM USB cable disconnected (needed for the
   coulomb windows anyway). UART cable stays — it does not power the device;
   both ABBA leg types share the condition so the differential is clean.
4. **Correct kernel**: `uname -r` → `7.0.11`; confirm the running system is
   the deployed image whose kernel is the s7gam9gn store item.
5. **No suspend possible while the module is loaded at a non-boot rate**:
   the image has no autosuspend (suspend is deliberately disabled), but
   verify nothing is armed: `cat /sys/power/autosleep` (absent/`off`), no
   pending rtcwake, and do not run any suspend experiment this session.
6. **EBC quiesced** (barrier-campaign discipline,
   `doc/hardware-deploy.md:139-145,178-180`):

   ```sh
   sudo herd stop reader-session
   echo 0 | sudo tee /sys/class/vtconsole/vtcon1/bind   # stop re-binds fbcon
   pgrep -af 'reader[.]lua'          # must print nothing
   ps -o stat= -C ebc-refresh        # must be I, not D (teardown takes a few s)
   # EBC IRQ delta over 6 s must be exactly 0:
   grep -i ebc /proc/interrupts; sleep 6; grep -i ebc /proc/interrupts
   ```
7. **Module staged and verified**:

   ```sh
   scp ddr-dvfs-test.ko root@<pinenote-reader>:/tmp/
   ssh root@<pinenote-reader> sha256sum /tmp/ddr-dvfs-test.ko
   # expect e720c6fe087bf737b050b73a175c50eaf18cc68dbe1c9023be42dc2dffd78486
   ```
8. `sync` on the device.

## Step A — read-only load: table + original rate (no set capability)

```sh
sync
insmod /tmp/ddr-dvfs-test.ko          # allow_set defaults to 0
dmesg | grep ddr_dvfs_test
```

This performs, in the BSP's exact order (each SMC announced in dmesg
*before* it is issued): GET_VERSION → GET_RATE → SHARE_MEM(2 pages, DDR) →
map → zero → **DRAM_INIT** → GET_FREQ_INFO → GET_RATE. `allow_set=0` means a
write to `set_rate` does nothing (EPERM) — this insmod cannot change the
rate no matter what.

DRAM_INIT is the one call here that is more than a query. It is the first
call of every BSP boot on every rk3568-family board, issued against a zeroed
share page exactly as we issue it, but it has never run on *this* device.
Watch the UART when its announcement scrolls past. (An extra-cautious
variant exists — `insmod ... dram_init=0` skips it and hard-disables
set_rate — but that probes a call ordering no BSP kernel ever uses, so the
default BSP-faithful order is the recommended path.)

**Good** looks like:

```
ddr_dvfs_test: DDR ATF version 0x101
ddr_dvfs_test: share page phys 0x......, mapping
ddr_dvfs_test: DRAM_INIT ok
ddr_dvfs_test: freq_table[0] = ... MHz
...
ddr_dvfs_test: original rate 1056000000 Hz (1056 MHz)
ddr_dvfs_test: loaded; set_rate disarmed (allow_set=0)
```

Then read everything back:

```sh
cat /sys/kernel/debug/ddr-dvfs-test/status
cat /sys/kernel/debug/ddr-dvfs-test/freq_table
cat /sys/kernel/debug/ddr-dvfs-test/current      # expect 1056 MHz
```

**Decision gate:**

- `GET_FREQ_INFO failed` or `freq_count` invalid, or the table has a single
  entry (just the boot rate): **the experiment is over, successfully** — the
  firmware answer is "no alternate setpoints were trained by this device's
  DDR blob". rmmod, restart the reader, record the result. No SET_RATE.
- Table has >= 2 entries and `original rate` matches a table entry
  (expected: 1056 at the top): proceed.
- Anything hung: worst-case protocol above.

Record verbatim: version, table, original rate, share phys.

## Step B — arm and issue the single supervised SET_RATE

Re-load with the set path armed (rmmod prints that no restore was needed):

```sh
rmmod ddr_dvfs_test
sync
insmod /tmp/ddr-dvfs-test.ko allow_set=1
cat /sys/kernel/debug/ddr-dvfs-test/status    # set_enabled 1, allow_set 1
```

Re-verify the EBC idle check (precondition 6) *immediately* before the
write — this is the one moment that matters. Then, with eyes on the UART:

```sh
sync
echo <LOWEST-TABLE-MHZ> > /sys/kernel/debug/ddr-dvfs-test/set_rate
```

The module refuses anything not exactly in the firmware's table, and
cross-checks ROUND_RATE first. **The first SET_RATE ever on this device
targets the lowest supported rate, with everything quiesced.** Do not try an
intermediate rate first, do not toggle rapidly.

**Good** (synchronous path):

```
ddr_dvfs_test: SET_RATE -> ...000000 Hz issuing SMC now (t=...)
ddr_dvfs_test: SET_RATE SMC returned a0=0 a1=0 after ... us
ddr_dvfs_test: SET_RATE done: GET_RATE now ... Hz (wanted ...) total ... us
```

**Good** (MCU path — equally fine): the same, with
`firmware deferred to DDR MCU; MCU_START + 100 ms wait` in between and
`a1=-6` in the SMC-returned line.

Immediately after: `cat .../current` (must show the new rate), check the
system is alive (SSH responsive, `dmesg` clean of new errors, memory sane —
run `sha256sum /tmp/ddr-dvfs-test.ko` again as a cheap DRAM-integrity
smoke test; it must still match).

**Bad**:

- `REFUSED` lines — the module blocked it; fix the command, nothing was
  issued to firmware.
- `SET_RATE rejected by firmware (a0=-2/-3/-5)` — record, do NOT retry with
  other values; rmmod (harmless — nothing changed), report. This outcome
  likely means v0x101 on this bl31 wants something we haven't given it.
- `VERIFY MISMATCH` — rate is not what we asked. Proceed directly to
  Step D revert; the module's rmmod restore is the backstop.
- Silence — worst-case protocol.

## Step C — measurement (ABBA vs original rate, coulomb method)

Only if Step B succeeded and the system is stable after a 2-minute soak.
Uses the proven rk817 `charge_now` differential method
(`doc/power-management.md:700-756`): interval-equivalent current over fixed
untouched windows; the governor ABBA resolved a 22 mA effect with 3-minute
legs, and 0.78 mA was below resolution — so expect to resolve the "tens of
mA" class, not single mA.

- Legs: **A = 1056 MHz (original), B = lowest rate**, order **A-B-B-A**.
  The rate for each leg is set via the same `set_rate` file (each change is
  one more supervised SET_RATE — keep the EBC idle throughout the session,
  which also makes this a clean *idle* measurement, where DDR frequency
  matters most).
- Each leg: >= 5 minutes untouched — no SSH traffic during the window
  (snapshot `charge_now` + timestamp, disconnect, reconnect after the
  window), frontlights at zero, Wi-Fi in the same state for all legs,
  reader stopped, fbcon unbound.
- Record per leg: `charge_now` before/after, wall time, `current` readback
  at start and end (rate must not have drifted), temperature if convenient.
- Report the repeated means as in the governor ABBA table. This is a
  first-light differential, not a battery-life estimate.

## Step D — revert and unload

```sh
# explicit restore first (belt), module rmmod restore is braces:
echo <ORIGINAL-MHZ> > /sys/kernel/debug/ddr-dvfs-test/set_rate
cat /sys/kernel/debug/ddr-dvfs-test/current    # must be the original rate
sync
rmmod ddr_dvfs_test                            # prints restore status
dmesg | tail -20
```

EBC must still be idle at rmmod time (the module's exit restore path, if it
fires, is one more SET_RATE — same rule, and the module does not check for
you). Only after rmmod:

```sh
echo 1 | sudo tee /sys/class/vtconsole/vtcon1/bind
sudo herd start reader-session
```

Confirm the reader repaints normally (one clean pass), and that dmesg shows
no EBC timeout/poison lines. If the explicit restore FAILED and rmmod's
restore also failed, the device is running at a non-boot rate with no module
loaded: do not suspend, finish collecting evidence, and reboot (a reboot
fully resets the DDR state — the boot chain retrains at 1056 MHz).

## Afterwards

- Save: full dmesg, the UART log, the debugfs snapshots, the ABBA numbers.
- Update `doc/status.md` (repo rule: hardware truth after every session):
  firmware table, which SET_RATE path fired (sync vs MCU), the measured
  differential, and the explicit statement that the rate was restored and
  verified before rmmod.
- The module taints the kernel (flag O) — cosmetic, clears on reboot.
- Re-insmod in a later session is safe: the firmware returns the same share
  page (no release call exists; see protocol.md §1).
