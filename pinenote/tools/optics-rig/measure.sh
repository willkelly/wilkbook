#!/bin/sh
# measure.sh CAPTURE.png INK_MASK.png PAPER_MASK.png -- differential
# ghost metric; positive % = residual darkness where the ink mask is.
# Quote numbers corrected by the same masks' washed-panel baseline.
set -eu
CAP=${1:?usage: measure.sh CAP.png INK_MASK.png PAPER_MASK.png}
INK=${2:?ink mask}
PAPER=${3:?paper mask}
ni=$(convert "$CAP" "$INK" -compose Multiply -composite -format '%[fx:mean]' info:)
di=$(convert "$INK" -format '%[fx:mean]' info:)
np=$(convert "$CAP" "$PAPER" -compose Multiply -composite -format '%[fx:mean]' info:)
dp=$(convert "$PAPER" -format '%[fx:mean]' info:)
awk -v ni="$ni" -v di="$di" -v np="$np" -v dp="$dp" 'BEGIN {
  i = ni / di; p = np / dp
  printf "paper=%.4f ink_region=%.4f ghost=%.2f%%\n", p, i, (p - i) / p * 100 }'
