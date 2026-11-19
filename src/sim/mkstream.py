#!/usr/bin/env python3
"""Ф0.4: MOS -> VDP byte streams for the VDP workload runs (run_f0.sh).

Each stream = the boot handshake (VDU 23,0,&80: general poll) + a workload + a general poll with a
tag, so the VDP reply "80 01 <tag>" in the ISS TX log marks the end of the work.
usage: mkstream.py [--nocursor] [--settle] <name> <out.bin>   names: see WORK
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


def bitmap_def(n, wpx, hpx):     # VDU 23,27,0,n: select bitmap n; VDU 23,27,1,w;h;<RGBA8888>
    px = bytearray()
    for y in range(hpx):
        for x in range(wpx):
            px += bytes((x * 16 & 255, y * 16 & 255, (x ^ y) * 8 & 255, 255 if (x - 8) ** 2 + (y - 8) ** 2 < 60 else 0))
    return vdu(23, 27, 0, n) + vdu(23, 27, 1) + w(wpx) + w(hpx) + bytes(px)


def bitmap_draw(n, x, y):         # VDU 23,27,0,n; VDU 23,27,3,x;y;
    return vdu(23, 27, 0, n) + vdu(23, 27, 3) + w(x) + w(y)


def gtext(mode_n, s):
    """VDU 5 (text at the graphics cursor) at odd pixel positions, then inside a graphics window
    (VDU 24) that cuts the glyphs: the paths the 8-aligned text cells never take."""
    out = bytearray(mode(mode_n) + vdu(5))
    for i in range(40):            # OS units: x 1280 wide, y 1024 high; odd pixels in every mode
        out += plot(4, 3 + i * 29, 1000 - i * 23) + s
    out += vdu(24) + w(203) + w(301) + w(1001) + w(699)   # graphics window left;bottom;right;top
    for i in range(40):
        out += plot(4, 150 + i * 21, 720 - i * 11) + s
    out += vdu(26, 4)              # reset the windows, VDU 4: text at the text cursor again
    return bytes(out)


def sprites(nspr, steps):
    out = bytearray(bitmap_def(0, 16, 16) + bitmap_def(1, 16, 16))
    for i in range(nspr):          # VDU 23,27,4,i select; 5 clear frames; 6,b add frame; 11 show
        out += vdu(23, 27, 4, i) + vdu(23, 27, 5) + vdu(23, 27, 6, 0) + vdu(23, 27, 6, 1) + vdu(23, 27, 11)
    out += vdu(23, 27, 7, nspr)    # activate
    for t in range(steps):
        for i in range(nspr):      # move to x;y (pixels), next frame
            out += vdu(23, 27, 4, i) + vdu(23, 27, 13) + w((i * 37 + t * 4) % 300) + w((i * 23 + t * 3) % 220) + vdu(23, 27, 8)
        out += vdu(23, 27, 15)     # refresh = one game frame
    return bytes(out)


def hwsprites(nspr, steps, wx, wy):
    # the same with hardware sprites (test flag 2 = VDU 23,0,&F8,2;1;, then VDU 23,27,19 per sprite):
    # drawn by the scanout over the frame; positions from -8 for the clipping at the edges
    out = bytearray(vdu(23, 0, 0xf8) + w(2) + w(1) + bitmap_def(0, 16, 16) + bitmap_def(1, 16, 16))
    for i in range(nspr):
        out += vdu(23, 27, 4, i) + vdu(23, 27, 5) + vdu(23, 27, 6, 0) + vdu(23, 27, 6, 1) + vdu(23, 27, 19) + vdu(23, 27, 11)
    out += vdu(23, 27, 7, nspr)
    for t in range(steps):
        for i in range(nspr):
            out += vdu(23, 27, 4, i) + vdu(23, 27, 13) + w((i * 37 + t * 4) % wx - 8) + w((i * 23 + t * 3) % wy - 8) + vdu(23, 27, 8)
        out += vdu(23, 27, 15)
    return bytes(out)


def note(ch, vol, freq, ms):      # VDU 23,0,&85,ch,0 (play),vol,freq;duration;
    return vdu(23, 0, 0x85, ch, 0, vol) + w(freq) + w(ms)


WORK = {
    # 8 KB of text in mode 0 (640x480, 16 colours): about 100 lines, 40 of them scroll
    'text0': lambda: mode(0) + text(8192),
    # the same in mode 1 (640x480, 4 colours) and mode 3 (640x240, 64 colours)
    'text1': lambda: mode(1) + text(8192),
    'text3': lambda: mode(3) + text(8192),
    # mode 2 (640x480, 2 colours) and mode 8 (320x240, 64 colours)
    'text2': lambda: mode(2) + text(8192),
    'text8': lambda: mode(8) + text(8192),
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
    # a 16x16 RGBA bitmap drawn 200 times, mode 0 and mode 8 (320x240, 64 colours, games)
    'bitmaps0': lambda: mode(0) + bitmap_def(0, 16, 16) + b''.join(bitmap_draw(0, (i * 29) % 620, (i * 17) % 460) for i in range(200)),
    'bitmaps8': lambda: mode(8) + bitmap_def(0, 16, 16) + b''.join(bitmap_draw(0, (i * 29) % 300, (i * 17) % 220) for i in range(200)),
    # big blits, mode 8: a 64x64 bitmap 50 times, a full-screen 320x240 bitmap 5 times
    'blit64': lambda: mode(8) + bitmap_def(0, 64, 64) + b''.join(bitmap_draw(0, (i * 29) % 256, (i * 17) % 176) for i in range(50)),
    'blitfull': lambda: mode(8) + bitmap_def(0, 320, 240) + b''.join(bitmap_draw(0, 0, 0) for i in range(5)),
    # text at the graphics cursor (odd positions, clipped by a graphics window): 16 / 4 / 2 / 64 colours
    'gtext0': lambda: gtext(0, b'Agon!'),
    'gtext1': lambda: gtext(1, b'Agon!'),
    'gtext2': lambda: gtext(2, b'Agon!'),
    'gtext8': lambda: gtext(8, b'Agon!'),
    # 16 sprites of 16x16 (2 frames), 60 refreshes, mode 8
    'sprites8': lambda: mode(8) + sprites(16, 60),
    # hardware sprites (the scanout overlay), mode 8 (320x240 64 colours) and mode 0 (640x480 16)
    'hwspr8': lambda: mode(8) + text(300) + hwsprites(16, 10, 330, 250),
    'hwspr0': lambda: mode(0) + text(300) + hwsprites(16, 10, 650, 490),
    # some text with the text cursor on (run without --nocursor: an XOR RGBA2222 sprite), steady
    # (back over the last character: VDU 8; then VDU 23,0,&0A,0 no blink + VDU 23,1,1 on: in the screenshot)
    'cursor0': lambda: mode(0) + text(300) + vdu(8) + vdu(23, 0, 0x0a, 0) + vdu(23, 1, 1, 0, 0, 0, 0, 0, 0, 0),
    # text0 while 3 channels play 4 s notes (audio cost = textaudio - text0)
    'textaudio': lambda: mode(0) + note(0, 100, 440, 4000) + note(1, 100, 554, 4000) + note(2, 100, 659, 4000) + text(8192),
}


def main():
    # --nocursor: the text cursor off first (VDU 23,1,0): its blink depends on time, so screenshots
    # of runs with another timing (the RTL against the ISS) differ only there
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    name, out = args[0], args[1]
    pre = vdu(23, 1, 0, 0, 0, 0, 0, 0, 0, 0) if '--nocursor' in sys.argv else b''
    # --settle: 6000 VDU 0 (nothing) at the end: at the real rate ~50 ms = 3 vblanks, so the frame
    # description of the last vblank is the picture of the screenshot (sprites moved after it otherwise)
    post = bytes(6000) if '--settle' in sys.argv else b''
    # mgN: gtext in Agon mode N (Ф2: the output timings of every mode)
    work = (lambda: gtext(int(name[2:]), b'Agon!')) if name.startswith('mg') and name[2:].isdigit() else WORK[name]
    data = gp(0x55) + pre + work() + post + gp(0xaa)
    with open(out, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    main()
