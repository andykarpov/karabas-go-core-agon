#pragma once
#include <stdint.h>
uint8_t bus_rand(void);   /* karabas: stub */
uint8_t port_read_byte(uint16_t addr);   /* karabas: stub */
void port_write_byte(uint16_t addr, uint8_t value);
