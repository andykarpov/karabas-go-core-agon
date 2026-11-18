// HardwareSerial of userspace-vdp-gl (its header, our methods) on the soft CPU: Serial2 = the eZ80
// UART0 behind MMIO_EZ_*, DBGSerial (the int constructor) = the debug console. Replaces
// userspace-platform/HardwareSerial.cpp, whose queues are fed by host threads.
// The VDP polls in busy loops (wait_eZ80, readBytes): an empty receive yields to the other
// cooperative tasks, so the loops cannot starve them; a full one yields every KG_RX_SLICE_US.
#include "HardwareSerial.h"
#include "coop.h"
#include "mmio.h"
#include "kg_scanout.h"

uint32_t kg_dbg_rx_n, kg_dbg_tx_n;
uint8_t kg_dbg_rx[16], kg_dbg_tx[16];

HardwareSerial Serial2;
FILE *dbg_serial_sink = nullptr;
extern bool is_fabgl_terminating;

// move the bytes waiting in the UART into the receive queue
static void kg_rx_pump(rigtorp::SPSCQueue<uint8_t> &q) {
	while (q.size() < q.capacity() && (MMIO_EZ_STAT & 1)) {
		uint32_t v = MMIO_EZ_RX;
		if (!(v & 0x100)) break;
		q.push((uint8_t)v);
		kg_dbg_rx[kg_dbg_rx_n++ & 15] = (uint8_t)v;
	}
}

// The VDP yields only when the input is empty; while the eZ80 keeps it full (the VDP is slower
// than the UART) the other tasks (audio) would starve: yield at least every KG_RX_SLICE_US.
#define KG_RX_SLICE_US 1000
static uint64_t kg_last_yield;

int HardwareSerial::available() {
	if (m_hacky_debug_output_to_stdout) return 0;
	kg_rx_pump(m_buf_in);
	int n = (int)m_buf_in.size();
	uint64_t now = coop_now_us();
	if (!n || now - kg_last_yield >= KG_RX_SLICE_US) {
		coop_yield();
		kg_last_yield = coop_now_us();
	}
	return n;
}
int HardwareSerial::read() {
	if (m_hacky_debug_output_to_stdout) return -1;
	kg_rx_pump(m_buf_in);
	if (m_buf_in.empty()) return -1;
	uint8_t v = *m_buf_in.front();
	m_buf_in.pop();
	return v;
}
int HardwareSerial::peek() {
	if (m_hacky_debug_output_to_stdout) return -1;
	kg_rx_pump(m_buf_in);
	if (m_buf_in.empty()) return -1;
	return *m_buf_in.front();
}
int HardwareSerial::readBytes(uint8_t *buffer, int len) {
	for (int i = 0; i < len && !is_fabgl_terminating; i++) {
		while (!available()) {}
		buffer[i] = (uint8_t)read();
	}
	return len;
}
size_t HardwareSerial::write(uint8_t c) {
	if (m_hacky_debug_output_to_stdout) {
		MMIO_CON = c;
		return 1;
	}
	while (!(MMIO_EZ_STAT & 2)) coop_yield();
	MMIO_EZ_TX = c;
	kg_dbg_tx[kg_dbg_tx_n++ & 15] = c;
	return 1;
}
// host-side hooks of the emulator, unused here
void HardwareSerial::writeToInQueue(uint8_t c) {
	if (m_buf_in.size() < m_buf_in.capacity()) m_buf_in.push(c);
}
bool HardwareSerial::readFromOutQueue(uint8_t *out) {
	(void)out;
	return false;
}
