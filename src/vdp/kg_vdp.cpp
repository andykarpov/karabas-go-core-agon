// The Agon Console8 VDP firmware (upstream/agon-vdp video.ino) on the soft CPU, the way
// fab-agon-emulator (src/vdp/vdp-console8.cpp + rust_glue.cpp) builds it for a host:
// vdp-gl from userspace-vdp-gl, tasks on the cooperative scheduler (coop.h).
#include "Arduino.h"
#include "vdp-console8.h"
#include "mmio.h"
#include "kg_scanout.h"

bool vdp_debug_logging = KG_VDP_DEBUG;
uint32_t startup_screen_mode = 0;

fabgl::SoundGenerator *getVDPSoundGenerator() {
	return &*soundGenerator;
}

#include "video/video.ino"

// Simulation only: screenshots at the requests of the sim (RGB888 at SHOT_BASE), and at its exit
// request the stack high-water marks of the tasks, then exit.
static void kg_sim_task(void *) {
	for (;;) {
		if (MMIO_SHOT) {
			auto lock = fabgl::VGABaseController::acquireLock();
			auto *vga = fabgl::VGABaseController::activeController;
			if (vga && vga->is_started()) {
				vga->readEmulatorScreen((fabgl::RGB888 *)SHOT_BASE);
				MMIO_SHOT = ((uint32_t)vga->getScreenWidth() << 16) | (uint32_t)vga->getScreenHeight();
			} else {
				MMIO_SHOT = 0;
			}
		}
		if (MMIO_SIMREQ & 1) {
			coop_report();
			fflush(stdout);
			MMIO_EXIT = 0;
		}
		coop_sleep_us(1000);
	}
}

// Audio: keep the output FIFO filled from the FabGL sound generator (on the host the emulator
// pulls getSample(); on the ESP32 the I2S DMA interrupt does it).
static void kg_audio_task(void *) {
	for (;;) {
		uint32_t n = MMIO_AUDIO;
		if (n) {
			auto lock = std::unique_lock<std::mutex>(soundGeneratorMutex);
			auto gen = getVDPSoundGenerator();
			while (n--) MMIO_AUDIO = gen ? (uint8_t)(gen->getSample() + 127) : 0x80;
		}
		coop_sleep_us(2000);
	}
}

// vblank of the video output -> vdp-gl (on the host: signal_vblank() of rust_glue.cpp). The frame
// counter too: in userspace-vdp-gl only readEmulatorScreen() counts it (the host emulator reads the
// screen every frame); the VDP needs it for the text cursor (shown after 3 idle frames) and
// the frame waits (setWaitForFrames: the Ctrl pause of the cursor control, a VDP variable).
static void kg_vblank_task(void *) {
	uint32_t last = MMIO_FRAME;
	for (;;) {
		uint32_t f = MMIO_FRAME;
		if (f != last) {
			last = f;
			if (auto *vga = fabgl::VGABaseController::activeController) vga->frameCounter++;
			fabgl::BaseDisplayController::vblankSignal.store(true);
			kg_scanout_publish();
		}
		coop_yield();
	}
}

// The mouse: the deltas of the board MCU (MMIO_MOUSE, USB: y + down) as the PS/2 packets the
// emulator injects (main.rs MouseMotion: byte 0 = 8 | buttons | x sign << 4 | y sign << 5, then
// x, y + up, the wheel); polled by the keyboard task (coop has 8 task slots)
static void kg_mouse_poll() {
	{
		uint32_t v = MMIO_MOUSE;
		auto *m = fabgl::PS2Controller::mouse();
		if ((v & 0x80000000u) && m) {
			int dx = (int)(v << 23) >> 23, dy = -((int)(v << 14) >> 23), dz = (int8_t)(v >> 18);
			if (dy > 255) dy = 255;
			if (dz > 7) dz = 7; else if (dz < -8) dz = -8;
			fabgl::MousePacket p;
			p.data[0] = 8 | ((v >> 26) & 7) | (dx < 0 ? 0x10 : 0) | (dy < 0 ? 0x20 : 0);
			p.data[1] = (uint8_t)dx;
			p.data[2] = (uint8_t)dy;
			p.data[3] = (uint8_t)dz;
			m->injectPacket(&p);
		}
	}
}

// The keyboard: PS/2 set 2 bytes of the board MCU (MMIO_KBD) into vdp-gl as the emulator does
// (rust_glue.cpp sendPS2KbEventToFabgl): E0 = an extended key (code | 0xE000), F0 = a release,
// E1 = Pause (E1 14 77 E1 F0 14 F0 77: VK_PAUSE on the first byte, the rest skipped).
static void kg_kbd_task(void *) {
	bool ext = false, rel = false;
	int skip = 0;
	for (;;) {
		uint32_t v = MMIO_KBD;
		if (!(v & 0x100)) { kg_mouse_poll(); coop_sleep_us(1000); continue; }
		uint8_t b = v & 0xff;
		auto *kb = fabgl::PS2Controller::keyboard();
		if (skip) { skip--; continue; }
		if (b == 0xe0) { ext = true; continue; }
		if (b == 0xf0) { rel = true; continue; }
		if (b == 0xe1) {
			skip = 7;
			if (kb) { fabgl::VirtualKeyItem item = {}; item.down = 1; item.vk = fabgl::VK_PAUSE; kb->injectVirtualKey(item, true); }
			continue;
		}
		if (kb) kb->injectScancode(ext ? (uint16_t)(0xe000 | b) : (uint16_t)b, rel ? 0 : 1);
		ext = rel = false;
	}
}

// Serial2 (the eZ80 UART0) talks to MMIO directly: kg_serial.cpp
int main() {
	coop_init();
	init_userspace_fabgl();
	coop_spawn_named(kg_vblank_task, nullptr, 2048, "vblank");
	coop_spawn_named(kg_sim_task, nullptr, 8192, "sim");
	coop_spawn_named(kg_audio_task, nullptr, 8192, "audio-out");
	coop_spawn_named(kg_kbd_task, nullptr, 4096, "kbd");
	setup();
	for (;;) loop();
}
