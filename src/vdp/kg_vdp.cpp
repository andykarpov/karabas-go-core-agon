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

// vblank of the video output -> vdp-gl (on the host: signal_vblank() of rust_glue.cpp)
static void kg_vblank_task(void *) {
	uint32_t last = MMIO_FRAME;
	for (;;) {
		uint32_t f = MMIO_FRAME;
		if (f != last) {
			last = f;
			fabgl::BaseDisplayController::vblankSignal.store(true);
			kg_scanout_publish();
		}
		coop_yield();
	}
}

// Serial2 (the eZ80 UART0) talks to MMIO directly: kg_serial.cpp
int main() {
	coop_init();
	init_userspace_fabgl();
	coop_spawn_named(kg_vblank_task, nullptr, 2048, "vblank");
	coop_spawn_named(kg_sim_task, nullptr, 8192, "sim");
	coop_spawn_named(kg_audio_task, nullptr, 8192, "audio-out");
	setup();
	for (;;) loop();
}
