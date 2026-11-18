// Ф1 replay testbench of the CPU against the oracle trace (src/oracle).
//   EZ80=0 (build): bare Z80 (oracle --z80): 64 KB memory image (--mem, the oracle's --mem-out).
//   EZ80=1 (build-ez80): the eZ80 core: 16 MB flat memory, --flash file (MOS) at 0, the rest 0
//     (as the oracle with RamInit::Zero); addresses AU:A.
// Port reads: the values of the oracle's r: events of the same instruction, in order (the port
// must match). At each InsnStart (the start of instruction k) the registers = the state after
// instruction k-1: compared with its trace line, and the memory / port writes seen since the
// previous InsnStart with its w: / o: events.
//   Vtb_t80 (--mem mem.bin | --flash mos.bin) --trace trace.txt [--max N] [--fmask 0xff] [--quiet]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <sstream>
#include <algorithm>
#include <deque>
#include "Vtb_t80.h"
#include "verilated.h"

#ifndef EZ80
#define EZ80 0
#endif

struct Ev { char k; uint32_t a; uint8_t v; };

// The eZ80F92 memory map of the Agon (as agon_machine.rs): flash 128 KB at FLASH_ADDR_U (port F7)
// << 16, on-chip SRAM 8 KB at {RAM_ADDR_U (B5)}:E000 if RAM_CTL (B4) bit 7, external 512 KB in the
// CS0 window (A8 / A9, mirrored), reads elsewhere F5. The registers follow the core's port writes.
struct Map {
    std::vector<uint8_t> rom = std::vector<uint8_t>(0x20000), ram = std::vector<uint8_t>(8192), ext = std::vector<uint8_t>(0x80000);
    uint8_t flash_u = 0, seg = 0xff, lbr = 0, ubr = 0xff;
    bool onchip = true;
    uint8_t *at(uint32_t a, bool wr) {
        a &= 0xffffff;
        uint32_t o = a - (((uint32_t)seg << 16) + 0xe000);
        if (onchip && o < 8192) return &ram[o];
        if (((a - ((uint32_t)flash_u << 16)) & 0xffffff) < 0x20000) return wr ? nullptr : &rom[(a - ((uint32_t)flash_u << 16)) & 0xffffff];
        if ((a >> 16) >= lbr && (a >> 16) <= ubr) return &ext[a & 0x7ffff];
        return nullptr;
    }
    uint8_t rd(uint32_t a) { uint8_t *p = at(a, false); return p ? *p : 0xf5; }
    void wr(uint32_t a, uint8_t v) { uint8_t *p = at(a, true); if (p) *p = v; }
    void out(uint16_t port, uint8_t v) {
        switch (port & 0xff) {
        case 0xf7: flash_u = v; break;
        case 0xb4: onchip = v & 0x80; break;
        case 0xb5: seg = v; break;
        case 0xa8: lbr = v; break;
        case 0xa9: ubr = v; break;
        }
    }
};
struct Line {
    uint64_t n; uint32_t pc, adl, madl, mb, af, bc, de, hl, ix, iy, sps, spl, i, iff1, iff2;
    std::vector<Ev> ev;
};

static bool parse(const std::string &s, Line &l) {
    std::istringstream is(s);
    std::string cyc;
    if (!(is >> l.n >> cyc >> std::hex >> l.pc >> l.adl >> l.madl >> l.mb >> l.af >> l.bc >> l.de >> l.hl >> l.ix >> l.iy >> l.sps >> l.spl >> l.i >> l.iff1 >> l.iff2))
        return false;
    std::string t;
    while (is >> t) {
        Ev e{};
        if (t.size() > 2 && t[1] == ':' && (t[0] == 'w' || t[0] == 'r' || t[0] == 'o')) {
            e.k = t[0];
            size_t eq = t.find('=');
            e.a = strtoul(t.substr(2, eq - 2).c_str(), 0, 16);
            e.v = (uint8_t)strtoul(t.substr(eq + 1).c_str(), 0, 16);
            l.ev.push_back(e);
        } else if (t.rfind("int:", 0) == 0) {
            e.k = 'i'; e.a = strtoul(t.c_str() + 4, 0, 16); l.ev.push_back(e);
        }
    }
    return true;
}

