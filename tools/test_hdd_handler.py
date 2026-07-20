#!/usr/bin/env python3
"""py65 test matrix for the H: CIO handler.

Loads hdd_handler.bin at $0900, drives its CIO vectors exactly as the OS
would (X = IOCB*16, ZIOCB populated), and stubs SIOV ($E459) with a python
implementation of the firmware's device-$72 protocol over a temp directory —
the same semantics as firmware.c's hdd_* (which have their own host suite).

Run: python3 tools/test_hdd_handler.py
"""
import os
import sys
import tempfile

from py65.devices.mpu6502 import MPU

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hdd_handler import build, LOAD, SIOV, DVSTAT

DDEVIC, DUNIT, DCOMND, DSTATS = 0x0300, 0x0301, 0x0302, 0x0303
DBUFLO, DBUFHI = 0x0304, 0x0305
DBYTLO, DBYTHI, DAUX1, DAUX2 = 0x0308, 0x0309, 0x030A, 0x030B
ICCOMZ, ICBALZ, ICBAHZ, ICAX1Z = 0x22, 0x24, 0x25, 0x2A
NAME_AT = 0x8000

CODE, LABELS = build()


# ── python mirror of the firmware's device-$72 semantics ────────────────────
class FwSide:
    def __init__(self, root):
        self.root = root
        self.h = [None, None]          # per-slot: None | file obj | ('dir', bytes, pos)

    def _path(self, raw):
        name, dots, started = "", 0, False
        for ch in raw.split("\x00")[0]:
            c = ch.upper()
            if c == ':':
                name, dots = "", 0
                continue
            if c == '.':
                if not name or dots:
                    continue
                dots += 1
                name += c
            elif c.isalnum() or c in '_-':
                name += c
        return os.path.join(self.root, name) if name else None

    def call(self, mem):
        cmd = mem[DCOMND]
        aux1, aux2 = mem[DAUX1], mem[DAUX2]
        buf = mem[DBUFLO] | (mem[DBUFHI] << 8)
        nbytes = mem[DBYTLO] | (mem[DBYTHI] << 8)
        h = aux2 & 3
        if h > 1:
            return 139
        try:
            if cmd == 0x4F:                                   # OPEN
                raw = bytes(mem[buf:buf + 64]).decode('latin1')
                if aux1 == 6:
                    lines = []
                    for fn in sorted(os.listdir(self.root)):
                        p = os.path.join(self.root, fn)
                        if os.path.isfile(p):
                            lines.append(f"{fn.upper():<14}{os.path.getsize(p)}\x9b")
                    lines.append("END OF DIRECTORY\x9b")
                    self.h[h] = ['dir', "".join(lines).encode('latin1'), 0]
                    return 1
                path = self._path(raw)
                if not path:
                    return 139
                if aux1 == 8:
                    self.h[h] = open(path, 'wb')
                elif aux1 == 9:
                    self.h[h] = open(path, 'ab')
                else:
                    if not os.path.exists(path):
                        return 170
                    self.h[h] = open(path, 'rb')
                return 1
            if cmd == 0x53:                                   # STATUS
                st = bytearray(4)
                st[0] = 1
                obj = self.h[h]
                if obj is None:
                    st[0] = 133
                else:
                    if isinstance(obj, list):
                        avail = len(obj[1]) - obj[2]
                    else:
                        pos = obj.tell()
                        obj.seek(0, 2)
                        end = obj.tell()
                        obj.seek(pos)
                        avail = max(0, end - pos)
                    st[1] = 1 | (2 if avail == 0 else 0)
                    avail = min(avail, 65535)
                    st[2], st[3] = avail & 0xFF, avail >> 8
                for i in range(4):
                    mem[buf + i] = st[i]
                return 1
            if cmd == 0x52:                                   # READ
                obj = self.h[h]
                if obj is None:
                    return 139
                if isinstance(obj, list):
                    data = obj[1][obj[2]:obj[2] + nbytes]
                    obj[2] += len(data)
                else:
                    data = obj.read(nbytes)
                if len(data) != nbytes:
                    return 144
                for i, byte in enumerate(data):
                    mem[buf + i] = byte
                return 1
            if cmd == 0x57:                                   # WRITE
                obj = self.h[h]
                if obj is None or isinstance(obj, list):
                    return 139
                obj.write(bytes(mem[buf:buf + nbytes]))
                return 1
            if cmd == 0x43:                                   # CLOSE
                obj = self.h[h]
                if obj is not None and not isinstance(obj, list):
                    obj.close()
                self.h[h] = None
                return 1
            if cmd == 0x58:                                   # XIO
                raw = bytes(mem[buf:buf + 64]).decode('latin1')
                if aux1 == 33:
                    p = self._path(raw)
                    if p and os.path.exists(p):
                        os.unlink(p)
                        return 1
                    return 170
                if aux1 == 32:
                    parts = raw.split("\x00")[0].split(',')
                    if len(parts) == 2:
                        po, pn = self._path(parts[0]), self._path(parts[1])
                        if po and pn and os.path.exists(po):
                            os.rename(po, pn)
                            return 1
                    return 170
                return 139
        except OSError:
            return 144
        return 139


