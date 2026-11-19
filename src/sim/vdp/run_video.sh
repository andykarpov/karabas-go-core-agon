#!/bin/bash
# The scanout RTL against the firmware screenshot on mkstream.py streams (each ~2 min, 4 at a time: JOBS=n):
#   src/sim/vdp/run_video.sh [names...]     out: src/sim/vdp/out/<name>.* ; prints the VIDEO lines
set -e
cd "$(dirname "$0")"
FW=$(cd ../../vdp && pwd)/build-rv32imO2/vdp.bin
NAMES=${*:-"gtext0 gtext1 gtext2 gtext8 hwspr8 mg2 mg12 mg16 mg18 mg19 mg20 mg24 mg27"}
mkdir -p out
./run.sh "$FW" --max 1 >/dev/null 2>&1 || true      # build once
JOBS=${JOBS:-4}
for n in $NAMES; do
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
	../mkstream.py "$n" "out/$n.bin" --nocursor --settle
	( ./run.sh "$FW" --in "out/$n.bin" --ppm "out/$n.ppm" > "out/$n.log" 2>&1 || true
	  echo "JOB-STAGE: $n"; grep -h "^VIDEO\|^DONE" "out/$n.log" | sed "s|^|$n: |" || echo "$n: no VIDEO line" ) &
done
wait
