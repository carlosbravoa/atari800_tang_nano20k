#!/usr/bin/env python3
"""py65 test for the first-cut R: (modem) CIO handler.

Assembles the handler at an install org (as `atari.py r-install` would via
plan_install(MEMLO)), drives its CIO vectors as the OS would (X = IOCB*16,
ZIOCB populated), and stubs SIOV ($E459) with a python mirror of the firmware's
device-$50 850 command set (CONFIGURE/CONTROL/STATUS/STREAM). Asserts each CIO
op issues the right SIO command and that XIO 40 programs POKEY ($D200-$D208 +
SKCTL) from the returned 9-byte table.

Run: python3 tools/test_r_handler.py
"""
import os
import sys

from py65.devices.mpu6502 import MPU

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from r_handler import build, plan_install, SIOV, DVSTAT, AUDF1, SKCTL, SSKCTL

DCOMND, DSTATS = 0x0302, 0x0303
DBUFLO, DBUFHI = 0x0304, 0x0305
DBYTLO, DBYTHI, DAUX1, DAUX2 = 0x0308, 0x0309, 0x030A, 0x030B
ICCOMZ, ICBALZ, ICBAHZ, ICAX1Z = 0x22, 0x24, 0x25, 0x2A
DOS_BASE = 0x0700
SENTINEL = 0xA5

# 19200 POKEY block that the firmware's $58 STREAM returns (FujiNet table).
POKEY_19200 = bytes([0x28, 0xA0, 0x00, 0xA0, 0x28, 0xA0, 0x00, 0xA0, 0x78])
STATUS_CONNECTED = bytes([0x00, 0xCC])          # {err=0, handshake=DSR|CTS|CRX}


class FwModem:
    """Mirror of firmware.c sio_rs232() ($50) for the SIOV stub."""
    def __init__(self):
        self.cmds = []                          # (cmd, aux1, aux2) issued

    def call(self, mem):
        cmd, aux1, aux2 = mem[DCOMND], mem[DAUX1], mem[DAUX2]
        buf = mem[DBUFLO] | (mem[DBUFHI] << 8)
        self.cmds.append((cmd, aux1, aux2))
        if cmd == 0x53:                         # STATUS -> 2 bytes
            for i, b in enumerate(STATUS_CONNECTED):
                mem[buf + i] = b
            return 1
        if cmd == 0x58:                         # STREAM -> 9-byte POKEY table
            for i, b in enumerate(POKEY_19200):
                mem[buf + i] = b
            return 1
        if cmd in (0x42, 0x41):                 # CONFIGURE / CONTROL (complete-only)
            return 1
        return 1

    def last(self):
        return self.cmds[-1] if self.cmds else (None, None, None)


class Rig:
    def __init__(self, org):
        self.org = org
        self.code, _ = build(org)
        self.mpu = MPU()
        self.mem = self.mpu.memory
        for a in range(DOS_BASE, org):
            self.mem[a] = SENTINEL
        for i, b in enumerate(self.code):
            self.mem[org + i] = b
        self.fw = FwModem()

    def dos_intact(self):
        return all(self.mem[a] == SENTINEL for a in range(DOS_BASE, self.org))

    def vector(self, idx):
        lo = self.mem[self.org + idx * 2] | (self.mem[self.org + idx * 2 + 1] << 8)
        return lo + 1

    def call(self, idx, iocb=1, a=0, ax1=0, iccom=0, max_steps=200000):
        m = self.mpu
        self.mem[ICAX1Z] = ax1
        self.mem[ICCOMZ] = iccom
        m.pc = self.vector(idx)
        m.a, m.x, m.y = a, (iocb << 4) & 0xFF, 0
        m.sp = 0xFB
        self.mem[0x01FC], self.mem[0x01FD] = 0xFE, 0xBF   # RTS -> $BFFF
        self.mem[0xBFFF] = 0x00                            # BRK fence
        for _ in range(max_steps):
            if m.pc == SIOV:
                status = self.fw.call(self.mem)
                m.y = status
                self.mem[DSTATS] = status
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


