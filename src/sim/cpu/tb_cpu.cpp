// Ф1.1 replay testbench of the CPU against the oracle trace (src/oracle, --z80 mode for now).
// Memory: the oracle's 64 KB image (--mem-out). Port reads: the values of the oracle's r: events of
// the same instruction, in order (the port must match). At each InsnStart (the start of
// instruction k) the registers = the state after instruction k-1: compared with its trace line,
// and the memory / port writes seen since the previous InsnStart with its w: / o: events.
//   Vtb_t80 --mem mem.bin --trace trace.txt [--max N] [--fmask 0xff (F bits compared)] [--quiet]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <sstream>
#include "Vtb_t80.h"
#include "verilated.h"

struct Ev { char k; uint32_t a; uint8_t v; };
struct Line {
    uint64_t n; uint32_t pc, af, bc, de, hl, ix, iy, sps, i, iff1, iff2;
    std::vector<Ev> ev;
};

static bool parse(const std::string &s, Line &l) {
    std::istringstream is(s);
    std::string cyc, adl, madl, mb, spl;
    if (!(is >> l.n >> cyc >> std::hex >> l.pc >> adl >> madl >> mb >> l.af >> l.bc >> l.de >> l.hl >> l.ix >> l.iy >> l.sps >> spl >> l.i >> l.iff1 >> l.iff2))
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

static uint32_t field(const VlWide<7> &r, int lo, int bits) {
    uint32_t v = 0;
    for (int b = 0; b < bits; b++) v |= ((r[(lo + b) >> 5] >> ((lo + b) & 31)) & 1u) << b;
    return v;
}

int main(int argc, char **argv) {
    const char *memf = 0, *trf = 0;
    uint64_t max = ~0ull;
    uint32_t fmask = 0xff;
    bool quiet = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mem")) memf = argv[++i];
        else if (!strcmp(argv[i], "--trace")) trf = argv[++i];
        else if (!strcmp(argv[i], "--max")) max = strtoull(argv[++i], 0, 10);
        else if (!strcmp(argv[i], "--fmask")) fmask = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
    }
    if (!memf || !trf) { fprintf(stderr, "usage: %s --mem mem.bin --trace trace.txt [--max N] [--fmask M]\n", argv[0]); return 2; }
    std::vector<uint8_t> mem(65536);
    FILE *f = fopen(memf, "rb");
    if (!f || fread(mem.data(), 1, 65536, f) != 65536) { perror(memf); return 2; }
    fclose(f);
    std::vector<Line> tr;
    {
        FILE *t = fopen(trf, "r");
        if (!t) { perror(trf); return 2; }
        char buf[65536];
        while (fgets(buf, sizeof buf, t)) {
            Line l;
            if (parse(buf, l)) tr.push_back(std::move(l));
            if (tr.size() >= max + 1) break;
        }
        fclose(t);
    }
    Verilated::commandArgs(argc, argv);
    Vtb_t80 *top = new Vtb_t80;
    top->int_n = 1; top->nmi_n = 1; top->reset_n = 0; top->clk = 0;
    for (int i = 0; i < 8; i++) { top->clk = !top->clk; top->eval(); }
    top->reset_n = 1;

    uint64_t k = 0;              // InsnStarts seen = the instruction now starting
    std::vector<Ev> seen;        // writes since the last InsnStart
    size_t rd_idx = 0;           // next r: event of the instruction in progress
    bool prev_wr = true, prev_insn = false, prev_rd = true;
    uint64_t cycles = 0, checked = 0;
    auto fail = [&](const char *what, const Line &l) {
        printf("FAIL at instruction %llu (pc %04x): %s\n", (unsigned long long)l.n, l.pc, what);
        printf("  bytes at pc: %02x %02x %02x %02x\n", mem[l.pc & 0xffff], mem[(l.pc + 1) & 0xffff], mem[(l.pc + 2) & 0xffff], mem[(l.pc + 3) & 0xffff]);
        exit(1);
    };
    while (k <= tr.size() && cycles < 400000000ull) {
        top->clk = 1; top->eval();
        bool rd = top->rd_n == 0, wr = top->wr_n == 0;
        uint32_t a = top->a;
        // drive DI for this cycle
        if (rd && !top->mreq_n) top->di = mem[a];
        else if (rd && !top->iorq_n) {
            const Line *cur = (k >= 1 && k <= tr.size()) ? &tr[k - 1] : nullptr;
            uint8_t v = 0xff;
            if (rd && !prev_rd && cur) {
                size_t j = rd_idx;
                while (j < cur->ev.size() && cur->ev[j].k != 'r') j++;
                if (j >= cur->ev.size()) fail("port read not in the oracle", *cur);
                if ((cur->ev[j].a & 0xffff) != a) fail("port read address differs", *cur);
                v = cur->ev[j].v;
                rd_idx = j + 1;
                top->di = v;
            }
        }
        if (wr && !prev_wr) seen.push_back(Ev{top->mreq_n ? 'o' : 'w', a, (uint8_t)top->dout});
        if (wr && !top->mreq_n) mem[a] = top->dout;
        prev_wr = wr; prev_rd = rd;
        top->eval();
        bool insn = top->insn;
        if (insn && !prev_insn) {
            if (k >= 1) {
                const Line &l = tr[k - 1];
                const VlWide<7> &r = top->regs;
                uint32_t A = field(r, 0, 8), F = field(r, 8, 8), SP = field(r, 48, 16), PC = field(r, 64, 16);
                uint32_t BC = field(r, 80, 16), DE = field(r, 96, 16), HL = field(r, 112, 16), IX = field(r, 128, 16), IY = field(r, 192, 16);
                uint32_t I = field(r, 32, 8), IFF1 = field(r, 210, 1), IFF2 = field(r, 211, 1);
                char msg[512];
                uint32_t eaf = l.af & (0xff00 | fmask), gaf = ((A << 8) | F) & (0xff00 | fmask);
                if (eaf != gaf || BC != (l.bc & 0xffff) || DE != (l.de & 0xffff) || HL != (l.hl & 0xffff) ||
                    IX != (l.ix & 0xffff) || IY != (l.iy & 0xffff) || SP != (l.sps & 0xffff) || I != l.i ||
                    IFF1 != l.iff1 || IFF2 != l.iff2) {
                    snprintf(msg, sizeof msg, "registers\n  rtl    AF %04x BC %04x DE %04x HL %04x IX %04x IY %04x SP %04x I %02x IFF %u%u\n  oracle AF %04x BC %04x DE %04x HL %04x IX %04x IY %04x SP %04x I %02x IFF %u%u",
                             (A << 8) | F, BC, DE, HL, IX, IY, SP, I, IFF1, IFF2, l.af, l.bc & 0xffff, l.de & 0xffff, l.hl & 0xffff, l.ix & 0xffff, l.iy & 0xffff, l.sps & 0xffff, l.i, l.iff1, l.iff2);
                    fail(msg, l);
                }
                if (k < tr.size() && PC != (tr[k].pc & 0xffff)) {
                    snprintf(msg, sizeof msg, "next PC rtl %04x oracle %04x", PC, tr[k].pc);
                    fail(msg, l);
                }
                std::vector<Ev> want;
                for (auto &e : l.ev) if (e.k == 'w' || e.k == 'o') want.push_back(e);
                bool same = want.size() == seen.size();
                for (size_t j = 0; same && j < want.size(); j++)
                    same = want[j].k == seen[j].k && (want[j].a & 0xffff) == (seen[j].a & 0xffff) && want[j].v == seen[j].v;
                if (!same) {
                    std::string s = "writes\n  rtl   ";
                    for (auto &e : seen) { char b[32]; snprintf(b, sizeof b, " %c:%04x=%02x", e.k, e.a, e.v); s += b; }
                    s += "\n  oracle";
                    for (auto &e : want) { char b[32]; snprintf(b, sizeof b, " %c:%04x=%02x", e.k, e.a & 0xffff, e.v); s += b; }
                    fail(s.c_str(), l);
                }
                checked++;
                if (!quiet && checked % 100000 == 0) { printf("%llu instructions ok\n", (unsigned long long)checked); fflush(stdout); }
            }
            seen.clear();
            rd_idx = 0;
            k++;
            if (k > tr.size() || k > max) break;
        }
        prev_insn = insn;
        top->clk = 0; top->eval();
        cycles++;
    }
    printf("PASS %llu instructions, %llu clocks (%.2f per instruction)\n", (unsigned long long)checked,
           (unsigned long long)cycles, checked ? (double)cycles / checked : 0.0);
    return 0;
}
