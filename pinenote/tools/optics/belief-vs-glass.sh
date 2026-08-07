#!/bin/sh
# Render what the DRIVER BELIEVES it painted next to what the GLASS
# actually shows.  The operator's idea, 2026-08-07, and it replaces the
# thing that kept going wrong tonight: judging panel quality by eye off a
# dim webcam frame.  With the framebuffer beside the photo, "the glass
# looks bad" becomes "the glass and the belief disagree HERE, by THIS
# much", which is a measurement.
#
# /dev/fb0 is 1872x1404 XRGB8888, stride 7488 (= 1872*4, no padding), so
# it feeds ffmpeg directly as rawvideo bgra.
#
# Usage: belief-vs-glass.sh <tag>
set -eu

TAG=${1:-cmp}
KH=/home/wkelly/.ssh/known_hosts_pinenote
HOST=192.168.86.145
W=1872; H=1404

user=root
ssh -o UserKnownHostsFile="$KH" -o BatchMode=yes -o ConnectTimeout=6 root@"$HOST" true 2>/dev/null || user=user

# 1. the belief: raw framebuffer, gzipped over the wire
ssh -o UserKnownHostsFile="$KH" -o BatchMode=yes "$user"@"$HOST" \
    "${user:+sudo} dd if=/dev/fb0 bs=7488 count=$H status=none | gzip -1" 2>/dev/null \
    | gunzip > "$TAG-fb.raw"
echo "[belief] $(stat -c %s "$TAG-fb.raw") bytes"
ffmpeg -hide_banner -loglevel error -f rawvideo -pixel_format bgra \
       -video_size ${W}x${H} -i "$TAG-fb.raw" -frames:v 1 -y "$TAG-belief.png"

# 2. the glass: camera, rotated to match the framebuffer's orientation
ffmpeg -hide_banner -loglevel error -f v4l2 -video_size 1920x1080 \
       -i /dev/video0 -vsync 0 -frames:v 25 -update 1 -y "$TAG-cam.jpg"

# 3. side by side, both scaled to the same height
ffmpeg -hide_banner -loglevel error -i "$TAG-belief.png" -i "$TAG-cam.jpg" \
       -filter_complex "[0:v]transpose=1,scale=-1:900[a];[1:v]transpose=2,crop=iw*0.60:ih*0.66:iw*0.28:ih*0.17,scale=-1:900[b];[a][b]hstack" \
       -frames:v 1 -y "$TAG-sidebyside.jpg"
echo "[done] $TAG-sidebyside.jpg  (left = framebuffer belief, right = glass)"
