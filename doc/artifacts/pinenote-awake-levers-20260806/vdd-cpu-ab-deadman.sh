#!/usr/bin/env bash
# vdd_cpu (TCS4525 @ i2c0/0x1c) force-PWM vs auto-PFM/PWM A/B with dead-man
# auto-revert.  PineNote rk3566, wilkbook reader image, kernel 7.0.11.
#
# What it does (default WINDOW=900):
#   clamp DVFS to 408 MHz -> phase A 900 s (force-PWM baseline, clamped)
#   -> clear COMMAND(0x14) bit6 (enable chip's automatic PFM/PWM)
#   -> phase B 900 s -> restore exact original 0x14 byte -> phase A2 900 s
#   -> unclamp.  Battery current sampled every 15 s with phase tags.
#
# Safety:
#   - Every step is RMW on bit 0x40 of reg 0x14 only; VSEL/TIME never touched.
#   - Preflight aborts (touching nothing) unless chip ID == TCS4525, bit6 is
#     currently set, and the active-VSEL model checks out (reg 0x10 NSEL
#     matches the regulator framework's microvolts).
#   - trap-based revert on EXIT/INT/TERM/HUP.
#   - An INDEPENDENT detached fallback process unconditionally restores the
#     original 0x14 byte and the cpufreq clamp at T+(3*WINDOW+600) s, so the
#     revert survives this script dying, OOM, or SSH loss.
#   - The kernel provably never writes 0x14 at runtime (fan53555.c: DVFS is
#     confined to 0x10 mask 0x7F), so RMW here cannot race anything.
#
# Run as root, fully detached:
#   setsid /root/vdd-cpu-ab-deadman.sh </dev/null >/dev/null 2>&1 &
# Log: /root/vdd-cpu-ab.<epoch>.log

set -u

BUS=0
ADDR=0x1c
REG_ID1=0x03
REG_VSEL1=0x10          # active voltage register (bit7=EN, 6:0=NSEL)
REG_CMD=0x14            # mode register; bit6 = force-PWM for VSEL1
BIT=0x40
WINDOW="${WINDOW:-900}"
CLAMP_KHZ="${CLAMP_KHZ:-408000}"
POL=/sys/devices/system/cpu/cpufreq/policy0
LOG="${LOG:-/root/vdd-cpu-ab.$(date +%s).log}"

log() { printf '%s %s\n' "$(date +%s.%N)" "$*" >>"$LOG"; }

rd()  { i2cget -f -y "$BUS" "$ADDR" "$1"; }
wr()  { i2cset -f -y "$BUS" "$ADDR" "$1" "$2"; }

# ---------- locate vdd_cpu regulator sysfs (live hardware opmode) ----------
REGDIR=""
for d in /sys/class/regulator/regulator.*; do
    [ -r "$d/name" ] || continue
    if [ "$(cat "$d/name")" = "vdd_cpu" ]; then REGDIR="$d"; break; fi
done

opmode()    { [ -n "$REGDIR" ] && cat "$REGDIR/opmode" 2>/dev/null || echo "?"; }
microvolts(){ [ -n "$REGDIR" ] && cat "$REGDIR/microvolts" 2>/dev/null || echo 0; }

fatal_pre() { log "ABORT-PREFLIGHT: $*"; exit 1; }   # nothing changed yet