template <class W> static uint32_t field(const W &r, int lo, int bits) {
    uint32_t v = 0;
    for (int b = 0; b < bits; b++) v |= ((r[(lo + b) >> 5] >> ((lo + b) & 31)) & 1u) << b;
    return v;
}

int main(int argc, char **argv) {
    const char *memf = 0, *flashf = 0, *trf = 0;
    uint64_t max = ~0ull;
    uint32_t fmask = EZ80 ? 0xd7 : 0xff;  // eZ80: flag bits 3 and 5 are undocumented (CEmu: "undef")
    bool quiet = false, io_lo = false;   // --io-lo: port writes compared by the low address byte
    long fill = -1;                      // --fill-ext N: RAM (external + on-chip) filled as cemu-oracle --fill N
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mem")) memf = argv[++i];
        else if (!strcmp(argv[i], "--flash")) flashf = argv[++i];
        else if (!strcmp(argv[i], "--trace")) trf = argv[++i];
        else if (!strcmp(argv[i], "--max")) max = strtoull(argv[++i], 0, 10);
        else if (!strcmp(argv[i], "--fmask")) fmask = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else if (!strcmp(argv[i], "--io-lo")) io_lo = true;
        else if (!strcmp(argv[i], "--fill-ext")) fill = strtol(argv[++i], 0, 0);
    }
    const uint32_t MEMSZ = EZ80 ? (1u << 24) : 65536, AMASK = MEMSZ - 1;
    if ((!memf && !flashf) || !trf) { fprintf(stderr, "usage: %s (--mem mem.bin | --flash mos.bin) --trace trace.txt [--max N] [--fmask M]\n", argv[0]); return 2; }
    std::vector<uint8_t> mem(EZ80 ? 0 : MEMSZ);
    Map map;
    if (fill >= 0) {
        for (uint32_t i = 0; i < map.ext.size(); i++) map.ext[i] = (uint8_t)(((uint32_t)i * 2654435761u + fill * 40503u) >> 13);
        for (uint32_t i = 0; i < map.ram.size(); i++) map.ram[i] = (uint8_t)(((uint32_t)(i + 0x80000) * 2654435761u + fill * 40503u) >> 13);
    }
    {
        FILE *f = fopen(memf ? memf : flashf, "rb");
        if (!f) { perror(memf ? memf : flashf); return 2; }
        size_t n = fread(EZ80 ? map.rom.data() : mem.data(), 1, EZ80 ? 0x20000 : MEMSZ, f);
        fclose(f);
        if (memf && !EZ80 && n != MEMSZ) { fprintf(stderr, "%s: %zu bytes, want %u\n", memf, n, MEMSZ); return 2; }
    }
    auto mrd = [&](uint32_t a) -> uint8_t { return EZ80 ? map.rd(a) : mem[a & AMASK]; };
    // the trace is read as it goes (it can come through a pipe: --trace /dev/stdin); Tr keeps the
    // lines from instruction base on, tr[i] = instruction i + 1
    FILE *tf = fopen(trf, "r");
    if (!tf) { perror(trf); return 2; }
    struct Tr {
        FILE *f; uint64_t max; std::deque<Line> v; uint64_t base = 0; bool eof = false;  // deque: references stay valid
        bool have(uint64_t i) {   // line i (0-based) available?
            while (!eof && i >= base + v.size()) {
                static char buf[1 << 16];
                if (base + v.size() > max || !fgets(buf, sizeof buf, f)) { eof = true; break; }
                Line l;
                if (parse(buf, l)) v.push_back(std::move(l));
            }
            return i < base + v.size();
        }
        Line &operator[](uint64_t i) { have(i); return v[i - base]; }
        void drop_before(uint64_t i) { if (i > base + 1024) { v.erase(v.begin(), v.begin() + (i - base)); base = i; } }
        uint64_t size_at_least(uint64_t i) { return have(i) ? i + 1 : base + v.size(); }
    } tr{tf, max};
    Verilated::commandArgs(argc, argv);
    Vtb_t80 *top = new Vtb_t80;
    top->int_n = 1; top->nmi_n = 1; top->reset_n = 0; top->clk = 0;
    for (int i = 0; i < 8; i++) { top->clk = !top->clk; top->eval(); }
    top->reset_n = 1;

    uint64_t k = 0;              // InsnStarts seen = the instruction now starting
    std::vector<Ev> seen;        // writes since the last InsnStart
    size_t rd_idx = 0;           // next r: event of the instruction in progress
    bool prev_wr = true, prev_insn = false, prev_rd = true;
    int int_vec = -1;            // the vector of the interrupt the oracle takes after the current instruction
    uint64_t cycles = 0, checked = 0;
    auto fail = [&](const char *what, const Line &l) {
        printf("FAIL at instruction %llu (pc %06x): %s\n", (unsigned long long)l.n, l.pc, what);
        printf("  bytes at pc: %02x %02x %02x %02x %02x\n", mrd(l.pc), mrd(l.pc + 1), mrd(l.pc + 2), mrd(l.pc + 3), mrd(l.pc + 4));
        exit(1);
    };
    while (cycles < 20000000000ull) {
        top->clk = 1; top->eval();
        bool rd = top->rd_n == 0, wr = top->wr_n == 0;
        uint32_t a = EZ80 ? (((uint32_t)top->au << 16) | top->a) : top->a;
        if (!top->m1_n && !top->iorq_n && int_vec >= 0) {
            // interrupt acknowledge: the vector on the bus, INT off
            top->di = (uint8_t)int_vec;
            top->int_n = 1;
            int_vec = -1;
        } else if (rd && !top->mreq_n) top->di = mrd(a);
        else if (rd && !top->iorq_n) {
            const Line *cur = (k >= 1 && tr.have(k - 1)) ? &tr[k - 1] : nullptr;
            if (!prev_rd && cur) {
                size_t j = rd_idx;
                while (j < cur->ev.size() && cur->ev[j].k != 'r') j++;
                if (j >= cur->ev.size()) fail("port read not in the oracle", *cur);
                if ((cur->ev[j].a & 0xffff) != (a & 0xffff)) {
                    char m[96]; snprintf(m, sizeof m, "port read address rtl %04x oracle %04x", a & 0xffff, cur->ev[j].a);
                    fail(m, *cur);
                }
                top->di = cur->ev[j].v;
                rd_idx = j + 1;
            }
        }
        if (wr && !prev_wr) seen.push_back(Ev{top->mreq_n ? 'o' : 'w', top->mreq_n ? (a & 0xffff) : (a & AMASK), (uint8_t)top->dout});
        if (wr && !top->mreq_n) { if (EZ80) map.wr(a, top->dout); else mem[a & AMASK] = top->dout; }
        if (EZ80 && wr && !prev_wr && top->mreq_n) map.out(a & 0xffff, top->dout);
        prev_wr = wr; prev_rd = rd;
        top->eval();
        bool insn = top->insn;
        if (insn && !prev_insn) {
            if (k >= 1) {
                const Line &l = tr[k - 1];
                const auto &r = top->regs;
                uint32_t A = field(r, 0, 8), F = field(r, 8, 8), SPS = field(r, 48, 16), PC = field(r, 64, 16);
                uint32_t BC = field(r, 80, 16), DE = field(r, 96, 16), HL = field(r, 112, 16), IX = field(r, 128, 16), IY = field(r, 192, 16);
                uint32_t I = field(r, 32, 8), IFF1 = field(r, 210, 1), IFF2 = field(r, 211, 1);
                uint32_t SPL = 0, MB = 0, ADL = 0, MADL = 0, PC24 = PC;
                uint32_t eBC = l.bc & 0xffff, eDE = l.de & 0xffff, eHL = l.hl & 0xffff, eIX = l.ix & 0xffff, eIY = l.iy & 0xffff;
#if EZ80
                const auto &x = top->regx;
                PC24 = field(x, 0, 24); SPL = field(x, 24, 24); MB = field(x, 48, 8); ADL = field(x, 56, 1); MADL = field(x, 57, 1);
                BC |= field(x, 64, 8) << 16; DE |= field(x, 72, 8) << 16; HL |= field(x, 80, 8) << 16;
                IX |= field(x, 88, 8) << 16; IY |= field(x, 120, 8) << 16;
                eBC = l.bc; eDE = l.de; eHL = l.hl; eIX = l.ix; eIY = l.iy;
#endif
                char msg[1024];
                uint32_t eaf = l.af & (0xff00 | fmask), gaf = ((A << 8) | F) & (0xff00 | fmask);
                if (eaf != gaf || BC != eBC || DE != eDE || HL != eHL || IX != eIX || IY != eIY || SPS != (l.sps & 0xffff) ||
                    I != l.i || IFF1 != l.iff1 || IFF2 != l.iff2 ||
                    (EZ80 && (SPL != l.spl || MB != l.mb || ADL != l.adl || MADL != l.madl))) {
                    snprintf(msg, sizeof msg,
                             "registers\n  rtl    AF %04x BC %06x DE %06x HL %06x IX %06x IY %06x SPS %04x SPL %06x MB %02x ADL %u MADL %u I %02x IFF %u%u"
                             "\n  oracle AF %04x BC %06x DE %06x HL %06x IX %06x IY %06x SPS %04x SPL %06x MB %02x ADL %u MADL %u I %02x IFF %u%u",
                             (A << 8) | F, BC, DE, HL, IX, IY, SPS, SPL, MB, ADL, MADL, I, IFF1, IFF2,
                             l.af, eBC, eDE, eHL, eIX, eIY, l.sps & 0xffff, l.spl, l.mb, l.adl, l.madl, l.i, l.iff1, l.iff2);
                    fail(msg, l);
                }
                if (tr.have(k) && PC24 != (tr[k].pc & AMASK)) {
                    snprintf(msg, sizeof msg, "next PC rtl %06x oracle %06x", PC24, tr[k].pc);
                    fail(msg, l);
                }
                std::vector<Ev> want;
                for (auto &e : l.ev) if (e.k == 'w' || e.k == 'o') want.push_back(Ev{e.k, e.k == 'w' ? (e.a & AMASK) : e.a, e.v});
                // memory writes of one instruction in any order (the eZ80 order is not visible to
                // software; the oracle writes words upwards, T80 the high byte first), ports in order
                auto key = [](const Ev &e) { return e.k == 'o' ? 0ull : (1ull << 32) | e.a; };
                std::stable_sort(want.begin(), want.end(), [&](const Ev &x, const Ev &y) { return key(x) < key(y); });
                std::stable_sort(seen.begin(), seen.end(), [&](const Ev &x, const Ev &y) { return key(x) < key(y); });
                bool same = want.size() == seen.size();
                for (size_t j = 0; same && j < want.size(); j++)
                    same = want[j].k == seen[j].k && want[j].v == seen[j].v &&
                           ((want[j].a & AMASK) == seen[j].a || (io_lo && want[j].k == 'o' && (want[j].a & 0xff) == (seen[j].a & 0xff)));
                if (!same) {
                    std::string s = "writes\n  rtl   ";
                    for (auto &e : seen) { char b[32]; snprintf(b, sizeof b, " %c:%06x=%02x", e.k, e.a, e.v); s += b; }
                    s += "\n  oracle";
                    for (auto &e : want) { char b[32]; snprintf(b, sizeof b, " %c:%06x=%02x", e.k, e.a & AMASK, e.v); s += b; }
                    fail(s.c_str(), l);
                }
                checked++;
                if (!quiet && checked % 1000000 == 0) { printf("%llu instructions ok\n", (unsigned long long)checked); fflush(stdout); }
            }
            seen.clear();
            rd_idx = 0;
            k++;
            if (k >= 2) tr.drop_before(k - 2);
            if (!tr.have(k - 1) || k > max) break;
            // the oracle takes an interrupt after instruction k: INT on now, during it
            for (auto &e : tr[k - 1].ev)
                if (e.k == 'i') { int_vec = (int)e.a; top->int_n = 0; }
        }
        prev_insn = insn;
        if (getenv("TB_DEBUG") && k >= (uint64_t)atoll(getenv("TB_DEBUG")) && k <= (uint64_t)atoll(getenv("TB_DEBUG")) + 1) {
            const auto &x = top->regx;
            printf("  k %llu M%u T%u a %06x rd%d wr%d mreq%d di %02x do %02x IYU %02x IXU %02x\n", (unsigned long long)k,
                   top->mcyc, top->tst, a, rd, wr, top->mreq_n ? 0 : 1, top->di, top->dout, field(x, 120, 8), field(x, 88, 8));
        }
        top->clk = 0; top->eval();
        cycles++;
    }
    printf("PASS %llu instructions, %llu clocks (%.2f per instruction)\n", (unsigned long long)checked,
           (unsigned long long)cycles, checked ? (double)cycles / checked : 0.0);
    return 0;
}
