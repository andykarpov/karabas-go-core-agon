// karabas: the frame description for the scanout RTL (kg_scanout.cpp)
#pragma once
#include <stdint.h>
void kg_scanout_publish();
// the debug overlay (Ctrl+Alt+D): the link counters and the last bytes each way (kg_serial.cpp)
extern bool kg_dbg_on;
extern uint32_t kg_dbg_rx_n, kg_dbg_tx_n;
extern uint8_t kg_dbg_rx[16], kg_dbg_tx[16];
