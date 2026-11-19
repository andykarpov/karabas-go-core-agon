# Agon Light core for Karabas Go / Mini / Mini G

[Русская версия](README.ru.md)

An [Agon Light](https://www.thebyteattic.com/p/agon.html) / Console8 machine for the Karabas Go board family (Xilinx Spartan-6 XC6SLX25): the eZ80F92 with MOS 3.0.2, and the VDP with the real Console8 VDP firmware 2.16.0 (vdp-gl) running on a VexRiscv RISC-V soft CPU. The two talk through the same byte link as the eZ80 UART0 and the ESP32 of the real machine.

| Board | Core file | Video | Sound |
|---|---|---|---|
| Karabas Go | `agon.kg` | VGA | I2S DAC (PCM5102) |
| Karabas Mini | `agon.kg` | HDMI | HDMI, analog output (sigma-delta) |
| Karabas Mini G | `agon.kg` | HDMI | HDMI, I2S DAC (PCM5102) |

The core file is in `src/`. MOS and the VDP firmware are inside it.

Status: checked on Mini G: MOS and the VDP boot, the keyboard, the mouse, `*cat` of the SD card, sound (HDMI, DAC, the level meter of the matrix). The Go and Mini builds have not been run on a board yet.

## The machine

- **eZ80:** our own eZ80 core (the T80 extended to 24-bit ADL mode, MBASE, the instruction suffixes), checked instruction by instruction against an emulator on the MOS boot and BBC BASIC. Its timing is that of a Z80 (not the one-clock-per-byte eZ80 pipeline), at 34.09 MHz.
- **F92 periphery:** UART0 (the VDP link with CTS), UART1, SPI (the SD card), the timers PRT0 / PRT2 (PRT1 / 3 / 4 / 5 are registers only), GPIO with interrupts (vblank on PB1), the on-chip 8 KB RAM, 512 KB external RAM, the 128 KB flash (MOS) in the board SRAM.
- **VDP:** the Console8 VDP firmware 2.16.0 on a VexRiscv (16 KB caches, 75 MHz, SDRAM); vdp-gl draws into its frame buffers, a scanout in the FPGA shows them with the hardware sprites, the text cursor and the mouse cursor on one 640 x 480 at 60 Hz output (smaller modes doubled or centred).
- **Sound:** the VDP sound generator (8 bit, 16384 Hz).
- **Keyboard and mouse:** USB through the board MCU, as PS/2 to the VDP.

## Getting started

1. Copy `agon.kg` (one file for Go, Mini and Mini G) to the root of the SD card of the board (SD1).
2. Put the files of an Agon SD card (FAT32: `/bin`, `bbcbasic.bin`, `autoexec.txt`, ...) on the second SD card (SD2, the slot of the FPGA): MOS uses it.
3. Choose Agon in the boot menu.

## Keys

- **F12:** reset (MOS and the VDP restart).
- **Ctrl+Alt+D:** a debug overlay (the eZ80 PC, the link counters and its last bytes).
- The mouse is off until a program turns it on (`VDU 23,0,&89,0`; at the MOS prompt `*vdu 23 0 137 0`).

## Licence

GPL-3.0 (see [LICENSE](LICENSE)). Agon MOS and the Agon VDP firmware are MIT (Dean Belfield and contributors), vdp-gl (FabGL) is GPL-3, BBC BASIC for Agon has its own zlib-like licence. The plan of the work (in Russian) is in [docs/PLAN.md](docs/PLAN.md).