# ------------------------------- preflight --------------------------------
command -v i2cget >/dev/null && command -v i2cset >/dev/null \
    || { echo "i2c-tools missing" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
: >>"$LOG" || { echo "cannot write $LOG" >&2; exit 1; }

log "start pid=$$ window=${WINDOW}s clamp=${CLAMP_KHZ}kHz"

ID1=$(rd $REG_ID1) || fatal_pre "i2c read ID1 failed"
[ $(( ID1 & 0x0f )) -eq 12 ] || fatal_pre "chip id $ID1 not TCS4525 (want low nibble 0xC)"

ORIG=$(rd $REG_CMD)  || fatal_pre "i2c read 0x14 failed"
sleep 0.2
ORIG2=$(rd $REG_CMD) || fatal_pre "i2c re-read 0x14 failed"
[ "$ORIG" = "$ORIG2" ] || fatal_pre "unstable 0x14 reads: $ORIG vs $ORIG2"
[ $(( ORIG & BIT )) -ne 0 ] || fatal_pre "0x14=$ORIG bit6 already clear; premise wrong"
log "preflight ID1=$ID1 CMD(0x14)=$ORIG (bit7=$(( (ORIG>>7)&1 )) bit6=$(( (ORIG>>6)&1 )))"

[ -n "$REGDIR" ] || fatal_pre "vdd_cpu regulator sysfs not found"
[ "$(opmode)" = "fast" ] || fatal_pre "opmode is '$(opmode)', expected fast"

V10=$(rd $REG_VSEL1) || fatal_pre "i2c read 0x10 failed"
[ $(( V10 & 0x80 )) -ne 0 ] || fatal_pre "VSEL1 EN bit clear?! 0x10=$V10"
UV_HW=$(( 600000 + (V10 & 0x7f) * 6250 ))
UV_FW=$(microvolts)
DIFF=$(( UV_HW - UV_FW )); [ $DIFF -lt 0 ] && DIFF=$(( -DIFF ))
[ $DIFF -le 6250 ] || fatal_pre "active-VSEL model mismatch: reg0x10=$V10 (${UV_HW}uV) vs framework ${UV_FW}uV"
log "preflight VSEL1(0x10)=$V10 hw=${UV_HW}uV fw=${UV_FW}uV opmode=fast — model confirmed"

# ------------------------- clamp DVFS (mandatory) -------------------------
MAXSAVE=$(cat "$POL/scaling_max_freq") || fatal_pre "no cpufreq policy0"
echo "$CLAMP_KHZ" > "$POL/scaling_max_freq" || fatal_pre "clamp write failed"
sleep 3
CUR=$(cat "$POL/scaling_cur_freq")
if [ "$CUR" -gt "$CLAMP_KHZ" ]; then
    echo "$MAXSAVE" > "$POL/scaling_max_freq"
    fatal_pre "clamp ineffective (cur=$CUR); restored max_freq"
fi
log "clamped: max_freq $MAXSAVE->$CLAMP_KHZ cur=$CUR uV=$(microvolts) VSEL1=$(rd $REG_VSEL1)"

# ---------------- revert machinery (from here we may mutate) ---------------
REVERTED=0
revert() {
    # Idempotent: restore exact original 0x14 byte, verify, unclamp.
    wr $REG_CMD "$ORIG"
    RB=$(rd $REG_CMD)
    echo "$MAXSAVE" > "$POL/scaling_max_freq" 2>/dev/null
    if [ "$RB" = "$ORIG" ]; then
        [ "$REVERTED" = 1 ] || log "REVERTED 0x14=$RB opmode=$(opmode); max_freq restored to $MAXSAVE"
        REVERTED=1
    else
        log "REVERT-VERIFY-FAILED wrote $ORIG read $RB — retrying once"
        wr $REG_CMD "$ORIG"; log "retry readback=$(rd $REG_CMD)"
    fi
}
trap 'log "trap fired"; revert; exit 1' INT TERM HUP
trap 'revert' EXIT

# Independent fallback: survives this script's death.  Restoring the same
# byte twice is harmless (kernel never writes 0x14).
DEADLINE=$(( 3 * WINDOW + 600 ))
setsid bash -c "
    sleep $DEADLINE
    i2cset -f -y $BUS $ADDR $REG_CMD $ORIG
    echo \$(date +%s.%N) 'FALLBACK fired: 0x14 restored to $ORIG, readback' \$(i2cget -f -y $BUS $ADDR $REG_CMD) >> '$LOG'
    echo $MAXSAVE > $POL/scaling_max_freq
" </dev/null >/dev/null 2>&1 &
FBPID=$!
log "fallback reverter pid=$FBPID deadline=+${DEADLINE}s"

# ------------------------- battery current sampler -------------------------
PSDIR=""
for p in /sys/class/power_supply/*/current_now; do
    [ -r "$p" ] && PSDIR="${p%/current_now}" && break
done
PHASEFILE=$(mktemp /tmp/vddcpu-phase.XXXXXX); echo A >"$PHASEFILE"
if [ -n "$PSDIR" ]; then
    ( while :; do
        printf '%s sample phase=%s current_now=%s voltage_now=%s\n' \
          "$(date +%s.%N)" "$(cat "$PHASEFILE")" \
          "$(cat "$PSDIR/current_now" 2>/dev/null)" \
          "$(cat "$PSDIR/voltage_now" 2>/dev/null)" >>"$LOG"
        sleep 15
      done ) &
    SAMPPID=$!
else
    SAMPPID=""
    log "no power_supply current_now found; external measurement required"
fi

# --------------------------------- phases ---------------------------------
log "PHASE-A start (force-PWM baseline, clamped) ${WINDOW}s 0x14=$(rd $REG_CMD) opmode=$(opmode)"
sleep "$WINDOW"

NEWVAL=$(( ORIG & ~BIT ))
wr $REG_CMD "$NEWVAL"
RB=$(rd $REG_CMD)
if [ $(( RB & BIT )) -ne 0 ] || [ "$(opmode)" != "normal" ]; then
    log "POKE-VERIFY-FAILED wrote $NEWVAL read $RB opmode=$(opmode) — reverting now"
    exit 1        # EXIT trap reverts
fi
echo B >"$PHASEFILE"
log "PHASE-B start (auto PFM/PWM) ${WINDOW}s 0x14=$RB opmode=normal"
sleep "$WINDOW"

revert
[ "$REVERTED" = 1 ] || { log "revert not confirmed — leaving fallback armed"; exit 1; }
[ "$(opmode)" = "fast" ] || log "WARNING: opmode after revert is $(opmode)"
# re-clamp for symmetric tail phase (revert() restored max_freq)
echo "$CLAMP_KHZ" > "$POL/scaling_max_freq"
echo A2 >"$PHASEFILE"
log "PHASE-A2 start (post-revert baseline) ${WINDOW}s 0x14=$(rd $REG_CMD) opmode=$(opmode)"
sleep "$WINDOW"

# ------------------------------- clean finish ------------------------------
[ -n "$SAMPPID" ] && kill "$SAMPPID" 2>/dev/null
kill "$FBPID" 2>/dev/null    # fallback no longer needed (firing would be harmless)
rm -f "$PHASEFILE"
echo "$MAXSAVE" > "$POL/scaling_max_freq"
log "done: 0x14=$(rd $REG_CMD) opmode=$(opmode) max_freq=$(cat "$POL/scaling_max_freq")"
trap - EXIT
exit 0
