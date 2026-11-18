#!/bin/bash
# Ф1.1 CPU testbench: src/rtl/ez80 (+ tb_t80.vhd) through ghdl --synth into Verilog, Verilator with
# tb_cpu.cpp, then runs it with the given arguments (see tb_cpu.cpp). Build in src/sim/cpu/build.
#   src/sim/cpu/run.sh --mem mem.bin --trace trace.txt [--max N]
set -e
cd "$(dirname "$0")"
SIM=$(pwd)
RTL=$(cd ../../rtl/ez80 && pwd)
B=$SIM/build
mkdir -p "$B/ghdl" "$B/vhd"
VHD="$RTL/T80_Pack.vhd $RTL/T80_ALU.vhd $RTL/T80_Reg.vhd $RTL/T80_MCode.vhd $RTL/T80.vhd $SIM/tb_t80.vhd"
G="--std=08 -fsynopsys -frelaxed --workdir=$B/ghdl"
NET=$B/tb_t80.v
if [ ! -f "$NET" ] || [ -n "$(find $VHD run.sh -newer "$NET" 2>/dev/null)" ]; then
	rm -f "$B"/ghdl/work-obj08.cf
	for f in $VHD; do
		# instance labels renamed where ghdl makes a net name label_port that is also a signal (as core-cpc)
		sed -e 's/^\tmcode : T80_MCode/\tu_mcode : T80_MCode/' -e 's/^\talu : T80_ALU/\tu_alu : T80_ALU/' \
			-e 's/^\tRegs : T80_Reg/\tu_regs : T80_Reg/' "$f" > "$B/vhd/$(basename "$f")"
		ghdl -a $G "$B/vhd/$(basename "$f")"
	done
	ghdl --synth $G --out=verilog tb_t80 > "$NET.tmp" 2> "$B/ghdl.log" || { tail -20 "$B/ghdl.log"; exit 1; }
	# ghdl writes VHDL names that are Verilog keywords as escaped identifiers (\reg ), also glued
	# into other names (u0_\reg ): plain names (as core-cpc fixcase.py)
	sed -E 's/\\([A-Za-z0-9_]+) /\1_esc/g' "$NET.tmp" > "$NET"
fi
BIN=$B/obj/Vtb_t80
if [ ! -x "$BIN" ] || [ -n "$(find "$NET" tb_cpu.cpp run.sh -newer "$BIN" 2>/dev/null)" ]; then
	verilator -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --no-timing +1364-2005ext+v --top-module tb_t80 \
		-Mdir "$B/obj" --cc "$NET" --exe "$SIM/tb_cpu.cpp" -CFLAGS "-std=c++17 -O2" -o Vtb_t80 \
		> "$B/verilator.log" 2>&1 || { grep -E '%Error' "$B/verilator.log" | head -20; exit 1; }
	make -s -j8 -C "$B/obj" -f Vtb_t80.mk > "$B/make.log" 2>&1 || { tail -20 "$B/make.log"; exit 1; }
fi
exec "$BIN" "$@"
