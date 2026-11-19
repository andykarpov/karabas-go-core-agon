#!/usr/bin/env python3
"""Ф1.2 per-opcode tests of the eZ80 core against the oracle.

For every opcode (base, CB, ED, DD, FD, DD/FD CB d op), with no suffix and each of .SIS / .LIS /
.SIL / .LIL, in ADL and in Z80 mode: a small flash image that sets a random state (JP.LIL to ADL,
24-bit values in BC DE HL IX IY, the shadows, SPS, SPL, F via POP AF, A; JP.SIS to Z80 mode for the
Z80 cases), then the opcode with random operand bytes. The oracle runs it as "MOS" (agon-oracle
--mos), the testbench (EZ80=1 build) replays the trace: every instruction of the set-up, the opcode
and the PC after it (jump targets) are compared.

usage: optest.py [--jobs N] [--seeds N] [--only HEX...] [--mode adl|z80] [--nosuffix] [--ref cemu|crate]
The reference is CEmu's cpu.c (src/oracle/cemu) by default: validated on real eZ80 silicon (TI-84 CE).
Prints a summary: the opcode keys that fail, with the first message of each.
"""
import argparse
import multiprocessing
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
ORACLE = os.path.join(ROOT, 'src', 'oracle', 'target', 'release', 'agon-oracle')
CEMU = os.path.join(ROOT, 'src', 'oracle', 'cemu', 'build', 'cemu-oracle')
REF = 'cemu'
TB = os.path.join(HERE, 'build-ez80', 'obj', 'Vtb_t80')

SUFFIXES = [None, 0x40, 0x49, 0x52, 0x5b]
RAM = 0x050000      # data pointers point here (external RAM in the default CS0 window)


def w24(v):
    return [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff]


def w16(v):
    return [v & 0xff, (v >> 8) & 0xff]


def opcodes():
    """(key, bytes before the operands, operand count) of every opcode to test."""
    out = []
    for o in range(256):
        if o in (0x76, 0xcb, 0xed, 0xdd, 0xfd, 0x40, 0x49, 0x52, 0x5b):
            continue
        out.append(('%02X' % o, [o]))
    for o in range(256):
        out.append(('CB %02X' % o, [0xcb, o]))
    for o in range(256):
        if o == 0x76:   # SLP
            continue
        out.append(('ED %02X' % o, [0xed, o]))
    for p in (0xdd, 0xfd):
        for o in range(256):
            if o in (0x76, 0xcb, 0xed, 0xdd, 0xfd):
                continue
            out.append(('%02X %02X' % (p, o), [p, o]))
        for o in range(256):
            out.append(('%02X CB d %02X' % (p, o), [p, 0xcb, None, o]))   # None = the d byte
    return out


def program(key, ops, suffix, adl, rnd):
    """The flash image and the number of set-up instructions before the opcode."""
    code = [0x5b, 0xc3] + w24(0x000010)          # JP.LIL 000010 (from Z80 mode at reset)
    n = 1
    code += [0] * (0x10 - len(code))
    def ins(b):
        nonlocal n
        code.extend(b)
        n += 1
    # shadows first: EXX / EX AF,AF' around their values
    for r in (0x01, 0x11, 0x21):                 # LD BC / DE / HL,nnnnnn
        ins([r] + w24(rnd.randrange(1 << 24)))
    ins([0x31] + w24(0x0bff00 - rnd.randrange(256) * 4))   # LD SP (SPL)
    ins([0x21] + w24(rnd.randrange(1 << 24)))
    ins([0xe5])                                  # PUSH HL
    ins([0xf1])                                  # POP AF
    ins([0xd9])                                  # EXX
    ins([0x08])                                  # EX AF,AF'
    # the state of the test
    ptr = lambda: RAM + rnd.randrange(0x8000)
    for r in (0x01, 0x11):                       # BC / DE: pointers or values
        ins([r] + w24(ptr() if rnd.random() < 0.6 else rnd.randrange(1 << 24)))
    k = rnd.random()                             # the last iteration of block instructions:
    if k < 0.15:                                 # B = 1
        ins([0x01] + w24(rnd.randrange(256) << 16 | 0x0100 | rnd.randrange(256)))
    elif k < 0.3:                                # BC = 1 (24 bits) / 0001 (16 bits)
        ins([0x01] + w24(1 if rnd.random() < 0.5 else rnd.randrange(256) << 16 | 1))
    ins([0xdd, 0x21] + w24(ptr()))               # IX
    ins([0xfd, 0x21] + w24(ptr()))               # IY
    ins([0x40, 0x31] + w16(0xf000 + rnd.randrange(0x800) * 2))   # .SIS LD SP,nnnn (SPS)
    ins([0x31] + w24(0x0bf000 - rnd.randrange(0x800) * 2))       # SPL
    ins([0x21] + w24(rnd.randrange(1 << 24)))
    ins([0xe5])
    ins([0xf1])                                  # F, A random
    ins([0x21] + w24(ptr()))                     # HL a pointer
    if rnd.random() < 0.3:
        ins([0xed, 0x7d])                        # STMIX: MADL = 1 (mixed TRAP / RET / interrupts)
    if not adl:
        here = len(code) + 4
        ins([0x40, 0xc3] + w16(here))            # JP.SIS to the next: Z80 mode (MBASE 0)
    body = []
    if suffix is not None:
        body.append(suffix)
    for b in ops:
        body.append(rnd.randrange(256) if b is None else b)
    body += [rnd.randrange(256) for _ in range(4)]    # operand bytes (n, nn, d)
    code += body
    img = bytes(code) + bytes(0x200 - len(code)) if len(code) < 0x200 else bytes(code)
    return img, n


