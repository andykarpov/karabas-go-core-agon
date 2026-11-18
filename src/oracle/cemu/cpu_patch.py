# karabas: patches of CEmu cpu.c for the Agon (see the Makefile)
import sys
p = sys.argv[1]
s = open(p).read()
old = """    if (mixed) {
        if (cpu.ADL) {
            cpu_push_byte_mode(cpu.registers.PCU, true);
            cpu_push_byte_mode((cpu.MADL << 1) | cpu.ADL, true);
        }"""
new = """    if (mixed && cpu.ADL && stack) { /* karabas: as the Agon: the mode byte on top */
        cpu_push_byte_mode(cpu.registers.PCU, true);
        cpu_push_byte_mode(cpu.registers.PCH, true);
        cpu_push_byte_mode(cpu.registers.PCL, true);
        cpu_push_byte_mode((cpu.MADL << 1) | cpu.ADL, true);
    } else if (mixed) {
        if (cpu.ADL) {
            cpu_push_byte_mode(cpu.registers.PCU, true);
            cpu_push_byte_mode((cpu.MADL << 1) | cpu.ADL, true);
        }"""
assert s.count(old) == 1
s = s.replace(old, new)
old = "    cpu_rst(address, cpu.ADL, cpu.ADL | cpu.MADL, cpu.MADL);"
assert s.count(old) == 1
s = s.replace(old, "    cpu_rst(address, cpu.ADL | cpu.MADL, cpu.ADL | cpu.MADL, cpu.MADL); /* karabas: SPL with MADL (Agon) */")
open(p, "w").write(s)
