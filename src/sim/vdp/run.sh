#!/bin/bash
# Ф1.4 RTL testbench of the VDP machine (src/rtl/vdp/vdp_soc.v) with the VDP firmware: builds in
# src/sim/vdp/build, then runs   src/sim/vdp/run.sh <vdp.bin> --in stream.bin --ppm out.ppm [...]
set -e
cd "$(dirname "$0")"
SIM=$(pwd)
R=$(cd ../../rtl && pwd)
B=$SIM/build
V="$R/vdp/vdp_soc.v $R/vdp/vdp_video.v $R/vdp/vdp_sdram.v $R/vexriscv/VexRiscv_16k.v"
BIN=$B/obj/Vvdp_soc
mkdir -p "$B"
if [ ! -x "$BIN" ] || [ -n "$(find $V tb_vdp.cpp run.sh -newer "$BIN" 2>/dev/null)" ]; then
	verilator -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --no-timing --top-module vdp_soc \
		-GSDRAM_INIT_CLOCKS=100 -Mdir "$B/obj" --cc $V --exe "$SIM/tb_vdp.cpp" -o Vvdp_soc \
		-CFLAGS "-std=c++17 -O2" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" > "$B/verilator.log" 2>&1 \
		|| { grep -E '%Error' "$B/verilator.log" | head -20; exit 1; }
	make -s -j8 -C "$B/obj" -f Vvdp_soc.mk > "$B/make.log" 2>&1 || { tail -20 "$B/make.log"; exit 1; }
fi
exec "$BIN" "$@"
