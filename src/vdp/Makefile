# VDP firmware for the soft CPU (Ф0.3): agon-vdp (Console8) + vdp-gl from userspace-vdp-gl,
# built for bare rv32 with the xPack toolchain. Our replacements of <mutex>, <thread>, <dirent.h>
# are in compat/ (searched before libstdc++ / newlib), tasks on coop.c.
#   make [ARCH=rv32im] [OPT=-O2]      -> build-<arch><opt>/vdp.elf, .bin, .map + size
XPACK   ?= $(HOME)/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin
CROSS   := $(XPACK)/riscv-none-elf-
ARCH    ?= rv32im
OPT     ?= -O2
ORG     ?= 0x10000000
LEN     ?= 0x1000000

UP      := ../../upstream
GL      := $(UP)/userspace-vdp-gl/src
EMU     := $(UP)/fab-agon-emulator/src/vdp
VDP     := $(UP)/agon-vdp
B       := build-$(ARCH)$(subst -,,$(OPT))$(if $(filter 1,$(DEBUG)),-dbg)

# the vdp-gl sources of the userspace-vdp-gl Makefile
GL_SRCS := $(shell sed -n '/^SRCS/,/^$$/p' $(GL)/Makefile | grep -o '[A-Za-z0-9_/-]*\.cpp')
# HardwareSerial.cpp: ours is kg_serial.cpp (Serial2 on MMIO)
GL_SRCS := $(filter-out userspace-platform/HardwareSerial.cpp,$(GL_SRCS))
GL_OBJS := $(addprefix $(B)/gl/,$(GL_SRCS:.cpp=.o))

ABI      := -march=$(ARCH) -mabi=ilp32
INC      := -I. -Icompat -I$(GL) -I$(GL)/dispdrivers -I$(GL)/comdrivers -I$(GL)/userspace-platform \
            -I$(GL)/userspace-platform/matrix -I$(EMU) -I$(VDP)/video -I$(VDP)
DEBUG    ?= 0
DEFS     := -DUSERSPACE -DWIFI_TASK_CORE_ID=0 -DKG_VDP_DEBUG=$(DEBUG)
CXXFLAGS := $(ABI) $(OPT) -g -std=gnu++17 -ffunction-sections -fdata-sections $(DEFS) $(INC) -w
CFLAGS   := $(ABI) $(OPT) -g -ffunction-sections -fdata-sections -I.
LDFLAGS  := $(ABI) -nostartfiles -Wl,--gc-sections

all: $(B)/vdp.bin

$(B)/gl/%.o: $(GL)/%.cpp
	@mkdir -p $(dir $@)
	$(CROSS)g++ $(CXXFLAGS) -c $< -o $@
# karabas: our patches to vdp-gl, one per file (patches/<path, / as _>.patch): the patched copy in
# $(B)/pgl/ is built instead of the upstream file
GL_PATCHED := dispdrivers/vga2controller.cpp dispdrivers/vga4controller.cpp dispdrivers/vga8controller.cpp \
              dispdrivers/vga16controller.cpp dispdrivers/vga64controller.cpp
define patched
$(B)/pgl/$(1): $(GL)/$(1) patches/$(subst /,_,$(1)).patch
	@mkdir -p $$(dir $$@)
	patch -s -o $$@ $$< patches/$(subst /,_,$(1)).patch
$(B)/gl/$(1:.cpp=.o): $(B)/pgl/$(1)
	@mkdir -p $$(dir $$@)
	$$(CROSS)g++ $$(CXXFLAGS) -c $$< -o $$@
endef
$(foreach f,$(GL_PATCHED),$(eval $(call patched,$(f))))

$(B)/%.o: %.cpp mmio.h coop.h compat/mutex compat/thread Makefile
	@mkdir -p $(B)
	$(CROSS)g++ $(CXXFLAGS) -c $< -o $@
$(B)/%.o: %.c mmio.h coop.h
	@mkdir -p $(B)
	$(CROSS)gcc $(CFLAGS) -c $< -o $@
$(B)/%.o: %.S
	@mkdir -p $(B)
	$(CROSS)gcc $(ABI) -c $< -o $@
$(B)/link.ld: link.ld.in Makefile
	@mkdir -p $(B)
	sed -e 's/@ORG@/$(ORG)/' -e 's/@LEN@/$(LEN)/' $< > $@

OBJS := $(B)/crt0.o $(B)/coop_switch.o $(B)/coop.o $(B)/syscalls.o $(B)/kg_vdp.o $(B)/kg_serial.o $(GL_OBJS)
$(B)/vdp.elf: $(OBJS) $(B)/link.ld
	$(CROSS)g++ $(LDFLAGS) -T $(B)/link.ld -Wl,-Map,$(B)/vdp.map -o $@ $(OBJS) -lstdc++ -lm
	$(CROSS)size $@
$(B)/vdp.bin: $(B)/vdp.elf
	$(CROSS)objcopy -O binary $< $@

clean:
	rm -rf build-*
.PHONY: all clean
