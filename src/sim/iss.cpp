// Ф0 fast RV32IM instruction-set simulator for the VDP firmware (src/vdp), from core-doom iss.cpp.
// Memory: SRAM 4 MB at 0x00000000, SDRAM 32 MB at 0x10000000, MMIO at 0x80000000 (src/vdp/mmio.h).
// No timing: time = retired instructions / --ipu (instructions per microsecond, default 50 = 80 MHz
// at CPI 1.6). The eZ80 side: bytes of --in (a MOS -> VDP stream) arrive on MMIO_EZ_RX at the UART
// rate (--baud, default 1152000), the VDP replies (MMIO_EZ_TX) go to --tx as hex. Cache model as in
// core-doom (--icache / --dcache bytes, 32-byte lines, direct-mapped, write-through).
//
// usage: iss <fw.bin> [--org A] [--max Minstr] [--ipu N] [--in file] [--in-at us] [--baud N] [--tx file]
//            [--icache B] [--dcache B] [--prof file: pc + ra every 256 instr]
//            [--shot us prefix: ask the firmware for a screenshot at that time -> prefix<N>.ppm; repeatable]
//            [--shot-poll file.ppm: with --stop-poll, a screenshot at that answer, then the exit]
//            [--stop-poll TAG: at the VDP answer 80 01 TAG print "DONE" with the counters since --in-at,
//             then ask the firmware to report (stacks) and exit]
// audio FIFO (MMIO_AUDIO): 512 samples drained at 16384 Hz, underruns counted
// prints per MMIO_MARK write: "M,<mark>,<us>,<instr>,<im_sram>,<im_sdram>,<dm_sram>,<dm_sdram>,<st_sram>,<st_sdram>"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>

static const uint32_t SRAM_SIZE = 4u << 20, SDRAM_BASE = 0x10000000u, SDRAM_SIZE = 32u << 20;
static std::vector<uint8_t> sram(SRAM_SIZE + 8), sdram(SDRAM_SIZE + 8);

// region of an address: 0 SRAM, 1 SDRAM; anything else stops the run
static inline uint8_t *host(uint32_t a, int &reg) {
    if (a < SRAM_SIZE) { reg = 0; return &sram[a]; }
    if (a - SDRAM_BASE < SDRAM_SIZE) { reg = 1; return &sdram[a - SDRAM_BASE]; }
    reg = -1; return nullptr;
}

struct Cache {
    uint32_t lines = 0;
    std::vector<uint32_t> tag;
    void init(uint32_t bytes) { lines = bytes / 32; tag.assign(lines ? lines : 1, 0xffffffffu); }
    bool miss(uint32_t a) {
        if (!lines) return true;
        uint32_t l = a >> 5, i = l % lines;
        if (tag[i] != l) { tag[i] = l; return true; }
        return false;
    }
    bool hit(uint32_t a) const { return lines && tag[(a >> 5) % lines] == (a >> 5); }
};

