/* VDP soft CPU MMIO (Ф0 draft, the same base as the core-doom bench; src/sim follows it).
   Memory map: SRAM 4 MB at 0x00000000, SDRAM 32 MB at 0x10000000, MMIO at 0x80000000
   (VexRiscv IO range = bit 31, uncached). */
#pragma once
#include <stdint.h>

#define MMIO_REG(o) (*(volatile uint32_t *)(0x80000000u + (o)))
#define MMIO_CON     MMIO_REG(0x00) /* write: debug console byte */
#define MMIO_EXIT    MMIO_REG(0x08) /* write: stop the simulation with this code */
#define MMIO_CYCLES  MMIO_REG(0x0c) /* read: clock cycles (ISS: instructions), low 32 bits */
#define MMIO_US_LO   MMIO_REG(0x10) /* read: microsecond counter, low 32 bits */
#define MMIO_US_HI   MMIO_REG(0x14) /* read: microsecond counter, high 32 bits */
#define MMIO_MS      MMIO_REG(0x1c) /* read: milliseconds */
#define MMIO_EZ_RX   MMIO_REG(0x40) /* read: byte from the eZ80 UART0, bit 8 = valid (pops it) */
#define MMIO_EZ_TX   MMIO_REG(0x44) /* write: byte to the eZ80 UART0 */
#define MMIO_EZ_STAT MMIO_REG(0x48) /* read: bit 0 = rx byte waiting, bit 1 = tx FIFO has room */
#define MMIO_MARK    MMIO_REG(0x50) /* write: benchmark mark (the sim logs counters at it) */
#define MMIO_SHOT    MMIO_REG(0x54) /* sim only. read: screenshot requests pending; write: (w << 16) | h,
                                       the sim saves the RGB888 picture at SHOT_BASE */
#define SHOT_BASE    0x11800000u    /* SDRAM, above the firmware region */
