# eZ80 oracle (Ф0.2): agon-ez80-emulator of fab-agon-emulator (GPL-3) + our kg_trace.rs, run
# deterministically (src/main.rs). The crate is copied to build/ (the submodule stays clean), its
# workspace-inherited keys made literal, and kg_trace.rs added as a child module of agon_machine.
#   make            -> target/release/agon-oracle
#   make sd         -> build/sd.img (16 MB FAT16, a few test files)
EMU  := ../../upstream/fab-agon-emulator
CR   := build/agon-ez80-emulator
CARGO ?= $(HOME)/.cargo/bin/cargo

EZ   := build/ez80
EZREV := 13c151e89f520b3bae3343bea9d67d06e8037cfa

all: $(CR)/.ready $(EZ)/.ready
	$(CARGO) build -q --release

# karabas: the ez80 crate (tomm/ez80, MIT) with our fixes where it differs from CEmu / UM0077,
# used through [patch] in Cargo.toml by both the emulator crate and the oracle
$(EZ)/.ready: Makefile
	rm -rf ./build/ez80
	git clone -q https://github.com/tomm/ez80.git $(EZ)
	git -C $(EZ) checkout -q $(EZREV)
	# IN0 r,(n): flags as IN r,(C) (S, Z, P parity, H = N = 0, C kept), not as a subtraction
	# (flag bits 3 and 5: kept for all instructions by kg_trace.rs)
	sed -i 's/env.state.reg.update_arithmetic_flags(data as u16, data as u16, data as u16, true, false); /env.state.reg.update_bits_in_flags(data); \/\/ karabas: IN0 flags (CEmu, UM0077)/' $(EZ)/src/opcode_io.rs
	grep -q 'karabas: IN0 flags' $(EZ)/src/opcode_io.rs
	# 24-bit ADD / ADC / SBC: H from bit 12 as the 16-bit ones (CEmu cpuflag_halfcarry_w_*), not bit 20
	sed -i -e '/env.state.reg.update_add24_flags(aaa, bbb, vvvv);/a\    env.state.reg.put_flag(Flag::H, ((aaa ^ bbb ^ vvvv) >> 12) \& 1 != 0); // karabas: H from bit 12 (CEmu)' \
	       -e '/env.state.reg.update_arithmetic_flags_24(aaa, bbb, vvvv, \(true\|false\));/a\    env.state.reg.put_flag(Flag::H, ((aaa ^ bbb ^ vvvv) >> 12) \& 1 != 0); // karabas: H from bit 12 (CEmu)' $(EZ)/src/operators.rs
	test $$(grep -c 'karabas: H from bit 12' $(EZ)/src/operators.rs) = 3
	# INI / IND / INIR / INDR: the port address is BC before B is decremented (TUZD, CEmu), the
	# crate had it after
	python3 -I -c "import sys; p=sys.argv[1]; s=open(p).read(); a='            let b = env.state.reg.inc_dec8(Reg8::B, false /* decrement */);\n            let address = env.state.reg.get16(Reg16::BC);\n\n            let value = env.port_in(address);'; assert s.count(a)==1; s=s.replace(a, '            let address = env.state.reg.get16(Reg16::BC); // karabas: INI BC before the decrement\n            let b = env.state.reg.inc_dec8(Reg8::B, false /* decrement */);\n\n            let value = env.port_in(address);'); open(p,'w').write(s)" $(EZ)/src/opcode_io.rs
	touch $@

$(CR)/.ready: $(EMU)/agon-ez80-emulator/Cargo.toml $(wildcard $(EMU)/agon-ez80-emulator/src/*.rs) kg_trace.rs Makefile
	mkdir -p build
	rm -rf ./build/agon-ez80-emulator
	cp -r $(EMU)/agon-ez80-emulator $(CR)
	sed -i -e 's/^version.workspace = true/version = "1.2.6"/' -e 's/^authors.workspace = true/authors = ["Tom Morton"]/' \
	       -e 's/^edition.workspace = true/edition = "2021"/' -e 's/^license.workspace = true/license = "GPL-3.0"/' $(CR)/Cargo.toml
	printf '\n// karabas: deterministic stepping for the oracle\n#[path = "../../../kg_trace.rs"]\npub mod kg_trace;\n' >> $(CR)/src/agon_machine.rs
	printf '\n// karabas: the bus events of the oracle\npub use agon_machine::kg_trace::{kg_ld_a_r_fix, kg_r_fix, KgEv};\n' >> $(CR)/src/lib.rs
	touch $@

sd: build/sd.img
build/sd.img:
	mkdir -p build
	mkfs.fat -F 16 -n AGONSD -C $@ 16384 >/dev/null
	printf 'Hello from the Karabas Agon oracle\r\n' > build/hello.txt
	mcopy -i $@ build/hello.txt ::HELLO.TXT
	mmd -i $@ ::BIN

clean:
	rm -rf build target
.PHONY: all sd clean