static uint64_t misaligned = 0;
struct Cnt { uint64_t instr = 0, im[2] = {0, 0}, dm[2] = {0, 0}, st[2] = {0, 0}, st8[2] = {0, 0}; };

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s fw.bin [--org A] [--max Minstr] [--ipu N] [--in f] [--in-at us] [--baud N] [--tx f] [--icache B] [--dcache B] [--prof f]\n", argv[0]); return 2; }
    uint64_t max_instr = 2000ull * 1000 * 1000;
    uint32_t icb = 4096, dcb = 4096, org = SDRAM_BASE, ipu = 50, baud = 1152000;
    uint64_t in_at = 0;
    FILE *prof = 0, *txf = 0;
    std::vector<uint8_t> in;
    std::vector<uint64_t> shots;
    const char *shot_prefix = "shot";
    int nshot = 0;
    const char *shot_poll = nullptr;   // --shot-poll file.ppm: at the --stop-poll answer a screenshot, then exit
    bool sp_pend = false;
    int stop_tag = -1;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--max")) max_instr = strtoull(argv[++i], 0, 10) * 1000000ull;
        else if (!strcmp(argv[i], "--icache")) icb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dcache")) dcb = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--org")) org = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ipu")) ipu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--baud")) baud = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--in-at")) in_at = strtoull(argv[++i], 0, 10);
        else if (!strcmp(argv[i], "--tx")) txf = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "--prof")) prof = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "--stop-poll")) stop_tag = strtol(argv[++i], 0, 16);
        else if (!strcmp(argv[i], "--shot")) { shots.push_back(strtoull(argv[++i], 0, 10)); shot_prefix = argv[++i]; }
        else if (!strcmp(argv[i], "--shot-poll")) shot_poll = argv[++i];
        else if (!strcmp(argv[i], "--in")) {
            FILE *f = fopen(argv[++i], "rb");
            if (!f) { perror(argv[i]); return 2; }
            int c; while ((c = fgetc(f)) != EOF) in.push_back((uint8_t)c);
            fclose(f);
        }
    }
    int reg;
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    size_t n = fread(host(org, reg), 1, 16u << 20, f);
    fclose(f);
    fprintf(stderr, "loaded %zu bytes at %08x, input %zu bytes, I$ %u D$ %u, %u instr/us\n", n, org, in.size(), icb, dcb, ipu);
    size_t in_pos = 0;
    const double us_per_byte = 10e6 / baud;   // 8N1
    Cache ic, dc; ic.init(icb); dc.init(dcb);

    uint32_t x[32] = {0}, pc = org;
    uint64_t ninstr = 0;
    Cnt tot, last, at_in;
    bool have_at_in = false, want_exit = false;
    int tx_state = 0;
    // audio FIFO: written samples vs drained by time
    const uint32_t AUD_DEPTH = 512, AUD_RATE = 16384;
    uint64_t aud_wr = 0, aud_under = 0, aud_drained = 0;
    uint64_t aud_nonsilent = 0;
    auto aud_level = [&]() -> uint64_t {
        uint64_t due = (ninstr / ipu) * AUD_RATE / 1000000;
        if (due > aud_drained) {
            uint64_t k = due - aud_drained;
            if (aud_wr - aud_drained < k) { aud_under += k - (aud_wr - aud_drained); aud_wr = due; }
            aud_drained = due;
        }
        return aud_wr - aud_drained;
    };
    int exit_code = 0;
    bool done = false;
    std::string line;

    auto bad = [&](const char *what, uint32_t a) {
        fprintf(stderr, "%s %08x at pc %08x ra %08x after %llu\n", what, a, pc, x[1], (unsigned long long)ninstr);
        exit(3);
    };
    auto ld = [&](uint32_t a, int sz) -> uint32_t {
        if (a & 0x80000000u) {
            switch (a & 0xff) {
            case 0x0c: return (uint32_t)ninstr;
            case 0x10: return (uint32_t)(ninstr / ipu);
            case 0x14: return (uint32_t)((ninstr / ipu) >> 32);
            case 0x18: return (uint32_t)(ninstr / ipu / 16667);   // 60 Hz frames
            case 0x1c: return (uint32_t)(ninstr / ipu / 1000);
            case 0x58: return want_exit ? 1u : 0u;
            case 0x5c: { uint64_t l = aud_level(); return l < AUD_DEPTH ? (uint32_t)(AUD_DEPTH - l) : 0u; }
            case 0x54: {
                uint32_t k = 0;
                for (uint64_t t : shots) if (t <= ninstr / ipu) k++;
                return (k > (uint32_t)nshot || sp_pend) ? 1u : 0u;
            }
            case 0x40: case 0x48: {
                // byte k of the input is there from in_at + k * us_per_byte
                bool rx = in_pos < in.size() && (double)(ninstr / ipu) >= in_at + in_pos * us_per_byte;
                if ((a & 0xff) == 0x48) return (rx ? 1u : 0u) | 2u;
                return rx ? 0x100u | in[in_pos++] : 0u;
            }
            }
            return 0;
        }
        uint8_t *p = host(a, reg);
        if (!p) bad("load from", a);
        if (a & (sz - 1)) { if (!misaligned++) fprintf(stderr, "MISALIGNED load %d at %08x pc %08x ra %08x\n", sz, a, pc, x[1]); }
        if (dc.miss(a)) tot.dm[reg]++;
        uint32_t v = 0;
        memcpy(&v, p, sz);
        return v;
    };
    auto st = [&](uint32_t a, uint32_t v, int sz) {
        if (a & 0x80000000u) {
            uint32_t o = a & 0xff;
            if (o == 0x00) { char c = (char)v; if (c == '\n') { printf("%s\n", line.c_str()); line.clear(); } else line += c; }
            else if (o == 0x5c) { aud_level(); aud_wr++; if ((v & 0xff) != 0x80 && (v & 0xff) != 0x7f) aud_nonsilent++; }
            else if (o == 0x44) {
                uint8_t b = v & 0xff;
                if (txf) fprintf(txf, "%llu %02x\n", (unsigned long long)(ninstr / ipu), b);
                if (tx_state == 2 && b == stop_tag && !want_exit) {
                    tot.instr = ninstr;
                    Cnt &z = at_in;
                    printf("DONE us %llu instr %llu im %llu/%llu dm %llu/%llu st %llu/%llu (sram/sdram) audio_under %llu\n",
                           (unsigned long long)(ninstr / ipu - in_at), (unsigned long long)(tot.instr - z.instr),
                           (unsigned long long)(tot.im[0] - z.im[0]), (unsigned long long)(tot.im[1] - z.im[1]),
                           (unsigned long long)(tot.dm[0] - z.dm[0]), (unsigned long long)(tot.dm[1] - z.dm[1]),
                           (unsigned long long)(tot.st[0] - z.st[0]), (unsigned long long)(tot.st[1] - z.st[1]),
                           (unsigned long long)aud_under);
                    if (shot_poll) sp_pend = true; else want_exit = true;
                }
                tx_state = (b == 0x80) ? 1 : (tx_state == 1 && b == 0x01) ? 2 : 0;
            }
            else if (o == 0x54) {
                uint32_t w = v >> 16, h = v & 0xffff;
                char name[512];
                if (sp_pend) snprintf(name, sizeof name, "%s", shot_poll);
                else snprintf(name, sizeof name, "%s%d.ppm", shot_prefix, nshot++);
                if (w && h && w * h * 3 <= (8u << 20)) {
                    FILE *pf = fopen(name, "wb");
                    fprintf(pf, "P6\n%u %u\n255\n", w, h);
                    fwrite(&sdram[0x01800000], 1, (size_t)w * h * 3, pf);
                    fclose(pf);
                }
                printf("SHOT %s %ux%u at %llu us\n", name, w, h, (unsigned long long)(ninstr / ipu));
                if (sp_pend) { sp_pend = false; want_exit = true; }
            }
            else if (o == 0x50) {
                tot.instr = ninstr;
                printf("M,%u,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu\n", v, (unsigned long long)(ninstr / ipu),
                       (unsigned long long)(tot.instr - last.instr),
                       (unsigned long long)(tot.im[0] - last.im[0]), (unsigned long long)(tot.im[1] - last.im[1]),
                       (unsigned long long)(tot.dm[0] - last.dm[0]), (unsigned long long)(tot.dm[1] - last.dm[1]),
                       (unsigned long long)(tot.st[0] - last.st[0]), (unsigned long long)(tot.st[1] - last.st[1]));
                last = tot;
            }
            else if (o == 0x08) { exit_code = (int)v; done = true; }
            return;
        }
        uint8_t *p = host(a, reg);
        if (!p) bad("store to", a);
        if (a & (sz - 1)) { if (!misaligned++) fprintf(stderr, "MISALIGNED store %d at %08x pc %08x ra %08x\n", sz, a, pc, x[1]); }
        tot.st[reg]++;                 // write-through D$: every store is a bus write (no allocate)
        if (sz < 4) tot.st8[reg]++;    // of them bytes / halfwords (a 16-bit bus needs a mask, a cache line a merge)
        memcpy(p, &v, sz);
    };

    while (!done && ninstr < max_instr) {
        if (!have_at_in && ninstr / ipu >= in_at) { tot.instr = ninstr; at_in = tot; have_at_in = true; aud_under = 0; }
        if (prof && (ninstr & 255) == 0) fprintf(prof, "%x %x\n", pc, x[1]);
        uint8_t *ip = host(pc, reg);
        if (!ip) bad("fetch from", pc);
        if (ic.miss(pc)) tot.im[reg]++;
        uint32_t in; memcpy(&in, ip, 4);
        uint32_t op = in & 0x7f, rd = (in >> 7) & 31, f3 = (in >> 12) & 7, rs1 = (in >> 15) & 31, rs2 = (in >> 20) & 31, f7 = in >> 25;
        int32_t immi = (int32_t)in >> 20;
        int32_t imms = ((int32_t)in >> 25 << 5) | ((in >> 7) & 31);
        int32_t immb = (((int32_t)in >> 31) << 12) | (((in >> 7) & 1) << 11) | (((in >> 25) & 63) << 5) | (((in >> 8) & 15) << 1);
        int32_t immj = (((int32_t)in >> 31) << 20) | (in & 0xff000) | (((in >> 20) & 1) << 11) | (((in >> 21) & 1023) << 1);
        uint32_t a = x[rs1], b = x[rs2], r = 0, npc = pc + 4;
        bool wr = true;
        switch (op) {
        case 0x37: r = in & 0xfffff000u; break;
        case 0x17: r = pc + (in & 0xfffff000u); break;
        case 0x6f: r = pc + 4; npc = pc + immj; break;
        case 0x67: r = pc + 4; npc = (a + immi) & ~1u; break;
        case 0x63: {
            bool t = false;
            switch (f3) {
            case 0: t = a == b; break; case 1: t = a != b; break;
            case 4: t = (int32_t)a < (int32_t)b; break; case 5: t = (int32_t)a >= (int32_t)b; break;
            case 6: t = a < b; break; case 7: t = a >= b; break;
            default: fprintf(stderr, "bad branch at %08x\n", pc); return 3;
            }
            if (t) npc = pc + immb;
            wr = false; break;
        }
        case 0x03: {
            uint32_t ea = a + immi;
            switch (f3) {
            case 0: r = (uint32_t)(int32_t)(int8_t)ld(ea, 1); break;
            case 1: r = (uint32_t)(int32_t)(int16_t)ld(ea, 2); break;
            case 2: r = ld(ea, 4); break;
            case 4: r = ld(ea, 1) & 0xff; break;
            case 5: r = ld(ea, 2) & 0xffff; break;
            default: fprintf(stderr, "bad load at %08x\n", pc); return 3;
            }
            break;
        }
        case 0x23: {
            uint32_t ea = a + imms;
            st(ea, b, f3 == 0 ? 1 : f3 == 1 ? 2 : 4);
            wr = false; break;
        }
        case 0x13: {
            uint32_t sh = immi & 31;
            switch (f3) {
            case 0: r = a + immi; break;
            case 2: r = (int32_t)a < immi; break;
            case 3: r = a < (uint32_t)immi; break;
            case 4: r = a ^ immi; break;
            case 6: r = a | immi; break;
            case 7: r = a & immi; break;
            case 1: r = a << sh; break;
            case 5: r = (in >> 30 & 1) ? (uint32_t)((int32_t)a >> sh) : a >> sh; break;
            }
            break;
        }
        case 0x33:
            if (f7 == 1) {
                int64_t sa = (int32_t)a, sb = (int32_t)b;
                switch (f3) {
                case 0: r = a * b; break;
                case 1: r = (uint32_t)((sa * sb) >> 32); break;
                case 2: r = (uint32_t)((sa * (int64_t)(uint64_t)b) >> 32); break;
                case 3: r = (uint32_t)(((uint64_t)a * b) >> 32); break;
                case 4: r = b == 0 ? 0xffffffffu : (a == 0x80000000u && b == 0xffffffffu) ? a : (uint32_t)((int32_t)a / (int32_t)b); break;
                case 5: r = b == 0 ? 0xffffffffu : a / b; break;
                case 6: r = b == 0 ? a : (a == 0x80000000u && b == 0xffffffffu) ? 0 : (uint32_t)((int32_t)a % (int32_t)b); break;
                case 7: r = b == 0 ? a : a % b; break;
                }
            } else {
                switch (f3) {
                case 0: r = (f7 & 0x20) ? a - b : a + b; break;
                case 1: r = a << (b & 31); break;
                case 2: r = (int32_t)a < (int32_t)b; break;
                case 3: r = a < b; break;
                case 4: r = a ^ b; break;
                case 5: r = (f7 & 0x20) ? (uint32_t)((int32_t)a >> (b & 31)) : a >> (b & 31); break;
                case 6: r = a | b; break;
                case 7: r = a & b; break;
                }
            }
            break;
        case 0x0f: wr = false; break; // fence
        case 0x73: wr = (rd != 0); r = 0; break; // csr reads as 0, ecall/ebreak ignored
        default:
            fprintf(stderr, "illegal %08x at %08x after %llu\n", in, pc, (unsigned long long)ninstr);
            return 3;
        }
        if (wr && rd) x[rd] = r;
        pc = npc;
        ninstr++;
    }
    if (!line.empty()) printf("%s\n", line.c_str());
    if (prof) fclose(prof);
    if (txf) fclose(txf);
    tot.instr = ninstr;
    printf("END pc %08x ra %08x misaligned %llu\n", pc, x[1], (unsigned long long)misaligned);
    printf("END audio %llu samples, %llu not silent, %llu underruns\n", (unsigned long long)aud_wr, (unsigned long long)aud_nonsilent, (unsigned long long)aud_under);
    printf("END instr %llu us %llu input %zu/%zu exit %d%s im %llu/%llu dm %llu/%llu st %llu/%llu (sram/sdram)\n", (unsigned long long)ninstr, (unsigned long long)(ninstr / ipu), in_pos, in.size(), exit_code, done ? "" : " (max)",
           (unsigned long long)tot.im[0], (unsigned long long)tot.im[1], (unsigned long long)tot.dm[0], (unsigned long long)tot.dm[1],
           (unsigned long long)tot.st[0], (unsigned long long)tot.st[1]);
    return done ? 0 : 1;
}
