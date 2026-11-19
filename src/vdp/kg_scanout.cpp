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
//   d[5] = the sprite list (below)
//   d[6] = output | xdouble << 2 | ydouble << 3 | bytes of a source line << 16
//          output (Ф2, the timing of the board video): 0 640x480@60, 1 640x400@70, 2 800x600@60,
//          3 1024x768@60
//   d[7] = x0 | y0 << 16: the top left of the picture on the output
//   d[8] = vw | vh << 16: the visible size of the picture on the output (cropped to it)
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
#include <cstdio>

#ifndef KG_DBG_DEFAULT
#define KG_DBG_DEFAULT 0
#endif
bool kg_dbg_on = KG_DBG_DEFAULT;

namespace {
const int MAXH = 1024, MAXPAL = 64, MAXSPR = 32;
struct Desc {
	uint32_t d[9];
	uint8_t rowpal[MAXH];
	uint8_t pal[MAXPAL][16];
	uint32_t spr[1 + 4 * MAXSPR];
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

void add_entry(uint32_t *l, int xs, int ys, int dw, int dh, uint32_t a, int stride, int fm, bool x) {
	uint32_t *e = &l[1 + 4 * l[0]++];
	e[0] = (uint32_t)ys | (uint32_t)dh << 16;
	e[1] = (uint32_t)xs | (uint32_t)dw << 16;
	e[2] = a;
	e[3] = (uint32_t)(stride & 0xffff) | (uint32_t)fm << 16 | (x ? 1u << 17 : 0u);
}

// the debug overlay: DBG_COLS x DBG_ROWS characters of 8x8, RGBA2222 (white on opaque black)
const int DBG_COLS = 38, DBG_ROWS = 5, DBG_W = DBG_COLS * 8, DBG_H = DBG_ROWS * 8;
uint8_t dbg_px[DBG_W * DBG_H];
void dbg_text(int row, const char *t) {
	const uint8_t *font = fabgl::FONT_8x8.data;
	for (int c = 0; c < DBG_COLS; c++) {
		uint8_t ch = *t ? (uint8_t)*t++ : ' ';
		for (int y = 0; y < 8; y++) {
			uint8_t bits = font[ch * 8 + y];
			uint8_t *p = &dbg_px[(row * 8 + y) * DBG_W + c * 8];
			for (int x = 0; x < 8; x++) p[x] = (bits & (0x80 >> x)) ? 0xff : 0xc0;
		}
	}
}
void dbg_hex(char *o, const uint8_t *ring, uint32_t n) {
	// the last 12 bytes, the oldest first
	for (int i = 0; i < 12; i++) {
		uint32_t k = n - 12 + (uint32_t)i;
		if (n < 12 && i < (int)(12 - n)) { o += sprintf(o, ".. "); continue; }
		o += sprintf(o, "%02X ", ring[k & 15]);
	}
}
void dbg_overlay(uint32_t *l, int w, int h) {
	if (l[0] >= (uint32_t)MAXSPR) return;
	char t[64], u[48];
	uint32_t ez = MMIO_DBG_EZ;
	snprintf(t, sizeof t, "EZ80 PC %06lX RST %c HALT %c", (unsigned long)(ez & 0xffffff), (ez >> 31) ? '1' : '0', ((ez >> 30) & 1) ? '1' : '0');
	dbg_text(0, t);
	snprintf(t, sizeof t, "RX %lu  TX %lu  FR %lu", (unsigned long)kg_dbg_rx_n, (unsigned long)kg_dbg_tx_n, (unsigned long)MMIO_FRAME);
	dbg_text(1, t);
	dbg_hex(u, kg_dbg_rx, kg_dbg_rx_n); snprintf(t, sizeof t, "R %s", u); dbg_text(2, t);
	dbg_hex(u, kg_dbg_tx, kg_dbg_tx_n); snprintf(t, sizeof t, "T %s", u); dbg_text(3, t);
	snprintf(t, sizeof t, "STAT %08lX", (unsigned long)MMIO_EZ_STAT); dbg_text(4, t);
	int dw = DBG_W < w ? DBG_W : w, dh = DBG_H < h ? DBG_H : h;
	add_entry(l, 0, h - dh, dw, dh, (uint32_t)(uintptr_t)dbg_px + (uint32_t)((DBG_H - dh) * DBG_W), DBG_W, 0, false);
}

// one sprite of the list, the way rawDrawSpriteScanline() draws it, clipped to the vw x vh picture:
//   e[0] = its first line | lines << 16       e[1] = its first x | pixels << 16 (RGBA8888: <= 256)
//   e[2] = the address of its first pixel    e[3] = the bytes of a row | RGBA8888 << 16 | XOR << 17
void add_sprite(uint32_t *l, fabgl::Sprite *s, int vw, int vh) {
	if (!s || l[0] >= (uint32_t)MAXSPR) return;
	auto *f = s->getFrame();
	if (!f || !f->data || f->width <= 0 || f->height <= 0) return;
	int fm = f->format == fabgl::PixelFormat::RGBA2222 ? 0 : f->format == fabgl::PixelFormat::RGBA8888 ? 1 : -1;
	if (fm < 0) return;
	bool x = fm == 0 && s->paintOptions.mode == fabgl::PaintMode::XOR;
	int bpp = fm ? 4 : 1, w = f->width, h = f->height;
	int ox = s->x < 0 ? -s->x : 0, xs = s->x + ox, dw = (s->x + w < vw ? s->x + w : vw) - xs;
	int oy = s->y < 0 ? -s->y : 0, ys = s->y + oy, dh = (s->y + h < vh ? s->y + h : vh) - ys;
	if (dw <= 0 || dh <= 0) return;
	if (fm && dw > 256) dw = 256;      // (the RTL raw[] holds 1088 bytes)
	add_entry(l, xs, ys, dw, dh, (uint32_t)(uintptr_t)f->data + (uint32_t)((oy * w + ox) * bpp), w * bpp, fm, x);
}
}

// the output timing for a vdp-gl mode and the place of the w x h picture on it (Ф2, user 2026-11-19):
// 640x480@60 (640x480, 640x240, 320x240), 640x400@70 (320x200@70 / @75), 800x600@60, 1024x768@60
// (1024x768, 512x384, and 640x512 / 640x256 centred 1:1: 1280x1024 needs 108 MHz)
const int OUT_W[4] = { 640, 640, 800, 1024 }, OUT_H[4] = { 480, 400, 600, 768 };
void geometry(uint32_t *d, const fabgl::VGATimings &t, int fmt, int w, int h) {
	int lines = t.VVisibleArea * (t.scanCount ? t.scanCount : 1);   // the lines of the real VGA signal
	int out = t.frequency >= 50000000 || t.HVisibleArea == 512 || lines > 600 ? 3 :
	          t.HVisibleArea > 640 || lines > 480 ? 2 : lines == 400 ? 1 : 0;
	int ow = OUT_W[out], oh = OUT_H[out];
	int xs = ow >= 2 * w ? 1 : 0, ys = oh >= 2 * h ? 1 : 0;
	int dw = w << xs, dh = h << ys;
	int vw = dw < ow ? dw : ow, vh = dh < oh ? dh : oh;
	int x0 = dw < ow ? (ow - dw) / 2 : 0, y0 = dh < oh ? (oh - dh) / 2 : 0;
	int nb = fmt == 1 ? (w + 7) >> 3 : fmt == 2 ? (w + 3) >> 2 : fmt == 3 ? ((w + 7) >> 3) * 3 : fmt == 4 ? (w + 1) >> 1 : w;
	d[6] = (uint32_t)out | (uint32_t)xs << 2 | (uint32_t)ys << 3 | (uint32_t)nb << 16;
	d[7] = (uint32_t)x0 | (uint32_t)y0 << 16;
	d[8] = (uint32_t)vw | (uint32_t)vh << 16;
}

void kg_scanout_publish() {
	auto *vga = fabgl::VGABaseController::activeController;
	Desc &o = desc[cur ^ 1];
	o.spr[0] = 0;
	o.d[5] = (uint32_t)(uintptr_t)o.spr;
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
		if (o.d[0]) geometry(o.d, vga->m_timings, fmt, w, h);
		if (o.d[0]) {
			auto *pc = static_cast<fabgl::VGAPalettedController *>(vga);
			auto *t = pc->textCursor();
			if (t && t->visible) add_sprite(o.spr, t, w, h);
			auto *m = pc->mouseCursor();
			bool mv = m && m->visible;
			for (int i = 0; i < pc->spritesCount() && o.spr[0] < (uint32_t)MAXSPR - (mv ? 1 : 0) - (kg_dbg_on ? 1 : 0); i++) {
				auto *sp = pc->getSprite(i);
				if (sp->hardware && sp->visible && sp->allowDraw) add_sprite(o.spr, sp, w, h);
			}
			if (mv) add_sprite(o.spr, m, w, h);
			if (kg_dbg_on) dbg_overlay(o.spr, w, h);
		}
	}
	cur ^= 1;
	MMIO_SCAN = (uint32_t)(uintptr_t)&desc[cur];
}
