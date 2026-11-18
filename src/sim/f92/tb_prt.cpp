// karabas: unit test of f92_prt (PRT0..5) against a C++ model of the same rules (prt_timer.rs of
// the Agon emulator without its 5-tick interrupt latency): random writes / reads / system clocks,
// every read compared; then the MOS delay (init_timer0 1 ms / 16, __wait_timer0) in real time.
#include "Vf92_prt.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

struct Prt {
	uint8_t ctl = 0, dr_h = 0, pre = 0;
	uint16_t rld = 0, cnt = 0;
	int div() const { static const int d[4] = {4, 16, 64, 256}; return d[(ctl >> 2) & 3]; }
	void tick() {
		if (!(ctl & 1)) return;
		if (ctl & 2) { cnt = rld; pre = 0; ctl &= ~2; return; }
		if (pre == div() - 1) {
			pre = 0;
			if (cnt == 1) {
				ctl |= 0x80;
				if (ctl & 0x10) cnt = rld; else { cnt = 0; ctl &= ~3; }
			} else cnt--;
		} else pre++;
	}
	uint8_t read(int rg) {
		if (rg == 0) { uint8_t c = ctl; ctl &= 0x7f; return c; }
		if (rg == 1) { dr_h = cnt >> 8; return cnt & 0xff; }
		return dr_h;
	}
	void write(int rg, uint8_t v) {
		if (rg == 0) ctl = v & 0x7f;
		else if (rg == 1) rld = (rld & 0xff00) | v;
		else rld = (rld & 0x00ff) | (v << 8);
	}
};

static Vf92_prt *d;
static void clk() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vf92_prt;
	Prt m[6];
	d->reset = 1; clk(); clk(); d->reset = 0;
	srand(1);
	long reads = 0, bad = 0;
	for (long step = 0; step < 2000000 && bad < 5; step++) {
		d->sys_ce = 0; d->sel = 0; d->rd = 0; d->wr = 0;
		int op = rand() % 100;
		if (op < 70) {                        // a system clock
			d->sys_ce = 1;
			for (auto &t : m) t.tick();
		} else {
			int a = rand() % 18, t = a / 3, rg = a % 3;
			d->sel = 1; d->addr = a;
			if (op < 90) {                    // a read: compare the data, then strobe
				d->eval();
				uint8_t want = m[t].read(rg), got = d->dout;
				d->rd = 1;
				reads++;
				if (got != want) { printf("FAIL step %ld read %02x: rtl %02x model %02x\n", step, 0x80 + a, got, want); bad++; }
			} else {                          // a write, biased to useful values
				uint8_t v = rand() & 0xff;
				if (rg == 0) v = (v & 0xdc) | (rand() % 4 ? 0x03 : (v & 3));
				else if (rg == 2) v &= 0x03;
				d->din = v; d->wr = 1;
				m[t].write(rg, v);
			}
		}
		clk();
		uint8_t irq = 0;
		for (int t = 0; t < 6; t++) if ((m[t].ctl & 0xc0) == 0xc0) irq |= 1 << t;
		if (d->irq != irq) { printf("FAIL step %ld irq rtl %02x model %02x\n", step, d->irq, irq); bad++; }
	}
	// MOS: init_timer0(1, 16, 0): CTL 0, RR = 18432 / 16 = 1152, CTL = 04; __wait_timer0: CTL |= 3,
	// poll DR until 0. Expect 1152 * 16 system clocks.
	auto wr = [&](int a, uint8_t v) { d->sys_ce = 0; d->sel = 1; d->addr = a; d->din = v; d->wr = 1; d->rd = 0; clk(); d->wr = 0; d->sel = 0; };
	wr(0, 0x00); wr(1, 1152 & 0xff); wr(2, 1152 >> 8); wr(0, 0x04); wr(0, 0x07);
	long n = 0;
	for (;;) {
		d->sys_ce = 1; d->sel = 0; clk(); n++;
		d->sys_ce = 0; d->sel = 1; d->addr = 1; d->eval(); int lo = d->dout; d->rd = 1; clk(); d->rd = 0;
		d->addr = 2; d->eval(); int hi = d->dout; d->sel = 0;
		if ((lo | hi) == 0 || n > 100000) break;
	}
	bool delay_ok = n >= 1152 * 16 && n <= 1152 * 16 + 2;
	printf("%s: %ld random reads (%ld bad), MOS 1 ms delay = %ld system clocks (%.3f ms at 18.432 MHz)\n",
	       bad == 0 && delay_ok ? "PASS" : "FAIL", reads, bad, n, n / 18432.0);
	delete d;
	return bad == 0 && delay_ok ? 0 : 1;
}
