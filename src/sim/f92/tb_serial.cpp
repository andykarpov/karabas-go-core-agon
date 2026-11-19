// karabas: unit test of f92_serial (the UART1 line to the ESP8266) against a time model of the line,
// not against itself: clk = clk_ez 34.09 MHz, sys_ce from the NCO of the top (35434 / 65536 ->
// 18.432 MHz), bit time = 16 * BRG / 18.432 MHz.
//  TX: bytes back to back; txd decoded in real time at the nominal rate (each bit sampled in its middle).
//  RX: rxd driven at the nominal rate * (1 + off), off = -3 % .. +3 %, back to back, with the UART
//      FIFO full now and then; the bytes must come out in order. Then a burst with the FIFO held full:
//      cts_n up after 1792 bytes, nothing lost up to 2047.
#include "Vf92_serial.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <deque>
#include <vector>

static Vf92_serial *d;
static const double TCLK = 1e9 / 34.090909e6;    // ns
static double now = 0;
static uint32_t nco = 0;
static int bad = 0;

// the line driven into rxd: a list of (time, level)
static std::deque<std::pair<double, int>> rx_line;
static int rx_level = 1;

static void clk() {
	while (!rx_line.empty() && rx_line.front().first <= now) { rx_level = rx_line.front().second; rx_line.pop_front(); }
	d->rxd = rx_level;
	uint32_t n = nco + 35434;
	d->sys_ce = n >> 16;
	nco = n & 0xffff;
	d->clk = 0; d->eval(); d->clk = 1; d->eval();
	now += TCLK;
}

static void send_rx(const std::vector<uint8_t> &b, double bit_ns, double t0) {
	double t = t0;
	for (uint8_t v : b) {
		rx_line.push_back({t, 0}); t += bit_ns;
		for (int i = 0; i < 8; i++) { rx_line.push_back({t, (v >> i) & 1}); t += bit_ns; }
		rx_line.push_back({t, 1}); t += bit_ns;
	}
}

static double bit_ns(int brg) { return 16.0 * (brg ? brg : 1) * 1e9 / 18432000.0; }

static void test_tx(int brg, int count) {
	d->brg = brg;
	double bt = bit_ns(brg);
	std::vector<uint8_t> want;
	for (int i = 0; i < count; i++) want.push_back(rand());
	size_t next = 0;
	// decoder state
	int prev = 1, st = 0, bit = 0; double t_start = 0, t_sample = 0; uint8_t sh = 0;
	std::vector<uint8_t> got;
	double t_end = now + bt * 10.5 * (count + 2);
	while (now < t_end) {
		d->tx_valid = next < want.size();
		d->tx_data = next < want.size() ? want[next] : 0;
		d->eval();
		bool taken = d->tx_ready;
		clk();
		if (taken) next++;
		int lv = d->txd;
		if (st == 0 && prev == 1 && lv == 0) { st = 1; t_start = now; t_sample = t_start + bt * 1.5; bit = 0; sh = 0; }
		else if (st == 1 && now >= t_sample) {
			if (bit < 8) { sh |= lv << bit; bit++; t_sample += bt; }
			else { if (!lv) { printf("FAIL tx brg %d: stop bit 0\n", brg); bad++; } got.push_back(sh); st = 0; }
		}
		prev = lv;
	}
	if (got != want) { printf("FAIL tx brg %d: %zu bytes of %zu\n", brg, got.size(), want.size()); bad++; return; }
	printf("tx brg %3d: %d bytes ok\n", brg, count);
}

static void test_rx(int brg, double off, int count) {
	d->brg = brg;
	double bt = bit_ns(brg) / (1.0 + off);
	std::vector<uint8_t> b;
	for (int i = 0; i < count; i++) b.push_back(rand());
	send_rx(b, bt, now + 1000);
	std::vector<uint8_t> got;
	double t_end = now + 1000 + bt * 10 * (count + 3);
	// the CPU: takes the head now and then (MOS: LSR then RBR), with long pauses, slower than the line
	int pause = 0, gap = 0;
	while (now < t_end + count * 6000 * TCLK + 1e7 && got.size() < b.size()) {
		d->rx_pop = 0; d->rx_clr = 0;
		d->eval();
		if (gap) gap--;
		if (pause == 0 && rand() % 20000 == 0) pause = rand() % 40000;
		if (pause) pause--;
		else if (gap == 0 && d->rx_avail) { got.push_back(d->rx_data); d->rx_pop = 1; gap = 40 + rand() % 4000; }
		clk();
	}
	if (got != b) { printf("FAIL rx brg %d off %+.1f %%: %zu bytes of %zu\n", brg, off * 100, got.size(), b.size()); bad++; return; }
	printf("rx brg %3d off %+.1f %%: %d bytes ok\n", brg, off * 100, count);
}

static void test_burst() {
	int brg = 1;
	d->brg = brg;
	double bt = bit_ns(brg);
	std::vector<uint8_t> b;
	for (int i = 0; i < 2100; i++) b.push_back(rand());
	double t0 = now + 1000;
	send_rx(b, bt, t0);
	double t_end = t0 + bt * 10 * 2103;
	int cts_at = -1;
	d->rx_pop = 0;
	while (now < t_end) {
		d->eval();
		clk();
		if (cts_at < 0 && d->cts_n) cts_at = (int)((now - t0) / (bt * 10));
	}
	std::vector<uint8_t> got;
	for (int i = 0; i < 20000; i++) {
		d->rx_pop = 0; d->eval();
		if (i % 4 == 0 && d->rx_avail) { got.push_back(d->rx_data); d->rx_pop = 1; }
		clk();
	}
	if (cts_at < 1789 || cts_at > 1795) { printf("FAIL burst: cts_n up at byte %d\n", cts_at); bad++; }
	std::vector<uint8_t> want(b.begin(), b.begin() + 2047);
	if (got != want) { printf("FAIL burst: %zu bytes out (want the first 2047)\n", got.size()); bad++; }
	if (d->cts_n) { printf("FAIL burst: cts_n still up when empty\n"); bad++; }
	printf("burst: cts_n up at byte %d, %zu kept\n", cts_at, got.size());
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vf92_serial;
	srand(5);
	d->reset = 1; d->brg = 10; d->rx_pop = 0; d->rx_clr = 0; d->tx_valid = 0;
	for (int i = 0; i < 4; i++) clk();
	d->reset = 0;
	test_tx(10, 200); test_tx(1, 200); test_tx(120, 20); test_tx(0, 50);
	for (double off : {-0.03, -0.015, 0.0, 0.015, 0.03}) test_rx(10, off, 300);
	test_rx(1, 0.02, 300); test_rx(120, -0.02, 20);
	test_burst();
	printf(bad ? "serial: FAIL\n" : "serial: PASS\n");
	return bad ? 1 : 0;
}
