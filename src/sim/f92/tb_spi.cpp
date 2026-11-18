// karabas: unit test of f92_spi: an SPI slave model on sck / mosi / miso in all four modes and a
// few BRG values; per byte: the slave received TSR, the master RBR = the slave byte, SCK half
// period = BRG system clocks, SPIF set at the end and cleared by the SR read; MOS's spi_transfer
// sequence (TSR, poll SR bit 7, RBR) with BRG 3 = 48 system clocks per byte.
#include "Vf92_spi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static Vf92_spi *d;
static int bad = 0;
static void clk() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static void wr(int a, uint8_t v) { d->sys_ce = 0; d->sel = 1; d->addr = a; d->din = v; d->wr = 1; d->rd = 0; clk(); d->wr = 0; d->sel = 0; }
static uint8_t rd(int a) { d->sys_ce = 0; d->sel = 1; d->addr = a; d->wr = 0; d->eval(); uint8_t v = d->dout; d->rd = 1; clk(); d->rd = 0; d->sel = 0; return v; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vf92_spi;
	d->reset = 1; clk(); clk(); d->reset = 0;
	srand(3);
	long bytes = 0;
	for (int mode = 0; mode < 4; mode++) {
		int cpol = mode >> 1, cpha = mode & 1;
		for (int brg : {1, 2, 3, 7}) {
			wr(2, 0x00);
			wr(0, brg); wr(1, 0);
			wr(2, 0x30 | (cpol << 3) | (cpha << 2));
			for (int k = 0; k < 64; k++) {
				uint8_t m = rand(), s = rand(), got = 0;
				int sbit = 7, nbits = 0;
				d->miso = cpha ? 1 : (s >> 7) & 1;          // CPHA 0: the slave's MSB is out at select
				if (!cpha) sbit = 6;
				wr(4, m);
				int prev = d->sck, last_edge = -1, t = 0, edges = 0;
				while (t < 4000) {
					d->sys_ce = 1; clk(); t++;
					int sk = d->sck;
					if (sk != prev) {
						bool leading = (sk != cpol);
						if (last_edge >= 0 && t - last_edge != brg) { printf("FAIL mode %d brg %d: half period %d\n", mode, brg, t - last_edge); bad++; }
						last_edge = t; edges++;
						bool sample = cpha ? !leading : leading;
						if (sample) { got = (got << 1) | d->mosi; nbits++; }
						else if (sbit >= 0) { d->miso = (s >> sbit) & 1; sbit--; }
						prev = sk;
					}
					if (!d->busy) break;
				}
				uint8_t sr = rd(3), sr2 = rd(3), r = rd(4);
				bytes++;
				if (edges != 16 || nbits != 8 || got != m || r != s || !(sr & 0x80) || (sr2 & 0x80) || d->sck != cpol) {
					printf("FAIL mode %d brg %d: edges %d bits %d slave got %02x (sent %02x), RBR %02x (slave %02x), SR %02x %02x\n",
					       mode, brg, edges, nbits, got, m, r, s, sr, sr2);
					if (++bad > 5) return 1;
				}
			}
		}
	}
	// MOS: CTL 0, BRG 3, CTL 30; spi_transfer: TSR, poll SR (each poll = 1 system clock here)
	wr(2, 0); wr(0, 3); wr(1, 0); wr(2, 0x30);
	wr(4, 0x40);
	int polls = 0;
	while (polls < 1000) { d->sys_ce = 1; clk(); polls++; if (rd(3) & 0x80) break; }
	bool mos_ok = polls == 48;
	printf("%s: %ld bytes in 4 modes x 4 BRG, MOS byte = %d system clocks (%.2f us)\n",
	       bad == 0 && mos_ok ? "PASS" : "FAIL", bytes, polls, polls / 18.432);
	delete d;
	return bad == 0 && mos_ok ? 0 : 1;
}
