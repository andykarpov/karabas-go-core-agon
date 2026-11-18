#!/bin/bash
# Ф1.1: the CPU testbench against the oracle's bare Z80 on random memory, N seeds (default 300) of
# 3000 instructions each. Prints the first failures and "pass P fail F". Seconds.
#   src/sim/cpu/fuzz_z80.sh [seeds] [instructions]
set -e
cd "$(dirname "$0")"
N=${1:-300}
I=${2:-3000}
OR=../../oracle/target/release/agon-oracle
make -s -C ../../oracle
W=$(mktemp -d)
trap 'rm -rf -- "$W"' EXIT
printf '\x00' > "$W/p.bin"
./run.sh --mem /dev/null --trace /dev/null >/dev/null 2>&1 || [ -x build/obj/Vtb_t80 ] && [ -z "$(find ../../rtl/ez80 tb_t80.vhd tb_cpu.cpp -newer build/obj/Vtb_t80)" ] || { echo "build failed: run ./run.sh"; exit 1; }
pass=0; fail=0
for s in $(seq 1 "$N"); do
	$OR --z80 "$W/p.bin" --fill "$s" --n "$I" --trace "$W/t.txt" --mem-out "$W/m.bin"
	if r=$(build/obj/Vtb_t80 --mem "$W/m.bin" --trace "$W/t.txt" --quiet 2>&1) && echo "$r" | grep -q PASS; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		[ $fail -le 3 ] && { echo "== seed $s"; echo "$r" | head -8; }
	fi
done
echo "pass $pass fail $fail"
[ $fail -eq 0 ]
