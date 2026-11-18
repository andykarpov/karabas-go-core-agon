# eZ80 oracle (Ф0.2): agon-ez80-emulator of fab-agon-emulator (GPL-3) + our kg_trace.rs, run
# deterministically (src/main.rs). The crate is copied to build/ (the submodule stays clean), its
# workspace-inherited keys made literal, and kg_trace.rs added as a child module of agon_machine.
#   make            -> target/release/agon-oracle
#   make sd         -> build/sd.img (16 MB FAT16, a few test files)
EMU  := ../../upstream/fab-agon-emulator
CR   := build/agon-ez80-emulator
CARGO ?= $(HOME)/.cargo/bin/cargo

all: $(CR)/.ready
	$(CARGO) build -q --release

$(CR)/.ready: $(EMU)/agon-ez80-emulator/Cargo.toml $(wildcard $(EMU)/agon-ez80-emulator/src/*.rs) kg_trace.rs Makefile
	mkdir -p build
	rm -rf ./build/agon-ez80-emulator
	cp -r $(EMU)/agon-ez80-emulator $(CR)
	sed -i -e 's/^version.workspace = true/version = "1.2.6"/' -e 's/^authors.workspace = true/authors = ["Tom Morton"]/' \
	       -e 's/^edition.workspace = true/edition = "2021"/' -e 's/^license.workspace = true/license = "GPL-3.0"/' $(CR)/Cargo.toml
	printf '\n// karabas: deterministic stepping for the oracle\n#[path = "../../../kg_trace.rs"]\nmod kg_trace;\n' >> $(CR)/src/agon_machine.rs
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
