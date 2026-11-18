// karabas: an SD card in SPI mode (SDHC, block addressing) for the system testbench, on an image
// file. The commands of the MOS driver (upstream/agon-mos/src/sd.asm): CMD0, CMD8, CMD55 +
// ACMD41, CMD58, CMD17 (read), CMD24 (write); others answer R1 = 0. Bit level: step() is given
// cs_n / sck / mosi each clock and returns miso (SPI mode 0: sampled on the rising edge, changed on
// the falling one). The sector sequence is logged for the comparison with the oracle.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <vector>
#include <string>

struct SdCard {
	FILE *img = nullptr;
	bool idle = true, app = false;
	std::deque<uint8_t> out;          // bytes to send
	std::vector<uint8_t> cmd;         // the command being received
	int wr_state = 0;                 // 0 none, 1 wait for FE, 2 data
	uint32_t wr_sector = 0;
	std::vector<uint8_t> wr_buf;
	std::vector<std::string> log;     // "R n" / "W n"
	// bit level
	int prev_sck = 0, bits = 0;
	uint8_t rx = 0, tx = 0xff, miso = 1;

	bool open(const char *path) { img = fopen(path, "r+b"); return img != nullptr; }

	void r1(uint8_t v) { out.push_back(0xff); out.push_back(v); }

	void command() {
		uint8_t c = cmd[0] & 0x3f;
		uint32_t arg = (uint32_t)cmd[1] << 24 | cmd[2] << 16 | cmd[3] << 8 | cmd[4];
		bool a = app; app = false;
		if (a && c == 41) { idle = false; r1(0x00); return; }
		switch (c) {
		case 0: idle = true; r1(0x01); break;
		case 8: r1(idle ? 0x01 : 0x00); out.push_back(0x00); out.push_back(0x00); out.push_back(0x01); out.push_back(arg & 0xff); break;
		case 55: app = true; r1(idle ? 0x01 : 0x00); break;
		case 58: r1(idle ? 0x01 : 0x00); out.push_back(0xc0); out.push_back(0xff); out.push_back(0x80); out.push_back(0x00); break;
		case 17: {
			r1(0x00);
			uint8_t buf[512] = {0};
			if (img) { fseek(img, (long)arg * 512, SEEK_SET); if (fread(buf, 1, 512, img) != 512) {} }
			log.push_back("R " + std::to_string(arg));
			out.push_back(0xff); out.push_back(0xfe);
			for (int i = 0; i < 512; i++) out.push_back(buf[i]);
			out.push_back(0xff); out.push_back(0xff);       // CRC
			break;
		}
		case 24: r1(0x00); wr_state = 1; wr_sector = arg; wr_buf.clear(); break;
		default: r1(0x00); break;
		}
	}

	// one received byte, returns the byte to send next
	uint8_t byte(uint8_t v) {
		if (wr_state == 1) {
			if (v == 0xfe) wr_state = 2;
		} else if (wr_state == 2) {
			wr_buf.push_back(v);
			if (wr_buf.size() == 514) {                  // 512 + CRC
				if (img) { fseek(img, (long)wr_sector * 512, SEEK_SET); fwrite(wr_buf.data(), 1, 512, img); fflush(img); }
				log.push_back("W " + std::to_string(wr_sector));
				wr_state = 0;
				out.push_back(0x05);                         // data accepted
				out.push_back(0x00);                         // busy one byte
			}
		} else if (!cmd.empty() || (v & 0xc0) == 0x40) {
			cmd.push_back(v);
			if (cmd.size() == 6) { command(); cmd.clear(); }
		}
		if (out.empty()) return 0xff;
		uint8_t o = out.front(); out.pop_front();
		return o;
	}

	int step(int cs_n, int sck, int mosi) {
		if (cs_n) { bits = 0; prev_sck = sck; miso = 1; return 1; }
		if (sck && !prev_sck) {                           // rising: sample
			rx = (rx << 1) | (mosi & 1);
			if (++bits == 8) { bits = 0; tx = byte(rx); }
		} else if (!sck && prev_sck) {                    // falling: the next bit out
			miso = (tx >> (7 - bits)) & 1;
		}
		if (bits == 0 && sck == 0 && prev_sck == 1) miso = (tx >> 7) & 1;
		prev_sck = sck;
		return miso;
	}
};
