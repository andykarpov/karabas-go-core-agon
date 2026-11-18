/* karabas: a CPU-only eZ80 oracle from CEmu's core/cpu.c (GPL-3, CE-Programming/CEmu, the TI-84 CE
 * emulator, validated against real eZ80 hardware), for the per-opcode tests of the core
 * (src/sim/cpu/optest.py). The program is a flash image under the eZ80F92 memory map of the Agon
 * (as the testbench: flash 128 KB at FLASH_ADDR_U, on-chip SRAM at {RAM_ADDR_U}:E000, external
 * 512 KB in the CS0 window, F5 elsewhere; the map registers follow the port writes). Port reads
 * give (low ^ high ^ 5A). No interrupt sources.
 *
 * Trace: the line format of agon-oracle (n cycles PC ADL MADL MB AF BC DE HL IX IY SPS SPL I IFF1
 * IFF2 then w: / r: / o: events), one line per instruction (a suffix / prefix and its opcode = one).
 *   cemu-oracle --flash p.bin --n N --trace t.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "cpu.h"
#include "emu.h"
#include "mem.h"
#include "bus.h"
#include "control.h"
#include "schedule.h"
#include "interrupt.h"

control_state_t control;
interrupt_state_t intrpt[2];
asic_state_t asic;

static uint8_t rom[0x20000], ram[8192], ext[0x80000];
static uint8_t flash_u = 0, seg = 0xff, lbr = 0, ubr = 0xff;
static int onchip = 1;

static char ev[4096];
static size_t evn;
static void evadd(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int k = vsnprintf(ev + evn, sizeof ev - evn, fmt, ap);
    va_end(ap);
    if (k > 0 && evn + (size_t)k < sizeof ev) evn += (size_t)k;
}

static uint8_t *at(uint32_t a, int wr) {
    a &= 0xffffff;
    uint32_t o = a - (((uint32_t)seg << 16) + 0xe000);
    if (onchip && o < 8192) return &ram[o];
    uint32_t f = (a - ((uint32_t)flash_u << 16)) & 0xffffff;
    if (f < 0x20000) return wr ? NULL : &rom[f];
    if ((a >> 16) >= lbr && (a >> 16) <= ubr) return &ext[a & 0x7ffff];
    return NULL;
}

/* each access is a cycle (CEmu's mem.c counts them; cpu_execute() runs until cpu.next) */
uint8_t mem_read_cpu(uint32_t address, bool fetch) {
    (void)fetch;
    cpu.cycles++;
    uint8_t *p = at(address, 0);
    return p ? *p : 0xf5;
}
void mem_write_cpu(uint32_t address, uint8_t value) {
    cpu.cycles++;
    evadd(" w:%06x=%02x", address & 0xffffff, value);
    uint8_t *p = at(address, 1);
    if (p) *p = value;
}
uint8_t port_read_byte(uint16_t addr) {
    cpu.cycles++;
    uint8_t v = (uint8_t)((addr & 0xff) ^ (addr >> 8) ^ 0x5a);
    evadd(" r:%04x=%02x", addr, v);
    return v;
}
void port_write_byte(uint16_t addr, uint8_t value) {
    cpu.cycles++;
    evadd(" o:%04x=%02x", addr, value);
    switch (addr & 0xff) {
    case 0xf7: flash_u = value; break;
    case 0xb4: onchip = (value & 0x80) != 0; break;
    case 0xb5: seg = value; break;
    case 0xa8: lbr = value; break;
    case 0xa9: ubr = value; break;
    }
}
bool unprivileged_code(void) { return false; }
uint8_t bus_rand(void) { return 0; }
/* the next "event" = 1 cycle after the start of this cpu_execute(): one instruction per call */
static uint32_t sched_target;
uint32_t sched_event_next_cycle(void) { return sched_target; }
void gui_console_printf(const char *format, ...) { va_list ap; va_start(ap, format); vfprintf(stderr, format, ap); va_end(ap); }
void gui_console_err_printf(const char *format, ...) { va_list ap; va_start(ap, format); vfprintf(stderr, format, ap); va_end(ap); }

int main(int argc, char **argv) {
    const char *flash = NULL, *trace = NULL;
    long n = 1000, fill = -1;   /* --fill N: RAM filled with a hash (as the testbench --fill-ext N) */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--flash")) flash = argv[++i];
        else if (!strcmp(argv[i], "--trace")) trace = argv[++i];
        else if (!strcmp(argv[i], "--n")) n = atol(argv[++i]);
        else if (!strcmp(argv[i], "--fill")) fill = atol(argv[++i]);
    }
    if (!flash || !trace) { fprintf(stderr, "usage: %s --flash p.bin --n N --trace t.txt\n", argv[0]); return 2; }
    FILE *f = fopen(flash, "rb");
    if (!f) { perror(flash); return 2; }
    if (fread(rom, 1, sizeof rom, f) == 0) { fprintf(stderr, "%s: empty\n", flash); return 2; }
    fclose(f);
    FILE *t = fopen(trace, "w");
    if (!t) { perror(trace); return 2; }

    if (fill >= 0) {
        for (uint32_t i = 0; i < sizeof ext; i++) ext[i] = (uint8_t)(((uint32_t)i * 2654435761u + fill * 40503u) >> 13);
        for (uint32_t i = 0; i < sizeof ram; i++) ram[i] = (uint8_t)(((uint32_t)(i + 0x80000) * 2654435761u + fill * 40503u) >> 13);
    }
    memset(&cpu, 0, sizeof cpu);
    cpu_flush(0, false);
    /* as the core and the other oracle after reset: AF = FFFF (CEmu clears everything) */
    cpu.registers.AF = 0xffff;
    for (long k = 1; k <= n; k++) {
        eZ80registers_t *r = &cpu.registers;
        uint32_t pc = r->PC & 0xffffff;
        if (cpu.halted) break;
        evn = 0; ev[0] = 0;
        sched_target = cpu.cycles + 1;
        cpu_execute();
        fprintf(t, "%ld %u %06x %u %u %02x %04x %06x %06x %06x %06x %06x %04x %06x %02x %u %u%s\n",
                k, cpu.cycles, pc, cpu.ADL, cpu.MADL, r->MBASE, r->AF, r->BC & 0xffffff, r->DE & 0xffffff,
                r->HL & 0xffffff, r->IX & 0xffffff, r->IY & 0xffffff, r->SPS, r->SPL & 0xffffff,
                r->I & 0xff, cpu.IEF1 | cpu.IEF_wait, cpu.IEF2 | cpu.IEF_wait, ev);  /* EI: IFF shown set (the core sets it in EI) */
    }
    fclose(t);
    return 0;
}