# ── CIO-style driver ─────────────────────────────────────────────────────────
class Rig:
    def __init__(self, tmp):
        self.mpu = MPU()
        self.mem = self.mpu.memory
        for i, byte in enumerate(CODE):
            self.mem[LOAD + i] = byte
        self.fw = FwSide(tmp)

    def vector(self, idx):
        lo = self.mem[LOAD + idx * 2] | (self.mem[LOAD + idx * 2 + 1] << 8)
        return lo + 1

    def call(self, idx, iocb=1, a=0, name=None, ax1=0, iccom=0, max_steps=200000):
        m = self.mpu
        if name is not None:
            for i, ch in enumerate(name.encode('latin1') + b'\x9b'):
                self.mem[NAME_AT + i] = ch
            self.mem[ICBALZ] = NAME_AT & 0xFF
            self.mem[ICBAHZ] = NAME_AT >> 8
        self.mem[ICAX1Z] = ax1
        self.mem[ICCOMZ] = iccom
        m.pc = self.vector(idx)
        m.a, m.x, m.y = a, (iocb << 4) & 0xFF, 0
        m.sp = 0xFD
        # fake return address so the handler's RTS lands on a BRK fence
        self.mem[0x01FD - 1 + 1] = 0  # keep py65 happy; we push manually:
        m.sp = 0xFB
        self.mem[0x01FC], self.mem[0x01FD] = 0xFE, 0xBF   # RTS -> $BFFF
        self.mem[0xBFFF] = 0x00                            # BRK fence
        for _ in range(max_steps):
            if m.pc == SIOV:
                status = self.fw.call(self.mem)
                m.y = status
                self.mem[DSTATS] = status
                # simulate RTS
                lo = self.mem[0x100 + ((m.sp + 1) & 0xFF)]
                hi = self.mem[0x100 + ((m.sp + 2) & 0xFF)]
                m.sp = (m.sp + 2) & 0xFF
                m.pc = ((hi << 8) | lo) + 1
                continue
            if m.pc == 0xBFFF:
                return m.a, m.y
            m.step()
        raise RuntimeError("handler runaway")


OPEN, CLOSE, GET, PUT, STATUS, SPECIAL = 0, 1, 2, 3, 4, 5
fails = 0


def check(label, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + (f"  {extra}" if extra else ""))
    if not cond:
        fails += 1


