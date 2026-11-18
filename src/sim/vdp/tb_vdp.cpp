// karabas: Ф1.4 RTL testbench of the VDP machine (src/rtl/vdp/vdp_soc.v: VexRiscv 16K + vdp_sdram +
// MMIO) running the VDP firmware (src/vdp, vdp.bin put straight into the SDRAM model at 0). The SDRAM
// pin model is core-doom's tb_rtl.cpp (commands at the rising edge, CAS 2, checks of tRCD / tRP /
// banks / refresh). A MOS -> VDP stream (mkstream.py) goes into the link at the UART rate (byte k at
// start + k * 10 / baud, held while CTS is low), starting --in-after us after the firmware first
// reads EZ_RX. At the VDP answer 80 01 aa (the end of the stream) the testbench asks for a
// screenshot (sim_shot_req); the firmware writes RGB888 at SHOT_BASE and writes SHOT = (w << 16) | h:
// saved as PPM (compare with iss --shot-poll of the same stream).
//   tb_vdp <vdp.bin> --in stream.bin --ppm out.ppm [--baud N] [--in-after us] [--max Mcycles]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include "Vvdp_soc.h"
#include "verilated.h"

static const uint32_t SDRAM_SIZE = 32u << 20, SHOT_OFS = 0x01800000u;
static std::vector<uint8_t> sdram(SDRAM_SIZE);

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s vdp.bin --in stream.bin --ppm out.ppm\n", argv[0]); return 2; }
	const char *inf = nullptr, *ppm = nullptr;
	double baud = 1152000, in_after = 1000;
	uint64_t max_cycles = 2000ull * 1000 * 1000;
	std::vector<uint8_t> ps2;        // --ps2 "hex bytes": PS/2 set 2 bytes on ps2_code / ps2_wr, 200 ms after the first link poll
	size_t ps2_pos = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--in")) inf = argv[++i];
		else if (!strcmp(argv[i], "--ppm")) ppm = argv[++i];
		else if (!strcmp(argv[i], "--baud")) baud = atof(argv[++i]);
		else if (!strcmp(argv[i], "--in-after")) in_after = atof(argv[++i]);
		else if (!strcmp(argv[i], "--ps2")) { for (const char *p = argv[++i]; *p; ) { char *e; long b = strtol(p, &e, 16); if (e == p) break; ps2.push_back((uint8_t)b); p = e; } }
		else if (!strcmp(argv[i], "--max")) max_cycles = strtoull(argv[++i], 0, 10) * 1000000ull;
	}
	{
		FILE *f = fopen(argv[1], "rb");
		if (!f) { perror(argv[1]); return 2; }
		size_t n = fread(sdram.data(), 1, SDRAM_SIZE, f);
		fclose(f);
		fprintf(stderr, "firmware %zu bytes\n", n);
	}
	std::vector<uint8_t> in;
	if (inf) {
		FILE *f = fopen(inf, "rb");
		if (!f) { perror(inf); return 2; }
		int c;
		while ((c = fgetc(f)) != EOF) in.push_back((uint8_t)c);
		fclose(f);
	}

	Verilated::commandArgs(argc, argv);
	Vvdp_soc *t = new Vvdp_soc;
	t->reset = 1; t->ld_active = 0; t->ld_wr = 0; t->ez_rx_valid = 0; t->ez_tx_ready = 1;
	t->clk_pix = 0; t->aud_ce = 0; t->sim_shot_req = 0; t->sim_req = 0; t->sdr_dq_i = 0;

	bool open[4] = {false, false, false, false};
	uint32_t row[4] = {0, 0, 0, 0};
	int64_t act_at[4] = {-100, -100, -100, -100}, pre_at[4] = {-100, -100, -100, -100};
	struct Rd { int64_t at; uint32_t addr; };
	std::vector<Rd> rd;
	int64_t last_ref = 0;
	int errors = 0;
	uint64_t cyc = 0;
	auto err = [&](const char *m, int b) {
		if (errors++ < 20) fprintf(stderr, "SDRAM %s bank %d at cycle %llu\n", m, b, (unsigned long long)cyc);
	};

	for (int i = 0; i < 16; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
	t->reset = 0;
	const double clk_per_us = 75.0;
	const uint64_t frame = 75000000 / 60, aud = 75000000 / 16384;
	uint64_t next_vs = frame, next_aud = aud;
	int64_t in_start = -1;           // cycle of the first byte
	size_t in_pos = 0;
	int tx_state = 0;
	bool shot_asked = false, done = false;
	std::string line;
	uint64_t done_cyc = 0;
	int cap_state = 0;               // 1 wait for vsync, 2 wait for the picture, 3 taking it
	size_t cap_n = 0;
	std::vector<uint8_t> cap(640 * 480 * 3), shot;
	uint32_t shot_w = 0, shot_h = 0;
	while (!done && cyc < max_cycles) {
		t->sdr_dq_i = 0xdead;
		for (auto &r : rd) if (cyc == (uint64_t)r.at + 2) { uint16_t v; memcpy(&v, &sdram[r.addr * 2], 2); t->sdr_dq_i = v; }
		// the audio rate
		t->aud_ce = cyc >= next_aud;
		if (t->aud_ce) next_aud += aud;
		// the stream into the link
		t->ez_rx_valid = 0;
		if (in_start >= 0 && in_pos < in.size() && t->ez_cts &&
		    (double)(cyc - in_start) >= in_pos * 10.0 / baud * 75e6) {
			t->ez_rx_data = in[in_pos++]; t->ez_rx_valid = 1;
		}
		t->ez_tx_ready = 1;
		t->ps2_wr = 0;
		if (in_start >= 0 && ps2_pos < ps2.size() && cyc >= (uint64_t)in_start + 15000000 && cyc % 75000 == 0) {
			t->ps2_code = ps2[ps2_pos++]; t->ps2_wr = 1;
		}
		// (env SHOT_DELAY us: the screenshot that long after DONE, e.g. for the text cursor shown when idle)
		t->sim_shot_req = shot_asked && cyc >= done_cyc + (uint64_t)(getenv("SHOT_DELAY") ? atof(getenv("SHOT_DELAY")) * clk_per_us : 0);

		t->clk = 0; t->eval();
		// the bytes to the eZ80 (taken at this edge)
		if (t->ez_tx_valid) {
			uint8_t b = t->ez_tx_data;
			if (tx_state == 2 && b == 0xaa && !shot_asked) {
				shot_asked = true; done_cyc = cyc;
				printf("DONE us %.0f (from the first byte) at cycle %llu\n", (cyc - in_start) / clk_per_us, (unsigned long long)cyc);
				fflush(stdout);
			}
			if (getenv("TB_TX")) printf("tx %02x at %.1f ms\n", b, cyc / 75000.0);
			tx_state = (b == 0x80) ? 1 : (tx_state == 1 && b == 0x01) ? 2 : 0;
		}
		t->clk = 1; t->clk_pix = (cyc % 3) == 0; t->eval();
		cyc++;
		// the picture: after the screenshot one whole output frame (de) is taken
		if (t->clk_pix && cap_state) {
			if (cap_state == 1 && t->vid_vs) cap_state = 2;              // a vertical sync: the next frame
			else if (cap_state == 2 && !t->vid_vs && t->vid_de) cap_state = 3;
			if (cap_state == 3 && t->vid_de) {
				uint8_t *q = &cap[cap_n * 3];
				q[0] = t->vid_r * 85; q[1] = t->vid_g * 85; q[2] = t->vid_b * 85;
				if (++cap_n == 640 * 480) { cap_state = 0; done = true; }
			}
		}
		if (t->clk_pix) t->clk_pix = 0, t->eval();
		uint8_t c = (t->sdr_ras_n << 2) | (t->sdr_cas_n << 1) | t->sdr_we_n;
		int b = t->sdr_ba;
		uint32_t a = t->sdr_a;
		int64_t k = (int64_t)cyc;
		switch (c) {
		case 3:
			if (open[b]) err("ACTIVE to an open bank", b);
			if (k - pre_at[b] < 2) err("tRP", b);
			open[b] = true; row[b] = a; act_at[b] = k; break;
		case 5: case 4: {
			if (!open[b]) { err("READ/WRITE to a closed bank", b); break; }
			if (k - act_at[b] < 2) err("tRCD", b);
			uint32_t addr = ((uint32_t)b << 22) | (row[b] << 9) | (a & 0x1ff);
			if (c == 5) rd.push_back({k, addr});
			else {
				uint16_t v = t->sdr_dq_o;
				if (t->sdr_dq_oe_n != 0) err("WRITE without DQ driven", b);
				if (!(t->sdr_dqm & 1)) sdram[addr * 2] = v & 0xff;
				if (!(t->sdr_dqm & 2)) sdram[addr * 2 + 1] = v >> 8;
			}
			if (a & 0x400) { open[b] = false; pre_at[b] = k + 1; }
			break;
		}
		case 2:
			if (a & 0x400) { for (int i = 0; i < 4; i++) { open[i] = false; pre_at[i] = k; } }
			else { open[b] = false; pre_at[b] = k; }
			break;
		case 1:
			for (int i = 0; i < 4; i++) if (open[i]) err("REFRESH with a bank open", i);
			if (last_ref && k - last_ref > 585 + 600) err("refresh interval", 0);
			last_ref = k; break;
		default: break;
		}
		rd.erase(std::remove_if(rd.begin(), rd.end(), [&](const Rd &r) { return k > r.at + 3; }), rd.end());

		// MMIO side effects
		if (t->dbg_con_wr) { char ch = (char)t->dbg_con; if (ch == '\n') { printf("%s\n", line.c_str()); line.clear(); } else line += ch; }
		if (t->sim_shot_wr) {
			uint32_t w = t->sim_shot >> 16, h = t->sim_shot & 0xffff;
			if (shot_asked && ppm && w && h && w * h * 3 <= (8u << 20)) {
				FILE *pf = fopen(ppm, "wb");
				fprintf(pf, "P6\n%u %u\n255\n", w, h);
				fwrite(&sdram[SHOT_OFS], 1, (size_t)w * h * 3, pf);
				fclose(pf);
				printf("SHOT %s %ux%u, %.0f us after DONE\n", ppm, w, h, (cyc - done_cyc) / clk_per_us);
				shot_w = w; shot_h = h; shot.assign(&sdram[SHOT_OFS], &sdram[SHOT_OFS] + (size_t)w * h * 3);
				cap_state = 1;
			}
		}
		if (getenv("TB_DEBUG") && cyc % 2000000 == 0)
			fprintf(stderr, "[%6.1f ms] iadr %08x io %c%02x\n", cyc / 75000.0, t->dbg_iadr, (t->dbg_io & 0x100) ? 'w' : 'r', t->dbg_io & 0xff);
		if (t->dbg_exit & 0x100) { printf("EXIT %d\n", t->dbg_exit & 0xff); done = true; }
		// the stream starts in_after us after the firmware waits for bytes (its first EZ_STAT / EZ_RX)
		if (in_start < 0 && t->dbg_rx_poll) {
			in_start = (int64_t)(cyc + in_after * clk_per_us);
			printf("the firmware polls the link at %.1f ms\n", cyc / 75000.0); fflush(stdout);
		}
	}
	if (!shot.empty() && cap_n == 640 * 480) {
		// the screenshot on the 640x480 output as vdp_video must show it: doubled if 320 wide / 240
		// high, centred if smaller, cropped if bigger
		std::vector<uint8_t> want(640 * 480 * 3, 0);
		int xs = shot_w <= 320 ? 2 : 1, ys = shot_h <= 240 ? 2 : 1;
		int dw = shot_w * xs, dh = shot_h * ys;
		int x0 = dw >= 640 ? 0 : (640 - dw) / 2, y0 = dh >= 480 ? 0 : (480 - dh) / 2;
		for (int y = 0; y < 480; y++) for (int x = 0; x < 640; x++) {
			int sx = (x - x0) / xs, sy = (y - y0) / ys;
			if (x < x0 || y < y0 || x - x0 >= dw || y - y0 >= dh) continue;
			memcpy(&want[(y * 640 + x) * 3], &shot[(sy * shot_w + sx) * 3], 3);
		}
		std::string vp = std::string(ppm) + ".video.ppm";
		FILE *pf = fopen(vp.c_str(), "wb"); fprintf(pf, "P6\n640 480\n255\n"); fwrite(cap.data(), 1, cap.size(), pf); fclose(pf);
		size_t bad = 0;
		for (size_t i = 0; i < cap.size(); i += 3) if (memcmp(&cap[i], &want[i], 3)) bad++;
		printf("VIDEO %s: %s (%zu of %d pixels differ from the screenshot)\n", vp.c_str(), bad ? "DIFFERS" : "EQUAL", bad, 640 * 480);
		if (bad) { std::string wp = std::string(ppm) + ".want.ppm"; FILE *wf = fopen(wp.c_str(), "wb"); fprintf(wf, "P6\n640 480\n255\n"); fwrite(want.data(), 1, want.size(), wf); fclose(wf); }
	}
	printf("END cycles %llu (%.1f ms), input %zu/%zu, sdram errors %d%s\n", (unsigned long long)cyc, cyc / 75000.0,
	       in_pos, in.size(), errors, done ? "" : " (NOT DONE)");
	t->final();
	delete t;
	return (errors || !done) ? 1 : 0;
}
