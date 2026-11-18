// karabas: unit test of f92_gpio against a per-pin C++ model written after gpio.rs of the Agon
// emulator (modes by {ALT2, ALT1, DDR, DR}; a mode change clears the pending bits it changes):
// random register writes and pin changes, every read and irq compared each clock; then the vsync
// pin of MOS (PB1, rising edge, cleared by a DR write of 1).
#include "Vf92_gpio.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

struct Gpio {
	uint8_t dr = 0, ddr = 0xff, alt1 = 0, alt2 = 0, irq = 0, lvl_q = 0;
	int mode(int p) const { return ((dr >> p) & 1) | ((ddr >> p) & 1) << 1 | ((alt1 >> p) & 1) << 2 | ((alt2 >> p) & 1) << 3; }
	uint8_t level(uint8_t pins) const {
		uint8_t l = 0;
		for (int p = 0; p < 8; p++) {
			int m = mode(p), b;
			if (m <= 1 || (m >= 4 && m <= 7)) b = (dr >> p) & 1; else b = (pins >> p) & 1;
			l |= b << p;
		}
		return l;
	}
	uint8_t sets(uint8_t pins) const {
		uint8_t l = level(pins), s = 0;
		for (int p = 0; p < 8; p++) {
			int b = (l >> p) & 1, c = ((l ^ lvl_q) >> p) & 1;
			switch (mode(p)) {
			case 9: s |= c << p; break;
			case 12: s |= (!b) << p; break;
			case 13: s |= b << p; break;
			case 14: s |= (c && !b) << p; break;
			case 15: s |= (c && b) << p; break;
			}
		}
		return s;
	}
	// one clock: the level history, the pending bits, then the write
	void clock(uint8_t pins, bool w, int a, uint8_t v) {
		uint8_t l = level(pins), nirq = irq | sets(pins);
		if (w) {
			if (a == 0) {
				uint8_t clr = 0;
				for (int p = 0; p < 8; p++) {
					int m = mode(p), b = (l >> p) & 1;
					if (m >= 8) {
						bool c = (v >> p) & 1;
						if (m == 12) c = c && b;
						if (m == 13) c = c && !b;
						clr |= c << p;
					}
				}
				dr = (dr & alt2) | (v & ~alt2);
				nirq &= ~clr;
			} else if (a == 1) { nirq &= ~(ddr ^ v); ddr = v; }
			else if (a == 2) { nirq &= ~(alt1 ^ v); alt1 = v; }
			else { nirq &= ~(alt2 ^ v); alt2 = v; }
		}
		irq = nirq; lvl_q = l;
	}
	uint8_t read(int a, uint8_t pins) const { return a == 0 ? level(pins) : a == 1 ? ddr : a == 2 ? alt1 : alt2; }
};

static Vf92_gpio *d;
static void clk() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vf92_gpio;
	Gpio m;
	d->reset = 1; d->pin_in = 0; clk(); clk(); d->reset = 0;
	srand(4);
	uint8_t pins = 0;
	long reads = 0, bad = 0, irqs = 0;
	for (long step = 0; step < 2000000 && bad < 5; step++) {
		if (rand() % 4 == 0) pins ^= 1 << (rand() % 8);
		d->pin_in = pins; d->sel = 0; d->wr = 0;
		int a = rand() % 4; uint8_t v = rand();
		bool w = rand() % 8 == 0;
		d->sel = 1; d->addr = a; d->eval();
		uint8_t want = m.read(a, pins);
		reads++;
		if (d->dout != want) { printf("FAIL step %ld read %d: rtl %02x model %02x\n", step, a, d->dout, want); bad++; }
		if (w) { d->wr = 1; d->din = v; }
		m.clock(pins, w, a, v);
		clk();
		if (d->irq != m.irq) { printf("FAIL step %ld irq rtl %02x model %02x\n", step, d->irq, m.irq); bad++; }
		if (m.irq) irqs++;
	}
	// MOS vsync: PB1 mode 15 set as gpio.asm GPIOB_M9 (DR, DDR, ALT1, ALT2 bit 1 = 1, in that order:
	// DR is not stored once in an interrupt mode), a rising edge, cleared by DR bit 1 = 1
	d->reset = 1; clk(); d->reset = 0;
	auto wr = [&](int a, uint8_t v) { d->sel = 1; d->addr = a; d->din = v; d->wr = 1; clk(); d->wr = 0; d->sel = 0; };
	d->pin_in = 0;
	wr(0, 0x02); wr(1, 0xff); wr(2, 0x02); wr(3, 0x02);
	clk();
	bool ok = d->irq == 0;
	d->pin_in = 0x02; clk(); clk();
	ok = ok && d->irq == 0x02;
	d->pin_in = 0x00; clk();
	ok = ok && d->irq == 0x02;                    // stays until cleared
	wr(0, 0x02); clk();
	ok = ok && d->irq == 0x00;
	printf("%s: %ld reads (%ld clocks with an interrupt pending), %ld bad, MOS vsync on PB1 %s\n",
	       bad == 0 && ok ? "PASS" : "FAIL", reads, irqs, bad, ok ? "ok" : "WRONG");
	delete d;
	return bad == 0 && ok ? 0 : 1;
}
