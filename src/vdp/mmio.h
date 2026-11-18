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
#define MMIO_FRAME   MMIO_REG(0x18) /* read: frame counter of the video output (+1 at each vblank) */
#define MMIO_MS      MMIO_REG(0x1c) /* read: milliseconds */
#define MMIO_EZ_RX   MMIO_REG(0x40) /* read: byte from the eZ80 UART0, bit 8 = valid (pops it) */
#define MMIO_EZ_TX   MMIO_REG(0x44) /* write: byte to the eZ80 UART0 */
#define MMIO_EZ_STAT MMIO_REG(0x48) /* read: bit 0 = rx byte waiting, bit 1 = tx FIFO has room */
#define MMIO_MARK    MMIO_REG(0x50) /* write: benchmark mark (the sim logs counters at it) */
#define MMIO_SHOT    MMIO_REG(0x54) /* sim only. read: screenshot requests pending; write: (w << 16) | h,
                                       the sim saves the RGB888 picture at SHOT_BASE */
#define SHOT_BASE    0x11800000u    /* SDRAM, above the firmware region */
#define MMIO_SIMREQ  MMIO_REG(0x58) /* sim only. read: bit 0 = the sim wants the firmware to report and exit */
#define MMIO_AUDIO   MMIO_REG(0x5c) /* read: free places in the audio FIFO (8-bit unsigned samples, 16384 Hz);
                                       write: one sample */
#define MMIO_SCAN    MMIO_REG(0x60) /* write: the address of the frame description (kg_scanout.cpp), taken
                                       by the scanout at the start of its next frame */
#define MMIO_KBD     MMIO_REG(0x64) /* read: { bit 8 valid, a PS/2 set 2 byte } of the keyboard (pops) */
#define MMIO_MOUSE   MMIO_REG(0x68) /* read: { 31 new, 28..26 buttons, 25..18 dz (+ up), 17..9 dy (+ down), 8..0 dx }
                                       summed since the last read (signed, saturated; the read clears) */
/* On the board the eZ80 UART RX FIFO level drives CTS to the eZ80 (MOS waits on it); the ISS is a
   lossless pipe without flow control. */
