#!/bin/bash
# Ф1.3 unit tests of the F92 periphery (src/rtl/f92), seconds each:  src/sim/f92/run.sh [prt ...]
set -e
cd "$(dirname "$0")"
RTL=../../rtl/f92
rc=0
for t in ${@:-prt uart spi gpio intc}; do
	verilator --cc --exe --build -O2 -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
		--top-module f92_$t -Mdir build/$t $PWD/$RTL/f92_$t.v $PWD/tb_$t.cpp >build-$t.log 2>&1 || { tail -20 build-$t.log; exit 1; }
	build/$t/Vf92_$t || rc=1
done
exit $rc
