// karabas: Ф1.4 step 4: the whole Agon in RTL (agon_sim_top.v): MOS on the eZ80 + F92 talks to the
// real VDP firmware on vdp_soc through agon_link; the output frame of the scanout is the result.
// Clocks from a 150 MHz tick: clk_vdp 75 MHz (/2), clk_pix 25 MHz (/6), clk_ez 18.75 MHz (/8; the F92
// system clock enable always on: the PRT / SPI rates of an 18.75 MHz F92). C++ models: the eZ80
// memories through the F92 map (flash = MOS, on-chip SRAM 8K, external 512K), the SD card
// (sdcard.h), the SDRAM at its pins (as tb_vdp.cpp, the VDP firmware put at SDRAM 0).
// After the MOS prompt ("*" of "/ *", then --after ms of quiet) one output frame -> --ppm.
//   tb_agon --mos mos.bin --vdp vdp.bin --sd sd.img --ppm out.ppm [--ms N (eZ80 time)] [--after ms]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include "Vagon_sim_top.h"
#include "verilated.h"
#include "../sys/sdcard.h"

static std::vector<uint8_t> sdram(32u << 20), flash(0x20000, 0xff), ram(8192), ext(0x80000);

static bool load(const char *f, uint8_t *p, size_t n) {
	FILE *h = fopen(f, "rb");
	if (!h) { perror(f); return false; }
	size_t k = fread(p, 1, n, h);
	fclose(h);
	fprintf(stderr, "%s: %zu bytes\n", f, k);
	return true;
}

