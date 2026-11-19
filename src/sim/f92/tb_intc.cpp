// karabas: unit test of f92_intc: random request sets against the priority loop of the oracle
// (kg_do_interrupts in src/oracle/kg_trace.rs).
#include "Vf92_intc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Vf92_intc *d = new Vf92_intc;
	srand(5);
	long bad = 0, n = 0;
	for (; n < 1000000 && bad < 5; n++) {
		auto r = [](int k) { return (rand() % k) == 0; };
		uint8_t prt = r(3) ? rand() & 0x3f : 0, gb = r(3) ? rand() : 0, gc = r(3) ? rand() : 0, gd = r(3) ? rand() : 0;
		bool u0 = r(4), u1 = r(4), i2 = r(4);
		d->prt = prt; d->uart0 = u0; d->uart1 = u1; d->i2c = i2; d->gpb = gb; d->gpc = gc; d->gpd = gd;
		d->eval();
		int v = -1;
		for (int i = 0; i < 6 && v < 0; i++) if (prt >> i & 1) v = 0xa + 2 * i;
		if (v < 0 && u0) v = 0x18;
		if (v < 0 && u1) v = 0x1a;
		if (v < 0 && i2) v = 0x1c;
		int base[3] = {0x30, 0x40, 0x50}; uint8_t due[3] = {gb, gc, gd};
		for (int p = 0; p < 3 && v < 0; p++) if (due[p]) v = base[p] + 2 * __builtin_ctz(due[p]);
		bool irq = v >= 0;
		if (d->irq != irq || (irq && d->vec != v)) { printf("FAIL: irq %d vector %02x, want %d %02x\n", d->irq, d->vec, irq, v); bad++; }
	}
	printf("%s: %ld request sets, %ld bad\n", bad ? "FAIL" : "PASS", n, bad);
	delete d;
	return bad ? 1 : 0;
}
