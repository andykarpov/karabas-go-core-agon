// The Agon Console8 VDP firmware (upstream/agon-vdp video.ino) on the soft CPU, the way
// fab-agon-emulator (src/vdp/vdp-console8.cpp + rust_glue.cpp) builds it for a host:
// vdp-gl from userspace-vdp-gl, tasks on the cooperative scheduler (coop.h).
#include "Arduino.h"
#include "vdp-console8.h"
#include "mmio.h"

bool vdp_debug_logging = KG_VDP_DEBUG;
uint32_t startup_screen_mode = 0;

fabgl::SoundGenerator *getVDPSoundGenerator() {
	return &*soundGenerator;
}

#include "video/video.ino"

// Simulation only: on a request of the sim (MMIO_SHOT), the screen as RGB888 at SHOT_BASE.
static void kg_shot_task(void *) {
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
		coop_sleep_us(10000);
	}
}

// Serial2 (the eZ80 UART0) talks to MMIO directly: kg_serial.cpp
int main() {
	coop_init();
	init_userspace_fabgl();
	coop_spawn(kg_shot_task, nullptr, 4096);
	setup();
	for (;;) loop();
}
