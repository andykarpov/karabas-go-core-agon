// karabas: the frame of the scanout description (src/vdp/kg_scanout.cpp) decoded in C++, as the
// scanout RTL must show it: for the ISS / RTL testbenches against the firmware's readEmulatorScreen().
// rd8(a) reads a byte of the VDP memory at CPU address a. Returns false if there is no picture.
#pragma once
#include <cstdint>
#include <vector>
#include <functional>

static bool scan_decode(uint32_t desc, const std::function<uint8_t(uint32_t)> &rd8,
                        std::vector<uint8_t> &rgb, int &w, int &h) {
	auto rd32 = [&](uint32_t a) { return (uint32_t)rd8(a) | rd8(a + 1) << 8 | rd8(a + 2) << 16 | (uint32_t)rd8(a + 3) << 24; };
	uint32_t d0 = rd32(desc);
	int fmt = d0 & 0xf;
	w = d0 >> 16; h = (int)rd32(desc + 4);
	if (!fmt || !w || !h) return false;
	uint32_t rows = rd32(desc + 8), rowpal = rd32(desc + 12), pals = rd32(desc + 16);
	rgb.assign((size_t)w * h * 3, 0);
	for (int y = 0; y < h; y++) {
		uint32_t row = rd32(rows + 4 * y);
		uint32_t pal = pals + 16 * rd8(rowpal + y);
		for (int x = 0; x < w; x++) {
			uint8_t c;
			switch (fmt) {
			case 1: c = rd8(pal + ((rd8(row + (x >> 3)) >> (7 - (x & 7))) & 1)); break;
			case 2: c = rd8(pal + ((rd8(row + (x >> 2)) >> (6 - (x & 3) * 2)) & 3)); break;
			case 3: { uint32_t a = row + (x >> 3) * 3; uint32_t v = rd8(a) | rd8(a + 1) << 8 | rd8(a + 2) << 16;
			          c = rd8(pal + ((v >> (21 - (x & 7) * 3)) & 7)); break; }
			case 4: c = rd8(pal + ((x & 1) ? (rd8(row + (x >> 1)) & 15) : (rd8(row + (x >> 1)) >> 4))); break;
			default: c = rd8(row + (x ^ 2)); break;
			}
			uint8_t *p = &rgb[((size_t)y * w + x) * 3];
			p[0] = (c & 3) * 85; p[1] = ((c >> 2) & 3) * 85; p[2] = ((c >> 4) & 3) * 85;
		}
	}
	return true;
}
