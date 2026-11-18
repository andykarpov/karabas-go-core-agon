#!/bin/sh
# Ф0.4: VDP workload on the ISS. For each stream of mkstream.py: start at IN_AT us (after the VDP
# boot), the UART at BAUD (default: the real 1152000; BAUD=100000000 = the bytes are all there
# at once, the time is then only the VDP work). The end = the VDP answer "80 01 aa" to the last
# general poll (the ISS stops there: --stop-poll). Prints: name, bytes, us from the start to the
# end, input bytes per second, the instructions and cache misses of the work, the task stacks.
#   [ICACHE=B DCACHE=B] ./run_f0.sh [names...]      out: $OUT (default ./f0); then ./model.py $OUT
set -e
cd "$(dirname "$0")"
FW=${FW:-../vdp/build-rv32imO2/vdp.bin}
OUT=${OUT:-f0}
BAUD=${BAUD:-1152000}
IN_AT=${IN_AT:-1500000}
IPU=${IPU:-50}
ICACHE=${ICACHE:-4096}
DCACHE=${DCACHE:-4096}
NAMES=${*:-"text0 text1 text2 text3 text8 modes lines fills cls bitmaps0 bitmaps8 blit64 blitfull gtext0 gtext1 gtext2 gtext8 sprites8 textaudio"}
mkdir -p "$OUT"
make -s iss
for n in $NAMES; do
    ./mkstream.py "$n" "$OUT/$n.bin"
    (
        ./iss "$FW" --max 3000 --ipu "$IPU" --baud "$BAUD" --in "$OUT/$n.bin" --in-at "$IN_AT" --tx "$OUT/$n.tx" \
            --stop-poll aa --icache "$ICACHE" --dcache "$DCACHE" > "$OUT/$n.log" 2>&1 || true
        size=$(stat -c %s "$OUT/$n.bin")
        done_line=$(grep '^DONE' "$OUT/$n.log" || true)
        if [ -n "$done_line" ]; then
            us=$(echo "$done_line" | awk '{print $3}')
            echo "$n $size bytes: $us us, $((size * 1000000 / (us > 0 ? us : 1))) B/s | $done_line"
        else
            echo "$n $size bytes: NOT DONE ($(grep '^END instr' "$OUT/$n.log"))"
        fi
        grep '^coop:' "$OUT/$n.log" | sed "s/^/  $n /" || true
    ) &
done
wait
