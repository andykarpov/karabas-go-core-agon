// karabas: Ф1.3 system testbench: the eZ80 core + the F92 periphery in RTL (sys_top.v) running MOS
// from the flash image with an SD image, a fake VDP on UART0 (the VDU parser of the oracle's
// main.rs: answers the general poll, the mode information and the RTC), vsync on PB1 every 1/60 s
// of F92 time. Keys are event-driven: each step of --keys (steps split by '|') is typed when the
// VDP output went quiet after a prompt ('*' of MOS, '>' of BASIC), so the VDU stream does not
// depend on timing. Writes the VDU stream to --vdp-out (compare with agon-oracle --vdp-out) and the
// SD sectors to --sd-log.
//   sys_tb --flash mos.bin --sd sd.img [--keys 'cat\r|...'] [--ms N (F92 time)] [--cpu-mhz F]
//          [--vdp-out f] [--sd-log f] [--quiet]
// --cpu-mhz: the core clock against the 18.432 MHz system clock (default 56; smaller = MOS delay
// loops in fewer core clocks).
#include "Vsys_top.h"
#include "verilated.h"
#include "sdcard.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <string>
#include <vector>
#include <algorithm>

struct Vdp {
	std::deque<uint8_t> to_ez80;
	std::vector<uint8_t> pending;
	FILE *log = nullptr;
	bool quiet = false;
	std::string screen;
	void reply(std::initializer_list<uint8_t> b) { for (auto x : b) to_ez80.push_back(x); }
	void put(uint8_t c) {
		if (log) fputc(c, log);
		if (pending.empty()) {
			if ((c >= 0x20 && c <= 0x7e) || c == 0x0a || c == 0x08) {
				screen += (char)c;
				if (!quiet) { putchar(c); fflush(stdout); }
				return;
			}
			switch (c) {
			case 1: case 17: case 18: case 19: case 22: case 23: case 24: case 25: case 28: case 29: case 31:
				pending.push_back(c); return;
			default: return;
			}
		}
		pending.push_back(c);
		auto &p = pending;
		size_t need;
		switch (p[0]) {
		case 1: case 17: case 22: need = 2; break;
		case 18: case 31: need = 3; break;
		case 19: need = 6; break;
		case 24: need = 9; break;
		case 25: need = 6; break;
		case 28: case 29: need = 5; break;
		case 23:
			if (p.size() < 3) need = 3;
			else if (p[1] == 0) {
				// the lengths of VDU 23,0,cmd from agon-vdp vdu_sys.h (as the oracle's main.rs)
				switch (p[2]) {
				case 0x87: need = (p.size() >= 4 && p[3] == 1) ? 10 : 4; break;
				case 0x0a: case 0x0b: case 0x80: case 0x81: case 0x8a: case 0x8b: case 0x94: case 0x98:
				case 0x99: case 0xc0: case 0xc1: case 0xf2: case 0xfe: need = 4; break;
				case 0x82: case 0x86: case 0x91: case 0x9a: case 0x9c: case 0x9d: case 0x9e: case 0x9f:
				case 0xc3: case 0xca: case 0xff: need = 3; break;
				case 0x83: case 0x84: case 0x93: case 0xf8: need = 7; break;
				case 0x88: need = 8; break;
				case 0x8c: case 0x9b: case 0xf9: need = 5; break;
				case 0x92: case 0x96: need = 6; break;
				case 0x90: need = 12; break;
				default: need = 10;
				}
			} else need = 10;
			break;
		default: need = 1;
		}
		if (p.size() < need) return;
		std::vector<uint8_t> cmd; cmd.swap(pending);
		if (cmd[0] == 23 && cmd[1] == 0) {
			switch (cmd[2]) {
			case 0x80: reply({0x80, 1, cmd[3]}); break;
			case 0x86: reply({0x86, 7, 0x80, 2, 0xe0, 1, 80, 60, 16}); break;
			case 0x87: if (cmd[3] == 0) reply({0x87, 6, 46, 10, 18, 12, 0, 0}); break;
			case 0x94: reply({0x84, 4, 0xff, 0xff, 0xff, (uint8_t)(cmd[3] < 64 ? cmd[3] : 15)}); break;
			case 0xf8: case 0x99: break;      // no reply (0x99: the key state comes in key packets)
			default: if (!quiet) fprintf(stderr, "[fake vdp: VDU 23,0,&%02x not answered]\n", cmd[2]);
			}
		}
	}
};

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *flashf = nullptr, *sdf = nullptr, *vdpf = nullptr, *sdlogf = nullptr;
	std::string keys;
	double ms = 5000, cpu_mhz = 56;
	bool quiet = false;
	// --vdp-rate B: the VDP side as a 64-byte FIFO drained at B bytes per second of F92 time, CTS
	// low above 48 bytes, bytes to the eZ80 at most one per 1/B s (0: everything at once, CTS high)
	double vdp_rate = 0;
	const bool dbg = getenv("SYS_DEBUG") != nullptr;   // every 100 ms: PC and the port traffic
	uint64_t iord = 0, iowr = 0, next_dbg = 0;
	char last_io[64] = "";
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--flash")) flashf = argv[++i];
		else if (!strcmp(argv[i], "--sd")) sdf = argv[++i];
		else if (!strcmp(argv[i], "--keys")) keys = argv[++i];
		else if (!strcmp(argv[i], "--ms")) ms = atof(argv[++i]);
		else if (!strcmp(argv[i], "--cpu-mhz")) cpu_mhz = atof(argv[++i]);
		else if (!strcmp(argv[i], "--vdp-out")) vdpf = argv[++i];
		else if (!strcmp(argv[i], "--sd-log")) sdlogf = argv[++i];
		else if (!strcmp(argv[i], "--quiet")) quiet = true;
		else if (!strcmp(argv[i], "--vdp-rate")) vdp_rate = atof(argv[++i]);
	}
	if (!flashf) { fprintf(stderr, "usage: %s --flash mos.bin --sd sd.img [--keys ..] [--ms N]\n", argv[0]); return 2; }
	// keys: \r -> Enter, steps split by '|'
	std::vector<std::string> steps(1);
	for (size_t i = 0; i < keys.size(); i++) {
		if (keys[i] == '\\' && i + 1 < keys.size() && keys[i + 1] == 'r') { steps.back() += '\r'; i++; }
		else if (keys[i] == '|') steps.emplace_back();
		else steps.back() += keys[i];
	}
	if (steps.back().empty()) steps.pop_back();

	std::vector<uint8_t> flash(0x20000, 0xff), ram(8192), ext(0x80000);
	{ FILE *f = fopen(flashf, "rb"); if (!f) { perror(flashf); return 2; } if (fread(flash.data(), 1, flash.size(), f) == 0) {} fclose(f); }
	SdCard sd;
	if (sdf && !sd.open(sdf)) { perror(sdf); return 2; }
	Vdp vdp; vdp.quiet = quiet;
	if (vdpf) vdp.log = fopen(vdpf, "wb");

	Vsys_top *t = new Vsys_top;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->reset_n = 0; t->sys_ce = 0; t->u0_cts = 1; t->sd_miso = 1; t->vsync = 0;
	for (int i = 0; i < 8; i++) tick();
	t->reset_n = 1;

	const double ce_per_clk = 18.432 / cpu_mhz;
	double acc = 0;
	uint64_t sys = 0, clocks = 0, insns = 0;
	const uint64_t sys_end = (uint64_t)(ms * 18432), frame = 18432000 / 60;
	uint64_t next_vsync = frame, last_out = 0, next_key = 0;
	size_t step = 0, kpos = 0; int kdown = 0;
	std::deque<std::pair<uint8_t, uint8_t>> kq;
	std::deque<uint8_t> vfifo;
	uint64_t next_drain = 0, next_rx = 0;
	size_t stall_max = 0;
	while (sys < sys_end) {
		// the clock enable of the F92 system clock
		acc += ce_per_clk;
		t->sys_ce = acc >= 1.0;
		if (t->sys_ce) { acc -= 1.0; sys++; }
		// vsync: a pulse on PB1
		t->vsync = sys >= next_vsync && sys < next_vsync + 64;
		if (sys >= next_vsync + 64) next_vsync += frame;
		// VDP -> eZ80 (keyboard packets come in its replies)
		if (kq.empty() && step < steps.size() && sys >= next_key && sys - last_out > 18432 * 50 &&
		    !vdp.screen.empty() && (vdp.screen.back() == '*' || vdp.screen.back() == '>')) {
			for (char c : steps[step]) { kq.push_back({(uint8_t)c, 1}); kq.push_back({(uint8_t)c, 0}); }
			step++;
		}
		if (!kq.empty() && sys >= next_key && vdp.to_ez80.empty()) {
			auto k = kq.front(); kq.pop_front();
			vdp.reply({0x81, 4, k.first, 0, 0, k.second});
			next_key = sys + 18432 * 20;                 // 20 ms per press / release
			if (kq.empty()) last_out = sys;
		}
		t->u0_rx_valid = 0;
		t->eval();
		bool rx_ok = vdp_rate == 0 || sys >= next_rx;
		if (rx_ok && !vdp.to_ez80.empty() && !t->u0_rx_full) {
			t->u0_rx_data = vdp.to_ez80.front(); t->u0_rx_valid = 1; vdp.to_ez80.pop_front();
			if (vdp_rate > 0) next_rx = sys + (uint64_t)(18432000 / vdp_rate);
		}
		// eZ80 -> VDP
		if (vdp_rate == 0) {
			t->u0_tx_ready = t->u0_tx_valid;
			if (t->u0_tx_valid) { vdp.put(t->u0_tx_data); last_out = sys; }
		} else {
			if (!vfifo.empty() && sys >= next_drain) {
				vdp.put(vfifo.front()); vfifo.pop_front(); last_out = sys;
				next_drain = sys + (uint64_t)(18432000 / vdp_rate);
			}
			t->u0_tx_ready = t->u0_tx_valid && vfifo.size() < 64;
			if (t->u0_tx_ready) { vfifo.push_back(t->u0_tx_data); last_out = sys; }
			t->u0_cts = vfifo.size() <= 48;
			stall_max = std::max(stall_max, vfifo.size());
		}
		// memory
		uint8_t md = 0xf5;
		if (t->sel_ram) md = ram[t->maddr & 0x1fff];
		else if (t->sel_flash) md = flash[t->flash_ofs];
		else if (t->sel_ext) md = ext[t->maddr & 0x7ffff];
		t->mem_di = md;
		// SD
		t->eval();
		t->sd_miso = sd.step(t->sd_cs_n, t->sd_sck, t->sd_mosi);
		t->eval();
		if (t->mwr) {
			if (t->sel_ram) ram[t->maddr & 0x1fff] = t->mdo;
			else if (t->sel_ext) ext[t->maddr & 0x7ffff] = t->mdo;
		}
		if (dbg && (t->dbg_io_rd || t->dbg_io_wr)) {
			(t->dbg_io_rd ? iord : iowr)++;
			snprintf(last_io, sizeof last_io, "%s:%02x=%02x", t->dbg_io_rd ? "r" : "o", t->maddr & 0xff, t->dbg_io_d);
			static long shown = 0;
			if (getenv("SYS_IO") && (t->maddr & 0xff) > 0x82 && shown < atol(getenv("SYS_IO"))) { shown++; fprintf(stderr, "  io %s pc %06x\n", last_io, t->regx[0] & 0xffffff); }
		}
		if (dbg && sys >= next_dbg) {
			fprintf(stderr, "[%5.0f ms] pc %06x adl %d insns %llu io r %llu w %llu last %s\n", sys / 18432.0,
			        t->regx[0] & 0xffffff, (t->regx[1] >> 24) & 1, (unsigned long long)insns,
			        (unsigned long long)iord, (unsigned long long)iowr, last_io);
			next_dbg += 18432 * 100;
		}
		tick();
		clocks++;
		if (t->insn) insns++;
	}
	if (vdp.log) fclose(vdp.log);
	if (sdlogf) { FILE *f = fopen(sdlogf, "w"); for (auto &s : sd.log) fprintf(f, "%s\n", s.c_str()); fclose(f); }
	if (vdp_rate > 0) printf("\nvdp link: %.0f B/s, FIFO up to %zu bytes", vdp_rate, stall_max);
	printf("\nsys: %.0f ms of F92 time, %llu core clocks, %llu instructions, %zu SD sectors, keys %zu / %zu steps\n",
	       sys / 18432.0, (unsigned long long)clocks, (unsigned long long)insns, sd.log.size(), step, steps.size());
	delete t;
	return 0;
}
