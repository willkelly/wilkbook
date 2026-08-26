#!/bin/sh
# make-fiducials.sh OUT.raw -- the registration pattern (README step 1)
set -eu
convert -size 1872x1404 xc:white -fill black \
  -draw "rectangle 40,40 120,120" -draw "rectangle 1752,40 1832,120" \
  -draw "rectangle 40,1284 120,1364" -draw "rectangle 1752,1284 1832,1364" \
  -draw "rectangle 916,682 956,722" \
  -depth 8 gray:"${1:?usage: make-fiducials.sh OUT.raw}"
