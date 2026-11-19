# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An Agon Light / Console8 core for the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST): eZ80F92 + 512 KB RAM + SD card running the stock MOS, and a VDP compatible with the Console8 firmware. No Agon or VDP on an FPGA existed when this started (2026-11-18). Docs, in Russian: `docs/PLAN.md` (research, decisions, phases). Follow the phases; record a changed decision in PLAN.md.

User decisions (2026-11-18): build an Agon; private repo for now. The eZ80 CPU is our own extension of the BSD T80 (user, 2026-11-18), 24-bit throughout, Z80 timing, at the highest clock PAR gives (~50-60 MHz): MSXnano-eZ80 (no licence) and the emulators are references only, never copy their code. VDP route 1 chosen by the user after Ф0 (2026-11-18): the real firmware on VexRiscv + our speed patches, scanout / audio FIFO / glue in RTL.

## Layout

- `modules/`: submodule `karabas-go-modules` (kg_* board modules).
- `upstream/`: submodules agon-vdp (at fab-agon-emulator's commit), userspace-vdp-gl, agon-mos, fab-agon-emulator (references; its `agon-ez80-emulator` is the eZ80 oracle).
- `src/vdp/`: the real VDP firmware for the soft CPU (VexRiscv rv32im): `make` -> `build-rv32imO2/vdp.bin`. `compat/` = our `<mutex>`, `<thread>`, `<dirent.h>` over the cooperative scheduler `coop.c`; `kg_serial.cpp` = Serial2 on MMIO; `kg_vdp.cpp` = main, vblank / audio / sim tasks; `mmio.h` = the MMIO map. `patches/` = our vdp-gl speed patches (one per file, applied to copies at build); `make GL_PATCHED= B=build-nopatch` builds the unpatched reference: screenshots must stay byte-identical.
- `src/sim/`: `iss.cpp` (rv32im ISS: eZ80 UART stream in, VDP replies, screenshots, audio FIFO, cache counters), `mkstream.py` (VDU workload streams), `run_f0.sh` (whole suite in seconds), `model.py` (cycles from the cache misses).

## Rules of the core

The rules of the other karabas-go cores apply: standard video timing with syncs always present, `FT_CLK_OUT` about 8 MHz on Mini / Mini G, Go `FDC_*` outputs 0 when unused, Mini / Mini G drive T3 (`FLASH_CS_N`) = 0, OSD switch index = item position unless `"index"`, an OSD value shows 10 characters at most, FL slots 0..7 only, Verilog-2001 for XST (`sv2v` for SV), imported code marked `karabas:`.

- Licences: MOS / agon-vdp MIT, vdp-gl / FabGL / userspace-vdp-gl / fab-agon-emulator GPL-3, BBC BASIC zlib-like; keep their notices.
- **Ask the user before every check on the board** (and the HDMI capture). Ask before a firmware flash.
- One branch per phase of `docs/PLAN.md`, one PR at its end.
- Heavy builds: Mini G only while working on one feature, all boards for a release; map with cost table 2 first.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