def run_matrix(org, tag):
    print(f"── matrix at org ${org:04X} ({tag}) ──")
    r = Rig(org)

    # OPEN -> CONFIGURE default 19200
    _, y = r.call(OPEN, iocb=1)
    cmd, aux1, _ = r.fw.last()
    check("open -> CONFIGURE 19200", y == 1 and cmd == 0x42 and aux1 == 0x0F,
          f"y={y} cmd=${cmd:02X} aux1=${aux1:02X}")

    # STATUS -> $53 fills DVSTAT
    _, y = r.call(STATUS, iocb=1)
    dv = bytes([r.mem[DVSTAT], r.mem[DVSTAT + 1]])
    check("status -> $53 -> DVSTAT", y == 1 and r.fw.last()[0] == 0x53
          and dv == STATUS_CONNECTED, f"y={y} dv={dv.hex()}")

    # XIO 40 -> STREAM. Must NOT touch POKEY (leaving POKEY reprogrammed corrupts
    # the following SIO command frames — the bench "cmd cksum" storm).
    _, y = r.call(SPECIAL, iocb=1, iccom=40)
    poked = bytes(r.mem[AUDF1 + i] for i in range(9))
    check("xio40 -> STREAM issued", r.fw.last()[0] == 0x58 and y == 1)
    check("xio40 leaves POKEY untouched (no cmd-frame corruption)",
          poked == bytes(9) and r.mem[SKCTL] == 0 and r.mem[SSKCTL] == 0,
          f"audf={poked.hex()} skctl=${r.mem[SKCTL]:02X}")

    # XIO 36 baud -> CONFIGURE with the requested code
    _, y = r.call(SPECIAL, iocb=1, ax1=0x0E, iccom=36)      # 0x0E = 9600
    cmd, aux1, _ = r.fw.last()
    check("xio36 -> CONFIGURE 9600", y == 1 and cmd == 0x42 and aux1 == 0x0E,
          f"cmd=${cmd:02X} aux1=${aux1:02X}")

    # CLOSE -> CONTROL DTR drop
    n_before = len(r.fw.cmds)
    _, y = r.call(CLOSE, iocb=1)
    cmd, aux1, _ = r.fw.last()
    check("close -> CONTROL DTR-drop", y == 1 and cmd == 0x41 and aux1 == 0x80,
          f"cmd=${cmd:02X} aux1=${aux1:02X}")

    # GET / PUT stubs: succeed, issue no SIO
    n = len(r.fw.cmds)
    a, y = r.call(GET, iocb=1)
    check("get stub (A=0, Y=1, no SIO)", a == 0 and y == 1 and len(r.fw.cmds) == n,
          f"a={a} y={y}")
    _, y = r.call(PUT, iocb=1, a=0x55)
    check("put stub (Y=1, no SIO)", y == 1 and len(r.fw.cmds) == n, f"y={y}")

    # unknown XIO accepted (so BobTerm's misc XIOs don't fail the open)
    _, y = r.call(SPECIAL, iocb=1, iccom=44)
    check("unknown xio accepted", y == 1, f"y={y}")

    check("resident DOS region intact", r.dos_intact())


def test_installer_and_xex():
    """The boot-disk path: the INITAD self-installer registers 'R' in HATABS,
    and build_xex() wraps body + installer-stub + INITAD correctly."""
    from r_handler import build, build_xex, BOOT_ORG
    code, labels = build(BOOT_ORG)
    mpu = MPU()
    mem = mpu.memory
    for i, b in enumerate(code):
        mem[BOOT_ORG + i] = b
    # HATABS: two resident devices (P,C) then empty slots
    hat = {0x031A: ord('P'), 0x031D: ord('C')}
    for a in range(0x031A, 0x031A + 36):
        mem[a] = hat.get(a, 0)
    # run the installer to RTS
    mpu.pc = labels['installer']
    mpu.sp = 0xFB
    mem[0x01FC], mem[0x01FD] = 0xFE, 0xBF
    mem[0xBFFF] = 0x00
    for _ in range(5000):
        if mpu.pc == 0xBFFF:
            break
        mpu.step()
    # 'R' should now be at the first empty slot ($0320) -> $2000 (BOOT_ORG)
    slot = None
    for a in range(0x031A, 0x031A + 36, 3):
        if mem[a] == ord('R'):
            slot = a
    tbl = (mem[slot + 1] | (mem[slot + 2] << 8)) if slot else 0
    check("installer registers R: in HATABS -> handler table",
          slot == 0x0320 and tbl == BOOT_ORG,
          f"slot=${slot:04X} tbl=${tbl:04X}" if slot else "R: not found")

    # idempotent: running again must not add a duplicate
    mpu.pc = labels['installer']; mpu.sp = 0xFB
    for _ in range(5000):
        if mpu.pc == 0xBFFF:
            break
        mpu.step()
    rcount = sum(1 for a in range(0x031A, 0x031A + 36, 3) if mem[a] == ord('R'))
    check("installer is idempotent", rcount == 1, f"R count={rcount}")

    # build_xex structure: body seg @ BOOT_ORG, stub seg, INITAD -> stub
    xex, new_memlo = build_xex()
    check("xex starts with $FFFF header", xex[:2] == b"\xff\xff")
    st = xex[2] | xex[3] << 8
    check("first segment loads at BOOT_ORG", st == BOOT_ORG, f"${st:04X}")
    # find the INITAD segment (start==$02E2)
    i, found_init = 2, False
    while i + 4 <= len(xex):
        if xex[i:i + 2] == b"\xff\xff":
            i += 2; continue
        s = xex[i] | xex[i + 1] << 8
        e = xex[i + 2] | xex[i + 3] << 8
        i += 4 + (e - s + 1)
        if s == 0x02E2:
            found_init = True
    check("xex sets INITAD ($02E2)", found_init)
    check("MEMLO raised above handler", new_memlo >= BOOT_ORG + len(code),
          f"memlo'=${new_memlo:04X}")


def main():
    org_dosless, code, nm = plan_install(0x0700)
    check("plan(MEMLO=$0700) = $0900", org_dosless == 0x0900,
          f"org=${org_dosless:04X}")
    for memlo in (0x0700, 0x1FE5, 0x2A00):
        org, code, nm = plan_install(memlo)
        check(f"plan(MEMLO=${memlo:04X}) page-aligned above MEMLO w/ room",
              org - memlo >= 0x200 and (org & 0xFF) == 0 and nm >= org + len(code),
              f"org=${org:04X} memlo'=${nm:04X}")

    org_mydos, _, _ = plan_install(0x1FE5)
    run_matrix(org_dosless, "DOS-less, MEMLO=$0700")
    run_matrix(org_mydos, "resident MyDOS, MEMLO=$1FE5")
    print("── boot-disk self-installer (INITAD) ──")
    test_installer_and_xex()

    print(f"\n{'ALL GREEN' if fails == 0 else f'{fails} FAILURES'}")
    return fails


if __name__ == '__main__':
    sys.exit(main())
