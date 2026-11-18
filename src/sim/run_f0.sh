#!/bin/sh
# Ф0.4: VDP workload on the ISS. For each stream of mkstream.py: start at IN_AT us (after the VDP
# boot), the UART at BAUD (default: the real 1152000; BAUD=100000000 = the bytes are all there
# at once, the time is then only the VDP work). The end = the VDP answer "80 01 aa" to the last
# general poll. Prints: name, bytes, us from the start to the end, input bytes per second.
#   ./run_f0.sh [names...]      out: $OUT (default ./f0), screenshots <name>.ppm at the end
set -e
cd "$(dirname "$0")"
FW=${FW:-../vdp/build-rv32imO2/vdp.bin}
OUT=${OUT:-f0}
BAUD=${BAUD:-1152000}
IN_AT=${IN_AT:-1500000}
IPU=${IPU:-50}
NAMES=${*:-"text0 text1 text3 modes lines fills cls"}
mkdir -p "$OUT"
make -s iss
for n in $NAMES; do
    ./mkstream.py "$n" "$OUT/$n.bin"
    (
        ./iss "$FW" --max 3000 --ipu "$IPU" --baud "$BAUD" --in "$OUT/$n.bin" --in-at "$IN_AT" --tx "$OUT/$n.tx" \
            > "$OUT/$n.log" 2>&1 || true
        size=$(stat -c %s "$OUT/$n.bin")
        # the reply to the last poll: "80 01 aa" (3 lines of the TX log)
        end=$(awk 'p==2 && $2=="aa" {print $1; exit} {p = ($2=="80") ? 1 : (p==1 && $2=="01") ? 2 : 0}' "$OUT/$n.tx")
        if [ -n "$end" ]; then
            us=$((end - IN_AT))
            echo "$n $size bytes: $us us, $((size * 1000000 / (us > 0 ? us : 1))) B/s"
        else
            echo "$n $size bytes: NOT DONE in the run ($(grep '^END instr' "$OUT/$n.log"))"
        fi
    ) &
done
wait