int main(int argc, char **argv) {
	const char *mosf = nullptr, *vdpf = nullptr, *sdf = nullptr, *ppm = nullptr;
	double ms = 6000, after = 200;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--mos")) mosf = argv[++i];
		else if (!strcmp(argv[i], "--vdp")) vdpf = argv[++i];
		else if (!strcmp(argv[i], "--sd")) sdf = argv[++i];
		else if (!strcmp(argv[i], "--ppm")) ppm = argv[++i];
		else if (!strcmp(argv[i], "--ms")) ms = atof(argv[++i]);
		else if (!strcmp(argv[i], "--after")) after = atof(argv[++i]);
	}
	if (!mosf || !vdpf || !ppm) { fprintf(stderr, "usage: %s --mos mos.bin --vdp vdp.bin --sd sd.img --ppm out.ppm\n", argv[0]); return 2; }
	if (!load(mosf, flash.data(), flash.size()) || !load(vdpf, sdram.data(), sdram.size())) return 2;
	SdCard sd;
	if (sdf && !sd.open(sdf)) { perror(sdf); return 2; }

	Verilated::commandArgs(argc, argv);
	Vagon_sim_top *t = new Vagon_sim_top;
	t->reset_n = 0; t->sys_ce = 1; t->sd_miso = 1; t->aud_ce = 0; t->sim_shot_req = 0; t->sdr_dq_i = 0;
	t->clk_ez = 0; t->clk_vdp = 0; t->clk_pix = 0; t->mem_di = 0xff;

	// SDRAM model (core-doom tb_rtl.cpp)
	bool open[4] = {false, false, false, false};
	uint32_t row[4] = {0, 0, 0, 0};
	int64_t act_at[4] = {-100, -100, -100, -100}, pre_at[4] = {-100, -100, -100, -100};
	struct Rd { int64_t at; uint32_t addr; };
	std::vector<Rd> rd;
	int64_t last_ref = 0;
	int errors = 0;
	uint64_t vcyc = 0, ecyc = 0, tick = 0;
	auto err = [&](const char *m, int b) {
		if (errors++ < 20) fprintf(stderr, "SDRAM %s bank %d at cycle %llu\n", m, b, (unsigned long long)vcyc);
	};

	const uint64_t ticks_end = (uint64_t)(ms * 150000), aud_ticks = 150000000 / 16384;
	uint64_t next_aud = aud_ticks, reset_end = 2000;
	std::string text;                 // the printable bytes MOS sent
	uint64_t prompt_tick = 0;         // the tick of the last byte after a '*'
	int cap_state = 0;                // 1 wait for vsync, 2 wait for the picture, 3 taking it
	size_t cap_n = 0;
	std::vector<uint8_t> cap(640 * 480 * 3);
	bool done = false;
	std::string con;
	uint64_t n_ez = 0, n_v = 0, n_vrx = 0;
	while (!done && tick < ticks_end) {
		tick++;
		if (tick == reset_end) t->reset_n = 1;
		// (the edges of different clocks never in the same eval)
		bool ev = tick % 2 == 0, ee = tick % 8 == 1 && !getenv("TB_NOEZ"), ep = tick % 6 == 3;
		t->aud_ce = 0;
		if (ev && tick >= next_aud) { t->aud_ce = 1; next_aud += aud_ticks; }
		if (ev) {
			// the read data, then the falling edge of clk_vdp (vdp_sdram takes DQ on it), as tb_vdp.cpp
			t->sdr_dq_i = 0xdead;
			for (auto &r : rd) if (vcyc == (uint64_t)r.at + 2) { uint16_t v; memcpy(&v, &sdram[r.addr * 2], 2); t->sdr_dq_i = v; }
			t->clk_vdp = 0;
			t->eval();
		}
		if (ee) {
			t->eval();
			uint8_t md = 0xf5;
			if (t->sel_ram) md = ram[t->maddr & 0x1fff];
			else if (t->sel_flash) md = flash[t->flash_ofs];
			else if (t->sel_ext) md = ext[t->maddr & 0x7ffff];
			t->mem_di = md;
			t->sd_miso = sd.step(t->sd_cs_n, t->sd_sck, t->sd_mosi);
			t->eval();
			if (t->mwr) {
				if (t->sel_ram) ram[t->maddr & 0x1fff] = t->mdo;
				else if (t->sel_ext) ext[t->maddr & 0x7ffff] = t->mdo;
			}
			if (t->dbg_ez_tx_wr) {
				uint8_t c = t->dbg_ez_tx;
				if (getenv("TB_LINK") && n_ez < 64) { fprintf(stderr, "[%7.1f ms] ez -> vdp %02x cts %d\n", tick / 150000.0, c, t->dbg_cts); }
				n_ez++;
				if ((c >= 0x20 && c < 0x7f) || c == '\n') { text += (char)c; putchar(c); fflush(stdout); }
				prompt_tick = (!text.empty() && text.back() == '*') ? tick : 0;
			}
		}
		// the rising edges
		if (ev) t->clk_vdp = 1;
		t->clk_ez = ee; t->clk_pix = ep;
		t->eval();
		if (ev) {
			vcyc++;
			uint8_t c = (t->sdr_ras_n << 2) | (t->sdr_cas_n << 1) | t->sdr_we_n;
			int b = t->sdr_ba;
			uint32_t a = t->sdr_a;
			int64_t k = (int64_t)vcyc;
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
			if (t->dbg_v_tx_wr) {
				if (getenv("TB_LINK") && n_v < 64) fprintf(stderr, "[%7.1f ms] vdp -> ez %02x\n", tick / 150000.0, t->dbg_v_tx);
				n_v++;
			}
			if (t->dbg_v_rx_wr) n_vrx++;
			if (t->dbg_con_wr) { char ch = (char)t->dbg_con; if (ch == '\n') { fprintf(stderr, "[vdp] %s\n", con.c_str()); con.clear(); } else con += ch; }
		}
		if (ee) ecyc++;
		if (getenv("TB_LINK") && tick % (getenv("TB_STEP") ? atol(getenv("TB_STEP")) : 15000000) == 0)
			fprintf(stderr, "[%7.1f ms] vdp run %d iadr %08x bus %02x, ez pc %06x\n", tick / 150000.0, t->dbg_vrun, t->dbg_viadr, t->dbg_vbus, t->regx[0] & 0xffffff);
		if (ep && cap_state) {
			if (cap_state == 1 && t->vid_vs) cap_state = 2;
			else if (cap_state == 2 && !t->vid_vs && t->vid_de) cap_state = 3;
			if (cap_state == 3 && t->vid_de) {
				uint8_t *q = &cap[cap_n * 3];
				q[0] = t->vid_r * 85; q[1] = t->vid_g * 85; q[2] = t->vid_b * 85;
				if (++cap_n == 640 * 480) { cap_state = 0; done = true; }
			}
		}
		if (!cap_state && !done && prompt_tick && tick - prompt_tick > (uint64_t)(after * 150000)) {
			cap_state = 1;
			printf("\n[the MOS prompt at %.0f ms: taking a frame]\n", prompt_tick / 150000.0);
		}
		t->clk_ez = 0; t->clk_pix = 0;      // (clk_vdp falls at its next tick, after the read data)
		t->eval();
	}
	if (cap_n == 640 * 480) {
		FILE *pf = fopen(ppm, "wb");
		fprintf(pf, "P6\n640 480\n255\n");
		fwrite(cap.data(), 1, cap.size(), pf);
		fclose(pf);
	}
	printf("\nlink: eZ80 sent %llu, VDP took %llu, VDP sent %llu bytes", (unsigned long long)n_ez, (unsigned long long)n_vrx, (unsigned long long)n_v);
	printf("\nEND %.0f ms, eZ80 %llu clocks, VDP %llu clocks, %zu SD sectors, sdram errors %d, frame %s\n",
	       tick / 150000.0, (unsigned long long)ecyc, (unsigned long long)vcyc, sd.log.size(), errors,
	       cap_n == 640 * 480 ? ppm : "NOT TAKEN");
	t->final();
	delete t;
	return (errors || cap_n != 640 * 480) ? 1 : 0;
}
