#!/bin/sh
# Is the cover switch wired, and does it move?
set -u
N=/proc/device-tree/gpio-keys/switch-cover

echo "=== DT node contents:"
for f in "$N"/*; do
    b=$(basename "$f")
    printf '  %-18s ' "$b"
    case $b in
        label|name) tr -d '\0' < "$f"; echo ;;
        *) od -An -tx1 "$f" | tr -s ' ' | head -1 ;;
    esac
done

echo "=== resolved gpio (phandle + pin + flags), and its live value if readable:"
if [ -e "$N/gpios" ]; then
    od -An -tu4 --endian=big "$N/gpios" 2>/dev/null | tr -s ' ' \
        | awk '{printf "  phandle=%s pin=%s flags=%s\n", $1, $2, $3}'
fi

echo "=== gpiochip lines mentioning the switch (needs gpioinfo):"
if command -v gpioinfo >/dev/null 2>&1; then
    gpioinfo 2>/dev/null | grep -i -B1 -A1 "cover\|gpio-keys" | head -10
else
    echo "  (no gpioinfo)"
fi

echo "=== debugfs gpio view:"
if [ -r /sys/kernel/debug/gpio ]; then
    grep -i -A2 "cover\|gpio-keys" /sys/kernel/debug/gpio | head -10
    echo "  --- gpio0 bank summary:"
    sed -n '/gpiochip0/,/gpiochip1/p' /sys/kernel/debug/gpio | head -12
else
    echo "  (no /sys/kernel/debug/gpio)"
fi

echo "=== irq for gpio-keys (a wired switch has one; count tells us if it ever fired):"
grep -i "gpio-keys\|switch-cover" /proc/interrupts || echo "  no gpio-keys IRQ line in /proc/interrupts"
