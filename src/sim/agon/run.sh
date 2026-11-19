#!/bin/bash
# Ф1.4 step 4: the whole Agon in RTL (agon_sim_top.v: agon_ez80 + agon_link + vdp_soc). The T80
# netlist from ghdl as src/sim/sys/run.sh. Build in src/sim/agon/build, then runs
#   src/sim/agon/run.sh --mos mos.bin --vdp vdp.bin --sd sd.img --ppm out.ppm [--ms N] [--after ms]
set -e
cd "$(dirname "$0")"
SIM=$(pwd)
R=$(cd ../../rtl && pwd)
B=$SIM/build
mkdir -p "$B/ghdl" "$B/vhd"
VHD="$R/ez80/T80_Pack.vhd $R/ez80/T80_ALU.vhd $R/ez80/T80_Reg.vhd $R/ez80/T80_MCode.vhd $R/ez80/T80.vhd"
G="--std=08 -fsynopsys -frelaxed --workdir=$B/ghdl"
NET=$B/t80.v2005   # (Verilog 2005 for this netlist only: +1364-2005ext+v2005)
if [ ! -f "$NET" ] || [ -n "$(find $VHD run.sh -newer "$NET" 2>/dev/null)" ]; then
	rm -f "$B"/ghdl/work-obj08.cf
	for f in $VHD; do
		sed -e 's/^\tmcode : T80_MCode/\tu_mcode : T80_MCode/' -e 's/^\talu : T80_ALU/\tu_alu : T80_ALU/' \
			-e 's/^\tRegs : T80_Reg/\tu_regs : T80_Reg/' "$f" > "$B/vhd/$(basename "$f")"
		ghdl -a $G "$B/vhd/$(basename "$f")"
	done
	ghdl --synth $G --out=verilog -gEZ80=1 -gIOWait=1 -gMode=0 T80 > "$NET.tmp" 2> "$B/ghdl.log" || { tail -20 "$B/ghdl.log"; exit 1; }
	sed -E 's/\\([A-Za-z0-9_]+) /\1_esc/g' "$NET.tmp" > "$NET"
fi
F=$R/f92
V="$SIM/agon_sim_top.v $R/agon_ez80.v $R/agon_link.v $F/f92.v $F/f92_mem.v $F/f92_prt.v $F/f92_gpio.v $F/f92_spi.v $F/f92_uart.v $F/f92_intc.v $R/vdp/vdp_soc.v $R/vdp/vdp_video.v $R/vdp/vdp_sdram.v $R/vexriscv/VexRiscv_16k.v"
BIN=$B/obj/Vagon_sim_top
if [ ! -x "$BIN" ] || [ -n "$(find "$NET" $V tb_agon.cpp ../sys/sdcard.h run.sh -newer "$BIN" 2>/dev/null)" ]; then
	verilator -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --no-timing +1364-2005ext+v2005 --top-module agon_sim_top \
		-DGHDL_T80 -Mdir "$B/obj" --cc "$NET" $V --exe "$SIM/tb_agon.cpp" -o Vagon_sim_top \
		-CFLAGS "-std=c++17 -O2" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" > "$B/verilator.log" 2>&1 \
		|| { grep -E '%Error' "$B/verilator.log" | head -20; exit 1; }
	make -s -j8 -C "$B/obj" -f Vagon_sim_top.mk > "$B/make.log" 2>&1 || { tail -20 "$B/make.log"; exit 1; }
fi
exec "$BIN" "$@"
