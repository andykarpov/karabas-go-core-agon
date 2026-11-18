#!/bin/bash
# Ф1.2: the eZ80 core against the oracle on the whole MOS run (boot + cat by default): the oracle
# writes the trace into a FIFO, the testbench (EZ80=1 build) reads it as it goes; no trace file.
#   src/sim/cpu/mos_replay.sh [ms of eZ80 time, default 5000] [keys, default "cat\r"] [sd: sd | sd-bbc]
# BBC BASIC (Z80 mode via MBASE, ~30 M instructions, ~15 min):
#   mos_replay.sh 7000 'load bbcbasic.bin\r~run\r~~PRINT 2^10\rFOR I=1 TO 5:PRINT I*I;:NEXT\r' sd-bbc
set -e
cd "$(dirname "$0")"
MS=${1:-5000}
KEYS=${2:-cat\\r}
SD=${3:-sd}
ROOT=$(cd ../../.. && pwd)
MOS=$ROOT/upstream/fab-agon-emulator/firmware/mos_platform.bin
OR=$ROOT/src/oracle/target/release/agon-oracle
make -s -C ../../oracle all "$SD"
EZ80=1 ./run.sh --flash "$MOS" --trace /dev/null --max 0 >/dev/null 2>&1 || true   # build
W=$(mktemp -d)
trap 'rm -rf -- "$W"' EXIT
mkfifo "$W/trace"
"$OR" --mos "$MOS" --sd "../../oracle/build/$SD.img" --ms "$MS" --keys "$KEYS" --keys-at 2500 --trace "$W/trace" > "$W/screen.txt" 2>&1 &
echo "JOB-STAGE: replay"
build-ez80/obj/Vtb_t80 --flash "$MOS" --trace "$W/trace" --fmask 0xff --quiet
wait
echo "--- MOS screen (fake VDP):"
cat "$W/screen.txt"
