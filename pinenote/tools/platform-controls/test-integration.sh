#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)
package=$repo/pinenote/packages/platform-controls.scm
service=$repo/pinenote/services/platform-controls.scm
reader=$repo/pinenote/services/reader-session.scm
system=$repo/pinenote/systems/pinenote-reader.scm
device=$repo/pinenote/packages/koreader-device/frontend/device/pinenote/device.lua

grep -q 'pinenote-power-broker.lua' "$package"
grep -q 'pinenote-wifi-control' "$package"
grep -q "(respawn? #t)" "$service"
grep -q 'WILKBOOK_KOREADER_ROOT=' "$service"
grep -q 'WILKBOOK_WIFI_CONTROL=' "$service"
grep -q "(provision '(pinenote-platform-controls))" "$service"
echo "PASS: Phase 2 packages and supervises the accepted broker"

grep -q 'pinenote-platform-controls' "$reader"
grep -q 'pinenote-platform-controls did not become ready' "$reader"
grep -q 'wilkbook-power-control' "$reader"
echo "PASS: reader-session requires broker readiness and its named input node"

grep -q '(service pinenote-platform-controls-service-type)' "$system"
! grep -q '(service pinenote-autosuspend-service-type)' "$system"
! grep -q 'WILKBOOK_PINENOTE_VALIDATION' "$device"
grep -q '/run/current-system/profile/bin/pinenote-wifi-control' "$device"
echo "PASS: production reader uses platform controls without the early patch or legacy daemon"
