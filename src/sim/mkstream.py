#!/usr/bin/env python3
"""Ф0.4: MOS -> VDP byte streams for the VDP workload runs (run_f0.sh).

Each stream = the boot handshake (VDU 23,0,&80: general poll) + a workload + a general poll with a
tag, so the VDP reply "80 01 <tag>" in the ISS TX log marks the end of the work.
usage: mkstream.py <name> <out.bin>   names: see WORK
"""
import struct
import sys


def vdu(*b):
    return bytes(b)


def gp(tag):                       # VDU 23,0,&80,tag: general poll, the VDP answers 80 01 tag
    return vdu(23, 0, 0x80, tag)


def mode(m):
    return vdu(22, m)


def w(v):                          # 16-bit little-endian word of a VDU parameter
    return struct.pack('<h', v)


def plot(k, x, y):                 # VDU 25,k,x;y;
    return vdu(25, k) + w(x) + w(y)


def text(nbytes, width=79):
    out = bytearray()
    line = 0
    while len(out) < nbytes:
        s = ('%05d The quick brown fox jumps over the lazy dog 0123456789 ' % line)
        out += (s * 2)[:width].encode() + b'\r\n'
        line += 1
    return bytes(out[:nbytes])


WORK = {
    # 8 KB of text in mode 0 (640x480, 16 colours): about 100 lines, 40 of them scroll
    'text0': lambda: mode(0) + text(8192),
    # the same in mode 1 (640x480, 4 colours) and mode 3 (640x240, 64 colours)
    'text1': lambda: mode(1) + text(8192),
    'text3': lambda: mode(3) + text(8192),
    # 8 mode changes 0..7
    'modes': lambda: b''.join(mode(m) for m in range(8)) + mode(0),
    # 200 lines across the screen, mode 0 (OS coordinates 1280x1024)
    'lines': lambda: mode(0) + b''.join(vdu(18, 0, 1 + i % 15) + plot(4, (i * 37) % 1280, 0) + plot(5, 1279 - (i * 53) % 1280, 1023)
                                        for i in range(200)),
    # 50 filled triangles and 50 filled circles
    'fills': lambda: mode(0) + b''.join(vdu(18, 0, 1 + i % 15) + plot(4, 100 + i * 10, 100) + plot(4, 600 + i * 5, 900) + plot(85, 1200 - i * 8, 300)
                                        for i in range(50))
                     + b''.join(vdu(18, 0, 1 + i % 15) + plot(4, 640, 512) + plot(157, 640 + 20 + i * 8, 512) for i in range(50)),
    # clear screen 20 times (CLS) in mode 0
    'cls': lambda: mode(0) + vdu(12) * 20,
}


def main():
    name, out = sys.argv[1], sys.argv[2]
    data = gp(0x55) + WORK[name]() + gp(0xaa)
    with open(out, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    main()