def main():
    tmp = tempfile.mkdtemp(prefix="hddtest_")
    r = Rig(tmp)

    # 1. open-write + 300 PUTs (two full flushes + partial at close)
    _, y = r.call(OPEN, iocb=1, name="H:TEST.TXT", ax1=8)
    check("open write", y == 1, f"y={y}")
    payload = bytes((i * 7 + 3) & 0xFF for i in range(300))
    ok = all(r.call(PUT, iocb=1, a=b)[1] == 1 for b in payload)
    check("300 PUTs", ok)
    _, y = r.call(CLOSE, iocb=1)
    check("close write", y == 1, f"y={y}")
    on_disk = open(os.path.join(tmp, "TEST.TXT"), 'rb').read()
    check("file content", on_disk == payload, f"{len(on_disk)} bytes")

    # 2. open-read + GET until EOF
    _, y = r.call(OPEN, iocb=1, name="H:TEST.TXT", ax1=4)
    check("open read", y == 1, f"y={y}")
    got = bytearray()
    while True:
        a, y = r.call(GET, iocb=1)
        if y != 1:
            break
        got.append(a)
    check("read back", bytes(got) == payload and y == 136, f"y={y} n={len(got)}")
    r.call(CLOSE, iocb=1)

    # 3. append + size check via STATUS
    r.call(OPEN, iocb=1, name="H:TEST.TXT", ax1=9)
    for b in b"XYZ":
        r.call(PUT, iocb=1, a=b)
    r.call(CLOSE, iocb=1)
    r.call(OPEN, iocb=1, name="H:TEST.TXT", ax1=4)
    _, y = r.call(STATUS, iocb=1)
    avail = r.mem[DVSTAT + 2] | (r.mem[DVSTAT + 3] << 8)
    check("append+status", y == 1 and avail == 303, f"avail={avail}")
    r.call(CLOSE, iocb=1)

    # 4. two concurrent channels (write on IOCB2 while reading on IOCB3)
    r.call(OPEN, iocb=2, name="H:B.DAT", ax1=8)
    r.call(OPEN, iocb=3, name="H:TEST.TXT", ax1=4)
    ok = True
    for i in range(64):
        ok &= r.call(PUT, iocb=2, a=i)[1] == 1
        a, y = r.call(GET, iocb=3)
        ok &= y == 1 and a == payload[i]
    r.call(CLOSE, iocb=2)
    r.call(CLOSE, iocb=3)
    check("two channels", ok and
          open(os.path.join(tmp, "B.DAT"), 'rb').read() == bytes(range(64)))

    # 5. directory listing
    r.call(OPEN, iocb=1, name="H:", ax1=6)
    listing = bytearray()
    while True:
        a, y = r.call(GET, iocb=1)
        if y != 1:
            break
        listing.append(a)
    text = listing.decode('latin1')
    check("dir listing", "TEST.TXT" in text and "B.DAT" in text and y == 136)
    r.call(CLOSE, iocb=1)

    # 6. XIO rename + delete
    _, y = r.call(SPECIAL, iocb=1, name="H:B.DAT,H:C.DAT", iccom=32)
    check("xio rename", y == 1 and os.path.exists(os.path.join(tmp, "C.DAT")),
          f"y={y}")
    _, y = r.call(SPECIAL, iocb=1, name="H:C.DAT", iccom=33)
    check("xio delete", y == 1 and not os.path.exists(os.path.join(tmp, "C.DAT")),
          f"y={y}")

    # 7. error paths
    _, y = r.call(OPEN, iocb=1, name="H:NOPE.FIL", ax1=4)
    check("open missing -> err", y > 127, f"y={y}")
    _, y = r.call(GET, iocb=5)
    check("get unopened -> 133", y == 133, f"y={y}")
    r.call(OPEN, iocb=1, name="H:TEST.TXT", ax1=4)
    r.call(OPEN, iocb=2, name="H:TEST.TXT", ax1=4)
    _, y = r.call(OPEN, iocb=3, name="H:TEST.TXT", ax1=4)
    check("third open -> 161", y == 161, f"y={y}")
    r.call(CLOSE, iocb=1)
    r.call(CLOSE, iocb=2)

    print(f"\n{'ALL GREEN' if fails == 0 else f'{fails} FAILURES'}")
    return fails


if __name__ == '__main__':
    sys.exit(main())