def run_case(args):
    key, ops, suffix, adl, seed = args
    rnd = random.Random(hash((key, suffix, adl, seed)) & 0xffffffff)
    img, n = program(key, ops, suffix, adl, rnd)
    fill = rnd.randrange(1 << 20)   # RAM contents (stack, pointers): a hash of the address and this
    with tempfile.TemporaryDirectory() as d:
        b = os.path.join(d, 'p.bin')
        t = os.path.join(d, 't.txt')
        open(b, 'wb').write(img)
        if REF == 'cemu':
            cmd = [CEMU, '--flash', b, '--n', str(n + 3), '--trace', t, '--fill', str(fill)]
        else:
            cmd = [ORACLE, '--mos', b, '--ms', '1', '--trace', t, '--trace-n', str(n + 3)]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        # the reference trapped (invalid opcode: CEmu cpu_trap = an RST 00): the next PC is 000000
        lines = open(t).read().splitlines()
        trap = len(lines) > n + 1 and int(lines[n + 1].split()[2], 16) < 8   # (it may fetch a byte or two at 0)
        r = subprocess.run([TB, '--flash', b, '--trace', t, '--max', str(n + 1), '--quiet'] +
                           (['--fill-ext', str(fill)] if REF == 'cemu' else []),
                           capture_output=True, text=True)
    ok = r.returncode == 0 and 'PASS' in r.stdout
    # after a trap CEmu may run on into the first bytes at 000000 in the same step (the suffix of the
    # JP.LIL there): the state matched, the next PC 000000 of the core is right
    if not ok and trap and 'next PC rtl 000000 oracle 00000' in r.stdout and 'registers' not in r.stdout \
            and 'writes' not in r.stdout:
        ok = True
    msg = '' if ok else (r.stdout.strip().splitlines() or ['(no output)'])
    if not ok:
        # where: the set-up (instruction <= n) or the opcode (n + 1)
        first = msg[0]
        msg = ' | '.join(msg[:3])
        try:
            at = int(first.split('instruction ')[1].split(' ')[0])
        except (IndexError, ValueError):
            at = -1
        msg = ('[set-up] ' if 0 < at <= n else '') + msg
    sfx = {None: '', 0x40: '.SIS ', 0x49: '.LIS ', 0x52: '.SIL ', 0x5b: '.LIL '}[suffix]
    if not ok and trap:
        msg = '[trap] ' + msg
    return ('ADL ' if adl else 'Z80 ') + sfx + key, ok, msg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    ap.add_argument('--seeds', type=int, default=1)
    ap.add_argument('--only', nargs='*')
    ap.add_argument('--mode', choices=['adl', 'z80'])
    ap.add_argument('--nosuffix', action='store_true')
    ap.add_argument('--ref', choices=['cemu', 'crate'], default='cemu',
                    help='the reference: CEmu core/cpu.c (default) or the crate of the Agon emulator')
    args = ap.parse_args()
    global REF
    REF = args.ref
    cases = []
    for key, ops in opcodes():
        if args.only and not any(key.startswith(o.upper()) for o in args.only):
            continue
        for adl in (True, False):
            if args.mode and (adl != (args.mode == 'adl')):
                continue
            for sfx in ([None] if args.nosuffix else SUFFIXES):
                for seed in range(args.seeds):
                    cases.append((key, ops, sfx, adl, seed))
    with multiprocessing.Pool(args.jobs) as pool:
        res = pool.map(run_case, cases, chunksize=8)
    bad = {}
    for name, ok, msg in res:
        if not ok:
            bad.setdefault(name, msg)
    ntrap = sum(1 for m in bad.values() if m.startswith('[trap]'))
    print('cases %d, failing %d (%d opcode keys: %d where the reference traps, %d others)' %
          (len(res), sum(1 for r in res if not r[1]), len(bad), ntrap, len(bad) - ntrap))
    # a table: failing keys (not traps) per group and suffix
    groups = {}
    for name in bad:
        if bad[name].startswith('[trap]'):
            continue
        parts = name.split()
        mode = parts[0]
        sfx = parts[1] if parts[1].startswith('.') else '-'
        op = parts[2:] if sfx != '-' else parts[1:]
        grp = 'base' if len(op) == 1 else (op[0] + ' CB' if len(op) == 4 else op[0])
        groups[(mode, sfx, grp)] = groups.get((mode, sfx, grp), 0) + 1
    for k in sorted(groups):
        print('  %s %-5s %-6s %d' % (k[0], k[1], k[2], groups[k]))
    for name in sorted(bad):
        print('%-22s %s' % (name, bad[name][:300]))


if __name__ == '__main__':
    main()
