# karabas: the CEmu CPU oracle (main.c) for the per-opcode tests. CEmu (GPL-3) is fetched at a
# fixed commit into build/; cpu.c, registers.c and their headers are copied next to our stubs
# (quoted includes look in the file's directory first, so the stubs must sit with them).
#   make   -> build/cemu-oracle
REV  := dd38ccec41cf201dcd360b2928f6db301cfbe9da
SRC  := build/CEmu
OBJ  := build/obj

all: build/cemu-oracle

$(SRC)/.ready: Makefile
	rm -rf ./build/CEmu
	mkdir -p $(SRC)
	git -C $(SRC) init -q
	git -C $(SRC) remote add origin https://github.com/CE-Programming/CEmu.git
	git -C $(SRC) fetch -q --depth 1 origin $(REV)
	git -C $(SRC) checkout -q FETCH_HEAD
	touch $@

$(OBJ)/.ready: $(SRC)/.ready $(wildcard stub/*.h stub/debug/*.h) Makefile
	rm -rf ./build/obj
	mkdir -p $(OBJ)/debug
	cp $(SRC)/core/cpu.c $(SRC)/core/cpu.h $(SRC)/core/registers.c $(SRC)/core/registers.h $(SRC)/core/defines.h $(OBJ)/
	cp stub/*.h $(OBJ)/
	cp stub/debug/debug.h $(OBJ)/debug/
	# one instruction per call also for EI (CEmu runs the next one in the same call)
	sed -i 's/cpu.eiDelay = cpu.cycles + 1;/cpu.eiDelay = cpu.cycles; \/* karabas: stop after EI *\//' $(OBJ)/cpu.c
	grep -q 'karabas: stop after EI' $(OBJ)/cpu.c
	# mixed RST / interrupt / trap pushes as the Agon (its crate, and what RET.L pops): from ADL with
	# the PC on SPL: U, H, L, then the mode byte; interrupts from Z80 mode with MADL: PC on SPL
	python3 cpu_patch.py $(OBJ)/cpu.c
	touch $@

build/cemu-oracle: $(OBJ)/.ready main.c
	gcc -O2 -std=gnu11 -w -I$(OBJ) -o $@ main.c $(OBJ)/cpu.c $(OBJ)/registers.c

clean:
	rm -rf build
.PHONY: all clean
