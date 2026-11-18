// karabas: the picture for the scanout RTL (src/rtl/vdp, Ф1.4). At each vblank the firmware describes
// the frame the vdp-gl controller shows, the way its readEmulatorScreen() reads it (without the
// sprites: vdp-gl draws them per scan line, decorateScanLinePixels), and gives the address of the
// description to MMIO_SCAN; the RTL takes it at the start of its next frame. Two descriptions in
// turn, so the one the RTL reads is not rewritten under it.
//   d[0] = format | width << 16     format: 1 PALETTE2, 2 PALETTE4, 3 PALETTE8, 4 PALETTE16 (the
//                                   colour index -> palette), 6 SBGR2222 (a byte per pixel, the
//                                   byte of pixel x at x ^ 2); 0 = no picture
//   d[1] = height
//   d[2] = the row table: height words, the address of each row (vdp-gl m_viewPortVisible)
//   d[3] = height bytes: the palette of each row (an index into d[4])
//   d[4] = the palettes: 16 bytes each, RGB222 (bits 1..0 R, 3..2 G, 5..4 B) per colour index
// Pixel packing in a row: PALETTE2 1 bit, the leftmost pixel in bit 7; PALETTE4 2 bits, leftmost in
// bits 7..6; PALETTE8 3 bits, 8 pixels in 3 bytes read as a little-endian 24-bit word, the leftmost in
// bits 23..21; PALETTE16 4 bits, the leftmost in the high nibble.
//
// The members it needs are protected in vdp-gl: they are opened in this file only.
#define protected public
#include "fabgl.h"
#include "dispdrivers/vgabasecontroller.h"
#include "dispdrivers/vgapalettedcontroller.h"
#undef protected
#include "mmio.h"
#include "kg_scanout.h"

namespace {
const int MAXH = 1024, MAXPAL = 64;
struct Desc {
	uint32_t d[5];
	uint8_t rowpal[MAXH];
	uint8_t pal[MAXPAL][16];
};
Desc desc[2];
int cur = 0;

// RGB222 of colour index i of a vdp-gl signal table (packSignals of each controller)
uint8_t colour_of(fabgl::NativePixelFormat f, void *signals, int i) {
	switch (f) {
	case fabgl::NativePixelFormat::PALETTE2:  return ((uint8_t *)((uint64_t *)signals + (i ? 0xff : 0)))[0] & 0x3f;
	case fabgl::NativePixelFormat::PALETTE4:  return ((uint8_t *)((uint32_t *)signals + i * 0x55))[0] & 0x3f;
	case fabgl::NativePixelFormat::PALETTE8:  return ((uint16_t *)signals)[(i << 3) | i] & 0x3f;
	case fabgl::NativePixelFormat::PALETTE16: return ((uint16_t *)signals)[(i << 4) | i] & 0x3f;
	default: return 0;
	}
}
}

void kg_scanout_publish() {
	auto *vga = fabgl::VGABaseController::activeController;
	Desc &o = desc[cur ^ 1];
	if (!vga || !vga->is_started()) {
		o.d[0] = 0;
	} else {
		auto f = vga->nativePixelFormat();
		int fmt = f == fabgl::NativePixelFormat::PALETTE2 ? 1 : f == fabgl::NativePixelFormat::PALETTE4 ? 2 :
		          f == fabgl::NativePixelFormat::PALETTE8 ? 3 : f == fabgl::NativePixelFormat::PALETTE16 ? 4 :
		          f == fabgl::NativePixelFormat::SBGR2222 ? 6 : 0;
		int w = vga->getViewPortWidth(), h = vga->getViewPortHeight();
		if (h > MAXH) fmt = 0;
		o.d[0] = (uint32_t)fmt | (uint32_t)w << 16;
		o.d[1] = (uint32_t)h;
		o.d[2] = (uint32_t)(uintptr_t)(vga->isDoubleBuffered() ? vga->m_viewPortVisible : vga->m_viewPort);
		o.d[3] = (uint32_t)(uintptr_t)o.rowpal;
		o.d[4] = (uint32_t)(uintptr_t)o.pal;
		if (fmt >= 1 && fmt <= 4) {
			auto *pc = static_cast<fabgl::VGAPalettedController *>(vga);
			if (!pc->m_signalList) o.d[0] = 0;
			int n = 0, colours = 1 << (fmt == 1 ? 1 : fmt == 2 ? 2 : fmt == 3 ? 3 : 4);
			int y = 0;
			for (auto *it = pc->m_signalList; it && n < MAXPAL && y < h; it = it->next, n++) {
				for (int i = 0; i < 16; i++) o.pal[n][i] = i < colours ? colour_of(f, it->signals, i) : 0;
				int end = it->next ? it->endRow : h;
				for (; y < end && y < h; y++) o.rowpal[y] = (uint8_t)n;
			}
			for (; y < h; y++) o.rowpal[y] = (uint8_t)(n ? n - 1 : 0);
		}
	}
	cur ^= 1;
	MMIO_SCAN = (uint32_t)(uintptr_t)&desc[cur];
}
