#!/bin/sh
# cap.sh OUT.png -- capture a settled rig frame and warp it into fb
# space (1872x1404 gray) through ./calibration (see README).
set -eu
S=$(dirname "$0")
OUT=${1:?usage: cap.sh OUT.png}
CAL="$S/calibration"
[ -r "$CAL" ] || { echo "no $CAL -- run the registration protocol (README)" >&2; exit 1; }
PAIRS=$(tr '\n' ' ' < "$CAL")
ffmpeg -y -hide_banner -loglevel error -f v4l2 -input_format mjpeg \
  -video_size 4096x2160 -i "${OPTICS_VIDEO:-/dev/video0}" \
  -vf "select='eq(n,19)'" -frames:v 1 -fps_mode passthrough "$S/.cap-raw.png"
convert "$S/.cap-raw.png" \
  -define distort:viewport=1872x1404+0+0 \
  -distort Perspective "$PAIRS" \
  -colorspace gray +repage "$OUT"
