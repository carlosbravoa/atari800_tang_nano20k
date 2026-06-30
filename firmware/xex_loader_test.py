#!/usr/bin/env python3
# Simulates the assembled XEX boot loader in py65 against a synthetic .xex
# that exercises: multiple segments, a $FFFF separator, an INITAD segment
# (must JSR once), and a RUNAD segment (must JMP at EOF).
import re, sys
from py65.devices.mpu6502 import MPU

# ---- pull the loader image + constants out of the generated header ----
src = open('xex_loader.h').read()
def const(name): return int(re.search(rf'#define {name}\s+(\d+)', src).group(1))
BLDCNT   = const('XEX_BLDCNT')
FIRSTSEC = const('XEX_FIRSTSEC')
REMLO_OFF, REMMID_OFF, REMHI_OFF = const('XEX_REMLO_OFF'), const('XEX_REMMID_OFF'), const('XEX_REMHI_OFF')
img = [int(x,16) for x in re.findall(r'0x([0-9a-fA-F]{2})', src.split('{',1)[1])]

# ---- synthetic .xex ----
def word(v): return [v & 0xFF, (v >> 8) & 0xFF]
xex = []
xex += word(0xFFFF)                       # mandatory header
xex += word(0x2000) + word(0x2004)        # seg A: $2000..$2004 (5 bytes)
xex += [0x11,0x22,0x33,0x44,0x55]
xex += word(0xFFFF)                        # separator
xex += word(0x2100) + word(0x2103)         # seg B: init routine  INC $4000 / RTS
xex += [0xEE,0x00,0x40,0x60]
xex += word(0x02E2) + word(0x02E3)         # seg C: INITAD = $2100  -> JSR once
xex += word(0x2100)
xex += word(0x02E0) + word(0x02E1)         # seg D: RUNAD = $5000   -> JMP at EOF
xex += word(0x5000)
XEX_LEN = len(xex)

# ---- patch REM (24-bit length) into the loader image, like the firmware does ----
img = img[:]
img[REMLO_OFF]  =  XEX_LEN        & 0xFF
img[REMMID_OFF] = (XEX_LEN >> 8)  & 0xFF
img[REMHI_OFF]  = (XEX_LEN >> 16) & 0xFF

# ---- virtual disk: sectors 1..BLDCNT = loader, FIRSTSEC.. = xex bytes ----
def read_sector(n):
    if 1 <= n <= BLDCNT:
        base = (n-1)*128
        return (img[base:base+128] + [0]*128)[:128]
    off = (n - FIRSTSEC) * 128
    chunk = xex[off:off+128]
    return (chunk + [0]*128)[:128]

mpu = MPU()
for a in range(0x10000): mpu.memory[a] = 0
# place the loader at $0700 as the OS boot would
for k,v in enumerate(img): mpu.memory[0x0700+k] = v

SIOV, RUNAD_TARGET = 0xE459, 0x5000
mpu.pc = 0x0706                       # OS JSRs load+6
mpu.sp = 0xFF
init_calls = 0
steps = 0
while True:
    if mpu.pc == SIOV:                # emulate a disk sector read + RTS
        sec = mpu.memory[0x030A] | (mpu.memory[0x030B] << 8)
        data = read_sector(sec)
        dbuf = mpu.memory[0x0304] | (mpu.memory[0x0305] << 8)   # DBUFLO/HI (v2: buffer not page 6)
        for k in range(128): mpu.memory[(dbuf + k) & 0xFFFF] = data[k]
        lo = mpu.memory[0x0100 + ((mpu.sp + 1) & 0xFF)]
        hi = mpu.memory[0x0100 + ((mpu.sp + 2) & 0xFF)]
        mpu.sp = (mpu.sp + 2) & 0xFF
        mpu.pc = ((hi << 8) | lo) + 1
        continue
    if mpu.pc == RUNAD_TARGET:        # production: JMP (RUNAD) landed here
        break
    prev = mpu.pc
    mpu.step()
    steps += 1
    if mpu.pc == prev:                # DIAG build: halt loop (JMP self) at run
        break
    if steps > 200000:
        print("FAIL: runaway, last pc=%04x" % prev); sys.exit(1)

DIAG = (mpu.pc != RUNAD_TARGET)       # broke out via the halt loop

# ---- checks ----
ok = True
def chk(cond, msg):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + msg)
    ok = ok and cond

chk(mpu.memory[0x2000:0x2005] == [0x11,0x22,0x33,0x44,0x55], "seg A data at $2000")
chk(mpu.memory[0x2100:0x2104] == [0xEE,0x00,0x40,0x60], "seg B init routine at $2100")
chk(mpu.memory[0x02E2] == 0x00 and mpu.memory[0x02E3] == 0x21, "INITAD = $2100")
chk(mpu.memory[0x02E0] == 0x00 and mpu.memory[0x02E1] == 0x50, "RUNAD = $5000")
chk(mpu.memory[0x4000] == 1, "INITAD routine ran exactly once ($4000==1, got %d)" % mpu.memory[0x4000])
if DIAG:
    chk(mpu.memory[0x02C8] == 0x84, "DIAG: COLBK == blue ($84) at run")
else:
    chk(mpu.pc == RUNAD_TARGET, "execution reached RUNAD ($5000)")
print("steps:", steps, "DIAG" if DIAG else "PROD")
sys.exit(0 if ok else 1)
