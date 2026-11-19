// karabas: unit test of f92_uart against a C++ model of the same rules (uart.rs of the Agon
// emulator with a byte link): random CPU reads / writes and link traffic; every read, irq and every
// byte that leaves on the link compared, cycle by cycle (the model works from the state at the
// start of each clock, as the RTL).
#include "Vf92_uart.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>

struct Uart {
	uint8_t ier = 0, fctl = 0, lctl = 0, mctl = 0, spr = 0, brg_l = 2, brg_h = 0;
	std::deque<uint8_t> tx, rx;
	bool cts = false;
	bool dlab() const { return lctl & 0x80; }
	uint8_t read(int a) {
		switch (a) {
		case 0: if (dlab()) return brg_l; if (rx.empty()) return 0; { uint8_t v = rx.front(); rx.pop_front(); return v; }
		case 1: return dlab() ? brg_h : ier;
		case 2: return ((fctl & 1) ? 0xc0 : 0) | ((ier & 1) && !rx.empty() ? 4 : (ier & 2) && tx.empty() ? 2 : 1);
		case 3: return lctl;
		case 4: return mctl;
		case 5: return (tx.empty() ? 0x60 : 0) | (rx.empty() ? 0 : 1);
		case 6: return cts ? 0x10 : 0;
		default: return spr;
		}
	}
	void write(int a, uint8_t v) {
		switch (a) {
		case 0: if (dlab()) brg_l = v; else if (tx.size() < 16) tx.push_back(v); break;
		case 1: if (dlab()) brg_h = v; else ier = v; break;
		case 2: fctl = v; if (v & 2) rx.clear(); if (v & 4) tx.clear(); break;
		case 3: lctl = v; break;
		case 4: mctl = v; break;
		case 7: spr = v; break;
		}
	}
	bool irq() const { return ((ier & 1) && !rx.empty()) || ((ier & 2) && tx.empty()); }
};

static Vf92_uart *d;
static void clk() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vf92_uart;
	Uart m;
	d->reset = 1; clk(); clk(); d->reset = 0;
	srand(2);
	long reads = 0, sent = 0, bad = 0;
	for (long step = 0; step < 2000000 && bad < 5; step++) {
		d->sel = 0; d->rd = 0; d->wr = 0; d->tx_ready = 0; d->rx_valid = 0;
		d->cts = m.cts = rand() % 4 != 0;
		d->eval();
		// everything from the state at the start of the clock, as the RTL
		size_t tx0 = m.tx.size(), rx0 = m.rx.size();
		bool pop = false, offer = false; uint8_t rxv = 0;
		if (rand() % 3 == 0 && d->tx_valid) {
			if (m.tx.empty() || d->tx_data != m.tx.front()) { printf("FAIL step %ld link byte %02x model %s\n", step, d->tx_data, m.tx.empty() ? "empty" : "other"); bad++; }
			pop = true; d->tx_ready = 1;
		} else if (!d->tx_valid && tx0) { printf("FAIL step %ld tx_valid 0, model has %zu\n", step, tx0); bad++; }
		if (rand() % 5 == 0) { rxv = rand(); d->rx_data = rxv; d->rx_valid = 1; offer = true; }
		int op = rand() % 100, a = rand() % 8; uint8_t v = rand();
		bool rdop = op < 40, wrop = !rdop && op < 60;
		if (rdop) {
			d->sel = 1; d->addr = a; d->eval();
			uint8_t got = d->dout, want;
			Uart t = m; want = t.read(a);              // the value, from the start state
			d->rd = 1; reads++;
			if (got != want) { printf("FAIL step %ld read C%d: rtl %02x model %02x\n", step, a, got, want); bad++; }
		} else if (wrop) {
			if (a == 3) v &= rand() % 4 ? 0x7f : 0xff;            // DLAB mostly off
			if (a == 2) v &= rand() % 8 ? 0xf9 : 0xff;            // FIFO clears now and then
			d->sel = 1; d->addr = a; d->din = v; d->wr = 1;
		}
		// the model update
		bool clrtx = wrop && a == 2 && (v & 4), clrrx = wrop && a == 2 && (v & 2);
		bool dl = m.dlab();
		if (pop && !m.tx.empty()) { m.tx.pop_front(); sent++; }
		if (rdop && a == 0 && !dl && rx0) m.rx.pop_front();
		if (offer && rx0 < 16) m.rx.push_back(rxv);
		if (wrop) {
			if (a == 0 && !dl) { if (tx0 < 16) m.tx.push_back(v); }
			else m.write(a, v);
		}
		if (clrtx) m.tx.clear();
		if (clrrx) m.rx.clear();
		clk();
		if (d->irq != m.irq()) { printf("FAIL step %ld irq rtl %d model %d\n", step, d->irq, m.irq()); bad++; }
	}
	printf("%s: %ld reads, %ld link bytes, %ld bad\n", bad ? "FAIL" : "PASS", reads, sent, bad);
	delete d;
	return bad ? 1 : 0;
}
