#!/usr/bin/env python3
# Ф0.4 cycle model over the DONE lines of run_f0.sh logs, the calibration of core-doom (Verilator,
# VexRiscv 4K/4K, SDRAM at the CPU clock): cycles = 1.50 * instr + 28 * (I$ + D$ line fills).
# Prints per stream the ISS time (instr / IPU) and the modelled time at 80 MHz.
# usage: model.py <out_dir> [MHz]
import glob, os, sys
OUT = sys.argv[1]
MHZ = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
BASE, MISS = 1.50, 28
print(f"{'stream':>10} {'Minstr':>7} {'miss/kI':>7} {'CPI':>5} {'ISS ms':>7} {f'{MHZ:.0f} MHz ms':>10}")
for fn in sorted(glob.glob(os.path.join(OUT, '*.log'))):
    done = [l.split() for l in open(fn) if l.startswith('DONE')]
    if not done:
        continue
    d = done[0]
    us, ins = int(d[2]), int(d[4])
    im = sum(map(int, d[6].split('/'))); dm = sum(map(int, d[8].split('/')))
    cyc = BASE * ins + MISS * (im + dm)
    print(f"{os.path.basename(fn)[:-4]:>10} {ins/1e6:7.1f} {1000*(im+dm)/ins:7.1f} {cyc/ins:5.2f} {us/1000:7.0f} {cyc/MHZ/1000:10.0f}")
