#!/bin/bash
# Ф1.3 system testbench: src/rtl/agon_ez80.v (T80 of src/rtl/ez80 through ghdl, EZ80 = 1, and
# src/rtl/f92) and sys_tb.cpp (memories, SD, fake VDP). Build in src/sim/sys/build, then runs
#   src/sim/sys/run.sh --flash mos.bin --sd sd.img [--keys 'cat\r'] [--ms N] [--vdp-out f] ...
set -e
cd "$(dirname "$0")"
SIM=$(pwd)
CPU=$(cd ../cpu && pwd)
RTL=$(cd ../../rtl/ez80 && pwd)
F92=$(cd ../../rtl/f92 && pwd)
B=$SIM/build
mkdir -p "$B/ghdl" "$B/vhd"
VHD="$RTL/T80_Pack.vhd $RTL/T80_ALU.vhd $RTL/T80_Reg.vhd $RTL/T80_MCode.vhd $RTL/T80.vhd"
G="--std=08 -fsynopsys -frelaxed --workdir=$B/ghdl"
NET=$B/t80.v
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
V="$SIM/sys_top.v $(cd ../../rtl && pwd)/agon_ez80.v $F92/f92.v $F92/f92_mem.v $F92/f92_prt.v $F92/f92_gpio.v $F92/f92_spi.v $F92/f92_uart.v $F92/f92_serial.v $F92/f92_intc.v"
BIN=$B/obj/Vsys_top
if [ ! -x "$BIN" ] || [ -n "$(find "$NET" $V sys_tb.cpp sdcard.h run.sh -newer "$BIN" 2>/dev/null)" ]; then
	verilator -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --no-timing +1364-2005ext+v --top-module sys_top \
		-Mdir "$B/obj" --cc "$NET" $V --exe "$SIM/sys_tb.cpp" -DGHDL_T80 -CFLAGS "-std=c++17 -O2 -I$SIM" -o Vsys_top \
		> "$B/verilator.log" 2>&1 || { grep -E '%Error' "$B/verilator.log" | head -20; exit 1; }
	make -s -j8 -C "$B/obj" -f Vsys_top.mk > "$B/make.log" 2>&1 || { tail -20 "$B/make.log"; exit 1; }
fi
exec "$BIN" "$@"
