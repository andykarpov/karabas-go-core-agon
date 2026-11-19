/* karabas: stub of CEmu's mem.h: the Agon memory map lives in main.c */
#pragma once
#include <stdint.h>
#include <stdbool.h>
uint8_t mem_read_cpu(uint32_t address, bool fetch);
void mem_write_cpu(uint32_t address, uint8_t value);
